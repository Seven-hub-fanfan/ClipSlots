import SwiftUI
import ClipSlotsKit

/// Crate 的提交、查询和写回共用一条执行链；内容仍由槽位存储持有。
extension CanvasWorkspaceView {
    func runGenerationForSelection() {
        inputRouter.anchorView?.window?.makeFirstResponder(nil)
        let runnable = canvas.nodes.filter { $0.kind.producesAsset || $0.kind == .text }
        let selected = runnable.filter { canvas.selectedNodeIds.contains($0.id) }
        let targets = selected.isEmpty && canvas.selectedNodeIds.isEmpty && runnable.count == 1 ? runnable : selected
        guard !targets.isEmpty else {
            store.transientUI.showToast("先选中要生成的文本、图片或视频节点")
            return
        }
        let promptNodes = targets.filter { $0.kind == .text }
        if !promptNodes.isEmpty {
            for node in promptNodes { startTextGeneration(node) }
            if targets.count > promptNodes.count {
                store.transientUI.showToast("先优化生图提示词，确认后再选择图片或视频节点生成", duration: 4)
            }
            return
        }
        guard canvas.selectionGenerationTask == nil else {
            store.transientUI.showToast("选中节点正在按依赖顺序生成")
            return
        }
        guard let ordered = CanvasEdgeInputs.generationOrder(nodes: targets, edges: canvas.edges) else {
            store.transientUI.showToast("连线中存在循环，请断开循环后重试")
            return
        }
        let projectId = canvas.activeProjectId
        let selectedIds = Set(ordered.map(\.id))
        canvas.selectionGenerationTask = Task { @MainActor in
            defer { canvas.selectionGenerationTask = nil }
            var succeeded = Set<String>()
            for snapshot in ordered {
                guard !Task.isCancelled, canvas.activeProjectId == projectId else { return }
                let required = canvas.incomingEdges(of: snapshot.id)
                    .map(\.fromNodeId).filter { selectedIds.contains($0) }
                guard required.allSatisfy({ succeeded.contains($0) }) else {
                    store.transientUI.showToast("上游未完成，已跳过依赖它的节点", duration: 4)
                    continue
                }
                guard let task = startGeneration(snapshot) else { continue }
                await task.value
                if let current = canvas.node(id: snapshot.id), current.createdAt == snapshot.createdAt,
                   case .succeeded = current.state { succeeded.insert(snapshot.id) }
            }
        }
    }

    @discardableResult
    func startGeneration(_ snapshot: CanvasNode, reusingSeed: Bool = false, restarting: Bool = false) -> Task<Void, Never>? {
        guard let node = canvas.node(id: snapshot.id), node.createdAt == snapshot.createdAt,
              node.kind.producesAsset else { return nil }
        if node.needsGenerationRecovery && !restarting && !reusingSeed {
            return recoverGeneration(node)
        }
        let inputs = resolveEdgeInputs(for: node)
        // #region debug-point A:resolved-inputs
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPSLOTS_CONTROL_PROBE"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7784/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "slot-input-controls", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "A", "msg": "[DEBUG] resolved generation inputs", "data": ["kind": node.kind.rawValue, "incoming": canvas.incomingEdges(of: node.id).count, "promptFragments": inputs.promptFragments.count, "images": inputs.assetPaths.count, "pending": inputs.pendingUpstreamCount]]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
        if let reason = inputs.blockingReason {
            store.transientUI.showToast(reason, duration: 4)
            return nil
        }
        let prompt = CanvasEdgeInputs.mergedPrompt(
            own: store.canvasSlotText(groupId: node.groupId, slot: node.slot) ?? "",
            upstream: inputs.promptFragments)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.transientUI.showToast(inputs.pendingUpstreamCount > 0
                ? "上游还没出结果，先生成上游节点"
                : CrateRequestError.emptyPrompt.userMessage)
            return nil
        }
        guard node.count == 1 else {
            store.transientUI.showToast(CrateRequestError.unsupportedCount(node.count).userMessage)
            return nil
        }
        let slotImages = inputImagePaths(for: node)
        let ownImages = store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
            .filter { $0.canvasIsImageLike && !node.outputAttachmentIds.contains($0.id.uuidString)
                && !CrateGeneration.isGeneratedAssetName($0.name) }
        if ownImages.count > slotImages.count {
            store.transientUI.showToast("本节点有参考图片不可用，请在入参文件中检查或重新添加", duration: 4)
            return nil
        }
        if node.kind == .video {
            let info = CrateModelCatalogStore.shared.videoModels.first { $0.id == node.model }
            let frames = CanvasEdgeInputs.videoFrames(edgeInputs: inputs, slotImages: slotImages, model: info)
            if let info, info.requiresImageInput, frames.first == nil, frames.last == nil, frames.references.isEmpty {
                store.transientUI.showToast(CrateRequestError.missingRequiredImage(model: node.model).userMessage)
                return nil
            }
            let request = CrateVideoRequest(
                model: node.model, prompt: prompt, ratio: node.ratio,
                resolution: (info?.supportsResolution ?? true) ? node.resolution : "",
                duration: (info?.supportsDuration ?? true) ? node.duration : nil,
                generateAudio: (info?.supportsAudio ?? false) ? node.generateAudio : nil,
                firstFramePath: frames.first, lastFramePath: frames.last,
                referenceImagePaths: frames.references, seed: reusingSeed ? node.seed : nil)
            return executeGeneration(node, restarting: restarting || reusingSeed) {
                let submission = try await CrateGenerationService.shared.submit(request)
                var warnings = submission.droppedParameters
                if submission.droppedSeed { warnings.append("固定 seed") }
                return (submission.result.taskId, submission.result.seed, warnings)
            }
        } else {
            let request = CrateImageRequest(
                model: node.model, prompt: prompt, ratio: node.ratio, count: node.count,
                imagePaths: CanvasEdgeInputs.imageReferences(edgeInputs: inputs, slotImages: slotImages),
                seed: reusingSeed ? node.seed : nil)
            return executeGeneration(node, restarting: restarting || reusingSeed) {
                let submission = try await CrateGenerationService.shared.submit(request)
                var warnings: [String] = []
                if submission.droppedSeed { warnings.append("固定 seed") }
                if submission.droppedRatio { warnings.append("比例 \(node.ratio)") }
                return (submission.result.taskId, submission.result.seed, warnings)
            }
        }
    }

    /// 只查询旧任务，不走 submit，超时和下载失败后不必再扣一次生成额度。
    @discardableResult
    func recoverGeneration(_ snapshot: CanvasNode) -> Task<Void, Never>? {
        guard let node = canvas.node(id: snapshot.id), node.createdAt == snapshot.createdAt,
              let taskId = node.taskId, !taskId.isEmpty else { return nil }
        return executeGeneration(node, recovering: true) { (taskId, node.seed, []) }
    }

    private func executeGeneration(
        _ node: CanvasNode, recovering: Bool = false, restarting: Bool = false,
        submit: @escaping () async throws -> (taskId: String, seed: Int?, warnings: [String])
    ) -> Task<Void, Never>? {
        guard let ticket = canvas.beginGeneration(node, recovering: recovering, restarting: restarting) else {
            store.transientUI.showToast("这个节点已有任务正在跟踪")
            return nil
        }
        let task = Task { @MainActor in
            defer { canvas.endGeneration(ticket.token) }
            let service = CrateGenerationService.shared
            do {
                try await service.preflight()
                guard canvas.shouldTrackGeneration(ticket.token) else { return }
                let submitted = try await submit()
                canvas.updateGeneration(ticket.token) {
                    $0.taskId = submitted.taskId
                    if let seed = submitted.seed { $0.seed = seed }
                }
                // 提交身份必须立即落盘：重启后“取回结果”可以继续查询，避免再次提交。
                canvas.flushSave()
                if !submitted.warnings.isEmpty {
                    store.transientUI.showToast("\(node.model) 不支持 \(submitted.warnings.joined(separator: "、"))，使用模型默认值", duration: 3)
                }
                guard canvas.shouldTrackGeneration(ticket.token) else { return }
                let urls = try await service.waitForCompletion(
                    taskId: submitted.taskId,
                    timeout: node.kind == .video ? CrateGeneration.videoPollTimeout : CrateGeneration.pollTimeout
                ) { progress in
                    Task { @MainActor in
                        self.applyProgress(progress, token: ticket.token)
                    }
                }
                guard canvas.shouldTrackGeneration(ticket.token) else { return }
                guard let first = urls.first else {
                    throw CrateGenerationService.ServiceError.taskFailed(reason: "任务完成但没有产物")
                }
                let file = try await service.download(urlString: first, taskId: submitted.taskId,
                                                      index: 0, fallbackExtension: node.kind == .video ? "mp4" : "jpg")
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                guard canvas.shouldTrackGeneration(ticket.token) else { return }
                finishGeneration(token: ticket.token, file: file, taskId: submitted.taskId)
            } catch {
                guard canvas.shouldTrackGeneration(ticket.token) else { return }
                let serviceError = error as? CrateGenerationService.ServiceError
                let reason = serviceError?.userMessage ?? error.localizedDescription
                NSLog("[ClipSlots][crate] node=\(node.id) \(serviceError?.logDetail ?? reason)")
                canvas.updateGeneration(ticket.token) { $0.state = .failed(reason: reason) }
                store.transientUI.showToast(reason, duration: 3)
            }
        }
        canvas.trackGeneration(task, token: ticket.token)
        return task
    }

    private func applyProgress(_ progress: CrateTaskProgress, token: UUID) {
        guard canvas.shouldTrackGeneration(token) else { return }
        canvas.updateGeneration(token) { node in
            switch progress {
            case .queued(let ahead): node.state = .queued(ahead: ahead)
            case .running:
                if case .running = node.state { return }
                node.state = .running(startedAt: Date())
            case .succeeded, .failed: break
            }
        }
    }

    func slotReferenceImagePaths(for node: CanvasNode) -> [String] {
        CrateGeneration.inputImagePaths(
            from: store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot),
            excludingAttachmentIds: [], includingGeneratedAssets: true,
            fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    func resolveEdgeInputs(for node: CanvasNode) -> CanvasEdgeInputs.Resolved {
        let incoming = canvas.incomingEdges(of: node.id)
        var upstreams: [String: CanvasEdgeInputs.Upstream] = [:]
        for edge in incoming {
            guard upstreams[edge.fromNodeId] == nil, let up = canvas.node(id: edge.fromNodeId) else { continue }
            var path: String?
            if case .succeeded(let asset) = up.state, !asset.isEmpty,
               FileManager.default.fileExists(atPath: asset) { path = asset }
            upstreams[up.id] = .init(nodeId: up.id, kind: up.kind,
                                     text: store.canvasSlotText(groupId: up.groupId, slot: up.slot) ?? "",
                                     assetPath: path,
                                     imagePaths: up.kind == .slot ? slotReferenceImagePaths(for: up) : [])
        }
        var resolved = CanvasEdgeInputs.resolve(incoming: incoming, upstreams: upstreams, downstreamKind: node.kind)
        // 缺失的槽位图片不能被筛掉后伪装成纯文本输入。
        for id in Set(incoming.filter { $0.role != .prompt }.map(\.fromNodeId)) {
            guard let upstream = canvas.node(id: id), upstream.kind == .slot else { continue }
            let expected = store.canvasSlotAttachments(groupId: upstream.groupId, slot: upstream.slot)
                .filter(\.canvasIsImageLike).count
            if (upstreams[id]?.imagePaths.count ?? 0) < expected { resolved.unavailableUpstreamCount += 1 }
        }
        return resolved
    }

    func inputImagePaths(for node: CanvasNode) -> [String] {
        CrateGeneration.inputImagePaths(
            from: store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot),
            excludingAttachmentIds: Set(node.outputAttachmentIds),
            fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    private func finishGeneration(token: UUID, file: URL, taskId: String) {
        guard let owner = canvas.generationNode(token) else { return }
        let type: SlotContent.AttachmentType = CanvasAttachmentKind.from(fileName: file.lastPathComponent) == .image ? .image : .file
        // storagePath 交给既有外置附件摄取器克隆到正式槽位；视频不再整包读入主线程内存。
        var attachment = SlotContent.SlotAttachment(name: file.lastPathComponent, type: type)
        attachment.storagePath = file.path
        var attachments = store.canvasSlotAttachments(groupId: owner.groupId, slot: owner.slot)
        // 同一任务恢复查询幂等，不重复添加产物。
        if let saved = attachments.first(where: {
            $0.name == file.lastPathComponent && owner.outputAttachmentIds.contains($0.id.uuidString)
                && ($0.storagePath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
        }) {
            canvas.updateGeneration(token) { $0.state = .succeeded(assetPath: saved.storagePath ?? "") }
            return
        }
        attachments.append(attachment)
        guard let saved = store.appendCanvasGeneratedAttachment(attachment, groupId: owner.groupId, slot: owner.slot),
              let path = saved.storagePath, path != file.path,
              FileManager.default.fileExists(atPath: path) else {
            canvas.updateGeneration(token) { $0.state = .failed(reason: "产物写入失败，可用“取回结果”重试") }
            store.transientUI.showToast("产物写入失败，可用“取回结果”重试")
            return
        }
        let alive = Set(attachments.map { $0.id.uuidString })
        canvas.updateGeneration(token) {
            $0.state = .succeeded(assetPath: path)
            $0.taskId = taskId
            $0.outputAttachmentIds = $0.outputAttachmentIds.filter { alive.contains($0) }
            if !$0.outputAttachmentIds.contains(attachment.id.uuidString) {
                $0.outputAttachmentIds.append(attachment.id.uuidString)
            }
        }
        canvas.noteSlotDataChanged()
        store.transientUI.showToast("生成完成")
    }
}
