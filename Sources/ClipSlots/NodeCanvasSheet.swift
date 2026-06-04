import SwiftUI

struct NodeCanvasSheet: View {
    @ObservedObject var store: SlotStoreObservable
    @Environment(\.dismiss) private var dismiss
    @State private var activeDrag: NodeCanvasDrag?
    @State private var hoveredNode: Int?
    @State private var hoveredTarget: SlotPortTarget?
    @State private var dragStarted = false

    private let canvasWidth: CGFloat = 920
    private let canvasHeight: CGFloat = 520
    private let nodeSize = CGSize(width: 150, height: 96)

    // v2.7.4: deterministic rects from fixed layout. No PreferenceKey needed.
    private var nodeFrames: [Int: CGRect] {
        Dictionary(uniqueKeysWithValues: (1...10).map { slot in
            let center = position(for: slot)
            let rect = CGRect(
                x: center.x - nodeSize.width / 2,
                y: center.y - nodeSize.height / 2,
                width: nodeSize.width,
                height: nodeSize.height
            )
            return (slot, rect)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(NSColor.windowBackgroundColor))
                    NodeConnectionCanvas(
                        map: store.currentConnectionMap,
                        nodeFrames: nodeFrames,
                        activeDrag: activeDrag,
                        hoveredTarget: hoveredTarget
                    )
                    .allowsHitTesting(false)
                    ForEach(1...10, id: \.self) { slot in
                        SlotNodeView(
                            slot: slot,
                            content: store.slotContent(for: slot),
                            colorId: store.currentConnectionMap.colorId(for: slot),
                            // v2.7.4: during a drag all node ports should be visible.
                            isHovered: hoveredNode == slot || activeDrag != nil,
                            connectedPorts: store.currentConnectionMap.connectedPorts(for: slot),
                            highlightedPort: hoveredTarget?.slot == slot ? hoveredTarget?.port : nil,
                            onBeginDrag: { port, point in beginDrag(slot: slot, port: port, point: point) },
                            onUpdateDrag: { point in updateDrag(point: point, fromSlot: slot) },
                            onEndDrag: { endDrag() }
                        )
                        .frame(width: nodeSize.width, height: nodeSize.height)
                        .position(position(for: slot))
                        .onHover { inside in hoveredNode = inside ? slot : (hoveredNode == slot ? nil : hoveredNode) }
                    }
                }
                .frame(width: canvasWidth, height: canvasHeight)
                .coordinateSpace(name: "nodeCanvas")
                .padding(18)
            }
            footer
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("节点画布")
                    .font(.system(size: 18, weight: .semibold))
                Text("独立画布内编辑连接；主界面继续保持干净，只显示色点提醒。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("十槽位全串联") { store.applyBuiltInFullChainTemplate() }
            Button("导出模板") { store.exportConnectionTemplate() }
            Button("导入模板") { store.importConnectionTemplate() }
            Button("清除连接", role: .destructive) { store.confirmAndClearCurrentConnections() }
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            let chains = store.connectionChainSummaries()
            if chains.isEmpty {
                Text("暂无连接。拖拽节点边缘端口建立连接。")
                    .foregroundColor(.secondary)
            } else {
                Text("当前链路：" + chains.map { compactChainDescription($0) }.joined(separator: "    "))
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func position(for slot: Int) -> CGPoint {
        let col = CGFloat((slot - 1) % 5)
        let row = CGFloat((slot - 1) / 5)
        return CGPoint(x: 115 + col * 175, y: 130 + row * 190)
    }

    private func beginDrag(slot: Int, port: SlotPort, point: CGPoint) {
        guard activeDrag == nil else { return }
        dragStarted = true
        activeDrag = NodeCanvasDrag(fromSlot: slot, fromPort: port, currentPoint: point)
    }

    private func updateDrag(point: CGPoint, fromSlot: Int) {
        guard var drag = activeDrag else { return }
        drag.currentPoint = point
        let target = nearestNodePortTarget(to: point, nodeFrames: nodeFrames, excluding: drag.fromSlot)
        hoveredTarget = target
        drag.hoverTarget = target
        activeDrag = drag
    }

    private func endDrag() {
        defer { activeDrag = nil; hoveredTarget = nil; dragStarted = false }
        guard let drag = activeDrag, let target = drag.hoverTarget else { return }
        store.connectSlots(fromSlot: drag.fromSlot, fromPort: drag.fromPort, toSlot: target.slot, toPort: target.port)
    }
}

// MARK: - Node Canvas Drag

struct NodeCanvasDrag: Equatable {
    let fromSlot: Int
    let fromPort: SlotPort
    var currentPoint: CGPoint
    var hoverTarget: SlotPortTarget?
}

// MARK: - Node Canvas Helpers

func nearestNodePortTarget(to point: CGPoint, nodeFrames: [Int: CGRect], excluding fromSlot: Int, threshold: CGFloat = 32) -> SlotPortTarget? {
    var best: (SlotPortTarget, CGFloat)?
    for (slot, rect) in nodeFrames where slot != fromSlot {
        for port in SlotPort.allCases {
            let anchor = nodeAnchorPoint(for: port, in: rect)
            let distance = hypot(anchor.x - point.x, anchor.y - point.y)
            if distance <= threshold {
                if let current = best {
                    if distance < current.1 { best = (SlotPortTarget(slot: slot, port: port), distance) }
                } else {
                    best = (SlotPortTarget(slot: slot, port: port), distance)
                }
            }
        }
    }
    return best?.0
}

func nodeAnchorPoint(for port: SlotPort, in rect: CGRect) -> CGPoint {
    switch port {
    case .top: return CGPoint(x: rect.midX, y: rect.minY)
    case .right: return CGPoint(x: rect.maxX, y: rect.midY)
    case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
    case .left: return CGPoint(x: rect.minX, y: rect.midY)
    }
}
