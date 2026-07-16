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
                        // v2.9.20: 端口三级常显模型——静默（默认低调常驻）/ 就绪（所属节点 hover）/
                        // 高亮（拖拽吸附目标）。命中区与可见性彻底解耦，端口始终可命中、可发现，
                        // 不再依赖 hover 才浮现，从根源消除"看不清连接点"的死循环。
                        let isReady = visibleSlots.contains(slot)
                        NodePortHandle(
                            slot: slot,
                            port: port,
                            point: nodeAnchorPoint(for: port, in: rect),
                            color: normalizedPortColor(colorProvider(slot)),
                            isReady: isReady,
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
    let isReady: Bool
    let isConnected: Bool
    let isHighlighted: Bool
    let onBeginDrag: (Int, SlotPort, CGPoint) -> Void
    let onUpdateDrag: (CGPoint) -> Void
    let onEndDrag: () -> Void

    // v2.9.20: 三级视觉规格。静默 8px / 就绪 12px / 高亮 16px / 已连接 11px。
    private var dotDiameter: CGFloat {
        if isHighlighted { return 16 }
        if isReady { return 12 }
        if isConnected { return 11 }
        return 8
    }

    // 静默态低对比常驻可见（0.35）；就绪 / 高亮 / 已连接为完全不透明。
    private var restingOpacity: Double {
        (isHighlighted || isReady || isConnected) ? 1 : 0.35
    }

    private var isFilled: Bool { isHighlighted || isConnected }

    private var strokeOpacity: Double {
        if isConnected { return 1 }
        if isReady { return 0.9 }
        return 0.55
    }

    var body: some View {
        Circle()
            .fill(isFilled ? color : Color(NSColor.windowBackgroundColor).opacity(0.92))
            .overlay(Circle().stroke(color.opacity(strokeOpacity), lineWidth: isHighlighted ? 2.6 : (isReady ? 2.0 : 1.4)))
            .overlay(Circle().stroke(Color.white.opacity(isHighlighted ? 0.4 : 0), lineWidth: 1))
            .shadow(color: color.opacity(isHighlighted ? 0.55 : (isReady ? 0.28 : 0.12)), radius: isHighlighted ? 7 : (isReady ? 4 : 2), x: 0, y: 0)
            .frame(width: dotDiameter, height: dotDiameter)
            // v2.9.20: 命中区收窄到 18×18（此前 28×28），减少对卡片中心 hover 的拦截，
            // 配合几何 nearestNodePortTarget（吸附半径 44px）保证拖拽仍好连上。
            .frame(width: 18, height: 18)
            .opacity(restingOpacity)
            .scaleEffect(isHighlighted ? 1.12 : 1)
            .animation(.easeOut(duration: 0.12), value: isHighlighted)
            .animation(.easeOut(duration: 0.12), value: isReady)
            .contentShape(Circle())
            .position(point)
            // v2.9.20: 命中区与可见性彻底解耦——端口恒可命中，不再随状态切换而翻转，
            // 从根源消除鼠标在卡片边缘时端口忽隐忽现的边界抖动。
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
