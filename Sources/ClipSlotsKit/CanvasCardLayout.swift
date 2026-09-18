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

// MARK: - ★ v2.11.8 十轮：纵向预算（纯设计单位，与 zoom 无关）

extension CanvasCardLayout {

    /// 卡片纵向分区的高度预算（单位 = **设计 pt**）。
    ///
    /// ## 为什么这里不再有 `renderScale`
    ///
    /// 九轮以前卡片内部按 `renderScale` 排版、文字按屏幕固定字号排版，两种量纲混在一个 `VStack`
    /// 里，预算函数必须同时知道缩放才能算对（还是算不对 —— 见 `CanvasNodeText` 的类型注释里那个
    /// 溢出 bug）。十轮把缩放整层上移到节点层的 `scaleEffect(zoom)` 之后，卡片内部只剩**一种**
    /// 量纲：设计 pt。于是这里的预算变成一次性的静态计算 —— 缩放不再是它的输入，也就不可能因为
    /// 缩放而算错。
    ///
    /// 仍然保留这个预算（而不是退回"随便写写让 SwiftUI 自己挤"）的原因没变：三个分区里有两个
    /// （顶部路径行、底部入参文件行）的高度由**字号**决定，而字号是用户可调的（8~24pt）；节点高度
    /// 也可以被改。谁都不让位的话，SwiftUI 会把超出的部分挤出定高容器，屏幕上就是重叠。
    ///
    /// - Parameters:
    ///   - nodeHeight: 节点逻辑高度（设计 pt）。
    ///   - headerFontSize: 顶部路径行字号（设计 pt）。
    ///   - footerFontSize: 底部入参文件行字号（设计 pt）。
    public static func verticalPlan(nodeHeight: CGFloat,
                                    headerFontSize: CGFloat,
                                    footerFontSize: CGFloat) -> VerticalPlan {
        let total = max(0, nodeHeight)

        // 文字行：按行高保底，保证任何字号下都放得下一整行（不会出现"字被竖着切一半"）。
        let header = max(headerRowHeight, CanvasNodeText.lineHeight(headerFontSize))
        let footer = max(inputFilesRowHeight, CanvasNodeText.lineHeight(footerFontSize))
        // 纯几何留白：内边距 + header↔预览 + 预览↔正文 + 正文↔底行。
        let chrome = cardPadding * 2 + rowSpacing + previewToPromptGap + rowSpacing

        let flexible = max(0, total - header - footer - chrome)
        // 预览区想要的高度（比例规则不变），被剩余高度截断。
        let want = previewHeight(nodeHeight: nodeHeight)
        let preview = min(want, flexible)

        return VerticalPlan(headerHeight: header,
                            footerHeight: footer,
                            previewHeight: preview,
                            promptMaxHeight: max(0, flexible - preview),
                            fitsText: total >= header + footer + chrome)
    }

    /// `verticalPlan` 的结果。全部是**设计 pt**，视图直接拿去写 `frame`。
    public struct VerticalPlan: Equatable {
        /// 顶部路径行高度（按字号行高保底）。
        public let headerHeight: CGFloat
        /// 底部入参文件行高度（按字号行高保底）。
        public let footerHeight: CGFloat
        /// 预览区（堆叠卡片）高度。
        ///
        /// ★ 十轮：只有这一个值了。九轮那会儿还要额外给一个 `previewHeight1x`，因为预览区里的
        /// 扇形几何按 1x 收敛、而预算是排版单位，两者量纲不同、直接喂会乘两次。现在全仓统一成
        /// 设计单位，这类"反算回 1x"的补丁整类消失。
        public let previewHeight: CGFloat
        /// 正文区可用的最大高度。
        public let promptMaxHeight: CGFloat
        /// 卡片总高是否连"两行字 + 留白"都装不下。
        ///
        /// 装不下时视图应当整体隐藏文字。它与 `CanvasNodeText.nodeTextVisible`（视觉短边 < 40pt）
        /// 是**两个互补的判据**，取 AND 才写字：40pt 那条是用户给的屏幕规格（缩太小就别写），
        /// 这条是几何兜底（极扁的节点在 100% 下短边够 40pt，但高度仍塞不下两行字）。
        /// 两条都是**整体**隐藏，不是逐行。
        public let fitsText: Bool

        public init(headerHeight: CGFloat,
                    footerHeight: CGFloat,
                    previewHeight: CGFloat,
                    promptMaxHeight: CGFloat,
                    fitsText: Bool) {
            self.headerHeight = headerHeight
            self.footerHeight = footerHeight
            self.previewHeight = previewHeight
            self.promptMaxHeight = promptMaxHeight
            self.fitsText = fitsText
        }
    }
}

// MARK: - ★ v2.11.8 九轮：文本节点的自适应纵向预算（用户问题 2）

extension CanvasCardLayout {

    /// 文本节点（`kind == .text`）的纵向分区（单位 = **设计 pt**）。
    ///
    /// ## 用户报的现象
    ///
    /// 「文本节点内部虚线『+』文件区与底部文字输入框重叠、错位、跳变。」
    ///
    /// ## 根因
    ///
    /// 文本节点的卡片是 `VStack { 路径行; 文本框; 入参文件行 }`，外面套一个**定高** frame。
    /// 三个孩子里有两个的高度由**字号**决定（路径行、入参文件行），而文本框写的是
    /// `maxHeight: .infinity`（想吃掉全部剩余）+ 一个最小高。
    ///
    /// 于是当 `固定两行 + 文本框最小高 > 定高` 时（节点做矮、或正文字号被调到 24pt），
    /// SwiftUI 只能把超出的部分挤出容器 —— 表现就是两个区块**互相压住**、边界抖动。
    /// 这不是动画问题，是**预算问题**：谁都没被告知"你只有这么多高度"。
    ///
    /// ## 让位顺序（用户指定：优先保证输入框可见）
    ///
    ///   1. 高度够 → 路径行 + 文本框 + 入参文件行，文本框拿走全部剩余；
    ///   2. 高度不够放下"入参文件行 + 一行文本" → **隐藏入参文件行**，把它的高度全给文本框；
    ///   3. 连一行文本都放不下 → `fitsText == false`，调用方整体隐藏文字（与
    ///      `CanvasNodeText.nodeTextVisible` 的 40pt 规格互补，取 AND 才写字）。
    ///
    /// 关键是 `boxHeight` 是**精确值**而不是 `.infinity`：三段之和恒 ≤ 可用高度，
    /// 所以"重叠出界"从结构上不可能发生。
    ///
    /// ★ 十轮：入参里的 `renderScale` 已删除。缩放现在整层由节点层的 `scaleEffect(zoom)` 承担，
    /// 卡片内部只有设计 pt 一种量纲 —— 这个预算因此与 zoom 完全无关，缩放不可能把它算歪。
    ///
    /// - Parameters:
    ///   - availableHeight: 卡片**内容区**的设计高度（= 节点高 − 上下内边距）。
    ///     刻意收这个而不是 `nodeHeight`：视图侧用 `GeometryReader` 量到的就是这个值，
    ///     节点尺寸变化时它比 `node.height` 更贴近真实容器（少一帧滞后）。
    ///   - headerFontSize / footerFontSize / bodyFontSize: 三处的设计 pt。
    public static func textNodePlan(availableHeight: CGFloat,
                                    headerFontSize: CGFloat,
                                    footerFontSize: CGFloat,
                                    bodyFontSize: CGFloat) -> TextNodePlan {
        let total = max(0, availableHeight)
        // 行间距也必须被容器夹住：容器可能被压到只剩十几 pt（节点做得很矮 / 字号拉到 24pt），
        // 此时 `rowSpacing` 本身就可能超过整个可用高度，而 VStack 的 spacing 是**先扣掉**的
        // —— 不夹的话无论三段怎么分配，"之和 ≤ 容器高"都不可能成立。取 total/4 兜底：
        // 两个间距最多吃掉一半高度，正常尺寸下这个上限远大于 `rowSpacing`，不影响既有观感。
        let gap = min(rowSpacing, total / 4)

        // 路径行想要的高度：设计高与"一整行字"取大。
        let headerWanted = max(headerRowHeight, CanvasNodeText.lineHeight(headerFontSize))
        // ★ 但它**也要被容器夹住**：极矮的容器下固定行高本身就可能超过可用高度 —— 不夹的话
        // `header + gap` 就已经溢出，文本框拿到 0 高度也救不回来，屏幕上又变成两个区块互相压。
        // 夹住之后"三段之和 ≤ 容器高"才是**恒成立**的，而不是"高度充足时成立"。文字此时早已由
        // `fitsText == false` 整体隐藏，夹扁不可见。减 `gap` 是因为 VStack 的行间距对
        // "高度为 0 的孩子"照样生效。
        let header = min(headerWanted, max(0, total - gap))
        // 入参文件行 = 一行字 + 上下 5pt 内边距。
        let footer = max(inputFilesRowHeight,
                         CanvasNodeText.lineHeight(footerFontSize) + 2 * 5)
        // 文本框至少要放得下一整行正文 + 上下呼吸。
        let minBox = CanvasNodeText.lineHeight(bodyFontSize) + 2 * promptVerticalPadding

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

    /// `textNodePlan` 的结果，全部是**设计 pt**。
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
