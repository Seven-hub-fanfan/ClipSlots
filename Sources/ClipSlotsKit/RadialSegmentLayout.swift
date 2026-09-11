import CoreGraphics
import Foundation

// MARK: - 轮盘扇区手动缩略图布局（v2.11.0 hotfix）
//
// 为什么这段「UI 几何」住在 Kit 而不是视图文件里：
//
// v2.11.0 首个构建的缩略图错位 bug，根因是**几何算错**而不是渲染错——扇区内容原本是一个
// `VStack` 用 `.offset(x:y:)` 把**整体中心**摆到扇区中轴线的中点上。当 VStack 里只有
// 「编号 + 标签」（高 ~40pt）时这没问题；一旦塞进 56pt 的缩略图，VStack 高度涨到 ~98pt，
// 而缩略图作为首个子视图会被推到 VStack 顶部——也就是**屏幕正上方** ~21pt 处。
//
// 「屏幕正上方」只对正上方那个扇区等价于「沿中轴线向外」。对其余扇区，这个位移是**垂直于
// 中轴线**的分量，于是缩略图整体歪出自己的楔形：实测 10 槽位布局下 8 个扇区的角偏差达
// 25°~30°（半扇区只有 18°），顶部扇区还会被顶到 r≈168pt 紧贴圆盘边缘。
//
// 把数学从 SwiftUI 视图里剥出来变成纯函数，才能用 smoke 测试直接断言
// 「缩略图四角必须落在本扇区楔形内、且不越过内外半径」这条不变量，防止再次回归。

/// 一个扇区内「缩略图 + 文字块」沿中轴线的布局结果。
///
/// 两个元素各自持有**独立的极坐标锚点**（都在扇区中轴线上），而不是共用一个 VStack ——
/// 这是本 hotfix 的核心：沿中轴线排布，位移方向永远是「径向」，不会随扇区方位漂移。
public struct RadialSegmentLayout: Equatable, Sendable {
    /// 缩略图边长（屏幕坐标轴对齐的正方形）。
    public let thumbnailSide: CGFloat
    /// 缩略图中心到圆盘圆心的距离（沿扇区中轴线，偏外侧）。
    public let thumbnailRadius: CGFloat
    /// 文字块（编号 + 标签）中心到圆盘圆心的距离（沿扇区中轴线，偏内侧）。
    public let textRadius: CGFloat
    /// 文字块允许的最大宽度（受楔形在 `textRadius` 处的弦宽约束）。
    public let textBlockWidth: CGFloat

    public init(thumbnailSide: CGFloat, thumbnailRadius: CGFloat, textRadius: CGFloat, textBlockWidth: CGFloat) {
        self.thumbnailSide = thumbnailSide
        self.thumbnailRadius = thumbnailRadius
        self.textRadius = textRadius
        self.textBlockWidth = textBlockWidth
    }
}

/// 轮盘扇区布局的纯几何计算器（无 AppKit / SwiftUI 依赖，可直接单测）。
public enum RadialSegmentLayoutCalculator {

    /// 缩略图边长上限。再大就会挤掉编号与标签的可读空间。
    public static let maxThumbnailSide: CGFloat = 56
    /// 边长下限。小于这个尺寸的封面图已经看不出内容，不如退回纯文字扇区。
    public static let minThumbnailSide: CGFloat = 26
    /// 文字块（编号 20pt + 间距 + 标签 9pt）的估算高度，仅用于沿中轴线分配位置。
    public static let textBlockHeight: CGFloat = 40
    /// 缩略图与文字块之间的间距。
    public static let stackGap: CGFloat = 4
    /// 距扇区内/外边界的安全留白，避免压线或压到分隔线端点。
    public static let edgeMargin: CGFloat = 6
    /// 角向可用弦宽的利用率。0.62 = 留出约 1/3 余量，实测可把最坏角偏差压到
    /// 半扇区角的 ~75% 以内（见 smoke 测试的四角断言）。
    public static let arcWidthUtilization: CGFloat = 0.62
    /// 文字块的最小宽度。再窄连「10」+ 一个省略号都放不下，宁可让它轻微压线。
    public static let minTextBlockWidth: CGFloat = 48
    /// 文字块相对弦宽的利用率。文字是横平的一行，比方形缩略图更贴合弦，
    /// 所以可以比 `arcWidthUtilization` 宽松一些。
    public static let textWidthUtilization: CGFloat = 0.9

    /// 楔形在半径 `radius` 处的可用弦宽（单侧半角 `segmentDegrees/2`）。
    /// `segmentDegrees >= 179` 时楔形不再构成约束，返回 `.greatestFiniteMagnitude`。
    public static func chordWidth(atRadius radius: CGFloat, segmentDegrees: Double) -> CGFloat {
        let halfDegrees = segmentDegrees / 2
        guard halfDegrees < 89.5 else { return .greatestFiniteMagnitude }
        return 2 * radius * CGFloat(tan(halfDegrees * .pi / 180))
    }

    /// 文字块在半径 `radius` 处允许的最大宽度。
    ///
    /// 为什么需要它：此前文字块宽度写死为 `midRadius * 0.78`（10 槽位下 ≈ 87pt），
    /// 而楔形在文字块所在半径处的弦宽只有 ~57pt —— 长标签因此**横向溢出到邻居扇区**，
    /// 并且在斜向扇区里正好撞上本扇区沿中轴线外移的缩略图（截图里 4 号扇区的标签
    /// 与缩略图相贴即由此而来）。按弦宽收敛后，文字永远待在自己的楔形里。
    public static func textBlockWidth(atRadius radius: CGFloat,
                                      segmentDegrees: Double,
                                      preferred: CGFloat) -> CGFloat {
        let byChord = chordWidth(atRadius: radius, segmentDegrees: segmentDegrees) * textWidthUtilization
        return max(minTextBlockWidth, min(preferred, byChord))
    }

    /// 计算某个扇区内缩略图 + 文字块的布局。
    ///
    /// - Parameters:
    ///   - innerRadius: 扇区内半径（死区外沿）。
    ///   - outerRadius: 扇区外半径（圆盘内沿）。
    ///   - segmentDegrees: 单个扇区的张角（度）。360 表示只有一个扇区。
    /// - Returns: 放得下缩略图时返回布局；扇区太窄或太薄放不下时返回 `nil`，
    ///            调用方应退回「纯文字居中」的原有渲染。
    public static func layout(innerRadius: CGFloat,
                             outerRadius: CGFloat,
                             segmentDegrees: Double) -> RadialSegmentLayout? {
        guard outerRadius > innerRadius, innerRadius >= 0, segmentDegrees > 0 else { return nil }

        let midRadius = (innerRadius + outerRadius) / 2
        let band = outerRadius - innerRadius

        // 约束 1（角向）：扇区在中轴线中点处的可用弦宽。楔形越往内越窄，用中点处估算
        // 已经足够保守——缩略图被摆在中点**外侧**，那里的楔形只会更宽。
        // 半扇区角 ≥ 90° 时楔形已不构成约束（tan 发散），直接放开。
        let halfDegrees = segmentDegrees / 2
        let byArcWidth: CGFloat
        if halfDegrees >= 89.5 {
            byArcWidth = .greatestFiniteMagnitude
        } else {
            byArcWidth = chordWidth(atRadius: midRadius, segmentDegrees: segmentDegrees) * arcWidthUtilization
        }

        // 约束 2（径向）：环带厚度要同时容纳缩略图、间距、文字块和两侧留白。
        let byBand = band - textBlockHeight - stackGap - 2 * edgeMargin

        let side = min(maxThumbnailSide, min(byArcWidth, byBand))
        guard side >= minThumbnailSide else { return nil }

        // 沿中轴线把「缩略图（外）+ 间距 + 文字块（内）」整体居中于环带中点：
        // 缩略图外移 (文字块高 + 间距)/2，文字块内移 (缩略图边长 + 间距)/2。
        var thumbnailRadius = midRadius + (textBlockHeight + stackGap) / 2
        // 正方形绕锚点最远的角按外接圆半径 side/√2 保守估计，确保不越过外沿。
        let maxThumbnailRadius = outerRadius - edgeMargin - side * CGFloat(2.0.squareRoot()) / 2
        thumbnailRadius = min(thumbnailRadius, maxThumbnailRadius)

        // 文字块同理不许压进死区。
        let minTextRadius = innerRadius + edgeMargin + textBlockHeight / 2
        let textRadius = max(midRadius - (side + stackGap) / 2, minTextRadius)

        guard thumbnailRadius > textRadius else { return nil }

        return RadialSegmentLayout(thumbnailSide: side,
                                   thumbnailRadius: thumbnailRadius,
                                   textRadius: textRadius,
                                   textBlockWidth: textBlockWidth(atRadius: textRadius,
                                                                  segmentDegrees: segmentDegrees,
                                                                  preferred: midRadius * 0.78))
    }
}

// MARK: - 「上次粘贴」扇区外弧（v2.11.1）

/// 扇区外沿那条「上次粘贴」高亮弧的几何参数（圆心与扇区同心）。
///
/// 为什么只画**外弧**而不是整条楔形轮廓：`PieSegmentShape.stroke` 会同时描出外弧、
/// 两条径向边和内弧，视觉重量远超一个状态标识，而且径向边与相邻扇区的分隔线重合，
/// 会让人误以为是「选中了两个扇区」。只描外弧既醒目又不污染分隔线。
public struct RadialLastPasteArc: Equatable {
    /// 弧线中心线所在半径（已扣掉线宽的一半与外沿留白）。
    public let radius: CGFloat
    public let lineWidth: CGFloat
    public let startDegrees: Double
    public let endDegrees: Double

    public init(radius: CGFloat, lineWidth: CGFloat, startDegrees: Double, endDegrees: Double) {
        self.radius = radius
        self.lineWidth = lineWidth
        self.startDegrees = startDegrees
        self.endDegrees = endDegrees
    }

    public var spanDegrees: Double { endDegrees - startDegrees }
    /// 弧线外缘（含线宽）触及的最大半径——用来断言「不越出扇区外沿」。
    public var outerEdgeRadius: CGFloat { radius + lineWidth / 2 }
    /// 弧线内缘触及的最小半径——用来断言「不压到缩略图」。
    public var innerEdgeRadius: CGFloat { radius - lineWidth / 2 }
}

extension RadialSegmentLayoutCalculator {

    /// 「上次粘贴」外弧线宽。
    public static let lastPasteArcLineWidth: CGFloat = 3.5
    /// 弧线外缘与扇区外沿之间的留白，避免和圆盘内阴影糊在一起。
    public static let lastPasteArcEdgeMargin: CGFloat = 1.5
    /// 弧线两端相对扇区分隔线内缩的**弧长**（pt）。用弧长而不是固定角度，
    /// 这样槽位数变化时两端的视觉留白保持一致。
    public static let lastPasteArcEndInset: CGFloat = 6
    /// 内缩后至少要保留的张角，否则宁可不画（扇区太窄时画出来就是一个点）。
    public static let lastPasteArcMinSpanDegrees: Double = 4

    /// 计算某扇区的「上次粘贴」外弧。
    ///
    /// - Parameters:
    ///   - outerRadius: 扇区外半径（与 `layout(innerRadius:outerRadius:segmentDegrees:)` 同一口径）。
    ///   - startDegrees / endDegrees: 扇区起止角（与扇区绘制用的角度同一坐标系，度）。
    /// - Returns: 可绘制时返回弧参数；扇区退化或太窄时返回 `nil`（调用方不画）。
    public static func lastPasteArc(outerRadius: CGFloat,
                                    startDegrees: Double,
                                    endDegrees: Double) -> RadialLastPasteArc? {
        let span = endDegrees - startDegrees
        guard span > 0 else { return nil }

        let radius = outerRadius - lastPasteArcEdgeMargin - lastPasteArcLineWidth / 2
        guard radius > 0 else { return nil }

        // 端点内缩：把固定弧长换算成角度；同时最多只吃掉本扇区 1/4 的张角，
        // 保证窄扇区下弧线不会被两端啃光。
        let byLength = Double(lastPasteArcEndInset / radius) * 180 / .pi
        let inset = min(byLength, span / 4)
        let start = startDegrees + inset
        let end = endDegrees - inset
        guard end - start >= min(lastPasteArcMinSpanDegrees, span) else { return nil }

        return RadialLastPasteArc(radius: radius,
                                  lineWidth: lastPasteArcLineWidth,
                                  startDegrees: start,
                                  endDegrees: end)
    }
}

// MARK: - 扇区编号行的横向排布约束（v2.11.1）

extension RadialSegmentLayoutCalculator {

    /// 编号行里一个状态角标（附件回形针等）的占位宽度。
    public static let badgeIconWidth: CGFloat = 13
    /// 串联色点的直径（与 `RadialMenuView.segmentTextBlock` 里的 Circle 保持一致）。
    public static let connectionDotWidth: CGFloat = 6
    /// 编号行内各元素间距（与 HStack(spacing:) 保持一致）。
    public static let numberRowSpacing: CGFloat = 4
    /// 槽位编号「10」在 20pt bold rounded 下的宽度上限估算（槽位数上限就是 10）。
    public static let slotNumberMaxWidth: CGFloat = 26

    /// 编号行（槽位编号 + 可选串联色点 + N 个状态角标）的估算总宽。
    ///
    /// 为什么把它做成纯函数：v2.11.0 hotfix 的教训是「往扇区里加元素」必须先算清楚
    /// 它会不会越出楔形。角标横向排布时的约束就是这行的总宽 ≤ 该半径处弦宽，
    /// 有了纯函数才能在 smoke 测试里把这条不变量钉死。
    public static func numberRowWidth(hasConnectionDot: Bool, badgeCount: Int) -> CGFloat {
        var width = slotNumberMaxWidth
        if hasConnectionDot { width += numberRowSpacing + connectionDotWidth }
        if badgeCount > 0 {
            width += CGFloat(badgeCount) * (numberRowSpacing + badgeIconWidth)
        }
        return width
    }

    /// 编号行在半径 `radius` 处是否仍待在自己的楔形内。
    public static func numberRowFits(hasConnectionDot: Bool,
                                     badgeCount: Int,
                                     atRadius radius: CGFloat,
                                     segmentDegrees: Double) -> Bool {
        let width = numberRowWidth(hasConnectionDot: hasConnectionDot, badgeCount: badgeCount)
        return width <= chordWidth(atRadius: radius, segmentDegrees: segmentDegrees)
    }
}
