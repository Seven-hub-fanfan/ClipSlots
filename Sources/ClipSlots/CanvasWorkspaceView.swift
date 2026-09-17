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
    @ObservedObject var store: SlotStoreObservable
    @ObservedObject var canvas: CanvasStore
    /// 画布页 Agent 侧栏的显隐。侧栏本体由 ContentView 的内容区并排渲染，
    /// 这里只持有开关：让"入口按钮"能待在画布右上（生成按钮旁），而布局让位交给外层 HStack。
    @Binding var agentVisible: Bool

    /// 画布根坐标空间名。槽位库的拖拽手势也用它上报落点，两边共用一个空间才能对齐坐标。
    static let spaceName = "clipslots.canvas.root"

    // MARK: 视口

    @State private var pan: CGSize = .zero
    @State private var zoom: CGFloat = 1
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
    @State private var layoutZoom: CGFloat = 1
    /// 连续缩放的落定防抖任务。新事件进来就取消上一个 —— 手势期间反复推迟，只有真的停手才落定。
    @State private var zoomSettleWork: DispatchWorkItem? = nil
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
    /// 「删了会断开连接」的确认弹窗（★ v2.11.8 三轮）。非 nil = 正在等用户拍板。
    ///
    /// 存一份**待删 id 集合**而不是只存个 Bool：弹窗弹出后用户可能改动选中集合（点了别处），
    /// 确认时若再去读 `canvas.selectedNodeIds` 就会删掉与提示文案不符的那批节点。
    @State private var pendingDeletion: PendingDeletion? = nil
    /// 历史面板是否展开。
    @State private var showHistory = false
    /// 框选矩形（屏幕空间）。
    @State private var marqueeStart: CGPoint? = nil
    @State private var marqueeCurrent: CGPoint? = nil
    /// 光标位置，供锚点缩放使用。
    @State private var cursorScreen: CGPoint = .zero
    /// 当前"按坐标维持 hover"的节点（★ v2.11.8 五轮）。
    ///
    /// 与节点自身的 `.onHover` 是 OR 关系：`.onHover` 管进入，这个管**维持**。判定规则全在
    /// `CanvasNodeHover`（本体矩形优先、维持区 = 节点 + 扇形包围盒 + 30pt）。
    @State private var hoverHoldNodeId: String? = nil
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
    @State private var archiveDrag: CanvasNodeArchiveDrag? = nil
    /// 最近一次已知的视图尺寸。
    ///
    /// `GeometryReader` 的 `proxy.size` 只在 `body` 里拿得到，而 Cmd+1 走的是 AppKit 事件监听
    /// 回调（`inputRouter.onKeyAction` → `handleSlotCommand`），那条路径**不在 body 里**。
    /// 没有这份镜像，热键就算不出"当前视口中央在画布的哪里"，只能把新节点扔到原点。
    @State private var viewSize: CGSize = .zero

    /// 「ADD NODE」菜单的待办请求（nil = 未打开）。
    ///
    /// 同时记 `screenPoint`（菜单画在哪）与 `canvasPoint`（节点建在哪）：两者在缩放/平移下不是
    /// 同一个数，等到用户选完菜单项再换算就会用上"已经变了的" pan/zoom（菜单开着时中键仍可平移），
    /// 节点会落在离双击点很远的地方。
    @State private var addMenu: AddNodeRequest? = nil

    /// 上一次「空白单击」的时间与位置，用来自己判定双击（见 `handleBlankTap`）。
    @State private var lastBlankClick: CanvasClickCadence.Click? = nil

    struct AddNodeRequest: Identifiable {
        let id = UUID()
        let screenPoint: CGPoint
        let canvasPoint: CGPoint
        /// 从「选中节点下方的 +」进来时，记住上游是谁。
        let parentNodeId: String?
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CanvasGridBackground(pan: effectivePan, zoom: zoom)
                    .allowsHitTesting(false)

                blankClickCatcher

                if canvas.nodes.isEmpty {
                    CanvasEmptyHint()
                        .frame(width: max(0, proxy.size.width - sidebarWidth), height: proxy.size.height)
                        .padding(.leading, sidebarWidth)
                }

                nodeLayer

                marqueeOverlay

                downstreamPlusOverlay

                floatingLayer(size: proxy.size)

                ghostOverlay

                inputFilesAnchorOverlay

                // ADD NODE 菜单压在最上层：它是模态性质的浮层，被任何东西盖住都会变成"点了没反应"。
                addNodeMenuOverlay(size: proxy.size)
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
                switch phase {
                case .active(let p):
                    cursorScreen = p
                    // ★ 五轮：hover 维持区判定挂在这条本来就在跑的通路上（原本只用于捏合锚点），
                    // 不新增任何可命中视图 —— 详见 `CanvasNodeHover` 里"为什么不用透明 halo"。
                    updateHoverHold(at: p)
                case .ended:
                    // 光标离开整个画布（切窗口 / 移到侧栏外）：按"离开"处理，但仍走宽限期，
                    // 免得贴边移动时的一次 ended/active 抖动把展开态打断。
                    scheduleHoverHold(nil)
                }
            }
            .onAppear {
                pan = canvas.pan
                zoom = canvas.zoom
                // 排版缩放必须与初始 zoom 对齐，否则首帧 ratio ≠ 1，节点会以一个错误的比例被拉伸。
                layoutZoom = CanvasZoomLayout.bucket(for: canvas.zoom)
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
            // ★ 三轮：删除节点会断开下游连接时的确认（用户要求「弹 Alert，可强制删除或取消」）。
            //
            // 用 `.alert(item:)` 而不是自绘浮层：这是一个真正需要打断用户的破坏性确认，系统 Alert
            // 自带 Esc/回车键盘语义与"点外面不会误关"的模态行为，自绘一遍等于重新实现一遍还容易漏。
            .alert(item: $pendingDeletion) { pending in
                Alert(title: Text(CanvasNodeDeletion.confirmTitle),
                      message: Text(CanvasNodeDeletion.confirmMessage(referrerCount: pending.referrerCount)),
                      primaryButton: .destructive(Text(CanvasNodeDeletion.confirmPrimary)) {
                          performDelete(ids: pending.ids)
                      },
                      secondaryButton: .cancel(Text(CanvasNodeDeletion.confirmCancel)))
            }
        }
    }

    /// 等待用户确认的删除请求。
    struct PendingDeletion: Identifiable {
        let id = UUID()
        let ids: Set<String>
        /// 会因此断链的下游节点数量。只用于文案，判定另存在 Kit。
        let referrerCount: Int
    }

    private var effectivePan: CGSize {
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
        Color.clear
            .contentShape(Rectangle())
            // ★ v2.11.8：双击空白 = 在鼠标位置弹「ADD NODE」菜单。
            //
            // 只挂单击手势，双击靠 `CanvasClickCadence` 自己数 —— 原因见该类型的文档：
            // 单击手势与 `onTapGesture(count: 2)` 共存时，双击在实测里**从不触发**。
            //
            // 位置取 `cursorScreen`（由 `.onContinuousHover` 实时更新）而不是手势的 location：
            // macOS 13 的 `onTapGesture` 不给落点，而 hover 位置与点击落点在实践中是同一个像素
            // （鼠标不会在按下与抬起之间跑掉）。锚点缩放一直用的也是这份坐标。
            .onTapGesture { handleBlankTap() }
    }

    /// 空白单击 / 双击的分流。
    ///
    /// 第一击照旧取消选中（保持 hotfix21 的手感，不能让它等双击超时），第二击落在同一处且在系统
    /// 双击间隔内就弹 ADD NODE 菜单。菜单弹出后把游标清空，避免"连点三下"弹第二个菜单。
    private func handleBlankTap() {
        // 正在 inline 编辑时，点空白处的语义是「写完了」——先按失焦保存收掉编辑态（否则编辑框会
        // 一直挂在节点上，见 endInlineEditing 的注释），这一击不再兼作取消选中/双击判定。
        if editingNodeId != nil {
            endInlineEditing()
            lastBlankClick = nil
            return
        }
        let click = CanvasClickCadence.Click(point: cursorScreen,
                                             time: Date().timeIntervalSinceReferenceDate)
        if CanvasClickCadence.isDoubleClick(previous: lastBlankClick,
                                            current: click,
                                            interval: NSEvent.doubleClickInterval) {
            lastBlankClick = nil
            openAddMenu(atScreen: cursorScreen, parentNodeId: nil)
            return
        }
        lastBlankClick = click
        canvas.clearSelection()
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
                                   pathLabel: pathLabel(for: node),
                                   attachments: liveAttachments(for: node),
                                   renderScale: layoutZoom,
                                   isEditing: isEditing,
                                   onBeginEdit: { beginEdit(node) },
                                   onCommitEdit: { commitEdit(node, text: $0) },
                                   onCancelEdit: { editingNodeId = nil },
                                   onOpenInputFiles: { openInputFiles(node) },
                                   onPromoteInput: { promoteInput(node, index: $0) },
                                   onDeleteInput: { deleteInput(node, index: $0) },
                                   onToggleAnimationStyle: { canvas.toggleAnimationStyle(id: node.id) },
                                   // ★ 六轮：卡片命中层独占点击后由它补选中（Shift 加选与祖先那条一致）。
                                   onActivateNode: {
                                       guard editingNodeId != node.id else { return }
                                       canvas.select(id: node.id,
                                                     additive: NSEvent.modifierFlags.contains(.shift))
                                   },
                                   onToast: { store.transientUI.showToast($0) },
                                   isHoverHeld: hoverHoldNodeId == node.id,
                                   onHoverChanged: { noteNodeHover(node, hovering: $0) })
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
        //
        // ★ v2.11.8：`scaleEffect` 已移除（见类型注释：它是放大模糊的根因），位置改为逐节点
        // 直接算屏幕坐标。这里只剩「拖拽时禁掉隐式动画」。
        //
        // 而且这个禁用**必须收窄到拖拽期**：v2.11.8 之前是无条件 `$0.animation = nil`，它会连坐
        // 掉子树里所有动画 —— 槽位节点的扇形展开（spring）正是子树里的动画，无条件禁用时它会
        // 变成一帧到位的硬切，看起来像"动画没写"。
        .transaction { t in
            if draggingNodeId != nil { t.animation = nil }
        }
    }

    @ViewBuilder
    private func nodeContextMenu(_ node: CanvasNode) -> some View {
        Button("编辑提示词") { beginEdit(node) }
        Button("管理入参文件") { openInputFiles(node) }
        // ★ 八轮需求 3：三种展开样式在右键菜单里并列可选。
        //
        // 为什么不只留右上角那颗 15pt 的循环按钮：三态循环意味着"想要第三种得连点两下、还要盯着
        // 图标猜自己现在在哪一态"。菜单是**直接选择**，且能显示当前值（✓）—— 而按钮保留是因为
        // 它在 hover 时就在手边，两条路径落到同一个 store 方法（同一条撤销记录）。
        // 文本节点没有卡叠，不给这一项（与右上角按钮的显示条件一致）。
        if node.kind != .text {
            Menu("展开样式") {
                ForEach(CanvasFanGeometry.ExpandStyle.allCases, id: \.self) { style in
                    Button {
                        canvas.setAnimationStyle(id: node.id, style: style)
                    } label: {
                        // macOS 13 的 Menu 里 Button 没有原生 checkmark 通路（Toggle 在 contextMenu
                        // 里样式不统一），用前缀标记当前项 —— 宽度用不换行的全角空格对齐。
                        Text(node.animationStyle == style ? "✓ \(style.displayName)" : "　\(style.displayName)")
                    }
                }
            }
        }
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
        if hovering {
            hoverLeaveTask?.cancel()
            hoverLeaveTask = nil
            if hoverHoldNodeId != node.id { hoverHoldNodeId = node.id }
        } else if hoverHoldNodeId == node.id {
            // 出边框先别收：光标可能只是移到了扇形溢出的那张卡或翻页箭头上（都在维持区里）。
            // 真正的判定交给 `updateHoverHold`（下一次光标移动）与宽限期定时器。
            scheduleHoverHold(resolvedHoverHold(at: cursorScreen))
        }
    }

    /// 光标移动时重算维持对象。
    private func updateHoverHold(at screenPoint: CGPoint) {
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

    private func resolvedHoverHold(at screenPoint: CGPoint) -> String? {
        let p = CanvasGeometry.canvasPoint(screen: screenPoint, pan: effectivePan, zoom: zoom)
        return CanvasNodeHover.resolve(current: hoverHoldNodeId, point: p, nodes: canvas.nodes)
    }

    /// 应用维持结果：**进入立即、离开延迟 `CanvasNodeHover.leaveDelay`**。
    ///
    /// 宽限期治的是另一半症状：鼠标快速穿过卡片之间的缝隙、或在节点边界上抖一下。录屏里
    /// f_035 展开 → f_036 收拢 → f_037 又展开，整个来回 0.33s —— 200ms 宽限期足以把它吃掉。
    private func scheduleHoverHold(_ next: String?) {
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
                updateArchiveDrag(node: node, at: value.location)
            }
            .onEnded { value in
                guard draggingNodeId == node.id else { return }
                // 归槽优先：光标松在侧栏的某个槽位块上时，这次拖拽的语义是"把内容归进那个槽位"，
                // 而**不是**移动节点位置。两件事都做的话，节点会先归槽再被挪到侧栏底下（被侧栏
                // 盖住 = 用户眼里凭空消失）。
                if let slot = archiveTargetSlot(at: value.location) {
                    archiveDrag = nil
                    draggingNodeId = nil
                    draggingIds = []
                    dragDelta = .zero
                    archiveNode(node, toSlot: slot)
                    return
                }
                archiveDrag = nil
                let delta = CGSize(width: value.translation.width / zoom,
                                   height: value.translation.height / zoom)
                canvas.moveNodes(ids: draggingIds, by: delta)
                draggingNodeId = nil
                draggingIds = []
                dragDelta = .zero
            }
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
        guard CanvasArchiveDropGeometry.isInsidePanel(point: point, panelSize: archivePanelSize) else {
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

    /// 松手点对应的槽位号（nil = 不在侧栏 / 不在任何块上）。
    ///
    /// 与侧栏渲染分栏块用的是**同一个** `CanvasArchiveDropGeometry`，不各写一份 —— 两份公式的
    /// 差异会让"看起来在第 3 块上、却归到第 4 个槽位"，且只在某些窗口高度下出现（见那个类型的注释）。
    private func archiveTargetSlot(at point: CGPoint) -> Int? {
        guard archiveDrag != nil else { return nil }
        return CanvasArchiveDropGeometry.blockIndex(at: point,
                                                    panelSize: archivePanelSize,
                                                    count: max(1, store.config.slots))
    }

    /// 归槽落地：把节点绑定的内容搬进当前组的第 `slot` 个槽位，节点跟着改绑。
    ///
    /// 顺序是**先搬内容、再改摆位**，且任一步失败就整体放弃：
    ///   - 内容搬成功、摆位没改 → 画布上的节点指着一个已经空了的槽位，卡片变空白，用户以为内容丢了；
    ///   - 摆位改成功、内容没搬 → 节点指向一个空槽，原槽位里还留着内容，等于凭空多出一份孤儿数据。
    ///
    /// 目标槽位非空时**不覆盖**（`canvasMoveSlotContent` 自己会拒绝），如实提示 —— 覆盖会静默毁掉
    /// 用户资产，而此刻用户的注意力全在自己拖的那个节点上，根本不会发现另一份内容不见了。
    private func archiveNode(_ node: CanvasNode, toSlot slot: Int) {
        let targetGroup = store.currentSpecialSlotId
        let targetPage = store.currentPageId

        guard node.groupId != targetGroup || node.slot != slot else {
            store.transientUI.showToast("已经在槽位 \(slot) 里了")
            return
        }
        guard store.canvasSlotIsFree(groupId: targetGroup, slot: slot) else {
            store.transientUI.showToast("槽位 \(slot) 已有内容，先清空或换一个")
            return
        }
        // 目标槽位已经被另一个节点占着（内容为空但画布上有节点）→ 会撞 id，拒绝。
        guard canvas.node(forGroupId: targetGroup, slot: slot) == nil else {
            store.transientUI.showToast("槽位 \(slot) 已经在画布上了")
            return
        }

        guard store.canvasMoveSlotContent(fromGroupId: node.groupId, fromSlot: node.slot,
                                          toGroupId: targetGroup, toSlot: slot) else {
            store.transientUI.showToast("存储繁忙，未能归入槽位 \(slot)")
            return
        }
        guard canvas.rebindNode(id: node.id, toPageId: targetPage, groupId: targetGroup, slot: slot) else {
            // 内容已经搬过去了，摆位没改成 —— 把内容搬回来，恢复到操作前的状态。
            store.canvasMoveSlotContent(fromGroupId: targetGroup, fromSlot: slot,
                                        toGroupId: node.groupId, toSlot: node.slot)
            store.transientUI.showToast("未能归槽，已还原")
            return
        }
        canvas.noteSlotDataChanged()
        store.transientUI.showToast("已归入槽位 \(slot)")
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
                    canvas.clearSelection()
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
                                              set: {
                                                  if !$0 {
                                                      inputFilesNodeId = nil
                                                      // 面板里增删过入参 → 关闭时让绑定节点重读槽位。
                                                      // （面板期间的实时刷新由 store 的
                                                      // `canvasSlotRevision` @Published 承担，
                                                      // 这里是关闭后的一道兜底。）
                                                      canvas.noteSlotDataChanged()
                                                  }
                                              }),
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

            CanvasAddNodeMenu(onPick: { choice in handleAddNode(choice, request: request) },
                              onDismiss: { addMenu = nil })
                .offset(x: clamp(request.screenPoint.x,
                                 min: 8,
                                 max: max(8, size.width - CanvasAddNodeMenu.width - 8)),
                        // 菜单高度按内容估的（3 项 + 标题 ≈ 168pt）。宁可估大：估小会让菜单在
                        // 窗口底部被切掉最后一项，而估大只是让它离底边远一点。
                        y: clamp(request.screenPoint.y,
                                 min: 8,
                                 max: max(8, size.height - 176)))
                .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
        }
    }

    /// 选中节点正下方的浮动圆形 +。
    ///
    /// 尺寸**刻意不随 zoom 缩放**：它是操作把手而不是画布内容，跟着缩到 25% 就变成一个点不中的
    /// 小点。同理它画在节点层之外（屏幕坐标系），这样缩放时把手大小恒定。
    @ViewBuilder
    private var downstreamPlusOverlay: some View {
        if let sole = canvas.soleSelectedNode,
           editingNodeId == nil,
           addMenu == nil,
           draggingNodeId == nil,
           inputFilesNodeId == nil {
            let anchor = CanvasGeometry.screenPoint(canvas: CGPoint(x: sole.x + sole.width / 2,
                                                                   y: sole.y + sole.height),
                                                    pan: effectivePan,
                                                    zoom: zoom)
            Button {
                let frame = CGRect(x: sole.x, y: sole.y, width: sole.width, height: sole.height)
                let origin = CanvasSpawnGeometry.downstreamOrigin(of: frame, newSize: CanvasNode.defaultSize)
                let center = CGPoint(x: origin.x + CanvasNode.defaultSize.width / 2,
                                     y: origin.y + CanvasNode.defaultSize.height / 2)
                openAddMenu(atScreen: CGPoint(x: anchor.x, y: anchor.y + 30),
                            canvasPoint: center,
                            parentNodeId: sole.id)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(AppTheme.chromeAccentInk))
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.25), radius: 5, x: 0, y: 2)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("在下方新建一个节点（自动记为下游）")
            .offset(x: anchor.x - 13, y: anchor.y + 8)
        }
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), Swift.max(lower, upper))
    }

    private func openAddMenu(atScreen screenPoint: CGPoint,
                             canvasPoint: CGPoint? = nil,
                             parentNodeId: String?) {
        let target = canvasPoint ?? CanvasGeometry.canvasPoint(screen: screenPoint, pan: effectivePan, zoom: zoom)
        withAnimation(Anim.interactive) {
            addMenu = AddNodeRequest(screenPoint: screenPoint,
                                     canvasPoint: target,
                                     parentNodeId: parentNodeId)
        }
    }

    private func handleAddNode(_ choice: CanvasAddNodeMenu.Choice, request: AddNodeRequest) {
        addMenu = nil
        switch choice {
        case .text:
            // 文本节点建完直接进编辑态：用户选「文本节点」的下一个动作必然是打字，
            // 让他再双击一次纯属多余。
            createNode(kind: .text, at: request.canvasPoint, parentNodeId: request.parentNodeId, beginEditing: true)
        case .image:
            createNode(kind: .image, at: request.canvasPoint, parentNodeId: request.parentNodeId, beginEditing: false)
        case .slot:
            // 「从已有槽位创建」不能凭空挑一个槽位塞上来 —— 哪个槽位只有用户知道。
            // 所以这一项的语义是**把选择器打开**：展开左侧槽位库，用户拖或按 Cmd+N 都行。
            withAnimation(Anim.transition) { canvas.isLibraryExpanded = true }
            store.transientUI.showToast("从左侧槽位库拖一个槽位到画布，或按 Cmd+1~0")
        }
    }

    /// 新建一个节点。
    ///
    /// ## ★ v2.11.8 二轮：新节点落到「未入库」，不再抢用户槽位
    ///
    /// 此前这里去 `activeHotkeySpecialSlotId`（当前组）里找空槽 —— 于是用户在画布上随手建三个
    /// 节点，编辑页的槽位 3/4/5 就被占了，圆盘和 Cmd+3~5 也跟着变，而那三个节点还只是草稿。
    /// 用户明确要求：**画布上没有对应槽位的独立节点归入「未入库」**。
    ///
    /// 于是新建一律落到未入库保留组（见 `SlotStoreObservable.canvasUnfiledGroupId`），
    /// 之后由用户把它拖进槽位库的某个槽位块完成"归槽"。真实槽位从此只由用户显式指定
    /// （槽位库拖拽 / Cmd+1~0），不会再被隐式占用。
    ///
    /// 返回 nil 表示没建成，调用方**不要**再往下写内容 —— 否则会写到一个不存在的槽位上。
    @discardableResult
    private func createNode(kind: CanvasNodeKind,
                            at canvasPoint: CGPoint,
                            parentNodeId: String?,
                            beginEditing: Bool,
                            quiet: Bool = false) -> CanvasNode? {
        let groupId = store.canvasUnfiledGroupId
        guard store.ensureCanvasUnfiledGroup() else {
            store.transientUI.showToast("存储繁忙，未能新建节点")
            return nil
        }
        guard let slot = store.allocateUnfiledSlot(occupied: canvas.occupiedSlots(inGroup: groupId)) else {
            // 说清出路而不是只说失败：这条提示是用户唯一能看到的解释。
            store.transientUI.showToast("未入库已满，先把一些节点拖进槽位库归档")
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
                                     avoidOverlap: true)
        if beginEditing { editingNodeId = result.node.id }
        if !quiet { store.transientUI.showToast("已新建\(kind.displayName)节点 · 未入库") }
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

        case .imageNodeWithFiles(let urls):
            guard let node = createNode(kind: .image, at: center, parentNodeId: nil,
                                        beginEditing: false, quiet: true) else { return true }
            let atts = urls.map {
                SlotContent.SlotAttachment(name: $0.lastPathComponent,
                                           type: CanvasPasteClassifier.isImageFile($0) ? .image : .file,
                                           path: $0.path)
            }
            appendAttachments(atts, to: node)
            store.transientUI.showToast(urls.count == 1 ? "已粘贴文件为入参" : "已粘贴 \(urls.count) 个文件为入参")

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
            store.transientUI.showToast("已粘贴图片为入参")
        }
        return true
    }

    private static let pasteStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// 往槽位的入参列表尾部追加。
    ///
    /// 读-改-写而不是直接覆盖：这个槽位刚被新建时是空的，但"刚才"与"现在"之间用户可能已经
    /// 从别处塞了东西（比如 Agent 侧栏），覆盖会静默吃掉它们。
    private func appendAttachments(_ new: [SlotContent.SlotAttachment], to node: CanvasNode) {
        guard !new.isEmpty else { return }
        var list = store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
        list.append(contentsOf: new)
        guard store.writeCanvasSlotAttachments(groupId: node.groupId, slot: node.slot, attachments: list) else {
            store.transientUI.showToast("存储繁忙，入参未写入")
            return
        }
        canvas.noteSlotDataChanged()
    }

    /// 扇形卡片的「设为入参」：把这张挪到入参列表首位。
    ///
    /// 首位不是随便定的名分 —— 缩略图、圆盘预览、生成时取的第一张入参都看列表首位，
    /// 所以"设为入参"落地成"挪到第 0 位"是这个词在本项目里唯一有实际后果的解释。
    private func promoteInput(_ node: CanvasNode, index: Int) {
        var list = store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
        guard list.indices.contains(index) else { return }
        guard index != 0 else {
            store.transientUI.showToast("它已经是首个入参了")
            return
        }
        let item = list.remove(at: index)
        list.insert(item, at: 0)
        guard store.writeCanvasSlotAttachments(groupId: node.groupId, slot: node.slot, attachments: list) else {
            store.transientUI.showToast("存储繁忙，稍后再试")
            return
        }
        canvas.noteSlotDataChanged()
        store.transientUI.showToast("已设为首个入参：\(item.name)")
    }

    /// 扇形卡片气泡里的「删除」：删掉这**一个入参文件**（★ v2.11.8 三轮）。
    ///
    /// 刻意**不弹确认**：用户明确要求「卡片内单张图片的删除（非整个节点删除），应该允许直接删除，
    /// 不影响节点本身」。删除只改附件列表 —— 节点、槽位正文、连线全都不动，且 `write` 路径本身
    /// 会把旧内容备份进 `.trash`（v2.10.16 起），误删有得救。要弹 Alert 的是**删节点**那条路
    /// （见 `deleteSelectedNodes`），两者语义不同，别合并。
    private func deleteInput(_ node: CanvasNode, index: Int) {
        var list = store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
        guard list.indices.contains(index) else { return }
        let item = list.remove(at: index)
        guard store.writeCanvasSlotAttachments(groupId: node.groupId, slot: node.slot, attachments: list) else {
            store.transientUI.showToast("存储繁忙，稍后再试")
            return
        }
        canvas.noteSlotDataChanged()
        store.transientUI.showToast("已删除入参：\(item.name)")
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
                                   onDropSlot: handleSlotDrop,
                                   archiveDrag: archiveDrag,
                                   onReorder: { groupId, from, to in
                                       handleSlotReorder(groupId: groupId, from: from, to: to)
                                   })

            // 右上：Agent 入口 + 生成按钮
            VStack {
                HStack(spacing: 8) {
                    Spacer()
                    // ★ v2.11.8：画布页的 Agent 入口紧贴「生成」左侧。
                    // 侧栏本体挂在 ContentView 的内容区（见那边的注释），这里只是开关，
                    // 因此侧栏展开后这一整排会随画布可用宽度自动左移，不需要手动补 padding。
                    Button {
                        withAnimation(Anim.transition) { agentVisible.toggle() }
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(agentVisible ? .white : AppTheme.chromeAccentInk)
                            .frame(width: 28, height: 28)
                            .background(agentVisible ? AppTheme.chromeAccentInk : AppTheme.canvasChromeSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(AppTheme.subtleBorder, lineWidth: agentVisible ? 0 : 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(agentVisible ? "收起 Agent 侧栏" : "打开 Agent 侧栏")

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
        let target = CanvasZoomLayout.settled(current: layoutZoom, zoom: value)
        guard layoutZoom != target else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        tx.animation = nil
        withTransaction(tx) { layoutZoom = target }
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

    private func fitToContent(size: CGSize) {
        guard !canvas.nodes.isEmpty else {
            settleLayoutZoom(to: 1)
            withAnimation(Anim.transition) { pan = .zero; zoom = 1 }
            canvas.updateViewport(pan: .zero, zoom: 1)
            return
        }
        let bounds = CanvasGeometry.bounds(of: canvas.nodes.map(\.frame))
        let fit = CanvasGeometry.fitTransform(contentBounds: bounds, viewSize: size)
        settleLayoutZoom(to: fit.zoom)
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

    /// 节点卡片顶部居中的路径标识：`页面 - 槽位组 - 槽位`（v2.11.8 二轮）。
    ///
    /// 在这里拼而不是在卡片里拼：页面名与组名要查主 store，而卡片刻意不认识 store
    /// （见 `CanvasNodeCardView` 的类型注释）。拼装规则本身在 `CanvasCardText.pathLabel`，
    /// 带 smoke 断言。
    ///
    /// 未入库的节点走 `未入库 - N`：它不属于任何用户页面，硬给它编一个页面名只会误导
    /// —— 用户会去那一页找这个节点，然后找不到。
    private func pathLabel(for node: CanvasNode) -> String {
        let isUnfiled = node.groupId == store.canvasUnfiledGroupId
        if isUnfiled {
            return CanvasCardText.pathLabel(pageName: nil, groupName: nil,
                                            slot: node.slot, isUnfiled: true)
        }
        let pageName = store.pages.first { $0.id == node.pageId }?.name
        let groupName = store.specialSlots.first { $0.id == node.groupId }?.name
        return CanvasCardText.pathLabel(pageName: pageName, groupName: groupName, slot: node.slot)
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

    // MARK: - 删除节点（带断链确认）

    /// 删除节点的**唯一入口**。有下游引用时先弹确认，没有就直接删。
    ///
    /// 三个调用点（Delete 键 / 右键"删除节点" / 右键"删除选中的 N 个"）全部收敛到这里 ——
    /// 之前它们各自调 `canvas.removeNodes` / `removeSelected`，任何一条漏加确认都等于
    /// 用户从那条路径删掉引用节点时静默断链，而断链事后无法还原（见 `CanvasNode.parentNodeId`）。
    private func requestDelete(ids: Set<String>) {
        let targets = ids.filter { id in canvas.nodes.contains { $0.id == id } }
        guard !targets.isEmpty else { return }
        let links = CanvasNodeDeletion.brokenLinks(deleting: targets, nodes: canvas.nodes)
        guard links.referrers.isEmpty else {
            pendingDeletion = PendingDeletion(ids: targets, referrerCount: links.referrers.count)
            return
        }
        performDelete(ids: targets)
    }

    /// 真正执行删除（确认之后，或本来就无需确认）。
    private func performDelete(ids: Set<String>) {
        pendingDeletion = nil
        let count = canvas.nodes.filter { ids.contains($0.id) }.count
        guard count > 0 else { return }
        canvas.removeNodes(ids: ids)
        store.transientUI.showToast(count == 1 ? "已删除节点" : "已删除 \(count) 个节点")
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
            guard !canvas.selectedNodeIds.isEmpty else {
                store.transientUI.showToast("请先选中要删除的节点")
                return true
            }
            // ★ 三轮：走统一入口，有下游引用先弹确认（toast 由 performDelete 负责）。
            requestDelete(ids: canvas.selectedNodeIds)
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

        case .paste:
            return handlePaste()

        case .cancel:
            // v2.11.8：把「编辑态卡住」收掉。
            //
            // 现场：新建文本节点会直接进 inline 编辑态；此时点画布空白处，SwiftUI 侧的
            // `Color.clear` 并不会把 NSTextView 的 first responder 抢走，于是编辑器失去了
            // 键盘焦点、`editingNodeId` 却还挂着 —— 节点永远显示编辑框，而下游 `+` 号、删除、
            // 撤销全都以 `editingNodeId == nil` 为前提，一起失效。用户唯一的印象是"画布卡住了"。
            //
            // 真正在编辑器里按 Esc 走不到这里（`CanvasInputRouter` 按 firstResponder 放行给
            // 文本系统），所以这条分支只处理"焦点已丢、状态还在"的残留态。
            if editingNodeId != nil {
                endInlineEditing()
                return true
            }
            if addMenu != nil {
                addMenu = nil
                return true
            }
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
    private func endInlineEditing() {
        guard editingNodeId != nil else { return }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let responder = window?.firstResponder as? NSTextView, responder.isEditable {
            window?.makeFirstResponder(nil)
        }
        editingNodeId = nil
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
