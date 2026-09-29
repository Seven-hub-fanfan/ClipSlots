import SwiftUI
import ClipSlotsKit

enum CanvasTextGeneration {
    static var config: AgentConfig { configuration(defaults: .standard) }

    static func configuration(defaults: UserDefaults) -> AgentConfig {
        return AgentPreferences.config(
            model: defaults.string(forKey: AgentPreferences.modelKey) ?? AgentConfig.defaultModel,
            systemPrompt: CanvasImagePrompt.systemPrompt,
            thinkingRaw: defaults.string(forKey: AgentPreferences.thinkingModeKey) ?? "",
            reasoningEffort: defaults.string(forKey: AgentPreferences.reasoningEffortKey) ?? "",
            endpoint: defaults.string(forKey: AgentPreferences.endpointKey) ?? AgentConfig.defaultEndpoint.absoluteString)
    }

    /// One correction pass for an unsuitable answer, with no tools or image submission.
    static func optimizedPrompt(_ prompt: String, config: AgentConfig, service: AgentService) async throws -> String {
        var history: [AgentMessage] = [.init(role: .user, content: prompt)]
        for attempt in 0..<2 {
            let messages = try await service.run(history: history, config: config, tools: nil, onEvent: { _ in })
            let result = messages.filter { $0.role == .assistant && !$0.isFailure }.map(\.content).joined(separator: "\n")
            // #region debug-point A-B:prompt-result
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1" { var request = URLRequest(url: URL(string: "http://127.0.0.1:7781/event")!); request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-prompt-sizing", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "A-B", "msg": "[DEBUG] text result format", "data": ["attempt": attempt, "characters": result.count, "svg": result.lowercased().contains("<svg"), "fenced": result.contains("```"), "replacementCharacter": result.contains("\u{fffd}"), "promptSpecific": config.systemPrompt.contains("生图提示词")]]); URLSession.shared.dataTask(with: request).resume() }
            #endif
            // #endregion
            do { return try CanvasImagePrompt.normalized(result) }
            catch {
                guard attempt == 0 else { throw error }
                history.append(.init(role: .user, content: CanvasImagePrompt.repairInstruction))
            }
        }
        throw CanvasImagePrompt.OutputError.unsuitable
    }
}

extension CanvasWorkspaceView {
    /// 文本走已有 Agent 接口，禁用工具；任务仍使用画布身份票据。
    func startTextGeneration(_ snapshot: CanvasNode, service: AgentService = AgentService(),
                             configuration: AgentConfig? = nil) {
        guard let node = canvas.node(id: snapshot.id), node.kind == .text,
              node.createdAt == snapshot.createdAt else { return }
        let upstream = canvas.incomingEdges(of: node.id).compactMap { edge -> String? in
            guard let source = canvas.node(id: edge.fromNodeId) else { return nil }
            let text = liveText(for: source)
            return text.isEmpty ? nil : text
        }
        let previous = liveText(for: node)
        let intent = node.textGenerationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty || !upstream.isEmpty || (try? CanvasImagePrompt.normalized(previous)) != nil else {
            store.transientUI.showToast("先描述画面想法，或连接参考文本")
            return
        }
        guard let ticket = canvas.beginGeneration(node) else {
            store.transientUI.showToast("这个节点正在生成")
            return
        }
        let prompt = CanvasImagePrompt.request(intent: intent.isEmpty ? "优化为完整的生图提示词" : intent,
                                               existing: previous, references: upstream)
        let config = configuration ?? CanvasTextGeneration.config
        Task { @MainActor in
            defer { canvas.endGeneration(ticket.token) }
            do {
                let result = try await CanvasTextGeneration.optimizedPrompt(prompt, config: config, service: service)
                guard let current = canvas.generationNode(ticket.token) else { return }
                guard liveText(for: current) == previous else {
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
                store.transientUI.showToast("生图提示词已优化，可编辑后引用到图片节点")
            } catch {
                guard canvas.generationNode(ticket.token) != nil else { return }
                canvas.updateGeneration(ticket.token) { $0.state = .failed(reason: error.localizedDescription) }
                if error as? AgentError == .missingAPIKey {
                    agentVisible = true
                    store.transientUI.showToast("请在 Agent 设置中配置文本模型和 API Key", duration: 4)
                } else {
                    store.transientUI.showToast(error.localizedDescription, duration: 4)
                }
            }
        }
    }
}
