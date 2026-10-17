import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    func requestPileGalleryClose() {
        guard let id = pileGalleryID else { return }
        NotificationCenter.default.post(name: .canvasPileGalleryCloseRequested, object: id)
    }

    func pileScreenFrame(_ pile: CanvasPile) -> CGRect {
        let frame = CanvasPileGeometry.frame(pile, nodes: canvas.nodes)
        let delta = draggingIds.contains(pile.id) || pileDragID == pile.id
            || (groupDragID == pile.groupID && groupDragID != nil) ? dragDelta : .zero
        return CGRect(x: (frame.minX + delta.width) * zoom + effectivePan.width,
                      y: (frame.minY + delta.height) * zoom + effectivePan.height,
                      width: frame.width * zoom, height: frame.height * zoom)
    }

    func pileBody(at point: CGPoint) -> CanvasPile? {
        let candidates = canvas.piles.filter { pileScreenFrame($0).insetBy(dx: -32 * zoom, dy: -18 * zoom).contains(point) }
        let pile = candidates.sorted {
            let a = canvas.selectedNodeIds.contains($0.id) ? 4 : 0
            let b = canvas.selectedNodeIds.contains($1.id) ? 4 : 0
            return a < b
        }.last
        guard let pile else { return nil }
        let rank: Double = pileDragID == pile.id ? 10 : draggingIds.contains(pile.id) ? 9
            : canvas.selectedNodeIds.contains(pile.id) ? 4 : 0
        if let node = nodesInPaintOrder.last(where: { screenFrame(of: $0).contains(point) }),
           nodeLayerOrder(node) > rank { return nil }
        return pile
    }

    func createSelectionPile() {
        endInlineEditing()
        let ids = canvas.selectedNodeIds
        pileEntryFrames = Dictionary(uniqueKeysWithValues: canvas.nodes.filter { ids.contains($0.id) }.map {
            ($0.id, screenFrame(of: $0))
        })
        for pile in canvas.piles where ids.contains(pile.id) {
            for member in CanvasPileGeometry.members(pile, nodes: canvas.nodes) {
                pileEntryFrames[member.id] = pileScreenFrame(pile)
            }
        }
        guard canvas.createPile(ids) != nil else {
            pileEntryFrames = [:]
            store.transientUI.showToast("请选择 2–50 个文本、图片或视频节点堆叠")
            return
        }
        hoverHoldNodeId = nil
    }

    func unstackPile(_ pile: CanvasPile) {
        let frame = pileScreenFrame(pile)
        let visible = Array(CanvasPileGeometry.members(pile, nodes: canvas.nodes).suffix(5))
        pileLandingFrames = CanvasPileGalleryMotion.pilePoses(visible, screenFrame: frame, zoom: zoom,
            expansion: hoveredPileID == pile.id ? 2 : 1).mapValues(\.frame)
        pileGalleryID = nil
        canvas.unpile(pile.id)
    }

    @ViewBuilder var pileLayer: some View {
        ForEach(canvas.piles) { pile in
            let frame = pileScreenFrame(pile)
            let visible = Array(CanvasPileGeometry.members(pile, nodes: canvas.nodes).suffix(5))
            let expanded = hoveredPileID == pile.id && pileDragID == nil
            let poses = CanvasPileGalleryMotion.pilePoses(visible, screenFrame: frame, zoom: zoom,
                                                         expansion: expanded ? 2 : 1)
            ZStack(alignment: .topLeading) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, member in
                    let pose = poses[member.id] ?? CanvasPileMemberPose(frame: frame)
                    CanvasPilePreviewMember(
                        destination: pose.frame.center,
                        origin: pileEntryFrames[member.id]?.center,
                        rotation: pose.rotation, scale: pose.frame.width / max(member.width * layoutZoom, 1),
                        shade: pose.shade, delay: Double(index) * 0.018) {
                            nodeCard(member, isEditing: false)
                    }
                    .zIndex(Double(index))
                }
                Text("\(pile.memberIDs.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(CanvasSkin.chromeInk)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(CanvasSkin.chromeFill))
                    .position(x: frame.maxX - 12, y: frame.maxY - 12)
                    .zIndex(6)
                    .accessibilityLabel("\(pile.memberIDs.count) 个堆叠成员")
            }
            .allowsHitTesting(false)
            .opacity(pileGalleryID == pile.id ? 0 : 1)
            .zIndex(pileDragID == pile.id ? 10 : draggingIds.contains(pile.id) ? 9
                : canvas.selectedNodeIds.contains(pile.id) ? 4 : 0)
        }
    }

    @ViewBuilder var pileToolbarOverlay: some View {
        if let pile = canvas.selectedPile ?? canvas.piles.first(where: { $0.id == hoveredPileID }),
           pileDragID == nil, pileGalleryID == nil, addMenu == nil {
            let frame = pileScreenFrame(pile)
            HStack(spacing: 8) {
                Button { pileGalleryID = pile.id } label: { Label("浏览成员", systemImage: "square.grid.2x2") }
                    .accessibilityIdentifier("pile-gallery")
                Button { unstackPile(pile) } label: { Label("展开堆叠", systemImage: "square.stack.3d.up.slash") }
                    .accessibilityIdentifier("pile-unstack")
                Button {
                    canvas.select(id: pile.id, additive: false)
                    copySelectionContents()
                } label: { Image(systemName: "doc.on.doc") }.help("复制成员内容")
                Button {
                    canvas.select(id: pile.id, additive: false)
                    copyCanvasStructure(duplicate: true)
                } label: { Image(systemName: "plus.square.on.square") }.help("复制整个堆叠")
                    .accessibilityIdentifier("pile-duplicate")
            }
            .font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
            .foregroundColor(CanvasSkin.chromeInk).padding(10)
            .background(CanvasSkin.chromeFill, in: Capsule())
            .overlay(Capsule().stroke(CanvasSkin.border, lineWidth: 0.7))
            .canvasControlRegion("pile-toolbar-\(pile.id)")
            .position(x: min(max(frame.midX, canvasContentViewport.minX + 150), canvasContentViewport.maxX - 150),
                      y: max(canvasContentViewport.minY + 22, frame.minY - 42))
            .zIndex(42)
        }
    }

    @ViewBuilder var pileGalleryOverlay: some View {
        if let id = pileGalleryID, let pile = canvas.piles.first(where: { $0.id == id }) {
            CanvasPileGallery(pile: pile, nodes: CanvasPileGeometry.members(pile, nodes: canvas.nodes),
                text: { liveText(for: $0) }, media: { previewableMedia(of: $0) },
                sourceFrame: pileScreenFrame(pile), canvasZoom: zoom,
                sourceExpansion: hoveredPileID == pile.id && pileDragID == nil ? 2 : 1,
                close: { expansion in
                    hoveredPileID = expansion > 1 ? id : nil
                    pileGalleryID = nil
                },
                unstack: { unstackPile(pile) },
                promote: { canvas.movePileMemberToTop(id, memberID: $0) },
                extract: { memberID, screenPoint in
                    guard let member = canvas.node(id: memberID) else { return }
                    let point = CanvasGeometry.canvasPoint(screen: screenPoint, pan: effectivePan, zoom: zoom)
                    canvas.extractPileMember(id, memberID: memberID,
                        at: CGPoint(x: point.x - member.width / 2, y: point.y - member.height / 2))
                    hoveredPileID = nil
                    pileGalleryID = nil
                }, preview: { node in
                    if let attachment = previewableMedia(of: node) {
                        openFullscreen(node, attachment: attachment)
                        canvas.select(id: id, additive: false)
                    }
                })
                .id(id)
        }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private struct CanvasPilePreviewMember<Content: View>: View {
    let destination: CGPoint
    let origin: CGPoint?
    let rotation: Double
    let scale: CGFloat
    let shade: Double
    let delay: Double
    @ViewBuilder let content: () -> Content
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { CanvasPileMotionAccessibility.shouldReduceMotion(systemReduceMotion) }
    var body: some View {
        content()
            .overlay(Color.black.opacity(shade))
            .clipShape(RoundedRectangle(cornerRadius: CanvasSkin.cardRadius * CanvasZoomLayout.layoutBaseScale))
            .scaleEffect(scale)
            .rotationEffect(.degrees(arrived || origin == nil ? rotation : 0))
            .position(arrived || origin == nil ? destination : origin ?? destination)
            .animation(reduceMotion ? nil : .timingCurve(0.65, 0, 0.35, 1,
                duration: CanvasPileGeometry.reflowDuration), value: destination)
            .animation(reduceMotion ? nil : .timingCurve(0.65, 0, 0.35, 1,
                duration: CanvasPileGeometry.reflowDuration), value: rotation)
            .onAppear {
                withAnimation(reduceMotion ? nil : .timingCurve(0.65, 0, 0.35, 1,
                    duration: CanvasPileGeometry.entryDuration).delay(delay)) { arrived = true }
            }
    }
}

struct CanvasPileLanding: ViewModifier {
    let start: CGRect?
    let target: CGRect
    let zoom: CGFloat
    @State private var progress: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { CanvasPileMotionAccessibility.shouldReduceMotion(systemReduceMotion) }
    func body(content: Content) -> some View {
        let scale = start.map { $0.width / max(target.width, 1) } ?? 1
        return content
            .scaleEffect(1 + (scale - 1) * (1 - progress), anchor: .topLeading)
            .offset(x: ((start?.minX ?? target.minX) - target.minX) * (1 - progress),
                    y: ((start?.minY ?? target.minY) - target.minY) * (1 - progress))
            .onAppear { animate() }
            .onChange(of: start) { _ in animate() }
    }
    private func animate() {
        guard start != nil, !reduceMotion else { progress = 1; return }
        progress = 0
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: CanvasPileGeometry.unstackDuration)) {
                progress = 1
            }
        }
    }
}
