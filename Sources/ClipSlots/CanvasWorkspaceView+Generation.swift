import SwiftUI
import ClipSlotsKit

/// Crate 的提交、查询和写回共用一条执行链；内容仍由槽位存储持有。
extension CanvasWorkspaceView {
    func runGenerationForSelection() {
        runGeneration(nodeIDs: canvas.selectedNodeIds, singleAttemptPerNode: true)
    }

    func runGeneration(nodeIDs: Set<String>, groupID: String? = nil, singleAttemptPerNode: Bool = false) {
        inputRouter.anchorView?.window?.makeFirstResponder(nil)
        let runnable = canvas.nodes.filter { $0.canGenerate }
        let selected = runnable.filter { nodeIDs.contains($0.id) }
        let targets = selected.isEmpty && nodeIDs.isEmpty && groupID == nil && runnable.count == 1 ? runnable : selected
        guard !targets.isEmpty else {
            store.transientUI.showToast("请选择图片或视频节点；文本润色请点击输入框右上角的“AI润色”")
            return
        }
        guard canvas.selectionGenerationTask == nil else {
            store.transientUI.showToast("选中节点正在生成")
            return
        }
        guard let ordered = CanvasEdgeInputs.generationOrder(nodes: targets, edges: canvas.interactionEdges) else {
            store.transientUI.showToast("连线中存在循环，请断开循环后重试")
            return
        }
        let projectId = canvas.activeProjectId
        let selectedIds = Set(ordered.map(\.id))
        let edges = CanvasEdgeInputs.generationEdges(canvas.interactionEdges)
        let runID = UUID()
        canvas.selectionGenerationID = runID
        canvas.runningGroupID = groupID
        canvas.selectionGenerationNodes = ordered
        canvas.selectionGenerationTask = Task { @MainActor in
            defer {
                if canvas.selectionGenerationID == runID {
                    canvas.selectionGenerationTask = nil
                    canvas.selectionGenerationID = nil
                    canvas.runningGroupID = nil
                    canvas.selectionGenerationNodes = []
                }
            }
            var succeeded = Set<String>()
            var completed = Set<String>()
            var upstreamResults: [String: String] = [:]
            var pending = ordered
            await withTaskGroup(of: (String, String?).self) { group in
                while !pending.isEmpty {
                    guard !Task.isCancelled, canvas.activeProjectId == projectId,
                          canvas.selectionGenerationID == runID else { return }
                    var waiting: [CanvasNode] = []
                    for snapshot in pending {
                        let required = edges.filter { $0.toNodeId == snapshot.id }
                            .map(\.fromNodeId).filter { selectedIds.contains($0) }
                        guard required.allSatisfy({ completed.contains($0) }) else {
                            waiting.append(snapshot)
                            continue
                        }
                        guard required.allSatisfy({ succeeded.contains($0) }) else {
                            completed.insert(snapshot.id)
                            store.transientUI.showToast("上游未完成，已跳过依赖它的节点", duration: 4)
                            continue
                        }
                        let previousTasks = Dictionary(canvas.nodes.map { ($0.id, $0.taskId) },
                                                       uniquingKeysWith: { first, _ in first })
                        guard let live = canvas.selectionGenerationNode(snapshot),
                              let task = generateAdjacentResults(live, upstreamResults: upstreamResults,
                                                                 singleAttempt: singleAttemptPerNode) else {
                            completed.insert(snapshot.id)
                            continue
                        }
                        let attempts = (canvas.adjacentLastResultIDs[live.id] ?? [live.id])
                            .compactMap { canvas.node(id: $0) }
                        group.addTask {
                            await task.value
                            let result = await MainActor.run { () -> String? in
                                guard canvas.activeProjectId == projectId,
                                      canvas.selectionGenerationID == runID else { return nil }
                                return attempts.last(where: { attempt in
                                    guard let current = canvas.node(id: attempt.id),
                                          current.createdAt == attempt.createdAt,
                                          let taskID = current.taskId,
                                          taskID != (previousTasks[current.id] ?? nil),
                                          case .succeeded = current.state else { return false }
                                    return true
                                })?.id
                            }
                            return (snapshot.id, result)
                        }
                    }
                    pending = waiting
                    if let (id, result) = await group.next() {
                        completed.insert(id)
                        if let result {
                            succeeded.insert(id)
                            upstreamResults[id] = result
                        }
                    } else if !pending.isEmpty {
                        completed.formUnion(pending.map(\.id))
                        store.transientUI.showToast("上游未完成，已跳过依赖它的节点", duration: 4)
                        pending = []
                    }
                }
                // All independent submissions start before any result is awaited.
                for await _ in group {}
            }
        }
    }

    /// The selected node is attempt one; count N allocates N-1 later results.
    /// Run submits current inputs; only explicit recovery queries an old task.
    @discardableResult
    func generateAdjacentResults(_ snapshot: CanvasNode,
                                 upstreamResults: [String: String] = [:],
                                 preparedByteArtist: PreparedGenerationRequest? = nil,
                                 singleAttempt: Bool = false) -> Task<Void, Never>? {
        guard let source = canvas.node(id: snapshot.id), source.createdAt == snapshot.createdAt,
              source.canGenerate else { return nil }
        guard !canvas.hasActiveGeneration(source) else {
            store.transientUI.showToast("本次生成已开始，请在节点查看进度")
            return nil
        }
        guard source.kind.isMediaNode else { return startGeneration(source, restarting: true) }
        guard GenerationRunStore.shared.latest(project: canvas.activeProjectId, node: source)?
            .requiresSubmissionReconciliation != true else {
            store.transientUI.showToast("上次提交结果未知，请先核对任务后再重新生成", duration: 4)
            return nil
        }
        guard canvas.adjacentGenerationIDs[source.id] == nil else {
            store.transientUI.showToast("本次生成已开始，请在结果节点查看进度")
            return nil
        }
        guard store.flushCanvasTextDocuments() else { return nil }
        var single = source
        single.count = 1
        let plan = CanvasWorkflowCapture.plan(node: single, canvas: canvas, store: store,
                                             upstreamResults: upstreamResults)
        if let reason = plan.blockingReasons.first {
            store.transientUI.showToast(reason, duration: 4)
            return nil
        }
        if source.generationProvider == .byteartist {
            do { _ = try validateByteArtist(source, plan: plan) }
            catch { store.transientUI.showToast(error.localizedDescription, duration: 4); return nil }
            if preparedByteArtist == nil {
                if singleAttempt {
                    canvas.adjacentLastResultIDs[source.id] = [source.id]
                    return startGeneration(source, restarting: true, upstreamResults: upstreamResults,
                                           preparedPlan: plan)
                }
                return prepareByteArtistBatch(source, plan: plan, upstreamResults: upstreamResults)
            }
        }
        let group = canvas.privateGroupId
        guard store.ensureCanvasPrivateGroup(id: group, name: canvas.activeProject.privateGroupName) else { return nil }
        var occupied = canvas.occupiedSlots(inGroup: group)
        var slots: [Int] = []
        for _ in 0..<(singleAttempt ? 0 : min(4, max(1, source.count)) - 1) {
            guard let slot = store.allocateCanvasPrivateSlot(groupId: group, occupied: occupied) else {
                store.transientUI.showToast("没有足够空槽创建本次生成结果")
                return nil
            }
            slots.append(slot)
            occupied.insert(slot)
        }
        let inputs = inputAttachments(for: source)
        let prompt = liveText(for: source)
        var preparedSlots: [Int] = []
        var createdResults = false
        defer {
            if !createdResults {
                for slot in preparedSlots {
                    _ = SpecialSlotStorage.canvasPrivate.clear(slot, in: group)
                }
            }
        }
        var inputIDs: [Int: [String]] = [:]
        for slot in slots {
            preparedSlots.append(slot)
            guard store.writeCanvasSlotText(groupId: group, slot: slot, text: prompt) else {
                store.transientUI.showToast("提示词保存失败，未提交生成")
                return nil
            }
            var copies = inputs.map { attachment -> SlotContent.SlotAttachment in
                var copy = SlotContent.SlotAttachment(name: attachment.name, type: attachment.type)
                copy.storagePath = attachment.storageFileURL?.path ?? attachment.storagePath
                copy.path = attachment.path
                copy.originalPath = attachment.originalPath
                copy.data = attachment.data
                copy.url = attachment.url
                return copy
            }
            if !copies.isEmpty {
                guard store.writeCanvasSlotAttachments(groupId: group, slot: slot, attachments: copies) else {
                    store.transientUI.showToast("参考文件保存失败，未提交生成")
                    return nil
                }
                copies = store.canvasSlotAttachments(groupId: group, slot: slot)
                inputIDs[slot] = copies.map { $0.id.uuidString }
            }
        }
        let children = slots.isEmpty ? [] : canvas.addGenerationResults(
            source: source, slots: slots, inputIDs: inputIDs, upstreamResults: upstreamResults)
        guard children.count == slots.count else { return nil }
        createdResults = true
        let resultNodes = [source] + children
        canvas.adjacentLastResultIDs[source.id] = resultNodes.map(\.id)
        let batchID = UUID()
        canvas.adjacentGenerationIDs[source.id] = batchID
        // Capture every request before submitting any task. Batch siblings never
        // inherit an output that finishes while another request is being prepared.
        let tasks = resultNodes.compactMap {
            startGeneration(canvas.node(id: $0.id) ?? $0, restarting: true, upstreamResults: upstreamResults,
                            preparedPlan: plan, preparedByteArtist: preparedByteArtist)
        }
        let aggregate = Task { @MainActor in
            defer {
                if canvas.adjacentGenerationIDs[source.id] == batchID {
                    canvas.adjacentGenerationIDs[source.id] = nil
                    canvas.adjacentGenerationTasks[source.id] = nil
                }
            }
            for task in tasks {
                // Never cancel a submit that has not returned its remote ID.
                // CanvasStore.stopGeneration owns the safe stop/recovery path.
                await task.value
            }
        }
        canvas.adjacentGenerationTasks[source.id] = aggregate
        return aggregate
    }

    @discardableResult
    func startGeneration(_ snapshot: CanvasNode, reusingSeed: Bool = false, restarting: Bool = false,
                         upstreamResults: [String: String] = [:],
                         preparedPlan: CanvasWorkflowResolver.Plan? = nil,
                         preparedByteArtist: PreparedGenerationRequest? = nil) -> Task<Void, Never>? {
        guard let node = canvas.node(id: snapshot.id), node.createdAt == snapshot.createdAt,
              node.canGenerate else { return nil }
        guard store.flushCanvasTextDocuments() else { return nil }
        if node.needsGenerationRecovery && !restarting && !reusingSeed {
            return recoverGeneration(node)
        }
        if !restarting && !reusingSeed,
           GenerationRunStore.shared.latest(project: canvas.activeProjectId, node: node)?.requiresSubmissionReconciliation == true {
            store.transientUI.showToast("上次提交结果未知，请先在原平台核对任务；确认需要新任务后使用“重新生成”。", duration: 5)
            return nil
        }
        let plan = preparedPlan ?? CanvasWorkflowCapture.plan(node: node, canvas: canvas, store: store,
                                             reusingSeed: reusingSeed, upstreamResults: upstreamResults)
        if let reason = plan.blockingReasons.first {
            store.transientUI.showToast(reason, duration: 4)
            return nil
        }
        if node.generationProvider == .byteartist {
            return startByteArtistGeneration(node, plan: plan, restarting: restarting || reusingSeed,
                                             prepared: preparedByteArtist)
        }
        let (workflow, paths) = CanvasWorkflowCapture.snapshot(canvas: canvas, store: store)
        let recording = GenerationRunContext(snapshot: workflow, node: node, resourceIDs: paths)
        if let request = plan.videoRequest {
            return executeGeneration(node, restarting: restarting || reusingSeed) {
                let submission = try await CrateGenerationService.shared.submit(request, recording: recording)
                var warnings = submission.droppedParameters
                if submission.droppedSeed { warnings.append("固定 seed") }
                return (submission.result.taskId, submission.result.seed, warnings)
            }
        } else if let request = plan.imageRequest {
            return executeGeneration(node, restarting: restarting || reusingSeed) {
                let submission = try await CrateGenerationService.shared.submit(request, recording: recording)
                var warnings: [String] = []
                if submission.droppedSeed { warnings.append("固定 seed") }
                if submission.droppedRatio { warnings.append("比例 \(node.ratio)") }
                return (submission.result.taskId, submission.result.seed, warnings)
            }
        }
        return nil
    }

    /// 只查询旧任务，不走 submit，超时和下载失败后不必再扣一次生成额度。
    @discardableResult
    func recoverGeneration(_ snapshot: CanvasNode) -> Task<Void, Never>? {
        guard let node = canvas.node(id: snapshot.id), node.createdAt == snapshot.createdAt,
              node.canGenerate,
              let taskId = node.taskId, !taskId.isEmpty else { return nil }
        if let task = node.generationTask, task.context.provider == .byteartist {
            return executeByteArtistGeneration(node, recovering: task)
        }
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
                    $0.generationTask = try? GenerationTaskHandle(context: .crate, taskID: submitted.taskId,
                        capabilityID: node.model, kind: node.kind == .video ? .video : .image, seed: submitted.seed)
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
                    timeout: node.kind == .video ? CrateGeneration.videoPollTimeout : CrateGeneration.pollTimeout,
                    recordingProject: ticket.projectId
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
                try await finishGeneration(token: ticket.token, file: file, taskId: submitted.taskId, projectID: ticket.projectId)
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
        CanvasWorkflowCapture.plan(node: node, canvas: canvas, store: store).edgeInputs
    }

    /// 生成和 composer 共用入参集合；显式上传的历史生成文件可再次作为参考。
    func inputAttachments(for node: CanvasNode) -> [SlotContent.SlotAttachment] {
        CanvasWorkflowCapture.inputAttachments(node: node,
            attachments: store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot))
    }

    func inputImagePaths(for node: CanvasNode) -> [String] {
        // #region debug-point C:input-paths
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPSLOTS_INPUT_UPLOAD_PROBE"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7791/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-input-upload", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "C", "msg": "[DEBUG] resolved generation inputs", "data": ["kind": node.kind.rawValue, "count": CrateGeneration.inputImagePaths(from: inputAttachments(for: node), excludingAttachmentIds: Set(node.outputAttachmentIds), explicitInputIds: Set(node.inputAttachmentIds), fileExists: { FileManager.default.fileExists(atPath: $0) }).count]]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
        return CrateGeneration.inputImagePaths(
            from: inputAttachments(for: node),
            excludingAttachmentIds: Set(node.outputAttachmentIds),
            explicitInputIds: Set(node.inputAttachmentIds),
            fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    func finishGeneration(token: UUID, file: URL, taskId: String, projectID: String,
                          provider: GenerationProviderContext = .crate,
                          marksCompleted: Bool = true) async throws {
        guard let owner = canvas.generationNode(token) else { return }
        if owner.kind == .image {
            let downloadID = provider.provider == .crate ? taskId
                : "ba-" + CanvasWorkflowSnapshot.digest(Data("\(provider)|\(taskId)|\(file.lastPathComponent)".utf8))
            _ = try await CanvasImageDownloads.shared.save(file: file, taskID: downloadID)
            guard canvas.shouldTrackGeneration(token) else { return }
        }
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
            if marksCompleted {
                canvas.updateGeneration(token) { $0.state = .succeeded(assetPath: saved.storagePath ?? "") }
            }
            try? GenerationRunStore.shared.updateTask(project: projectID, taskID: taskId,
                outcome: marksCompleted ? "succeeded" : "saving", outputIDs: owner.outputAttachmentIds, provider: provider)
            return
        }
        attachments.append(attachment)
        guard let saved = store.appendCanvasGeneratedAttachment(attachment, groupId: owner.groupId, slot: owner.slot),
              let path = saved.storagePath, path != file.path,
              FileManager.default.fileExists(atPath: path) else {
            throw CrateGenerationService.ServiceError.taskFailed(reason: "产物写入失败，可用“取回结果”重试")
        }
        let alive = Set(attachments.map { $0.id.uuidString })
        canvas.updateGeneration(token) {
            if marksCompleted { $0.state = .succeeded(assetPath: path) }
            $0.taskId = taskId
            $0.outputAttachmentIds = $0.outputAttachmentIds.filter { alive.contains($0) }
            if !$0.outputAttachmentIds.contains(attachment.id.uuidString) {
                $0.outputAttachmentIds.append(attachment.id.uuidString)
            }
        }
        try? GenerationRunStore.shared.updateTask(project: projectID, taskID: taskId,
            outcome: marksCompleted ? "succeeded" : "saving", outputIDs: canvas.generationNode(token)?.outputAttachmentIds ?? [],
            provider: provider)
        canvas.noteSlotDataChanged()
        if marksCompleted {
            store.transientUI.showToast(owner.kind == .image ? "生成完成，原图已保存到下载文件夹" : "生成完成")
        }
    }

    func downloadGeneratedImages(_ nodes: [CanvasNode]) {
        let images = nodes.filter { $0.kind == .image && !$0.isMediaSource }
        let files = images.compactMap { node -> (URL, String)? in
            guard let media = previewableMedia(of: node), let url = media.canvasLocalURL else { return nil }
            return (url, node.taskId ?? media.id.uuidString)
        }
        guard !files.isEmpty else {
            store.transientUI.showToast("图片生成完成后会自动保存到下载文件夹")
            return
        }
        Task { @MainActor in
            do {
                var saved: [URL] = []
                for (file, taskID) in files {
                    saved.append(try await CanvasImageDownloads.shared.save(file: file, taskID: taskID))
                }
                NSWorkspace.shared.activateFileViewerSelecting(saved)
                store.transientUI.showToast("已保存 \(saved.count) 张原图")
            } catch {
                store.transientUI.showToast("原图下载保存失败：\(error.localizedDescription)", duration: 4)
            }
        }
    }
}
