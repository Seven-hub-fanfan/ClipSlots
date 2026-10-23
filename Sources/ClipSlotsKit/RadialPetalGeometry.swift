import CoreGraphics
import Foundation

// MARK: - 花瓣扇区几何（v2.11.5）
//
// v2.11.4 之前，轮盘扇区是**硬边扇形**：两条径向直边直接顶到相邻扇区，靠一条 1pt 分隔线
// 划界。十格排下来是一整块被切开的披萨，没有「一格一张卡」的独立感，视觉上也谈不上精致。
//
// v2.11.5 改成「花瓣式」：每个扇区变成一张带大圆角、四周留白的独立卡片。
//
// 几何上真正需要想清楚的是**间隙怎么定义**。有两种做法：
//
//   ① 固定角度内缩（θ ± k 度）：实现最省事，但间隙宽度随半径线性增长——内圈两瓣几乎贴在
//      一起，外圈却裂开一道十几 pt 的大口子。10 槽位、内半径 46pt / 外半径 178pt 的实际
//      比例下，同一个 2° 内缩在内圈只有 1.6pt、在外圈是 6.2pt，看着像做坏了。
//   ② 固定**垂直距离**内缩（本文件的做法）：花瓣的侧边是一条与原径向边平行、垂直距离恒为
//      gap/2 的**直线**。这样从内到外整条通道宽度恒等于 gap，才是参考图里那种均匀留白。
//
// 做法②的代价是花瓣侧边不再穿过圆心，边界角度成了半径的函数：
//
//      Δ(r) = asin(h / r)，其中 h = gap / 2
//
// 于是花瓣在半径 r 处的角度范围是 [θ_start + Δ(r), θ_end − Δ(r)]。内圈 Δ 大、外圈 Δ 小，
// 花瓣自然呈现「上宽下窄的花瓣形」，与参考图一致。r 必须大于 h（本 App 内圈 46pt ≫ 2.5pt），
// 且扇区数极多时要防止 2Δ 吃光整个张角 —— 见 `sideInset` 的收紧逻辑。
//
// 圆角用**二次贝塞尔**实现，控制点就放在被切掉的几何拐角上：曲线在两个切点处分别与相邻的
// 两条边相切，因此接缝是光滑的，而且天然不会像 `addArc(tangent1End:...)` 那样在「直线接圆弧」
// 的场合退化失败（CGPath 的切线圆弧只支持两条直线）。切点距离（trim）就是圆角的视觉半径量级。
//
// 为什么这堆数学住在 Kit 而不是 SwiftUI 视图里：与 v2.11.0 的缩略图布局同理 —— 本机跑不了
// App 层测试，而「花瓣必须完整落在自己的楔形内」「相邻花瓣的通道宽度必须恒为 gap」「圆角不能
// 大到让路径自交」这些都是**可断言的不变量**，不是审美问题。放进 Kit 才能被 smoke 直接钉住。

/// 花瓣路径的一段基元。视图层只负责把它们逐条喂给 `SwiftUI.Path`，不参与任何计算。
///
/// 坐标一律是**相对圆心**的偏移（视图层再加上 center），角度单位为弧度，
/// 坐标系与 SwiftUI / AppKit 视图一致：x 向右、y 向下、0 弧度指向正右方、角度增大为屏幕顺时针。
public enum RadialPetalPathElement: Equatable {
    case move(CGPoint)
    case line(CGPoint)
    /// 二次贝塞尔圆角：`control` 落在被切掉的几何拐角上。
    case quad(to: CGPoint, control: CGPoint)
    /// 与圆盘同心的圆弧。`clockwise` 语义与 `SwiftUI.Path.addArc` 一致
    /// （在 y 向下的坐标系里，`false` = 角度递增方向）。
    case arc(radius: CGFloat, startRadians: CGFloat, endRadians: CGFloat, clockwise: Bool)
    case close
}

/// 一枚花瓣扇区的完整几何解，附带「实际生效」的参数以便断言与调试。
public struct RadialPetal: Equatable {
    /// 路径基元序列，固定为 move → arc → quad → line → quad → arc → quad → line → quad → close。
    public let elements: [RadialPetalPathElement]

    /// 实际生效的侧边内缩（垂直距离，= 通道宽度的一半）。可能被扇区宽度收紧到小于请求值。
    public let sideInset: CGFloat
    /// 实际生效的外侧圆角切点距离。
    public let outerCornerTrim: CGFloat
    /// 实际生效的内侧圆角切点距离（内圈弧短，通常比外侧小）。
    public let innerCornerTrim: CGFloat

    public let innerRadius: CGFloat
    public let outerRadius: CGFloat
    /// 原始（未内缩）扇区起止角，单位度。用于断言「花瓣不越出自己的楔形」。
    public let startDegrees: Double
    public let endDegrees: Double

    /// 四个几何拐角（未倒角时的尖角），顺序：外-起始边、外-结束边、内-结束边、内-起始边。
    public let corners: [CGPoint]

    /// 花瓣在指定半径处的角度范围（度）。半径超出 [inner, outer] 时仍按公式外推，方便测试采样。
    public func angleRange(atRadius r: CGFloat) -> (start: Double, end: Double) {
        let delta = RadialPetalGeometry.insetDegrees(atRadius: r, sideInset: sideInset)
        return (startDegrees + delta, endDegrees - delta)
    }
}

public enum RadialPetalGeometry {

    // MARK: - 默认视觉参数

    /// 花瓣之间的通道宽度（pt）。5pt 是在 10 槽位下试出来的甜点：4pt 偏挤、6pt 起花瓣开始显瘦。
    public static let defaultGap: CGFloat = 5
    /// 请求的圆角切点距离。实际值会被弧长 / 径向长度收紧（见 `clampedTrim`）。
    public static let defaultCornerTrim: CGFloat = 18

    // MARK: - 基础换算

    /// 侧边内缩对应的角度偏移：Δ(r) = asin(h / r)，单位度。
    ///
    /// r ≤ h 时（理论上不该发生，内圈半径远大于半间隙）退化为 90°，
    /// 让调用方的宽度判断自然走进「扇区太窄」分支，而不是产生 NaN。
    public static func insetDegrees(atRadius r: CGFloat, sideInset h: CGFloat) -> Double {
        guard h > 0 else { return 0 }
        guard r > h else { return 90 }
        return Double(asin(h / r)) * 180 / .pi
    }

    /// 扣掉两侧通道后，花瓣在半径 r 处**实际可用**的张角（度）。
    ///
    /// 文字块 / 缩略图的宽度必须按这个角度算，否则会压在花瓣边缘上甚至探出通道。
    public static func effectiveSegmentDegrees(atRadius r: CGFloat,
                                              segmentDegrees: Double,
                                              sideInset h: CGFloat) -> Double {
        max(0, segmentDegrees - 2 * insetDegrees(atRadius: r, sideInset: h))
    }

    /// 把请求的间隙收紧到内圈也放得下的程度。
    ///
    /// 约束：内圈处两侧内缩合计不得吃掉超过 60% 的张角（即单侧 Δ ≤ 0.3 × span），
    /// 否则窄扇区（比如一页 30 个组）会被通道压成一根针甚至反向自交。
    public static func clampedSideInset(requestedGap gap: CGFloat,
                                       innerRadius: CGFloat,
                                       segmentDegrees: Double) -> CGFloat {
        guard gap > 0, innerRadius > 0, segmentDegrees > 0 else { return 0 }
        let h = gap / 2
        let maxDeltaDegrees = min(60.0, 0.3 * segmentDegrees)
        let maxH = innerRadius * CGFloat(sin(maxDeltaDegrees * .pi / 180))
        return min(h, maxH)
    }

    /// 圆角切点距离的收紧：不能超过所在边一半的长度，否则两端切点交叉、路径自交。
    static func clampedTrim(_ requested: CGFloat, edgeLengths: [CGFloat]) -> CGFloat {
        var trim = max(0, requested)
        for length in edgeLengths {
            trim = min(trim, max(0, length * 0.45))
        }
        return trim
    }

    // MARK: - 主入口

    /// 求解一枚花瓣扇区。
    ///
    /// - Parameters:
    ///   - startDegrees/endDegrees: 原始扇区角度（`end > start`，可跨越 360）。
    ///   - innerRadius/outerRadius: 环带内外半径。
    ///   - gap: 期望的**通道总宽**（相邻花瓣之间的垂直距离）。
    ///   - cornerTrim: 期望的圆角切点距离。
    /// - Returns: 几何解；输入退化（内外半径倒置、张角非正等）时返回 nil，调用方应回退到不画。
    public static func petal(startDegrees: Double,
                             endDegrees: Double,
                             innerRadius: CGFloat,
                             outerRadius: CGFloat,
                             gap: CGFloat = defaultGap,
                             cornerTrim: CGFloat = defaultCornerTrim) -> RadialPetal? {
        let span = endDegrees - startDegrees
        guard span > 0, innerRadius > 0, outerRadius > innerRadius else { return nil }

        let h = clampedSideInset(requestedGap: gap, innerRadius: innerRadius, segmentDegrees: span)

        let outerDelta = insetDegrees(atRadius: outerRadius, sideInset: h)
        let innerDelta = insetDegrees(atRadius: innerRadius, sideInset: h)
        let outerSpan = span - 2 * outerDelta
        let innerSpan = span - 2 * innerDelta
        // 收紧之后仍然摆不下（极端窄扇区），宁可不画也不要画出自交的怪形状。
        guard outerSpan > 0.5, innerSpan > 0.5 else { return nil }

        let a1 = startDegrees + outerDelta      // 外弧起点角
        let a2 = endDegrees - outerDelta        // 外弧终点角
        let b1 = startDegrees + innerDelta      // 内弧起点角（靠起始边）
        let b2 = endDegrees - innerDelta        // 内弧终点角（靠结束边）

        let cornerOuterStart = point(radius: outerRadius, degrees: a1)
        let cornerOuterEnd = point(radius: outerRadius, degrees: a2)
        let cornerInnerEnd = point(radius: innerRadius, degrees: b2)
        let cornerInnerStart = point(radius: innerRadius, degrees: b1)

        // 侧边是直线，长度可直接由勾股定理给出：沿线到圆心垂足的距离是 √(r² − h²)。
        let sideLength = sqrt(max(0, outerRadius * outerRadius - h * h))
            - sqrt(max(0, innerRadius * innerRadius - h * h))
        let outerArcLength = outerRadius * CGFloat(outerSpan * .pi / 180)
        let innerArcLength = innerRadius * CGFloat(innerSpan * .pi / 180)

        // 外圈弧长富裕、内圈弧长紧张，所以两端各自收紧，别让内侧圆角把短弧吃光。
        let outerTrim = clampedTrim(cornerTrim, edgeLengths: [outerArcLength, sideLength])
        let innerTrim = clampedTrim(cornerTrim, edgeLengths: [innerArcLength, sideLength])
        // 一条侧边两端各切一次，两个切点不能越过对方。
        let sideBudget = max(0, sideLength * 0.9)
        let scale = (outerTrim + innerTrim) > sideBudget && (outerTrim + innerTrim) > 0
            ? sideBudget / (outerTrim + innerTrim)
            : 1
        let outerTrimFinal = outerTrim * scale
        let innerTrimFinal = innerTrim * scale

        let outerTrimDegrees = Double(outerTrimFinal / outerRadius) * 180 / .pi
        let innerTrimDegrees = Double(innerTrimFinal / innerRadius) * 180 / .pi

        // 侧边单位方向向量（外 → 内）。
        let startDir = unit(from: cornerOuterStart, to: cornerInnerStart)
        let endDir = unit(from: cornerOuterEnd, to: cornerInnerEnd)

        let arcOuterStart = point(radius: outerRadius, degrees: a1 + outerTrimDegrees)
        let arcOuterEnd = point(radius: outerRadius, degrees: a2 - outerTrimDegrees)
        let arcInnerEnd = point(radius: innerRadius, degrees: b2 - innerTrimDegrees)
        let arcInnerStart = point(radius: innerRadius, degrees: b1 + innerTrimDegrees)

        let endSideTop = offset(cornerOuterEnd, by: endDir, distance: outerTrimFinal)
        let endSideBottom = offset(cornerInnerEnd, by: endDir, distance: -innerTrimFinal)
        let startSideBottom = offset(cornerInnerStart, by: startDir, distance: -innerTrimFinal)
        let startSideTop = offset(cornerOuterStart, by: startDir, distance: outerTrimFinal)

        let elements: [RadialPetalPathElement] = [
            .move(arcOuterStart),
            .arc(radius: outerRadius,
                 startRadians: radians(a1 + outerTrimDegrees),
                 endRadians: radians(a2 - outerTrimDegrees),
                 clockwise: false),
            .quad(to: endSideTop, control: cornerOuterEnd),
            .line(endSideBottom),
            .quad(to: arcInnerEnd, control: cornerInnerEnd),
            .arc(radius: innerRadius,
                 startRadians: radians(b2 - innerTrimDegrees),
                 endRadians: radians(b1 + innerTrimDegrees),
                 clockwise: true),
            .quad(to: startSideBottom, control: cornerInnerStart),
            .line(startSideTop),
            .quad(to: arcOuterStart, control: cornerOuterStart),
            .close
        ]

        return RadialPetal(elements: elements,
                           sideInset: h,
                           outerCornerTrim: outerTrimFinal,
                           innerCornerTrim: innerTrimFinal,
                           innerRadius: innerRadius,
                           outerRadius: outerRadius,
                           startDegrees: startDegrees,
                           endDegrees: endDegrees,
                           corners: [cornerOuterStart, cornerOuterEnd, cornerInnerEnd, cornerInnerStart])
    }

    // MARK: - 小工具

    static func radians(_ degrees: Double) -> CGFloat { CGFloat(degrees * .pi / 180) }

    static func point(radius: CGFloat, degrees: Double) -> CGPoint {
        let rad = radians(degrees)
        return CGPoint(x: radius * cos(rad), y: radius * sin(rad))
    }

    static func unit(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 0 else { return CGPoint(x: 0, y: 0) }
        return CGPoint(x: dx / len, y: dy / len)
    }

    static func offset(_ p: CGPoint, by dir: CGPoint, distance: CGFloat) -> CGPoint {
        CGPoint(x: p.x + dir.x * distance, y: p.y + dir.y * distance)
    }

    /// 点到「过圆心、方向为 `degrees`」的射线所在直线的垂直距离。测试用来验证通道宽度。
    public static func perpendicularDistance(_ p: CGPoint, toRayAtDegrees degrees: Double) -> CGFloat {
        let rad = radians(degrees)
        return abs(p.x * sin(rad) - p.y * cos(rad))
    }
}
