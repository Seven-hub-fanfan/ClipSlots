import SwiftUI
import AppKit
import ClipSlotsKit

/// 槽位节点的「堆叠卡片」（v2.11.8 · 二轮重做交互）。
///
/// 取代此前预览区里那张**单图**。单图的问题不是不好看，是**说了谎**：一个槽位可以挂 4 个入参
/// 文件、可以是三段文字，卡片上却只画第一张图 —— 用户在画布上根本看不出这个槽位到底装了几件
/// 东西，得点开入参文件面板才知道。堆叠卡片把「数量」变成了视觉信息。
///
/// ## 展开风格：只有扇形（★ v2.11.8 九轮）
///
/// 一轮只有扇形，用户实测反馈「展开很难选到第二个」「最后那个没有办法选择中间的」。视频分析确认了
/// 根因（见 `hitLayer` 的注释），二轮的处理是把扇形修好：角度 20°、横向张开 12pt，并把命中判定
/// 从"各卡自己 onHover"换成**统一透明命中层 + 旋转后多边形**。
///
/// 二~八轮另外并存过「水平轮播」与「交替叠放」两种风格 + 一个切换按钮 + 一个右键子菜单。
/// 用户九轮明确要求**只留扇形**、删掉切换入口，所以本文件里所有 `carouselActive` /
/// `scatterActive` 分支、轮播专用的侧滑转场与倒算卡宽都已删除（左右翻页箭头**保留** ——
/// 它是扇形自己的固定栅格分页入口，跟风格无关）。`style` 入参也随之去掉 ——
/// 留一个恒等于 `.fanOut` 的参数只会让下一位读者以为这里还有分支。
///
/// ## 刻意的取舍
///   - **展开只是视觉溢出，不改布局**。卡片全部走 `offset`/`rotationEffect`（渲染期变换），
///     容器尺寸恒为预览区大小 —— 否则 hover 一张卡就会把下面的正文、参数栏往下推，
///     一屏十几个节点时整个画布会随鼠标"呼吸"。
///   - **角度关于中轴严格对称**（几何在 `CanvasFanGeometry`，可被 smoke 断言）：视觉重心不随
///     张数奇偶左右跳动。
///   - **卡片自己不认识 store**。改数据的三件事（编辑正文 / 打开入参面板 / 置为首个入参）全部
///     以闭包上抛，与 `CanvasNodeCardView` 的既有约定一致。
struct CanvasSlotFanStack: View {

    /// **全量**卡片来源（不截断）。扇形模式内部再截到 `maxCards`，剩下的进 `+N` 角标；
    /// 轮播模式按页取。
    ///
    /// 一轮这里收的是已经截断过的数组，于是"总共有几张"这个信息在进入本视图前就丢了，
    /// `+N` 和轮播分页都无从计算。
    let sources: [CanvasFanGeometry.CardSource]
    /// 槽位的完整附件列表。`sources` 里的 `attachmentIndex` 是它的下标。
    let attachments: [SlotContent.SlotAttachment]
    /// 可见性闸门用的**量化** zoom（`CanvasNodeText.gateZoom`）。
    ///
    /// ★ v2.11.8 十轮：与 `CanvasNodeCardView.gateZoom` 同一个契约 —— 本视图里**唯一**知道画布
    /// 缩放的量，且只能参与"卡内文字写不写"的布尔判定。扇形的一切几何（卡片尺寸、张角、错位、
    /// 命中多边形）都是设计稿单位，缩放由节点层唯一那层 `scaleEffect(zoom)` 承担。
    var gateZoom: CGFloat = 1
    /// 整个节点是否被悬停（展开的唯一开关）。
    let nodeHovered: Bool
    /// 预览区可用高度（1x）。卡片按它收敛，避免在小节点上戳出卡片外。
    let boxHeight: CGFloat
    /// 节点身份（`groupId#slot`）。★ 六轮：翻页窗口按它存活，见 `CanvasFanWindowState`。
    let stateKey: String

    let onEditText: () -> Void
    let onOpenInputFiles: () -> Void
    /// 选中所属节点。★ 六轮：命中层升级成 `highPriorityGesture` 后祖先那条
    /// `onTapGesture { canvas.select(...) }` 再也不会触发，选中必须由这里显式补上。
    let onActivateNode: () -> Void
    /// 把第 N 个附件挪到列表首位。首位 = 缩略图/圆盘取的那一张，所以这件事等于"设为主入参"。
    let onPromoteInput: (Int) -> Void
    /// 删除第 N 个附件（★ v2.11.8 三轮）。只动附件列表，节点/槽位正文不受影响 ——
    /// 用户明确要求「卡片内单张图片的删除，允许直接删除，不影响节点本身」。
    let onDeleteInput: (Int) -> Void
    let onToast: (String) -> Void

    @State private var hoveredCard: Int? = nil
    /// 打开了操作气泡的卡片下标（**全量数组的下标**）。
    @State private var openedCard: Int? = nil
    /// 翻页窗口起点（全量下标）。★ v2.11.8 三轮取代旧的 `page`：翻页步长是"容量 - 1"（重叠一张
    /// 参考卡），页号乘以容量的算法表达不了这种重叠。
    @State private var windowStart: Int = 0
    /// 本页是否由「⬅ 后退」到达。只影响参考卡摆头还是摆尾，见 `CanvasFanPaging`。
    /// 鼠标是否压在「+N」灰卡露出的那块楔形上（★ 五轮）。灰卡沉到牌面之下、不再是 Button 之后，
    /// hover 反馈只能自己记 —— 没有反馈的话，那块灰楔形看起来就是"背景的一部分"。
    @State private var overflowHot: Bool = false
    /// 上一次见到的附件总数。★ 六轮：数量变化要区分"变多（露出新增那张）"和"变少（只钳制）"，
    /// `onChange(of:)` 只给新值，旧值得自己记。
    @State private var lastSourceCount: Int = -1

    /// 窗口起点在登记处里的 key。见 `CanvasFanWindowState` 顶部注释：`@State` 活不过右键与页面切换。
    ///
    /// ★ 九轮：风格只剩扇形，`styleTag` 恒为 `fan`（八轮那个按风格分 tag 的三元表达式随
    /// 「水平轮播」一起删了）。tag 保留在 key 里是为了不让老的窗口起点记录串到别的语义上去。
    private var windowKey: String {
        CanvasFanWindowState.key(nodeId: stateKey, styleTag: "fan")
    }

    /// 把当前起点写回登记处。所有改 `windowStart` 的地方都要走这里，漏一处就等于那条路径"不记得"。
    private func persistWindowStart(_ v: Int) {
        CanvasFanWindowRegistry.shared.set(v, for: windowKey)
    }

    /// 扇形展开动画。用户明确指定的参数，不要顺手改成 `Anim.transition`。
    private static let fanSpring = Animation.spring(response: 0.35, dampingFraction: 0.72)
    private var expanded: Bool { nodeHovered }

    /// 几何量直通（★ 十轮：不再乘 `renderScale`，理由见 `CanvasNodeCardView` 的类型注释）。
    private func s(_ v: CGFloat) -> CGFloat { max(0.01, v) }

    /// 字号直通（设计 pt）。文字与卡片等比缩放，不做任何反向补偿。
    private func fs(_ v: CGFloat) -> CGFloat { max(1, v) }

    /// 卡片在屏幕上是否大到值得写字（阈值比节点那条更低，见 `CanvasNodeText`）。
    ///
    /// ★ 十轮：九轮这里还有一个 `cardTextCounter(_:)`，用来把 hover 的 `scaleEffect(1.08)`
    /// 也反向抵掉（否则"鼠标扫过的那张卡字比邻卡大 8%"）。等比缩放架构下这个问题自动消失：
    /// 文字跟着卡片一起放大 8% 本来就是 hover 该有的效果。
    private func cardTextVisible(_ cardSize: CGSize) -> Double {
        CanvasNodeText.cardTextVisible(cardSize: cardSize, zoom: gateZoom) ? 1 : 0
    }

    // MARK: - 卡片来源切片

    private var total: Int { max(sources.count, 1) }

    /// 窗口容量：扇形 5 张（★ 九轮：轮播的 3 张随风格一起删了）。
    private var windowCapacity: Int { CanvasFanGeometry.maxCards }

    /// 当前翻页窗口（★ v2.11.8 三轮，取代二轮的「前 5 张 + `+N` 网格浮层」）。
    ///
    /// 二轮把超出的卡片收进一个缩略图网格浮层，用户实测的结论是「第 6 张以后看不到」——
    /// 网格是另一种呈现，第 6 张从未以卡片形态出现。三轮改成真正的窗口翻页，几何与边界在
    /// `CanvasFanPaging` 里，本视图只负责把窗口翻译成 SwiftUI。
    private var window: CanvasFanGeometry.CardWindow {
        CanvasFanGeometry.cardWindow(total: sources.count,
                                     start: windowStart,
                                     maxCards: windowCapacity)
    }

    /// 当前渲染的卡片：`(全量下标, 内容)`。
    ///
    /// 带着**全量下标**走是关键：操作气泡、`onPromoteInput`、单卡删除都要作用到真实附件，
    /// 页内下标一旦泄漏到这些地方，翻到第 2 页点"设为入参"就会置顶错的那张图。
    private var visibleCards: [(index: Int, source: CanvasFanGeometry.CardSource)] {
        guard !sources.isEmpty else { return [(index: 0, source: .empty)] }
        return window.indices.map { (index: $0, source: sources[$0]) }
    }

    // MARK: - 尺寸

    /// 扇形态卡片尺寸（1x）。★ 五轮搬到 Kit（`CanvasFanGeometry.fanCardSize`）——
    /// hover 维持区要按"这叠卡能张多宽"外扩，两处各写一份 `0.82` 迟早会不一致。
    private var fanCardSize: CGSize {
        CanvasFanGeometry.fanCardSize(boxHeight: boxHeight)
    }

    /// `+N / 点击加载` 这两行固定字号的文字块，在给定灰卡尺寸下装不装得下（**整块**判定）。
    ///
    /// ★ 十轮：全仓统一设计单位后，这里就是同一量纲的两个数直接比大小 —— 八轮"文字漫出灰卡"
    /// 那个 bug（一边乘缩放一边不乘）在架构层面已经不可能再出现，这个判定只剩"字号太大/卡太小"
    /// 这一种真实情形（`+N` 用 18pt，灰卡在小节点上可能只有十几 pt 高）。
    private func overflowLabelFits(_ cardSize: CGSize) -> Bool {
        let need = CanvasNodeText.lineHeight(18) + CanvasNodeText.lineHeight(7.5) + 2
        return cardSize.height >= need
    }

    /// ★ 九轮：风格只剩扇形，卡尺寸不再随风格分叉。签名保留 `containerWidth` 是因为调用点
    /// 都在 `GeometryReader` 里，留着它以后要做"按容器收敛"不用再改一圈调用方。
    private func activeCardSize(containerWidth: CGFloat) -> CGSize { fanCardSize }

    // MARK: - 布局

    /// 本页要摆的全部位置的布局。
    ///
    /// ★ 三轮：位置数 = 牌面数 + （需要「+N」灰卡时的 1）。多出来的那一格由 `overflowCardLayer`
    /// 渲染，但**必须走同一套几何**，否则灰卡的角度/错位跟旁边的牌面对不上。
    private func layouts(containerWidth: CGFloat) -> [CanvasFanGeometry.CardLayout] {
        let slotCount = sources.isEmpty ? 1 : window.slotCount
        return CanvasFanGeometry.layouts(count: slotCount,
                                         expanded: expanded,
                                         // 同轮播分支：命中层记的是**全量**下标，布局要的是页内位置。
                                         // 翻到第 2 页后（windowStart=4）不换算的话，hover 第 5 张
                                         // 会去抬起页内第 5 格 —— 那是「+N」灰卡，抬错人。
                                         hoveredIndex: hoveredCard.flatMap { global in
                                             visibleCards.firstIndex { $0.index == global }
                                         })
    }

    /// 「+N」灰卡所在的 slot 下标（`nil` = 本页没有灰卡）。
    ///
    /// 布局里它永远是最后一格：`layouts(count:)` 的上界是 `maxCards + 1`，第 6 格专门留给它。
    private var overflowSlot: Int? {
        window.showsOverflowCard ? window.count : nil
    }

    private var activeSpring: Animation { CanvasSlotFanStack.fanSpring }

    /// **翻页**用的曲线。★ 九轮：轮播那条专用侧滑曲线随风格删除，扇形翻页是"原地换内容"，
    /// 平移量很小，直接用展开曲线。
    private var pagingSpring: Animation { activeSpring }

    // MARK: - body

    var body: some View {
        GeometryReader { geo in
            // 命中数学全在 1x 空间做（几何常量都是 1x），所以进来先把容器尺寸还原成 1x。
            let box = geo.size
            let cardSize = activeCardSize(containerWidth: box.width)
            let ls = layouts(containerWidth: box.width)

            ZStack {
                // 0) 「+N」灰卡：★ 五轮**沉到所有牌面之下**。
                //
                //    三轮把它单独提到 `zIndex(350)`，理由是"翻页入口要能点"。那个理由是错的：
                //    半透明灰卡压在牌面上，等于给右边两三张内容卡蒙了一层灰（用户截图 image-351a7cbf
                //    里的照片卡和音频卡都被压暗了），把"还有更多"的提示做成了"内容看不清"。
                //    它现在只是**纯展示**，可点性由命中层负责（见 hitLayer 的 overflowSlot 分支）——
                //    灰卡在扇形最外侧、与邻卡差 20° 张角，右侧本来就露出一大块楔形，够点。
                if window.showsOverflowCard, let slot = ls.last {
                    overflowCardLayer(slot, cardSize: cardSize)
                        .allowsHitTesting(false)
                        .zIndex(-1)
                }

                // 1) 卡片层：纯展示，**不接事件**（见 hitLayer 注释）。
                cardsLayer(ls, cardSize: cardSize)
                    .allowsHitTesting(false)

                // 2) 命中层：整块透明，自己算落在哪张卡上（含「+N」灰卡那一格）。
                hitLayer(ls, cardSize: cardSize, box: box)

                // 3) 角标层：收拢态的 +（加入参）。要能点，所以放在命中层之上。
                badgeLayer(ls, cardSize: cardSize)

                // 4) 左右翻页箭头：★ 三轮起两种风格都有（用户要求「展示区左右」），
                //    不再是轮播专属。
                if expanded && (window.hasPrev || window.hasNext) {
                    arrowsLayer(box: box)
                }

                if let opened = openedCard {
                    actionBubble(for: opened)
                        .zIndex(500)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // hover 离开整个节点时把浮层收掉：留一个悬在别处的黑气泡会被当成渲染残留。
        .onChange(of: nodeHovered) { hovering in
            if !hovering {
                hoveredCard = nil
                openedCard = nil
                overflowHot = false
            }
        }
        // ★ 六轮：视图重建（右键 `.contextMenu` 重新求值 / 画布↔编辑页 unmount-remount）后把窗口
        // 起点从登记处读回来。此前它是纯 `@State`，重建即归零 —— 用户看到的就是"卡片顺序自己变了"。
        .onAppear {
            lastSourceCount = sources.count
            let restored = CanvasFanWindowRegistry.shared.start(for: windowKey,
                                                               total: sources.count,
                                                               capacity: windowCapacity)
            if restored != windowStart { windowStart = restored }
        }
        // 内容变了（切槽位 / 附件增删）就重置**交互态**；但窗口起点不再无条件归零。
        //
        // 旧代码这里写 `windowStart = 0`：拖入一张新图（数组尾部）→ 窗口跳回第一页 → 新图片被翻页
        // 藏起来，用户的观感就是"我刚拖进来的图不在第 1 张、顺序乱了"。现在按数量的变化方向处理：
        // 变多 → 把新增那张露出来；变少 → 只钳制（连删几张不该每删一次都翻回第一页）。
        .onChange(of: sources.count) { newCount in
            hoveredCard = nil
            openedCard = nil
            let old = lastSourceCount < 0 ? newCount : lastSourceCount
            lastSourceCount = newCount
            let next = CanvasFanWindowState.startAfterCountChange(oldTotal: old,
                                                                  newTotal: newCount,
                                                                  start: windowStart,
                                                                  capacity: windowCapacity)
            if next != windowStart { windowStart = next }
            persistWindowStart(next)
        }
    }

    // MARK: - 卡片层

    private func cardsLayer(_ ls: [CanvasFanGeometry.CardLayout],
                            cardSize: CGSize) -> some View {
        ZStack {
            // 只渲染牌面位（`visibleCards`）。当 `window.showsOverflowCard` 时 `ls` 会多出最后一格，
            // 那一格属于「+N」灰卡，由 `overflowCardLayer` 单独画（它要能点，不能待在这个
            // `allowsHitTesting(false)` 的层里）。
            // ★ 七轮：`id` 从"位置下标"改成"位置 + 内容身份"。
            //
            // 用户报「翻页后同屏出现两张一模一样的图」。窗口本身摊开是严格递增无重复的
            // （`CardWindow.indicesAreSane` 钉住），所以重复只可能出现在渲染层：
            // 以位置为 id 时，翻页只是"同一个视图换了 source"，SwiftUI 复用视图实例、
            // `CanvasAttachmentPreviewImage` 里那个 `@State image` 跟着留在原位，
            // 于是新附件的缩略图解出来之前（甚至旧附件的异步回调迟到时）位置上显示的是**上一页那张图**
            // —— 而那张图往往正好也在新窗口里，同屏就出现两张相同的图。
            // 把内容身份编进 id 后，换内容 = 换视图，旧的 @State 一并作废。
            ForEach(ls.filter { visibleCards.indices.contains($0.index) },
                    id: \.index) { layout in
                let card = visibleCards[layout.index]
                cardView(layout,
                         globalIndex: card.index,
                         source: card.source,
                         cardSize: cardSize)
                    .id("\(layout.index)#\(cardIdentity(card.source, globalIndex: card.index))")
                    // 翻页转场：★ 九轮起只剩扇形，卡片是"原地换内容"，纯淡入淡出即可
                    // （八轮那套带方向的侧滑是轮播专用的，随风格一起删了）。
                    //
                    // 仍然挂在 `.id(...)` **外面**：`.id` 是身份边界，翻页时被销毁/新建的是它标识的
                    // 那个节点，转场写在边界内部会被父级 diff 忽略，退化成硬切（八轮真机踩过）。
                    .transition(.opacity)
            }
        }
    }

    /// 牌面内容身份：喂给 SwiftUI 的 `.id`，用来在翻页时强制**替换**而不是复用视图（★ 七轮）。
    private func cardIdentity(_ source: CanvasFanGeometry.CardSource, globalIndex: Int) -> String {
        switch source {
        case .empty:
            return "empty"
        case .textSegment(let text):
            // 文本段没有稳定 id，用"全量下标 + 内容哈希"：内容一样就没必要重建。
            return "text-\(globalIndex)-\(text.hashValue)"
        case .attachmentIndex(let index):
            let a = index < attachments.count ? attachments[index] : nil
            return "att-\(index)-\(a?.id.uuidString ?? "nil")"
        }
    }

    private func cardView(_ layout: CanvasFanGeometry.CardLayout,
                          globalIndex: Int,
                          source: CanvasFanGeometry.CardSource,
                          cardSize: CGSize) -> some View {
        let isHot = (hoveredCard == globalIndex)
        return cardBody(source)
            .frame(width: s(cardSize.width), height: s(cardSize.height))
            // ★ 八轮：牌面内容按卡片轮廓裁剪。
            //
            // 需求 1 让卡内文字变成屏幕固定字号，缩小画布时"7 行文字卡"的排版高度会超过卡片本身
            // （卡片高度仍按 zoom 缩）。SwiftUI 不裁剪溢出的子视图，不裁的话文字会漏在卡片外面、
            // 盖住邻卡 —— 这与 hotfix20「图片溢出盖住按钮」是同一类故障，那次的结论就是
            // "先钉尺寸再裁剪"。裁在 `background` 之前，所以白底与描边不受影响。
            .clipShape(RoundedRectangle(cornerRadius: s(17), style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: s(17), style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: s(17), style: .continuous)
                    .stroke(Color.white, lineWidth: s(2.6))
            )
            // 卡片边缘再压一道极淡的灰线：纯白卡叠在浅色预览底上时，白描边本身是看不见的，
            // 少了这道线整叠卡会糊成一团。
            .overlay(
                RoundedRectangle(cornerRadius: s(17), style: .continuous)
                    .stroke(Color.black.opacity(0.10), lineWidth: s(0.6))
            )
            // ★ 七轮：参考卡的灰遮罩已整套删除。
            //
            // 三~六轮这里压着一层 `Color.black.opacity(0.4)`，目的是标记"这张是上一页残留的参考卡"。
            // 用户录屏实测的观感是「点了 +2 之后第一张图片变灰」并明确要求去掉，所以牌面现在一律全亮 ——
            // 不加遮罩、也不降 opacity（降 opacity 会让下面那张卡透出来，看着像渲染错误）。
            // 投影刻意保持"小半径、偏淡"：扇形态卡片几乎完全重叠，大半径投影会互相叠加成一团
            // 灰雾（五轮那次"灰卡压暗牌面"就是同一类视觉事故）。
            .shadow(color: Color.black.opacity(isHot ? 0.26 : 0.16),
                    radius: s(isHot ? 9 : 5),
                    x: 0,
                    y: s(isHot ? 5 : 2.5))
            .scaleEffect(layout.scale, anchor: .bottom)
            .rotationEffect(.degrees(layout.angle), anchor: .bottom)
            .offset(x: s(layout.offset.width), y: s(layout.offset.height))
            .zIndex(layout.zIndex)
            .animation(activeSpring, value: expanded)
            .animation(activeSpring, value: hoveredCard)
            .animation(pagingSpring, value: windowStart)
    }

    @ViewBuilder
    private func cardBody(_ source: CanvasFanGeometry.CardSource) -> some View {
        switch source {
        case .attachmentIndex(let idx):
            if attachments.indices.contains(idx) {
                let att = attachments[idx]
                // ★ 三轮：按类别分两种牌面。
                //
                // 三轮之前只有图片这一条路，非图像附件（用户截图里的 `.command` / `.md` / `.mp3`）
                // 压根不进 `sources`，卡片上凭空少两张 —— 而堆叠卡片的全部意义就是把"装了几件东西"
                // 变成视觉信息，少画就等于报了个错的数（见 `CanvasAttachmentKind`）。
                if att.canvasIsImageLike {
                    // 用 Color.clear 定尺 + overlay 承载图片 + clipped：`aspectRatio(.fill)` 会溢出，
                    // 而 ZStack 不裁剪 —— 这正是 hotfix20「图片错位盖住按钮」的根因，别改回去。
                    Color.clear
                        .overlay(CanvasAttachmentPreviewImage(attachment: att, maxPixel: 360))
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: s(14), style: .continuous))
                        .padding(s(2.6))
                } else {
                    fileCardBody(att)
                }
            } else {
                emptyCardBody()
            }

        case .textSegment(let text):
            Text(text)
                // ★ 十轮：卡内文字与卡片等比缩放（设计 pt 直通）。
                .font(.system(size: fs(10.5)))
                .foregroundColor(.black.opacity(0.78))
                .lineLimit(7)
                .multilineTextAlignment(.leading)
                // ★ 三轮：卡内文字也禁自动收紧 / 自动缩字，理由同节点正文（见 CanvasNodeCardView）。
                .allowsTightening(false)
                .minimumScaleFactor(1.0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(s(8))
                // 卡片缩到指甲盖大小就别写字了（阈值见 `CanvasNodeText`）。
                .opacity(cardTextVisible(fanCardSize))

        case .empty:
            emptyCardBody()
        }
    }

    /// 非图像入参文件的牌面：深灰卡 + 类型图标 + 文件名（最多 2 行）。
    ///
    /// 用户指定「背景用深灰色卡片，和图片卡片风格一致」：所以外框圆角/描边/阴影完全沿用
    /// `cardView` 那一套（本视图只画内容），这里只把内容区铺成深灰。
    private func fileCardBody(_ att: SlotContent.SlotAttachment) -> some View {
        let name = att.name.isEmpty ? (att.path.map { ($0 as NSString).lastPathComponent } ?? "文件") : att.name
        let kind = CanvasAttachmentKind.from(fileName: att.path ?? att.name)
        return RoundedRectangle(cornerRadius: s(14), style: .continuous)
            .fill(Color(red: 0.16, green: 0.17, blue: 0.19))
            .overlay(
                VStack(spacing: s(6)) {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: s(19), weight: .regular))
                        .foregroundColor(.white.opacity(0.92))
                    Text(name)
                        .font(.system(size: fs(8.5), weight: .medium))
                        .foregroundColor(.white.opacity(0.78))
                        .opacity(cardTextVisible(fanCardSize))
                        .lineLimit(CanvasAttachmentKind.cardNameLineLimit)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                        .allowsTightening(false)
                        .minimumScaleFactor(1.0)
                }
                .padding(.horizontal, s(6))
            )
            .padding(s(2.6))
            .help("\(kind.displayName)：\(name)")
    }

    private func emptyCardBody() -> some View {
        RoundedRectangle(cornerRadius: s(14), style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: s(1.4), dash: [s(4), s(3)]))
            .foregroundColor(Color.black.opacity(0.22))
            .overlay(
                VStack(spacing: s(4)) {
                    Image(systemName: "tray")
                        .font(.system(size: s(15), weight: .light))
                    Text("空槽位")
                        .font(.system(size: fs(9), weight: .medium))
                        .opacity(cardTextVisible(fanCardSize))
                }
                .foregroundColor(Color.black.opacity(0.35))
            )
            .padding(s(3))
    }

    // MARK: - 命中层

    /// 统一命中层：一整块透明视图，鼠标位置 → 卡片下标由 `CanvasFanGeometry.hitTest` 判定。
    ///
    /// ## 为什么不能让每张卡片各自 `.onHover`（v2.11.8 二轮，用户实测反馈的根因）
    ///
    /// 一轮就是那么写的，用户的原话是「展开很难选到第二个」「最后那个又没有办法选择中间的」。
    /// 录屏分析后确认：卡片是**不透明的白卡且右压左**（当时 zIndex 递增；四轮已按用户要求翻成
    /// 左压右，见 `CanvasFanGeometry.layouts` —— 下面这段讲的是"为什么不能各自 onHover"，
    /// 与层级朝哪边无关，翻转后一字不改仍然成立），旋转 17° 后相邻两卡在下半部
    /// 几乎完全重合 —— 每张卡"只属于自己"的可点区域是靠顶端一道窄楔形。SwiftUI 的命中是逐视图的，
    /// 谁在上面谁吃事件，于是中间那几张剩下的有效面积只有几个像素宽；更糟的是鼠标横向移动时会
    /// 连续穿过好几张卡的边缘，`hoveredCard` 疯狂改写，卡片跟着抖，观感像是"选不中"。
    ///
    /// 换成统一命中层后：
    ///   - 命中顺序由 `hitTest` 按 **zIndex 从高到低**遍历，与视觉遮挡严格一致（看到谁点到谁）；
    ///   - 判定用的是**旋转后的真实四边形**（`cardPolygon`），不是未旋转的包围盒 ——
    ///     20° 下包围盒会比实际卡片胖出十几 pt，用它判定会出现"点在空白处却选中了卡片"；
    ///   - 只有一个视图接事件，不存在子视图之间来回抢 hover 的抖动。
    ///
    /// 点击用 `DragGesture(minimumDistance: 0)` 而不是 `onTapGesture`：后者在 macOS 13 上
    /// **拿不到点击坐标**，而这里的全部前提就是"我需要知道你点在哪"。
    private func hitLayer(_ ls: [CanvasFanGeometry.CardLayout],
                          cardSize: CGSize,
                          box: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    let p1x = p
                    // 收拢态不做单卡 hover：卡片几乎完全重叠，此时"单卡放大"只会让最前面那张
                    // 无缘无故抖一下，用户根本分不清自己指的是哪一张。
                    guard expanded else {
                        if hoveredCard != nil { hoveredCard = nil }
                        return
                    }
                    let hit = CanvasFanGeometry.hitTest(point: p1x,
                                                        layouts: ls,
                                                        cardSize: cardSize,
                                                        containerSize: box)
                    // ★ 五轮：「+N」灰卡不再是独立浮层，它就是 `ls` 的最后一格，可点性走这里。
                    let onOverflow = (hit != nil && hit == overflowSlot)
                    if overflowHot != onOverflow { overflowHot = onOverflow }
                    let global = hit.flatMap { local -> Int? in
                        visibleCards.indices.contains(local) ? visibleCards[local].index : nil
                    }
                    if hoveredCard != global { hoveredCard = global }
                case .ended:
                    if hoveredCard != nil { hoveredCard = nil }
                    if overflowHot { overflowHot = false }
                }
            }
            // ★ 六轮：`gesture` → `highPriorityGesture`，把这块区域的点击**独占**下来。
            //
            // ## 用户报的现象
            //
            // 「点击『+2 点击加载』灰卡后，弹出了导入文件侧边栏，触发了新建导入流程」。
            //
            // ## 为什么普通 `.gesture` 不够
            //
            // 节点卡片的祖先上挂着两个东西（`CanvasWorkspaceView.nodeLayer`）：
            // `onTapGesture { canvas.select(...) }` 和 `.contextMenu { ... }`。
            // 默认优先级下 SwiftUI 会让这两条与命中层的 `DragGesture` **同时参与识别**，实测后果是
            // 一次点击既走了翻页、又把节点选中了 —— 选中会改 `canvas.selectedNodeIds`（@Published），
            // 节点子树跟着重新求值，`isHovering` / `windowStart` 这些 `@State` 在重建里被打回初值：
            // 扇形当场收拢回一叠。收拢态右下角那颗 `+` 角标（`plusBadge` → `onOpenInputFiles`）
            // 正好落在用户刚才点的那片区域，紧接着的第二下就点进了「入参文件」面板 ——
            // 用户看到的"点 +N 弹出导入文件侧边栏"就是这么来的。
            //
            // `highPriorityGesture` 让命中层**先于祖先**吃掉这次点击：不再触发选中、不再重建、
            // 扇形不收拢，`+N` 老老实实翻页。选中这件事不能就这么丢掉，所以下面在"非 +N"的分支里
            // 显式调 `onActivateNode()` 补回来 —— 唯独点 `+N` 不选中：翻页是纯浏览动作，
            // 没有任何理由顺手改选中状态、顺手触发一轮全局重绘。
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        // 拖动过就不算点击：画布上按住卡片拖是"移动节点"，不该顺手弹个气泡。
                        let moved = hypot(value.translation.width, value.translation.height)
                        guard moved < 4 else { return }
                        let p1x = value.location
                        let local0 = CanvasFanGeometry.hitTest(point: p1x,
                                                              layouts: ls,
                                                              cardSize: cardSize,
                                                              containerSize: box)
                        // ★ 五轮：点在「+N」灰卡露出的那块楔形上 = 翻页。
                        // 灰卡沉到牌面之下后，能被 hitTest 选中的只有它没被邻卡盖住的部分，
                        // 语义正好是"看得见才点得到"，与其它卡一视同仁。
                        //
                        // ★ 六轮：只在**展开态**认这一格。收拢态下这张灰卡完全埋在牌面之下、
                        // 一个像素都看不见，此时"点到看不见的东西然后页面自己翻了"是纯粹的意外。
                        if expanded, let local = local0, local == overflowSlot {
                            pageForward()
                            return
                        }
                        // 走到这里说明点的是真牌面或空白 —— 把祖先被抢掉的"选中节点"补回来。
                        onActivateNode()
                        guard let local = local0,
                              local != overflowSlot,
                              visibleCards.indices.contains(local) else {
                            withAnimation(activeSpring) { openedCard = nil }
                            return
                        }
                        let global = visibleCards[local].index
                        withAnimation(activeSpring) {
                            openedCard = (openedCard == global) ? nil : global
                        }
                    }
            )
    }

    // MARK: - 角标层

    /// 角标层：**只剩**收拢态最前面那张卡右下角的 `+`（直通入参文件面板）。
    ///
    /// ★ 三轮删掉了展开态的 `+N` 角标 —— 它被第 6 个位置上那张真正可翻页的灰卡取代
    /// （见 `overflowCardLayer`）。角标 + 缩略图网格那套是"另一种呈现"，用户的判断是
    /// 「第 6 张以后看不到」，因为第 6 张从来没以卡片形态出现过。
    ///
    /// 单独成层是因为卡片层被 `allowsHitTesting(false)` 关掉了事件 —— 角标是**要能点的**，
    /// 只能自己带着同一套变换独立渲染一遍。
    ///
    /// ★ 四轮：层级翻转后"最前面那张"由最右变成**最左**（下标 0），这里取的是 `zIndex` 最大者，
    /// 所以角标自动跟着走 —— 千万别改成写死 `ls.last`，那样角标会被压到卡片底下变成点不着的死按钮。
    @ViewBuilder
    private func badgeLayer(_ ls: [CanvasFanGeometry.CardLayout],
                            cardSize: CGSize) -> some View {
        // ★ 三轮：展开态不再画 `+N` 角标（它被真正的翻页卡取代，见 overflowCardLayer）。
        // 收拢态照旧只有「+ 加入参」。
        if !expanded, let top = ls.max(by: { $0.zIndex < $1.zIndex }) {
            badgeAnchor(top, cardSize: cardSize) { plusBadge }
        }
    }

    /// 把角标摆到某张卡片的右下角：用一个与卡片同尺寸的透明框走同一套变换，再 overlay 角标。
    private func badgeAnchor<Content: View>(_ layout: CanvasFanGeometry.CardLayout,
                                            cardSize: CGSize,
                                            @ViewBuilder _ content: () -> Content) -> some View {
        Color.clear
            .frame(width: s(cardSize.width), height: s(cardSize.height))
            .overlay(alignment: .bottomTrailing) { content() }
            .scaleEffect(layout.scale, anchor: .bottom)
            .rotationEffect(.degrees(layout.angle), anchor: .bottom)
            .offset(x: s(layout.offset.width), y: s(layout.offset.height))
            .animation(activeSpring, value: expanded)
            .zIndex(300)
    }

    /// 右下角 + 角标：把「这叠卡还能加东西」摆到明处，点它直通入参文件面板。
    private var plusBadge: some View {
        Button(action: onOpenInputFiles) {
            Image(systemName: "plus")
                .font(.system(size: s(9), weight: .bold))
                .foregroundColor(.white)
                .frame(width: s(19), height: s(19))
                .background(Circle().fill(AppTheme.chromeAccentInk))
                .overlay(Circle().stroke(Color.white, lineWidth: s(1.6)))
                .shadow(color: .black.opacity(0.2), radius: s(2), x: 0, y: s(1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("添加入参文件")
        .offset(x: s(5), y: s(5))
    }

    // MARK: - 「+N」翻页卡（v2.11.8 三轮）

    /// 第 6 个位置那张**灰色半透明「+N」卡**（用户逐条指定的样式：深灰、opacity 0.5、
    /// 中心大号 `+N` 白字、下面小字「点击加载」、形状与其他卡完全一致）。
    ///
    /// 它取代了二轮的「右下角 +N 角标 + hover 缩略图网格」。二轮那套的问题不是不好看：
    /// 网格里的小方格是**另一种呈现**，第 6 张卡从未以"卡片"形态出现过，所以用户的结论就是
    /// 「第 6 张以后看不到」。这张灰卡把"后面还有"直接放在卡叠的下一个位置上，点它就翻页。
    /// ★ v2.11.8 五轮：**改成纯展示层，沉到所有牌面之下**（用户明确指出三轮的 `zIndex(350)` 是错的）。
    ///
    /// 三轮把它当"控件必须浮在最上层"处理，结果半透明灰卡给右侧两三张内容卡蒙了灰（截图
    /// image-351a7cbf：照片卡、音频卡都被压暗）。用户的判断是对的 —— 它**不需要**浮起来：
    /// 灰卡与左邻卡有 20° 张角差，右侧露出的是一整块楔形（不是"12pt 的斜边"，三轮那句注释
    /// 把 `expandedStagger` 当成了露出宽度，漏算了旋转），命中层照样点得到。
    ///
    /// 于是这里不再是 `Button`：点击与 hover 都走 `hitLayer`（`overflowSlot` 分支），
    /// 与其它卡片共用同一套"旋转后多边形 + zIndex 从高到低"的命中语义。
    private func overflowCardLayer(_ layout: CanvasFanGeometry.CardLayout,
                                   cardSize: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: s(17), style: .continuous)
                .fill(Color(red: 0.20, green: 0.21, blue: 0.23))
            VStack(spacing: s(2)) {
                Text("+\(window.remaining)")
                    .font(.system(size: fs(18), weight: .bold))
                    .foregroundColor(.white)
                Text("点击加载")
                    .font(.system(size: fs(7.5), weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
            }
            .allowsTightening(false)
            .minimumScaleFactor(1.0)
            .fixedSize()
            // `fixedSize()` 让这个两行块保持固定字号的自然尺寸 —— 缩小画布时它会比灰卡本身还大，
            // 于是漫出卡片、糊在邻卡上（八轮真机 25% 缩放实拍到）。
            //
            // ★ 九轮：判据从"逐行塞不下就藏那一行"改成**整块**判定 —— 灰卡的排版高度装不下整块
            // 就整块不画（灰卡照旧显示，用户仍看得到"后面还有几张"）。这与用户九轮的规格同构：
            // 隐藏的粒度是"一个文字块"，不是"块里的某一行"。
            .opacity(overflowLabelFits(cardSize) ? 1 : 0)
            // ★ 五轮：文字挪到**露出的那块楔形**的重心上，不再居中。
            //
            // 沉到牌面之下后，卡片中心正好是被左邻卡盖住的地方 —— 居中的文字一个像素都看不见
            // （实机截图 v5-crop 只剩一条白描边）。锚点由几何算出来（见 `overflowLabelAnchor`），
            // 用比例而不是固定 pt：卡片尺寸随节点高度收敛，写死 18pt 在小节点上会顶出楔形。
            .offset(x: s(cardSize.width * (CanvasFanGeometry.overflowLabelAnchor.x - 0.5)),
                    y: s(cardSize.height * (CanvasFanGeometry.overflowLabelAnchor.y - 0.5)))
        }
        .frame(width: s(cardSize.width), height: s(cardSize.height))
        // 半透明是"这不是一张真牌面"的唯一视觉线索，别顺手改成 1.0。
        // 鼠标压在露出的楔形上时提浓一点 —— 沉到底层之后，这是"我可以点"的唯一反馈
        // （原来是 Button，靠 hover 光标和整卡可点性表达）。
        .opacity(overflowHot ? CanvasFanGeometry.overflowCardHotOpacity
                             : CanvasFanGeometry.overflowCardOpacity)
        .overlay(
            RoundedRectangle(cornerRadius: s(17), style: .continuous)
                .stroke(Color.white.opacity(overflowHot ? 0.6 : 0.35), lineWidth: s(1.2))
        )
        .help("还有 \(window.remaining) 张，点击加载")
        .scaleEffect(layout.scale, anchor: .bottom)
        .rotationEffect(.degrees(layout.angle), anchor: .bottom)
        .offset(x: s(layout.offset.width), y: s(layout.offset.height))
        .animation(activeSpring, value: expanded)
        .animation(activeSpring, value: windowStart)
        .animation(.easeOut(duration: 0.12), value: overflowHot)
    }

    // MARK: - 翻页

    /// 前进一页。步长 = 整页容量（七轮起是固定栅格分页，不再重叠参考卡），到底回到开头（用户指定）。
    ///
    /// ★ 六轮：这里**只翻页**。用户报的「点『+2 点击加载』弹出了导入文件侧边栏」是命中被祖先
    /// 手势抢走后的连锁反应（详见 `hitLayer` 里 `highPriorityGesture` 的注释）——
    /// 这个函数从来不碰导入，也绝不允许以后往里加。
    ///
    private func pageForward() {
        let target = CanvasFanGeometry.forwardStart(from: window)
        withAnimation(pagingSpring) {
            hoveredCard = nil
            openedCard = nil
            windowStart = target
        }
        persistWindowStart(target)
    }

    /// 后退一页（整页回退，见 `CanvasFanGeometry.backwardStart`）。
    private func pageBackward() {
        let target = CanvasFanGeometry.backwardStart(from: window, maxCards: windowCapacity)
        withAnimation(pagingSpring) {
            hoveredCard = nil
            openedCard = nil
            windowStart = target
        }
        persistWindowStart(target)
    }

    // MARK: - 左右翻页箭头

    /// 左右翻页箭头。**只在该方向确实有内容时出现**（用户指定）。
    ///
    /// 一个例外：到达末尾后右箭头仍然显示 —— 它此时的语义是"回到开头"（用户明确要求这个循环），
    /// 若按"没有下一页就藏起来"处理，用户翻到底就只能一路 ⬅ 退回去。
    private func arrowsLayer(box: CGSize) -> some View {
        HStack {
            if window.hasPrev {
                arrowButton("chevron.left", forward: false)
            } else {
                Spacer().frame(width: s(18))
            }
            Spacer(minLength: 0)
            if window.hasNext || window.hasPrev {
                arrowButton("chevron.right", forward: true)
            }
        }
        // ★ 五轮：往里收 `arrowLaneInset`。原来箭头贴着预览区边缘 = 距节点边框只有 12pt，
        // 录屏里那次误收缩就是"伸手去点左箭头、过冲 12px 出了节点边界"。维持区 + 宽限期已经能
        // 兜住这种过冲，但让按钮本身离边界远一点是成本最低的一半。
        .padding(.horizontal, s(CanvasFanGeometry.arrowLaneInset))
        .frame(width: s(box.width))
        .zIndex(400)
    }

    private func arrowButton(_ symbol: String, forward: Bool) -> some View {
        Button {
            if forward { pageForward() } else { pageBackward() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: s(9), weight: .bold))
                .foregroundColor(.white)
                .frame(width: s(18), height: s(18))
                .background(Circle().fill(Color.black.opacity(0.55)))
                .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: s(1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(forward ? (window.hasNext ? "后面几张" : "回到开头") : "前面几张")
    }

    // MARK: - 操作气泡

    /// 点卡片弹出的黑色圆角气泡。
    ///
    /// 位置固定在整叠卡片的**正上方**，不跟着被点的那张卡飘：跟着飘的话相邻两张卡的气泡会
    /// 各偏 20~30pt，用户连点两张就会觉得气泡在乱跳；而气泡里已经写明了操作对象的类型。
    private func actionBubble(for index: Int) -> some View {
        let source = sources.indices.contains(index) ? sources[index] : .empty
        return HStack(spacing: s(2)) {
            bubbleButton("编辑", "pencil") {
                openedCard = nil
                switch source {
                case .textSegment, .empty: onEditText()
                case .attachmentIndex: onOpenInputFiles()
                }
            }
            bubbleDivider
            bubbleButton("复制", "doc.on.doc") {
                openedCard = nil
                copyCard(source)
            }
            if case .attachmentIndex(let ai) = source {
                bubbleDivider
                bubbleButton("打开", "arrow.up.forward.app") {
                    openedCard = nil
                    openCard(ai)
                }
                bubbleDivider
                bubbleButton("设为入参", "star") {
                    openedCard = nil
                    onPromoteInput(ai)
                }
                bubbleDivider
                // ★ 三轮：单卡删除。
                //
                // 用户明确区分了两件事：「卡片内单张图片的删除（非整个节点删除），允许直接删除
                // （不影响节点本身）」。所以这里**不弹确认**（删的只是一个入参引用，节点、槽位、
                // 正文都不动，且有 .trash 兜底），与"删节点"那条要弹 Alert 的路径是两套语义。
                bubbleButton("删除", "trash") {
                    openedCard = nil
                    onDeleteInput(ai)
                }
            }
        }
        .padding(.horizontal, s(5))
        .padding(.vertical, s(4))
        .background(
            RoundedRectangle(cornerRadius: s(11), style: .continuous)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: s(11), style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: s(0.8))
        )
        .shadow(color: .black.opacity(0.35), radius: s(10), x: 0, y: s(4))
        .offset(y: -s(bubbleLift))
        .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
    }

    /// 气泡相对预览区中心的上移量。
    ///
    /// 「卡片顶 + 22」是理想位置，但卡片几乎顶满预览区（`fanCardSize` 只比它矮 10pt），照这个抬
    /// 会把气泡顶到预览区外面，压在节点顶部的路径标识上——看起来像错位的浮层。所以再夹一道
    /// 上限：气泡整体必须留在预览区内（`bubbleHeight` 是气泡自身高度的估值）。
    private var bubbleLift: CGFloat {
        let ideal = fanCardSize.height / 2 + 22
        let bubbleHeight: CGFloat = 26
        let ceiling = max(0, boxHeight / 2 - bubbleHeight / 2 - 4)
        return min(ideal, ceiling)
    }

    private var bubbleDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: s(0.8), height: s(13))
    }

    private func bubbleButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: s(3)) {
                Image(systemName: symbol)
                    .font(.system(size: s(8.5), weight: .semibold))
                Text(title)
                    // 气泡按钮只在 hover 出现（此时节点必然够大），字号仍按屏幕固定处理，
                    // 保证与卡片上其它文字同一视觉尺寸。
                    .font(.system(size: fs(9.5), weight: .medium))
            }
            .foregroundColor(.white.opacity(0.94))
            .padding(.horizontal, s(6))
            .padding(.vertical, s(3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 「复制」的落地：文本进剪贴板、图片附件优先给**文件 URL**（能直接粘进 Finder / 其他 App），
    /// 只有内嵌字节的附件才退化成图片对象。
    private func copyCard(_ source: CanvasFanGeometry.CardSource) {
        let pb = NSPasteboard.general
        switch source {
        case .textSegment(let text):
            pb.clearContents()
            pb.setString(text, forType: .string)
            onToast("已复制文本")

        case .attachmentIndex(let idx):
            guard attachments.indices.contains(idx) else { return }
            let att = attachments[idx]
            if let path = att.path, !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                pb.clearContents()
                pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
                onToast("已复制文件")
            } else if let data = att.resolveData(), let image = NSImage(data: data) {
                pb.clearContents()
                pb.writeObjects([image])
                onToast("已复制图片")
            } else {
                // 断链的附件复制出去会是一个空剪贴板，静默失败比报错更难查。
                onToast("这个入参文件已断链，无法复制")
            }

        case .empty:
            onToast("空槽位没有可复制的内容")
        }
    }

    /// 「打开」的落地：用系统默认程序打开这个入参文件（★ v2.11.8 三轮，用户指定
    /// `NSWorkspace.shared.open(url)`）。
    ///
    /// 内嵌字节（无磁盘路径）的附件先落到临时目录再打开 —— 否则音频 / 文档这类不能内嵌预览的
    /// 附件在卡片上"点了没反应"，和三轮修的那个"入参文件入口点不开"是同一种体感。
    private func openCard(_ idx: Int) {
        guard attachments.indices.contains(idx) else { return }
        let att = attachments[idx]
        if let path = att.path, !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        guard let data = att.resolveData() else {
            onToast("这个入参文件已断链，无法打开")
            return
        }
        let name = att.name.isEmpty ? "入参文件" : att.name
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipslots-open-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let dst = tmp.appendingPathComponent(name)
            try data.write(to: dst)
            NSWorkspace.shared.open(dst)
        } catch {
            onToast("打开失败：\(error.localizedDescription)")
        }
    }
}
