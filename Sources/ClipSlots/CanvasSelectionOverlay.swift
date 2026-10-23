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
        return CGPoint(x: bounds.maxX, y: bounds.midY)
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
        if let junction = selectionLinkPoint, draggingNodeId == nil, pileDragID == nil, linkDrag == nil {
            ForEach(selectedCanvasNodes) { node in
                let rect = canvas.pile(containing: node.id).map(pileScreenFrame) ?? screenFrame(of: node)
                let start = CGPoint(x: rect.maxX, y: rect.midY)
                let dx = junction.x - start.x
                let controls = (CGPoint(x: start.x + dx * 0.5, y: start.y),
                                CGPoint(x: junction.x - dx * 0.5, y: junction.y))
                CanvasEdgeCurve(start: start, c1: controls.0, c2: controls.1, end: junction)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1.4)
                    .allowsHitTesting(false)
            }
            Text("+").font(.system(size: 20, weight: .light)).foregroundColor(Color(white: 0.32))
                .frame(width: 20, height: 20).background(Circle().fill(.white))
                .position(junction).allowsHitTesting(false)
        }
    }

    @ViewBuilder var selectionActionsOverlay: some View {
        if let bounds = selectionScreenBounds, let junction = selectionJunction,
           draggingNodeId == nil, pileDragID == nil, linkDrag == nil, addMenu == nil {
            Button { spawnSelectionDownstream() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(TapSkin.portStroke))
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
        openAddMenu(atScreen: junction, parentNodeId: nil,
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
