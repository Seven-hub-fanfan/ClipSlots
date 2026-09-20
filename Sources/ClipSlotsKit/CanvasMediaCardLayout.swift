import CoreGraphics

/// 媒体节点卡片（图片 / 视频）的**纵向分区几何**（v2.15.0）。
///
/// ## 为什么不复用 `CanvasCardLayout`
///
/// 通用槽位卡的预算是「预览区按比例、正文吃剩下」——它的主角是**文字**，预览区有 34% 的上限，
/// 节点拖高多出来的高度全进正文。媒体卡的主角是**媒体**，优先级正好反过来：
/// 媒体区应该吃掉全部剩余，而提示词收成底部一条单行摘要。两套优先级塞进同一个函数就要多一个
/// `isMedia` 分支，而这个分支会穿透到 `previewHeight` / `plan` / 每条 smoke 断言 ——
/// 不如给媒体卡一张自己的预算表。
///
/// ## 卡片自上而下
///
/// ```text
///   路径标识行                    ← headerHeight（固定字号一行）
///   ── spacing ──
///   ┌──────────────────────┐
///   │   媒体区（aspect-fit） │     ← mediaHeight，吃掉全部剩余
///   │        [信息角标]      │       角标**悬浮在媒体区内**，不占纵向预算
///   └──────────────────────┘
///   ── spacing ──
///   提示词条（单行摘要）           ← promptHeight
/// ```
///
/// ## 让位顺序（与通用卡相反）
///
///   1. 高度够 → 三段齐全；
///   2. 媒体区跌破 `mediaMinHeight` → **先砍提示词条**（它的内容在属性面板 / 双击编辑里都能看到，
///      而媒体区一旦被压成一条缝，这张卡就完全丧失了"我是什么"的表达）；
///   3. 还不够 → 再砍路径行，媒体区独占全部高度，`fitsText == false`。
///
/// 三段之和恒**等于**可用高度（不是"小于等于"）：媒体区取的是精确剩余值而不是 `.infinity`，
/// 所以拖拽缩放时不可能出现区块互相压住 —— 这条经验是 v2.11.8 九轮修文本节点重叠时买来的。
public enum CanvasMediaCardLayout {

    // MARK: - 常量

    /// 卡片内边距（1x）。
    ///
    /// 比通用卡的 12 小：媒体卡的边框内侧紧跟着就是媒体区的圆角矩形，两层圆角之间留 12pt
    /// 会出现明显的"双层相框"感；8pt 刚好读作"一道描边"。
    public static let cardPadding: CGFloat = 8

    /// 路径标识行高度（1x）。
    public static let headerRowHeight: CGFloat = 13

    /// 底部提示词条高度（1x）。
    ///
    /// 只放**一行**摘要。媒体节点的提示词是"这张图怎么来的"，属于回看信息；要改要读全文走双击编辑
    /// 或右侧属性面板。给它两行就要从媒体区借 20pt，而媒体区少 20pt 是用户一眼能看见的损失。
    public static let promptStripHeight: CGFloat = 20

    /// 分区间距（1x）。
    public static let rowSpacing: CGFloat = 5

    /// 媒体区高度地板（1x）。低于这个值媒体就只是一条色带，认不出内容。
    public static let mediaMinHeight: CGFloat = 36

    /// 媒体区圆角（1x）。
    public static let mediaCornerRadius: CGFloat = 8

    /// 信息角标与媒体区边缘的距离（1x）。
    public static let badgeInset: CGFloat = 6

    /// 媒体节点的默认尺寸。
    ///
    /// 比通用卡（320×220）更高更窄：媒体卡里没有 4 行正文要横向铺开，而 3:4 的外框能同时把
    /// 竖图和横图放得不难看（横图上下留边、竖图左右留边，两种留边都在可接受范围）。
    /// 宽度沿用 280 是为了让媒体卡和槽位卡摆在一起时网格感不破。
    public static let defaultSize = CGSize(width: 280, height: 300)

    // MARK: - 预算

    public struct Plan: Equatable {
        public let headerHeight: CGFloat
        /// 媒体区的**精确**高度。
        public let mediaHeight: CGFloat
        /// 底部提示词条高度；`showPrompt == false` 时为 0。
        public let promptHeight: CGFloat
        /// VStack 行间距。视图必须照用（不能自己写 `s(5)`），否则极端矮容器下预算不再闭合。
        public let spacing: CGFloat
        /// 路径行是否还画得下。
        public let showHeader: Bool
        /// 底部提示词条是否还画得下。
        public let showPrompt: Bool
        /// 是否还画得下文字（与 `CanvasScreenText.textVisible` 取 OR 使用）。
        public let fitsText: Bool

        public init(headerHeight: CGFloat,
                    mediaHeight: CGFloat,
                    promptHeight: CGFloat,
                    spacing: CGFloat,
                    showHeader: Bool,
                    showPrompt: Bool,
                    fitsText: Bool) {
            self.headerHeight = headerHeight
            self.mediaHeight = mediaHeight
            self.promptHeight = promptHeight
            self.spacing = spacing
            self.showHeader = showHeader
            self.showPrompt = showPrompt
            self.fitsText = fitsText
        }
    }

    /// - Parameters:
    ///   - availableHeight: 卡片**内容区**的排版高度（= 节点高 × renderScale − 上下内边距）。
    ///   - renderScale: 排版缩放。
    ///   - headerFontSize / promptFontSize: **设计 pt**（不随缩放变，见 `CanvasScreenText.font`）。
    public static func plan(availableHeight: CGFloat,
                           renderScale: CGFloat,
                           headerFontSize: CGFloat,
                           promptFontSize: CGFloat) -> Plan {
        let rs = max(0.01, renderScale)
        let total = max(0, availableHeight)
        // 间距也要被容器夹住：rs=2 时 `rowSpacing × rs` = 10pt，而可用高度可能只有 8pt。
        // VStack 的 spacing 是先扣掉的，不夹就无论怎么分配都超。
        let gap = min(rowSpacing * rs, total / 4)

        let headerWanted = max(headerRowHeight * rs, CanvasScreenText.lineHeight(headerFontSize))
        let promptWanted = max(promptStripHeight * rs,
                               CanvasScreenText.lineHeight(promptFontSize) + 2 * 3 * rs)
        let minMedia = mediaMinHeight * rs

        // 方案 1：三段齐全。
        let mediaFull = total - headerWanted - promptWanted - 2 * gap
        if mediaFull >= minMedia {
            return Plan(headerHeight: headerWanted,
                        mediaHeight: mediaFull,
                        promptHeight: promptWanted,
                        spacing: gap,
                        showHeader: true,
                        showPrompt: true,
                        fitsText: true)
        }

        // 方案 2：砍提示词条。
        let mediaNoPrompt = total - headerWanted - gap
        if mediaNoPrompt >= minMedia {
            return Plan(headerHeight: headerWanted,
                        mediaHeight: mediaNoPrompt,
                        promptHeight: 0,
                        spacing: gap,
                        showHeader: true,
                        showPrompt: false,
                        fitsText: true)
        }

        // 方案 3：媒体独占。`fitsText == false`，文字整体隐藏。
        return Plan(headerHeight: 0,
                    mediaHeight: total,
                    promptHeight: 0,
                    spacing: 0,
                    showHeader: false,
                    showPrompt: false,
                    fitsText: false)
    }

    // MARK: - aspect-fit

    /// 把 `content` 按比例放进 `container`（contain 语义，不裁切、不放大超过容器）。
    ///
    /// 抽成纯函数不是因为 SwiftUI 不会做 —— `.aspectRatio(contentMode: .fit)` 当然会做。
    /// 是因为**空态**也要按比例画：媒体节点还没有产物时，占位虚线框必须按用户选的 `ratio` 画，
    /// 否则选了 `9:16` 却看到一个横框，会被读成"参数没生效"。那个占位框没有内容可以让 SwiftUI
    /// 去 fit，只能自己算。顺带这条几何也就能被 smoke 钉住了。
    ///
    /// 任一维度非正时返回 `.zero`：那是"没量到"，画一个 0 尺寸的框比画一个瞎猜的框好。
    public static func fittedSize(content: CGSize, in container: CGSize) -> CGSize {
        guard content.width > 0, content.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        return CGSize(width: content.width * scale, height: content.height * scale)
    }
}
