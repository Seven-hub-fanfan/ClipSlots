import SwiftUI
import ClipSlotsKit

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
                        let isHighlighted = highlightedTarget?.slot == slot && highlightedTarget?.port == port
                        // v2.9.18: 端口按需显示——仅当该端口已有连接、所属节点被 hover，
                        // 或正作为拖拽目标高亮时才实心显示；其余情况大幅弱化（保留命中区域，不影响拖拽建连）。
                        let isVisible = connectedPorts.contains(port) || visibleSlots.contains(slot) || isHighlighted
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .fill(isHighlighted || isConnected ? color : Color(NSColor.windowBackgroundColor).opacity(0.92))
            .overlay(Circle().stroke(color.opacity(isConnected ? 1 : 0.78), lineWidth: isHighlighted ? 2.6 : 1.8))
            .overlay(Circle().stroke(Color.white.opacity(isHighlighted ? 0.35 : 0), lineWidth: 1))
            .shadow(color: color.opacity(isHighlighted ? 0.55 : 0.18), radius: isHighlighted ? 7 : 3, x: 0, y: 0)
            .frame(width: isHighlighted ? 15 : 10, height: isHighlighted ? 15 : 10)
            .frame(width: 28, height: 28)
            // v2.9.18: 未连接且未 hover 的端口大幅弱化到 0.12（此前恒为 0.92），减少 40 个圆点常显的噪音；
            // 命中区域保留不变，拖拽建连不受影响。
            .opacity(isVisible ? 1 : 0.12)
            .scaleEffect(isHighlighted ? 1.08 : 1)
            .animation(.easeOut(duration: 0.10), value: isHighlighted)
            .contentShape(Rectangle())
            .position(point)
            .allowsHitTesting(true)
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
