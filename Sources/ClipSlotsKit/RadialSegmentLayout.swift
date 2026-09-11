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

    public init(thumbnailSide: CGFloat, thumbnailRadius: CGFloat, textRadius: CGFloat) {
        self.thumbnailSide = thumbnailSide
        self.thumbnailRadius = thumbnailRadius
        self.textRadius = textRadius
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
            let chord = 2 * midRadius * CGFloat(tan(halfDegrees * .pi / 180))
            byArcWidth = chord * arcWidthUtilization
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
                                   textRadius: textRadius)
    }
}
