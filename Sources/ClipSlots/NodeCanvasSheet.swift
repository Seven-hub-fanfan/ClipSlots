import SwiftUI

struct NodeCanvasSheet: View {
    @ObservedObject var store: SlotStoreObservable
    @Environment(\.dismiss) private var dismiss
    @AppStorage("suppressClearConnectionsConfirm") private var suppressClearConnectionsConfirm = false
    @AppStorage("suppressExportConnectionsPanel") private var suppressExportConnectionsPanel = false
    @State private var activeDrag: NodeCanvasDrag?
    @State private var hoveredNode: Int?
    @State private var hoveredTarget: SlotPortTarget?
    @State private var showingExportScopeSheet = false
    @State private var showingClearConfirmSheet = false

    private let canvasWidth: CGFloat = 920
    private let canvasHeight: CGFloat = 520
    private let nodeSize = CGSize(width: 150, height: 96)

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

    private var visiblePortSlots: Set<Int> { Set(1...10) }

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
                            isHovered: hoveredNode == slot,
                            store: store
                        )
                        .frame(width: nodeSize.width, height: nodeSize.height)
                        .position(position(for: slot))
                        .onHover { inside in hoveredNode = inside ? slot : (hoveredNode == slot ? nil : hoveredNode) }
                    }

                    NodePortOverlay(
                        nodeFrames: nodeFrames,
                        // v2.7.6: In the dedicated node canvas, show all ports by default.
                        visibleSlots: Set(1...10),
                        connectedPortsProvider: { store.currentConnectionMap.connectedPorts(for: $0) },
                        colorProvider: { slot in SlotConnectionColor.color(for: store.currentConnectionMap.colorId(for: slot)) },
                        highlightedTarget: hoveredTarget,
                        onBeginDrag: { slot, port, point in beginDrag(slot: slot, port: port, point: point) },
                        onUpdateDrag: { point in updateDrag(point: point) },
                        onEndDrag: { endDrag() }
                    )
                    .zIndex(10)

                    // v2.7.67: 附件入口改为显示在每条连线的中点，管理源节点
                    // (fromSlot) 的附件。zIndex 高于连线与端口 overlay，确保点击必达。
                    ForEach(store.currentConnectionMap.edges) { edge in
                        if let point = edgeMidpoint(edge) {
                            NodeAttachmentButton(slot: edge.fromSlot, store: store)
                                .position(point)
                        }
                    }
                    .zIndex(20)
                }
                .frame(width: canvasWidth, height: canvasHeight)
                .coordinateSpace(name: "nodeCanvas")
                .padding(18)
            }
            footer
        }
        .sheet(isPresented: $showingExportScopeSheet) {
            ConnectionExportScopeSheet(
                suppressNextTime: $suppressExportConnectionsPanel,
                onCancel: { showingExportScopeSheet = false },
                onExportCurrentGroup: {
                    showingExportScopeSheet = false
                    store.exportConnectionTemplate(scope: .currentGroup)
                },
                onExportCurrentPage: {
                    showingExportScopeSheet = false
                    store.exportConnectionTemplate(scope: .currentPage)
                },
                onExportAll: {
                    showingExportScopeSheet = false
                    store.exportConnectionTemplate(scope: .all)
                }
            )
            .frame(width: 420)
        }
        .sheet(isPresented: $showingClearConfirmSheet) {
            ConnectionClearConfirmSheet(
                suppressNextTime: $suppressClearConnectionsConfirm,
                onCancel: { showingClearConfirmSheet = false },
                onClearCurrentGroup: {
                    showingClearConfirmSheet = false
                    store.clearCurrentConnectionsWithoutConfirm()
                },
                onClearCurrentPage: {
                    showingClearConfirmSheet = false
                    store.clearCurrentPageConnections()
                },
                onClearAll: {
                    showingClearConfirmSheet = false
                    store.clearAllConnections()
                }
            )
            .frame(width: 440)
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
            Button { store.applyBuiltInFullChainTemplate() } label: { Label("十槽位全串联", systemImage: "link") }
            Button {
                if suppressExportConnectionsPanel {
                    store.exportConnectionTemplate(scope: .currentGroup)
                } else {
                    showingExportScopeSheet = true
                }
            } label: { Label("导出模板", systemImage: "square.and.arrow.up") }
            Button { store.importConnectionTemplate() } label: { Label("导入模板", systemImage: "square.and.arrow.down") }
            Button(role: .destructive) {
                if suppressClearConnectionsConfirm {
                    store.clearCurrentConnectionsWithoutConfirm()
                } else {
                    showingClearConfirmSheet = true
                }
            } label: {
                Label("清除", systemImage: "trash")
                    .frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
    }

    private var footer: some View {
        VStack(spacing: 8) {
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

            HStack(spacing: 8) {
                Button { store.applyBuiltInFullChainTemplate() } label: { Label("本组全联", systemImage: "link") }
                Button { store.applyFullChainToCurrentPage() } label: { Label("本页全联", systemImage: "square.grid.2x2") }
                Spacer()
                Button(role: .destructive) { store.clearCurrentConnectionsWithoutConfirm() } label: { Label("清本组", systemImage: "trash").frame(minWidth: 72) }
                .buttonStyle(.borderedProminent).tint(.red)
                Button(role: .destructive) { store.clearCurrentPageConnections() } label: { Label("清本页", systemImage: "trash.slash").frame(minWidth: 72) }
                .buttonStyle(.borderedProminent).tint(.red)
                Menu {
                    Button {
                        store.applyCurrentConnectionMapToAllGroupsInCurrentPage()
                    } label: {
                        Label("批量应用于全部组", systemImage: "folder.badge.gearshape")
                    }
                    Button {
                        store.applyCurrentConnectionMapToAllPagesAndGroups()
                    } label: {
                        Label("批量应用于全部页", systemImage: "square.grid.3x3.topleft.filled")
                    }
                } label: {
                    Label("批量应用当前连接", systemImage: "wand.and.stars")
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .font(.caption)
            .buttonStyle(.bordered)
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

    // v2.7.67: 连线两端口锚点的中点，用于放置连线上的附件按钮。
    private func edgeMidpoint(_ edge: SlotConnectionEdge) -> CGPoint? {
        guard let fromRect = nodeFrames[edge.fromSlot], let toRect = nodeFrames[edge.toSlot] else { return nil }
        let start = nodeAnchorPoint(for: edge.fromPort, in: fromRect)
        let end = nodeAnchorPoint(for: edge.toPort, in: toRect)
        let point = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    private func beginDrag(slot: Int, port: SlotPort, point: CGPoint) {
        guard activeDrag == nil else { return }
        activeDrag = NodeCanvasDrag(fromSlot: slot, fromPort: port, currentPoint: point)
    }

    private func updateDrag(point: CGPoint) {
        guard var drag = activeDrag else { return }
        drag.currentPoint = point
        let target = nearestNodePortTarget(to: point, nodeFrames: nodeFrames, excluding: drag.fromSlot)
        hoveredTarget = target
        drag.hoverTarget = target
        activeDrag = drag
    }

    private func endDrag() {
        defer { activeDrag = nil; hoveredTarget = nil }
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
