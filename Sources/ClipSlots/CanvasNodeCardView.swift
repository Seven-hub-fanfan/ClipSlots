import SwiftUI
import ClipSlotsKit

/// 画布节点卡片（v2.11.8 · 二轮改版）。
///
/// 结构自上而下：
///
/// ```text
///   槽位节点 / 图像节点：  路径标识行  →  堆叠卡片预览  →  4 行正文预览  →  入参文件（整行）
///   纯文本节点：          路径标识行  →  深色纯文本框（占满）           →  入参文件（整行）
/// ```
///
/// ## 二轮为什么把「类型 / 状态 / 参数」三处信息全删了（用户逐条指定）
///
/// 一轮的卡片顶部是「图像生成」类型胶囊 + 右上「未生成」状态 + 铅笔按钮，底部还有一条
/// 「模型 · 比例 · 槽位名」参数栏。用户的原话是这些字样"不应该有"、"信息量很小"。这不是审美偏好，
/// 是**信息密度错配**：
///   - **类型**：卡片形态已经说明了一切（有堆叠卡片的是槽位/图像节点，一整块深色文本框的是文本节点），
///     再写一遍"图像生成"占掉的是整行宽度里最贵的位置。
///   - **未生成**：这是**所有**节点的默认状态。一个所有卡片都一样的标签不携带任何信息，
///     纯粹是噪声；真正需要提示的 `排队 / 生成中 / 失败` 仍然保留（见 `statusBadge`）。
///   - **模型 / 比例 / 槽位名**：出图参数属于"要改的时候才关心"，放在常驻位置每张卡都要占一行；
///     而槽位身份已经被顶部的路径标识精确表达了（还更准 —— 它带页面和组）。
///
/// 删掉之后腾出来的高度给了**正文预览 2 行 → 4 行**，这是用户明确要的：画布上扫一眼就能认出
/// 哪个节点装的是哪段提示词，而两行经常连主语都截断。
///
/// ## 关于尺寸：为什么每个数值都要乘 `renderScale`（v2.11.8 修「放大变模糊」）
///
/// 此前的做法是卡片内部一律按 1x 写，缩放由节点层外面一个 `scaleEffect(zoom)` 统一施加。那样确实
/// 省事，代价是**放大后全糊**：`scaleEffect` 是渲染期的仿射变换 —— SwiftUI 先按 1x 布局把文字光栅化
/// 成位图，再把位图放大 2 倍，于是 200% 缩放下看到的是 2 倍放大的 1x 字形，边缘发虚、细边框糊成灰带。
/// 这不是"设置项没打开抗锯齿"，是像素本来就不存在。
///
/// 唯一的解法是把缩放**下沉到布局**：字号、内边距、圆角、线宽全部按当前 zoom 重算，让 SwiftUI 在
/// 真实像素尺寸上重新排版并重新光栅化文字。代价是缩放时每张卡片都要重新布局（此前只是改一个变换
/// 矩阵）—— 这笔账必须付：矢量清晰度是画布的基本可用性，而节点数量在这个 App 的量级（几十张）
/// 下重排一次仍在一帧内。
///
/// 所以本文件的铁律：**所有几何量都过 `s(_:)`，不要出现裸的常量尺寸**。漏乘一个的表现是"放大后
/// 某个边距/字号不跟着变"，在 100% 缩放下完全看不出来。
///
/// ## 关于文本的来源（v2.11.7 hotfix18 → hotfix20）
///
/// 卡片**不缓存正文**，而是用外部传进来的 `text`。节点就是槽位，正文的唯一真相是 `SlotContent`。
/// 卡片自己去读槽位数据就得认识主 store，那会把画布重新拖回"任一槽位变化触发全局重绘"的老路
/// —— 所以取数留在上层，卡片保持纯展示。
struct CanvasNodeCardView: View {
    let node: CanvasNode
    let isSelected: Bool
    /// 正文实时值 = 该槽位的主体文本。
    let text: String
    /// 顶部居中的路径标识：`页面 - 槽位组 - 槽位`（由上层用 `CanvasCardText.pathLabel` 拼好）。
    ///
    /// ★ 二轮新增，替换掉原来的「图像生成」类型胶囊。上层拼而不是卡片自己拼：页面名和组名要查
    /// 主 store，而卡片刻意不认识 store（见类型注释）。
    let pathLabel: String
    /// 槽位的实时附件列表 = 画布语境下的**入参文件**（v2.11.7 hotfix20 改名）。
    ///
    /// 与 `text` 同源同理：真相在槽位数据里，卡片只负责展示，取数留在上层。
    let attachments: [SlotContent.SlotAttachment]
    /// 当前画布缩放。见类型注释：卡片按它**重新布局**，不靠位图缩放。
    let renderScale: CGFloat
    /// 文字的反向缩放（★ 九轮需求 1 的收口）= `CanvasZoomLayout.textCounterScale(zoom:layoutZoom:)`。
    ///
    /// 节点层挂着 `scaleEffect(zoom / layoutZoom)`，它会把已经固定成设计 pt 的字号再连带缩放 ——
    /// 这一项是那个残差的**精确倒数**：静息态 ≤1（档位不高于 zoom），缩小手势进行中会 >1
    /// （`layoutZoom` 冻结在旧档时必须放大补偿）。九轮起**不再钳制**，推导见
    /// `CanvasZoomLayout.textCounterScale`。
    /// 默认 1 = 不补偿，方便预览/测试构造。
    var textCounter: CGFloat = 1
    /// 是否处于 inline 编辑态（由上层集中管理，保证同一时刻只有一个节点在编辑）。
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCommitEdit: (String) -> Void
    let onCancelEdit: () -> Void
    /// 点「入参文件 N」按钮。弹层由上层（`CanvasWorkspaceView`）呈现 —— 它需要 `SlotStoreObservable`
    /// 才能增删改附件，而卡片刻意不认识主 store（见上面那段注释）。
    let onOpenInputFiles: () -> Void
    /// 把第 N 个附件挪到入参列表首位（堆叠卡片的「设为入参」）。写数据同样上抛。
    let onPromoteInput: (Int) -> Void
    /// 删掉第 N 个入参文件（堆叠卡片气泡里的「删除」）。★ v2.11.8 三轮：只动附件列表，
    /// **不删节点** —— 用户明确要求单张图片可以直接删掉且不影响节点本身。
    let onDeleteInput: (Int) -> Void
    /// 选中本节点。★ 六轮：堆叠卡片的命中层升级成 `highPriorityGesture` 独占点击后，祖先那条
    /// `onTapGesture { canvas.select(...) }` 不再触发，"点卡片顺带选中节点"必须由卡片自己补上。
    let onActivateNode: () -> Void
    /// 轻提示（复制成功 / 断链等）。卡片不认识 `transientUI`，同上。
    let onToast: (String) -> Void

    /// 上层按**光标坐标**判定的"这个节点仍应保持 hover"（★ v2.11.8 五轮）。
    ///
    /// 为什么需要它：`.onHover` 是边界即真理 —— 光标出节点边框那一帧就 `false`，扇形当场收拢、
    /// 翻页箭头随之消失。而左箭头距节点边框只有 12pt，"伸手去点箭头"这个动作本身就有很大概率
    /// 先摸出边界一下（录屏 20260916125646 f_035→f_036→f_037，0.33s 内闪了一次）。
    /// 上层用画布那个本来就在跑的 `.onContinuousHover` 拿到光标位置，按
    /// `CanvasNodeHover.holdRect`（节点 + 扇形包围盒 + 30pt）判定并带 200ms 宽限期。
    ///
    /// 两个信号是 **OR**：`.onHover` 负责"进入"（灵敏、零延迟），这个负责"维持"（宽容）。
    /// 万一上层的坐标通路失效，退化成三轮的行为，不会变成"永远不展开"。
    let isHoverHeld: Bool
    /// 把本卡片自己的 `.onHover` 结果报给上层（上层据此把维持对象锁到本节点）。
    let onHoverChanged: (Bool) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false
    @State private var draft = ""

    private func s(_ v: CGFloat) -> CGFloat { max(0.01, v * renderScale) }

    /// **文字**专用字号（★ v2.11.8 八轮 · 需求 1「画布文字不跟随缩放」）。
    ///
    /// 与 `s(_:)` 的唯一区别：**刻意不乘 renderScale**。为什么这是"抵消画布缩放"而不是"漏乘"，
    /// 完整推导见 `CanvasScreenText` 的类型注释（一句话版本：本项目静息时排版尺寸 = 屏幕尺寸，
    /// 所以想让屏幕字号恒为 13pt，排版时就得写 13）。
    ///
    /// 铁律更新：**几何量过 `s(_:)`，字号过 `fs(_:)`**。图标（SF Symbol）仍走 `s(_:)` ——
    /// 它们是按钮/角标的一部分，尺寸必须跟着容器走，否则放大后会出现"20pt 的圆里一个 8pt 的勾"。
    private func fs(_ v: CGFloat) -> CGFloat {
        CanvasScreenText.layoutFontSize(v, renderScale: renderScale)
    }

    /// 节点在屏幕上是否大到值得写字（★ 八轮需求 1 的第二半）。
    ///
    /// 用 `renderScale`（= `layoutZoom`）当 zoom 的替身，而不是把真正的实时 zoom 传进来：
    /// 实时 zoom 每帧都在变，用它做布尔判定会让缩放手势跨过阈值时文字**闪烁**；
    /// `layoutZoom` 是量化后的阶梯值（`CanvasZoomLayout`），最多与实时 zoom 差 18%，
    /// 落在 40pt 阈值上的误差远小于"文字该不该看得清"这件事本身的模糊度。
    private var textVisible: Bool {
        CanvasScreenText.textVisible(nodeSize: CGSize(width: node.width, height: node.height),
                                     zoom: renderScale)
    }

    /// 卡片纵向分区预算（★ 九轮）。文字行按固定行高先扣，可伸缩的预览区/正文区让位 ——
    /// 这样"某一行没有完整行高"从结构上不可能发生，不再需要八轮那套逐行隐藏。
    /// 推导见 `CanvasCardLayout.verticalPlan`。
    private var plan: CanvasCardLayout.VerticalPlan {
        CanvasCardLayout.verticalPlan(nodeHeight: node.height,
                                      renderScale: renderScale,
                                      headerFontSize: 9.5,
                                      footerFontSize: 9.5)
    }

    /// **整卡**文字可见性（★ 九轮，用户明确要求"整体 opacity = 0，不是逐行隐藏"）。
    ///
    /// 两个条件取 AND，都是整体判定：
    ///   - 节点视觉短边 ≥ 40pt（用户给的显式规格）；
    ///   - 卡片高度至少装得下"两行字 + 留白"（几何兜底，极扁的节点短边可能够 40pt 但高度不够）。
    ///
    /// 用 opacity 而不是 `if` 分支：避免跨阈值那一帧整卡重排。
    private var textOpacity: Double {
        // 文本节点没有预览区，用它自己那套预算判定 —— 拿出图节点的 `verticalPlan` 去判会**过早**
        // 隐藏（后者要为预览区/正文间距预留 52pt chrome，文本节点根本没有这些）。
        let fits = isTextNode ? textNodeFitPlan.fitsText : plan.fitsText
        return (textVisible && fits) ? 1 : 0
    }

    /// 文本节点文字可见性判定用的预算（**只**用于 opacity，不用于 frame）。
    ///
    /// 真正排版的那份在 `textNodeStack` 里由 `GeometryReader` 量出容器高度后重算 —— 这里用
    /// `node.height` 反推是为了让 opacity 不必穿透到子视图；差一帧对布尔判定无影响
    /// （相反，逐帧变化的容器高度会让文字在阈值附近闪烁）。
    private var textNodeFitPlan: CanvasCardLayout.TextNodePlan {
        let inner = node.height * renderScale - 2 * CanvasCardLayout.cardPadding * renderScale
        return CanvasCardLayout.textNodePlan(availableHeight: inner,
                                             renderScale: renderScale,
                                             headerFontSize: 9.5,
                                             footerFontSize: 9.5,
                                             bodyFontSize: node.resolvedBodyFontSize)
    }

    /// 纯文本节点：不出图，卡片主体就是一块文本框（用户二轮明确要求"不需要卡片预览的形式"）。
    private var isTextNode: Bool { node.kind == .text }

    /// 本节点是否处于"活跃 hover"（★ 五轮）：自身 `.onHover` **或**上层坐标维持。
    ///
    /// 边框高亮 / 风格切换按钮也一起走这个值，而不是只让扇形走 —— 光标在维持区里（正伸向翻页箭头）
    /// 时节点本来就该是活跃的；若边框先灭一下再亮回来，那种闪烁比扇形收拢更扎眼。
    private var hoverActive: Bool { isHovering || isHoverHeld }

    /// 正文实际用的字体。
    ///
    /// **必须走 `CanvasFontCatalog`，不能写 `.font(.custom(node.fontName, size:))`** ——
    /// `Font.custom` 收的是字体名 / PostScript 名，而这里存的是用户在 picker 里选的**族名**
    /// （`HarmonyOS Sans SC`）。中文字体两者几乎从不相同，`Font.custom` 解析失败时会**静默**
    /// 回落系统字体：没有崩溃、没有告警，表现就是用户反馈的「选了字体但一点变化都没有」。
    private var bodyFont: Font {
        // ★ 八轮：字号走 `fs(_:)`（屏幕固定），不再乘 renderScale。
        CanvasFontCatalog.font(family: node.fontName, size: fs(node.resolvedBodyFontSize))
    }

    /// 全部入参文件在 `attachments` 里的下标（★ v2.11.8 三轮：不再只筛图片）。
    ///
    /// 三轮之前这里是 `canvasIsImageLike` 过滤后的图片下标，于是 `.command` / `.md` / `.mp3`
    /// 这类附件**根本进不了卡叠**：面板写着「入参文件 5 项」，卡片却只叠 3 张。用户的反馈原话是
    /// 「卡片不显示非图像文件」。非图像附件的牌面长什么样由 `CanvasSlotFanStack.fileCardBody`
    /// （深灰卡 + 类型图标 + 文件名）负责，这里只要把它们放进来。
    private var attachmentCardIndices: [Int] {
        Array(attachments.indices)
    }

    /// **全量**卡片来源（不截断）。`CanvasSlotFanStack` 自己决定扇形截到 5 张、多出来的怎么翻页 ——
    /// 在这里就截断会让"总共有几张"丢失，`+N` 灰卡和翻页窗口都算不出来。
    private var fanSources: [CanvasFanGeometry.CardSource] {
        CanvasFanGeometry.allCardSources(attachmentIndices: attachmentCardIndices, text: text)
    }

    /// 正文预览（行数自适应，已剥掉 Markdown 原始标记）。几何/字符串加工在 Kit 里，可被 smoke 断言。
    private var previewText: String {
        CanvasCardText.previewText(text, limit: promptLineLimit)
    }

    /// 正文预览行数 = **正文区实际分到的高度里能装几行**（★ v2.11.9）。
    ///
    /// ## 修的是什么
    ///
    /// 用户截图 image-242bbdf5：正文只写了 4 行，下面空了差不多同样高的一大块，一直空到
    /// 底部「入参文件」行。根因不是预算算错了，而是 `lineLimit` 写死成 4：4 行是用户当初提的
    /// “至少要看到多少”（二轮从 2 行改成 4 行），被当成上限用了。而 `plan.promptMaxHeight`
    /// 把“除预览区/路径行/入参行之外的全部剩余”都给了正文区，默认节点高度下那是 7~8 行。
    /// 差额就是红框里的空白。空白不是审美问题：卡片上能区分“这个节点装的是哪段提示词”的
    /// 信息只有正文，白留的每一行都是本可读到的内容。
    ///
    /// ## 为什么行高要取真字体度量，不能用 `fontSize × 1.2`
    ///
    /// `CanvasScreenText.lineHeightFactor`(1.2) 是给预算估算用的保守值，但中文字体
    /// （HarmonyOS Sans SC / 苹方）的实际行高在 1.35~1.45 倍之间 —— 用 1.2 会多算出一行，
    /// 表现是最后一行被 `.clipped()` 切成半截，比留白更难看。`ascender - descender + leading`
    /// 是排版引擎真正用的行高，与字体无关地准。
    ///
    /// 减掉上下各 `promptVerticalPadding`：那两块 padding 挂在 `maxHeight` frame **外面**（为了把
    /// 命中区一起撑大），所以正文区实际占的是 `promptMaxHeight + 16pt`。不扣这 16pt 的话，
    /// 当 `Spacer` 没有宽余时底部入参行会被顶出卡片。
    private var promptLineLimit: Int {
        let inner = plan.promptMaxHeight - 2 * s(CanvasCardLayout.promptVerticalPadding)
        let font = CanvasFontCatalog.nsFont(family: node.fontName,
                                           size: fs(node.resolvedBodyFontSize))
        let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        let fits = Int((max(0, inner) / lineHeight).rounded(.down))
        return min(CanvasCardText.previewLineCap, max(1, fits))
    }

    var body: some View {
        Group {
            if isTextNode {
                // ★ 九轮（用户问题 2）：文本节点单独走一套**按实测容器高度**分配的布局。
                // 以前它和出图节点共用同一个 VStack，文本框写 `maxHeight: .infinity`：
                // 路径行/入参文件行的高度不随缩放收缩（固定字号），文本框又要"吃掉全部剩余"，
                // 把节点拖矮到一定程度三者之和就超过定高 frame —— 屏幕上就是用户报的
                // 「虚线『+』区和输入框重叠、错位、跳变」。推导见 `CanvasCardLayout.textNodePlan`。
                textNodeStack
            } else {
                imageNodeStack
            }
        }
        .padding(s(12))
        .frame(width: s(node.width), height: s(node.height), alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: s(14), style: .continuous)
                .fill(AppTheme.cardBackground(isEmpty: false))
        )
        .overlay(
            RoundedRectangle(cornerRadius: s(14), style: .continuous)
                .stroke(borderColor, lineWidth: s(isSelected ? 1.6 : 1))
        )
        .shadow(color: AppTheme.cardShadow(isEmpty: false),
                radius: s(isSelected ? 12 : 7),
                x: 0, y: s(isSelected ? 5 : 3))
        .onHover {
            isHovering = $0
            onHoverChanged($0)
        }
        .onChange(of: isEditing) { editing in
            // 进编辑态就把当前槽位正文灌进草稿。焦点由 `CanvasPromptEditor` 自己在挂载时抢
            // （NSTextView 要等 window 就绪，SwiftUI 的 @FocusState 在深层子树里实测抢不稳）。
            if editing { draft = text }
        }
        .onAppear {
            if isEditing { draft = text }
        }
    }

    // MARK: - 两种节点的纵向骨架

    /// 出图节点：路径行 / 预览区（堆叠卡片）/ 正文区 / 入参文件行。
    private var imageNodeStack: some View {
        VStack(alignment: .leading, spacing: s(8)) {
            headerRow

                // ★ zIndex：堆叠卡片 hover 时会向两侧扇开、向上抬、还要浮出操作气泡和 `+N` 网格，
                // 这些都溢出预览区。VStack 里**后声明的兄弟画在上面**，所以不置顶的话正文区（以及
                // 编辑态那个带边框的输入框）会盖在飞出来的卡片上，把卡片下半截切掉一条 ——
                // 用户反馈的"卡片被横线割裂"就是这个。预览区置顶后，卡片永远浮在正文区之上。
                previewArea
                    .zIndex(10)
                promptArea
                    // 卡片区与文字区之间留 12pt（VStack 已有 8pt，这里补 4pt）。
                    // 卡片扇开时会略微下探，间距太小就会和正文首行"贴脸"。
                    .padding(.top, s(previewToPromptGap - 8))  // VStack 自带 8pt
                // 正文字号被调大后（最大 24pt）会把下面的内容顶出卡片。加一个可压缩的 Spacer，
                // 让入参文件行始终钉在卡片底边，被挤掉的是正文的末行而不是整条按钮。
                Spacer(minLength: 0)

            // ★ 二轮：入参文件从"参数栏旁边的小胶囊"改成**卡片最底部独立一行**（用户明确要求）。
            // 它是这张卡上唯一的写操作入口，之前挤在一排芯片中间，点击目标只有 60pt 宽。
            inputFilesRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 文本节点：路径行 / 深色文本框 / 入参文件行，三段高度由 `textNodePlan` **精确**分配。
    ///
    /// 为什么必须 `GeometryReader` 而不是拿 `node.width/height` 自己算：拖拽缩放手柄时
    /// `node.height` 是**上一帧提交后**的值，而外层 `.frame` 已经按新值布好 —— 用它算预算会
    /// 慢一帧，那一帧的三段之和不等于容器高度，正是用户看到的"跳变"。`GeometryReader`
    /// 量到的是**当前帧真实容器**，三段之和恒等于它，所以任何一帧都不可能重叠出界。
    ///
    /// `.clipped()` 是最后一道保险：即使文本框里的字比 `boxHeight` 高（长文本），
    /// 也只会被裁在框内，不会漫出去压到入参文件行。
    private var textNodeStack: some View {
        GeometryReader { geo in
            let plan = CanvasCardLayout.textNodePlan(availableHeight: geo.size.height,
                                                     renderScale: renderScale,
                                                     headerFontSize: 9.5,
                                                     footerFontSize: 9.5,
                                                     bodyFontSize: node.resolvedBodyFontSize)
            VStack(alignment: .leading, spacing: plan.spacing) {
                headerRow
                    .frame(height: plan.headerHeight)

                textNodeBody
                    .frame(height: plan.boxHeight)
                    .clipped()

                // 高度不够时**整行让位**给输入框（用户指定的优先级）。用 `if` 而不是 opacity：
                // 这一行必须真正从布局里消失，只是透明的话它仍占着 26pt，等于没让位。
                if plan.showFooter {
                    inputFilesRow
                        .frame(height: plan.footerHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var borderColor: Color {
        if isEditing { return AppTheme.chromeAccentInk }
        if isSelected { return AppTheme.chromeAccentInk.opacity(0.85) }
        if hoverActive { return AppTheme.minimalCardHoverBorder }
        return AppTheme.subtleBorder
    }

    // MARK: - 顶部：路径标识行

    /// 顶行 = **居中**的 `页面 - 槽位组 - 槽位`，左侧挂非 idle 状态角标，右侧挂动画风格切换。
    ///
    /// 用 `overlay` 而不是 `HStack` 排三段是刻意的：HStack 里居中那段的实际位置取决于左右两侧的
    /// 宽度，而状态角标的宽度是变的（"排队 · 前方 3" 比 "失败" 宽一倍），路径标识会跟着左右晃。
    /// 居中的东西必须相对**卡片**居中，不是相对"剩下的空间"居中。
    private var headerRow: some View {
        Text(pathLabel)
            .font(.system(size: fs(9.5), weight: .semibold))
            .foregroundColor(AppTheme.canvasCardMetaInk)
            .lineLimit(1)
            .truncationMode(.middle)
            // 单行也要禁字距自适应：不然缩放时"页面 - 组 - 槽位"这行会时紧时松地呼吸。
            .canvasStableLabel()
            // ★ 八轮：抹掉节点层缩放残差，屏幕字号严格恒定（见 `canvasScreenFixedText`）。
            .canvasScreenFixedText(textCounter)
            // ★ 八轮：节点缩到 40pt 以下、或这一行放不下一行固定字号的字，就别写字了。
            .opacity(textOpacity)
            // 给两侧控件留出通道，否则长路径会压在图标上。
            .padding(.horizontal, s(24))
            .frame(maxWidth: .infinity, alignment: .center)
            .overlay(alignment: .leading) { statusBadge }
            .help(pathLabel)
    }

    /// 状态角标。
    ///
    /// ★ 二轮：**`idle` 不再显示任何东西**（用户要求去掉"未生成"）。其余状态保留 —— 它们是真正的
    /// 例外信息：排队多久、跑了几秒、为什么失败，这些在画布上看不到就只能去别处翻。
    @ViewBuilder
    private var statusBadge: some View {
        switch node.state {
        case .idle:
            EmptyView()
        case .queued(let ahead):
            // 「前方 N 个」用的是 CLI 真字段 queue_ahead_count，不是估算。
            Label(ahead > 0 ? "前方 \(ahead)" : "排队", systemImage: "clock")
                .font(.system(size: fs(9), weight: .medium))
                .foregroundColor(AppTheme.canvasCardMetaInk)
                .canvasScreenFixedText(textCounter, anchor: .leading)
                .opacity(textOpacity)
        case .running(let startedAt):
            // 刻意不给百分比：CLI 不提供，编出来的进度在 10~20s 量级会明显失真。
            RunningBadge(startedAt: startedAt,
                         renderScale: renderScale,
                         textCounter: textCounter,
                         textOpacity: textOpacity)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: s(10), weight: .semibold))
                .foregroundColor(.green.opacity(0.85))
        case .failed:
            Label("失败", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: fs(9), weight: .medium))
                .foregroundColor(.red.opacity(0.85))
                .canvasScreenFixedText(textCounter, anchor: .leading)
                .opacity(textOpacity)
        }
    }

    // MARK: - 纯文本节点主体

    /// 深色圆角纯文本框（用户二轮明确要求）。
    ///
    /// 为什么是**深色**而不是跟随卡片底色：文本节点没有图，整张卡就是一片留白，浅色文本框在浅色
    /// 卡片上没有边界感，一眼看不出"这里是内容"。深底把内容区从卡片里"抠"出来，同时也和画布上
    /// 出图节点的白色堆叠卡形成一眼可辨的区分 —— 用户扫画布时不需要读字就知道哪个是文本节点。
    ///
    /// 行数不设死上限（`lineLimit(nil)` + 高度自适应到剩余空间）：文本节点的全部价值就是那段文字，
    /// 截断它等于让节点失去意义；真的超长时由 `frame` 裁掉尾部，而不是提前省略。
    @ViewBuilder
    private var textNodeBody: some View {
        if isEditing {
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: s(10), style: .continuous)
                    .fill(AppTheme.canvasTextNodeFill)

                if text.isEmpty {
                    Text(attachments.isEmpty ? "点这里写文本…" : "仅入参文件，无文本")
                        .font(bodyFont)
                        .foregroundColor(.white.opacity(0.45))
                        .canvasStableLabel()
                        .canvasScreenFixedText(textCounter, anchor: .topLeading)
                        .opacity(textOpacity)
                        .padding(.horizontal, s(10))
                        .padding(.vertical, s(10 + CanvasCardLayout.promptVerticalPadding))
                } else {
                    Text(text)
                        .font(bodyFont)
                        .foregroundColor(.white.opacity(0.92))
                        .canvasScreenFixedText(textCounter, anchor: .topLeading)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(s(2))
                        .lineLimit(nil)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        // 宽度吃满、高度随内容 + 禁止字距收紧/字号自适应：换行位置只由容器宽度决定。
                        // ★ 三轮 hotfix2：光有 fixedSize 不够 —— 见 `canvasStableText()` 的注释，
                        // `allowsTightening` / `minimumScaleFactor` 是"同一宽度下换行来回跳"的另一半肇因。
                        .canvasStableText()
                        // ★ 八轮：屏幕固定字号 + 太小就不画（深色底板保留，它是"这是文本节点"的标识）。
                        .opacity(textOpacity)
                        // ★ 三轮：上下各多 8pt 呼吸（用户要求）。
                        .padding(.horizontal, s(10))
                        .padding(.vertical, s(10 + CanvasCardLayout.promptVerticalPadding))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: s(10), style: .continuous))
            // 命中区盖满整块，否则空节点只有那句灰字那么窄，点不中。
            .contentShape(RoundedRectangle(cornerRadius: s(10), style: .continuous))
            // ★ 三轮：双击 → 单击进编辑（同 `promptArea`，理由见那里的注释）。
            .onTapGesture(perform: onBeginEdit)
        }
    }

    // MARK: - 预览区

    /// ## 为什么图片分支必须先 `.frame` 再 `.clipShape`（v2.11.7 hotfix20 修的「图片错位」）
    ///
    /// 用户反馈"节点里的图片错位、还把编辑按钮挡住点不到"。根因不是坐标算错，是 **`aspectRatio(.fill)`
    /// 在 ZStack 里会溢出**：`.fill` 的语义是"短边贴合、长边超出"，一张 3:4 的竖图放进预览区，
    /// 高度会被撑到远超容器 —— 而 `ZStack` **不裁剪**超出的子视图。此前那份代码把 `.clipShape`
    /// 直接挂在 `Image` 上，裁的是**图片自己那个被撑高的框**（等于没裁），于是图片上下各溢出几十点，
    /// 向上盖住顶行里的按钮（所以"无法编辑"），向下盖住正文。
    ///
    /// 正确的顺序是：**先用 `.frame` 把容器尺寸钉死，再在容器外层裁剪**（`fillImageBox`）。
    ///
    /// ## 为什么外层那道兜底 `.clipShape` 被拿掉了（v2.11.8）
    ///
    /// 堆叠卡片**必须**能溢出预览区：hover 展开时卡片要向两侧扇开、单卡要向上抬 10pt，
    /// 操作气泡还要浮在卡片上方。留着兜底裁剪，这些动作会被齐刷刷切掉一半 —— 那正是用户
    /// 要的"卡片飞出来"的反面。裁剪责任因此下移到**每个会溢出的图片分支自己**（`fillImageBox`）。
    private var previewArea: some View {
        ZStack {
            // ★ 边框画在**底板上**（`.overlay` 挂在这个 shape 上），而不是挂在整个 ZStack 外面。
            // 挂外面的话这条 0.5pt 的线会画在所有卡片之上：扇开的卡片下半截被这条线横穿，
            // 观感就是用户说的"卡片被横线割裂"。放到底板层后，线永远在卡片之下。
            RoundedRectangle(cornerRadius: s(10), style: .continuous)
                .fill(AppTheme.previewBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: s(10), style: .continuous)
                        .stroke(AppTheme.subtleBorder.opacity(0.6), lineWidth: s(0.5))
                )

            if case .succeeded(let path) = node.state,
               let img = NSImage(contentsOfFile: path) {
                // 产物在就显示产物：生成结果是这个节点的成品，入参堆叠此时让位。
                fillImageBox {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            } else if case .failed(let reason) = node.state {
                DiagonalHatch(spacing: s(7))
                    .stroke(AppTheme.subtleBorder.opacity(0.55), lineWidth: s(1))
                    .clipShape(RoundedRectangle(cornerRadius: s(10), style: .continuous))
                VStack(spacing: s(3)) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: s(14), weight: .semibold))
                    Text(reason)
                        .font(.system(size: fs(9)))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .canvasScreenFixedText(textCounter)
                        .opacity(textOpacity)
                }
                .foregroundColor(.red.opacity(0.75))
                .padding(.horizontal, s(8))
            } else {
                // ★ v2.11.8：入参不再只画"第一张图"，而是整叠可展开的卡片。见 CanvasSlotFanStack。
                CanvasSlotFanStack(sources: fanSources,
                                   attachments: attachments,
                                   renderScale: renderScale,
                                   textCounter: textCounter,
                                   // ★ v2.11.9：去掉 `&& !isEditing`。这个条件的后果是用户在正文上点一下
                                   // （指针根本没动），图片扇形就“啖”地**反向收回去** —— 而且因为
                                   // hover 只在指针**移动**时重算，不动就永远展不回来。于是一次单击
                                   // 同时发生三件事（扇形收、正文变 Markdown、面板冒出），看起来就是
                                   // “我是不是点错了”。编辑态与卡叠展开本来也不冲突：卡叠在预览区、
                                   // 编辑框在正文区，两个矩形不重叠。
                                   nodeHovered: hoverActive,
                                   // ★ 九轮：卡叠整套按 1x 收敛（内部自己乘 renderScale），
                                   // 这里必须给 1x 量纲，不能给排版单位（会乘两次）。
                                   boxHeight: plan.previewHeight1x,
                                   // 节点身份 = `groupId#slot`（`CanvasNode.id`）。翻页窗口按它存活，
                                   // 右键 / 页面切换导致的重建不会把用户翻到的那一页打回第一页。
                                   stateKey: node.id,
                                   onEditText: onBeginEdit,
                                   onOpenInputFiles: onOpenInputFiles,
                                   onActivateNode: onActivateNode,
                                   onPromoteInput: onPromoteInput,
                                   onDeleteInput: onDeleteInput,
                                   onToast: onToast)
            }
        }
        .frame(height: previewHeight)
    }

    /// 卡片区与文字区之间的间距（1x）。
    private var previewToPromptGap: CGFloat { CanvasCardLayout.previewToPromptGap }

    /// 预览区高度（1x）。
    ///
    /// ★ 二轮从 148 降到 132：正文预览由 2 行变 4 行，多出来的两行高度得从某处来。删掉的参数栏
    /// 只值 ~18pt，剩下的从预览区借 —— 堆叠卡片本身是按这个高度收敛的（见 `fanCardSize`），
    /// 少 16pt 不影响可读性，而正文少两行会直接看不出这个节点是干什么的。
    ///
    /// ★ 三轮改成**按节点高度取比例**（上限仍是 132）。比例/上下限连同理由都在
    /// `CanvasCardLayout` 里，那边有 smoke 断言盯着"卡片区不得超过节点高度 35%"这条用户约束。
    /// 预览区高度（**排版单位**，已由 `plan` 扣掉固定字号的文字行）。
    ///
    /// ★ 九轮：以前这里返回 1x 设计值、调用点再 `s(...)` 乘 renderScale。现在预算里混着
    /// "缩的几何"和"不缩的文字行"两种量纲，只能整段在 `verticalPlan` 里算完再拿过来，
    /// 调用点**不要**再乘 renderScale（乘两次的症状是缩小时预览区消失、放大时溢出卡片）。
    private var previewHeight: CGFloat { plan.previewHeight }

    /// 「填充式图片盒」：用 `Color.clear` 定尺、内容走 overlay、再 `.clipped()`。见 `previewArea` 的注释。
    private func fillImageBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Color.clear
            .overlay(content())
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: s(10), style: .continuous))
    }

    // MARK: - 正文预览（= 槽位正文，最多 4 行）

    @ViewBuilder
    private var promptArea: some View {
        if isEditing {
            editor
        } else {
            Group {
                if previewText.isEmpty {
                    Text(attachments.isEmpty ? "点这里写提示词…" : "仅入参文件，无提示词")
                        .font(bodyFont)
                        .foregroundColor(AppTheme.canvasCardMetaInk.opacity(0.75))
                        .canvasStableLabel()
                        .canvasScreenFixedText(textCounter, anchor: .topLeading)
                } else {
                    // ★ 二轮：2 行 → 4 行，且显示的是**剥掉 Markdown 标记**的纯文本
                    // （用户要求"中间去掉 Markdown 表格等原始模板字样"）。加工逻辑在
                    // `CanvasCardText`，带 smoke 断言 —— 它的翻车方式是少一行/多一个竖线，
                    // 不报错、只是"看起来有点怪"，靠肉眼极难发现回归。
                    Text(previewText)
                        .font(bodyFont)
                        .foregroundColor(.primary.opacity(0.88))
                        // ★ v2.11.9：行数改成按实际可用高度算（见 `promptLineLimit`），
                        // 写死 4 行就是用户报的“文字下面一大片空白”。
                        .lineLimit(promptLineLimit)
                        .multilineTextAlignment(.leading)
                        // 只让高度跟着内容长，宽度**始终**吃满容器；同时禁掉字距收紧与字号自适应。
                        // 这样换行位置只由容器宽度决定，不会因为"文字理想宽度"参与协商而在缩放过程中
                        // 来回改主意 —— 用户录屏里「快速推进」/「快速推进(」两种断行反复横跳就是它。
                        .canvasStableText()
                        // ★ 八轮：整块正文按左上角反向缩放 —— 锚点必须是 topLeading，用 center 会让
                        // 文字块在缩小时朝中心收，看起来像"正文自己在卡里游动"。
                        .canvasScreenFixedText(textCounter, anchor: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: s(30), alignment: .topLeading)
            // ★ 八轮：正文改成屏幕固定字号后必须**限高 + 裁剪**。
            //
            // 缩小画布时字号不再跟着缩，4 行正文的实际需求高度会超过正文区在小节点里分到的那点
            // 空间；`VStack` 不裁剪，多出来的部分会把底部「入参文件」行顶出卡片、甚至溢到卡片外
            // 压在相邻节点上。上限的算法（节点高 - 其它固定分区）在 `CanvasCardLayout` 里，带断言。
            .frame(maxHeight: plan.promptMaxHeight,
                   alignment: .topLeading)
            .clipped()
            // ★ 八轮：节点太小就不画字（阈值见 `CanvasScreenText`）。
            .opacity(textOpacity)
            // ★ 三轮：正文区上下各留 8pt 呼吸（用户要求）。padding 必须在 contentShape **之前**，
            // 否则这 8pt 不算进命中区，等于白留。
            .padding(.vertical, s(CanvasCardLayout.promptVerticalPadding))
            // 命中区要盖满整行（含上面那 8pt padding），否则空节点只有那句灰字那么窄，点不中。
            .contentShape(Rectangle())
            // ★ 三轮：双击 → **单击**进编辑（用户要求"点一下就能直接打字"）。
            //
            // 原来写的是 `onTapGesture(count: 2)`，而**祖先**（节点整体）上挂着一个 count:1 的
            // 选中手势。SwiftUI 里这两者共存时，count:2 会被上层的单击不断打断 —— 实测表现就是
            // 用户说的"要点好几下才进得去"。改成单击后，内层手势优先级天然高于祖先，一击直达；
            // `beginEdit` 本身会先 select 再置 editingNodeId，所以选中态不会丢。
            // 拖拽不受影响：节点的 DragGesture 有 2pt 起步距离，位移一旦超过阈值 tap 就失败。
            .onTapGesture(perform: onBeginEdit)
        }
    }

    /// inline 提示词编辑器（v2.11.7 hotfix20 重写）。
    ///
    /// ## 键位契约
    ///   - **回车 = 保存**（用户明确要求）。
    ///   - **Shift+回车 = 换行**。
    ///   - Esc = 放弃。
    ///   - 失焦 = 保存（点画布别处、切到另一个节点）。
    ///
    /// ## 为什么不用 SwiftUI `TextEditor`
    ///
    /// `TextEditor` 会把 Return 直接吞掉插进文本，SwiftUI 在 macOS 13 上**没有**任何合法钩子能
    /// 在它之前拿到这个键（`.onKeyPress` 是 macOS 14+；`.onSubmit` 对 `TextEditor` 不触发）。
    /// 所以这里换成裹了 `NSTextView` 的 `CanvasPromptEditor`，在
    /// `textView(_:doCommandBy:)` 里按修饰键分流 —— 这是唯一能同时满足"回车保存"和"Shift+回车换行"
    /// 的路径，而这两条正是用户要的。
    /// ## 三轮：底部那行「回车保存 / ⇧回车换行 / Esc 放弃」提示已删除（用户要求）
    ///
    /// 它是**一次性信息占了常驻位置**：这三个键位学一次就会了，而提示行在每次编辑时都要吃掉一行
    /// 高度 —— 而正文区的高度正是这轮一直在抢的东西。键位契约本身没变，改挂到 `.help` 悬浮提示上，
    /// 需要的人停一秒就能看到。
    private var editor: some View {
        // ★ 八轮：编辑器字号也走屏幕固定（`fs`）。
        //
        // 一定要和非编辑态用**同一个**字号来源：两边不一致的表现是"点进编辑，字突然变大/变小一截"，
        // 而正文的字号在编辑态还决定光标高度与换行位置 —— 换行位置一变，用户就会以为自己的文本
        // 被改了。（此前这里乘 renderScale，是与旧的"文字跟随缩放"配套的。）
        CanvasPromptEditor(text: $draft,
                           font: CanvasFontCatalog.nsFont(family: node.fontName,
                                                          size: fs(node.resolvedBodyFontSize)),
                           onCommit: { onCommitEdit(draft) },
                           onCancel: onCancelEdit,
                           onBlur: { onCommitEdit(draft) })
            .frame(minHeight: s(40))
            .padding(.horizontal, s(4))
            // ★ 三轮：上下各 8pt 呼吸，与非编辑态的正文区对齐 —— 否则一进编辑文字就往上跳一截。
            .padding(.vertical, s(CanvasCardLayout.promptVerticalPadding))
            .background(
                RoundedRectangle(cornerRadius: s(6), style: .continuous)
                    .fill(AppTheme.previewBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: s(6), style: .continuous)
                    .stroke(AppTheme.chromeAccentInk.opacity(0.5), lineWidth: s(1))
            )
            .help("回车保存 · ⇧回车换行 · Esc 放弃")
    }

    // MARK: - 入参文件（卡片最底部整行）

    /// 「入参文件」行。
    ///
    /// ★ hotfix19 这里是一排缩略图（`CanvasNodeAttachmentStrip`），用户反馈"点了完全没反应"——
    /// 它当时确实只是一排 `Image`，没有任何交互。改成一个明确的按钮：**看得出能点**。
    /// 名字用「入参文件」而不是「附件」：画布语境下它们是喂给模型的输入，不是"顺带附上的东西"。
    ///
    /// ★ 二轮改成**通栏一行**并钉在卡片底部（用户明确要求）。整行的意义不只是好看：它是这张卡上
    /// 唯一的入口按钮，之前那个 60pt 宽的小胶囊在 50% 缩放下只有 30pt，实际是点不中的。
    @ViewBuilder
    private var inputFilesRow: some View {
        Button(action: onOpenInputFiles) {
            HStack(spacing: s(5)) {
                Image(systemName: attachments.isEmpty ? "tray" : "tray.full")
                    .font(.system(size: s(9), weight: .semibold))
                Text(attachments.isEmpty ? "入参文件" : "入参文件 \(attachments.count)")
                    .font(.system(size: fs(9.5), weight: .medium))
                    .canvasStableLabel()
                    .canvasScreenFixedText(textCounter, anchor: .leading)
                    .opacity(textOpacity)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: s(7), weight: .bold))
                    .opacity(0.6)
            }
            .foregroundColor(attachments.isEmpty
                             ? AppTheme.canvasCardMetaInk
                             : AppTheme.chromeAccentInk)
            .padding(.horizontal, s(9))
            .padding(.vertical, s(5))
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: s(8), style: .continuous)
                    .fill(attachments.isEmpty
                          ? AppTheme.previewBackground
                          : AppTheme.chromeAccentSoftFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: s(8), style: .continuous)
                    .stroke(AppTheme.subtleBorder.opacity(attachments.isEmpty ? 0.7 : 0),
                            lineWidth: s(0.5))
            )
            .contentShape(RoundedRectangle(cornerRadius: s(8), style: .continuous))
        }
        .buttonStyle(.plain)
        .help("管理入参文件：增删、调整顺序（与该槽位的附件是同一份数据）")
    }
}

// MARK: - 生成中角标

/// 已用秒数会自己走字。用独立小视图承载 `TimelineView`，避免每秒重绘整张卡片。
private struct RunningBadge: View {
    let startedAt: Date
    var renderScale: CGFloat = 1
    /// ★ 八轮：文字反向缩放，见 `CanvasZoomLayout.textCounterScale`。
    var textCounter: CGFloat = 1
    /// ★ 八轮：节点太小时秒数一起隐掉（与卡片上其它文字同一条阈值）。
    var textOpacity: Double = 1

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(spacing: 3 * renderScale) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6 * renderScale)
                    .frame(width: 8 * renderScale, height: 8 * renderScale)
                Text("\(elapsed)s")
                    // ★ 八轮：屏幕固定字号（不乘 renderScale），与卡片上其它文字一致。
                    .font(.system(size: CanvasScreenText.layoutFontSize(9, renderScale: renderScale),
                                  weight: .medium))
                    .foregroundColor(AppTheme.canvasCardMetaInk)
                    .canvasScreenFixedText(textCounter, anchor: .leading)
                    .opacity(textOpacity)
            }
        }
    }
}

// MARK: - 斜纹占位

/// 45° 斜纹填充。用 Shape 而不是贴图，缩放时始终清晰。
struct DiagonalHatch: Shape {
    var spacing: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard spacing > 0, rect.width > 0, rect.height > 0 else { return p }
        var x = -rect.height
        var guardCount = 0
        while x < rect.width && guardCount < 600 {
            p.move(to: CGPoint(x: rect.minX + x, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + x + rect.height, y: rect.minY))
            x += spacing
            guardCount += 1
        }
        return p
    }
}
