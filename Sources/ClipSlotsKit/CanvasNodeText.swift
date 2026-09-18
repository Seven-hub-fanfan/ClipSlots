import CoreGraphics

/// 画布节点文字的**行高度量**与**可见性闸门**（v2.11.8 十轮 · 架构改回「等比缩放」）。
///
/// ## 这一版把方向掉了个头
///
/// 二~九轮的方向是「屏幕字号固定」：卡片内部按 `renderScale` 排版（宽度、内边距全乘一遍），
/// 而文字**刻意不乘**、再挂一层 `scaleEffect(layoutZoom / zoom)` 反向补偿，想让文字在屏幕上
/// 恒为 13pt。九轮把补偿系数算到了严格精确，离屏光栅化测量四档都是 0px 误差 —— 但用户第
/// N 次录屏（20260918110609）显示的现象是**文字从卡片底部溢出、悬浮在画布背景上**，并伴随
/// 换行抖动。
///
/// 根因不在系数，在**量纲**：
///
/// ```text
///   卡片排版宽度 = 260 × renderScale     ← 随缩放变
///   文字排版字号 = 13（屏幕固定）        ← 不随缩放变
/// ```
///
/// 缩小到 25% 时容器宽只有 65pt，而文字仍按 13pt 排版并被补偿成屏幕 13pt —— 文字的物理尺寸
/// 相对容器**变成了 4 倍**。SwiftUI 于是在 65pt 宽里给 13pt 字折行（每帧宽度都在变 → 每帧
/// 重新折行 = 抖动），补偿层再把这坨已经折错的文字整体放大 4 倍 → 越过卡片边框飘到背景上。
/// 补偿系数再精确也救不了：溢出是"内容比容器大"，不是"字号不对"。
///
/// ## 十轮的架构：只有一套量纲
///
/// ```text
///   节点子树全部按**设计稿尺寸**排版（260pt 宽、13pt 字、8pt 内边距……），与 zoom 无关
///   节点层套一层 scaleEffect(zoom)                        ← 唯一的缩放来源
/// ```
///
/// 于是：
///   - **布局只算一次**。zoom 不进任何 `frame` / `font` / `padding`，SwiftUI 没有任何理由重新
///     折行，换行位置在 25% 和 200% 下逐字相同 —— 抖动被结构性消灭，而不是靠某个系数凑准。
///   - **文字随卡片等比缩放**。屏幕字号 = `13 × zoom`，文字与卡片的相对比例恒定，永远不可能
///     溢出边框（这是相似变换的性质，不依赖任何阈值）。
///   - 代价是缩小/放大时文字是位图变换（放大后偏软）。这是用户本轮明确选择的取舍：宁可略软，
///     也不要溢出和抖动。**不要再把 `renderScale` 塞回卡片内部** —— 那条路走过五轮，
///     它与「屏幕固定字号」组合出的就是上面那个溢出 bug。
///
/// 本文件只剩两类纯函数：
///   1. **行高度量**：给 `CanvasCardLayout` 做纵向预算用（设计单位，与 zoom 无关）；
///   2. **可见性闸门**：节点/卡片在屏幕上太小时整块文字淡出（用户需求 3）。
public enum CanvasNodeText {

    // MARK: - 行高度量（设计单位）

    /// 行高 / 字号 比。
    ///
    /// SwiftUI 的 `Text` 实际行高由字体的 ascent/descent/leading 决定，系统字在 13pt 下约
    /// 15.5pt（≈1.19）。预算里取 1.2 略微保守：取小了会放过"刚好差一点"的情形（屏幕上就是
    /// 字被切掉半行），取大了只是浪费一点高度 —— 两种错误的代价不对称。
    public static let lineHeightFactor: CGFloat = 1.2

    /// 某字号占的行高（设计单位）。
    public static func lineHeight(_ fontSize: CGFloat) -> CGFloat {
        max(0, fontSize) * lineHeightFactor
    }

    /// 给定高度能完整放下几行（不足一行返回 0，**不返回半行**）。
    public static func fittingLineCount(boxHeight: CGFloat, fontSize: CGFloat) -> Int {
        let h = lineHeight(fontSize)
        guard h > 0, boxHeight > 0 else { return 0 }
        return Int((boxHeight / h).rounded(.down))
    }

    // MARK: - 可见性闸门（唯一允许吃 zoom 的地方）

    /// 节点在屏幕上的短边小于这个值时，整块文字淡出。
    ///
    /// 用户需求 3 给的就是 40pt。取"短边"而不是面积：一个 300×20 的极扁节点，面积不小但那 20pt
    /// 高里塞不进任何一行有意义的文字。
    public static let nodeTextMinVisualSize: CGFloat = 40

    /// 扇形牌面卡的阈值比节点低 —— 卡片本来就是节点的零件，等到节点级阈值才隐藏的话，
    /// 牌面上早就只剩糊成一团的噪点了。
    public static let cardTextMinVisualSize: CGFloat = 24

    /// 逻辑尺寸 + 缩放 → 屏幕上的**短边**。
    public static func visualShortSide(size: CGSize, zoom: CGFloat) -> CGFloat {
        max(0, min(size.width, size.height)) * max(0, zoom)
    }

    /// 节点这块文字该不该写。
    public static func nodeTextVisible(nodeSize: CGSize,
                                       zoom: CGFloat,
                                       threshold: CGFloat = nodeTextMinVisualSize) -> Bool {
        visualShortSide(size: nodeSize, zoom: zoom) >= threshold
    }

    /// 牌面卡这块文字该不该写。
    public static func cardTextVisible(cardSize: CGSize,
                                       zoom: CGFloat,
                                       threshold: CGFloat = cardTextMinVisualSize) -> Bool {
        visualShortSide(size: cardSize, zoom: zoom) >= threshold
    }

    /// 闸门用的 zoom **量化步长**。
    ///
    /// 为什么要量化：闸门是唯一把 zoom 传进卡片的通道，若传实时值，捏合手势的每一帧都会让卡片
    /// 视图重新求值（几十个节点 × 60fps）。量化到 5% 后，一次完整的 25%→200% 缩放只让卡片重新
    /// 求值 30 来次。
    ///
    /// **注意**：量化只影响"何时重新求值"和"闸门在哪一帧翻转"，绝不参与任何几何计算 ——
    /// 卡片内部的尺寸一律是设计稿常量。这是本文件类型注释里那条架构约束的关键前提。
    public static let gateZoomStep: CGFloat = 0.05

    /// 把实时 zoom 量化成闸门用的档位值。
    public static func gateZoom(_ zoom: CGFloat) -> CGFloat {
        let z = max(0, zoom)
        let step = max(0.001, gateZoomStep)
        return (z / step).rounded() * step
    }

    /// 文字整块的不透明度（`1` 写字 / `0` 淡出）。
    ///
    /// 刻意不做「逐行判定」：八轮试过按行裁，结果是同一段文字里上面几行在、下面几行没了，
    /// 用户看到的是"文字被吃掉一半"。要么整块写，要么整块不写。
    public static func textOpacity(nodeSize: CGSize,
                                   zoom: CGFloat,
                                   fitsBox: Bool = true,
                                   threshold: CGFloat = nodeTextMinVisualSize) -> Double {
        (fitsBox && nodeTextVisible(nodeSize: nodeSize, zoom: zoom, threshold: threshold)) ? 1 : 0
    }
}
