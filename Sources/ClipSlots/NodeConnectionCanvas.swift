import SwiftUI
import ClipSlotsKit

struct NodeConnectionCanvas: View {
    let map: SlotConnectionMap
    let nodeFrames: [Int: CGRect]
    let activeDrag: NodeCanvasDrag?
    let hoveredTarget: SlotPortTarget?
    // v2.16.3：被 hover 的连线只轻微提亮；旧版整条变红加粗太像流程图编辑器，
    // 与 TapNow 的低存在感关系线不一致。真正删除仍由中点按钮/菜单表达。
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
        let baseColor = SlotConnectionColor.color(for: edge.colorId)
        let color = isHovered ? baseColor.opacity(0.85) : baseColor.opacity(0.58)
        let lineWidth: CGFloat = isHovered ? 1.6 : 1.2
        if isHovered {
            context.stroke(path,
                           with: .color(baseColor.opacity(0.18)),
                           style: StrokeStyle(lineWidth: 5.0, lineCap: .round, lineJoin: .round))
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
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
        // v2.16.3：拖线预览与成品线保持同一套轻量语言。命中目标时提亮，
        // 悬空时用短疏虚线表达“还没落地”，避免旧版粗蓝箭头的工程图感。
        if snapped {
            context.stroke(path,
                           with: .color(.white.opacity(0.86)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)),
                         with: .color(.white.opacity(0.86)))
        } else {
            context.stroke(path,
                           with: .color(.white.opacity(0.46)),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: [3, 6]))
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
