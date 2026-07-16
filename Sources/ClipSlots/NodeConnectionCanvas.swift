import SwiftUI
import ClipSlotsKit

struct NodeConnectionCanvas: View {
    let map: SlotConnectionMap
    let nodeFrames: [Int: CGRect]
    let activeDrag: NodeCanvasDrag?
    let hoveredTarget: SlotPortTarget?
    // v2.9.20: 被 hover 的连线（用于 hover 删除入口）整条变红加粗，给出明确的"将删除此线"反馈。
    var hoveredEdgeId: UUID? = nil

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
        let isHovered = hoveredEdgeId == edge.id
        let color = isHovered ? Color.red : SlotConnectionColor.color(for: edge.colorId)
        let lineWidth: CGFloat = isHovered ? 3.4 : 2.4
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        // 起点保留小圆点，终点用方向箭头（output → input）表达数据流向。
        context.fill(Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)), with: .color(color))
        drawArrow(at: end, towards: edge.toPort, color: color, in: &context)
    }

    private func draw(_ drag: NodeCanvasDrag, in context: inout GraphicsContext) {
        guard let fromRect = nodeFrames[drag.fromSlot] else { return }
        let start = nodeAnchorPoint(for: drag.fromPort, in: fromRect)
        let end: CGPoint
        let endPort: SlotPort
        let snapped: Bool
        if let target = drag.hoverTarget, let targetRect = nodeFrames[target.slot] {
            end = nodeAnchorPoint(for: target.port, in: targetRect)
            endPort = target.port
            snapped = true
        } else {
            end = drag.currentPoint
            endPort = drag.fromPort.opposite
            snapped = false
        }
        // v2.7.3: avoid drawing a long line from the canvas edge when frames are not ready.
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { return }
        let path = nodeConnectionPath(start: start, startPort: drag.fromPort, end: end, endPort: endPort)
        // v2.9.20: 吸附命中时预览线加粗为实线并画出方向箭头，明确"这一放会连到哪"；
        // 未吸附时用较细的虚线表示仍在自由拖拽。
        if snapped {
            context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 3.0, lineCap: .round, lineJoin: .round))
            drawArrow(at: end, towards: endPort, color: .accentColor, in: &context)
        } else {
            context.stroke(path, with: .color(.accentColor.opacity(0.85)), style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round, dash: [6, 5]))
        }
    }

    // 在 tip 处绘制一个指向节点内部的小三角箭头。port 是终点端口，其 direction 指向节点外侧，
    // 连线自节点外侧进入，故箭头方向取 -direction（指向节点）。
    private func drawArrow(at tip: CGPoint, towards port: SlotPort, color: Color, in context: inout GraphicsContext) {
        let dir = port.direction
        let ux = -dir.dx, uy = -dir.dy   // 指向节点内部
        let len: CGFloat = 9
        let halfWidth: CGFloat = 5
        let px = -uy, py = ux            // 垂直方向
        let base = CGPoint(x: tip.x - ux * len, y: tip.y - uy * len)
        let p1 = CGPoint(x: base.x + px * halfWidth, y: base.y + py * halfWidth)
        let p2 = CGPoint(x: base.x - px * halfWidth, y: base.y - py * halfWidth)
        var tri = Path()
        tri.move(to: tip)
        tri.addLine(to: p1)
        tri.addLine(to: p2)
        tri.closeSubpath()
        context.fill(tri, with: .color(color))
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
