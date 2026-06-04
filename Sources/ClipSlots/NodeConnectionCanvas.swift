import SwiftUI

struct NodeConnectionCanvas: View {
    let map: SlotConnectionMap
    let nodeFrames: [Int: CGRect]
    let activeDrag: NodeCanvasDrag?
    let hoveredTarget: SlotPortTarget?

    var body: some View {
        Canvas { context, _ in
            for edge in map.edges { draw(edge, in: &context) }
            if let activeDrag { draw(activeDrag, in: &context) }
        }
    }

    private func draw(_ edge: SlotConnectionEdge, in context: inout GraphicsContext) {
        guard let fromRect = nodeFrames[edge.fromSlot], let toRect = nodeFrames[edge.toSlot] else { return }
        let start = nodeAnchorPoint(for: edge.fromPort, in: fromRect)
        let end = nodeAnchorPoint(for: edge.toPort, in: toRect)
        let path = nodeConnectionPath(start: start, startPort: edge.fromPort, end: end, endPort: edge.toPort)
        let color = SlotConnectionColor.color(for: edge.colorId)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        context.fill(Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)), with: .color(color))
        context.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)), with: .color(color))
    }

    private func draw(_ drag: NodeCanvasDrag, in context: inout GraphicsContext) {
        guard let fromRect = nodeFrames[drag.fromSlot] else { return }
        let start = nodeAnchorPoint(for: drag.fromPort, in: fromRect)
        let end: CGPoint
        let endPort: SlotPort
        if let target = drag.hoverTarget, let targetRect = nodeFrames[target.slot] {
            end = nodeAnchorPoint(for: target.port, in: targetRect)
            endPort = target.port
        } else {
            end = drag.currentPoint
            endPort = drag.fromPort.opposite
        }
        let path = nodeConnectionPath(start: start, startPort: drag.fromPort, end: end, endPort: endPort)
        context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
    }
}

func nodeConnectionPath(start: CGPoint, startPort: SlotPort, end: CGPoint, endPort: SlotPort) -> Path {
    var path = Path()
    path.move(to: start)
    let dx = abs(end.x - start.x)
    let dy = abs(end.y - start.y)
    let distance = max(60, min(180, max(dx, dy) * 0.45))
    let s = startPort.direction
    let e = endPort.direction
    let c1 = CGPoint(x: start.x + s.dx * distance, y: start.y + s.dy * distance)
    let c2 = CGPoint(x: end.x + e.dx * distance, y: end.y + e.dy * distance)
    path.addCurve(to: end, control1: c1, control2: c2)
    return path
}
