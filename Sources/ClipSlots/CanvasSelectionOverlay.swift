import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    var selectedCanvasNodes: [CanvasNode] {
        canvas.nodes.filter { canvas.selectedNodeIds.contains($0.id) }
    }

    var selectionScreenBounds: CGRect? {
        let nodes = selectedCanvasNodes
        guard nodes.count > 1, let first = nodes.first else { return nil }
        return nodes.dropFirst().reduce(screenFrame(of: first)) { $0.union(screenFrame(of: $1)) }
            .insetBy(dx: -12, dy: -26)
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
        if let junction = selectionJunction, draggingNodeId == nil, linkDrag == nil {
            ForEach(selectedCanvasNodes) { node in
                let rect = screenFrame(of: node)
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
           draggingNodeId == nil, linkDrag == nil {
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
                HStack(spacing: 10) {
                    Menu {
                        Button("水平排列") { canvas.arrangeSelection(vertically: false) }
                        Button("垂直排列") { canvas.arrangeSelection(vertically: true) }
                    } label: {
                        Image(systemName: "rectangle.3.group").frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    canvasIconButton("text.alignleft", help: "垂直排列") { canvas.arrangeSelection(vertically: true) }
                    canvasIconButton("doc.on.doc", help: "复制选中内容") { copySelectionContents() }
                    Rectangle().fill(TapSkin.chromeDivider).frame(width: 1, height: 18)
                    canvasIconButton("folder.badge.plus", help: "加入槽位库") {
                        for node in selectedCanvasNodes where canArchiveToLibrary(node) { archiveNodeToLibrary(node) }
                    }
                    canvasIconButton("arrow.up.left.and.arrow.down.right", help: "适应选区") {
                        _ = handleKeyAction(.fitSelection)
                    }
                }
                .foregroundColor(TapSkin.chromeInk)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Capsule().fill(TapSkin.chromeFill))
                .overlay(Capsule().stroke(TapSkin.border.opacity(0.7), lineWidth: 1))
                .canvasControlRegion("selection-toolbar")
                .position(x: max(canvasContentViewport.minX + 114,
                                 min(bounds.midX, canvasContentViewport.maxX - 114)),
                          y: max(canvasContentViewport.minY + 22, bounds.minY - 32))
            }
        }
    }

    func canvasIconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            // #region debug-point C:toolbar-action
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_CONTROL_PROBE"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7784/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "slot-input-controls", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "C", "msg": "[DEBUG] toolbar action", "data": ["symbol": symbol]]); URLSession.shared.dataTask(with: r).resume() }
            #endif
            // #endregion
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundColor(TapSkin.chromeInk)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
        let nodes = selectedCanvasNodes.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
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
