import SwiftUI
import ClipSlotsKit

enum CanvasTextGeneration {
    #if DEBUG
    static var regressionBackend: (any AgentBackend)?
    #endif
    static var config: AgentConfig { configuration(defaults: .standard) }

    static func configuration(defaults: UserDefaults) -> AgentConfig {
        let selection = AgentBackendCoordinator.selection(for: .sidebar, defaults: defaults)
        return selection.normalized(baseConfiguration(defaults: defaults))
    }

    fileprivate static func baseConfiguration(defaults: UserDefaults) -> AgentConfig {
        var config = AgentPreferences.config(
            model: defaults.string(forKey: AgentPreferences.modelKey) ?? AgentConfig.defaultModel,
            systemPrompt: CanvasImagePrompt.systemPrompt,
            thinkingRaw: defaults.string(forKey: AgentPreferences.thinkingModeKey) ?? "",
            reasoningEffort: defaults.string(forKey: AgentPreferences.reasoningEffortKey) ?? "",
            endpoint: defaults.string(forKey: AgentPreferences.endpointKey) ?? AgentConfig.defaultEndpoint.absoluteString)
        config.taskPolicy = .textPolish
        return config
    }

    /// One correction pass for an unsuitable answer, with no tools or image submission.
    static func optimizedPrompt(_ prompt: String, config: AgentConfig, service: any AgentBackend) async throws -> String {
        try await optimizedPrompt(
            prompt,
            config: config,
            selection: AgentBackendCoordinator.injected(service, scope: .sidebar))
    }

    fileprivate static func optimizedPrompt(_ prompt: String,
                                            config: AgentConfig,
                                            selection: AgentBackendSelection) async throws -> String {
        var config = config
        config.taskPolicy = .textPolish
        var history: [AgentMessage] = [.init(role: .user, content: prompt)]
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let context = selection.invocation(history: history, config: config, tools: nil)
            var backend = selection.backend
            var isolated: AgentGatewayBackend?
            var temporaryRoot: URL?
            if let gateway = backend as? AgentGatewayBackend {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-polish-\(UUID())")
                let fresh = await gateway.isolatedBackend(journalRoot: root)
                backend = fresh
                isolated = fresh
                temporaryRoot = root
            }
            let messages: [AgentMessage]
            do {
                messages = try await backend.run(context: context, onEvent: { _ in })
                if let isolated, await isolated.snapshot.phase != "completed" {
                    throw AgentError.invalidResponse("润色尚未完成，已保留原文")
                }
            } catch {
                if let isolated {
                    await isolated.cancelRun()
                    if await !isolated.hasResumableRun, let temporaryRoot {
                        try? FileManager.default.removeItem(at: temporaryRoot)
                    }
                }
                throw error
            }
            if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
            try Task.checkCancellation()
            guard !messages.contains(where: { $0.isFailure || !$0.toolCalls.isEmpty || $0.role == .tool }) else {
                throw AgentError.invalidResponse("润色未返回完整正文，已保留原文")
            }
            let result = messages.filter { $0.role == .assistant && !$0.isFailure }.map(\.content).joined(separator: "\n")
            do { return try CanvasImagePrompt.normalized(result) }
            catch {
                guard attempt == 0 else { throw error }
                history.append(.init(role: .assistant, content: result))
                history.append(.init(role: .user, content: CanvasImagePrompt.repairInstruction))
            }
        }
        throw CanvasImagePrompt.OutputError.unsuitable
    }
}

extension CanvasWorkspaceView {
    /// 文本走已有 Agent 接口，禁用工具；任务仍使用画布身份票据。
    func startTextGeneration(_ snapshot: CanvasNode, service: (any AgentBackend)? = nil,
                             configuration: AgentConfig? = nil) {
        guard let node = canvas.node(id: snapshot.id), node.kind == .text,
              node.createdAt == snapshot.createdAt else { return }
        guard store.flushCanvasTextDocuments() else { return }
        let document = store.canvasTextDocument(groupID: node.groupId, slot: node.slot)
        let sourceRevision = document.revision
        let plan = CanvasWorkflowCapture.plan(node: node, canvas: canvas, store: store)
        let previous = liveText(for: node)
        if let reason = plan.blockingReasons.first {
            store.transientUI.showToast(reason)
            return
        }
        guard let ticket = canvas.beginGeneration(node) else {
            store.transientUI.showToast("这个节点正在生成")
            return
        }
        let prompt = plan.prompt
        let selection = service.map {
            AgentBackendCoordinator.injected($0, scope: .sidebar)
        } ?? AgentBackendCoordinator.selection(for: .sidebar,
            binding: .init(sessionID: "canvas-polish-\(ticket.token)",
                           projectID: ticket.projectId, canvasID: ticket.projectId))
        let baseConfig = configuration ?? CanvasTextGeneration.baseConfiguration(defaults: .standard)
        let config = selection.normalized(baseConfig)
        var backend = selection.backend
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPSLOTS_ADVANCED_TEXT_PROBE"] == "1",
           Bundle.main.bundleIdentifier == "com.clipslots.app.canvas-v2174-test",
           let fixture = CanvasTextGeneration.regressionBackend { backend = fixture }
        #endif
        let task = Task { @MainActor in
            defer { canvas.endGeneration(ticket.token) }
            do {
                let activeSelection = AgentBackendCoordinator.injected(
                    backend, scope: .sidebar, kind: selection.kind)
                let result = try await CanvasTextGeneration.optimizedPrompt(
                    prompt, config: config, selection: activeSelection)
                try Task.checkCancellation()
                guard canvas.shouldTrackGeneration(ticket.token),
                      let current = canvas.generationNode(ticket.token) else { return }
                guard document.revision == sourceRevision, liveText(for: current) == previous else {
                    throw AgentError.invalidResponse("生成期间正文已修改，已保留你的编辑")
                }
                guard store.writeCanvasSlotText(groupId: current.groupId, slot: current.slot, text: result) else {
                    throw AgentError.invalidResponse("正文保存失败，请重试")
                }
                if canvas.activeProjectId == ticket.projectId {
                    canvas.recordSlotTextEdit(nodeId: current.id, edit: .init(
                        groupId: current.groupId, slot: current.slot, before: previous, after: result))
                }
                canvas.noteSlotDataChanged()
                canvas.updateGeneration(ticket.token) { $0.state = .succeeded(assetPath: "") }
                store.transientUI.showToast("正文已润色，可继续编辑或引用到图片、视频节点")
            } catch {
                guard canvas.shouldTrackGeneration(ticket.token) else { return }
                if Task.isCancelled || error is CancellationError || error as? AgentError == .cancelled {
                    canvas.updateGeneration(ticket.token) { $0.state = .idle }
                    return
                }
                canvas.updateGeneration(ticket.token) { $0.state = .failed(reason: error.localizedDescription) }
                if error as? AgentError == .missingAPIKey {
                    agentVisible = true
                    store.transientUI.showToast("请在 Agent 设置中配置文本模型和 API Key", duration: 4)
                } else {
                    store.transientUI.showToast(error.localizedDescription, duration: 4)
                }
            }
        }
        canvas.trackGeneration(task, token: ticket.token)
    }
}
