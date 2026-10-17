import AppKit
import ClipSlotsKit

@MainActor
enum CanvasStructureClipboard {
    static let type = NSPasteboard.PasteboardType("com.clipslots.canvas-structure")
    static var capture: CanvasStructureCapture?
    static var pasteCount = 0

    static func matchesPasteboard() -> Bool {
        guard let capture else { return false }
        return NSPasteboard.general.string(forType: type) == capture.token
    }
}

extension CanvasWorkspaceView {
    @discardableResult
    func copyCanvasStructure(duplicate: Bool = false) -> Bool {
        do {
            guard editingNodeId == nil, canvas.flushSave() else { return false }
            let roots = canvas.selectedGroupID.map { [$0] } ?? Array(canvas.selectedNodeIds)
            let capture = try CanvasStructureCapture(projectID: canvas.activeProjectId,
                document: canvas.gatewayDocument(), roots: roots, root: ClipSlotsPaths.dataRoot) { node in
                guard var content = store.canvasReadFullContent(groupId: node.groupId, slot: node.slot) else {
                    throw AgentCanvasError.unavailable
                }
                content.label = store.canvasSlotLabel(groupId: node.groupId, slot: node.slot)
                if content.hasManualThumbnail {
                    let source = store.canvasStorage(groupId: node.groupId)
                    guard let url = source.manualThumbnailURL(node.slot, in: node.groupId) else { throw AgentCanvasError.unavailable }
                    content.pendingManualThumbnailData = try Data(contentsOf: url)
                }
                return content
            }
            if duplicate {
                return pasteCanvasStructure(capture, delta: CGSize(width: 40 / max(zoom, 0.01), height: 40 / max(zoom, 0.01)))
            }
            CanvasStructureClipboard.capture = capture
            CanvasStructureClipboard.pasteCount = 0
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(capture.token, forType: CanvasStructureClipboard.type)
            store.transientUI.showToast("已复制 \(capture.graph.nodes.count) 个节点")
            return true
        } catch {
            store.transientUI.showToast(error.localizedDescription)
            return true
        }
    }

    @discardableResult
    func pasteCanvasStructure(_ capture: CanvasStructureCapture, delta: CGSize? = nil) -> Bool {
        do {
            let group = canvas.privateGroupId
            guard store.ensureCanvasPrivateGroup(id: group, name: canvas.activeProject.privateGroupName) else {
                throw AgentCanvasError.writeFailed
            }
            var occupied = canvas.privateSlotsReferencedByNodes(), slots: [Int] = []
            let target = SpecialSlotStorage.canvasPrivate.storageRoot.appendingPathComponent(group)
            for slot in 1...SpecialSlotStorage.unfiledCapacity
                where FileManager.default.fileExists(atPath: target.appendingPathComponent(String(slot)).path) {
                occupied.insert(slot)
            }
            for _ in capture.graph.nodes {
                guard let slot = store.allocateCanvasPrivateSlot(groupId: group, occupied: occupied) else {
                    throw AgentOperationError("未入库空间不足，需要 \(capture.graph.nodes.count) 个空槽；可先将已有节点归槽。")
                }
                slots.append(slot); occupied.insert(slot)
            }
            let translation: CGSize
            if let delta { translation = delta }
            else {
                let center = CGPoint(x: (viewSize.width / 2 - pan.width) / max(zoom, 0.01),
                                     y: (viewSize.height / 2 - pan.height) / max(zoom, 0.01))
                let offset = CGFloat(CanvasStructureClipboard.pasteCount) * 40 / max(zoom, 0.01)
                translation = CGSize(width: center.x - capture.bounds.minX + offset,
                                     height: center.y - capture.bounds.minY + offset)
            }
            try canvas.appendStructure(capture, slots: slots, delta: translation)
            SpecialSlotStorage.canvasPrivate.invalidateContentCaches()
            CanvasStructureClipboard.pasteCount += 1
            _ = store.reconcileCanvasPrivateContents(groupId: group,
                referencedByNodes: canvas.privateSlotsReferencedByNodes(), documentLoadFailed: canvas.documentLoadFailed)
            canvas.noteSlotDataChanged()
            store.transientUI.showToast("已复制 \(slots.count) 个节点，可一次撤销")
            return true
        } catch {
            store.transientUI.showToast(error.localizedDescription)
            return true
        }
    }
}
