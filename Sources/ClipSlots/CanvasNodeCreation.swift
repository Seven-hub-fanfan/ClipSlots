import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    /// Disk validation precedes the graph commit, on a worker. No provisional
    /// node points at an unverified slot, and a project switch cancels the commit.
    @MainActor func createNodeFromMenu(kind: CanvasNodeKind, request: AddNodeRequest) async {
        let project = canvas.activeProjectId, group = canvas.privateGroupId
        let name = canvas.activeProject.privateGroupName, page = store.currentPageId
        let referenced = Set(request.allParentIds + [request.childNodeId].compactMap { $0 })
        guard !canvas.connectionPolicy.readOnly,
              referenced.allSatisfy({ canvas.connectionPolicy.canConnect(nodeID: $0) }) else { return }
        guard await store.flushCanvasTextDocumentsAsync(), canvas.activeProjectId == project else { return }
        for _ in 0..<SpecialSlotStorage.unfiledCapacity {
            let occupied = canvas.occupiedSlots(inGroup: group)
            let dirty = Set(store.canvasTextDocuments.compactMap { key, document -> Int? in
                guard key.hasPrefix(group + "#"), document.isDirty else { return nil }
                return Int(key.dropFirst(group.count + 1))
            })
            let slot: Int? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let storage = SpecialSlotStorage.canvasPrivate
                    do {
                        _ = try storage.ensureReservedGroup(id: group, name: name)
                        let stashed = storage.stashedCanvasUndoSlots(in: group)
                        let candidate = (1...SpecialSlotStorage.unfiledCapacity).first {
                            !occupied.contains($0) && !dirty.contains($0) && !stashed.contains($0)
                                && storage.getOrUnknown($0, in: group)?.isEmpty == true
                        }
                        continuation.resume(returning: candidate)
                    } catch { continuation.resume(returning: nil) }
                }
            }
            guard canvas.activeProjectId == project, !Task.isCancelled else { return }
            guard let slot else {
                store.transientUI.showToast("存储繁忙或本项目未入库槽位已满，请稍后重试或归档节点")
                return
            }
            // Another queued click may have committed while this worker read.
            guard !canvas.occupiedSlots(inGroup: group).contains(slot) else { continue }
            guard await store.flushCanvasTextDocumentsAsync(), canvas.activeProjectId == project else { return }
            guard !canvas.occupiedSlots(inGroup: group).contains(slot) else { continue }
            guard !canvas.connectionPolicy.readOnly,
                  referenced.allSatisfy({ canvas.connectionPolicy.canConnect(nodeID: $0) }) else { return }
            let result = canvas.placeSlot(pageId: page, groupId: group, slot: slot,
                name: kind == .text ? "文本" : kind.displayName, at: request.canvasPoint, kind: kind,
                parentNodeIds: request.allParentIds.filter { canvas.node(id: $0) != nil }, avoidOverlap: true)
            if let child = request.childNodeId, canvas.node(id: child) != nil {
                _ = canvas.connect(from: result.node.id, to: child)
            }
            refreshCanvasContent()
            return
        }
        store.transientUI.showToast("新建请求繁忙，请重试")
    }
}
