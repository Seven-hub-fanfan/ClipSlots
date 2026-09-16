import Foundation
import CoreGraphics

/// 画布「排版缩放」的量化阶梯（v2.11.8 三轮 hotfix2）。
///
/// ## 要解决的现象
///
/// 用户第二次录屏（20260916102744）里，Cmd+滚轮缩放时节点正文在**不停重新折行**：
/// 「快速推进」/「快速推进(」两种断行来回跳，文本块底边跟着上下抽动，下面的「入参文件 6」
/// 整行也被顶得一跳一跳。图片是平滑的，只有文字在跳 —— 这是**重排**（reflow）而不是缩放。
///
/// ## 为什么二轮的 `layoutZoom` 没修掉
///
/// 二轮已经把「排版用 zoom」与「视觉用 zoom」拆开了（节点内部按 `layoutZoom` 排版，差值由
/// `scaleEffect(zoom / layoutZoom)` 补），但**落定策略是「停手 0.15s 后把 layoutZoom 钉到当前 zoom」**。
/// 而 Cmd+滚轮的一格 ≈ 8%，鼠标滚轮（非触控板）产生的是**离散且稀疏**的事件：两格之间常常超过
/// 0.15s，于是「缩放中」在系统看来就是一连串「已停手」——每一格都落定一次、每一格都重排一次文字。
/// 触控板连续滚也只是把重排推迟到最后，一旦用户分几次滚，抖动照旧。
///
/// ## 这里的修法：把排版缩放量化到阶梯 + 迟滞
///
///   1. **阶梯**：排版只允许取 `ladder` 里的值（公比 2^(1/3) ≈ 1.26 的几何序列）。一格 8% 的滚轮
///      动作几乎永远落在同一档里 → 一次都不重排。
///   2. **迟滞**：只有当 `zoom / 当前档` 偏离超过 `hysteresis`（18%）才换档。少了这一条，
///      zoom 停在档位边界附近（用户来回微调）会让排版在两档之间反复跳，比原来更糟。
///
/// ## 代价与取舍（必须写清楚，否则后人会"优化"掉）
///
/// 换档之间，视觉缩放与排版缩放存在最多 ~18% 的差（由 `scaleEffect` 补），文字因此会有**轻微**
/// 软化 —— 而这正是二轮不敢量化、直接钉死到实时 zoom 的原因。实测取舍很清楚：
///   - 12%~18% 的位图放大：静止画面下几乎看不出，且缩放停下后依然是矢量清晰的那一档在渲染；
///   - 每格一次重排：**运动中的文字跳动**，人眼对此极度敏感（用户两轮反馈都在抱怨这件事）。
/// 所以选择「宁可轻微软化，绝不重排」。若哪天要恢复"绝对清晰"，正确做法是缩小公比（阶梯更密）
/// 而不是取消量化 —— 但公比越小越容易被一格滚轮跨过去，重排又会回来。
public enum CanvasZoomLayout {

    /// 允许的排版缩放档位。公比 2^(1/3) ≈ 1.26，覆盖 `CanvasGeometry` 的 zoom 区间（0.25~4）。
    ///
    /// 含 1.0 是刻意的：绝大多数时间画布停在 100%，此时排版与视觉完全一致（零软化）。
    public static let ladder: [CGFloat] = [
        0.25, 0.315, 0.4, 0.5, 0.63, 0.79,
        1.0,
        1.26, 1.59, 2.0, 2.52, 3.17, 4.0
    ]

    /// 换档迟滞：`zoom / 当前档` 落在 `[1/hysteresis, hysteresis]` 内就不换档。
    ///
    /// 取 1.18 而不是恰好半档（√1.26 ≈ 1.12）：留一点余量，避免「刚跨过半档就换、换完又被下一格滚回来」
    /// 这种边界震荡 —— 震荡一次等于重排一次，正是本文件要消灭的东西。
    public static let hysteresis: CGFloat = 1.18

    /// 取离 `zoom` 最近的档位（在**对数尺度**上取最近）。
    ///
    /// 必须用对数距离：线性距离下 0.9 到 1.0 的差（0.1）比 3.0 到 3.17 的差（0.17）小，
    /// 但人眼感知的缩放差是**比例**而不是绝对值，线性取最近会让低档过密、高档过疏。
    public static func bucket(for zoom: CGFloat) -> CGFloat {
        let z = max(0.01, zoom)
        var best = ladder[0]
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for step in ladder {
            let d = abs(log(z / step))
            if d < bestDistance {
                bestDistance = d
                best = step
            }
        }
        return best
    }

    /// 给定「当前排版档」与「最新视觉 zoom」，返回**应该使用的排版档**。
    ///
    /// 返回值等于 `current` 表示**不需要重排**（调用方据此直接跳过 state 写入，连一次 body 求值都不发生）。
    public static func settled(current: CGFloat, zoom: CGFloat) -> CGFloat {
        guard current > 0.01 else { return bucket(for: zoom) }
        let ratio = max(0.01, zoom) / current
        if ratio <= hysteresis && ratio >= 1 / hysteresis { return current }
        return bucket(for: zoom)
    }

    /// 连续手势（触控板捏合 / 滚轮）停手后多久才允许换档。
    ///
    /// 0.15s → 0.32s：鼠标滚轮的相邻两格间隔常在 0.15~0.3s，旧值让"一次连续缩放"被切成许多段。
    /// 有了阶梯量化后，这个延时其实只是二道保险（同档内根本不会重排），但保留它可以让"跨档的那一次
    /// 重排"发生在用户手停之后，而不是滚动中途。
    public static let settleDelay: TimeInterval = 0.32
}
