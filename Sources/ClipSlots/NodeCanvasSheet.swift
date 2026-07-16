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
    @State private var hoveredEdgeId: UUID?
    @State private var showingExportScopeSheet = false
    @State private var showingClearConfirmSheet = false

    private let canvasWidth: CGFloat = 920
    private let canvasHeight: CGFloat = 520
    // v2.7.68: card height grew from 96 to 128 to host the bottom attachment bar.
    private let nodeSize = CGSize(width: 150, height: 128)

    // v2.9.20: nodeFrames 从计算属性改为 @State 缓存。此前每次 body 求值都重建 10 个
    // CGRect 字典并喂给连线层 / 端口层 / 附件层，SwiftUI 每帧 diff 时视图身份不稳定，
    // 表现为端口和连线在重绘瞬间"跳一下"。节点几何仅由常量决定，只需在出现时算一次。
    @State private var nodeFrames: [Int: CGRect] = [:]

    private func computeNodeFrames() -> [Int: CGRect] {
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
                        hoveredTarget: hoveredTarget,
                        hoveredEdgeId: hoveredEdgeId
                    )
                    .allowsHitTesting(false)
                    // v2.9.20: 连线中点的 hover 删除入口。默认只有透明命中区，hover 时该连线
                    // 变红（见 NodeConnectionCanvas）并在中点显示红色 × 按钮，点击断开该连线。
                    ForEach(store.currentConnectionMap.edges) { edge in
                        if let fromRect = nodeFrames[edge.fromSlot], let toRect = nodeFrames[edge.toSlot] {
                            let start = nodeAnchorPoint(for: edge.fromPort, in: fromRect)
                            let end = nodeAnchorPoint(for: edge.toPort, in: toRect)
                            EdgeConnectionDeleteHandle(
                                isHovered: hoveredEdgeId == edge.id,
                                onHover: { inside in
                                    if inside { hoveredEdgeId = edge.id }
                                    else if hoveredEdgeId == edge.id { hoveredEdgeId = nil }
                                },
                                onDelete: {
                                    hoveredEdgeId = nil
                                    store.disconnectEdge(id: edge.id)
                                }
                            )
                            .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                        }
                    }
                    .zIndex(5)
                    ForEach(1...10, id: \.self) { slot in
                        SlotNodeView(
                            slot: slot,
                            content: store.slotContent(for: slot),
                            colorId: store.currentConnectionMap.colorId(for: slot),
                            isHovered: hoveredNode == slot,
                            store: store
                        )
                        .frame(width: nodeSize.width, height: nodeSize.height)
                        // v2.9.21: 端口圆点位于卡片四边外侧（上/下/左/右）。此前 hover 命中区仅为卡片本体，
                        // 鼠标从卡片主体移向任一边的端口时会离开 hover 区，导致端口从就绪态缩回/消失，
                        // 用户"刚要点就找不到"。这里在卡片外扩 12px（四向）hover 命中区，覆盖四边端口圆点。
                        .padding(12)
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
                        // v2.9.21: 一旦进入拖拽连线模式（activeDrag != nil），所有节点端口保持就绪态，
                        // 无论 hover 与否，直到连线完成或取消——避免拖拽途中目标端口缩回/消失。
                        visibleSlots: activeDrag != nil ? Set(1...10) : (hoveredNode.map { [$0] } ?? []),
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
                .onAppear {
                    if nodeFrames.isEmpty { nodeFrames = computeNodeFrames() }
                }
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
                // v2.9.21: 移除标题下方说明小字，界面更简洁。
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
            // v2.9.21: 移除「当前链路：1→6 …」文字行——连线关系从画布本身即可看清，无需文字重复。

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
        // v2.9.21: 节点网格在画布内水平 + 垂直居中，不再紧贴左上角。
        // 5 列 × 2 行，列间距 175 / 行间距 190。内容整体尺寸 = 中心跨度 + 单节点尺寸。
        let colSpacing: CGFloat = 175
        let rowSpacing: CGFloat = 190
        let cols: CGFloat = 5
        let rows: CGFloat = 2
        let contentWidth = (cols - 1) * colSpacing + nodeSize.width
        let contentHeight = (rows - 1) * rowSpacing + nodeSize.height
        let originX = (canvasWidth - contentWidth) / 2 + nodeSize.width / 2
        let originY = (canvasHeight - contentHeight) / 2 + nodeSize.height / 2
        return CGPoint(x: originX + col * colSpacing, y: originY + row * rowSpacing)
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

func nearestNodePortTarget(to point: CGPoint, nodeFrames: [Int: CGRect], excluding fromSlot: Int, threshold: CGFloat = 44) -> SlotPortTarget? {
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

// MARK: - Edge Delete Handle

// v2.9.20: 连线中点的删除入口。默认只提供透明命中区（供 hover 检测），
// hover 时中点浮现红色 × 按钮，点击断开该连线。
struct EdgeConnectionDeleteHandle: View {
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 26, height: 26)
                .contentShape(Circle())
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.red))
                        .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.25), radius: 2, x: 0, y: 1)
                }
                .buttonStyle(.plain)
                .help("断开此连线")
                .transition(.opacity)
            }
        }
        .frame(width: 26, height: 26)
        .contentShape(Circle())
        .onHover { onHover($0) }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
