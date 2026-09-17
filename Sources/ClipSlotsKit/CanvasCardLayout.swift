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
