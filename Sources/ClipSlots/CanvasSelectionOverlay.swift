import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    var selectedCanvasNodes: [CanvasNode] {
        let ids = canvas.expandedNodeIDs(canvas.selectedNodeIds)
        return canvas.nodes.filter { ids.contains($0.id) }
    }

    var selectionScreenBounds: CGRect? {
        guard canvas.selectedGroupID == nil, canvas.selectedPile == nil,
              canvas.selectedNodeIds.count > 1 else { return nil }
        let frames = canvas.nodes.filter {
            canvas.selectedNodeIds.contains($0.id) && !canvas.piledMemberIDs.contains($0.id)
        }.map(screenFrame) + canvas.piles.filter { canvas.selectedNodeIds.contains($0.id) }.map(pileScreenFrame)
        guard !frames.isEmpty else { return nil }
        return CanvasGeometry.bounds(of: frames).insetBy(dx: -12, dy: -26)
    }

    var selectionJunction: CGPoint? {
        guard let bounds = selectionScreenBounds else { return nil }
        if let point = selectionLinkPoint { return point }
        let viewport = canvasContentViewport
        let x = min(bounds.maxX + 92, viewport.maxX - 24)
        let y = bounds.maxX + 110 <= viewport.maxX ? bounds.midY : bounds.minY - 46
        return CGPoint(x: max(viewport.minX + 24, x),
                       y: min(max(viewport.minY + 28, y), viewport.maxY - 28))
    }

    @ViewBuilder var selectionBoundsOverlay: some View {
        if let rect = selectionScreenBounds {
            RoundedRectangle(cornerRadius: 10)
                .fill(TapSkin.accent.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(TapSkin.accent.opacity(0.3), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
        if let junction = selectionJunction, draggingNodeId == nil, pileDragID == nil, linkDrag == nil {
            ForEach(selectedCanvasNodes) { node in
                let rect = canvas.pile(containing: node.id).map(pileScreenFrame) ?? screenFrame(of: node)
                let start = CGPoint(x: rect.maxX, y: rect.midY)
                let controls = CanvasEdgeGeometry.controlPoints(start: start, end: junction,
                                                                outSide: .right, inSide: .left)
                CanvasEdgeCurve(start: start, c1: controls.0, c2: controls.1, end: junction)
                    .stroke(TapSkin.edgeInkActive.opacity(0.65), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder var selectionActionsOverlay: some View {
        if let bounds = selectionScreenBounds, let junction = selectionJunction,
           draggingNodeId == nil, pileDragID == nil, linkDrag == nil {
            Button { spawnSelectionDownstream() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(TapSkin.onAccent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(TapSkin.accent))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .position(junction)
            .help("引用所有选中的节点生成")
            .zIndex(22)
            if addMenu == nil, selectionLinkPoint == nil {
                selectionToolbar(at: CGPoint(x: bounds.midX,
                    y: bounds.minY - (selectionIsWholeGroup ? 78 : 34) - (actionToolbarHeight - 42) / 2))
            }
        }
    }

    func spawnSelectionDownstream(at point: CGPoint? = nil) {
        guard let junction = point ?? selectionJunction else { return }
        let center = CanvasGeometry.canvasPoint(
            screen: CGPoint(x: junction.x + 180 * zoom, y: junction.y),
            pan: effectivePan, zoom: zoom)
        openAddMenu(atScreen: CGPoint(x: junction.x - 12, y: junction.y + 20),
                    canvasPoint: center, parentNodeId: nil,
                    parentNodeIds: selectedCanvasNodes.map(\.id))
    }

    /// 媒体走文件剪贴板，文本按画布顺序复制完整正文。
    func copySelectionContents() {
        let nodes = canvas.selectedPile.map { CanvasPileGeometry.members($0, nodes: canvas.nodes) }
            ?? selectedCanvasNodes.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        let text = nodes.map { liveText(for: $0) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let urls = nodes.compactMap { previewableMedia(of: $0)?.canvasLocalURL as NSURL? }
        let board = NSPasteboard.general
        guard !text.isEmpty || !urls.isEmpty else {
            store.transientUI.showToast("选中的节点还没有内容")
            return
        }
        board.clearContents()
        if !urls.isEmpty { board.writeObjects(urls) }
        if !text.isEmpty { board.setString(text, forType: .string) }
        store.transientUI.showToast("已复制 \(nodes.count) 个节点的内容")
    }
}
