import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    /// Called on attachment changes, document restore and entry, never on pan/zoom frames.
    func synchronizeMediaLayouts() {
        mediaLayoutTask?.cancel()
        let projectId = canvas.activeProjectId
        mediaLayoutTask = Task { @MainActor in
            for snapshot in canvas.nodes where snapshot.kind.isMediaNode {
                guard !Task.isCancelled, canvas.activeProjectId == projectId else { return }
                let attachments = renderAttachments(for: snapshot)
                guard let primary = CanvasMediaPick.primary(node: snapshot, attachments: attachments) else { continue }
                let result = await CanvasMediaProbe.load(for: primary)
                guard !Task.isCancelled, canvas.activeProjectId == projectId else { return }
                guard let node = canvas.node(id: snapshot.id), node.createdAt == snapshot.createdAt,
                      node.mediaLayoutAttachmentID != result.version,
                      let pixels = result.facts.pixelSize, pixels.width > 0, pixels.height > 0 else { continue }
                if case .running = node.state { continue }
                if case .queued = node.state { continue }
                let latestAttachments = renderAttachments(for: node)
                guard CanvasMediaPick.primary(node: node, attachments: latestAttachments)?.canvasSourceIdentity == primary.canvasSourceIdentity,
                      let size = CanvasNodeSizing.size(ratio: "\(pixels.width):\(pixels.height)",
                                                       shortSide: min(node.width, node.height)) else { continue }
                let onlyVideoReference = primary.canvasIsVideoLike && !latestAttachments.contains(where: \.canvasIsImageLike)
                    && node.outputAttachmentIds.isEmpty && node.taskId == nil
                let isBatchResult = node.generationSourceID != nil
                    || canvas.adjacentLastResultIDs[node.id]?.contains(node.id) == true
                canvas.updateNode(id: node.id) { current in
                    if current.kind == .image && onlyVideoReference {
                        current.kind = .video
                        current.model = CanvasNode.defaultModel(for: .video)
                        current.resolution = ""
                    }
                    let center = CGPoint(x: current.frame.midX, y: current.frame.midY)
                    let originalOrigin = current.frame.origin
                    // 旧版仅存附件 ID 时保留用户已经选择的比例，并升级版本标记。
                    if current.mediaLayoutAttachmentID != primary.id.uuidString {
                        current.width = size.width
                        current.height = size.height
                        current.x = isBatchResult ? originalOrigin.x : center.x - size.width / 2
                        current.y = isBatchResult ? originalOrigin.y : center.y - size.height / 2
                        if node.outputAttachmentIds.isEmpty {
                            current.ratio = CanvasMediaInfo.ratioLabel(pixels) ?? "\(Int(pixels.width)):\(Int(pixels.height))"
                        }
                    }
                    current.mediaLayoutAttachmentID = result.version
                }
                if isBatchResult { canvas.reserveSpaceForResult(id: node.id) }
            }
        }
    }
}
