import Foundation
import CoreGraphics

/// 连线的几何运算（v2.12.0）。
///
/// 与 `CanvasGeometry` 同一条规矩：**纯函数下沉到 Kit，SwiftUI 侧只翻译不计算**。理由是既往教训 ——
/// v2.11.0 轮盘把极坐标数学写在 View 里，扇区角偏差 25°~30° 却无法被任何测试发现，最后靠离屏截图
/// 对照才定位（见 `RadialSegmentLayout`）。贝塞尔的命中判定更隐蔽：偏一点只表现为"这条线点不中"，
/// 用户不会报，只会觉得画布不听话。
///
/// 全部工作在**屏幕坐标系**（`screen = canvas * zoom + pan`）：连线的粗细、箭头大小、命中容差都是
/// 操作尺度而非内容尺度，不该随缩放变化。
public enum CanvasEdgeGeometry {

    // MARK: - 端点

    /// 连线贴在卡片的哪条边上。
    public enum Side: Equatable {
        case top, bottom, left, right

        /// 该边朝外的单位法向量。控制点就是沿它推出去的。
        public var outwardNormal: CGPoint {
            switch self {
            case .top: return CGPoint(x: 0, y: -1)
            case .bottom: return CGPoint(x: 0, y: 1)
            case .left: return CGPoint(x: -1, y: 0)
            case .right: return CGPoint(x: 1, y: 0)
            }
        }
    }

    /// 某条边的中点。
    public static func anchor(of rect: CGRect, side: Side) -> CGPoint {
        switch side {
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        }
    }

    /// 拖线用的**出口把手**位置：固定在右边中点。
    ///
    /// 与 `anchor(of:side:)` 算出来的渲染端点刻意分开：把手是"从哪儿开始拖"的固定约定（固定位置
    /// 才形成肌肉记忆），渲染端点则要顺着两个节点的实际相对位置走才好看。
    public static func outputHandle(of rect: CGRect) -> CGPoint {
        anchor(of: rect, side: .right)
    }

    /// 入口把手位置：左边中点。
    public static func inputHandle(of rect: CGRect) -> CGPoint {
        anchor(of: rect, side: .left)
    }

    /// 两个卡片之间该从哪条边出、进哪条边。
    ///
    /// 以水平（右→左）为**默认**，只有当两者明显是上下关系时才改走竖直。阈值取 1.6 倍而不是 1.0：
    /// 画布上"下游节点"由 `CanvasSpawnGeometry` 放在正下方偏右，dx/dy 接近时用 1.0 会让这一批线
    /// 在水平与竖直之间反复横跳（拖动时每帧都可能翻一次），而线型突变比线型不最优难受得多。
    public static func sides(from: CGRect, to: CGRect) -> (out: Side, in: Side) {
        let dx = to.midX - from.midX
        let dy = to.midY - from.midY
        if abs(dy) > 1.6 * abs(dx) {
            return dy >= 0 ? (.bottom, .top) : (.top, .bottom)
        }
        return dx >= 0 ? (.right, .left) : (.left, .right)
    }

    // MARK: - 曲线

    /// 三次贝塞尔的两个控制点。
    ///
    /// 控制点沿各自边的外法向推出去，推多远 = 端点距离的 45%，夹在 [40, 180]。
    ///   - 不夹下限：两个节点贴在一起时曲线退化成直线折角，看不出方向；
    ///   - 不夹上限：跨半个画布的连线会甩出两个大弧线，压在中间所有卡片上。
    public static func controlPoints(start: CGPoint,
                                     end: CGPoint,
                                     outSide: Side,
                                     inSide: Side) -> (CGPoint, CGPoint) {
        let dist = hypot(end.x - start.x, end.y - start.y)
        let k = min(max(dist * 0.45, 40), 180)
        let n1 = outSide.outwardNormal
        let n2 = inSide.outwardNormal
        return (CGPoint(x: start.x + n1.x * k, y: start.y + n1.y * k),
                CGPoint(x: end.x + n2.x * k, y: end.y + n2.y * k))
    }

    /// 曲线上 `t ∈ [0,1]` 处的点。
    public static func point(start: CGPoint,
                             c1: CGPoint,
                             c2: CGPoint,
                             end: CGPoint,
                             t: CGFloat) -> CGPoint {
        let u = 1 - t
        let w0 = u * u * u
        let w1 = 3 * u * u * t
        let w2 = 3 * u * t * t
        let w3 = t * t * t
        return CGPoint(x: w0 * start.x + w1 * c1.x + w2 * c2.x + w3 * end.x,
                       y: w0 * start.y + w1 * c1.y + w2 * c2.y + w3 * end.y)
    }

    /// 曲线上 `t` 处的切线方向（未归一化）。
    public static func tangent(start: CGPoint,
                               c1: CGPoint,
                               c2: CGPoint,
                               end: CGPoint,
                               t: CGFloat) -> CGPoint {
        let u = 1 - t
        let w0 = 3 * u * u
        let w1 = 6 * u * t
        let w2 = 3 * t * t
        return CGPoint(x: w0 * (c1.x - start.x) + w1 * (c2.x - c1.x) + w2 * (end.x - c2.x),
                       y: w0 * (c1.y - start.y) + w1 * (c2.y - c1.y) + w2 * (end.y - c2.y))
    }

    // MARK: - 箭头

    /// 箭头三角形的三个点。
    ///
    /// 尖端刻意放在 `t = 0.99` 而不是 1.0：端点正好压在卡片边线上，箭头尖端落在那里会被卡片的
    /// 描边吃掉一半。同时方向取该处的切线，这样箭头永远沿着曲线来的方向指，而不是指向端点连线。
    public static func arrowHead(start: CGPoint,
                                 c1: CGPoint,
                                 c2: CGPoint,
                                 end: CGPoint,
                                 size: CGFloat = 9) -> (tip: CGPoint, left: CGPoint, right: CGPoint) {
        let t: CGFloat = 0.99
        let tip = point(start: start, c1: c1, c2: c2, end: end, t: t)
        var dir = tangent(start: start, c1: c1, c2: c2, end: end, t: t)
        let len = hypot(dir.x, dir.y)
        // 退化保护：四点重合时切线长度为 0，归一化会得到 NaN，一路传到 Path 里会让整层不渲染
        // （SwiftUI 对 NaN 几何的表现是静默空白，极难定位）。
        if len < 0.0001 { dir = CGPoint(x: 1, y: 0) } else { dir = CGPoint(x: dir.x / len, y: dir.y / len) }
        let normal = CGPoint(x: -dir.y, y: dir.x)
        let back = CGPoint(x: tip.x - dir.x * size, y: tip.y - dir.y * size)
        let half = size * 0.52
        return (tip,
                CGPoint(x: back.x + normal.x * half, y: back.y + normal.y * half),
                CGPoint(x: back.x - normal.x * half, y: back.y - normal.y * half))
    }

    /// 角标（角色标签）挂在哪：曲线中点。
    public static func badgeAnchor(start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint) -> CGPoint {
        point(start: start, c1: c1, c2: c2, end: end, t: 0.5)
    }

    // MARK: - 命中

    /// 点到曲线的最短距离（按 `samples` 段折线近似）。
    ///
    /// 采样数默认 24：连线最长也就几百像素，24 段的弦长误差远小于命中容差；调到几百段只是白烧
    /// 每次鼠标移动的 CPU（命中判定在 hover 通路上，每帧都可能跑）。
    public static func distance(from point: CGPoint,
                               start: CGPoint,
                               c1: CGPoint,
                               c2: CGPoint,
                               end: CGPoint,
                               samples: Int = 24) -> CGFloat {
        let n = max(samples, 2)
        var best = CGFloat.greatestFiniteMagnitude
        var previous = start
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let current = self.point(start: start, c1: c1, c2: c2, end: end, t: t)
            best = min(best, distanceToSegment(point, previous, current))
            previous = current
        }
        return best
    }

    /// 点是否落在连线的可点击带内。容差 10pt —— 1.6pt 的线要求像素级精准会让"选中一条线"变成
    /// 运气活；10pt 约等于一根手指在触控板上的可控精度。
    public static func hitTest(point p: CGPoint,
                              start: CGPoint,
                              c1: CGPoint,
                              c2: CGPoint,
                              end: CGPoint,
                              tolerance: CGFloat = 10) -> Bool {
        distance(from: p, start: start, c1: c1, c2: c2, end: end) <= tolerance
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = min(max(t, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
