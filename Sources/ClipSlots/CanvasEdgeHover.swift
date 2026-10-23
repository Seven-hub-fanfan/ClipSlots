import SwiftUI
import ClipSlotsKit

/// Screen-distance search is independent of the invisible SVG-style hit band.
final class CanvasEdgeHover: ObservableObject {
    struct Visible: Equatable {
        let edgeID: String
        var point: CGPoint
    }
    @Published private(set) var visible: Visible?
    @Published private(set) var buttonHovered = false
    private var candidateID: String?
    private var latestPoint = CGPoint.zero
    private var show: DispatchWorkItem?
    private var hide: DispatchWorkItem?

    deinit { show?.cancel(); hide?.cancel() }

    func hit(at point: CGPoint) -> String? {
        guard let visible, hypot(point.x - visible.point.x, point.y - visible.point.y) <= 16 else { return nil }
        return visible.edgeID
    }

    func update(edgeID: String?, point: CGPoint) {
        latestPoint = point
        if hit(at: point) != nil {
            buttonHovered = true
            hide?.cancel(); hide = nil
            return
        }
        buttonHovered = false
        guard let edgeID else { leave(); return }
        hide?.cancel(); hide = nil
        if visible?.edgeID == edgeID {
            visible = Visible(edgeID: edgeID, point: point)
            return
        }
        guard candidateID != edgeID else { return }
        show?.cancel()
        candidateID = edgeID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.candidateID == edgeID else { return }
            self.visible = Visible(edgeID: edgeID, point: self.latestPoint)
            self.show = nil
        }
        show = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func leave() {
        buttonHovered = false
        show?.cancel(); show = nil; candidateID = nil
        guard hide == nil, visible != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.visible = nil
            self?.hide = nil
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func cancel() {
        show?.cancel(); show = nil
        hide?.cancel(); hide = nil
        candidateID = nil; visible = nil; buttonHovered = false
    }
}

struct CanvasEdgeScissors: View {
    @ObservedObject var hover: CanvasEdgeHover
    var body: some View {
        if let visible = hover.visible {
            Image(systemName: "scissors")
                .font(.system(size: 18))
                .rotationEffect(.degrees(-45))
                .foregroundColor(hover.buttonHovered ? .white : Color(white: 0.64))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(white: hover.buttonHovered ? 0.153 : 0.094)
                    .opacity(hover.buttonHovered ? 0.9 : 0.8)))
                .overlay(Circle().stroke(Color(white: hover.buttonHovered ? 0.322 : 0.25)
                    .opacity(hover.buttonHovered ? 1 : 0.5), lineWidth: 1))
                .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.2), value: hover.buttonHovered)
                .position(visible.point)
                .allowsHitTesting(false)
                .accessibilityLabel("断开连接")
        }
    }
}

extension CanvasWorkspaceView {
    func updateEdgeHover(at point: CGPoint?) {
        guard showCanvasEdges, pointerSession == nil, linkDrag == nil, addMenu == nil,
              draggingNodeId == nil, groupDragID == nil, edgePanTask == nil,
              let point else { edgeHover.cancel(); return }
        if edgeHover.hit(at: point) != nil { edgeHover.update(edgeID: nil, point: point); return }
        guard canvasContentViewport.contains(point), !canvasOverlayContains(point),
              nodeBody(at: point) == nil, pileBody(at: point) == nil else {
            edgeHover.leave(); return
        }
        var closest: String?
        var distance: CGFloat = 10
        for edge in renderedCanvasEdges {
            guard let from = nodeScreenFrames[edge.fromNodeId], let to = nodeScreenFrames[edge.toNodeId] else { continue }
            let start = CanvasEdgeGeometry.connectionAnchor(of: from, output: true, zoom: zoom)
            let end = CanvasEdgeGeometry.connectionAnchor(of: to, output: false, zoom: zoom)
            let c = CanvasEdgeGeometry.controlPoints(start: start, end: end, outSide: .right, inSide: .left,
                                                     coordinateScale: zoom)
            let next = CanvasEdgeGeometry.distance(from: point, start: start, c1: c.0, c2: c.1, end: end)
            if next <= distance { distance = next; closest = edge.id }
        }
        edgeHover.update(edgeID: closest, point: point)
    }
}
