import SwiftUI

// v2.7.5: Unified port overlay at canvas level.
// Previously each SlotNodeView had its own portLayer, causing the last-
// rendered node (slot 10) to swallow hover/drag events for earlier nodes.

struct NodePortOverlay: View {
    let nodeFrames: [Int: CGRect]
    let visibleSlots: Set<Int>
    let connectedPortsProvider: (Int) -> Set<SlotPort>
    let colorProvider: (Int) -> Color
    let highlightedTarget: SlotPortTarget?
    let onBeginDrag: (Int, SlotPort, CGPoint) -> Void
    let onUpdateDrag: (CGPoint) -> Void
    let onEndDrag: () -> Void

    var body: some View {
        ZStack {
            ForEach(1...10, id: \.self) { slot in
                if let rect = nodeFrames[slot] {
                    ForEach(SlotPort.allCases) { port in
                        let connectedPorts = connectedPortsProvider(slot)
                        let isVisible = visibleSlots.contains(slot) || connectedPorts.contains(port)
                        let isHighlighted = highlightedTarget?.slot == slot && highlightedTarget?.port == port
                        NodePortHandle(
                            slot: slot,
                            port: port,
                            point: nodeAnchorPoint(for: port, in: rect),
                            color: normalizedPortColor(colorProvider(slot)),
                            isVisible: isVisible,
                            isConnected: connectedPorts.contains(port),
                            isHighlighted: isHighlighted,
                            onBeginDrag: onBeginDrag,
                            onUpdateDrag: onUpdateDrag,
                            onEndDrag: onEndDrag
                        )
                    }
                }
            }
        }
    }

    private func normalizedPortColor(_ color: Color) -> Color {
        color == .clear ? .accentColor : color
    }
}

// MARK: - Node Port Handle

struct NodePortHandle: View {
    let slot: Int
    let port: SlotPort
    let point: CGPoint
    let color: Color
    let isVisible: Bool
    let isConnected: Bool
    let isHighlighted: Bool
    let onBeginDrag: (Int, SlotPort, CGPoint) -> Void
    let onUpdateDrag: (CGPoint) -> Void
    let onEndDrag: () -> Void

    var body: some View {
        Circle()
            .fill(isHighlighted || isConnected ? color : Color(NSColor.windowBackgroundColor))
            .overlay(Circle().stroke(color, lineWidth: 2))
            .frame(width: isHighlighted ? 16 : 12, height: isHighlighted ? 16 : 12)
            .frame(width: 30, height: 30)
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible ? 1 : 0.7)
            .animation(.easeOut(duration: 0.12), value: isVisible)
            .contentShape(Rectangle())
            .position(point)
            .allowsHitTesting(isVisible)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("nodeCanvas"))
                    .onChanged { value in
                        onBeginDrag(slot, port, value.startLocation)
                        onUpdateDrag(value.location)
                    }
                    .onEnded { _ in onEndDrag() }
            )
    }
}
