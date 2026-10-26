import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    /// API tasks retain the evaluation cell even if the next provider selection changes.
    @discardableResult
    func startModelAPIGeneration(_ node: CanvasNode, recovering: Bool = false) -> Task<Void, Never>? {
        let models = ModelWorkspaceStore.shared
        if let old = node.modelEvaluationCellID, let cell = models.evaluationCell(old),
           cell.state.active || cell.state == .unknown {
            if !recovering && cell.state != .queued {
                store.transientUI.showToast("原 API 任务尚未完成，请继续查询或到原服务核对")
                return nil
            }
        }
        guard let ticket = canvas.beginGeneration(node, recovering: recovering, restarting: !recovering) else { return nil }
        let task = Task { @MainActor in
            defer { canvas.endGeneration(ticket.token) }
            do {
                await models.load()
                let cellID: String
                if recovering, let saved = node.modelEvaluationCellID { cellID = saved }
                else {
                    guard let profile = models.canvasProfile(for: node) else {
                        throw ModelWorkspaceError.invalid("请在模型配置中心设置同类型 API，或在节点选择一个 API 模型。")
                    }
                    guard store.flushCanvasTextDocuments() else { throw ModelWorkspaceError.unreadable }
                    // Edge resolution supplies authoritative text and reference roles.
                    let inputs = resolveEdgeInputs(for: node)
                    if let reason = inputs.blockingReason { throw ModelWorkspaceError.invalid(reason) }
                    var question = ModelQuestion()
                    question.title = node.displayName; question.kind = profile.kind
                    question.prompt = ([liveText(for: node)] + inputs.promptFragments).filter { !$0.isEmpty }.joined(separator: "\n\n")
                    question.references = Array(Set(inputImagePaths(for: node) + inputs.assetPaths)).sorted().map { ModelReference(path: $0) }
                    guard let id = await models.beginCanvas(question: question, profile: profile) else {
                        throw ModelWorkspaceError.invalid(models.message ?? "API 任务保存失败")
                    }
                    cellID = id
                    canvas.updateGeneration(ticket.token) {
                        $0.modelEvaluationCellID = id; $0.taskId = "api-" + id; $0.generationTask = nil
                    }
                    canvas.flushSave()
                }
                await models.resumeCanvas(cellID)
                while canvas.shouldTrackGeneration(ticket.token) {
                    try Task.checkCancellation()
                    guard let cell = models.evaluationCell(cellID) else { throw ModelWorkspaceError.unreadable }
                    if cell.state == .succeeded {
                        let file: URL
                        if let path = cell.localMediaPaths.first { file = URL(fileURLWithPath: path) }
                        else {
                            guard let raw = cell.mediaURLs.first, let url = URL(string: raw) else { throw ModelWorkspaceError.response }
                            let (temporary, response) = try await URLSession.shared.download(from: url)
                            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                                throw ModelWorkspaceError.response
                            }
                            let root = ClipSlotsPaths.dataRoot.appendingPathComponent("models/media")
                            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                            let ext = url.pathExtension.isEmpty ? (node.kind == .video ? "mp4" : node.kind == .audio ? "mp3" : "png") : url.pathExtension
                            file = root.appendingPathComponent("api-\(cellID).\(ext)")
                            if !FileManager.default.fileExists(atPath: file.path) { try FileManager.default.moveItem(at: temporary, to: file) }
                        }
                        try await finishGeneration(token: ticket.token, file: file, taskId: "api-" + cellID, projectID: ticket.projectId)
                        canvas.flushSave()
                        return
                    }
                    if [.failed, .cancelled, .unknown].contains(cell.state) {
                        throw ModelWorkspaceError.invalid(cell.detail.isEmpty ? cell.state.title : cell.detail)
                    }
                    if cell.state == .polling && !cell.detail.isEmpty {
                        throw ModelWorkspaceError.invalid(cell.detail)
                    }
                    try await Task.sleep(for: .milliseconds(300))
                }
            } catch {
                guard canvas.shouldTrackGeneration(ticket.token) else { return }
                canvas.updateGeneration(ticket.token) { $0.state = .failed(reason: error.localizedDescription) }
                canvas.flushSave()
                store.transientUI.showToast(error.localizedDescription, duration: 4)
            }
        }
        canvas.trackGeneration(task, token: ticket.token)
        return task
    }
}
