import CoreGraphics

/// 画布节点卡片的**纵向分区几何**（v2.11.8 三轮）。
///
/// 只有三个数，但它们全是用户逐条指定的比例约束，而且都属于"改错了不报错、只是看起来有点挤"
/// 的那一类 —— 唯一能拦住回归的办法就是把它们挪出视图、变成可断言的纯函数。
///
/// ## 卡片自上而下的分区
///
/// ```text
///   路径标识行
///   预览区（堆叠卡片）      ← previewHeight(nodeHeight:)，占节点高度 ≤ 35%
///   ── previewToPromptGap ──
///   正文区（4 行纯文本）    ← 上下各 promptVerticalPadding
///   入参文件行（钉在底边）
/// ```
///
/// ## 为什么预览区要按**比例**而不是固定高度
///
/// 二轮写的是固定 132pt。用户三轮的反馈是"卡片区约占 40%、文字区 45%，整体太紧凑"——固定值的
/// 问题不在这个数本身，而在于它**不随节点长高让位**：用户把节点拉高是为了看更多正文，可固定高度的
/// 预览区一步不让，多出来的高度被 `Spacer` 吃掉，正文永远只有那么几行。改成比例后，加高节点
/// 多出来的空间全部进正文区。
public enum CanvasCardLayout {

    /// 预览区占节点高度的比例。
    ///
    /// 用户要求"卡片高度控制在节点总高度 35% 以内"，这里取 34% 留一点余量 —— 卡在 35.0 上
    /// 会让"是否满足要求"取决于浮点误差。
    public static let previewHeightRatio: CGFloat = 0.34

    /// 预览区高度上限（1x）。
    ///
    /// 超过 132pt 后堆叠卡片不会更好看（`fanCardSize` 自己就收敛在 132），只是白占正文的地方。
    /// 所以很高的节点（比如 600pt）里预览区停在 132，剩下的全给正文。
    public static let previewHeightCap: CGFloat = 132

    /// 预览区高度下限（1x）。
    ///
    /// 低于 72pt 那叠卡片就看不出是"一叠"了（卡片本身的地板是 64pt），此时宁可让正文区被压缩 ——
    /// 一个矮到极限的节点，用户要的是"还认得出这是槽位节点"，而不是多半行字。
    public static let previewHeightFloor: CGFloat = 72

    /// 卡片区与文字区之间的间距（1x，用户指定 8–12pt，取上限 12）。
    ///
    /// 不能更小：卡片 hover 扇开时会略微下探出预览区，间距不足就会和正文首行贴脸，
    /// 观感是"卡片压在字上"。
    public static let previewToPromptGap: CGFloat = 12

    /// 正文区上下内边距（1x，用户指定各加 8pt）。
    public static let promptVerticalPadding: CGFloat = 8

    /// 预览区高度（1x）。
    ///
    /// - Parameter nodeHeight: 节点总高度（1x，画布坐标）。
    /// - Returns: 夹在 `[previewHeightFloor, previewHeightCap]` 内的比例高度。
    public static func previewHeight(nodeHeight: CGFloat) -> CGFloat {
        min(previewHeightCap, max(previewHeightFloor, nodeHeight * previewHeightRatio))
    }

    // MARK: - 正文区高度上限（★ v2.11.8 八轮）

    /// 卡片四周内边距（1x）。与视图里的 `s(12)` 对应。
    public static let cardPadding: CGFloat = 12
    /// 路径标识行的高度预算（1x）。
    public static let headerRowHeight: CGFloat = 14
    /// VStack 的行间距（1x）。与视图里的 `spacing: s(8)` 对应。
    public static let rowSpacing: CGFloat = 8
    /// 底部「入参文件」整行的高度预算（1x）。
    public static let inputFilesRowHeight: CGFloat = 26

    /// 正文区允许占用的最大高度（1x）。
    ///
    /// ## 为什么八轮才需要这个数
    ///
    /// 需求 1 把正文改成了**屏幕固定字号**（排版时不再乘 zoom）。它有一个必然的副作用：
    /// 缩小画布时，正文相对卡片会越来越大 —— zoom 0.4 时节点排版高度只有 220pt 的量级不变，
    /// 但字号从 "13×0.4=5.2pt" 变回 13pt，4 行正文要 60pt 以上。SwiftUI 的 `VStack` 不裁剪，
    /// 于是正文会把底部那行「入参文件」顶出卡片、甚至溢到卡片外面去（用户看到的是"字压在别的
    /// 节点上"）。
    ///
    /// 所以正文区必须有一个**上限 + 裁剪**：宁可少显示一行字，也不能破坏卡片的纵向分区。
    /// 这个上限就是"节点高度减掉其它固定分区"，全部分区常量都在本文件里，和视图里的
    /// `s(...)` 一一对应（改视图忘了改这里的表现是"正文被多裁/少裁一点"，smoke 只能盯住
    /// 单调性与非负，因此常量必须成对修改）。
    public static func promptMaxHeight(nodeHeight: CGFloat) -> CGFloat {
        let fixed = cardPadding * 2               // 上下内边距
            + headerRowHeight                     // 路径标识行
            + rowSpacing                          // header ↔ 预览区
            + previewHeight(nodeHeight: nodeHeight)
            + previewToPromptGap                  // 预览区 ↔ 正文
            + rowSpacing                          // 正文 ↔ 入参文件行
            + inputFilesRowHeight
        return max(0, nodeHeight - fixed)
    }
}

// MARK: - ★ v2.11.8 九轮：renderScale 感知的纵向预算

extension CanvasCardLayout {

    /// 卡片纵向分区的**实际排版高度**（单位 = 排版 pt，即 1x 设计值 × renderScale 之后的坐标系）。
    ///
    /// ## 为什么需要它（八轮"半截字"的病根）
    ///
    /// 八轮把字号固定成设计 pt 之后，卡片里出现了两种**量纲不同**的高度：
    ///   - 几何（内边距、预览区、行距）随 `renderScale` 缩；
    ///   - 文字行高**不缩**（这正是"屏幕字号恒定"的定义）。
    ///
    /// 而分区预算仍然整个乘 `renderScale`，于是缩到一定程度后各行需要的高度之和超过卡片总高。
    /// 卡片外面是 `.frame(height:)` 定高，SwiftUI 只能压扁某几行 —— 屏幕上就是"路径行被竖着切了
    /// 一半"、"`+N 点击加载` 漫出灰卡"。八轮的处理是"塞不下就把那一行藏起来"，用户九轮明确否掉了。
    ///
    /// 这里改成让预算自己算对：
    ///   1. 文字行（顶部路径行、底部入参文件行）按**固定高度**先扣掉 —— 它们的高度由字号决定，
    ///      不参与缩放，`max(设计值 × rs, 行高)` 保证任何缩放下都放得下一整行；
    ///   2. 剩下的高度才给**可伸缩**的预览区和正文区，预览区按比例要、但绝不超过剩余；
    ///   3. 剩余为 0 时预览区和正文区就是 0（卡片只剩两行字），**永不返回负数**
    ///      —— SwiftUI 的 `frame(height:)` 收到负值会直接报无效布局。
    ///
    /// 因此"某一行没有完整行高"这件事从**结构上**不可能发生，不需要任何逐行隐藏。
    ///
    /// - Parameters:
    ///   - nodeHeight: 节点高度（1x 设计值）。
    ///   - renderScale: 排版缩放（= `layoutZoom`）。
    ///   - headerFontSize: 顶部路径行字号（设计 pt，不缩）。
    ///   - footerFontSize: 底部入参文件行字号（设计 pt，不缩）。
    public static func verticalPlan(nodeHeight: CGFloat,
                                    renderScale: CGFloat,
                                    headerFontSize: CGFloat,
                                    footerFontSize: CGFloat) -> VerticalPlan {
        let rs = max(0.01, renderScale)
        let total = max(0, nodeHeight) * rs

        // 文字行：固定行高保底。
        let header = max(headerRowHeight * rs, CanvasScreenText.lineHeight(headerFontSize))
        let footer = max(inputFilesRowHeight * rs, CanvasScreenText.lineHeight(footerFontSize))
        // 纯几何留白：内边距 + header↔预览 + 预览↔正文 + 正文↔底行。
        let chrome = (cardPadding * 2 + rowSpacing + previewToPromptGap + rowSpacing) * rs

        let flexible = max(0, total - header - footer - chrome)
        // 预览区想要的高度（1x 比例规则不变），换算到排版单位后被剩余高度截断。
        let want = previewHeight(nodeHeight: nodeHeight) * rs
        let preview = min(want, flexible)

        return VerticalPlan(headerHeight: header,
                            footerHeight: footer,
                            previewHeight: preview,
                            previewHeight1x: preview / rs,
                            promptMaxHeight: max(0, flexible - preview),
                            fitsText: total >= header + footer + chrome)
    }

    /// `verticalPlan` 的结果。全部是**排版单位**，视图直接拿去写 `frame`。
    public struct VerticalPlan: Equatable {
        /// 顶部路径行高度（固定字号保底）。
        public let headerHeight: CGFloat
        /// 底部入参文件行高度（固定字号保底）。
        public let footerHeight: CGFloat
        /// 预览区（堆叠卡片）高度。
        public let previewHeight: CGFloat
        /// 预览区高度换算回 **1x 设计单位**。
        ///
        /// `CanvasSlotFanStack` / `CanvasFanGeometry.fanCardSize` 全套按 1x 收敛（内部自己乘
        /// `renderScale`），把排版单位的高度直接喂给它们会**乘两次**：缩小时卡片被 64pt 下限
        /// 撑爆预览区，放大时卡片小得像图钉。所以这里显式给出反算值，调用点按量纲各取所需。
        public let previewHeight1x: CGFloat
        /// 正文区可用的最大高度。
        public let promptMaxHeight: CGFloat
        /// 卡片总高是否连"两行字 + 留白"都装不下。
        ///
        /// 装不下时视图应当整体隐藏文字。它与 `CanvasScreenText.textVisible`（视觉短边 < 40pt）
        /// 是**同一个语义的两种度量**，取 OR：40pt 那条是用户给的显式规格，这条是几何兜底
        /// （极扁的节点可能短边够 40pt 但高度仍塞不下两行字）。两条都是**整体**隐藏，不是逐行。
        public let fitsText: Bool

        public init(headerHeight: CGFloat,
                    footerHeight: CGFloat,
                    previewHeight: CGFloat,
                    previewHeight1x: CGFloat,
                    promptMaxHeight: CGFloat,
                    fitsText: Bool) {
            self.headerHeight = headerHeight
            self.footerHeight = footerHeight
            self.previewHeight = previewHeight
            self.previewHeight1x = previewHeight1x
            self.promptMaxHeight = promptMaxHeight
            self.fitsText = fitsText
        }
    }
}

// MARK: - ★ v2.11.8 九轮：文本节点的自适应纵向预算（用户问题 2）

extension CanvasCardLayout {

    /// 文本节点（`kind == .text`）的纵向分区。
    ///
    /// ## 用户报的现象
    ///
    /// 「拖拽 Text 节点角部缩放手柄时，内部虚线『+』按钮区和底部文字输入框重叠、错位、跳变。」
    ///
    /// ## 根因
    ///
    /// 文本节点的卡片是 `VStack { 路径行; 文本框; 入参文件行 }`，外面套一个**定高**
    /// `frame(height: node.height × renderScale)`。三个孩子里有两个的高度**不随缩放收缩**：
    /// 路径行和入参文件行的高度由固定字号决定（`v2.11.8` 起字号恒为设计 pt），
    /// 而文本框写的是 `maxHeight: .infinity`（想吃掉全部剩余）+ `minHeight: 40 × rs`。
    ///
    /// 于是把节点拖矮到一定程度后 `固定两行 + 文本框最小高 > 定高`，SwiftUI 只能把超出的部分
    /// 挤出容器 —— 表现就是两个区块**互相压住**、边界随拖拽抖动。这不是动画问题，是**预算问题**：
    /// 谁都没被告知"你只有这么多高度"。
    ///
    /// ## 让位顺序（用户指定：优先保证输入框可见）
    ///
    ///   1. 高度够 → 路径行 + 文本框 + 入参文件行，文本框拿走全部剩余；
    ///   2. 高度不够放下"入参文件行 + 一行文本" → **隐藏入参文件行**，把它的高度全给文本框；
    ///   3. 连一行文本都放不下 → `fitsText == false`，调用方整体隐藏文字（与
    ///      `CanvasScreenText.textVisible` 的 40pt 规格同语义，取 OR）。
    ///
    /// 关键是 `boxHeight` 是**精确值**而不是 `.infinity`：三段之和恒等于可用高度，
    /// 所以"重叠出界"从结构上不可能发生，与拖拽是否连续无关。
    ///
    /// - Parameters:
    ///   - availableHeight: 卡片**内容区**的排版高度（= 节点高 × renderScale − 上下内边距）。
    ///     刻意收这个而不是 `nodeHeight`：视图侧用 `GeometryReader` 量到的就是这个值，
    ///     拖拽过程中它比 `node.height` 更贴近真实容器（少一帧滞后）。
    ///   - renderScale: 排版缩放（= `layoutZoom`）。
    ///   - headerFontSize / footerFontSize / bodyFontSize: 三处的**设计 pt**（不随缩放变）。
    public static func textNodePlan(availableHeight: CGFloat,
                                    renderScale: CGFloat,
                                    headerFontSize: CGFloat,
                                    footerFontSize: CGFloat,
                                    bodyFontSize: CGFloat) -> TextNodePlan {
        let rs = max(0.01, renderScale)
        let total = max(0, availableHeight)
        // 行间距也必须被容器夹住。`rowSpacing × rs` 在放大倍率下本身就可能超过整个可用高度
        // （rs=2、可用 10pt 时 gap=16pt），此时无论三段怎么分配，"之和 ≤ 容器高"都不可能成立
        // —— VStack 的 spacing 是**先扣掉**的。取 total/4 兜底：两个间距最多吃掉一半高度，
        // 正常尺寸下这个上限远大于 `rowSpacing × rs`，不影响既有观感。
        let gap = min(rowSpacing * rs, total / 4)

        // 路径行想要的高度：设计高与"一整行固定字号"取大。
        let headerWanted = max(headerRowHeight * rs, CanvasScreenText.lineHeight(headerFontSize))
        // ★ 但它**也要被容器夹住**。极端矮的容器（拖到只剩十几 pt）下，固定行高 11.4pt 本身
        // 就可能超过可用高度 —— 不夹的话 `header + gap` 就已经溢出，文本框拿到 0 高度也救不回来，
        // 屏幕上又变成两个区块互相压。夹住之后"三段之和 ≤ 容器高"才是**恒成立**的，
        // 而不是"高度充足时成立"。文字此时早已由 `fitsText == false` 整体隐藏，夹扁不可见。
        // 减 `gap` 是因为 VStack 的行间距对"高度为 0 的孩子"照样生效。
        let header = min(headerWanted, max(0, total - gap))
        // 入参文件行 = 一行固定字号 + 上下 5pt 内边距（内边距是几何，要缩）。
        let footer = max(inputFilesRowHeight * rs,
                         CanvasScreenText.lineHeight(footerFontSize) + 2 * 5 * rs)
        // 文本框至少要放得下一整行正文 + 上下呼吸。
        let minBox = CanvasScreenText.lineHeight(bodyFontSize) + 2 * promptVerticalPadding * rs

        // 方案 1：三段齐全（两个间距）。
        let withFooter = total - header - footer - 2 * gap
        if withFooter >= minBox {
            return TextNodePlan(headerHeight: header,
                                boxHeight: withFooter,
                                footerHeight: footer,
                                spacing: gap,
                                showFooter: true,
                                fitsText: true)
        }

        // 方案 2：砍掉入参文件行（只剩一个间距），把高度让给输入框。
        let withoutFooter = total - header - gap
        if withoutFooter >= minBox {
            return TextNodePlan(headerHeight: header,
                                boxHeight: withoutFooter,
                                footerHeight: 0,
                                spacing: gap,
                                showFooter: false,
                                fitsText: true)
        }

        // 方案 3：连一行都放不下 —— 文字整体隐藏，剩下的高度仍如实给出（不返回负数）。
        return TextNodePlan(headerHeight: header,
                            boxHeight: max(0, withoutFooter),
                            footerHeight: 0,
                            spacing: gap,
                            showFooter: false,
                            fitsText: false)
    }

    /// `textNodePlan` 的结果，全部是**排版单位**。
    public struct TextNodePlan: Equatable {
        public let headerHeight: CGFloat
        /// 深色文本框的**精确**高度（不是 `.infinity`，这正是修复重叠的关键）。
        public let boxHeight: CGFloat
        /// 入参文件行高度；`showFooter == false` 时为 0。
        public let footerHeight: CGFloat
        /// VStack 的行间距。**必须由视图照用**（不能自己写 `s(8)`）：极端矮的容器下它会被收窄，
        /// 视图那边若仍写死 8×rs，"三段之和 ≤ 容器高"就又不成立了。
        public let spacing: CGFloat
        /// 入参文件行（用户口中的「+」按钮区）是否还画得下。
        public let showFooter: Bool
        /// 是否还画得下文字。
        public let fitsText: Bool

        public init(headerHeight: CGFloat,
                    boxHeight: CGFloat,
                    footerHeight: CGFloat,
                    spacing: CGFloat,
                    showFooter: Bool,
                    fitsText: Bool) {
            self.headerHeight = headerHeight
            self.boxHeight = boxHeight
            self.footerHeight = footerHeight
            self.spacing = spacing
            self.showFooter = showFooter
            self.fitsText = fitsText
        }
    }
}
