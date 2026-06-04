import SwiftUI

// MARK: - Slot Port Handle (single port circle)

struct SlotPortHandle: View {
    let slot: Int
    let port: SlotPort
    let color: Color
    let isVisible: Bool
    let isConnected: Bool
    let isHighlighted: Bool
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: () -> Void
    let onBeginDrag: (CGPoint) -> Void

    @State private var isHoveringPort = false

    var body: some View {
        let size: CGFloat = (isHighlighted || isHoveringPort) ? 16 : 12

        Circle()
            .fill(isConnected || isHighlighted ? color : Color(NSColor.windowBackgroundColor))
            .overlay(
                Circle()
                    .stroke(color, lineWidth: 2)
            )
            .frame(width: size, height: size)
            .frame(width: 28, height: 28) // hit area
            .opacity(isVisible || isConnected ? 1 : 0)
            .scaleEffect(isVisible || isConnected ? 1 : 0.65)
            .animation(.easeOut(duration: 0.12), value: isVisible)
            .animation(.easeOut(duration: 0.12), value: isConnected)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringPort = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("slotGrid"))
                    .onChanged { value in
                        if value.translation.width == 0 && value.translation.height == 0 {
                            // first call: drag started
                        }
                        onDragChanged(value.location)
                    }
                    .onEnded { _ in
                        onDragEnded()
                    }
            )
    }
}

// MARK: - Slot Port Layer (4 ports positioned at card edges)

struct SlotPortLayer: View {
    let slot: Int
    let size: CGSize
    let color: Color
    let isVisible: Bool
    let connectedPorts: Set<SlotPort>
    let highlightedPort: SlotPort?
    let onBeginDrag: (SlotPort, CGPoint) -> Void
    let onUpdateDrag: (CGPoint) -> Void
    let onEndDrag: () -> Void

    var body: some View {
        ZStack {
            portHandle(.top)
                .position(x: size.width / 2, y: 0)

            portHandle(.right)
                .position(x: size.width, y: size.height / 2)

            portHandle(.bottom)
                .position(x: size.width / 2, y: size.height)

            portHandle(.left)
                .position(x: 0, y: size.height / 2)
        }
        .allowsHitTesting(isVisible || !connectedPorts.isEmpty)
    }

    @ViewBuilder
    private func portHandle(_ port: SlotPort) -> some View {
        SlotPortHandle(
            slot: slot,
            port: port,
            color: color,
            isVisible: isVisible,
            isConnected: connectedPorts.contains(port),
            isHighlighted: highlightedPort == port,
            onDragChanged: { point in
                onUpdateDrag(point)
            },
            onDragEnded: {
                onEndDrag()
            },
            onBeginDrag: { point in
                onBeginDrag(port, point)
            }
        )
    }
}
