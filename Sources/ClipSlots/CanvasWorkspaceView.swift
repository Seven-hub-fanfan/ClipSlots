import SwiftUI
import ClipSlotsKit

/// 无限画布工作区（v2.11.8 · 版本 C2 极简浮动）。
///
/// 层级自下而上：网格背景 → 空白点击层 → 节点层 → 框选矩形 → 下游 + 按钮 → 浮动 UI（左侧槽位库 /
/// 右上生成 / 底部工具栏 / 缩放控件）→ 拖影 → 入参弹层锚点 → ADD NODE 菜单。
///
/// **视口状态刻意留在本视图的 `@State`**，不放进 `CanvasStore` 的 `@Published`。缩放平移是每帧
/// 事件，若走 `@Published`，一次捏合会让所有节点视图重新求值几十次。停手后才通过
/// `canvas.updateViewport` 落盘（内部防抖）。
///
/// ## ★ v2.11.8：视口变换从「外层 scaleEffect」改为「逐节点算屏幕坐标 + 卡片内部按 zoom 排版」
///
/// 旧做法是整个节点层套一个 `scaleEffect(zoom)`，缩放成本与节点数量无关 —— 但它把文字也一起当
/// 位图放大了，于是用户反馈「放大后节点模糊」。`scaleEffect` 是渲染期变换：1x 排版 → 光栅化 →
/// 拉伸，200% 下看到的就是 2 倍放大的 1x 字形，糊是必然的，不是抗锯齿参数问题。
///
/// 现在：节点位置在这里直接算成屏幕坐标（`screen = canvas * zoom + pan`，与 `CanvasGeometry`
/// 同一个公式），缩放通过 `renderScale` 传进卡片，由卡片把字号/内边距/线宽全部乘一遍重新排版。
/// 代价是缩放时每张卡片重新布局而非只改一个变换矩阵 —— 这笔账必须付：清晰度是画布的基本可用性。
struct CanvasWorkspaceView: View {
    typealias TapSkin = CanvasSkin
    typealias AppTheme = CanvasTheme
    @ObservedObject var store: SlotStoreObservable
    @ObservedObject var canvas: CanvasStore
    @ObservedObject var modelCatalog = CrateModelCatalogStore.shared
    var entryPrepared = false
    var isWorkspaceTransitioning: () -> Bool = { false }
    let textSurfacePool: CanvasTextSurfacePool
    let sectionMounts: CanvasNodeMountQueue?
    init(store: SlotStoreObservable, canvas: CanvasStore, agentVisible: Binding<Bool>,
         snapshots: CanvasContentSnapshots? = nil, entryPrepared: Bool = false,
         isWorkspaceTransitioning: @escaping () -> Bool = { false },
         textSurfacePool: CanvasTextSurfacePool = CanvasTextSurfacePool(),
         sectionMounts: CanvasNodeMountQueue? = nil) {
        self.store = store
        self.canvas = canvas
        self._agentVisible = agentVisible
        self.entryPrepared = entryPrepared
        self.isWorkspaceTransitioning = isWorkspaceTransitioning
        self.textSurfacePool = textSurfacePool
        self.sectionMounts = sectionMounts
        self._pan = State(initialValue: canvas.pan)
        self._zoom = State(initialValue: canvas.zoom)
        self._contentSnapshots = StateObject(wrappedValue: snapshots ?? CanvasContentSnapshots())
    }
    @State var mediaLayoutTask: Task<Void, Never>?
    @StateObject private var presenceMirror = CanvasPresenceMirror()
    @State private var retiringNodes: [CanvasRetiringNode] = []
    @State var nodeMountQueue = CanvasNodeMountQueue()
    @State var groupMounts = CanvasGroupMountAdmission()
    /// 画布页 Agent 侧栏的显隐。侧栏本体由 ContentView 的内容区并排渲染，
    /// 这里只持有开关：让"入口按钮"能待在画布右上（生成按钮旁），而布局让位交给外层 HStack。
    @Binding var agentVisible: Bool
    @State private var externalAgentContext: AgentExternalProjectContext?
    @State private var showExternalAgent = false

    /// 画布根坐标空间名。槽位库的拖拽手势也用它上报落点，两边共用一个空间才能对齐坐标。
    static let spaceName = "clipslots.canvas.root"

    // MARK: 视口

    @State var pan: CGSize = .zero
    @State var zoom: CGFloat = 1
    /// **排版用的缩放**（三轮新增，修「缩放时文字跳舞」）。
    ///
    /// 与 `zoom` 的区别只有一个：它**只在缩放落定后才更新**。节点卡片内部的一切尺寸（宽高、字号、
    /// padding、线宽）都按这个值排版，缩放过程中的差值由节点层的 `scaleEffect(zoom / layoutZoom)`
    /// 补上 —— 变换是渲染期的，不会触发重新折行。详见 `nodeLayer` 里那段注释。
    ///
    /// 落定时机：
    ///   - **离散缩放**（工具栏 +/-、100%、适应内容）：目标值当场就知道，立刻落定，
    ///     动画由 ratio 从 `旧/新` 收到 1 来演；
    ///   - **连续缩放**（触控板捏合、Cmd+滚轮）：停手 `zoomSettleDelay` 后落定。
    /// ★★ v2.11.13：从 `@State` 变成**常量** —— 排版尺度不再跟 zoom 有任何关系。
    ///
    /// 这一行是本轮的全部要害。此前它会在缩放落定后更新，于是每次落定都重算一次卡片排版，
    /// 用户看到的"停手瞬间文字跳一下/换行变了"就是它。钉成常量后：
    ///   - 卡片内部排版（宽高、字号、padding、行数、换行位置）**全生命周期只算一次**；
    ///   - 视觉缩放 100% 交给 `nodeLayer` 的 `scaleEffect(zoom / layoutZoom)`，那是渲染期变换，
    ///     不参与布局协商，物理上不可能触发重新折行。
    var layoutZoom: CGFloat { CanvasZoomLayout.layoutBaseScale }
    /// ★ 九轮需求 1：文字的反向缩放 = `layoutZoom / zoom`（**精确倒数，不钳制**）。
    ///
    /// 节点层的 `scaleEffect(zoom / layoutZoom)` 是"排版档位"与"真实缩放"之间的差值补偿，它对
    /// 卡片里的一切生效 —— 包括已经被固定成设计 pt 的字号。所以文字必须再乘回它的倒数。
    ///
    /// ★ 八轮在这里写的是 `min(1, layoutZoom / zoom)`，用户四次打回的"字体缩放仍未生效"就出在
    /// 这个 `min` 上：`layoutZoom` 是**落定后**才更新的，缩小手势进行中它还冻结在旧档（例如从
    /// 200% 捏到 50%，`layoutZoom` 仍是 2.0），此时精确补偿是 4.0，被钳成 1 等于完全不补偿 ——
    /// 文字跟着画布缩到 1/4，手一停又"啪"地跳回来。详细推导见 `CanvasZoomLayout.textCounterScale`。
    ///
    /// 之所以敢每帧变：它只作用在 `scaleEffect` 上，是**渲染期变换**，不改版面、不触发重新折行。
    private var textCounter: CGFloat {
        CanvasZoomLayout.textCounterScale(zoom: zoom, layoutZoom: layoutZoom)
    }
    /// 连续缩放的落定防抖任务。新事件进来就取消上一个 —— 手势期间反复推迟，只有真的停手才落定。
    @State private var zoomSettleWork: DispatchWorkItem? = nil
    /// 平移手势进行中的临时量。手势结束才合并进 `pan`，避免逐帧累加带来的漂移。
    @State private var panGestureDelta: CGSize = .zero
    /// 捏合开始时的 pan / zoom 基准。锚点缩放必须基于「手势开始那一刻」的状态反算，
    /// 否则 `MagnificationGesture` 每帧给的是相对初始的累计比例，用当前 zoom 去乘会指数放大。
    /// 滚轮 / 中键路由器。**必须是 `@StateObject`**：事件监听器的寿命要跨越视图重建
    /// （实测本项目的画布子树每秒会被重建一次，监听器若绑在 NSView 挂载周期上会反复装卸并丢事件）。
    @StateObject var inputRouter = CanvasInputRouter()
    @StateObject var inlinePlayback = CanvasInlinePlayback()
    @StateObject var contentSnapshots = CanvasContentSnapshots()
    @StateObject var linkCandidateCache = CanvasLinkCandidateCache()
    @State var menuCreationTask: Task<Void, Never>?
    /// 绑定本视图安装到 `CanvasStore` 的闭包，避免旧视图晚到的 onDisappear 清掉新视图的 handler。
    @State private var slotTextRestorerToken = UUID()
    @State private var attachmentBridgeToken = UUID()

    @State private var pinchBasePan: CGSize? = nil
    @State private var pinchBaseZoom: CGFloat = 1

    // MARK: 交互

    /// 拖拽中的节点位移（画布空间）。刻意不写进 store，松手才提交。
    @State var draggingNodeId: String? = nil
    /// 本次拖拽会一起走的节点集合。
    ///
    /// ★ v2.11.7 hotfix18 修 bug：框选两个节点后拖其中一个，只有被按住的那个动。
    /// 根因是预览位移只加在 `draggingNodeId` 上、提交也只提交它一个。现在在 `onChanged` 的第一帧
    /// 就把「这次要一起动谁」定下来（按下时的选中集合），拖拽过程中即使选中集合被别处改动也不受影响。
    @State var draggingIds: Set<String> = []
    @State var dragDelta: CGSize = .zero
    @State var groupDragID: String?
    @State var groupResizePreview: CGRect?
    @State var editingGroupID: String?
    @State var pileDragID: String?
    @State var hoveredPileID: String?
    @State var pileGalleryID: String?
    @State var pileEntryFrames: [String: CGRect] = [:]
    @State var pileLandingFrames: [String: CGRect] = [:]
    @State var groupTitleDraft = ""
    @State var groupWorkflowDraft: CanvasGroupWorkflowDraft?
    @State var groupRunAlert: NSAlert?
    @State var magnetGuideX: CGFloat?
    @State var magnetGuideY: CGFloat?
    @State var magnetState = CanvasMagnetGeometry.State()
    @AppStorage("canvas.navigation.map") var showMiniMap = true
    @AppStorage("canvas.navigation.edges") var showCanvasEdges = true
    @AppStorage("canvas.navigation.gridSnap") var gridSnapEnabled = false
    /// 正在 inline 编辑正文的节点。集中管理，保证同一时刻只有一个编辑器抢焦点。
    @State var editingNodeId: String? = nil
    @State var composingNodeId: String? = nil
    @State var textComposerHeight: CGFloat = 220
    /// 正在管理「入参文件」的节点 id。见 `openInputFiles(_:)` 说明为何弹层不挂在卡片里。
    @State var inputFilesNodeId: String? = nil
    /// 正在全屏预览的媒体（v2.15.0）。nil = 没在预览。
    ///
    /// 住在 View 而不是 `CanvasStore`：它是纯粹的**观看态**，既不进撤销栈也不该被持久化
    /// （下次进画布还停在一张全屏图上是莫名其妙的）。
    @State private var previewTarget: CanvasPreviewTarget? = nil
    /// 正在拖的那条连线（v2.12.0）。nil = 没在拖。
    ///
    /// 全程只活在 View 的 `@State`：拖线是每帧更新光标的高频操作，塞进 `CanvasStore` 的
    /// `@Published` 会让每一帧都重绘所有节点视图（与视口 pan/zoom 留在 View 里同一个理由）。
    @State var linkDrag: LinkDrag? = nil
    /// 历史面板是否展开。
    @State private var showHistory = false
    @State private var showInspector = false
    @State private var showBatchGeneration = false
    /// 框选矩形（屏幕空间）。
    @State var marqueeStart: CGPoint? = nil
    @State var marqueeCurrent: CGPoint? = nil
    @State var pointerSession: CanvasPointerSession? = nil
    @State var edgePanTask: Task<Void, Never>?
    @State var edgePanSessionID: UUID?
    @State var edgePanPoint: CGPoint?
    @StateObject var edgeHover = CanvasEdgeHover()
    @State var selectionLinkPoint: CGPoint? = nil
    @State private var publishedControlRegions: [String: CGRect] = [:]
    @State var controlRegionBuffer = CanvasControlRegionBuffer()
    @State var localControlRegistry = CanvasLocalControlRegistry()
    @State private var viewportFitAnimation: UUID?
    @State private var passiveBatchFit = false
    @State private var activatedTextSlots = Set<String>()
    var controlRegions: [String: CGRect] {
        let published = publishedControlRegions
        var regions = controlRegionBuffer.latest ?? published
        regions.merge(localControlRegistry.screenRegions(nodes: visibleNodes, pan: effectivePan, zoom: zoom,
            layoutZoom: layoutZoom, dragged: draggingIds, delta: dragDelta), uniquingKeysWith: { _, new in new })
        return regions
    }
    /// 光标位置，供锚点缩放使用。
    private var cursorScreen: CGPoint { inputRouter.cursorPoint }
    /// 当前"按坐标维持 hover"的节点（★ v2.11.8 五轮）。
    ///
    /// 与节点自身的 `.onHover` 是 OR 关系：`.onHover` 管进入，这个管**维持**。判定规则全在
    /// `CanvasNodeHover`（本体矩形优先、维持区 = 节点 + 扇形包围盒 + 30pt）。
    @State var hoverHoldNodeId: String? = nil
    @State var portMotions = CanvasPortMotions()
    /// 维持区的离开宽限期定时器（约 200ms）。
    ///
    /// 只给"离开"用，进入是立即的 —— 进入也加延迟会让整个画布的 hover 反馈变粘。
    @State private var hoverLeaveTask: DispatchWorkItem? = nil
    /// 槽位库拖拽的实时拖影。
    @State private var ghost: (title: String, point: CGPoint)? = nil
    /// 「正在把节点往槽位库里拖」的状态（v2.11.8 二轮归槽）。
    ///
    /// 只在光标真的进入侧栏范围后才置起来：拖节点横穿侧栏上方是很常见的动作（把节点从右边挪到
    /// 左边），一进入就把整条侧栏换成分栏块会让列表在拖拽途中不停闪。
    @State var archiveDrag: CanvasNodeArchiveDrag? = nil
    @State var archiveRequest: CanvasArchiveRequest?
    /// 最近一次已知的视图尺寸。
    ///
    /// `GeometryReader` 的 `proxy.size` 只在 `body` 里拿得到，而 Cmd+1 走的是 AppKit 事件监听
    /// 回调（`inputRouter.onKeyAction` → `handleSlotCommand`），那条路径**不在 body 里**。
    /// 没有这份镜像，热键就算不出"当前视口中央在画布的哪里"，只能把新节点扔到原点。
    @State var viewSize: CGSize = .zero

    /// 「ADD NODE」菜单的待办请求（nil = 未打开）。
    ///
    /// 同时记 `screenPoint`（菜单画在哪）与 `canvasPoint`（节点建在哪）：两者在缩放/平移下不是
    /// 同一个数，等到用户选完菜单项再换算就会用上"已经变了的" pan/zoom（菜单开着时中键仍可平移），
    /// 节点会落在离双击点很远的地方。
    @State var addMenu: AddNodeRequest? = nil

    /// 上一次「空白单击」的时间与位置，用来自己判定双击（见 `handleBlankTap`）。
    @State var lastBlankClick: CanvasClickCadence.Click? = nil

    struct AddNodeRequest: Identifiable {
        let id = UUID()
        let screenPoint: CGPoint
        let canvasPoint: CGPoint
        /// 从「选中节点下方的 +」进来时，记住上游是谁。
        let parentNodeId: String?
        var parentNodeIds: [String] = []
        var childNodeId: String? = nil
        var allParentIds: [String] { Array(Set(parentNodeIds + [parentNodeId].compactMap { $0 })).sorted() }
    }

    var body: some View {
        GeometryReader { proxy in
            CanvasAbsoluteLayout {
                CanvasGridBackground(pan: effectivePan, zoom: zoom)
                    .allowsHitTesting(false)
                    .animation(Anim.transition, value: viewportFitAnimation)

                blankClickCatcher

                if canvas.nodes.isEmpty {
                    CanvasEmptyHint()
                        .frame(width: max(0, proxy.size.width - sidebarWidth), height: proxy.size.height)
                        .padding(.leading, sidebarWidth)
                }

                if !canvas.groups.isEmpty {
                    WorkspaceContentBoundary { groupBackgroundLayer }
                        .animation(Anim.transition, value: viewportFitAnimation)
                }
                WorkspaceContentBoundary { edgeLayer }
                    .animation(Anim.transition, value: viewportFitAnimation)

                if canvas.selectedNodeIds.count > 1 || selectionLinkPoint != nil {
                    WorkspaceContentBoundary { selectionBoundsOverlay }
                }
                entrySection("0-canvas-nodes", size: proxy.size) { nodeLayer }
                    .zIndex(11)
                if !canvas.groups.isEmpty {
                WorkspaceSectionAdmission(admission: groupMounts.admission(for: canvas.selectedGroupID),
                                          width: proxy.size.width, height: proxy.size.height,
                                          fillsViewport: true,
                                          traceLabel: "canvas-group-header") { groupHeaderLayer }
                    .animation(Anim.transition, value: viewportFitAnimation)
                }

                if linkDrag != nil { WorkspaceContentBoundary { linkDragOverlay } }
                if draggingNodeId != nil { WorkspaceContentBoundary { magnetGuideOverlay } }

                WorkspaceContentBoundary { outputPortOverlay }
                // v2.15.0：入口端口。与出口把手同层（节点之上），静态只画一枚、拖线时画全部合法落点。
                WorkspaceContentBoundary { inputPortOverlay }
                if canvas.selectedNodeIds.count > 1 {
                    WorkspaceContentBoundary { selectionActionsOverlay }
                }

                WorkspaceContentBoundary { actionBarOverlay }
                if canvas.selectedPile != nil || hoveredPileID != nil {
                    WorkspaceContentBoundary { pileToolbarOverlay }
                }
                WorkspaceContentBoundary { composerOverlay }
                if canvas.selectedEdgeId != nil { WorkspaceContentBoundary { selectedEdgeToolbar } }
                CanvasEdgeScissors(hover: edgeHover)
                    .zIndex(60)

                if marqueeStart != nil { WorkspaceContentBoundary { marqueeOverlay } }

                WorkspaceContentBoundary { floatingLayer(size: proxy.size) }
                    .zIndex(70)
                entrySection("5-canvas-library", size: proxy.size) { libraryOverlay(size: proxy.size) }
                    .zIndex(80)

                if ghost != nil { WorkspaceContentBoundary { ghostOverlay } }

                // ADD NODE 菜单压在最上层：它是模态性质的浮层，被任何东西盖住都会变成"点了没反应"。
                if addMenu != nil { WorkspaceContentBoundary { addNodeMenuOverlay(size: proxy.size) } }

                // 全屏预览比 ADD NODE 菜单还高一层：它是**全屏模态**，预览期间下面的一切都不该
                // 能被点到（包括那个菜单）。铺满整个 proxy 而不是只铺画布区 —— 侧边槽位库面板
                // 也必须被盖住，否则"全屏"这个词就名不副实。
                if previewTarget != nil { WorkspaceContentBoundary { fullscreenPreviewOverlay } }
                if pileGalleryID != nil {
                    WorkspaceContentBoundary { pileGalleryOverlay }.zIndex(850)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // v2.16.0：画布底改**纯黑**，且不再跟随 AppTheme 的浅色/深色模式。
            // 理由见 `TapSkin` 的注释：画布是摄影棚，主角是用户的图片和视频，浅色底会把媒体的
            // 对比度吃掉一半。这是全 App 唯一一处刻意脱离主题体系的界面。
            .background(TapSkin.void)
            // ★ v2.11.7 hotfix17: 滚轮 / 中键只能从 AppKit 拿（见 CanvasInputRouter）。
            // 这里只放一个对鼠标透明的几何锚点，事件监听的寿命由 @StateObject 持有的路由器决定。
            .background(CanvasInputAnchor(router: inputRouter).allowsHitTesting(false))
            .contentShape(Rectangle())
            // 命名坐标空间：槽位库那边的 DragGesture 也报到这个空间，落点才能直接换算成画布坐标。
            .coordinateSpace(name: CanvasWorkspaceView.spaceName)
            .onPreferenceChange(CanvasControlRegions.self) {
                // #region debug-point A-D:menu-latency-layout
                #if DEBUG
                if let endpoint = ProcessInfo.processInfo.environment["CLIPSLOTS_MENU_LATENCY_URL"], let url = URL(string: endpoint), let request = addMenu { let now = ProcessInfo.processInfo.systemUptime; var r = URLRequest(url: url); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-menu-latency", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "D", "msg": "[DEBUG] menu layout", "data": ["uptime": now, "id": request.id.uuidString, "menu": NSStringFromRect($0["add-menu"] ?? .zero), "image": NSStringFromRect($0["add-menu-row-image"] ?? .zero), "nodeBodies": CanvasRenderDiagnostics.count]]); URLSession.shared.dataTask(with: r).resume() }
                #endif
                // #endregion
                controlRegionBuffer.receive($0) { regions in
                    if publishedControlRegions != regions { publishedControlRegions = regions }
                }
            }
            .simultaneousGesture(pinchGesture)
            .onAppear {
                pan = canvas.pan
                zoom = canvas.zoom
                canvas.agentGenerationOwner = slotTextRestorerToken
                canvas.agentGenerationHandler = { ids in
                    runGeneration(nodeIDs: ids)
                    return canvas.selectionGenerationTask
                }
                // ★ v2.11.13：`layoutZoom` 已是常量基准，这里无须（也无法）再对齐 zoom。
                // 首帧的 ratio = zoom / base ≠ 1 是**故意**的：卡片按基准排版、由变换缩到位。
                // 闭包在这里绑一次即可：@State/@ObservedObject 的读写都走稳定的存储盒，
                // 视图结构体后续被重建也不影响这几个闭包写到正确的地方。
                inputRouter.onScroll = { dx, dy, precise, isZoom, point in
                    controlRegionBuffer.end()
                    edgeHover.cancel()
                    handleScroll(deltaX: dx, deltaY: dy, precise: precise, isZoom: isZoom, at: point)
                }
                inputRouter.onMiddleDrag = { delta in
                    controlRegionBuffer.end()
                    edgeHover.cancel(); handleMiddleDrag(delta)
                }
                inputRouter.onMiddleDragEnded = { canvas.updateViewport(pan: pan, zoom: zoom) }
                inputRouter.onKeyAction = { action in
                    controlRegionBuffer.end()
                    return handleKeyAction(action)
                }
                inputRouter.blocksCanvasInput = {
                    isWorkspaceTransitioning() || previewTarget != nil || pileGalleryID != nil || showBatchGeneration
                }
                inputRouter.usesHandTool = { canvas.activeTool == .hand && addMenu == nil }
                inputRouter.onPointer = { event, point in routeCanvasPointer(event, at: point) }
                inputRouter.onHover = { point in
                    controlRegionBuffer.end()
                    updateEdgeHover(at: point)
                    if let point {
                        updateHoverHold(at: point)
                        updatePortHover(at: point)
                    } else {
                        portMotions.reset()
                        scheduleHoverHold(nil)
                    }
                }
                inputRouter.canPanAt = { isCanvasSurface(at: $0, allowingSlotPreview: true) }
                inputRouter.onCancelPointer = { cancelCanvasPointer() }
                inputRouter.allowsEditorFocus = { addMenu == nil && inputFilesNodeId == nil }
                inputRouter.canFocusEditorAt = { point in
                    if composerContains(point) { return true }
                    guard let node = nodeBody(at: point) else { return true }
                    return node.kind == .text && editingNodeId == node.id
                }
                inputRouter.start()

                // 撤销/重做要能把槽位主体文本一起回滚。store 层不认识 `SlotStoreObservable`
                // （那会把画布重新绑回全局重绘的老路），所以由视图层把这条写回能力注入进去。
                canvas.installSlotTextRestorer(id: slotTextRestorerToken) { groupId, slot, text in
                    _ = store.writeCanvasSlotText(groupId: groupId, slot: slot, text: text)
                }
                canvas.flushTextDocuments = { [weak store] in store?.flushCanvasTextDocuments() ?? true }
                store.canvasTextDidPersist = { [weak canvas] groupID, slot, before, after in
                    guard let canvas,
                          let node = canvas.nodes.first(where: { $0.groupId == groupID && $0.slot == slot }) else { return }
                    canvas.recordSlotTextEdit(nodeId: node.id, edit: .init(
                        groupId: groupID, slot: slot, before: before, after: after))
                    canvas.noteSlotDataChanged()
                }

                // 附件编辑（增删入参 / 提升主体）的撤销回滚桥（v2.16.5）。
                canvas.installAttachmentBridge(id: attachmentBridgeToken, apply: { groupId, slot, attachments, token, stashAway, restore in
                    _ = store.applyCanvasAttachmentEdit(groupId: groupId,
                                                        slot: slot,
                                                        attachments: attachments,
                                                        stashToken: token,
                                                        stashAwayIds: stashAway,
                                                        restoreIds: restore)
                    canvas.noteSlotDataChanged()
                }, discard: { token in
                    store.discardCanvasAttachmentStash(token: token)
                })
                canvas.documentRestorerID = slotTextRestorerToken
                canvas.onRestoreDocument = { _ = reconcilePrivateContents() }
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
                canvas.recoverGenerationAction = { node in _ = recoverGeneration(node) }
                canvas.byteArtistInputPlan = { node in CanvasWorkflowCapture.plan(node: node, canvas: canvas, store: store) }

                // 没有光标事件之前，锚点先取视图中心，避免首次捏合以 (0,0) 为锚点把画面甩到角上。
                inputRouter.cursorPoint = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                viewSize = proxy.size

                // ★ v2.14.0：进画布时对一次账。
                //
                // 这条不只是"顺手打扫"：v2.12.x 删节点不清内容、v2.13.0 又给撤销栈开了豁免，
                // 老用户的私有库里已经堆了一批无主残留（用户截图里 9 条），而那些节点早就不在
                // 画布上了，只靠"删除时清理"永远清不到。一次对账覆盖所有历史成因。
                //
                // 这里**不弹 toast**：搬进暂存区不是"清理掉了"，Cmd+Z 还能拿回来，而且刚进画布
                // 就弹一句"已清理 N 项"只会让用户以为自己丢了东西。真正需要告知的是删除那一刻
                // （见 `performDelete`）。
                if !entryPrepared { _ = reconcilePrivateContents() }
                refreshCanvasContent()
                synchronizeMediaLayouts()
                fitCreatedWorkflow(size: proxy.size)
                #if DEBUG
                if ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1" {
                    CanvasAgentGroupsProbeBridge.current = self
                }
                if ProcessInfo.processInfo.environment["CLIPSLOTS_WINDOW_CHROME_PROBE"] != "1" {
                    runCanvasRegressionIfRequested()
                }
                #endif
            }
            .onChange(of: proxy.size) { newSize in viewSize = newSize }
            .onChange(of: canvas.selectedNodeIds) { selected in
                if selected.isEmpty { CanvasParameterPopoverSession.popover?.performClose(nil) }
            }
            .onChange(of: addMenu?.id) { request in
                if request != nil { CanvasParameterPopoverSession.popover?.performClose(nil) }
            }
            .sheet(isPresented: $showExternalAgent) {
                if let externalAgentContext {
                    AgentExternalHandoffView(context: externalAgentContext,
                                             availableSize: proxy.size,
                                             onClose: { showExternalAgent = false })
                }
            }
            .sheet(isPresented: $showBatchGeneration) {
                BatchGenerationView(store: store, canvas: canvas, size: proxy.size)
            }
            .sheet(item: $archiveRequest) { request in
                CanvasArchivePicker(store: store, canvas: canvas, request: request,
                    archive: { node, page, group, slot in
                        try archiveNode(node, pageID: page, groupID: group, slot: slot)
                    }, close: { archiveRequest = nil })
            }
            .sheet(item: $groupWorkflowDraft) { request in
                WorkflowSkillEditor(draft: request.skill, context: request.context,
                                    original: request.original, onSaved: request.onSaved)
            }
            .onChange(of: canvas.slotRevision) { _ in refreshCanvasContent() }
            .onChange(of: store.canvasSlotRevision) { _ in refreshCanvasContent() }
            .onChange(of: store.slots.mapValues(\.contentId)) { _ in refreshCanvasContent() }
            .onChange(of: store.currentSpecialSlotId) { _ in refreshCanvasContent() }
            .onChange(of: canvas.nodes.map { "\($0.id):\($0.groupId):\($0.slot)" }) { _ in
                nodeMountQueue.update(ids: canvas.nodes.map(\.id))
                refreshCanvasContent()
            }
            .onChange(of: canvas.edges) { _ in edgeHover.cancel() }
            .onChange(of: hoverHoldNodeId) { id in
                if let id { activatedTextSlots.insert(id) }
            }
            .onChange(of: canvas.agentFocusRequest) { request in
                if let request, let node = canvas.nodes.first(where: { $0.id == request.nodeID }) {
                    centerViewport(on: node)
                }
            }
            .onChange(of: canvas.workflowFitRequest) { _ in fitCreatedWorkflow(size: proxy.size) }
            .onChange(of: canvas.agentHistoryError) { error in
                if let error { store.transientUI.showToast(error) }
            }
            .onChange(of: canvas.activeProjectId) { _ in
                controlRegionBuffer.end()
                cancelCanvasPointer()
                nodeMountQueue.reset()
                groupMounts.reset()
                activatedTextSlots = []
                pileGalleryID = nil; hoveredPileID = nil
                pileEntryFrames = [:]; pileLandingFrames = [:]
                editingGroupID = nil
                groupWorkflowDraft = nil
                if let alert = groupRunAlert, let window = inputRouter.anchorView?.window {
                    window.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
                    groupRunAlert = nil
                }
                inlinePlayback.stop()
                refreshCanvasContent()
            }
            .task(id: canvas.activeProjectId) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    refreshCanvasContent()
                }
            }
            .onDisappear {
                controlRegionBuffer.end()
                nodeMountQueue.reset()
                cancelCanvasPointer()
                inlinePlayback.stop()
                mediaLayoutTask?.cancel()
                AttachmentManagerPanelController.shared.close()
                inputRouter.stop()
                // 必须撤销登记：留着它，切回编辑模式后 Cmd+1 会被一个已经下台的画布吃掉，
                // 表现是"热键静默失效"（既没粘贴，也没有任何提示）。
                CanvasCommandBridge.shared.slotCommandHandler = nil
                canvas.recoverGenerationAction = nil
                canvas.byteArtistInputPlan = nil
                if canvas.agentGenerationOwner == slotTextRestorerToken {
                    canvas.agentGenerationOwner = nil
                    canvas.agentGenerationHandler = nil
                }
                canvas.clearSlotTextRestorer(id: slotTextRestorerToken)
                canvas.clearAttachmentBridge(id: attachmentBridgeToken)
                if canvas.documentRestorerID == slotTextRestorerToken {
                    canvas.documentRestorerID = nil
                    canvas.onRestoreDocument = nil
                    canvas.slotTitleProvider = nil
                }
                canvas.flushSave()
            }
        }
    }

    private func entrySection<Content: View>(_ id: String, size: CGSize,
                                            @ViewBuilder content: @escaping () -> Content) -> WorkspaceSectionAdmission {
        WorkspaceSectionAdmission(admission: sectionMounts?.admission(for: id) ?? .immediate,
                                  width: size.width, height: size.height, fillsViewport: true, content: content)
    }

    /// 一次进行中的拖线（v2.12.0）。
    struct LinkDrag {
        /// 从哪个节点拖出来的。
        let fromNodeId: String
        /// 出发点（屏幕坐标，= 出口把手位置）。
        var start: CGPoint
        /// 当前光标（屏幕坐标）。
        var cursor: CGPoint
        /// 光标此刻压在哪个节点上（且那个节点可以接这条线）。nil = 落空。
        var targetNodeId: String?
        var fromInput: Bool = false
    }

    var effectivePan: CGSize {
        CGSize(width: pan.width + panGestureDelta.width, height: pan.height + panGestureDelta.height)
    }

    // MARK: - 空白单击

    /// 「点空白取消选中」的承接层（v2.11.7 hotfix21）。
    ///
    /// 三个设计约束，缺一个就会引出新 bug：
    ///   1. **必须是 ZStack 的最底层**。命中测试取最上面那一层，所以节点卡片、槽位库侧栏、
    ///      右上按钮、底部工具栏、属性面板都在它之上 —— 点它们时事件根本到不了这里，
    ///      不会出现「点属性面板里的字体下拉，结果选中被清空、面板当场消失」。
    ///   2. **不能挂在 `CanvasGridBackground` 上**。网格层是 `allowsHitTesting(false)` 的
    ///      （它压在整幅画布上，能吃事件就等于把整块画布点死），给它加 tap 收不到任何点击。
    ///      所以另铺一张只负责收点击的透明层。
    ///   3. **tap 而不是 drag**。框选是外层那条 `canvasDragGesture`（ancestor），SwiftUI 里
    ///      后代手势优先，但 TapGesture 一旦位移超阈值就会失败并把比赛让给 ancestor 的
    ///      DragGesture —— 于是「点一下 = 取消选中，拖出去 = 框选」天然分流，不需要额外的
    ///      互斥判断。带抖动的单击由 `canvasDragGesture` 那侧的 click slop 兜住。
    private var blankClickCatcher: some View {
        Color.black.opacity(0.001)
            .contentShape(Rectangle())
            // ★ v2.11.8：双击空白 = 在鼠标位置弹「ADD NODE」菜单。
            //
            // 只挂单击手势，双击靠 `CanvasClickCadence` 自己数 —— 原因见该类型的文档：
            // 单击手势与 `onTapGesture(count: 2)` 共存时，双击在实测里**从不触发**。
            //
            // 位置取 `cursorScreen`（由 `.onContinuousHover` 实时更新）而不是手势的 location：
            // macOS 13 的 `onTapGesture` 不给落点，而 hover 位置与点击落点在实践中是同一个像素
            // （鼠标不会在按下与抬起之间跑掉）。锚点缩放一直用的也是这份坐标。
            .allowsHitTesting(false)
    }

    /// 空白单击 / 双击的分流。
    ///
    /// 第一击照旧取消选中（保持 hotfix21 的手感，不能让它等双击超时），第二击落在同一处且在系统
    /// 双击间隔内，顶部留白放大窗口，内容区弹 ADD NODE 菜单。
    /// 清空点击计时，避免"连点三下"触发第二个动作。
    func handleBlankTap(eventTime: Double? = nil) {
        // #region debug-point C:blank
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7777/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-pointer-routing", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "C", "msg": "[DEBUG] blank callback"]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
        // 正在 inline 编辑时，点空白处的语义是「写完了」——先按失焦保存收掉编辑态（否则编辑框会
        // 一直挂在节点上，见 endInlineEditing 的注释），这一击不再兼作取消选中/双击判定。
        endInlineEditing()
        composingNodeId = nil
        hoverLeaveTask?.cancel()
        hoverHoldNodeId = nil
        let click = CanvasClickCadence.Click(point: cursorScreen,
                                             time: eventTime ?? NSApp.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime)
        if CanvasClickCadence.isDoubleClick(previous: lastBlankClick,
                                            current: click,
                                            interval: NSEvent.doubleClickInterval) {
            lastBlankClick = nil
            if cursorScreen.y <= 80, let window = NSApp.keyWindow,
               !window.styleMask.contains(.fullScreen) {
                MainWindowDragRegion.toggleZoom(window)
            } else {
                openAddMenu(atScreen: cursorScreen, parentNodeId: nil)
            }
            return
        }
        lastBlankClick = click
        canvas.clearSelection()
    }

    // MARK: - 全屏预览（v2.15.0）

    @ViewBuilder
    private var fullscreenPreviewOverlay: some View {
        if let target = previewTarget {
            CanvasFullscreenPreview(target: target,
                                    onClose: { previewTarget = nil },
                                    onArchive: { archiveFromPreview(target) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(900)
        }
    }

    /// 打开全屏预览。
    ///
    /// 顺手把节点选中：关掉浮层后用户通常紧接着要对这个节点做事（重跑 / 入库 / 连线），
    /// 而"我刚才看的是哪个"在一屏几十个节点里并不显然。
    func openFullscreen(_ node: CanvasNode, attachment: SlotContent.SlotAttachment) {
        inlinePlayback.pause()
        canvas.select(id: node.id, additive: false)
        previewTarget = CanvasPreviewTarget(nodeId: node.id,
                                           attachment: attachment,
                                           pathLabel: pathLabel(for: node),
                                           canArchive: canArchiveToLibrary(node),
                                           isGeneratedImage: node.kind == .image && !node.isMediaSource)
    }

    /// 这个节点有没有"能全屏看"的东西 —— 有则返回该展示哪一份。
    ///
    /// 不按 `kind` 卡门槛：槽位节点（`.slot`）里躺着一张生成好的图是最常见的情形，而用户这一轮的
    /// 诉求是"全屏显示图片和视频"，不是"只有图片节点才能全屏"。文本节点自然返回 nil，操作条上的
    /// 全屏按钮也就跟着消失。
    ///
    /// 挑选逻辑委托给 `CanvasMediaPick`，与媒体卡**画在脸上的那张图**共用一套规则 —— 否则会出现
    /// "卡片显示产物、点全屏弹出参考图"。
    func previewableMedia(of node: CanvasNode) -> SlotContent.SlotAttachment? {
        CanvasMediaPick.primary(node: node, attachments: liveAttachments(for: node))
    }

    /// 全屏态里点「入库」。
    ///
    /// 入库会把节点重新绑到正式槽位（`node.groupId/slot` 变），于是 `previewTarget.nodeId`
    /// 立刻失效 —— 所以先关浮层再入库，而不是入库后留着一个指向旧 id 的浮层。
    private func archiveFromPreview(_ target: CanvasPreviewTarget) {
        guard let node = canvas.nodes.first(where: { $0.id == target.nodeId }) else {
            previewTarget = nil
            return
        }
        if node.kind == .image && !node.isMediaSource {
            downloadGeneratedImages([node])
        } else {
            previewTarget = nil
            archiveNodeToLibrary(node)
        }
    }

    // MARK: - 入库（v2.15.0）

    /// 这个节点还能不能入库。
    ///
    /// 已经在正式槽位组里的节点返回 false：它**本来就在槽位库里**，再"入库"一次没有任何语义。
    func canArchiveToLibrary(_ node: CanvasNode) -> Bool {
        !(node.kind == .image && !node.isMediaSource)
            && SpecialSlotStorage.isReservedGroupId(node.groupId)
    }

    /// Button, preview and drag entry points all use the same three-level picker.
    func archiveNodeToLibrary(_ node: CanvasNode) {
        requestArchive([node])
    }

    func requestArchive(_ nodes: [CanvasNode]) {
        let targets = nodes.filter(canArchiveToLibrary).sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        guard !targets.isEmpty else {
            store.transientUI.showToast("这个节点已经在槽位库里了")
            return
        }
        endInlineEditing()
        guard store.flushCanvasTextDocuments() else { return }
        archiveRequest = CanvasArchiveRequest(projectID: canvas.activeProjectId, nodes: targets)
    }

    // MARK: - 节点卡片分派（v2.15.0 建立 · v2.16.0 收敛为两张卡）

    /// 按 `kind.cardForm` 选卡片。
    ///
    /// ## v2.16.0：三张卡并成两张
    ///
    /// v2.15.0 是「通用槽位卡 + 媒体卡」两个视图、三种形态（`.slotStack` / `.text` / `.media`），
    /// 但 `.text` 走的是通用卡 —— 于是文本节点继承了一整套它用不上的结构（path 标题行、入参文件行、
    /// 扇形槽位堆）。实测 TapNow 之后这个分法站不住了：TapNow 的文本节点和图片节点**外形完全相同**，
    /// 区别只在"中间画字还是画图"。
    ///
    /// 所以 `.text` / `.media` 一起交给 `CanvasTapNodeCard`（它内部就是一个 `switch`），
    /// `.slotStack` 留给 `CanvasNodeCardView`。
    ///
    /// ## 为什么 `.slotStack` **不**一起并过去
    ///
    /// 槽位节点不是"一块内容"，它是**一叠内容**（一个槽位组里的多个槽位，可扇形展开、可翻页、
    /// 可提升/删除入参）。这些交互是 ClipSlots 自己的东西，TapNow 里没有对应物，硬塞进
    /// 「一块圆角媒体」的模型里会把它做残。它需要的是**按 TapNow 的皮肤重绘**（去边框、去标题栏、
    /// 名签外置），而不是换一个模型 —— 皮肤和模型是两件事，这一版只统一皮肤。
    ///
    /// ## 为什么分派在这里而不是在卡片内部
    ///
    /// 全屏层的状态（`previewTarget`）住在本视图里，因为它要盖在整个工作区之上、还要能被 `Esc`
    /// 关掉 —— 这些都不是一张卡片能负责的。若把分派藏进卡片，那个回调就得穿透一层只为了转交。
    @ViewBuilder
    func nodeCard(_ node: CanvasNode, isEditing: Bool) -> some View {
        if node.kind.cardForm == .slotStack {
            if usesIdleTextSurface(node, isEditing: isEditing) {
                CanvasIdleTextSlot(node: node, text: renderText(for: node), pathLabel: pathLabel(for: node),
                    renderScale: layoutZoom, viewZoom: zoom, onOpenInputFiles: { openInputFiles(node) },
                    registry: localControlRegistry)
            } else {
            CanvasNodeCardView(node: node,
                               isSelected: canvas.selectedGroupID == nil && canvas.selectedNodeIds.contains(node.id),
                               text: renderText(for: node),
                               pathLabel: pathLabel(for: node),
                               attachments: renderAttachments(for: node),
                               // ★★ v2.11.13：常量基准。卡片内部排版只算这一次，
                               // 之后 zoom 怎么变都只走下面那句 `scaleEffect`。
                               renderScale: layoutZoom,
                               // 恒为 1（`textCounterScale` 已退休），留着调用点便于查证。
                               textCounter: textCounter,
                               // 真实缩放：只用于"要不要写字"的判定。
                               viewZoom: zoom,
                               isEditing: isEditing,
                               onBeginEdit: { beginEdit(node) },
                               onCommitEdit: { commitEdit(node, text: $0) },
                               onCancelEdit: { editingNodeId = nil },
                               onOpenInputFiles: { openInputFiles(node) },
                               onPromoteInput: { promoteInput(node, index: $0) },
                               onDeleteInput: { deleteInput(node, index: $0) },
                               // ★ 六轮：卡片命中层独占点击后由它补选中（Shift 加选与祖先那条一致）。
                               onActivateNode: {
                                   guard editingNodeId != node.id else { return }
                                   endInlineEditing()
                                   inputRouter.claimKeyboardFocus()
                                   canvas.select(id: node.id,
                                                 additive: NSEvent.modifierFlags.contains(.shift))
                               },
                               onToast: { store.transientUI.showToast($0) },
                               isHoverHeld: hoverHoldNodeId == node.id,
                               onHoverChanged: { noteNodeHover(node, hovering: $0) },
                               onPreviewDragChanged: { updateNodeDrag(node, translation: $0, point: $1) },
                               onPreviewDragEnded: { endNodeDrag(node, translation: $0, point: $1) })
            }
        } else {
            CanvasTapNodeCard(node: node,
                              isSelected: canvas.selectedGroupID == nil && canvas.selectedNodeIds.contains(node.id),
                              isEditing: isEditing,
                              text: renderText(for: node),
                              textDocument: node.kind == .text ? store.canvasTextDocument(groupID: node.groupId, slot: node.slot,
                                  renderContent: contentSnapshots.entry(node)?.content, rendering: true) : nil,
                              pathLabel: pathLabel(for: node),
                              attachments: renderAttachments(for: node),
                              renderScale: layoutZoom,
                              textCounter: textCounter,
                              viewZoom: zoom,
                              isHoverHeld: hoverHoldNodeId == node.id,
                              canArchive: canArchiveToLibrary(node),
                              inlinePlayback: inlinePlayback,
                              connectionAppearance: connectionAppearance(for: node),
                              generationBackdrop: generationBackdrop(for: node),
                              onHoverChanged: { noteNodeHover(node, hovering: $0) },
                              onBeginEdit: { beginEdit(node) },
                              onCommitEdit: { commitEdit(node, text: $0) },
                              onCancelEdit: { editingNodeId = nil },
                              onOpenFullscreen: { openFullscreen(node, attachment: $0) },
                              onArchive: { archiveNodeToLibrary(node) })
        }
    }

    func usesIdleTextSurface(_ node: CanvasNode, isEditing: Bool) -> Bool {
        node.kind.cardForm == .slotStack && !isEditing && hoverHoldNodeId != node.id
            && !activatedTextSlots.contains(node.id)
            && draggingNodeId == nil && draggingIds.isEmpty && groupDragID == nil
            && linkDrag == nil && pileLandingFrames[node.id] == nil
            && (!canvas.selectedNodeIds.contains(node.id) || canvas.selectedGroupID != nil)
            && node.state == .idle && renderAttachments(for: node).isEmpty
            && !renderText(for: node).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && CanvasFanGeometry.allCardSources(attachmentIndices: [], text: renderText(for: node)).count <= 5
            // The shared passive host is below interactive siblings. Overlapping
            // cards retain the normal tree so visual and pointer paint order agree.
            && !canvas.nodes.contains { $0.id != node.id && $0.frame.intersects(node.frame.insetBy(dx: -20, dy: -20)) }
    }

    // MARK: - 节点层

    @ViewBuilder private func nodeMeasurement(_ node: CanvasNode) -> some View {
        if canvas.groups.contains(where: { $0.nodeIDs.contains(node.id) }) {
            CanvasGroupNodeMeasurement(node: node, projectID: canvas.activeProjectId, layoutScale: layoutZoom)
        }
    }

    private var nodeLayer: some View {
        let aimed = linkDrag.flatMap { drag in
            drag.targetNodeId ?? nodeBody(at: drag.cursor)?.id
        }
        return CanvasNodeLayerBoundary(key: .init(project: canvas.activeProjectId,
            nodes: canvas.nodes, edges: canvas.edges, piles: canvas.piles, groups: canvas.groups,
            selected: canvas.selectedNodeIds, selectedGroup: canvas.selectedGroupID,
            edited: editingNodeId, hovered: hoverHoldNodeId, dragID: draggingNodeId,
            dragged: draggingIds, delta: dragDelta, pan: effectivePan, zoom: zoom, layoutZoom: layoutZoom,
            size: viewSize, source: linkDrag?.fromNodeId, reverse: linkDrag?.fromInput ?? false, aimed: aimed,
            contentRevisions: contentSnapshots.entries.mapValues(\.revision),
            currentGroup: store.currentSpecialSlotId, paths: canvas.nodes.map(pathLabel),
            landings: pileLandingFrames, groupDrag: groupDragID, groupResize: groupResizePreview,
            pileDrag: pileDragID, hoveredPile: hoveredPileID, pileGallery: pileGalleryID, pileEntries: pileEntryFrames)) {
                nodeLayerContents
            }.equatable()
    }

    private var nodeLayerContents: some View {
        let idle = visibleNodes.filter { usesIdleTextSurface($0, isEditing: editingNodeId == $0.id) }
        let idleIDs = Set(idle.map(\.id))
        return CanvasAbsoluteLayout {
            CanvasPooledTextLayer(pool: textSurfacePool,
                items: idle.map { .init(node: $0, text: renderText(for: $0), path: pathLabel(for: $0)) },
                pan: effectivePan, zoom: zoom, layoutZoom: layoutZoom, registry: localControlRegistry,
                onOpenInputFiles: { openInputFiles($0) })
                .frame(width: viewSize.width, height: viewSize.height)
            ForEach(visibleNodes.filter { !idleIDs.contains($0.id) }) { node in
                let isDragging = draggingIds.contains(node.id)
                let isEditing = editingNodeId == node.id
                let controlSpace = "canvas-node-controls-\(node.id)"
                let controlScale = zoom / max(layoutZoom, 0.01)
                let controlOrigin = screenFrame(of: node).origin
                CanvasMountingNode(admission: nodeMountQueue.admission(for: node.id)) {
                CanvasRenderBoundary(key: .init(
                    node: node, selected: canvas.selectedGroupID == nil && canvas.selectedNodeIds.contains(node.id),
                    editing: isEditing, hovered: hoverHoldNodeId == node.id,
                    textVisible: CanvasScreenText.textVisible(nodeSize: node.frame.size, zoom: zoom),
                    fanTextVisible: CanvasScreenText.cardTextVisible(
                        cardSize: CanvasFanGeometry.fanCardSize(boxHeight: CanvasCardLayout.verticalPlan(
                            nodeHeight: node.height, renderScale: layoutZoom,
                            headerFontSize: 9.5, footerFontSize: 9.5).previewHeight1x), zoom: zoom),
                    slotRevision: 0, contentRevision: contentSnapshots.entry(node)?.revision ?? 0,
                    currentGroup: store.currentSpecialSlotId,
                    currentContentId: node.groupId == store.currentSpecialSlotId ? store.slots[node.slot]?.contentId : nil,
                    path: pathLabel(for: node),
                    connectionAppearance: connectionAppearance(for: node)
                )) {
                    nodeCard(node, isEditing: isEditing)
                        .contextMenu { nodeContextMenu(node) }
                }
                    .equatable()
                    .environment(\.canvasControlSpace, controlSpace)
                    .environment(\.canvasControlTransform, CanvasControlTransform(origin: controlOrigin, scale: controlScale))
                    .coordinateSpace(name: controlSpace)
                    .onPreferenceChange(CanvasLocalControlRegions.self) { values in
                        if !usesIdleTextSurface(node, isEditing: isEditing) {
                            localControlRegistry.nodes[node.id] = values
                        }
                    }
                    .transformPreference(CanvasLocalControlRegions.self) { $0 = [:] }
                    .onDisappear { localControlRegistry.nodes[node.id] = nil }
                    .background(nodeMeasurement(node))
                    .modifier(CanvasNodePresence(createdAt: usesIdleTextSurface(node, isEditing: isEditing)
                        ? .distantPast : node.createdAt))
                    // ★ 三轮：缩放过程中的「文字跳舞」修复 —— 排版用 `layoutZoom`，缩放差值用变换补。
                    //
                    // 症状（用户录屏）：缩放时节点里的文字一帧一个换行位置，整块文字在抖。
                    // 根因：v2.11.8 为了消除放大模糊，把 zoom 做成了**排版参数**（卡片宽度、字号
                    // 全乘 zoom）。这在缩放**稳定**时是对的（每个字号都重新排版 → 清晰），但缩放
                    // **过程中** zoom 每帧都在变，等于每帧拿一个新宽度重新折行 —— 折行位置在
                    // "第 N 个字" 和 "第 N+1 个字" 之间反复跳，看起来就是文字在跳舞。
                    //
                    // 修法（业界画布通用做法）：把"排版"和"动画"分开。
                    //   - `layoutZoom` 只在缩放**落定**后才更新（离散缩放立即落定，连续手势
                    //     停手 0.15s 后落定），所以文字在整段缩放里**只排版一次**；
                    //   - 视觉上的连续变化交给 `scaleEffect(zoom / layoutZoom)`，这是渲染期变换，
                    //     不触发任何重新排版。
                    // 于是：缩放中不抖（代价是过程中略软），落定后 ratio 回到 1，恢复逐字号清晰排版
                    // —— v2.11.8 修掉的"放大模糊"不会回来，因为那说的是**稳定态**。
                    //
                    // 锚点必须 `.topLeading`：下面那行 `.offset` 定位的是节点左上角，用 `.center`
                    // 缩放会让节点绕自己中心胀缩，与 `screen = canvas * zoom + pan` 不再自洽。
                    .scaleEffect(zoom / max(layoutZoom, 0.01), anchor: .topLeading)
                    // 屏幕坐标 = 画布坐标 * zoom + pan。**必须与 `CanvasGeometry.screenPoint` 同式**，
                    // 否则命中判定（框选、拖拽落点、弹层锚点）会与眼睛看到的位置整体错开。
                    .offset(x: (node.x + (isDragging ? dragDelta.width : 0)) * zoom + effectivePan.width,
                            y: (node.y + (isDragging ? dragDelta.height : 0)) * zoom + effectivePan.height)
                    .modifier(CanvasPileLanding(start: pileLandingFrames[node.id],
                        target: screenFrame(of: node), zoom: zoom))
                    .animation(Anim.transition, value: viewportFitAnimation)
                }
                    .frame(width: node.width * layoutZoom, height: node.height * layoutZoom, alignment: .topLeading)
                    // 被按住的那个压在最上层；同批一起走的排第二层，这样多选拖动时整组都浮在其他节点之上。
                    .zIndex(nodeLayerOrder(node))
                    // 外壳/正文由原生路由处理；预览独立传递拖动，编辑器和按钮保留自身事件。
            }
            ForEach(retiringNodes) { retired in
                CanvasTapNodeCard(node: retired.node, isSelected: false, isEditing: false,
                                  text: retired.text, pathLabel: retired.path, attachments: retired.attachments,
                                  renderScale: layoutZoom, textCounter: textCounter, viewZoom: zoom,
                                  isHoverHeld: false, canArchive: false, inlinePlayback: inlinePlayback,
                                  onHoverChanged: { _ in }, onBeginEdit: {}, onCommitEdit: { _ in },
                                  onCancelEdit: {}, onOpenFullscreen: { _ in }, onArchive: {})
                    .modifier(CanvasNodePresence(createdAt: retired.node.createdAt, exiting: true))
                    .scaleEffect(zoom / max(layoutZoom, 0.01), anchor: .topLeading)
                    .offset(x: retired.node.x * zoom + effectivePan.width,
                            y: retired.node.y * zoom + effectivePan.height)
                    .allowsHitTesting(false)
            }
            pileLayer
        }
        .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
        // 统一施加视口变换。锚点固定 `.topLeading` 是刻意的：`CanvasGeometry` 全部公式都建立在
        // `screen = canvas * zoom + pan` 之上，而这个式子只有在缩放锚点为原点时才成立。
        // 用 `.center` 会凭空引入一个「视图尺寸的一半」的偏移，让所有命中判定整体错位。
        //
        // ★ v2.11.8：`scaleEffect` 已移除（见类型注释：它是放大模糊的根因），位置改为逐节点
        // 直接算屏幕坐标。这里只剩「拖拽时禁掉隐式动画」。
        //
        // 而且这个禁用**必须收窄到拖拽期**：v2.11.8 之前是无条件 `$0.animation = nil`，它会连坐
        // 掉子树里所有动画 —— 槽位节点的扇形展开（spring）正是子树里的动画，无条件禁用时它会
        // 变成一帧到位的硬切，看起来像"动画没写"。
        .transaction { t in
            if draggingNodeId != nil || groupDragID != nil { t.animation = nil }
        }
        .onAppear { presenceMirror.nodes = canvas.nodes }
        .onChange(of: canvas.activeProjectId) { _ in
            retiringNodes = []; presenceMirror.nodes = canvas.nodes
        }
        .onChange(of: canvas.nodes) { nodes in
            let ids = Set(nodes.map(\.id))
            let removed = presenceMirror.nodes.filter {
                !ids.contains($0.id) && $0.kind.cardForm != .slotStack
            }
            presenceMirror.nodes = nodes
            for node in removed {
                let retired = CanvasRetiringNode(node: node, text: renderText(for: node),
                                                 path: pathLabel(for: node), attachments: renderAttachments(for: node))
                retiringNodes.append(retired)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.23) {
                    retiringNodes.removeAll { $0.id == retired.id }
                }
            }
        }
        .onPreferenceChange(CanvasGroupMeasurementPreference.self) { values in
            guard !canvas.groups.isEmpty else { return }
            let project = canvas.activeProjectId
            let sizes = values.filter { id, value in
                value.projectID == project && canvas.node(id: id)?.createdAt == value.createdAt
            }.mapValues(\.size)
            canvas.updateGroupMeasurements(sizes, projectID: project,
                allowLayout: pointerSession == nil && draggingNodeId == nil && groupDragID == nil && groupResizePreview == nil)
        }
        .onChange(of: canvas.groups) { _ in
            if pointerSession == nil && draggingNodeId == nil && groupDragID == nil && groupResizePreview == nil {
                canvas.reconcileMeasuredServerGroups()
            }
        }
        .onChange(of: groupDragID) { id in
            if id == nil && pointerSession == nil { canvas.reconcileMeasuredServerGroups() }
        }
    }

    @ViewBuilder
    private func nodeContextMenu(_ node: CanvasNode) -> some View {
        Button("复制节点") {
            if !canvas.selectedNodeIds.contains(node.id) { canvas.select(id: node.id, additive: false) }
            copyCanvasStructure()
        }
        Button("创建副本") {
            if !canvas.selectedNodeIds.contains(node.id) { canvas.select(id: node.id, additive: false) }
            copyCanvasStructure(duplicate: true)
        }
        Divider()
        Button(node.isMediaSource ? "上传 / 替换素材" : "编辑提示词") { beginEdit(node) }
        Button("节点属性") {
            canvas.select(id: node.id, additive: false)
            showInspector = true
        }
        if !node.isMediaSource {
            Button("管理入参文件") { openInputFiles(node) }
        }
        Divider()
        if node.canGenerate {
            if node.needsGenerationRecovery {
                Button("继续查询已提交任务") { recoverGeneration(node) }
            }
            Button(node.state == .idle && node.taskId == nil ? "生成" : "重新生成") {
                startGeneration(node, reusingSeed: true, restarting: true)
            }
            if case .running = node.state {
                Button("停止本地跟踪") { canvas.stopGeneration(node) }
            } else if case .queued = node.state {
                Button("停止本地跟踪") { canvas.stopGeneration(node) }
            }
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
            Button("删除选中的 \(canvas.selectedNodeIds.count) 个节点") {
                requestDelete(ids: canvas.selectedNodeIds)
            }
        } else {
            Button("删除节点") { requestDelete(ids: [node.id]) }
        }
    }

    // MARK: - hover 维持区（★ v2.11.8 五轮）

    /// 节点自身 `.onHover` 的回调：进入立刻把维持对象锁到它身上。
    ///
    /// 为什么"进入"要靠 `.onHover` 而不是也用坐标：坐标通路依赖画布那层 `.onContinuousHover`
    /// 在光标压在节点上时仍然报点（SwiftUI 里祖先的 hover 不被子视图吃掉，实测如此），但这是个
    /// 实现细节。让"进入"走视图自己的 hover，即使坐标通路哪天失效，也只是退回三轮的行为，
    /// 而不是"节点永远不响应 hover"——这种降级方向的选择在本项目吃过教训（v2.11.0 轮盘）。
    private func noteNodeHover(_ node: CanvasNode, hovering: Bool) {
        // AppKit mouse movement is the sole hover state writer. SwiftUI can
        // deliver entered/exited again when a nearby port or composer redraws.
    }

    /// 光标移动时重算维持对象。
    private func updateHoverHold(at screenPoint: CGPoint) {
        if hoveredPileID.flatMap({ controlRegions["pile-toolbar-\($0)"] })?.contains(screenPoint) != true {
            hoveredPileID = pileBody(at: screenPoint)?.id
        }
        let next = resolvedHoverHold(at: screenPoint)
        guard next != hoverHoldNodeId else {
            // 位置没变化也要把待执行的"离开"撤掉：鼠标已经回到维持区里了。
            if next != nil, hoverLeaveTask != nil {
                hoverLeaveTask?.cancel()
                hoverLeaveTask = nil
            }
            return
        }
        scheduleHoverHold(next)
    }

    func resolvedHoverHold(at screenPoint: CGPoint) -> String? {
        guard addMenu == nil, !canvasOverlayContains(screenPoint) else { return nil }
        if let hit = displayedPortHit(at: screenPoint) {
            return hit.node.id
        }
        if let node = nodeBody(at: screenPoint) { return node.id }
        if let node = interactionNode {
            let home = outputPortHome(of: node)
            if CanvasPortInteractionGeometry.follows(screenPoint, home: home, output: true, zoom: zoom) {
                return node.id
            }
        }
        let p = CanvasGeometry.canvasPoint(screen: screenPoint, pan: effectivePan, zoom: zoom)
        return CanvasNodeHover.resolve(current: hoverHoldNodeId, point: p, nodes: nodesInPaintOrder)
    }

    func updatePortHover(at point: CGPoint) {
        portMotions.prune(nodeIDs: Set(canvas.nodes.map(\.id)))
        let coveredByOverlay = canvasOverlayContains(point)
        let order = nodesInPaintOrder
        let frames = nodeScreenFrames, scale = zoom, drag = linkDrag, motions = portMotions
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element.id, $0.offset) })
        let body = pileBody(at: point) == nil ? order.last { frames[$0.id]?.contains(point) == true } : nil
        func exposed(_ node: CanvasNode) -> Bool {
            guard let body, body.id != node.id else { return true }
            return (ranks[node.id] ?? -1) > (ranks[body.id] ?? -1)
        }
        let nodes = drag.map {
            linkCandidates(from: $0.fromNodeId, reverse: $0.fromInput)
        } ?? (pointerSession == nil ? staticPortNodes : [])
        if let drag {
            hoverHoldNodeId = nodes.reversed().compactMap { node -> (CanvasNode, CGFloat)? in
                guard let frame = frames[node.id] else { return nil }
                let home = CGPoint(x: (drag.fromInput ? frame.maxX : frame.minX)
                    + (drag.fromInput ? 37 : -37) * scale, y: frame.midY)
                guard exposed(node) && !coveredByOverlay
                    && (frame.contains(point)
                        || CGRect(x: home.x - 40 * scale, y: home.y - 40 * scale,
                                  width: 80 * scale, height: 80 * scale).contains(point)) else { return nil }
                return (node, hypot(point.x - home.x, point.y - home.y))
            }.min { $0.1 < $1.1 }?.0.id
        }
        var active: Set<String> = []
        let hovered = hoverHoldNodeId, outputs = drag.map { [$0.fromInput] } ?? [false, true]
        for node in nodes {
            guard let frame = frames[node.id] else { continue }
            for output in outputs {
                let home = CGPoint(x: (output ? frame.maxX : frame.minX) + (output ? 37 : -37) * scale, y: frame.midY)
                // Use the same node stack for following, drawing and pressing.
                let isExposed = exposed(node)
                    && (drag == nil || hovered == node.id)
                let cursor = isExposed && !coveredByOverlay ? point : nil
                motions.motion(nodeID: node.id, output: output)
                    .update(cursor: cursor, home: home, output: output, zoom: scale)
                active.insert(node.id + (output ? ":output" : ":input"))
            }
        }
        motions.reset(except: active)
    }

    /// 应用维持结果：**进入立即、离开延迟 `CanvasNodeHover.leaveDelay`**。
    ///
    /// 宽限期治的是另一半症状：鼠标快速穿过卡片之间的缝隙、或在节点边界上抖一下。录屏里
    /// f_035 展开 → f_036 收拢 → f_037 又展开，整个来回 0.33s —— 200ms 宽限期足以把它吃掉。
    private func scheduleHoverHold(_ next: String?) {
        if next == nil, hoverHoldNodeId == nil || hoverLeaveTask != nil { return }
        hoverLeaveTask?.cancel()
        hoverLeaveTask = nil
        guard next == nil else {
            hoverHoldNodeId = next
            return
        }
        let task = DispatchWorkItem {
            // 定时器到点时再确认一次：这 200ms 里鼠标可能又回来了（回来时 task 已被 cancel，
            // 这里是双保险），也可能节点被删了。
            let still = resolvedHoverHold(at: cursorScreen)
            hoverHoldNodeId = still
            hoverLeaveTask = nil
        }
        hoverLeaveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + CanvasNodeHover.leaveDelay, execute: task)
    }

    // MARK: - 手势

    /// 节点拖动。位移必须**除以 zoom** 换算回画布空间 —— 否则放大到 2x 时节点会跑得比鼠标快一倍。
    ///
    /// ★ v2.11.7 hotfix18：支持多选整组拖动。按下的节点若在选中集合内，整个选中集合一起走；
    /// 若不在（直接去拖一个未选中的节点），先把选择切成它自己 —— 这与 Figma 一致，也避免
    /// "拖一个没选中的节点，却把别处选中的一堆节点也带走"这种完全意料之外的破坏。
    func updateNodeDrag(_ node: CanvasNode, translation: CGSize, point: CGPoint) {
                // 抓手/框选模式下不允许拖动节点，否则「想框选却拖歪一个节点」会成为常态。
                guard canvas.activeTool == .select else { return }
                if draggingNodeId != node.id {
                    draggingNodeId = node.id
                    magnetState = CanvasMagnetGeometry.State()
                    // v2.16.0：抓起来的瞬间换握拳光标。
                    //
                    // 这里用 `push/pop`，悬停则由 `tapCursor` 持续更新。
                    // 拖拽是一段**有明确起止**的操作，起点在这个 if 里
                    // （只进一次），终点在 `onEnded` 里（必然执行，含归槽早退那条路径），
                    // push/pop 严格配对。悬停不同：`onHover(false)` 会在窗口失焦等情况下漏发，
                    // 那才是 push/pop 会漏栈的场景。
                    NSCursor.closedHand.push()
                    if canvas.selectedGroupID != nil || !canvas.selectedNodeIds.contains(node.id) {
                        canvas.select(id: node.id, additive: false)
                    }
                    // 一次性定下同批集合。此后不再读 selectedNodeIds：拖拽中途集合若变，
                    // 预览与提交就会对不上（预览动了 3 个、提交只写 2 个）。
                    draggingIds = canvas.selectedNodeIds.contains(node.id)
                        ? canvas.selectedNodeIds
                        : [node.id]
                }
                let proposed = CGSize(width: translation.width / zoom, height: translation.height / zoom)
                let magnet = CanvasMagnetGeometry.resolve(
                    moving: canvas.layoutNodes(draggingIds).map(\.frame),
                    stationary: canvas.layoutNodes(canvas.visibleEntityIDs.subtracting(draggingIds)).map(\.frame),
                    proposed: proposed, zoom: zoom, grid: gridSnapEnabled,
                    state: magnetState)
                dragDelta = magnet.delta
                magnetState = magnet.state
                magnetGuideX = magnet.verticalGuide
                magnetGuideY = magnet.horizontalGuide
                updateArchiveDrag(node: node, at: point)
    }

    func endNodeDrag(_ node: CanvasNode, translation: CGSize, point: CGPoint) {
                // 这条 guard 同时也是 `NSCursor` 栈的配对保证：`draggingNodeId` 只在 onChanged
                // 里紧跟 `push()` 之后被赋值，所以走到这里必然恰好 push 过一次。
                guard draggingNodeId == node.id else { return }
                defer {
                    magnetGuideX = nil; magnetGuideY = nil
                    magnetState = CanvasMagnetGeometry.State()
                }
                NSCursor.pop()
                // 归槽优先：光标松在侧栏的某个槽位块上时，这次拖拽的语义是"把内容归进那个槽位"，
                // 而**不是**移动节点位置。两件事都做的话，节点会先归槽再被挪到侧栏底下（被侧栏
                // 盖住 = 用户眼里凭空消失）。
                if archiveDrag != nil, CanvasArchiveDropGeometry.isInsidePanel(point: point, panelSize: archivePanelSize) {
                    let targets = canvas.nodes.filter { draggingIds.contains($0.id) }
                    archiveDrag = nil
                    draggingNodeId = nil
                    draggingIds = []
                    dragDelta = .zero
                    requestArchive(targets)
                    return
                }
                archiveDrag = nil
                let delta = dragDelta
                if let pile = canvas.piles.last(where: { !draggingIds.contains($0.id) && pileScreenFrame($0).contains(point) }),
                   canvas.addToPile(pile.id, entityIDs: draggingIds) {
                    hoverHoldNodeId = nil
                } else { canvas.moveNodes(ids: draggingIds, by: delta) }
                draggingNodeId = nil
                draggingIds = []
                dragDelta = .zero
    }

    // MARK: - 归槽（v2.11.8 二轮：把画布节点拖进槽位库）

    /// 侧栏在归槽模式下的尺寸。
    ///
    /// 宽度**固定取展开态**（240）而不是 `sidebarWidth`：归槽时侧栏会被强制展开（见
    /// `updateArchiveDrag`），而 `canvas.isLibraryExpanded` 的变化要等下一轮 body 才反映到
    /// `sidebarWidth` 上 —— 用它算命中会让拖入的第一帧按 44pt 判定，表现为"刚碰到侧栏那下没反应"。
    private var archivePanelSize: CGSize {
        CGSize(width: CanvasSlotLibraryPanel.width(expanded: true),
               height: max(0, viewSize.height))
    }

    /// 拖拽过程中维护归槽状态：进入侧栏 → 展开侧栏并显示分栏块；离开 → 收掉。
    private func updateArchiveDrag(node: CanvasNode, at point: CGPoint) {
        guard canvas.nodes.contains(where: { draggingIds.contains($0.id) && canArchiveToLibrary($0) }),
              CanvasArchiveDropGeometry.isInsidePanel(point: point, panelSize: archivePanelSize) else {
            if archiveDrag != nil { archiveDrag = nil }
            return
        }
        // 侧栏收起时只有 44pt 宽，10 个分栏块挤在里面既看不清也点不准，直接展开。
        if !canvas.isLibraryExpanded {
            withAnimation(Anim.reveal) { canvas.isLibraryExpanded = true }
        }
        let groupId = store.currentSpecialSlotId
        let groupName = store.specialSlots.first { $0.id == groupId }?.name ?? "当前组"
        archiveDrag = CanvasNodeArchiveDrag(title: canvas.nodeTitle(node),
                                           point: point,
                                           slotCount: max(1, store.config.slots),
                                           groupName: groupName)
    }

    /// Move complete slot contents and attach the reverse exchange to this
    /// node/edge/group history entry. A stale target never advances undo history.
    func archiveNode(_ snapshot: CanvasNode, pageID: String, groupID: String, slot: Int) throws {
        endInlineEditing()
        try store.prepareArchiveExchange()
        guard let node = canvas.node(id: snapshot.id), node.createdAt == snapshot.createdAt,
              canArchiveToLibrary(node),
              canvas.node(forGroupId: groupID, slot: slot) == nil,
              store.canvasSlotIsFree(groupId: groupID, slot: slot) else {
            throw AgentCanvasError.staleTarget
        }
        let source = CanvasArchiveTransfer.Location(storage: store.canvasStorage(groupId: node.groupId),
                                                   groupID: node.groupId, slot: node.slot)
        let target = CanvasArchiveTransfer.Location(storage: store.canvasStorage(groupId: groupID),
                                                   groupID: groupID, slot: slot)
        let transfer = try CanvasArchiveTransfer.begin(source: source, target: target, pageID: pageID)
        store.refreshArchivedSlots([source, target])
        let exchange: (Bool) throws -> Void = { [weak store] undo in
            guard let store else { throw AgentCanvasError.unavailable }
            try store.prepareArchiveExchange()
            try transfer.exchange(undo: undo)
            store.refreshArchivedSlots([source, target])
        }
        guard canvas.rebindNode(id: node.id, toPageId: pageID, groupId: groupID, slot: slot,
            historyExchange: (undo: { try exchange(true) }, redo: { try exchange(false) })) else {
            try exchange(true)
            throw AgentCanvasError.writeFailed
        }
        canvas.noteSlotDataChanged()
        store.transientUI.showToast("已保存到槽位 \(slot)")
    }

    /// 槽位库内的拖拽排序：交换同组两个槽位的内容，并让画布上的节点跟着换位。
    ///
    /// 节点也必须跟着换，否则"槽位 2 的节点"在交换后显示的是槽位 3 的内容 —— 而节点的身份就是
    /// `groupId#slot`，它指向哪个槽位就必须显示哪个槽位。换法是**两步改绑经过一个空号**：
    /// 直接互改会在中间态撞 id（两个节点同时叫 `g#2`），SwiftUI `ForEach` 遇到重复 id 的表现是
    /// "点 A 动 B"，且这种损坏会留在撤销栈里。
    private func handleSlotReorder(groupId: String, from: Int, to: Int) {
        guard from != to else { return }
        guard store.canvasSwapSlotContent(groupId: groupId, from, to) else {
            store.transientUI.showToast("存储繁忙，未能调整顺序")
            return
        }
        let nodeA = canvas.node(forGroupId: groupId, slot: from)
        let nodeB = canvas.node(forGroupId: groupId, slot: to)
        if let nodeA, let nodeB {
            // 借一个未被占用的槽号做中转，避开中间态撞 id。
            let occupied = canvas.occupiedSlots(inGroup: groupId)
            let parking = (1...max(store.config.slots, max(from, to) + 1)).first {
                !occupied.contains($0)
            }
            if let parking {
                canvas.rebindNode(id: nodeA.id, toPageId: nodeA.pageId, groupId: groupId, slot: parking)
                canvas.rebindNode(id: nodeB.id, toPageId: nodeB.pageId, groupId: groupId, slot: from)
                let movedId = CanvasNode.makeId(groupId: groupId, slot: parking)
                canvas.rebindNode(id: movedId, toPageId: nodeA.pageId, groupId: groupId, slot: to)
            } else {
                // 全部槽位都被节点占满，没有中转位。内容已经换好了，但节点换不了 ——
                // 与其留下一半正确的状态，不如把内容也换回去。
                store.canvasSwapSlotContent(groupId: groupId, from, to)
                store.transientUI.showToast("画布槽位已满，无法调整顺序")
                return
            }
        } else if let nodeA {
            canvas.rebindNode(id: nodeA.id, toPageId: nodeA.pageId, groupId: groupId, slot: to)
        } else if let nodeB {
            canvas.rebindNode(id: nodeB.id, toPageId: nodeB.pageId, groupId: groupId, slot: from)
        }
        canvas.noteSlotDataChanged()
        store.transientUI.showToast("已调整槽位顺序")
    }

    /// 画布空白处的左键拖拽。
    ///
    /// ★ v2.11.7 hotfix17（语义反转）：**箭头(V) 拉选区，抓手(H) 平移**。
    ///
    /// 上一版是反的（箭头也平移、框选另设一个 M 工具），理由是「平移入口只有手势一条，默认工具下
    /// 必须能挪动视图」。这条前提已经不成立了：现在平移有**中键拖动**和**滚轮**两个不依赖工具切换的
    /// 入口（见 `CanvasEventInterceptor`），左键就可以还给选区 —— 与 Figma / Sketch / Crate 网页端
    /// 一致，用户的肌肉记忆不用重学。
    ///
    /// ★ v2.11.7 hotfix21：松手时若位移**没过 click slop**，本次按下按「点空白」处理 → 取消选中。
    ///
    /// 为什么这条也要管取消选中：真正的原地单击由最底层那张 `blankClickCatcher` 的 tap 负责
    /// （见 body），但鼠标单击常常带 1~3pt 的抖动，那已经足够让这条 `minimumDistance: 1` 的手势
    /// 抢先赢下比赛、把 tap 挤掉。若这里不兜住，「点空白取消选中」就会时灵时不灵 —— 而"偶尔失效"
    /// 的交互比"一直没有"更让人不信任。
    ///
    /// 抖动同时也不该点亮选框：`marqueeStart` 改为**越过 slop 才记**，否则每次单击都会在屏幕上
    /// 闪一个 1~2pt 的选框。
    private var canvasDragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasWorkspaceView.spaceName))
            .onChanged { value in
                if canvas.activeTool == .hand {
                    panGestureDelta = value.translation
                } else {
                    if marqueeStart == nil { endInlineEditing() }
                    guard !CanvasGeometry.isClickWithoutDrag(translation: value.translation) else { return }
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
                } else if let start = marqueeStart {
                    commitMarquee(from: start, to: value.location)
                    marqueeStart = nil
                    marqueeCurrent = nil
                } else {
                    // 走到这里 = 非抓手工具、且全程没越过 slop → 一次（带抖动的）空白单击。
                    //
                    // 刻意**不**顺手关掉 inline 编辑器：正在编辑的节点里，光标移动/选词都可能把
                    // 事件带到这里，把编辑当场中断（且未保存）远比"选中框还亮着"糟糕。
                    // 编辑的退出口是 Enter / Esc，保持单一。
                    handleBlankTap()
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
            // 连续缩放：排版缩放不跟着每一格滚动走，停手后才落定（见 scheduleLayoutZoomSettle）。
            scheduleLayoutZoomSettle()
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
    func commitMarquee(from start: CGPoint, to end: CGPoint, additive: Bool? = nil) {
        let topLeftScreen = CGPoint(x: min(start.x, end.x), y: min(start.y, end.y))
        let bottomRightScreen = CGPoint(x: max(start.x, end.x), y: max(start.y, end.y))
        let topLeft = CanvasGeometry.canvasPoint(screen: topLeftScreen, pan: pan, zoom: zoom)
        let bottomRight = CanvasGeometry.canvasPoint(screen: bottomRightScreen, pan: pan, zoom: zoom)
        let rect = CGRect(x: topLeft.x,
                          y: topLeft.y,
                          width: bottomRight.x - topLeft.x,
                          height: bottomRight.y - topLeft.y)
        canvas.selectNodes(inCanvasRect: rect, additive: additive ?? NSEvent.modifierFlags.contains(.shift))
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
                // 捏合期间不重排文字（见 layoutZoom 的注释），松手后才落定。
                scheduleLayoutZoomSettle()
            }
            .onEnded { _ in
                pinchBasePan = nil
                // 松手立刻落定，不必再等防抖那 0.15s —— 手势结束是最明确的"缩放稳定"信号。
                settleLayoutZoom(to: zoom)
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

    // MARK: - ADD NODE 菜单 / 下游 + 按钮（v2.11.8）

    /// 「ADD NODE」浮层。两个入口（双击空白 / 选中节点下方的 +）共用。
    ///
    /// 菜单**不用 `.popover`**：popover 在 macOS 上会新开一个 NSWindow，它自带的箭头与系统配色
    /// 跟画布的深色浮层完全不是一路，而且新窗口会抢走 key window —— 那会打断画布的 AppKit 事件
    /// 监听（滚轮/中键路由器按 window 过滤事件），菜单一开画布就不能平移缩放了。
    @ViewBuilder
    private func addNodeMenuOverlay(size: CGSize) -> some View {
        if let request = addMenu {
            // 关闭层：铺满画布收走一切点击。少了它，点画布别处会直接落到 blankClickCatcher 上
            // （取消选中、甚至再弹一个菜单），而用户的意图只是"把这个菜单关掉"。
            // 不用 `Color.clear`：完全透明的视图在 macOS 上不参与命中测试。
            Color.black.opacity(0.001)
                .frame(width: max(size.width, 1), height: max(size.height, 1))
                .contentShape(Rectangle())
                .onTapGesture { addMenu = nil }
                .zIndex(90)

            CanvasAddNodeMenu(parentCount: request.allParentIds.count,
                              upstream: request.childNodeId != nil,
                              maxHeight: max(100, size.height - 32),
                              onPick: { choice in handleAddNode(choice, request: request) },
                              onDismiss: { addMenu = nil })
                .modifier(CanvasMenuPresence())
                .offset(x: clamp(request.screenPoint.x,
                                 min: 12,
                                 max: max(12, size.width - CanvasAddNodeMenu.width - 12)),
                        // 菜单高度按内容估的（3 项 + 标题 ≈ 168pt）。宁可估大：估小会让菜单在
                        // 窗口底部被切掉最后一项，而估大只是让它离底边远一点。
                        y: clamp(request.screenPoint.y,
                                 min: 12,
                                 max: max(8, size.height - min(CanvasAddNodeMenu.height(parentCount: request.allParentIds.count,
                                        upstream: request.childNodeId != nil), size.height - 32) - 12)))
                // Keep layout and hit regions at their final coordinates from the
                // first frame. Scaling after offset also scaled the distance from
                // the canvas origin, moving the menu and republishing every row.
                .zIndex(91)
        }
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), Swift.max(lower, upper))
    }

    func openAddMenu(atScreen screenPoint: CGPoint,
                     canvasPoint: CGPoint? = nil,
                     parentNodeId: String?,
                     parentNodeIds: [String] = [],
                     childNodeId: String? = nil) {
        // #region debug-point B-C:menu-latency-entry
        #if DEBUG
        if let endpoint = ProcessInfo.processInfo.environment["CLIPSLOTS_MENU_LATENCY_URL"], let url = URL(string: endpoint) { let now = ProcessInfo.processInfo.systemUptime; var r = URLRequest(url: url); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-menu-latency", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "C", "msg": "[DEBUG] menu entry", "data": ["uptime": now, "event": NSApp.currentEvent?.timestamp ?? 0, "referencing": parentNodeId != nil || !parentNodeIds.isEmpty, "nodes": canvas.nodes.count, "nodeBodies": CanvasRenderDiagnostics.count]]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
        endInlineEditing()
        let referencedIDs = Set(parentNodeIds + [parentNodeId, childNodeId].compactMap { $0 })
        guard referencedIDs.allSatisfy({ canvas.connectionPolicy.canConnect(nodeID: $0) }) else { return }
        let target = canvasPoint ?? CanvasGeometry.canvasPoint(screen: screenPoint, pan: effectivePan, zoom: zoom)
        let referenced = parentNodeId != nil || !parentNodeIds.isEmpty || childNodeId != nil
        let menuPoint = referenced
            ? CGPoint(x: screenPoint.x - CanvasAddNodeMenu.width / 2, y: screenPoint.y + 16) : screenPoint
        // Only the menu's opacity transitions. The canvas and its geometry
        // preferences must not inherit an animation transaction on menu open.
        addMenu = AddNodeRequest(screenPoint: menuPoint,
                                 canvasPoint: target,
                                 parentNodeId: parentNodeId,
                                 parentNodeIds: parentNodeIds,
                                 childNodeId: childNodeId)
        // #region debug-point A-D:menu-latency-commit
        #if DEBUG
        if let endpoint = ProcessInfo.processInfo.environment["CLIPSLOTS_MENU_LATENCY_URL"], let url = URL(string: endpoint) { let now = ProcessInfo.processInfo.systemUptime; var r = URLRequest(url: url); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-menu-latency", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "A", "msg": "[DEBUG] menu committed", "data": ["uptime": now, "id": addMenu?.id.uuidString ?? "", "nodeBodies": CanvasRenderDiagnostics.count]]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
        // #region debug-point B:menu-open
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7780/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-overlay-hit", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "B", "msg": "[DEBUG] menu open", "data": ["parents": addMenu?.allParentIds ?? [], "point": NSStringFromPoint(screenPoint)]]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
    }

    func handleAddNode(_ choice: CanvasAddNodeMenu.Choice, request: AddNodeRequest) {
        // #region debug-point D:menu-latency-pick
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPSLOTS_MENU_LATENCY_PROBE"] == "1", addMenu?.id == request.id, choice.isAvailable { CanvasMenuLatencyObservation.pickedAt = ProcessInfo.processInfo.systemUptime }
        if let endpoint = ProcessInfo.processInfo.environment["CLIPSLOTS_MENU_LATENCY_URL"], let url = URL(string: endpoint) { let now = ProcessInfo.processInfo.systemUptime; var r = URLRequest(url: url); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-menu-latency", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "D", "msg": "[DEBUG] menu picked", "data": ["uptime": now, "id": request.id.uuidString, "choice": choice.rawValue, "matches": addMenu?.id == request.id]]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
        // #region debug-point B:reference-menu-hit
        #if DEBUG
        if let endpoint = ProcessInfo.processInfo.environment["CLIPSLOTS_MENU_HIT_URL"], let url = URL(string: endpoint) { var r = URLRequest(url: url); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "reference-menu-hit", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "B", "msg": "[DEBUG] picked menu choice", "data": ["choice": choice.rawValue, "requestMatches": addMenu?.id == request.id, "parents": request.allParentIds]]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
        guard addMenu?.id == request.id, choice.isAvailable else { return }
        addMenu = nil
        func create(_ kind: CanvasNodeKind) {
            let previous = menuCreationTask
            let project = canvas.activeProjectId
            menuCreationTask = Task { @MainActor in
                await previous?.value
                guard canvas.activeProjectId == project else { return }
                await createNodeFromMenu(kind: kind, request: request)
            }
        }
        switch choice {
        case .text:
            // 文本节点建完直接进编辑态：用户选「文本节点」的下一个动作必然是打字，
            // 让他再双击一次纯属多余。
            create(.text)
        case .image:
            create(.image)
        case .video:
            create(.video)
        case .slot:
            // ★ v2.15.0：直接建一张空槽位卡，不再只是"展开左侧槽位库+弹提示"。
            // 不进编辑态：槽位卡的下一步动作不确定（写提示词 / 拖文件 / 连线），
            // 抢焦点到提示词框会让"拖一张图进来"多一次 Esc。
            create(.slot)
        case .upload:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.image, .movie, .plainText]
            panel.message = "选择图片、视频或文本文件添加到画布"
            let project = canvas.activeProjectId
            guard let window = inputRouter.anchorView?.window else { return }
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url, canvas.activeProjectId == project else { return }
                importCanvasResource(url, at: request.canvasPoint, parentNodeIds: request.allParentIds,
                                     childNodeId: request.childNodeId)
            }
        case .audio, .threeD, .timeline, .stage:
            break
        }
    }

    func importCanvasResource(_ url: URL, at point: CGPoint, parentNodeIds: [String] = [],
                              childNodeId: String? = nil) {
        let ext = url.pathExtension.lowercased()
        let kind: CanvasNodeKind = ["txt", "md", "csv"].contains(ext) ? .text :
            (["mov", "mp4", "m4v", "avi", "webm", "mkv"].contains(ext) ? .video : .image)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let importedText: String?
        do { importedText = kind == .text ? try String(contentsOf: url, encoding: .utf8) : nil }
        catch {
            store.transientUI.showToast("无法读取文本：\(error.localizedDescription)")
            return
        }
        guard let node = createNode(kind: kind, at: point, parentNodeId: nil, beginEditing: false,
                                    quiet: true, parentNodeIds: parentNodeIds) else { return }
        if let child = childNodeId { _ = canvas.connect(from: node.id, to: child) }
        if let importedText {
            guard store.writeCanvasSlotText(groupId: node.groupId, slot: node.slot, text: importedText) else {
                canvas.removeNodes(ids: [node.id])
                store.transientUI.showToast("文本导入失败")
                return
            }
            canvas.noteSlotDataChanged()
        } else {
            var attachment = SlotContent.SlotAttachment(name: url.lastPathComponent, type: kind == .image ? .image : .file)
            attachment.storagePath = url.path
            guard store.appendCanvasGeneratedAttachment(attachment, groupId: node.groupId, slot: node.slot) != nil else {
                canvas.removeNodes(ids: [node.id])
                store.transientUI.showToast("文件导入失败")
                return
            }
        }
        store.transientUI.showToast("已添加\(kind == .text ? "文本" : (kind == .image ? "图片" : "视频"))")
        synchronizeMediaLayouts()
    }

    /// 新建一个节点。
    ///
    /// ## ★ v2.11.8 二轮：新节点落到保留组，不再抢用户槽位
    ///
    /// 此前这里去 `activeHotkeySpecialSlotId`（当前组）里找空槽 —— 于是用户在画布上随手建三个
    /// 节点，编辑页的槽位 3/4/5 就被占了，圆盘和 Cmd+3~5 也跟着变，而那三个节点还只是草稿。
    /// 用户明确要求：**画布上没有对应槽位的独立节点归入暂存区**。
    ///
    /// 于是新建一律落到保留组，之后由用户把它拖进槽位库的某个槽位块完成"归槽"。真实槽位从此
    /// 只由用户显式指定（槽位库拖拽 / Cmd+1~0），不会再被隐式占用。
    ///
    /// ## ★ v2.13.0：落到**当前项目**的私有组
    ///
    /// 从全局唯一的「未入库」改成 `canvas.privateGroupId`（默认项目仍是 `__unfiled__`）。
    /// 两个原因：60 个槽位不再被所有项目共享（三个项目各 25 个节点就撞墙），以及"删掉整个项目"
    /// 能把它的内容一起带走。
    ///
    /// 返回 nil 表示没建成，调用方**不要**再往下写内容 —— 否则会写到一个不存在的槽位上。
    @discardableResult
    func createNode(kind: CanvasNodeKind,
                            at canvasPoint: CGPoint,
                            parentNodeId: String?,
                            beginEditing: Bool,
                            quiet: Bool = false,
                            parentNodeIds: [String] = []) -> CanvasNode? {
        let groupId = canvas.privateGroupId
        guard store.ensureCanvasPrivateGroup(id: groupId, name: canvas.activeProject.privateGroupName) else {
            store.transientUI.showToast("存储繁忙，未能新建节点")
            return nil
        }
        guard let slot = store.allocateCanvasPrivateSlot(groupId: groupId,
                                                         occupied: canvas.occupiedSlots(inGroup: groupId)) else {
            // 说清出路而不是只说失败：这条提示是用户唯一能看到的解释。
            store.transientUI.showToast("本项目「未入库」已满（60），先把一些节点拖进槽位库归档")
            return nil
        }
        let name = kind == .text ? "文本" : kind.displayName
        let result = canvas.placeSlot(pageId: store.currentPageId,
                                     groupId: groupId,
                                     slot: slot,
                                     name: name,
                                     at: canvasPoint,
                                     kind: kind,
                                     parentNodeId: parentNodeId,
                                     parentNodeIds: parentNodeIds,
                                     avoidOverlap: true)
        if beginEditing { editingNodeId = result.node.id }
        if !quiet { store.transientUI.showToast("已新建\(result.node.displayName)节点") }
        return result.node
    }

    // MARK: - Cmd+V 粘贴（v2.11.8）

    /// Cmd+V：把剪贴板变成**视口中心**的一个新节点。
    ///
    /// 位置必须是视口中心而不是画布原点：画布可以被平移到几千点之外，落在原点等于"粘贴了但看不见"。
    ///
    /// 类型优先级由 `CanvasPasteClassifier` 定（文件 > 位图 > 文本），不在这里现判 ——
    /// 剪贴板通常同时带多种表示（复制一张图常常同时有 TIFF + 文件 URL + HTML + 一段说明文字），
    /// 顺序写错就会把图片粘成一段文字。
    private func handlePaste() -> Bool {
        // 正在 inline 编辑 → 这次 Cmd+V 属于文本框（把文字粘进 prompt），不能被画布截走。
        guard editingNodeId == nil else { return false }

        if CanvasStructureClipboard.matchesPasteboard(), let capture = CanvasStructureClipboard.capture {
            return pasteCanvasStructure(capture)
        }
        let pb = NSPasteboard.general
        var fileURLs = (pb.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let text = pb.string(forType: .string)

        // 从终端 / 属性面板拷来的往往是**一行绝对路径**，剪贴板里只有纯文本、没有 file URL。
        // 存在这个文件就按文件处理，否则用户会得到一个内容是路径字符串的文本节点。
        if fileURLs.isEmpty,
           let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines),
           raw.hasPrefix("/"),
           FileManager.default.fileExists(atPath: raw) {
            fileURLs = [URL(fileURLWithPath: raw)]
        }

        // 远程图片链接：只存引用，**不下载**。下载要处理超时/重试/大小限制/证书，Cmd+V 这条
        // 同步路径没有任何地方能把失败讲清楚；存 url 型入参既无损也不阻塞。
        if fileURLs.isEmpty,
           let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           CanvasPasteClassifier.isImageFile(url) {
            guard let node = createNode(kind: .image,
                                        at: visibleCenterInCanvas(),
                                        parentNodeId: nil,
                                        beginEditing: false,
                                        quiet: true) else { return true }
            appendAttachments([SlotContent.SlotAttachment(name: url.lastPathComponent,
                                                          type: .url,
                                                          url: raw)],
                              to: node)
            store.transientUI.showToast("已粘贴图片链接为入参")
            return true
        }

        let snapshot = CanvasPasteSnapshot(fileURLs: fileURLs,
                                           hasBitmap: pb.canReadObject(forClasses: [NSImage.self], options: nil),
                                           text: text)
        guard let intent = CanvasPasteClassifier.classify(snapshot) else {
            store.transientUI.showToast("剪贴板里没有可粘贴到画布的内容")
            return true
        }

        let center = visibleCenterInCanvas()
        switch intent {
        case .textNode(let value):
            guard let node = createNode(kind: .text, at: center, parentNodeId: nil,
                                        beginEditing: false, quiet: true) else { return true }
            guard store.writeCanvasSlotText(groupId: node.groupId, slot: node.slot, text: value) else {
                store.transientUI.showToast("存储繁忙，粘贴未写入")
                return true
            }
            canvas.noteSlotDataChanged()
            store.transientUI.showToast("已粘贴文本节点")

        case .imageNodeWithFiles(let urls), .videoNodeWithFiles(let urls):
            for (index, url) in urls.enumerated() {
                let kind: CanvasNodeKind = CanvasAttachmentKind.from(fileName: url.lastPathComponent) == .video ? .video : .image
                let point = CGPoint(x: center.x + CGFloat(index) * 48, y: center.y + CGFloat(index) * 48)
                guard let node = createNode(kind: kind, at: point, parentNodeId: nil,
                                            beginEditing: false, quiet: true) else { return true }
                let atts = [SlotContent.SlotAttachment(name: url.lastPathComponent,
                                                       type: kind == .image ? .image : .file,
                                                       path: url.path)]
                appendAttachments(atts, to: node)
                synchronizeMediaLayouts()
                // #region debug-point A-B:paste-media
                #if DEBUG
                if ProcessInfo.processInfo.environment["CLIPSLOTS_MEDIA_THEME_PROBE"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7782/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-media-theme", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "A-B", "msg": "[DEBUG] pasted media", "data": ["kind": node.kind.rawValue, "frame": NSStringFromRect(canvas.node(id: node.id)!.frame), "media": atts.first.map { NSStringFromSize(CanvasMediaProbe.facts(for: $0).pixelSize ?? .zero) } ?? "", "appearance": inputRouter.anchorView?.window?.effectiveAppearance.name.rawValue ?? ""]]); URLSession.shared.dataTask(with: r).resume() }
                #endif
                // #endregion
            }
            store.transientUI.showToast("已粘贴 \(urls.count) 个素材节点")

        case .imageNodeWithBitmap:
            // 位图没有源文件，必须把字节存进附件。统一转 PNG：剪贴板给的常是 TIFF，
            // 直接存会让一张截图占好几 MB。
            guard let image = NSImage(pasteboard: pb),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                store.transientUI.showToast("剪贴板里的图片读不出来")
                return true
            }
            guard let node = createNode(kind: .image, at: center, parentNodeId: nil,
                                        beginEditing: false, quiet: true) else { return true }
            let stamp = Self.pasteStampFormatter.string(from: Date())
            appendAttachments([SlotContent.SlotAttachment(name: "粘贴图片-\(stamp).png",
                                                          type: .image,
                                                          data: png)],
                              to: node)
            synchronizeMediaLayouts()
            store.transientUI.showToast("已粘贴图片节点")
        }
        return true
    }

    private static let pasteStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// 面板与扇形卡片共用事务：保全删除字节 → 写入成功 → 记录一次历史。
    @discardableResult
    private func replaceAttachments(_ list: [SlotContent.SlotAttachment], for node: CanvasNode,
                                    addingInputs: Bool = true) -> Bool {
        guard let live = canvas.node(id: node.id), live.createdAt == node.createdAt,
              live.groupId == node.groupId, live.slot == node.slot else { return false }
        let before = store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
        if live.isMediaSource {
            // 旧文档里的多附件原样保留；本次写入只能是删除旧项或替换为一份同类素材。
            let removingOnly = list.allSatisfy { before.contains($0) } && list.count < before.count
            guard removingOnly || list.isEmpty || (list.count == 1 && list.allSatisfy {
                if live.kind == .video { return $0.canvasIsVideoLike }
                if $0.canvasIsImageLike { return true }
                // 保留既有 Cmd+V 图片链接功能；链接仍只存引用，不在此处下载。
                return $0.type == .url && $0.url.flatMap { URL(string: $0) }.map(CanvasPasteClassifier.isImageFile) == true
            }) else { return false }
        }
        guard before != list else { return true }
        let token = UUID().uuidString
        let remaining = Set(list.map(\.id))
        let removed = before.filter { !remaining.contains($0.id) }
        let copied = Set(store.copyCanvasAttachmentBinsToStash(
            groupId: node.groupId, slot: node.slot, ids: removed.map { $0.id.uuidString }, token: token))
        let required = removed.filter {
            $0.storageFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
        guard required.allSatisfy({ copied.contains($0.id.uuidString) }) else {
            store.discardCanvasAttachmentStash(token: token)
            return false
        }
        guard store.writeCanvasSlotAttachments(groupId: node.groupId, slot: node.slot, attachments: list) else {
            store.discardCanvasAttachmentStash(token: token)
            return false
        }
        let saved = store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
        canvas.recordSlotAttachmentEdit(nodeId: node.id, edit: .init(
            groupId: node.groupId, slot: node.slot, before: before, after: saved, stashToken: token),
            addingInputs: addingInputs && !live.isMediaSource)
        let updated = canvas.node(id: node.id) ?? live
        // #region debug-point B-C:input-upload-write
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPSLOTS_INPUT_UPLOAD_PROBE"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7791/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-input-upload", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "B-C", "msg": "[DEBUG] reference attachment write", "data": ["kind": node.kind.rawValue, "before": before.count, "after": saved.count, "outputCount": updated.outputAttachmentIds.count, "inputCount": inputImagePaths(for: updated).count, "preview": CanvasMediaPick.primary(node: updated, attachments: saved)?.name ?? "none"]]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
        canvas.noteSlotDataChanged()
        return true
    }

    /// 往槽位的入参列表尾部追加。
    ///
    /// 读-改-写而不是直接覆盖：这个槽位刚被新建时是空的，但"刚才"与"现在"之间用户可能已经
    /// 从别处塞了东西（比如 Agent 侧栏），覆盖会静默吃掉它们。
    private func appendAttachments(_ new: [SlotContent.SlotAttachment], to node: CanvasNode) {
        guard !new.isEmpty else { return }
        let before = store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
        var list = before
        list.append(contentsOf: new)
        guard replaceAttachments(list, for: node, addingInputs: false) else {
            store.transientUI.showToast("存储繁忙，入参未写入")
            return
        }
    }

    /// 扇形卡片的「设为入参」：把这张挪到入参列表首位。
    ///
    /// 首位不是随便定的名分 —— 缩略图、圆盘预览、生成时取的第一张入参都看列表首位，
    /// 所以"设为入参"落地成"挪到第 0 位"是这个词在本项目里唯一有实际后果的解释。
    private func promoteInput(_ node: CanvasNode, index: Int) {
        let before = store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
        var list = before
        guard list.indices.contains(index) else { return }
        guard index != 0 else {
            store.transientUI.showToast("它已经是首个入参了")
            return
        }
        // v2.16.5：入参排序改动可撤销。纯重排不丢字节，暂存 swap 为空操作。
        let item = list.remove(at: index)
        list.insert(item, at: 0)
        guard replaceAttachments(list, for: node) else {
            store.transientUI.showToast("存储繁忙，稍后再试")
            return
        }
        store.transientUI.showToast("已设为首个入参：\(item.name)")
    }

    /// 扇形卡片气泡里的「删除」：删掉这**一个入参文件**（★ v2.11.8 三轮）。
    ///
    /// 刻意**不弹确认**：用户明确要求「卡片内单张图片的删除（非整个节点删除），应该允许直接删除，
    /// 不影响节点本身」。删除只改附件列表 —— 节点、槽位正文、连线全都不动，且 `write` 路径本身
    /// 会把旧内容备份进 `.trash`（v2.10.16 起），误删有得救。要弹 Alert 的是**删节点**那条路
    /// （见 `deleteSelectedNodes`），两者语义不同，别合并。
    private func deleteInput(_ node: CanvasNode, index: Int) {
        let before = store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
        var list = before
        guard list.indices.contains(index) else { return }
        let item = list.remove(at: index)
        guard replaceAttachments(list, for: node) else {
            store.transientUI.showToast("存储繁忙，稍后再试")
            return
        }
        store.transientUI.showToast("已删除入参：\(item.name)")
    }

    // MARK: - 浮动层

    /// 左侧侧栏当前占据的宽度。其余浮动控件都要按它让位，否则会被压在侧栏底下（侧栏是不透明的）。
    var sidebarWidth: CGFloat {
        CanvasSlotLibraryPanel.width(expanded: canvas.isLibraryExpanded)
    }

    @ViewBuilder
    func libraryOverlay(size: CGSize) -> some View {
            // 左侧：贴边槽位库侧栏（Figma 风格）。
            //
            // ★ v2.11.7 hotfix18：从「左上角的浮动卡片」改为「贴住窗口左缘、上下通高的侧栏」。
            // 所以这里**不能再有 padding** —— 一点内边距就会露出后面的网格，那道缝隙正是浮动卡片
            // 与贴边侧栏观感上的全部差别。
            CanvasSlotLibraryPanel(store: store,
                                   canvas: canvas,
                                   onDragChanged: handleSlotDragChanged,
                                   onDropSlot: handleSlotDrop,
                                   archiveDrag: archiveDrag,
                                   onReorder: { groupId, from, to in
                                       handleSlotReorder(groupId: groupId, from: from, to: to)
                                   })
                .frame(width: canvas.isLibraryExpanded ? sidebarWidth : 38,
                       height: canvas.isLibraryExpanded ? size.height : 34, alignment: .topLeading)
                .clipped()
                .padding(.leading, canvas.isLibraryExpanded ? 0 : 12)
                .padding(.top, canvas.isLibraryExpanded ? 0 : 12 + TapSkin.titlebarInset)
                .canvasControlRegion("library-panel")
    }

    private func floatingLayer(size: CGSize) -> some View {
        CanvasAbsoluteLayout {

            // 左上（紧挨侧栏）：项目切换器。
            //
            // 贴在画布内容区左上角而不是 App 顶栏：项目是**画布的文档单位**，和顶栏那一排
            // 「页 / 组」不是同一维度（那两级是槽位容器），并排摆会让人以为有从属关系。
            entrySection("1-canvas-project", size: size) {
            HStack(spacing: 10) {
                CanvasProjectSwitcher(canvas: canvas,
                                      onSwitch: handleSwitchProject,
                                      onCreate: handleCreateProject,
                                      onRename: handleRenameProject,
                                      onDelete: handleDeleteProject)
                CanvasSaveProgressView(progress: canvas.saveProgress, retry: { canvas.flushSave() })
            }
                .padding(.leading, canvas.isLibraryExpanded ? sidebarWidth + 12 : 60)
                // v2.16.1: +titlebarInset —— 画布现在黑到窗口顶边，这条 chrome 要落到
                // 标题栏拖拽区下面，否则点它等于在拖窗口。
                .padding(.top, 12 + TapSkin.titlebarInset)
            }

            // 右上：连接 Agent、外观、画布 Agent 侧栏与批量生成。
            entrySection("2-canvas-actions", size: size) {
            VStack {
                HStack(spacing: 8) {
                    Spacer()
                    Button(action: connectExternalAgent) {
                        CanvasAgentPlug()
                            .stroke(style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
                            .frame(width: 20, height: 20)
                            .frame(width: 44, height: 40)
                    }
                    .buttonStyle(CanvasHeaderButtonStyle(iconOnly: true, isActive: showExternalAgent))
                    .help("连接 Agent")
                    .accessibilityLabel("连接 Agent")
                    .accessibilityIdentifier("canvas-connect-agent")
                    .canvasControlRegion("connect-agent")
                    AppAppearanceButton(compact: true, canvasPalette: true)
                        .canvasControlRegion("appearance")
                    // ★ v2.11.8：画布页的 Agent 入口紧贴「生成」左侧。
                    // 侧栏本体挂在 ContentView 的内容区（见那边的注释），这里只是开关，
                    // 因此侧栏展开后这一整排会随画布可用宽度自动左移，不需要手动补 padding。
                    Button {
                        withAnimation(Anim.transition) { agentVisible.toggle() }
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .regular))
                            .frame(width: 44, height: 40)
                    }
                    .buttonStyle(CanvasHeaderButtonStyle(iconOnly: true, isActive: agentVisible))
                    .help(agentVisible ? "收起 Agent 侧栏" : "打开 Agent 侧栏")
                    .accessibilityLabel(agentVisible ? "收起 Agent 侧栏" : "打开 Agent 侧栏")
                    .accessibilityIdentifier("canvas-agent-toggle")
                    .accessibilityAddTraits(agentVisible ? [.isSelected] : [])
                    .canvasControlRegion("agent-toggle")

                    BatchGenerationEntry(canvasHeader: true, iconOnly: size.width - sidebarWidth < 530) {
                        inputRouter.anchorView?.window?.makeFirstResponder(nil)
                        AttachmentManagerPanelController.shared.close()
                        addMenu = nil
                        showBatchGeneration = true
                    }
                    .canvasControlRegion("batch-generation")

                }
                Spacer()
            }
            .padding(.trailing, 16)
            .padding(.top, 12 + TapSkin.titlebarInset)
            }

            // 右侧：属性面板（v2.11.7 hotfix19）。
            //
            // 只在**单选**时出现，见 `CanvasStore.soleSelectedNode`。用 `if let` 而不是
            // `.opacity(0)` 隐藏：面板里的 Picker 要枚举全机字体，不显示时就不该构建。
            //
            // 位置压在生成按钮下方 52pt：两者都贴右缘，重叠会让生成按钮点不到。
            if showInspector, let sole = canvas.soleSelectedNode {
                VStack {
                    HStack {
                        Spacer()
                        CanvasInspectorPanel(canvas: canvas, node: sole)
                            .canvasControlRegion("inspector")
                    }
                    Spacer()
                }
                .padding(.trailing, 16)
                .padding(.top, 62 + TapSkin.titlebarInset)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            // 底部：工具栏。在**侧栏右侧的可见区域**里居中，不是在整个窗口里居中 ——
            // 否则侧栏一展开，工具栏看起来就是偏左的。
            entrySection("4-canvas-toolbar", size: size) {
            CanvasFloatingToolbar(canvas: canvas, activeTool: canvas.activeTool,
                                      isHistoryOpen: $showHistory,
                                      onPickSlot: {
                    // hotfix20：节点就是槽位，「放入槽位」不能再凭空造一个空节点（那会是一张
                    // 不对应任何槽位的孤儿卡片）。这里改成把左侧槽位库展开，引导用户从库里拖，
                    // 并顺手提示另一条更快的路（Cmd+1~0）。
                    _ = handleKeyAction(.newNode)
                })
            .equatable()
            .frame(width: footerToolbarFrame.width, height: footerToolbarFrame.height)
            .canvasControlRegion("canvas-footer-toolbar")
            .position(x: footerToolbarFrame.midX, y: footerToolbarFrame.midY)
            }

            // 左下：缩放控件（紧贴侧栏右侧）
            entrySection("3-canvas-navigation", size: size) {
            VStack {
                Spacer()
                HStack {
                    CanvasNavigationControls(nodes: canvas.nodes.map { node in
                        guard draggingIds.contains(node.id) else { return node }
                        var preview = node
                        preview.x += dragDelta.width; preview.y += dragDelta.height
                        return preview
                    }, projectID: canvas.activeProjectId, selectedNodeIDs: canvas.selectedNodeIds,
                        viewport: canvasContentViewport,
                        saveStatus: .saved, saveProgress: canvas.saveProgress, pan: $pan, zoom: $zoom,
                        showMap: $showMiniMap, showEdges: $showCanvasEdges, gridSnap: $gridSnapEnabled,
                        onZoom: { target in
                            let anchor = CGPoint(x: canvasContentViewport.midX, y: canvasContentViewport.midY)
                            pan = CanvasGeometry.panForAnchoredZoom(anchorScreen: anchor, pan: pan,
                                                                  oldZoom: zoom, newZoom: target)
                            zoom = target
                        },
                        onFit: { fitToContent(size: size) },
                        onViewportEnd: { canvas.updateViewport(pan: pan, zoom: zoom) },
                        onSave: { canvas.flushSave() },
                        onAgent: { withAnimation(Anim.transition) { agentVisible = true } })
                    Spacer()
                }
            }
            .padding(.leading, sidebarWidth + 14)
            .padding(.bottom, 16)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func connectExternalAgent() {
        do {
            let project = canvas.activeProjectId
            let context = CanvasAgentContext(canvas: canvas, store: store, projectID: project)
            let turn = try context.captureTurn(supportsTools: true)
            let directory = try JSONEncoder().encode(turn.directory)
            let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/clipslots-cli")
            externalAgentContext = AgentExternalProjectContext(
                scope: try AgentArtifactScope(projectID: project, canvasID: project),
                projectTitle: canvas.projects.first(where: { $0.id == project })?.name ?? "当前项目",
                selectedContext: String(decoding: directory, as: UTF8.self), cliPath: cli.path,
                mcpReadiness: FileManager.default.isExecutableFile(atPath: cli.path)
                    ? .ready : .unavailable("尚未找到本地命令行工具"),
                region: "global", language: "zh-CN", snapshotID: turn.snapshotID)
            showExternalAgent = true
        } catch {
            store.transientUI.showToast(error.localizedDescription)
        }
    }

    @ViewBuilder var magnetGuideOverlay: some View {
        if draggingNodeId != nil {
            Path { path in
                if let x = magnetGuideX {
                    let screen = x * zoom + effectivePan.width
                    path.move(to: CGPoint(x: screen, y: canvasContentViewport.minY))
                    path.addLine(to: CGPoint(x: screen, y: canvasContentViewport.maxY))
                }
                if let y = magnetGuideY {
                    let screen = y * zoom + effectivePan.height
                    path.move(to: CGPoint(x: canvasContentViewport.minX, y: screen))
                    path.addLine(to: CGPoint(x: canvasContentViewport.maxX, y: screen))
                }
            }
            .stroke(TapSkin.accent.opacity(0.65), style: StrokeStyle(lineWidth: 0.8, dash: [4, 4]))
            .allowsHitTesting(false)
        }
    }

    // MARK: - 动作

    /// 立刻把排版缩放钉到目标值（**不带动画**）。
    ///
    /// 用于离散缩放：目标值当场就知道，所以文字直接按终值排版一次，视觉上的渐变交给节点层那个
    /// `scaleEffect(zoom / layoutZoom)`（ratio 从 `旧/新` 动画到 1）。
    ///
    /// `withTransaction` 里把 animation 显式清成 nil 是必须的：这个函数经常在 `withAnimation`
    /// 的调用点附近执行，一旦被外层事务捕获，卡片的宽高字号就会跟着动画逐帧变 —— 那正是要修的抖动。
    private func settleLayoutZoom(to value: CGFloat) {
        zoomSettleWork?.cancel()
        zoomSettleWork = nil
        // ★ 三轮 hotfix2：不再把排版缩放钉到"任意实数 zoom"，而是钉到 `CanvasZoomLayout` 的档位。
        //
        // 二轮那版（`layoutZoom = value`）在鼠标滚轮下等于每一格都重排一次文字，因为滚轮事件是
        // 离散且稀疏的，每一格之间都会走完 0.15s 防抖被当成"已停手"。量化 + 迟滞后，同一档内的
        // 多次缩放**一次都不重排**（下面那个 guard 直接返回）。理由与代价见 CanvasZoomLayout。
        // ★ v2.11.9（用户：「放大看文字开始模糊」）：落定时钉到**精确 zoom**，不再量化到档位。
        //
        // 档位量化的代价此前被低估了：`layoutZoom = floorBucket(zoom)` 意味着**静息态也留着**一个
        // 最大 1.26 倍的残差 `scaleEffect(zoom / layoutZoom)`。卡片、边框、以及文字都是先按
        // `layoutZoom` 光栅化、再被这个残差放大 —— 于是任何落在两档之间的缩放（150% → 档位
        // 1.26，残差 1.19）静息时看到的就是一张被拉大 19% 的位图。文字更惨：它还多走了一道
        // `canvasScreenFixedText(textCounter)`（counter = layoutZoom / zoom < 1）—— 先缩小光栅化、再放大回去，
        // 两次重采样叠在一起，正是用户看到的“字发虚”。
        //
        // 钉精确值后：残差 ≡ 1，`textCounterScale` 也 ≡ 1，静息态严格 1:1 逐像素清晰。
        // 这**不是**退回二轮的“每一格都重排”：重排仍只发生在停手之后（连续手势期间
        // `layoutZoom` 照旧冻结，见 `scheduleLayoutZoomSettle`），下面那道 0.5% 死区又吃掉了
        // 浮点噪声带来的无意义重排。代价是离散滚轮每一格会重排一次文字 —— 而在八轮
        // “屏幕字号恒定”之后这本来就是**必然**的：卡片变宽而字号不变，每行能装的字数真的变了。
        // ★★ v2.11.13：排版尺度已是常量（`layoutZoom` 现在是 `layoutBaseScale`），
        // "落定后重排一次"这件事本身被取消了 —— 它正是用户看到的"停手瞬间文字跳一下"。
        // 保留函数壳是因为调用点散在离散缩放/手势结束/适应内容等七八处，全删容易漏。
        _ = max(0.01, value)
    }

    /// 连续缩放（捏合 / Cmd+滚轮）停手后再落定排版缩放。
    ///
    /// 期间 `layoutZoom` 保持不动 → 文字一次都不重排；`scaleEffect` 的 ratio 跟着手势实时变化，
    /// 所以手感仍然是连续的，只是过程中略软。
    ///
    /// ★ 三轮 hotfix2：防抖 0.15s → `CanvasZoomLayout.settleDelay`(0.32s)，并且落定时走档位量化。
    /// 单靠防抖修不掉抖动 —— 鼠标滚轮相邻两格常隔 0.15~0.3s，每一格都会被判成"停手"然后重排一次。
    private func scheduleLayoutZoomSettle() {
        zoomSettleWork?.cancel()
        let work = DispatchWorkItem { settleLayoutZoom(to: zoom) }
        zoomSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CanvasZoomLayout.settleDelay, execute: work)
    }

    /// 按钮缩放以**视图中心**为锚点（没有正在移动的光标可依据时，中心是唯一合理选择）。
    private func applyZoomStep(_ factor: CGFloat, size: CGSize) {
        let anchor = CGPoint(x: size.width / 2, y: size.height / 2)
        let target = CanvasGeometry.clampZoom(zoom * factor)
        let newPan = CanvasGeometry.panForAnchoredZoom(anchorScreen: anchor, pan: pan, oldZoom: zoom, newZoom: target)
        settleLayoutZoom(to: target)
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
        settleLayoutZoom(to: 1)
        withAnimation(Anim.transition) {
            pan = newPan
            zoom = 1
        }
        canvas.updateViewport(pan: newPan, zoom: 1)
    }

    private func fitCreatedWorkflow(size: CGSize) {
        guard let request = canvas.workflowFitRequest, size.width > 0, size.height > 0,
              !canvas.nodes.isEmpty else { return }
        fitToContent(size: size)
        canvas.completeWorkflowFit(request)
    }

    private func fitToContent(size: CGSize, selectionOnly: Bool = false) {
        guard !canvas.nodes.isEmpty else {
            settleLayoutZoom(to: 1)
            withAnimation(Anim.transition) { pan = .zero; zoom = 1 }
            canvas.updateViewport(pan: .zero, zoom: 1)
            return
        }
        let targetIDs = selectionOnly ? canvas.expandedNodeIDs(canvas.selectedNodeIds) : Set(canvas.nodes.map(\.id))
        let targets = canvas.nodes.filter { targetIDs.contains($0.id) && !canvas.piledMemberIDs.contains($0.id) }
        let targetPiles = canvas.piles.filter { !targetIDs.isDisjoint(with: $0.memberIDs) }
        guard !targets.isEmpty || !targetPiles.isEmpty else { return }
        let containers = canvas.groups.filter {
            selectionOnly ? $0.id == canvas.selectedGroupID : !targetIDs.isDisjoint(with: canvas.groupMemberIDs($0.id))
        }.compactMap { CanvasGroupGeometry.frame($0, nodes: canvas.nodes) }
        let bounds = CanvasGeometry.bounds(of: targets.map(\.frame) + containers
            + targetPiles.map { CanvasPileGeometry.frame($0, nodes: canvas.nodes).insetBy(dx: -56, dy: -24) })
        let includesGroup = canvas.groups.contains { !targetIDs.isDisjoint(with: canvas.groupMemberIDs($0.id)) }
        let composerSpace: CGFloat = targets.contains(where: { $0.kind.isMediaNode }) ? 240 : 0
        let available = CGSize(width: max(100, size.width - sidebarWidth),
                               height: max(100, size.height - (includesGroup ? 190 : 110) - composerSpace))
        var fit = CanvasGeometry.fitTransform(contentBounds: bounds, viewSize: available)
        fit.pan.width += sidebarWidth
        fit.pan.height += includesGroup ? 110 : 45
        settleLayoutZoom(to: fit.zoom)
        // Persist before opening the view animation transaction. Publishing
        // during it forces SwiftUI to synchronously flush the new node tree.
        canvas.updateViewport(pan: fit.pan, zoom: fit.zoom)
        if !passiveBatchFit { viewportFitAnimation = UUID() }
        pan = fit.pan
        zoom = fit.zoom
    }

    private func handleSlotDragChanged(_ payload: CanvasSlotDragPayload?, at point: CGPoint) {
        if let payload {
            let title = payload.isGroup ? "\(payload.name) · \(payload.slots.count) 个槽位"
                : (payload.name.isEmpty ? "槽位 \(payload.slot)" : payload.name)
            ghost = (title, point)
        } else {
            ghost = nil
        }
    }

    /// 槽位库拖拽落到画布：把落点换算成画布坐标后摆上去。
    func handleSlotDrop(_ payload: CanvasSlotDragPayload, screenPoint: CGPoint) {
        ghost = nil
        guard canvasContentViewport.contains(screenPoint) else { return }
        let canvasPoint = CanvasGeometry.canvasPoint(screen: screenPoint, pan: pan, zoom: zoom)
        if payload.isGroup {
            let projectID = canvas.activeProjectId
            let storage = store.canvasStorage(groupId: payload.groupId)
            // Capture only in-memory state on the main thread. Cold reads may wait
            // for a CLI writer and must not block pointer events or canvas rendering.
            func memoryOccupied(_ slot: Int) -> Bool {
                store.canvasSlotHasUnsavedContent(groupId: payload.groupId, slot: slot)
            }
            let occupied = Set(payload.slots.filter(memoryOccupied))
            Task { @MainActor in
                let prepared: (Set<Int>, SlotConnectionMap, [Int: SlotContent]) = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        var texts: [Int: SlotContent] = [:]
                        let diskOccupied = Set(payload.slots.filter {
                            let content = storage.getOrUnknown($0, in: payload.groupId)
                            if let content, content.attachments.isEmpty { texts[$0] = content }
                            return content?.isEmpty != true
                        })
                        let map = SlotConnectionStorage.shared.load(pageId: payload.pageId, groupId: payload.groupId)
                        continuation.resume(returning: (diskOccupied, map, texts))
                    }
                }
                guard canvas.activeProjectId == projectID, !Task.isCancelled else { return }
                let slots = payload.slots.filter {
                    occupied.contains($0) || prepared.0.contains($0) || memoryOccupied($0)
                }
                let imported = prepared.1.edges.enumerated().map { index, edge in
                    CanvasEdge(id: "slot-\(payload.groupId)-\(edge.id)",
                           fromNodeId: CanvasNode.makeId(groupId: payload.groupId, slot: edge.fromSlot),
                           toNodeId: CanvasNode.makeId(groupId: payload.groupId, slot: edge.toSlot),
                           createdAt: Date(timeIntervalSince1970: Double(index)),
                           sourceFromPort: edge.fromPort.rawValue, sourceToPort: edge.toPort.rawValue,
                           sourceColorID: edge.colorId)
                }
                let existing = Set(canvas.nodes.map(\.id))
                let fresh = slots.map { CanvasNode.makeId(groupId: payload.groupId, slot: $0) }
                    .filter { !existing.contains($0) }
                contentSnapshots.seedText(group: payload.groupId, contents: prepared.2)
                nodeMountQueue.enroll(fresh)
                nodeMountQueue.admitNative(fresh.filter { id in
                    guard let slot = slots.first(where: { CanvasNode.makeId(groupId: payload.groupId, slot: $0) == id }),
                          let content = prepared.2[slot], let text = content.plainText else { return false }
                    return !text.isEmpty
                        && CanvasFanGeometry.allCardSources(attachmentIndices: [], text: text).count <= 5
                })
                // Native hit routing reads the latest measurements directly.
                // The entry has fixed final geometry; no completion publication
                // is needed merely to repeat that geometry in the workspace.
                controlRegionBuffer.begin(duration: 0.3 + Double(fresh.count) / 60) { _ in }
                groupMounts.prepare("batch")
                if let placedGroup = canvas.placeSlotGroup(pageID: payload.pageId, groupID: payload.groupId, slots: slots,
                                     name: payload.name, edges: imported, at: canvasPoint) {
                    groupMounts.finish("batch")
                    passiveBatchFit = !fresh.isEmpty
                    guard canvas.activeProjectId == projectID, canvas.selectedGroupID == placedGroup.id,
                          canvas.groups.contains(where: { $0.id == placedGroup.id }) else { return }
                    _ = handleKeyAction(.fitSelection)
                    passiveBatchFit = false
                    await CanvasDisplayClock.shared.nextFrame()
                    guard canvas.activeProjectId == projectID,
                          canvas.groups.contains(where: { $0.id == placedGroup.id }) else { return }
                    store.transientUI.showToast("已编组 \(slots.count) 个槽位，可点击组内“生成”")
                } else {
                    groupMounts.cancel("batch")
                    nodeMountQueue.update(ids: canvas.nodes.map(\.id))
                    controlRegionBuffer.end()
                }
            }
            return
        }
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
    // internal（非 private）：`CanvasWorkspaceView+Edges` 的「复制全文」也要读它。
    func liveText(for node: CanvasNode) -> String {
        store.canvasSlotText(groupId: node.groupId, slot: node.slot) ?? ""
    }

    /// 槽位 Label 的实时值。槽位被改名 / 删名时跟着变。
    private func liveLabel(for node: CanvasNode) -> String? {
        contentSnapshots.entry(node)?.label
    }

    /// 节点卡片顶部居中的路径标识：`页面 - 槽位组 - 槽位`（v2.11.8 二轮）。
    ///
    /// 在这里拼而不是在卡片里拼：页面名与组名要查主 store，而卡片刻意不认识 store
    /// （见 `CanvasNodeCardView` 的类型注释）。拼装规则本身在 `CanvasCardText.pathLabel`，
    /// 带 smoke 断言。
    ///
    /// 暂存区的节点走 `未入库 - N`：它不属于任何用户页面，硬给它编一个页面名只会误导
    /// —— 用户会去那一页找这个节点，然后找不到。
    ///
    /// v2.13.0：判定改成"是不是保留组"。除了当前项目的私有组，还要盖住**别的项目**的私有组
    /// ——跨项目的节点不该出现在画布上，但真出现了（数据异常）也不能给它编一个不存在的页面名。
    private func pathLabel(for node: CanvasNode) -> String {
        let isUnfiled = SpecialSlotStorage.isReservedGroupId(node.groupId)
        if isUnfiled {
            return CanvasCardText.pathLabel(pageName: nil, groupName: nil,
                                            slot: node.slot, isUnfiled: true)
        }
        let pageName = store.pages.first { $0.id == node.pageId }?.name
        let groupName = store.specialSlots.first { $0.id == node.groupId }?.name
        return CanvasCardText.pathLabel(pageName: pageName, groupName: groupName, slot: node.slot)
    }

    /// 槽位的**实时**附件列表 = 画布语境下的入参文件。
    func liveAttachments(for node: CanvasNode) -> [SlotContent.SlotAttachment] {
        store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
    }

    func beginEdit(_ node: CanvasNode) {
        if node.isMediaSource {
            canvas.select(id: node.id, additive: false)
            addInputFiles(node)
            return
        }
        if composingNodeId != nil || (editingNodeId != nil && editingNodeId != node.id) {
            endInlineEditing()
        }
        canvas.select(id: node.id, additive: false)
        editingNodeId = node.id
    }

    /// inline 提示词提交（回车 / 失焦）。
    ///
    /// 只有一条路：写进**槽位主体**，编辑页立刻看到。这一步记进画布撤销栈并带上 `slotEdit`，
    /// 这样 Cmd+Z 能把槽位文本一起退回去 —— 否则撤销后画布显示旧文本、编辑页还留着新文本，
    /// 两边当场对不上。
    func commitEdit(_ node: CanvasNode, text: String) {
        editingNodeId = nil
        guard let current = canvas.node(id: node.id), current.createdAt == node.createdAt else { return }
        if node.kind == .text {
            let document = store.canvasTextDocument(groupID: node.groupId, slot: node.slot)
            document.edit(text)
            document.saveSoon()
            return
        }
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

    // MARK: - 项目（v2.13.0）

    /// 切项目。
    ///
    /// `CanvasStore.switchProject` 内部会先把当前项目落盘、再换文档、并清掉撤销栈
    /// （跨项目 Cmd+Z 会把 A 的节点写进 B 的文档，见那边的注释）。
    private func handleSwitchProject(_ id: String) {
        endInlineEditing()
        guard canvas.switchProject(to: id) else {
            if case .failed = canvas.saveStatus {
                store.transientUI.showToast("画布保存失败，请先重试保存后再切换项目")
            }
            return
        }
        hoverHoldNodeId = nil
        addMenu = nil
        linkDrag = nil
        // 视口是文档的一部分（每个项目各记自己的 pan/zoom），换文档后必须把 View 侧的
        // `@State` 同步过来 —— 否则新项目会用上一个项目的视口打开，看起来像"节点全不见了"。
        pan = canvas.pan
        zoom = canvas.zoom
        // 切过来的项目也要对一次账：它上次退出前可能删过节点而没轮到对账（崩溃 / 强退）。
        _ = reconcilePrivateContents()
        store.transientUI.showToast("已切到项目「\(canvas.activeProject.name)」")
    }

    private func handleCreateProject(_ name: String) {
        endInlineEditing()
        hoverHoldNodeId = nil
        addMenu = nil
        linkDrag = nil
        guard canvas.flushSave() else {
            store.transientUI.showToast("画布保存失败，请先重试保存")
            return
        }
        let project = canvas.createProject(name: name)
        pan = canvas.pan
        zoom = canvas.zoom
        // 私有组当场建好：不等到"第一次新建节点"时才建，是为了让删项目那条路径永远有东西可删
        // （否则会出现"组不存在 → 删除静默失败"的分支，而那条分支只有极少数项目会走到，最容易腐坏）。
        _ = store.ensureCanvasPrivateGroup(id: project.privateGroupId, name: project.privateGroupName)
        store.transientUI.showToast("已新建项目「\(project.name)」")
    }

    private func handleRenameProject(_ name: String) {
        guard canvas.renameProject(id: canvas.activeProjectId, name: name) else { return }
        store.transientUI.showToast("已重命名为「\(canvas.activeProject.name)」")
    }

    /// 删项目：画布文档 + 私有槽位组一起删，都走软删除。
    ///
    /// 顺序刻意是"先删文档/索引，再删私有组"：反过来的话，一旦删组成功而删文档失败，画布上会留着
    /// 一批指向已消失组的节点（`groupId#slot` 找不到内容 → 满屏空卡片）。而现在这个顺序下最坏的
    /// 结果是留下一个不再被任何项目引用的私有组，那是可以被下次清理收拾的静默残留，不影响使用。
    private func handleDeleteProject(_ project: CanvasProject) {
        guard let deleted = canvas.deleteProject(id: project.id) else {
            if case .failed = canvas.saveStatus {
                store.transientUI.showToast("画布保存失败，项目未删除")
            } else { store.transientUI.showToast("至少要保留一个项目") }
            return
        }
        pan = canvas.pan
        zoom = canvas.zoom
        _ = store.deleteCanvasPrivateGroup(id: deleted.privateGroupId)
        store.transientUI.showToast("已删除项目「\(deleted.name)」（内容可在回收站恢复）")
    }

    // MARK: - 删除节点

    /// 键盘与右键菜单共用直接删除入口；节点、连线和私有内容仍可共同撤销。
    private func requestDelete(ids: Set<String>) {
        // #region debug-point C:delete-request
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPSLOTS_REFERENCE_DELETE_PROBE"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7792/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-reference-delete", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "C", "msg": "[DEBUG] delete request", "data": ["targets": ids.sorted(), "referrers": CanvasNodeDeletion.brokenLinks(deleting: ids, nodes: canvas.nodes, edges: canvas.edges).referrers.count]]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
        let targets = canvas.expandedNodeIDs(ids)
        guard !targets.isEmpty else { return }
        performDelete(ids: targets)
    }

    /// 删除及附件暂存属于同一次操作，Cmd+Z 原样恢复。
    private func performDelete(ids: Set<String>) {
        let count = canvas.nodes.filter { ids.contains($0.id) }.count
        guard count > 0 else { return }
        endInlineEditing()
        guard store.flushCanvasTextDocuments() else { return }
        if let playingID = inlinePlayback.nodeID, ids.contains(playingID) { inlinePlayback.stop() }
        canvas.removeNodes(ids: ids)
        // ★ v2.14.0：画布私有内容**当场**跟着节点消失（用户原话：「在画布中删除应该就消失了才可以」、
        // 「暂存区还是不会同步删除」）。内容被搬进不可见的撤销暂存区而不是留在原地：
        // 用户视角是"删掉了"，Cmd+Z 视角是"还在，能原样搬回来"。
        _ = reconcilePrivateContents()
        store.transientUI.showToast(count == 1 ? "已删除节点" : "已删除 \(count) 个节点")
    }

    /// 让当前项目的画布私有内容与画布节点对账（v2.14.0）。
    ///
    /// 不变量是「可见内容 == 当前节点引用的内容」：多的搬进撤销暂存区（列表立刻少一条），
    /// 少的从暂存区搬回来（Cmd+Z 把节点带回来时，内容跟着回来）。规则与安全闸见 Kit 里的
    /// `CanvasPrivateReconcile`，这里只是把 store 两侧的输入接起来。
    ///
    /// 必须在**每一次节点集合可能变化之后**调用：删除、撤销、重做、切项目、进画布。漏掉任何一处，
    /// 那条路径上就会出现"内容与节点不一致"的可见 bug（v2.13.0 漏的是删除之后那一下）。
    @discardableResult
    private func reconcilePrivateContents() -> (stashed: [Int], restored: [Int]) {
        store.reconcileCanvasPrivateContents(groupId: canvas.privateGroupId,
                                             referencedByNodes: canvas.privateSlotsReferencedByNodes(),
                                             documentLoadFailed: canvas.documentLoadFailed)
    }

    /// 生成面板的 + 直接选文件；记录发起时的项目及节点身份，避免迟到的选择写到别处。
    func addInputFiles(_ node: CanvasNode) {
        guard let window = inputRouter.anchorView?.window, window.attachedSheet == nil else { return }
        endInlineEditing()
        AttachmentManagerPanelController.shared.close()
        let project = canvas.activeProjectId
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = !node.isMediaSource
        panel.prompt = node.isMediaSource ? "使用素材" : "添加"
        panel.message = node.isMediaSource
            ? (node.kind == .video ? "选择一个视频" : "选择一张图片")
            : "选择参考文件（可多选）"
        if node.isMediaSource {
            panel.allowedContentTypes = node.kind == .video ? [.movie] : [.image]
        }
        // #region debug-point A:input-picker
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPSLOTS_INPUT_UPLOAD_PROBE"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7791/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-input-upload", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "post-fix", "hypothesisId": "A", "msg": "[DEBUG] direct input picker opened", "data": ["kind": node.kind.rawValue]]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            importInputFiles(panel.urls, to: node, projectId: project)
        }
    }

    @discardableResult
    private func importInputFiles(_ urls: [URL], to node: CanvasNode, projectId: String) -> Bool {
        guard canvas.activeProjectId == projectId,
              let live = canvas.node(id: node.id), live.createdAt == node.createdAt else { return false }
        let files = urls.filter { $0.isFileURL && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        guard !files.isEmpty else { return false }
        if live.isMediaSource {
            guard urls.count == 1, files.count == 1,
                  CanvasAttachmentKind.from(fileName: files[0].lastPathComponent) == (live.kind == .video ? .video : .image) else {
                store.transientUI.showToast(live.kind == .video ? "视频节点只能上传一个视频" : "图片节点只能上传一张图片")
                return false
            }
        }
        let accesses = files.filter { $0.startAccessingSecurityScopedResource() }
        defer { accesses.forEach { $0.stopAccessingSecurityScopedResource() } }
        let added = files.map {
            SlotContent.SlotAttachment(name: $0.lastPathComponent,
                type: CanvasAttachmentKind.from(fileName: $0.lastPathComponent) == .image ? .image : .file,
                path: $0.path)
        }
        let current = store.canvasSlotAttachments(groupId: live.groupId, slot: live.slot)
        guard replaceAttachments(live.isMediaSource ? added : current + added, for: live) else {
            store.transientUI.showToast("文件未能写入，请重试")
            return false
        }
        synchronizeMediaLayouts()
        return true
    }

    /// 打开「入参文件」管理弹层。
    ///
    /// 弹层刻意**不挂在卡片上**：它要增删改附件，得拿到 `SlotStoreObservable`，而卡片视图刻意
    /// 不认识主 store（见 `CanvasNodeCardView` 的注释）。同时它也不能挂在缩放子树里 —— 附件行
    /// 在 25% 缩放下只有几个像素高，以它为锚点的 popover 箭头会指到离谱的位置。所以统一由本视图
    /// 在**未缩放的根层**上，按节点的屏幕坐标放一个 1×1 锚点来呈现。
    func openInputFiles(_ node: CanvasNode) {
        if node.isMediaSource { addInputFiles(node); return }
        guard let anchor = inputRouter.anchorView else { return }
        let project = canvas.activeProjectId
        // #region debug-point A:input-manager
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPSLOTS_INPUT_UPLOAD_PROBE"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7791/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-input-upload", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "A", "msg": "[DEBUG] input manager opened", "data": ["kind": node.kind.rawValue]]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
        canvas.select(id: node.id, additive: false)
        AttachmentManagerPanelController.shared.showCanvas(
            anchor: anchor, point: inputFilesAnchor(node),
            content: AttachmentManagerPopover(slot: node.slot, store: store, groupId: node.groupId,
                                               isCanvasContext: true,
                                               onWrite: {
                                                   guard canvas.activeProjectId == project else { return false }
                                                   return replaceAttachments($0, for: node)
                                               }),
            slot: node.slot) {
                inputFilesNodeId = nil
                canvas.noteSlotDataChanged()
            }
        inputFilesNodeId = node.id
    }

    /// 入参文件弹层的锚点在屏幕坐标里的位置（节点卡片底边中点）。
    ///
    /// ★ v2.11.17：算完再夹到可视区内。节点可以被平移到窗口外（甚至负坐标），锚点跟着跑出屏幕后
    /// AppKit 只能把 popover 硬塞到屏幕边上 —— 表现又变成"弹层出现在莫名其妙的地方"。
    /// 夹一下之后最坏情况是"贴着窗口边、离节点近的那一侧"，语义仍然成立。
    /// 左边界额外让开侧栏：弹层压在侧栏上就是这次要修的那个观感。
    private func inputFilesAnchor(_ node: CanvasNode) -> CGPoint {
        let center = CGPoint(x: node.x + node.width / 2, y: node.y + node.height)
        let raw = CanvasGeometry.screenPoint(canvas: center, pan: effectivePan, zoom: zoom)
        return CanvasGeometry.clampedPopoverAnchor(raw,
                                                  viewSize: viewSize,
                                                  leftInset: sidebarWidth)
    }

    // MARK: - 键盘 / 槽位命令

    /// 键盘动作。返回 true = 已消费，事件不再下派给系统。
    func handleKeyAction(_ action: CanvasKeyBinding.Action) -> Bool {
        // #region debug-point B-C:key-action
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPSLOTS_REFERENCE_DELETE_PROBE"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7792/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-reference-delete", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "B-C", "msg": "[DEBUG] canvas key action", "data": ["action": String(describing: action), "editing": editingNodeId ?? "", "composing": composingNodeId ?? "", "selected": canvas.selectedNodeIds.sorted()]]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
        if previewTarget != nil {
            if action == .cancel { previewTarget = nil }
            return true
        }
        if pileGalleryID != nil {
            if action == .cancel { requestPileGalleryClose() }
            return true
        }
        // 添加菜单是当前操作目标；快捷键不能穿透删除或撤销后方节点。
        if addMenu != nil, action != .cancel { return true }
        switch action {
        case .selectTool:
            canvas.activeTool = .select
            return true
        case .handTool:
            canvas.activeTool = .hand
            return true
        case .newNode:
            openAddMenu(atScreen: CGPoint(x: (viewSize.width + sidebarWidth) / 2,
                                         y: viewSize.height / 2), parentNodeId: nil)
            return true
        case .selectAll:
            canvas.selectedGroupID = nil
            canvas.selectedEdgeId = nil
            canvas.selectedNodeIds = canvas.visibleEntityIDs
            return true
        case .pile:
            finishGroupTitle()
            createSelectionPile()
            return true
        case .group:
            finishGroupTitle()
            if canvas.groupNodes(canvas.selectedNodeIds) == nil {
                store.transientUI.showToast("请选择 2–50 个节点编组")
            }
            return true
        case .ungroup:
            canvas.ungroupNodes(canvas.selectedNodeIds)
            return true
        case .fitContent, .fitSelection:
            fitToContent(size: viewSize, selectionOnly: action == .fitSelection)
            return true
        case .delete:
            // 正在 inline 编辑时退格属于文本编辑（`CanvasInputRouter` 已按 firstResponder 拦掉一层，
            // 这里再兜一次：焦点抢占存在一帧空窗，那一帧误删是不可挽回的）。
            guard editingNodeId == nil else { return false }
            // 选中的是一条连线时，Delete 的语义是「断开它」（v2.12.0）。两种选中互斥
            // （见 `CanvasStore.clearSelection`），所以这里不会出现"该删哪个"的歧义。
            if let edgeId = canvas.selectedEdgeId, canvas.selectedNodeIds.isEmpty {
                disconnectEdge(edgeId)
                return true
            }
            guard !canvas.selectedNodeIds.isEmpty else {
                store.transientUI.showToast("请先选中要删除的节点或连线")
                return true
            }
            // 有下游引用也直接删除，断开的连线随节点一起进入撤销历史。
            requestDelete(ids: canvas.selectedNodeIds)
            return true

        case .undo:
            guard editingNodeId == nil else { return false }
            if let entry = canvas.undo() {
                // 撤销把节点带回来了 → 把它的内容从暂存区搬回槽位（反之，撤销掉一次"新建节点"
                // 会让内容重新变成无主的，同一次对账顺手搬进暂存区）。
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

        case .paste:
            return handlePaste()

        case .copy:
            return copyCanvasStructure()
        case .duplicate:
            return copyCanvasStructure(duplicate: true)

        case .cancel:
            if editingGroupID != nil { editingGroupID = nil; return true }
            if pointerSession != nil { cancelCanvasPointer(); return true }
            // v2.11.8：把「编辑态卡住」收掉。
            //
            // 现场：新建文本节点会直接进 inline 编辑态；此时点画布空白处，SwiftUI 侧的
            // `Color.clear` 并不会把 NSTextView 的 first responder 抢走，于是编辑器失去了
            // 键盘焦点、`editingNodeId` 却还挂着 —— 节点永远显示编辑框，而下游 `+` 号、删除、
            // 撤销全都以 `editingNodeId == nil` 为前提，一起失效。用户唯一的印象是"画布卡住了"。
            //
            // 真正在编辑器里按 Esc 走不到这里（`CanvasInputRouter` 按 firstResponder 放行给
            // 文本系统），所以这条分支只处理"焦点已丢、状态还在"的残留态。
            if editingNodeId != nil || composingNodeId != nil {
                endInlineEditing()
                return true
            }
            if addMenu != nil {
                addMenu = nil
                return true
            }
            if linkDrag != nil { linkDrag = nil; return true }
            if canvas.selectedEdgeId != nil { canvas.clearSelection(); return true }
            if !canvas.selectedNodeIds.isEmpty {
                canvas.clearSelection()
                return true
            }
            return false

        case .none:
            return false
        }
    }

    /// 结束 inline 编辑（点空白 / Esc 残留态）。
    ///
    /// 焦点还在编辑器上时走 `makeFirstResponder(nil)`：这会触发 `textDidEndEditing`，编辑器
    /// 沿既有的"失焦保存"路径把草稿写回槽位，不会丢用户刚打的字。焦点已经不在编辑器上（卡住态）
    /// 时没有可触发的失焦事件，直接清状态。
    func endInlineEditing() {
        guard editingNodeId != nil || composingNodeId != nil else { return }
        let window = inputRouter.anchorView?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let responder = window?.firstResponder as? NSTextView, responder.isEditable {
            window?.makeFirstResponder(nil)
        }
        editingNodeId = nil
        composingNodeId = nil
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
        // 走 Kit 里的纯函数（而不是在这儿再算一遍）：Cmd+1~0 与 Cmd+V 都要这个落点，
        // 两处各算一份就是"快捷键建的节点偏半格、粘贴的不偏"这类无人写测试的分叉。
        return CanvasSpawnGeometry.viewportCenter(pan: effectivePan,
                                                 zoom: zoom,
                                                 viewportSize: CGSize(width: max(0, viewSize.width - sidebarWidth),
                                                                      height: viewSize.height),
                                                 viewportOrigin: CGPoint(x: sidebarWidth, y: 0))
    }
}

// MARK: - 点阵背景

/// 画布底纹：**点阵**（v2.16.0 由实线网格改成点阵）。
///
/// ## 为什么从线改成点
///
/// 实线网格会把画布切成一格一格的**表格**，视线沿着线条跑，节点变成"填在格子里的东西"。
/// TapNow 用点阵：点之间没有连续路径，眼睛抓不住方向，于是底纹退回成纯粹的"这里有一片空间"
/// 的质感提示，注意力全部留给内容。实测 TapNow 就是点阵，间距 16pt、点径约 1.2pt、色约 `#4A4A4A`。
///
/// 还有一条实际好处：线网格在缩小时，相邻两条线会落进同一个物理像素并互相叠加，出现"某几条
/// 突然变粗"的摩尔纹；点阵缩小只是变稀，不会互相干涉。
///
/// ## 为什么点也**不**随缩放变小
///
/// `dotSize` 直接用屏幕点，不乘 zoom。底纹的作用是给出一个恒定的"纸面颗粒"参照——缩小时如果
/// 点也跟着缩，到 0.4x 就全部消失，画布会变成一块什么都没有的黑布，用户失去"我还在画布上，
/// 只是拉远了"的感知。间距跟着缩（由 `gridScreenStep` 在 14…96pt 之间按 2 的幂折叠），
/// 点径不跟着缩，是这两个需求的交点。
struct CanvasGridBackground: View {
    typealias TapSkin = CanvasSkin
    let pan: CGSize
    let zoom: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let step = CanvasGeometry.gridScreenStep(base: TapSkin.gridStep, zoom: zoom)
            let xs = CanvasGeometry.gridLineOffsets(viewLength: canvasSize.width,
                                                    panComponent: pan.width, step: step)
            let ys = CanvasGeometry.gridLineOffsets(viewLength: canvasSize.height,
                                                    panComponent: pan.height, step: step)
            // 上限保护：xs × ys 在极端窗口尺寸下可能上万，`Path` 里塞太多子路径会拖慢每帧。
            // 4000 个点已经远超"看得出是点阵"所需（1440×900 的窗口按 16pt 间距约 5000 个，
            // 到这个量级视觉上早已饱和，少画一些完全看不出来）。
            let budget = 4000
            var path = Path()
            var drawn = 0
            let d = TapSkin.gridDotSize
            outer: for y in ys {
                for x in xs {
                    path.addEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
                    drawn += 1
                    if drawn >= budget { break outer }
                }
            }
            context.fill(path, with: .color(TapSkin.gridDot))
        }
    }
}

#if DEBUG
extension CanvasWorkspaceView {
    @MainActor func runInputUploadProbe(directory: URL) async {
        if ProcessInfo.processInfo.environment["CLIPSLOTS_REFERENCE_DELETE_PROBE"] == "1" {
            await runReferenceDeleteProbe(directory: directory)
            return
        }
        var passed = 0
        var failures: [String] = []
        let run = ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix"
        func check(_ condition: Bool, _ label: String, data: [String: Any] = [:]) {
            if condition { passed += 1 } else { failures.append(label) }
            // #region debug-point A-C:input-upload-probe
            var r = URLRequest(url: URL(string: "http://127.0.0.1:7791/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-input-upload", "runId": run, "hypothesisId": "A-C", "msg": "[DEBUG] \(label)", "data": data.merging(["passed": condition]) { _, new in new }]); URLSession.shared.dataTask(with: r).resume()
            // #endregion
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(500)) }
        guard let window = inputRouter.anchorView?.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        canvas.isLibraryExpanded = false
        agentVisible = false
        pan = CGSize(width: 80, height: 65)
        zoom = 0.8
        if ProcessInfo.processInfo.environment["CLIPSLOTS_MEDIA_ROLE_PROBE"] == "1" {
            func click(_ rect: CGRect) async {
                guard let anchor = inputRouter.anchorView else { return }
                let point = anchor.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!, atStart: false)
                    try? await Task.sleep(for: .milliseconds(100))
                }
                await settle()
            }
            func screenshot(_ name: String) {
                if let root = window.contentView, let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                    root.cacheDisplay(in: root.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
                }
            }
            let request = AddNodeRequest(screenPoint: .zero, canvasPoint: CGPoint(x: 400, y: 250), parentNodeId: nil)
            addMenu = request
            handleAddNode(.image, request: request)
            guard let source = canvas.soleSelectedNode else { return }
            await settle()
            check(source.isMediaSource && !source.canGenerate, "blank-menu image is persistent source")
            if let region = controlRegions["source-upload-\(source.id)"] {
                await click(region)
                let picker = NSApp.windows.compactMap { $0 as? NSOpenPanel }.first { $0.isVisible }
                check(picker != nil && picker?.allowsMultipleSelection == false, "source upload click opens single picker")
                check(picker?.allowedContentTypes == [.image], "source picker restricts images")
                check(!AttachmentManagerPanelController.shared.isVisible, "source picker skips manager")
                picker?.cancel(nil)
                await settle()
            } else { check(false, "source upload control exists") }
            let photo = directory.appendingPathComponent("fixture.png")
            let movie = directory.appendingPathComponent("fixture.mp4")
            let portrait = directory.appendingPathComponent("portrait.png")
            let image = NSImage(size: CGSize(width: 120, height: 240))
            image.lockFocus()
            NSColor.systemTeal.setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: 120, height: 240)).fill()
            image.unlockFocus()
            if let data = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                try? png.write(to: portrait)
            }
            check(importInputFiles([photo], to: source, projectId: canvas.activeProjectId), "source upload succeeds")
            await settle()
            check(previewableMedia(of: canvas.node(id: source.id)!) != nil, "blank-menu image displays uploaded source")
            check(composerFrame == nil, "source has no generation composer")
            check(canvas.node(id: source.id)?.ratio == "16:9", "source image adopts native aspect ratio")
            check(inputAttachments(for: canvas.node(id: source.id)!).isEmpty, "source file is not a local generation input")
            check(startGeneration(source) == nil, "source cannot submit generation")
            let original = liveAttachments(for: source)
            let history = canvas.history.cursor
            check(!importInputFiles([movie], to: source, projectId: canvas.activeProjectId), "image source rejects video")
            check(!importInputFiles([photo, photo], to: source, projectId: canvas.activeProjectId), "source rejects multiple files")
            check(canvas.history.cursor == history && liveAttachments(for: source) == original, "rejected source uploads are atomic")
            let next = AddNodeRequest(screenPoint: .zero, canvasPoint: CGPoint(x: 900, y: 250),
                                      parentNodeId: nil, parentNodeIds: [source.id])
            addMenu = next
            handleAddNode(.image, request: next)
            guard let generated = canvas.soleSelectedNode else { return }
            check(generated.mediaRole == .generation && generated.canGenerate, "parent-array menu creates generation node")
            check(resolveEdgeInputs(for: generated).assetPaths.count == 1, "downstream receives uploaded source")
            check(importInputFiles([photo], to: generated, projectId: canvas.activeProjectId), "generation upload succeeds")
            check(previewableMedia(of: canvas.node(id: generated.id)!) == nil, "generation input stays out of main preview")
            check(importInputFiles([portrait], to: source, projectId: canvas.activeProjectId), "source replacement succeeds")
            await settle()
            let replaced = liveAttachments(for: source)
            let sourceNow = canvas.node(id: source.id)!
            check(replaced.count == 1 && replaced.first?.name == "portrait.png", "replacement leaves one source file")
            check(sourceNow.ratio == "1:2" && abs(sourceNow.width / sourceNow.height - 0.5) < 0.001,
                  "replacement adopts portrait geometry")
            check(sourceNow.inputAttachmentIds.isEmpty, "replacement retains source identity")
            check(resolveEdgeInputs(for: generated).assetPaths == [replaced[0].canvasLocalURL!.path],
                  "downstream follows replacement source")
            canvas.undo()
            await settle()
            check(liveAttachments(for: source).map(\.id) == original.map(\.id)
                  && liveAttachments(for: source).first?.resolveData() == (try? Data(contentsOf: photo)),
                  "source undo restores original identity and bytes")
            check(canvas.node(id: source.id)?.ratio == "16:9", "source undo restores original ratio")
            canvas.redo()
            await settle()
            check(liveAttachments(for: source).map(\.id) == replaced.map(\.id)
                  && liveAttachments(for: source).first?.resolveData() == (try? Data(contentsOf: portrait)),
                  "source redo restores replacement identity and bytes")
            canvas.select(id: source.id, additive: false)
            await settle()
            screenshot("canvas-source-image.png")
            commitEdit(generated, text: "保持构图，暖色调")
            if let task = startGeneration(canvas.node(id: generated.id)!) {
                await task.value
                check(previewableMedia(of: canvas.node(id: generated.id)!)?.canvasIsImageLike == true,
                      "image generation displays only generated output")
                let commands = (try? String(contentsOf: directory.appendingPathComponent("commands.jsonl"))) ?? ""
                check(commands.contains(replaced[0].canvasLocalURL!.path), "mock Crate receives actual uploaded source path")
                let output = previewableMedia(of: canvas.node(id: generated.id)!)?.id
                check(importInputFiles([portrait], to: generated, projectId: canvas.activeProjectId), "generation accepts further input")
                check(previewableMedia(of: canvas.node(id: generated.id)!)?.id == output, "generation input preserves output")
            } else { check(false, "source-connected image generation starts") }
            let videoRequest = AddNodeRequest(screenPoint: .zero, canvasPoint: CGPoint(x: 550, y: 600), parentNodeId: nil)
            addMenu = videoRequest
            handleAddNode(.video, request: videoRequest)
            guard let sourceVideo = canvas.soleSelectedNode else { return }
            check(sourceVideo.isMediaSource, "blank-menu video creates source")
            await settle()
            addInputFiles(sourceVideo)
            await settle()
            let videoPicker = NSApp.windows.compactMap { $0 as? NSOpenPanel }.first { $0.isVisible }
            check(videoPicker != nil && videoPicker?.allowsMultipleSelection == false
                  && videoPicker?.allowedContentTypes == [.movie], "video picker selects one movie")
            videoPicker?.cancel(nil)
            await settle()
            check(!importInputFiles([photo], to: sourceVideo, projectId: canvas.activeProjectId), "video source rejects image")
            check(importInputFiles([movie], to: sourceVideo, projectId: canvas.activeProjectId), "video source upload succeeds")
            await settle()
            let videoNow = canvas.node(id: sourceVideo.id)!
            check(previewableMedia(of: videoNow)?.canvasIsVideoLike == true && videoNow.ratio == "16:9", "video source shows video with native ratio")
            check(composerFrame == nil && inputAttachments(for: videoNow).isEmpty, "video source has no generation inputs or composer")
            if let media = previewableMedia(of: videoNow) {
                check((CanvasMediaProbe.facts(for: media).duration ?? 0) > 0, "uploaded video duration is readable")
                openFullscreen(videoNow, attachment: media)
                await settle()
                check(previewTarget != nil, "uploaded video supports fullscreen preview")
                previewTarget = nil
            }
            screenshot("canvas-source-video.png")
            let originalMovie = liveAttachments(for: sourceVideo)
            var legacyVideo = videoNow
            legacyVideo.kind = .image
            legacyVideo.inputAttachmentIds = originalMovie.map { $0.id.uuidString }
            check(CanvasMediaPick.primary(node: legacyVideo, attachments: originalMovie)?.canvasIsVideoLike == true,
                  "legacy image-kind video source remains available for type migration")
            check(importInputFiles([movie], to: sourceVideo, projectId: canvas.activeProjectId), "video source can replace its movie")
            check(liveAttachments(for: sourceVideo).count == 1
                  && liveAttachments(for: sourceVideo).first?.id != originalMovie.first?.id, "video replacement retains exactly one file")
            canvas.undo()
            await settle()
            check(liveAttachments(for: sourceVideo).first?.id == originalMovie.first?.id
                  && liveAttachments(for: sourceVideo).first?.resolveData() == (try? Data(contentsOf: movie)),
                  "video replacement undo restores original bytes")
            for parent in [source.id, sourceVideo.id] {
                let childRequest = AddNodeRequest(screenPoint: .zero, canvasPoint: CGPoint(x: 1100, y: 700),
                                                 parentNodeId: nil, parentNodeIds: [parent])
                addMenu = childRequest
                handleAddNode(.video, request: childRequest)
                let child = canvas.soleSelectedNode!
                check(child.mediaRole == .generation, "media-linked menu creates video generation")
                check(importInputFiles([photo, portrait], to: child, projectId: canvas.activeProjectId), "video generation accepts multiple input images")
                check(previewableMedia(of: canvas.node(id: child.id)!) == nil, "video generation inputs stay outside preview")
                if let edge = canvas.incomingEdges(of: child.id).first {
                    _ = canvas.disconnect(edgeId: edge.id)
                    check(canvas.node(id: child.id)?.mediaRole == .generation, "disconnect preserves generation role")
                }
            }
            if let edge = canvas.incomingEdges(of: generated.id).first { _ = canvas.disconnect(edgeId: edge.id) }
            canvas.flushSave()
            let loaded = CanvasStorage(rootOverride: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLIPSLOTS_DATA_DIR"]!))
                .load(projectId: canvas.activeProjectId)
            check(loaded.nodes.first { $0.id == source.id }?.isMediaSource == true, "source role survives reload")
            check(loaded.nodes.first { $0.id == generated.id }?.mediaRole == .generation, "disconnected generation role survives reload")
            if let reloaded = loaded.nodes.first(where: { $0.id == source.id }) {
                check(CanvasMediaPick.primary(node: reloaded, attachments: replaced)?.id == replaced[0].id, "source preview survives reload")
            }
            canvas.select(id: generated.id, additive: false)
            await settle()
            screenshot("canvas-input-upload.png")
            let pasteboard = NSPasteboard.general
            let savedPasteboard = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
                let copy = NSPasteboardItem()
                for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                return copy
            }
            let previousNodes = Set(canvas.nodes.map(\.id))
            pasteboard.clearContents()
            pasteboard.writeObjects([photo as NSURL, movie as NSURL])
            _ = handlePaste()
            let pasted = canvas.nodes.filter { !previousNodes.contains($0.id) }
            check(pasted.count == 2 && Set(pasted.map { $0.kind.rawValue }) == ["image", "video"], "mixed media paste creates one node per file")
            check(pasted.allSatisfy { $0.isMediaSource && liveAttachments(for: $0).count == 1 },
                  "pasted sources each contain only one file")
            pasteboard.clearContents()
            pasteboard.setString("https://example.invalid/reference.png", forType: .string)
            _ = handlePaste()
            check(canvas.soleSelectedNode.map { liveAttachments(for: $0).count == 1 } == true,
                  "image URL paste retains its single stored reference")
            pasteboard.clearContents()
            pasteboard.writeObjects(savedPasteboard)
            try? JSONSerialization.data(withJSONObject: ["passed": passed, "failures": failures], options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"))
            await settle()
            NSApp.terminate(nil)
            return
        }
        guard let prompt = createNode(kind: .text, at: CGPoint(x: 100, y: 200),
                                      parentNodeId: nil, beginEditing: false, quiet: true) else { return }
        guard let video = createNode(kind: .video, at: CGPoint(x: 450, y: 200),
                                     parentNodeId: prompt.id, beginEditing: false, quiet: true) else { return }
        commitEdit(video, text: "镜头缓慢推进")
        canvas.select(id: video.id, additive: false)
        await settle()
        let initialHistory = canvas.history.cursor
        if let anchor = inputRouter.anchorView, let rect = composerFrame {
            let point = anchor.convert(CGPoint(x: rect.minX + 32, y: rect.minY + 32), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                NSApp.postEvent(event, atStart: false)
                try? await Task.sleep(for: .milliseconds(100))
            }
            await settle()
            check(!AttachmentManagerPanelController.shared.isVisible, "plus skips attachment manager")
            let picker = NSApp.windows.compactMap { $0 as? NSOpenPanel }.first { $0.isVisible }
            check(picker != nil, "plus directly opens native file picker")
            check(picker?.allowsMultipleSelection == true, "file picker supports multiple files")
            picker?.cancel(nil)
            AttachmentManagerPanelController.shared.close()
            await settle()
        } else { check(false, "composer exposes add reference button") }
        check(canvas.history.cursor == initialHistory && liveAttachments(for: video).isEmpty,
              "cancelling picker leaves attachments and history unchanged")
        let text = liveText(for: video)
        let photo = directory.appendingPathComponent("fixture.png")
        let previousOutput = directory.appendingPathComponent("crate_reference.png")
        let note = directory.appendingPathComponent("notes.txt")
        try? FileManager.default.copyItem(at: photo, to: previousOutput)
        try? "参考说明".write(to: note, atomically: true, encoding: .utf8)
        check(importInputFiles([photo, previousOutput, note], to: video, projectId: canvas.activeProjectId),
              "multiple reference files use upload transaction")
        await settle()
        let saved = store.canvasSlotAttachments(groupId: video.groupId, slot: video.slot)
        let current = canvas.node(id: video.id)!
        check(inputImagePaths(for: current).count == 2, "uploaded images including previous generated file are generation inputs")
        check(saved.count == 3 && current.inputAttachmentIds.count == 3, "all files have explicit input identity")
        check(canvas.history.cursor == initialHistory + 1, "multiple files create one undo transaction")
        check(current.ratio == video.ratio && current.frame == video.frame, "reference upload preserves video size and generation ratio")
        check(liveText(for: video) == text && video.outputAttachmentIds.isEmpty,
              "upload preserves prompt and output identity")
        check(previewableMedia(of: canvas.node(id: video.id)!) == nil, "input image does not replace video preview",
              data: ["preview": previewableMedia(of: canvas.node(id: video.id)!)?.name ?? "none"])
        canvas.undo()
        check(store.canvasSlotAttachments(groupId: video.groupId, slot: video.slot).isEmpty, "undo removes uploaded input")
        check(canvas.node(id: video.id)?.inputAttachmentIds.isEmpty == true, "undo removes input identity")
        canvas.redo()
        check(store.canvasSlotAttachments(groupId: video.groupId, slot: video.slot).map(\.id) == saved.map(\.id),
              "redo restores input order")
        check(store.canvasSlotAttachments(groupId: video.groupId, slot: video.slot).first?.resolveData()
              == (try? Data(contentsOf: directory.appendingPathComponent("fixture.png"))), "redo restores input bytes")
        check(canvas.node(id: video.id)?.inputAttachmentIds == current.inputAttachmentIds, "redo restores input identity")
        await settle()
        for att in saved {
            check(controlRegions["composer-input-\(att.id.uuidString)"] != nil, "composer displays \(att.name) as input")
        }
        if let region = saved.first.flatMap({ controlRegions["composer-input-\($0.id.uuidString)"] }),
           let anchor = inputRouter.anchorView {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type,
                    location: anchor.convert(CGPoint(x: region.midX, y: region.midY), to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!, atStart: false)
                try? await Task.sleep(for: .milliseconds(100))
            }
            await settle()
            check(previewTarget != nil, "native thumbnail click previews input independently")
            previewTarget = nil
            await settle()
        }
        if let root = window.contentView, let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("canvas-input-upload.png"))
        }
        check(replaceAttachments(Array(saved.reversed()), for: current), "manager can reorder inputs")
        canvas.undo()
        check(liveAttachments(for: current).map(\.id) == saved.map(\.id), "undo restores input order after reorder")
        check(replaceAttachments(Array(saved.dropFirst()), for: current), "manager can delete an input")
        canvas.undo()
        check(liveAttachments(for: current).first?.resolveData() == (try? Data(contentsOf: photo)),
              "undo deletion restores file bytes")
        check(canvas.node(id: video.id)?.inputAttachmentIds == current.inputAttachmentIds,
              "undo deletion restores reference identity")
        canvas.flushSave()
        let loaded = CanvasStorage(rootOverride: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLIPSLOTS_DATA_DIR"]!))
            .load(projectId: canvas.activeProjectId)
        if let node = loaded.nodes.first(where: { $0.id == video.id }) {
            check(node.inputAttachmentIds == current.inputAttachmentIds && CanvasMediaPick.primary(node: node, attachments: saved) == nil,
                  "reload retains inputs without creating main preview")
        } else { check(false, "saved node reloads") }
        canvas.updateNode(id: video.id) { $0.model = "seedance2-mini" }
        if let task = startGeneration(canvas.node(id: video.id)!) {
            await task.value
            let generated = canvas.node(id: video.id)!
            check(!generated.outputAttachmentIds.isEmpty && previewableMedia(of: generated)?.canvasIsVideoLike == true,
                  "mock video generation shows output as main preview")
            check(inputImagePaths(for: generated).count == 2, "generated result stays out of next input set")
            let commands = (try? String(contentsOf: directory.appendingPathComponent("commands.jsonl"), encoding: .utf8)) ?? ""
            check(inputImagePaths(for: generated).first.map { commands.contains($0) } == true,
                  "mock Crate receives uploaded first frame path")
            let output = previewableMedia(of: generated)?.id
            check(importInputFiles([photo], to: generated, projectId: canvas.activeProjectId),
                  "can add more inputs after generation")
            check(previewableMedia(of: canvas.node(id: video.id)!)?.id == output, "adding input preserves generated preview")
            canvas.undo()
            check(previewableMedia(of: canvas.node(id: video.id)!)?.id == output && inputImagePaths(for: canvas.node(id: video.id)!).count == 2,
                  "undo post-generation upload preserves output and previous inputs")
        } else { check(false, "mock generation starts") }
        importCanvasResource(photo, at: CGPoint(x: 950, y: 200))
        if let imported = canvas.soleSelectedNode, imported.id != video.id {
            let media = previewableMedia(of: imported)?.id
            check(media != nil && imported.inputAttachmentIds.isEmpty, "standalone imported image retains preview")
            check(importInputFiles([previousOutput], to: imported, projectId: canvas.activeProjectId),
                  "source image accepts replacement")
            check(previewableMedia(of: canvas.node(id: imported.id)!)?.id != media && liveAttachments(for: imported).count == 1,
                  "source replacement changes primary and keeps one file")
        }
        if let empty = createNode(kind: .image, at: CGPoint(x: 1200, y: 200),
                                   parentNodeId: prompt.id, beginEditing: false, quiet: true) {
            check(importInputFiles([photo], to: empty, projectId: canvas.activeProjectId), "empty image node accepts input")
            check(previewableMedia(of: canvas.node(id: empty.id)!) == nil, "empty image node input does not become output")
        }
        check(!importInputFiles([photo], to: current, projectId: "stale-project"), "stale project picker response is rejected")
        canvas.removeNodes(ids: [current.id])
        check(!importInputFiles([photo], to: current, projectId: canvas.activeProjectId), "deleted node picker response is rejected")
        try? JSONSerialization.data(withJSONObject: ["passed": passed, "failures": failures], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        await settle()
        NSApp.terminate(nil)
    }

    @MainActor func runReferenceDeleteProbe(directory: URL) async {
        var passed = 0
        var failures: [String] = []
        let run = ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix"
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failures.append(label) }
            // #region debug-point A-C:reference-delete-probe
            var r = URLRequest(url: URL(string: "http://127.0.0.1:7792/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-reference-delete", "runId": run, "hypothesisId": "A-C", "msg": "[DEBUG] \(label)", "data": ["passed": condition, "editing": editingNodeId ?? "", "composing": composingNodeId ?? "", "sheet": inputRouter.anchorView?.window?.attachedSheet != nil, "selected": canvas.selectedNodeIds.sorted(), "responder": inputRouter.anchorView?.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"]]); URLSession.shared.dataTask(with: r).resume()
            // #endregion
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(500)) }
        guard let window = inputRouter.anchorView?.window else { return }
        func click(_ point: CGPoint, modifiers: NSEvent.ModifierFlags = []) async {
            guard let anchor = inputRouter.anchorView else { return }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: anchor.convert(point, to: nil),
                    modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!, atStart: false)
                try? await Task.sleep(for: .milliseconds(100))
            }
            await settle()
        }
        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) async {
            let characters = code == 6 ? "z" : code == 51 ? "\u{7f}" : "\u{f728}"
            NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!, atStart: false)
            await settle()
        }
        func thumbnailVisible(_ node: CanvasNode, _ media: SlotContent.SlotAttachment) -> Bool {
            controlRegions["composer-reference-media-\(node.id)-\(media.id.uuidString)"] != nil
        }
        func screenshot(_ name: String) {
            if let root = window.contentView, let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        canvas.isLibraryExpanded = false
        agentVisible = false
        pan = CGSize(width: 80, height: 65)
        zoom = 0.8
        importCanvasResource(directory.appendingPathComponent("fixture.png"), at: CGPoint(x: 350, y: 280))
        guard let source = canvas.soleSelectedNode,
              let generated = createNode(kind: .video, at: CGPoint(x: 1100, y: 280),
                                         parentNodeId: source.id, beginEditing: false, quiet: true) else { return }
        commitEdit(generated, text: "缓慢推进")
        await settle()
        guard let original = previewableMedia(of: source) else { return }
        check(thumbnailVisible(source, original), "connected source displays thumbnail")
        screenshot("canvas-input-upload.png")
        let rect = screenFrame(of: canvas.node(id: generated.id)!)
        await click(CGPoint(x: rect.midX, y: rect.midY))
        check(canvas.selectedNodeIds == [generated.id], "native click selects generation node")
        await key(51)
        check(canvas.node(id: generated.id) == nil, "Delete directly removes selected generation node")
        if canvas.node(id: generated.id) == nil { canvas.undo(); await settle() }
        await click(CGPoint(x: rect.midX, y: rect.midY))
        if let frame = composerFrame {
            await click(CGPoint(x: frame.minX + 100, y: frame.minY + 85))
            check(window.firstResponder is NSTextView, "native prompt click focuses editor")
            if let editor = window.firstResponder as? NSTextView {
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                let before = editor.string
                await key(51)
                check(canvas.node(id: generated.id) != nil && editor.string != before,
                      "Delete while editing only removes prompt character")
            }
            await click(CGPoint(x: rect.midX, y: rect.midY))
            await key(117)
            check(canvas.node(id: generated.id) == nil, "Forward Delete after editor blur removes selected node")
            if canvas.node(id: generated.id) == nil { canvas.undo(); await settle() }
        } else { check(false, "reselected node exposes composer") }
        endInlineEditing()
        let sourceRect = screenFrame(of: canvas.node(id: source.id)!)
        await click(CGPoint(x: sourceRect.midX, y: sourceRect.midY))
        check(canvas.selectedNodeIds == [source.id], "native click selects connected source")
        let edgesBefore = canvas.edges
        let bytesBefore = original.resolveData()
        let historyBefore = canvas.history.cursor
        await key(51)
        check(window.attachedSheet == nil && canvas.node(id: source.id) == nil,
              "Delete connected source skips confirmation")
        check(canvas.node(id: generated.id) != nil && canvas.incomingEdges(of: generated.id).isEmpty,
              "source deletion keeps downstream and removes connection")
        check(canvas.history.cursor == historyBefore + 1, "source deletion records one undo entry")
        await key(6, modifiers: .command)
        check(canvas.node(id: source.id) != nil && canvas.edges == edgesBefore
              && liveAttachments(for: source).first?.resolveData() == bytesBefore,
              "keyboard undo restores connected source and attachment bytes")
        await key(6, modifiers: [.command, .shift])
        check(canvas.node(id: source.id) == nil && canvas.incomingEdges(of: generated.id).isEmpty,
              "keyboard redo removes source and connection")
        await key(6, modifiers: .command)
        await click(CGPoint(x: sourceRect.midX, y: sourceRect.midY))
        await click(CGPoint(x: rect.midX, y: rect.midY), modifiers: .shift)
        check(canvas.selectedNodeIds == [source.id, generated.id], "shift click selects both connected nodes")
        await key(117)
        check(canvas.node(id: source.id) == nil && canvas.node(id: generated.id) == nil && window.attachedSheet == nil,
              "Forward Delete removes multiselection without confirmation")
        await key(6, modifiers: .command)
        check(canvas.node(id: source.id) != nil && canvas.node(id: generated.id) != nil
              && canvas.edges == edgesBefore && liveAttachments(for: source).first?.resolveData() == bytesBefore,
              "one keyboard undo restores multiselection connections and bytes")
        await click(CGPoint(x: rect.midX, y: rect.midY))
        if let button = controlRegions["composer-reference-\(source.id)"] {
            await click(CGPoint(x: button.midX, y: button.midY))
            check(canvas.selectedNodeIds == [source.id], "thumbnail click selects its connected source")
        } else { check(false, "reference thumbnail button exists") }
        canvas.select(id: generated.id, additive: false)
        let portrait = directory.appendingPathComponent("portrait.png")
        let image = NSImage(size: CGSize(width: 120, height: 240))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 120, height: 240)).fill()
        image.unlockFocus()
        if let data = image.tiffRepresentation {
            try? NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])?.write(to: portrait)
        }
        check(importInputFiles([portrait], to: source, projectId: canvas.activeProjectId), "replace upstream source while composer stays open")
        await settle()
        guard let replacement = previewableMedia(of: canvas.node(id: source.id)!) else { return }
        check(thumbnailVisible(source, replacement) && !thumbnailVisible(source, original),
              "open composer refreshes replaced source identity")
        screenshot("canvas-source-image.png")
        canvas.undo()
        await settle()
        check(thumbnailVisible(source, original) && !thumbnailVisible(source, replacement),
              "source replacement undo refreshes thumbnail")
        importCanvasResource(directory.appendingPathComponent("fixture.mp4"), at: CGPoint(x: 350, y: 800))
        guard let video = canvas.soleSelectedNode, let movie = previewableMedia(of: video) else { return }
        if let edge = canvas.incomingEdges(of: generated.id).first { canvas.disconnect(edgeId: edge.id) }
        canvas.connect(from: video.id, to: generated.id)
        canvas.select(id: generated.id, additive: false)
        await settle()
        check(thumbnailVisible(video, movie) && !thumbnailVisible(source, original),
              "same-count connection swap refreshes video thumbnail")
        screenshot("canvas-source-video.png")
        guard let text = createNode(kind: .text, at: CGPoint(x: 700, y: 800), parentNodeId: nil, beginEditing: false, quiet: true),
              let upstream = createNode(kind: .image, at: CGPoint(x: 1100, y: 800),
                                        parentNodeId: text.id, beginEditing: false, quiet: true) else { return }
        canvas.connect(from: text.id, to: generated.id)
        canvas.connect(from: upstream.id, to: generated.id)
        canvas.select(id: generated.id, additive: false)
        check(importInputFiles([portrait], to: upstream, projectId: canvas.activeProjectId), "upload upstream generation input")
        await settle()
        check(controlRegions["composer-reference-\(text.id)"] != nil
              && !controlRegions.keys.contains { $0.hasPrefix("composer-reference-media-\(text.id)-") },
              "text connection retains text entry")
        check(controlRegions["composer-reference-\(upstream.id)"] != nil
              && !controlRegions.keys.contains { $0.hasPrefix("composer-reference-media-\(upstream.id)-") },
              "upstream generation input is not shown as its output thumbnail")
        commitEdit(upstream, text: "生成构图参考")
        if let task = startGeneration(canvas.node(id: upstream.id)!) {
            await task.value
            await settle()
            if let output = previewableMedia(of: canvas.node(id: upstream.id)!) {
                check(thumbnailVisible(upstream, output), "upstream generated output appears in open composer")
            } else { check(false, "upstream generation has output") }
        } else { check(false, "upstream mock generation starts") }
        let sessionLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        try? JSONSerialization.data(withJSONObject: ["passed": passed, "failures": failures, "sessionLocked": sessionLocked], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        await settle()
        NSApp.terminate(nil)
    }
}
#endif
