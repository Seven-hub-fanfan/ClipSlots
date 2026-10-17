import SwiftUI
import ClipSlotsKit
import ImageIO
import AVFoundation

extension CanvasWorkspaceView {
    func prepareByteArtistBatch(_ node: CanvasNode, plan: CanvasWorkflowResolver.Plan,
                                upstreamResults: [String: String]) -> Task<Void, Never>? {
        let batch = UUID()
        canvas.adjacentGenerationIDs[node.id] = batch
        canvas.updateNode(id: node.id) { $0.generationDiagnostic = .init(stage: "preparing") }
        let project = canvas.activeProjectId
        let task = Task { @MainActor in
            defer {
                if canvas.adjacentGenerationIDs[node.id] == batch {
                    canvas.adjacentGenerationIDs[node.id] = nil
                    canvas.adjacentGenerationTasks[node.id] = nil
                }
            }
            do {
                let capability = try validateByteArtist(node, plan: plan)
                let runtime = try ByteArtistCatalogStore.shared.runtime()
                try await runtime.adapter.preflight()
                let prepared = try await runtime.prepare(configuration: node.byteArtist, capability: capability,
                    prompt: plan.prompt, images: plan.providerImages,
                    firstFrame: plan.edgeInputs.firstFramePath, lastFrame: plan.edgeInputs.lastFramePath)
                try Task.checkCancellation()
                let livePlan = canvas.node(id: node.id).map {
                    CanvasWorkflowCapture.plan(node: $0, canvas: canvas, store: store)
                }
                guard canvas.activeProjectId == project, let live = canvas.node(id: node.id),
                      live.createdAt == node.createdAt, live.byteArtist == node.byteArtist,
                      live.generationProvider == .byteartist,
                      live.count == node.count,
                      livePlan?.prompt == plan.prompt, livePlan?.providerImages == plan.providerImages,
                      livePlan?.edgeInputs == plan.edgeInputs else {
                    store.transientUI.showToast("生成参数已变化，请确认后重新生成。")
                    return
                }
                canvas.adjacentGenerationIDs[node.id] = nil
                canvas.adjacentGenerationTasks[node.id] = nil
                await generateAdjacentResults(live, upstreamResults: upstreamResults, preparedByteArtist: prepared)?.value
            } catch {
                guard canvas.activeProjectId == project else { return }
                canvas.updateNode(id: node.id) { $0.generationDiagnostic = .init(stage: "preparing", message: error.localizedDescription) }
                store.transientUI.showToast(error.localizedDescription, duration: 5)
            }
        }
        canvas.adjacentGenerationTasks[node.id] = task
        return task
    }

    func validateByteArtist(_ node: CanvasNode, plan: CanvasWorkflowResolver.Plan) throws -> GenerationCapability {
        guard let capability = ByteArtistCatalogStore.shared.capability(id: node.byteArtist.workflowID) else {
            throw GenerationAdapterError.invalidInput("请点击 BA 旁的「选择工作流」，添加或重新加载能力。")
        }
        guard capability.kind == (node.kind == .video ? .video : .image) else {
            throw GenerationAdapterError.invalidInput("BA 工作流输出类型与当前节点不匹配。")
        }
        _ = try node.byteArtist.input(capability: capability, prompt: plan.prompt,
            images: plan.providerImages, firstFrame: plan.edgeInputs.firstFramePath, lastFrame: plan.edgeInputs.lastFramePath)
        return capability
    }

    func startByteArtistGeneration(_ node: CanvasNode, plan: CanvasWorkflowResolver.Plan,
                                   restarting: Bool, prepared: PreparedGenerationRequest? = nil) -> Task<Void, Never>? {
        do {
            let capability = try validateByteArtist(node, plan: plan)
            let (snapshot, paths) = CanvasWorkflowCapture.snapshot(canvas: canvas, store: store)
            let context = GenerationRunContext(snapshot: snapshot, node: node, resourceIDs: paths)
            return executeByteArtistGeneration(node, restarting: restarting,
                preparation: (plan, capability, context), prepared: prepared)
        } catch {
            store.transientUI.showToast(error.localizedDescription, duration: 4)
            return nil
        }
    }

    func executeByteArtistGeneration(_ node: CanvasNode, recovering: GenerationTaskHandle? = nil,
                                     restarting: Bool = false,
                                     preparation: (CanvasWorkflowResolver.Plan, GenerationCapability, GenerationRunContext)? = nil,
                                     prepared: PreparedGenerationRequest? = nil) -> Task<Void, Never>? {
        guard let ticket = canvas.beginGeneration(node, recovering: recovering != nil, restarting: restarting) else {
            store.transientUI.showToast("这个节点已有任务正在跟踪")
            return nil
        }
        let task = Task { @MainActor in
            defer { canvas.endGeneration(ticket.token) }
            do {
                canvas.updateGeneration(ticket.token) { $0.generationDiagnostic = .init(stage: "preparing") }
                let runtime = try ByteArtistCatalogStore.shared.runtime()
                try await runtime.adapter.preflight()
                guard canvas.shouldTrackGeneration(ticket.token) else { return }
                let handle: GenerationTaskHandle
                if let recovering { handle = recovering }
                else if let (plan, capability, context) = preparation {
                    let request: PreparedGenerationRequest
                    if let prepared { request = prepared }
                    else {
                        request = try await runtime.prepare(configuration: node.byteArtist, capability: capability,
                            prompt: plan.prompt, images: plan.providerImages,
                            firstFrame: plan.edgeInputs.firstFramePath, lastFrame: plan.edgeInputs.lastFramePath)
                    }
                    guard canvas.shouldTrackGeneration(ticket.token) else { return }
                    canvas.updateGeneration(ticket.token) { $0.generationDiagnostic = .init(stage: "submitting") }
                    let submitted = try await runtime.submit(request, recording: context)
                    handle = submitted.task
                } else { throw GenerationAdapterError.invalidConfiguration("缺少 BA 生成请求。") }
                // Save accepted ownership even if stop/project-switch happened during submit.
                canvas.updateGeneration(ticket.token) {
                    $0.taskId = handle.taskID
                    $0.generationTask = handle
                }
                canvas.flushSave()
                guard canvas.shouldTrackGeneration(ticket.token) else { return }
                let result = try await runtime.wait(handle,
                    timeout: node.kind == .video ? CrateGeneration.videoPollTimeout : CrateGeneration.pollTimeout) { observation in
                    await MainActor.run {
                        guard canvas.shouldTrackGeneration(ticket.token) else { return }
                        canvas.updateGeneration(ticket.token) {
                            $0.generationDiagnostic = observation.diagnostic
                            switch observation.status {
                            case .queued(let ahead): $0.state = .queued(ahead: ahead ?? 0)
                            case .running, .unknown: if case .running = $0.state {} else { $0.state = .running(startedAt: Date()) }
                            default: break
                            }
                        }
                        try? GenerationRunStore.shared.updateTask(project: ticket.projectId, taskID: handle.taskID,
                            outcome: observation.diagnostic?.stage ?? "querying", provider: handle.context,
                            diagnostic: observation.diagnostic)
                    }
                }
                guard canvas.shouldTrackGeneration(ticket.token) else { return }
                canvas.updateGeneration(ticket.token) {
                    $0.generationRawOutput = result.rawOutput
                    $0.generationDiagnostic = result.diagnostic
                }
                canvas.flushSave()
                switch result.status {
                case .succeeded: break
                case .outputMismatch:
                    canvas.updateGeneration(ticket.token) { $0.state = .idle }
                    store.transientUI.showToast(result.detail ?? "BA 已完成，请确认产物。", duration: 5)
                    canvas.flushSave()
                    return
                case .failed:
                    throw GenerationAdapterError.invalidResponseForCanvas("BA 工作流执行失败，可在工作流面板查看任务 ID。")
                default:
                    throw GenerationAdapterError.invalidResponseForCanvas("BA 任务状态暂无法识别；已保留任务 ID，可继续查询。")
                }
                var urls = Set<URL>()
                let artifacts = result.artifacts.filter { $0.kind == handle.kind && $0.remoteURL.map { urls.insert($0).inserted } == true }
                guard !artifacts.isEmpty, artifacts.count <= 100 else { throw GenerationAdapterError.invalidResponse }
                var downloads: [URL] = []
                defer { for file in downloads { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
                let fileID = "ba-" + CanvasWorkflowSnapshot.digest(Data("\(handle.context)|\(handle.taskID)".utf8))
                for (index, artifact) in artifacts.enumerated() {
                    guard canvas.shouldTrackGeneration(ticket.token) else { return }
                    let file = try await CrateGenerationService.shared.download(urlString: artifact.remoteURL!.absoluteString,
                        taskId: fileID, index: index, fallbackExtension: handle.kind == .video ? "mp4" : "png")
                    downloads.append(file)
                    if handle.kind == .image {
                        guard let image = CGImageSourceCreateWithURL(file as CFURL, nil),
                              CGImageSourceGetCount(image) > 0 else {
                            throw GenerationAdapterError.invalidResponseForCanvas("所选字段没有返回可读取的图片，请重新选择产物字段。")
                        }
                    } else {
                        let tracks = try await AVURLAsset(url: file).loadTracks(withMediaType: .video)
                        guard !tracks.isEmpty else {
                            throw GenerationAdapterError.invalidResponseForCanvas("所选字段没有返回可读取的视频，请重新选择产物字段。")
                        }
                    }
                }
                for (index, file) in downloads.enumerated() {
                    guard canvas.shouldTrackGeneration(ticket.token) else { return }
                    canvas.updateGeneration(ticket.token) { $0.generationDiagnostic?.stage = "saving" }
                    try await finishGeneration(token: ticket.token, file: file, taskId: handle.taskID,
                                               projectID: ticket.projectId, provider: handle.context,
                                               marksCompleted: index == downloads.count - 1)
                }
                canvas.updateGeneration(ticket.token) { $0.generationDiagnostic?.stage = "succeeded" }
                try? GenerationRunStore.shared.updateTask(project: ticket.projectId, taskID: handle.taskID,
                    outcome: "succeeded", provider: handle.context, diagnostic: canvas.generationNode(ticket.token)?.generationDiagnostic)
                canvas.flushSave()
            } catch {
                guard canvas.shouldTrackGeneration(ticket.token) else { return }
                let reason = (error as? CrateGenerationService.ServiceError)?.userMessage ?? error.localizedDescription
                let previous = canvas.generationNode(ticket.token)?.generationDiagnostic?.stage
                let paused = canvas.generationNode(ticket.token)?.generationTask != nil
                    && !["failed", "downloading", "saving"].contains(previous ?? "")
                canvas.updateGeneration(ticket.token) {
                    $0.state = paused ? .idle : .failed(reason: reason)
                    var diagnostic = $0.generationDiagnostic ?? .init(stage: "failed")
                    diagnostic.stage = paused ? "query-paused" : "failed"; diagnostic.message = reason
                    $0.generationDiagnostic = diagnostic
                }
                if let handle = canvas.generationNode(ticket.token)?.generationTask {
                    try? GenerationRunStore.shared.updateTask(project: ticket.projectId, taskID: handle.taskID,
                        outcome: paused ? "query-paused" : "failed", provider: handle.context,
                        diagnostic: canvas.generationNode(ticket.token)?.generationDiagnostic)
                }
                canvas.flushSave()
                store.transientUI.showToast(reason, duration: 5)
            }
        }
        canvas.trackGeneration(task, token: ticket.token)
        return task
    }
}

private extension GenerationAdapterError {
    static func invalidResponseForCanvas(_ message: String) -> Self { .invalidInput(message) }
}
