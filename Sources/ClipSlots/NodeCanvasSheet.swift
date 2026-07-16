import SwiftUI
import ClipSlotsKit

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
    // v2.7.68: card height grew from 96 to 128 to host the bottom attachment bar.
    private let nodeSize = CGSize(width: 150, height: 128)

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
                        // v2.9.19: onHover 必须作用在"卡片尺寸"的视图上，且要在 .position 之前。
                        // 此前 onHover 加在 .position 之后——而 .position 会让返回的视图占满整个画布
                        // （内容居中于指定点），于是 10 个节点的 hover 区域都变成"整块画布"。
                        // ZStack 中最后渲染的 10 号视图在最上层，吞掉了全画布的 hover 事件：
                        //   Bug1：1-9 号收不到任何 hover；
                        //   Bug2：鼠标在画布内移动永远不会离开 10 号的全画布跟踪区，onHover(false)
                        //         不触发，蓝框/端口一直不消失且响应迟钝。
                        // 加 contentShape(Rectangle()) 保证整张卡片区域都能稳定命中 hover。
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside {
                                hoveredNode = slot
                            } else if hoveredNode == slot {
                                // v2.9.19: 鼠标移出立即清除本节点 hover（无延迟/动画拖尾）。
                                hoveredNode = nil
                            }
                        }
                        .position(position(for: slot))
                    }

                    NodePortOverlay(
                        nodeFrames: nodeFrames,
                        // v2.9.18: 端口按需显示——只把当前 hover 的节点传入 visibleSlots，
                        // 未 hover 且无连接的端口在 overlay 内弱化，减少常显圆点噪音（连接/拖拽目标仍实心）。
                        visibleSlots: hoveredNode.map { [$0] } ?? [],
                        connectedPortsProvider: { store.currentConnectionMap.connectedPorts(for: $0) },
                        colorProvider: { slot in SlotConnectionColor.color(for: store.currentConnectionMap.colorId(for: slot)) },
                        highlightedTarget: hoveredTarget,
                        onBeginDrag: { slot, port, point in beginDrag(slot: slot, port: port, point: point) },
                        onUpdateDrag: { point in updateDrag(point: point) },
                        onEndDrag: { endDrag() }
                    )
                    .zIndex(10)

                    // v2.7.69: interactive attachment buttons live in their OWN
                    // layer at the highest zIndex (above NodePortOverlay), so no
                    // port hit area or card layer can swallow their taps. Placed
                    // over each card's reserved bottom bar, leading-aligned to keep
                    // clear of the bottom-center port.
                    ForEach(1...10, id: \.self) { slot in
                        if let rect = nodeFrames[slot] {
                            HStack(spacing: 0) {
                                NodeAttachmentButton(slot: slot, store: store)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(width: rect.width, height: SlotNodeLayout.attachmentBarHeight)
                            .position(x: rect.midX, y: rect.maxY - SlotNodeLayout.attachmentBarHeight / 2)
                        }
                    }
                    .zIndex(30)
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
        // v2.9.18: 工具栏按钮间距收敛到 AppTheme.spacingSmall。
        HStack(spacing: AppTheme.spacingSmall) {
            VStack(alignment: .leading, spacing: 2) {
                Text("节点画布")
                    // v2.9.18: 标题统一到 AppTheme.Fonts.title（18pt）。
                    .font(AppTheme.Fonts.title)
                Text("独立画布内编辑连接；主界面继续保持干净，只显示色点提醒。")
                    // v2.9.18: 说明小字统一 AppTheme.Fonts.caption。
                    .font(AppTheme.Fonts.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            // v2.9.18: 精简按钮文字（去掉"模板/十槽位"等冗余词），完整语义由 systemImage + help 承载。
            Button { store.applyBuiltInFullChainTemplate() } label: { Label("全串联", systemImage: "link") }
                .help("十槽位全串联")
            Button {
                if suppressExportConnectionsPanel {
                    store.exportConnectionTemplate(scope: .currentGroup)
                } else {
                    showingExportScopeSheet = true
                }
            } label: { Label("导出", systemImage: "square.and.arrow.up") }
                .help("导出连接模板")
            Button { store.importConnectionTemplate() } label: { Label("导入", systemImage: "square.and.arrow.down") }
                .help("导入连接模板")
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
            .tint(AppTheme.danger)
            .help("清除连接")
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

            HStack(spacing: AppTheme.spacingSmall) {
                Button { store.applyBuiltInFullChainTemplate() } label: { Label("本组全联", systemImage: "link") }
                Button { store.applyFullChainToCurrentPage() } label: { Label("本页全联", systemImage: "square.grid.2x2") }
                Spacer()
                // v2.9.18: 清除类危险按钮 tint 统一到 AppTheme.danger。
                Button(role: .destructive) { store.clearCurrentConnectionsWithoutConfirm() } label: { Label("清本组", systemImage: "trash").frame(minWidth: 72) }
                .buttonStyle(.borderedProminent).tint(AppTheme.danger)
                Button(role: .destructive) { store.clearCurrentPageConnections() } label: { Label("清本页", systemImage: "trash.slash").frame(minWidth: 72) }
                .buttonStyle(.borderedProminent).tint(AppTheme.danger)
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
                    // v2.9.18: 精简为"批量应用"，完整语义由图标 + help 承载。
                    Label("批量应用", systemImage: "wand.and.stars")
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.borderedProminent)
                .help("批量应用当前连接")
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
