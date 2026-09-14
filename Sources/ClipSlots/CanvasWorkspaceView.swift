import SwiftUI
import ClipSlotsKit

/// 无限画布工作区（v2.11.7 MVP · 版本 C2 极简浮动）。
///
/// 层级自下而上：网格背景 → 节点层 → 框选矩形 → 浮动 UI（左侧槽位库 / 右上生成 / 底部工具栏 /
/// 缩放控件）→ 拖影。
///
/// **视口状态刻意留在本视图的 `@State`**，不放进 `CanvasStore` 的 `@Published`。缩放平移是每帧
/// 事件，若走 `@Published`，一次捏合会让所有节点视图重新求值几十次。节点只关心自己的画布坐标，
/// 视口变换统一由外层一个 `scaleEffect` + `offset` 施加 —— 这样缩放平移的成本与节点数量无关。
/// 停手后才通过 `canvas.updateViewport` 落盘（内部防抖）。
struct CanvasWorkspaceView: View {
    @ObservedObject var store: SlotStoreObservable
    @ObservedObject var canvas: CanvasStore

    /// 画布根坐标空间名。槽位库的拖拽手势也用它上报落点，两边共用一个空间才能对齐坐标。
    static let spaceName = "clipslots.canvas.root"

    // MARK: 视口

    @State private var pan: CGSize = .zero
    @State private var zoom: CGFloat = 1
    /// 平移手势进行中的临时量。手势结束才合并进 `pan`，避免逐帧累加带来的漂移。
    @State private var panGestureDelta: CGSize = .zero
    /// 捏合开始时的 pan / zoom 基准。锚点缩放必须基于「手势开始那一刻」的状态反算，
    /// 否则 `MagnificationGesture` 每帧给的是相对初始的累计比例，用当前 zoom 去乘会指数放大。
    /// 滚轮 / 中键路由器。**必须是 `@StateObject`**：事件监听器的寿命要跨越视图重建
    /// （实测本项目的画布子树每秒会被重建一次，监听器若绑在 NSView 挂载周期上会反复装卸并丢事件）。
    @StateObject private var inputRouter = CanvasInputRouter()

    @State private var pinchBasePan: CGSize? = nil
    @State private var pinchBaseZoom: CGFloat = 1

    // MARK: 交互

    /// 拖拽中的节点位移（画布空间）。刻意不写进 store，松手才提交。
    @State private var draggingNodeId: String? = nil
    /// 本次拖拽会一起走的节点集合。
    ///
    /// ★ v2.11.7 hotfix18 修 bug：框选两个节点后拖其中一个，只有被按住的那个动。
    /// 根因是预览位移只加在 `draggingNodeId` 上、提交也只提交它一个。现在在 `onChanged` 的第一帧
    /// 就把「这次要一起动谁」定下来（按下时的选中集合），拖拽过程中即使选中集合被别处改动也不受影响。
    @State private var draggingIds: Set<String> = []
    @State private var dragDelta: CGSize = .zero
    /// 正在 inline 编辑正文的节点。集中管理，保证同一时刻只有一个编辑器抢焦点。
    @State private var editingNodeId: String? = nil
    /// 正在管理「入参文件」的节点 id。见 `openInputFiles(_:)` 说明为何弹层不挂在卡片里。
    @State private var inputFilesNodeId: String? = nil
    /// 历史面板是否展开。
    @State private var showHistory = false
    /// 框选矩形（屏幕空间）。
    @State private var marqueeStart: CGPoint? = nil
    @State private var marqueeCurrent: CGPoint? = nil
    /// 光标位置，供锚点缩放使用。
    @State private var cursorScreen: CGPoint = .zero
    /// 槽位库拖拽的实时拖影。
    @State private var ghost: (title: String, point: CGPoint)? = nil
    /// 最近一次已知的视图尺寸。
    ///
    /// `GeometryReader` 的 `proxy.size` 只在 `body` 里拿得到，而 Cmd+1 走的是 AppKit 事件监听
    /// 回调（`inputRouter.onKeyAction` → `handleSlotCommand`），那条路径**不在 body 里**。
    /// 没有这份镜像，热键就算不出"当前视口中央在画布的哪里"，只能把新节点扔到原点。
    @State private var viewSize: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CanvasGridBackground(pan: effectivePan, zoom: zoom)
                    .allowsHitTesting(false)

                if canvas.nodes.isEmpty {
                    CanvasEmptyHint()
                        .frame(width: max(0, proxy.size.width - sidebarWidth), height: proxy.size.height)
                        .padding(.leading, sidebarWidth)
                }

                nodeLayer

                marqueeOverlay

                floatingLayer(size: proxy.size)

                ghostOverlay

                inputFilesAnchorOverlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.windowBackground)
            // ★ v2.11.7 hotfix17: 滚轮 / 中键只能从 AppKit 拿（见 CanvasInputRouter）。
            // 这里只放一个对鼠标透明的几何锚点，事件监听的寿命由 @StateObject 持有的路由器决定。
            .background(CanvasInputAnchor(router: inputRouter))
            .contentShape(Rectangle())
            // 命名坐标空间：槽位库那边的 DragGesture 也报到这个空间，落点才能直接换算成画布坐标。
            .coordinateSpace(name: CanvasWorkspaceView.spaceName)
            .gesture(canvasDragGesture)
            .simultaneousGesture(pinchGesture)
            .onContinuousHover { phase in
                if case .active(let p) = phase { cursorScreen = p }
            }
            .onAppear {
                pan = canvas.pan
                zoom = canvas.zoom
                // 闭包在这里绑一次即可：@State/@ObservedObject 的读写都走稳定的存储盒，
                // 视图结构体后续被重建也不影响这几个闭包写到正确的地方。
                inputRouter.onScroll = { dx, dy, precise, isZoom, point in
                    handleScroll(deltaX: dx, deltaY: dy, precise: precise, isZoom: isZoom, at: point)
                }
                inputRouter.onMiddleDrag = { delta in handleMiddleDrag(delta) }
                inputRouter.onMiddleDragEnded = { canvas.updateViewport(pan: pan, zoom: zoom) }
                inputRouter.onKeyAction = { action in handleKeyAction(action) }
                inputRouter.start()

                // 撤销/重做要能把槽位主体文本一起回滚。store 层不认识 `SlotStoreObservable`
                // （那会把画布重新绑回全局重绘的老路），所以由视图层把这条写回能力注入进去。
                canvas.onRestoreSlotText = { groupId, slot, text in
                    _ = store.writeCanvasSlotText(groupId: groupId, slot: slot, text: text)
                }
                // 历史条目 / toast 里的节点名。hotfix20 起节点不再缓存 Label 与正文，
                // 名字只能当场问槽位 —— 同样由认识主 store 的视图层注入。
                canvas.slotTitleProvider = { groupId, slot in
                    if let label = store.canvasSlotLabel(groupId: groupId, slot: slot),
                       !label.isEmpty {
                        return label
                    }
                    let text = store.canvasSlotText(groupId: groupId, slot: slot) ?? ""
                    return text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
                }
                // 登记「槽位命令」处理器：画布在台上时，Cmd+1~0 与圆盘选槽都改为填进选中节点。
                CanvasCommandBridge.shared.slotCommandHandler = { slot in handleSlotCommand(slot) }

                // 没有光标事件之前，锚点先取视图中心，避免首次捏合以 (0,0) 为锚点把画面甩到角上。
                cursorScreen = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                viewSize = proxy.size
            }
            .onChange(of: proxy.size) { newSize in viewSize = newSize }
            .onDisappear {
                inputRouter.stop()
                // 必须撤销登记：留着它，切回编辑模式后 Cmd+1 会被一个已经下台的画布吃掉，
                // 表现是"热键静默失效"（既没粘贴，也没有任何提示）。
                CanvasCommandBridge.shared.slotCommandHandler = nil
                canvas.onRestoreSlotText = nil
                canvas.slotTitleProvider = nil
                canvas.flushSave()
            }
        }
    }

    private var effectivePan: CGSize {
        CGSize(width: pan.width + panGestureDelta.width, height: pan.height + panGestureDelta.height)
    }

    // MARK: - 节点层

    private var nodeLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(canvas.nodes) { node in
                let isDragging = draggingIds.contains(node.id)
                let isEditing = editingNodeId == node.id
                CanvasNodeCardView(node: node,
                                   isSelected: canvas.selectedNodeIds.contains(node.id),
                                   text: liveText(for: node),
                                   slotLabel: liveLabel(for: node),
                                   attachments: liveAttachments(for: node),
                                   isEditing: isEditing,
                                   onBeginEdit: { beginEdit(node) },
                                   onCommitEdit: { commitEdit(node, text: $0) },
                                   onCancelEdit: { editingNodeId = nil },
                                   onOpenInputFiles: { openInputFiles(node) })
                    .offset(x: node.x + (isDragging ? dragDelta.width : 0),
                            y: node.y + (isDragging ? dragDelta.height : 0))
                    // 被按住的那个压在最上层；同批一起走的排第二层，这样多选拖动时整组都浮在其他节点之上。
                    .zIndex(draggingNodeId == node.id ? 10 : (isDragging ? 9 : (isEditing ? 8 : 0)))
                    // 编辑中把手势整体屏蔽（`including: .none`）：TextEditor 里选文字是拖动，
                    // 会被 DragGesture 抢走，表现是"想选中一段文字，结果把节点拖跑了"。
                    .gesture(nodeDragGesture(node), including: isEditing ? .none : .all)
                    .onTapGesture {
                        guard !isEditing else { return }
                        canvas.select(id: node.id, additive: NSEvent.modifierFlags.contains(.shift))
                    }
                    .contextMenu { nodeContextMenu(node) }
            }
        }
        // 统一施加视口变换。锚点固定 `.topLeading` 是刻意的：`CanvasGeometry` 全部公式都建立在
        // `screen = canvas * zoom + pan` 之上，而这个式子只有在缩放锚点为原点时才成立。
        // 用 `.center` 会凭空引入一个「视图尺寸的一半」的偏移，让所有命中判定整体错位。
        .scaleEffect(zoom, anchor: .topLeading)
        .offset(x: effectivePan.width, y: effectivePan.height)
        // 禁掉隐式动画：拖拽时每帧都在改 offset，一旦被动画接管就会有明显的橡皮筋滞后。
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func nodeContextMenu(_ node: CanvasNode) -> some View {
        Button("编辑提示词") { beginEdit(node) }
        Button("管理入参文件") { openInputFiles(node) }
        Divider()
        Button("重跑") {
            // MVP：生图未接入，先给明确反馈而不是静默无响应。
            store.transientUI.showToast("生图功能开发中")
        }
        if let taskId = node.taskId {
            Button("复制 taskId") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(taskId, forType: .string)
            }
        }
        Divider()
        // 右键点在选中集合里的某个节点上时，删除的是**整个选中集合** —— 与 Delete 键一致。
        // 两条路径语义不同（一个删一个、一个删一片）是最容易被用户当成 bug 的那类不一致。
        if canvas.selectedNodeIds.contains(node.id), canvas.selectedNodeIds.count > 1 {
            Button("删除选中的 \(canvas.selectedNodeIds.count) 个节点") { canvas.removeSelected() }
        } else {
            Button("删除节点") { canvas.removeNodes(ids: [node.id]) }
        }
    }

    // MARK: - 手势

    /// 节点拖动。位移必须**除以 zoom** 换算回画布空间 —— 否则放大到 2x 时节点会跑得比鼠标快一倍。
    ///
    /// ★ v2.11.7 hotfix18：支持多选整组拖动。按下的节点若在选中集合内，整个选中集合一起走；
    /// 若不在（直接去拖一个未选中的节点），先把选择切成它自己 —— 这与 Figma 一致，也避免
    /// "拖一个没选中的节点，却把别处选中的一堆节点也带走"这种完全意料之外的破坏。
    private func nodeDragGesture(_ node: CanvasNode) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(CanvasWorkspaceView.spaceName))
            .onChanged { value in
                // 抓手/框选模式下不允许拖动节点，否则「想框选却拖歪一个节点」会成为常态。
                guard canvas.activeTool == .select else { return }
                if draggingNodeId != node.id {
                    draggingNodeId = node.id
                    if !canvas.selectedNodeIds.contains(node.id) {
                        canvas.select(id: node.id, additive: false)
                    }
                    // 一次性定下同批集合。此后不再读 selectedNodeIds：拖拽中途集合若变，
                    // 预览与提交就会对不上（预览动了 3 个、提交只写 2 个）。
                    draggingIds = canvas.selectedNodeIds.contains(node.id)
                        ? canvas.selectedNodeIds
                        : [node.id]
                }
                dragDelta = CGSize(width: value.translation.width / zoom,
                                   height: value.translation.height / zoom)
            }
            .onEnded { value in
                guard draggingNodeId == node.id else { return }
                let delta = CGSize(width: value.translation.width / zoom,
                                   height: value.translation.height / zoom)
                canvas.moveNodes(ids: draggingIds, by: delta)
                draggingNodeId = nil
                draggingIds = []
                dragDelta = .zero
            }
    }

    /// 画布空白处的左键拖拽。
    ///
    /// ★ v2.11.7 hotfix17（语义反转）：**箭头(V) 拉选区，抓手(H) 平移**。
    ///
    /// 上一版是反的（箭头也平移、框选另设一个 M 工具），理由是「平移入口只有手势一条，默认工具下
    /// 必须能挪动视图」。这条前提已经不成立了：现在平移有**中键拖动**和**滚轮**两个不依赖工具切换的
    /// 入口（见 `CanvasEventInterceptor`），左键就可以还给选区 —— 与 Figma / Sketch / Crate 网页端
    /// 一致，用户的肌肉记忆不用重学。
    private var canvasDragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasWorkspaceView.spaceName))
            .onChanged { value in
                if canvas.activeTool == .hand {
                    panGestureDelta = value.translation
                } else {
                    if marqueeStart == nil { marqueeStart = value.startLocation }
                    marqueeCurrent = value.location
                }
            }
            .onEnded { value in
                if canvas.activeTool == .hand {
                    // 位移量本身就是屏幕空间的，直接加到 pan 上，不需要除 zoom。
                    pan.width += value.translation.width
                    pan.height += value.translation.height
                    panGestureDelta = .zero
                    canvas.updateViewport(pan: pan, zoom: zoom)
                } else {
                    if let start = marqueeStart {
                        commitMarquee(from: start, to: value.location)
                    }
                    marqueeStart = nil
                    marqueeCurrent = nil
                }
            }
    }

    // MARK: - 滚轮 / 中键

    /// 滚轮：裸滚 = 翻页式平移，Cmd + 滚 = 以光标为锚点缩放。
    ///
    /// 刻意**不做**「裸滚轮缩放」：那是画布类工具里最招人烦的默认值之一 —— 用户以为自己在向下看内容，
    /// 结果整个画面在缩放。缩放必须显式按住 Cmd。
    private func handleScroll(deltaX: CGFloat, deltaY: CGFloat, precise: Bool, isZoom: Bool, at point: CGPoint) {
        if isZoom {
            // 缩放步长（8/行）比平移小：一格 ≈ 8%，连续滚才快，单格不会跳档。
            let dz = CanvasGeometry.normalizedScrollDelta(deltaY, precise: precise, lineStep: 8)
            let target = CanvasGeometry.clampZoom(zoom * CanvasGeometry.wheelZoomFactor(scrollDeltaY: dz))
            guard target != zoom else { return }
            pan = CanvasGeometry.panForAnchoredZoom(anchorScreen: point,
                                                    pan: pan,
                                                    oldZoom: zoom,
                                                    newZoom: target)
            zoom = target
        } else {
            pan = CanvasGeometry.pannedViewport(
                pan: pan,
                scrollDeltaX: CanvasGeometry.normalizedScrollDelta(deltaX, precise: precise, lineStep: 24),
                scrollDeltaY: CanvasGeometry.normalizedScrollDelta(deltaY, precise: precise, lineStep: 24)
            )
        }
        // updateViewport 内部防抖，逐事件调用不会逐帧落盘。
        canvas.updateViewport(pan: pan, zoom: zoom)
    }

    /// 中键拖动平移。增量直接落到 `pan` 上（而不是先攒进 `panGestureDelta`）：
    /// 这条路径没有 SwiftUI 手势的 onEnded 保证，一旦中途丢事件，攒着的临时量就会永远留在视图上。
    private func handleMiddleDrag(_ delta: CGSize) {
        pan.width += delta.width
        pan.height += delta.height
    }

    /// 框选提交。命中判定换算到**画布空间**再做，这样同一个框在任何缩放下选中的节点集合都一致。
    private func commitMarquee(from start: CGPoint, to end: CGPoint) {
        let topLeftScreen = CGPoint(x: min(start.x, end.x), y: min(start.y, end.y))
        let bottomRightScreen = CGPoint(x: max(start.x, end.x), y: max(start.y, end.y))
        let topLeft = CanvasGeometry.canvasPoint(screen: topLeftScreen, pan: pan, zoom: zoom)
        let bottomRight = CanvasGeometry.canvasPoint(screen: bottomRightScreen, pan: pan, zoom: zoom)
        let rect = CGRect(x: topLeft.x,
                          y: topLeft.y,
                          width: bottomRight.x - topLeft.x,
                          height: bottomRight.y - topLeft.y)
        canvas.selectNodes(inCanvasRect: rect, additive: NSEvent.modifierFlags.contains(.shift))
    }

    /// 捏合缩放。锚点跟光标 —— 缩放必须让光标下的内容保持不动，否则放大到 3x 时用户想看的区域会
    /// 直接飞出屏幕。
    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if pinchBasePan == nil {
                    pinchBasePan = pan
                    pinchBaseZoom = zoom
                }
                guard let basePan = pinchBasePan else { return }
                let target = CanvasGeometry.clampZoom(pinchBaseZoom * scale)
                pan = CanvasGeometry.panForAnchoredZoom(anchorScreen: cursorScreen,
                                                        pan: basePan,
                                                        oldZoom: pinchBaseZoom,
                                                        newZoom: target)
                zoom = target
            }
            .onEnded { _ in
                pinchBasePan = nil
                canvas.updateViewport(pan: pan, zoom: zoom)
            }
    }

    // MARK: - 框选矩形

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let start = marqueeStart, let current = marqueeCurrent {
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            Rectangle()
                .fill(AppTheme.chromeAccentInk.opacity(0.08))
                .overlay(Rectangle().stroke(AppTheme.chromeAccentInk.opacity(0.5), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 拖影

    @ViewBuilder
    private var ghostOverlay: some View {
        if let ghost {
            CanvasDragGhost(title: ghost.title)
                // 用 offset 而非 position：拖影本身有自适应宽度，position 会把它的中心钉在光标上，
                // 让文字压住光标；offset 从左上角起算，观感上是「挂在光标右下」。
                .offset(x: ghost.point.x + 10, y: ghost.point.y + 10)
                .transaction { $0.animation = nil }
        }
    }

    // MARK: - 入参文件弹层

    /// 「入参文件」管理弹层的宿主。
    ///
    /// 它是一个 1×1 的透明锚点，位置按节点卡片底边中点换算到屏幕坐标 —— 见
    /// `openInputFiles(_:)` 里为什么弹层不能挂在卡片自己身上。
    ///
    /// 锚点必须 `allowsHitTesting(false)`：它压在节点层之上，若能吃事件，卡片上那一小块
    /// （恰好是底边中点，也就是入参文件胶囊附近）就会点不动。
    @ViewBuilder
    private var inputFilesAnchorOverlay: some View {
        if let id = inputFilesNodeId, let node = canvas.nodes.first(where: { $0.id == id }) {
            let anchor = inputFilesAnchor(node)
            Color.clear
                .frame(width: 1, height: 1)
                .offset(x: anchor.x, y: anchor.y)
                .allowsHitTesting(false)
                .popover(isPresented: Binding(get: { inputFilesNodeId != nil },
                                              set: { if !$0 { inputFilesNodeId = nil } }),
                         arrowEdge: .bottom) {
                    // 与编辑页槽位附件面板是**同一个组件**、同一份底层数据，只是换了称呼。
                    // 复用而不是新写一份，才能保证增删 / 拖拽排序 / 断链角标 / 悬停预览这些
                    // 已经踩过一轮坑的行为在两处完全一致。
                    AttachmentManagerPopover(slot: node.slot,
                                             store: store,
                                             groupId: node.groupId,
                                             isCanvasContext: true)
                }
        }
    }

    // MARK: - 浮动层

    /// 左侧侧栏当前占据的宽度。其余浮动控件都要按它让位，否则会被压在侧栏底下（侧栏是不透明的）。
    private var sidebarWidth: CGFloat {
        CanvasSlotLibraryPanel.width(expanded: canvas.isLibraryExpanded)
    }

    private func floatingLayer(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // 左侧：贴边槽位库侧栏（Figma 风格）。
            //
            // ★ v2.11.7 hotfix18：从「左上角的浮动卡片」改为「贴住窗口左缘、上下通高的侧栏」。
            // 所以这里**不能再有 padding** —— 一点内边距就会露出后面的网格，那道缝隙正是浮动卡片
            // 与贴边侧栏观感上的全部差别。
            CanvasSlotLibraryPanel(store: store,
                                   canvas: canvas,
                                   onDragChanged: handleSlotDragChanged,
                                   onDropSlot: handleSlotDrop)

            // 右上：生成按钮
            VStack {
                HStack {
                    Spacer()
                    CanvasGenerateButton {
                        store.transientUI.showToast("生图功能开发中")
                    }
                }
                Spacer()
            }
            .padding(.trailing, 16)
            .padding(.top, 14)

            // 右侧：属性面板（v2.11.7 hotfix19）。
            //
            // 只在**单选**时出现，见 `CanvasStore.soleSelectedNode`。用 `if let` 而不是
            // `.opacity(0)` 隐藏：面板里的 Picker 要枚举全机字体，不显示时就不该构建。
            //
            // 位置压在生成按钮下方 52pt：两者都贴右缘，重叠会让生成按钮点不到。
            if let sole = canvas.soleSelectedNode {
                VStack {
                    HStack {
                        Spacer()
                        CanvasInspectorPanel(canvas: canvas, node: sole)
                    }
                    Spacer()
                }
                .padding(.trailing, 16)
                .padding(.top, 62)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            // 底部：工具栏。在**侧栏右侧的可见区域**里居中，不是在整个窗口里居中 ——
            // 否则侧栏一展开，工具栏看起来就是偏左的。
            VStack {
                Spacer()
                CanvasFloatingToolbar(canvas: canvas,
                                      isHistoryOpen: $showHistory,
                                      onPickSlot: {
                    // hotfix20：节点就是槽位，「放入槽位」不能再凭空造一个空节点（那会是一张
                    // 不对应任何槽位的孤儿卡片）。这里改成把左侧槽位库展开，引导用户从库里拖，
                    // 并顺手提示另一条更快的路（Cmd+1~0）。
                    withAnimation(Anim.transition) { canvas.isLibraryExpanded = true }
                    store.transientUI.showToast("从左侧槽位库拖入，或按 Cmd+1~0 放入槽位")
                })
            }
            .frame(width: max(0, size.width - sidebarWidth))
            .padding(.leading, sidebarWidth)
            .padding(.bottom, 16)

            // 左下：缩放控件（紧贴侧栏右侧）
            VStack {
                Spacer()
                HStack {
                    CanvasZoomControl(zoom: zoom,
                                      onZoomOut: { applyZoomStep(0.8, size: size) },
                                      onZoomIn: { applyZoomStep(1.25, size: size) },
                                      onReset: { resetZoom(size: size) },
                                      onFit: { fitToContent(size: size) })
                    Spacer()
                }
            }
            .padding(.leading, sidebarWidth + 14)
            .padding(.bottom, 16)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    // MARK: - 动作

    /// 按钮缩放以**视图中心**为锚点（没有正在移动的光标可依据时，中心是唯一合理选择）。
    private func applyZoomStep(_ factor: CGFloat, size: CGSize) {
        let anchor = CGPoint(x: size.width / 2, y: size.height / 2)
        let target = CanvasGeometry.clampZoom(zoom * factor)
        let newPan = CanvasGeometry.panForAnchoredZoom(anchorScreen: anchor, pan: pan, oldZoom: zoom, newZoom: target)
        withAnimation(Anim.interactive) {
            pan = newPan
            zoom = target
        }
        canvas.updateViewport(pan: newPan, zoom: target)
    }

    /// 重置为 100%，同样以视图中心为锚点 —— 直接把 pan 归零会让用户丢失当前所看的位置。
    private func resetZoom(size: CGSize) {
        let anchor = CGPoint(x: size.width / 2, y: size.height / 2)
        let newPan = CanvasGeometry.panForAnchoredZoom(anchorScreen: anchor, pan: pan, oldZoom: zoom, newZoom: 1)
        withAnimation(Anim.transition) {
            pan = newPan
            zoom = 1
        }
        canvas.updateViewport(pan: newPan, zoom: 1)
    }

    private func fitToContent(size: CGSize) {
        guard !canvas.nodes.isEmpty else {
            withAnimation(Anim.transition) { pan = .zero; zoom = 1 }
            canvas.updateViewport(pan: .zero, zoom: 1)
            return
        }
        let bounds = CanvasGeometry.bounds(of: canvas.nodes.map(\.frame))
        let fit = CanvasGeometry.fitTransform(contentBounds: bounds, viewSize: size)
        withAnimation(Anim.transition) {
            pan = fit.pan
            zoom = fit.zoom
        }
        canvas.updateViewport(pan: fit.pan, zoom: fit.zoom)
    }

    private func handleSlotDragChanged(_ payload: CanvasSlotDragPayload?, at point: CGPoint) {
        if let payload {
            let title = payload.name.isEmpty ? "槽位 \(payload.slot)" : payload.name
            ghost = (title, point)
        } else {
            ghost = nil
        }
    }

    /// 槽位库拖拽落到画布：把落点换算成画布坐标后摆上去。
    private func handleSlotDrop(_ payload: CanvasSlotDragPayload, screenPoint: CGPoint) {
        ghost = nil
        let canvasPoint = CanvasGeometry.canvasPoint(screen: screenPoint, pan: pan, zoom: zoom)
        let result = canvas.placeSlot(pageId: payload.pageId,
                                     groupId: payload.groupId,
                                     slot: payload.slot,
                                     name: payload.name,
                                     at: canvasPoint)
        // 拖了半天却没多出卡片，必须说清是"已经在上面了"而不是"拖丢了"。
        if !result.isNew { store.transientUI.showToast(result.message) }
    }

    // MARK: - 槽位数据（v2.11.7 hotfix20：节点 = 槽位，画布只存摆位）

    /// 节点正文的**实时**值 = 该槽位的主体文本。
    ///
    /// hotfix20 起这里不再有"读不到就回落节点副本"的分支：节点结构里已经没有 `prompt` 字段了。
    /// 槽位被清空时如实显示为空 —— 回落旧副本等于把已删除的内容又变出来。
    private func liveText(for node: CanvasNode) -> String {
        store.canvasSlotText(groupId: node.groupId, slot: node.slot) ?? ""
    }

    /// 槽位 Label 的实时值。槽位被改名 / 删名时跟着变。
    private func liveLabel(for node: CanvasNode) -> String? {
        store.canvasSlotLabel(groupId: node.groupId, slot: node.slot)
    }

    /// 槽位的**实时**附件列表 = 画布语境下的入参文件。
    private func liveAttachments(for node: CanvasNode) -> [SlotContent.SlotAttachment] {
        store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
    }

    private func beginEdit(_ node: CanvasNode) {
        canvas.select(id: node.id, additive: false)
        editingNodeId = node.id
    }

    /// inline 提示词提交（回车 / 失焦）。
    ///
    /// 只有一条路：写进**槽位主体**，编辑页立刻看到。这一步记进画布撤销栈并带上 `slotEdit`，
    /// 这样 Cmd+Z 能把槽位文本一起退回去 —— 否则撤销后画布显示旧文本、编辑页还留着新文本，
    /// 两边当场对不上。
    private func commitEdit(_ node: CanvasNode, text: String) {
        editingNodeId = nil
        let old = liveText(for: node)
        guard old != text else { return }

        guard store.writeCanvasSlotText(groupId: node.groupId, slot: node.slot, text: text) else {
            store.transientUI.showToast("存储繁忙，未能保存")
            return
        }
        let edit = CanvasHistoryEntry.SlotTextEdit(groupId: node.groupId,
                                                  slot: node.slot,
                                                  before: old,
                                                  after: text)
        canvas.recordSlotTextEdit(nodeId: node.id, edit: edit)
        canvas.noteSlotDataChanged()
    }

    /// 打开「入参文件」管理弹层。
    ///
    /// 弹层刻意**不挂在卡片上**：它要增删改附件，得拿到 `SlotStoreObservable`，而卡片视图刻意
    /// 不认识主 store（见 `CanvasNodeCardView` 的注释）。同时它也不能挂在缩放子树里 —— 附件行
    /// 在 25% 缩放下只有几个像素高，以它为锚点的 popover 箭头会指到离谱的位置。所以统一由本视图
    /// 在**未缩放的根层**上，按节点的屏幕坐标放一个 1×1 锚点来呈现。
    private func openInputFiles(_ node: CanvasNode) {
        canvas.select(id: node.id, additive: false)
        inputFilesNodeId = node.id
    }

    /// 入参文件弹层的锚点在屏幕坐标里的位置（节点卡片底边中点）。
    private func inputFilesAnchor(_ node: CanvasNode) -> CGPoint {
        let center = CGPoint(x: node.x + node.width / 2, y: node.y + node.height)
        return CanvasGeometry.screenPoint(canvas: center, pan: effectivePan, zoom: zoom)
    }

    // MARK: - 键盘 / 槽位命令

    /// 键盘动作。返回 true = 已消费，事件不再下派给系统。
    private func handleKeyAction(_ action: CanvasKeyBinding.Action) -> Bool {
        switch action {
        case .delete:
            // 正在 inline 编辑时退格属于文本编辑（`CanvasInputRouter` 已按 firstResponder 拦掉一层，
            // 这里再兜一次：焦点抢占存在一帧空窗，那一帧误删是不可挽回的）。
            guard editingNodeId == nil else { return false }
            let removed = canvas.removeSelected()
            if removed == 0 {
                store.transientUI.showToast("请先选中要删除的节点")
            } else {
                store.transientUI.showToast(removed == 1 ? "已删除节点" : "已删除 \(removed) 个节点")
            }
            return true

        case .undo:
            guard editingNodeId == nil else { return false }
            if let entry = canvas.undo() {
                store.transientUI.showToast("已撤销：\(entry.kind.title)")
            } else {
                store.transientUI.showToast("没有可撤销的操作")
            }
            return true

        case .redo:
            guard editingNodeId == nil else { return false }
            if let entry = canvas.redo() {
                store.transientUI.showToast("已重做：\(entry.kind.title)")
            } else {
                store.transientUI.showToast("没有可重做的操作")
            }
            return true

        case .none:
            return false
        }
    }

    /// Cmd+1~0 / 圆盘选槽：把槽位摆到画布上。
    ///
    /// 返回 true 表示画布已经消费掉这次命令。**不能偷偷退回去写系统剪贴板** —— 那会在用户毫无
    /// 察觉的情况下改掉剪贴板，还可能往别的 App 里粘出东西。
    ///
    /// ## ★ v2.11.7 hotfix20：语义收敛成一件事
    ///
    /// hotfix19 这里有两条分支：有选中节点 → 把槽位内容"填进"选中节点（含改绑 / 追加）；
    /// 没选中 → 新建一个绑定该槽位的节点。节点 = 槽位之后，**"填进另一个节点"这件事不存在了**——
    /// 把槽位 3 的内容填进"槽位 5 那张卡片"，要么是改写槽位 5 的数据（用户按 Cmd+3 绝不是想改
    /// 槽位 5），要么是让一张卡片同时代表两个槽位（自相矛盾）。
    ///
    /// 所以现在只有一条语义：**Cmd+N = 把槽位 N 放到画布上**。已经在上面了就选中它并说明原因。
    private func handleSlotCommand(_ slot: Int) -> Bool {
        let groupId = store.activeHotkeySpecialSlotId
        let text = store.canvasSlotText(groupId: groupId, slot: slot) ?? ""
        let attachments = store.canvasSlotAttachments(groupId: groupId, slot: slot)
        // 判空要把入参文件算进去：一个"只放了图、没写字"的槽位是**有内容**的，旧代码只看文本，
        // 于是这类槽位按 Cmd+1 会被当成空槽拒掉（正是 hotfix19 要修的第三个 bug 的同源问题）。
        guard !text.isEmpty || !attachments.isEmpty else {
            store.transientUI.showToast("槽位 \(slot) 是空的")
            return true
        }

        let label = store.canvasSlotLabel(groupId: groupId, slot: slot)
        let name = (label?.isEmpty == false) ? label! : "槽位 \(slot)"
        let result = canvas.placeSlot(pageId: store.currentPageId,
                                     groupId: groupId,
                                     slot: slot,
                                     name: name,
                                     at: visibleCenterInCanvas())
        store.transientUI.showToast(result.message)
        // 已在画布上时只"选中"是不够的：它完全可能在视口外，用户看到的就是"按了没反应 + 一句
        // 莫名的提示"。所以把视口平移到它身上，让"已选中"这句话在屏幕上有对应物。
        if case let .alreadyPlaced(node, _) = result {
            centerViewport(on: node)
        }
        return true
    }

    /// 把视口平移到某个节点上（缩放不动 —— 用户自己定的缩放级别不该被一次快捷键改掉）。
    private func centerViewport(on node: CanvasNode) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let target = CGPoint(x: sidebarWidth + (viewSize.width - sidebarWidth) / 2,
                            y: viewSize.height / 2)
        let nodeCenter = CGPoint(x: node.x + node.width / 2, y: node.y + node.height / 2)
        withAnimation(Anim.transition) {
            pan = CGSize(width: target.x - nodeCenter.x * zoom,
                         height: target.y - nodeCenter.y * zoom)
        }
        canvas.updateViewport(pan: pan, zoom: zoom)
    }

    /// 当前**可见区域**中心对应的画布坐标。
    ///
    /// 用可见区域而不是视图中心：侧栏展开时占 240pt，视图中心可能正藏在侧栏后面，
    /// 新建的节点会落在用户看不见的地方（看起来像"按了没反应"）。
    ///
    /// `viewSize` 尚未就绪（理论上只发生在首帧之前）时退化为视图原点 —— 那时画布必然是空的，
    /// 节点落在原点附近反而是最容易被找到的位置。
    private func visibleCenterInCanvas() -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else {
            return CanvasGeometry.canvasPoint(screen: .zero, pan: pan, zoom: zoom)
        }
        let center = CGPoint(x: sidebarWidth + (viewSize.width - sidebarWidth) / 2,
                            y: viewSize.height / 2)
        return CanvasGeometry.canvasPoint(screen: center, pan: pan, zoom: zoom)
    }
}

// MARK: - 网格背景

/// 细网格。用 `Canvas`（Core Graphics 直绘）而不是成百上千个 `Divider` —— 后者在缩小时会瞬间
/// 创建几千个视图节点把主线程打满。
struct CanvasGridBackground: View {
    let pan: CGSize
    let zoom: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let step = CanvasGeometry.gridScreenStep(base: CanvasStore.gridBase, zoom: zoom)
            let xs = CanvasGeometry.gridLineOffsets(viewLength: canvasSize.width,
                                                    panComponent: pan.width, step: step)
            let ys = CanvasGeometry.gridLineOffsets(viewLength: canvasSize.height,
                                                    panComponent: pan.height, step: step)
            var path = Path()
            for x in xs {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: canvasSize.height))
            }
            for y in ys {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: canvasSize.width, y: y))
            }
            context.stroke(path, with: .color(AppTheme.subtleBorder.opacity(0.45)), lineWidth: 0.5)
        }
    }
}
