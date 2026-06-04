import SwiftUI

// MARK: - Slot Connection Canvas

struct SlotConnectionCanvas: View {
    let map: SlotConnectionMap
    let slotFrames: [Int: CGRect]
    let activeDrag: ActiveDragConnection?
    let isConnectionModeEnabled: Bool
    let hoveredSlot: Int?

    var body: some View {
        Canvas { context, size in
            // Draw existing edges
            for edge in map.edges {
                draw(edge, in: &context)
            }

            // Draw active drag line
            if let drag = activeDrag {
                drawActiveDrag(drag, in: &context)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Draw Edge

    private func draw(_ edge: SlotConnectionEdge, in context: inout GraphicsContext) {
        guard let fromRect = slotFrames[edge.fromSlot],
              let toRect = slotFrames[edge.toSlot] else {
            return
        }

        let start = anchorPoint(for: edge.fromPort, in: fromRect)
        let end = anchorPoint(for: edge.toPort, in: toRect)
        let path = connectionPath(start: start, startPort: edge.fromPort, end: end, endPort: edge.toPort)
        let color = SlotConnectionColor.color(for: edge.colorId)
        let lw: CGFloat = isConnectionModeEnabled ? 2.4 : 1.6
        let alpha: CGFloat = isConnectionModeEnabled ? 1.0 : 0.45

        context.stroke(
            path,
            with: .color(color.opacity(alpha)),
            style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
        )

        // Endpoint dots
        let dotRect = { (pt: CGPoint) -> CGRect in
            CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)
        }
        context.fill(Path(ellipseIn: dotRect(start)), with: .color(color.opacity(alpha)))
        context.fill(Path(ellipseIn: dotRect(end)), with: .color(color.opacity(alpha)))
    }

    // MARK: - Draw Active Drag

    private func drawActiveDrag(_ drag: ActiveDragConnection, in context: inout GraphicsContext) {
        guard let fromRect = slotFrames[drag.fromSlot] else { return }

        let start = anchorPoint(for: drag.fromPort, in: fromRect)

        let end: CGPoint
        let endPort: SlotPort

        if let target = drag.hoverTarget, let targetRect = slotFrames[target.slot] {
            end = anchorPoint(for: target.port, in: targetRect)
            endPort = target.port
        } else {
            end = drag.currentPoint
            endPort = drag.fromPort.opposite
        }

        let path = connectionPath(start: start, startPort: drag.fromPort, end: end, endPort: endPort)

        context.stroke(
            path,
            with: .color(.accentColor.opacity(0.85)),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        )
    }
}
