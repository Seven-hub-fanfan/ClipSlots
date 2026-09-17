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

    // MARK: - 八轮：给「屏幕固定字号」用的向下取档 + 反向补偿

    /// 换档余量（向下取档时允许档位比 zoom 高出的比例），同时充当迟滞带宽。
    ///
    /// ★ 九轮：`1.06` → `1.001`。
    ///
    /// 八轮留 6% 是为了"不要为了 3% 的差把整张卡降一档"，代价是静息态档位可以比 zoom 高 6%，
    /// 于是 `textCounterScale` 需要 > 1 才能补偿 —— 八轮那版不敢放大，就地钳成 1，直接放弃了
    /// 这 6%（外加缩小手势全程失效，见 `textCounterScale`）。
    ///
    /// 九轮改成精确补偿后，这里的取值只影响两件事，都不再影响"字号是否恒定"：
    ///   1. **位图清晰度**：档位离 zoom 越远，节点层的残差放大越多；
    ///   2. **静息态 counter 是否 ≤ 1**：留 0.1% 的头就够挡住浮点误差
    ///      （`zoom = 0.9999999` 不至于整档掉到 0.79），同时保证静息态基本不需要放大补偿，
    ///      文字永远不会探出版面盒子。
    ///
    /// 顺带一个原本担心、现在不成立的问题：余量收紧后下边界的迟滞几乎没有了，跨档更频繁。
    /// 但**跨档不再引起文字重排**（字号已固定成设计 pt），而几何的屏幕尺寸
    /// = 设计值 × layoutZoom × (zoom / layoutZoom) = 设计值 × zoom 是**连续**的，
    /// 换档只换光栅化精度，用户看不见。
    public static let floorTolerance: CGFloat = 1.001

    /// **向下**取档：返回不超过 `zoom * floorTolerance` 的最大档位。
    ///
    /// ## 为什么八轮要从「最近档」改成「向下取档」
    ///
    /// 八轮要求"文字在屏幕上的视觉大小恒定"。文字排版字号已经固定成设计 pt（见 `CanvasScreenText`），
    /// 但节点层还挂着 `scaleEffect(zoom / layoutZoom)` —— 这个**残差**会照样把文字连带放大/缩小。
    /// 实测（真机像素量化）：zoom 1.08 档位 1.26（残差 0.86）与 zoom 2.12 档位 2.0（残差 1.06）
    /// 两处，同一行字的屏幕高度差 **1.23×** —— 方向对了但没到"恒定"。
    ///
    /// 要抹掉残差，只能给文字再乘一个 `1/残差` 的反向变换（`textCounterScale`）。向下取档让
    /// **静息态**的残差 ≥ 1，于是反向变换 ≤ 1 —— 文字永远不需要放大，就不会溢出自己的版面盒子
    /// （标题压到角标上、正文漫过圆角）。
    ///
    /// ★ 九轮补充：反向变换本身已经**不再钳制**（缩小手势中途必须允许 > 1，否则文字跟着画布缩，
    /// 见 `textCounterScale`）。向下取档因此从"正确性的前提"降级成"静息态不溢出的保障"。
    ///
    /// 代价：档位与 zoom 的最大差从「最近档」的 ±18% 变成「向下」的 0%~26%，即位图放大的上限
    /// 从 1.18 抬到 1.26（只在两档之间的 zoom 上出现，落在档位上依然是 1.0 逐字号清晰）。
    public static func floorBucket(for zoom: CGFloat) -> CGFloat {
        let limit = max(0.01, zoom) * floorTolerance
        var best = ladder[0]
        for step in ladder where step <= limit { best = step }
        return best
    }

    /// 向下取档版的 `settled`：仍在「当前档 ≤ zoom < 下一档」区间内就不换档（带 6% 下沉余量）。
    ///
    /// 返回值等于 `current` 表示**不需要重排**。下沉余量只加在下边界：上边界一旦被跨过就立刻换档，
    /// 否则残差会超过一整档，位图放大失控。
    public static func settledFloor(current: CGFloat, zoom: CGFloat) -> CGFloat {
        guard current > 0.01 else { return floorBucket(for: zoom) }
        let z = max(0.01, zoom)
        let next = ladder.first(where: { $0 > current }) ?? .greatestFiniteMagnitude
        if z * floorTolerance >= current && z < next { return current }
        return floorBucket(for: zoom)
    }

    /// 文字要额外乘的反向缩放 = **精确的** `layoutZoom / zoom`（★ v2.11.8 九轮，用户第 4 次打回后重写）。
    ///
    /// ## 契约（用户九轮原话）
    ///
    /// 「文字的 `scaleEffect` 必须精确等于 `1.0 / effectiveZoom`，抵消文字实际经历的所有上层缩放；
    /// 不允许使用最小字号限制或非线性缩放。」
    ///
    /// 本项目里文字实际经历的上层缩放只有一处 —— 节点层的 `scaleEffect(zoom / layoutZoom)`
    /// （排版字号已经是设计 pt，见 `CanvasScreenText`）。所以
    /// `effectiveZoom = zoom / layoutZoom`，本函数返回它的倒数，屏幕字号 ≡ 设计 pt。
    ///
    /// ## 八轮的 `min(1, ...)` 为什么会让用户看到"文字还在变"
    ///
    /// 八轮写的是 `min(1, l / z)`，理由是"反向变换只能缩小不能放大，否则文字溢出版面盒子"，
    /// 并且认为残差 < 1 只会发生在向下取档那 6% 的余量里（最多让字小 6%，肉眼不可分辨）。
    ///
    /// **这个前提只在「静息态」成立。** `layoutZoom` 是**落定后**才更新的（`settleDelay` 0.32s），
    /// 缩放手势进行中它被冻结在旧档位上：
    ///
    /// ```text
    ///   用户从 200% 一路捏到 50%（一次手势，全程 < 0.32s）
    ///   layoutZoom 仍冻结在 2.0，zoom 已经到 0.5
    ///   残差 = 0.5 / 2.0 = 0.25          ← 远不止 6%
    ///   counter = min(1, 2.0/0.5) = min(1, 4) = 1   ← 钳制生效，完全不补偿
    ///   屏幕字号 = 设计 pt × 0.25        ← 文字缩成 1/4，和没修一样
    ///   0.32s 后落定，counter 恢复 → 文字"啪"地跳回原大小
    /// ```
    ///
    /// 也就是说：**放大方向（zoom 追上档位）修好了，缩小方向完全没修**，而且落定瞬间还会跳一下。
    /// 用户反馈的"放大缩小时文字仍然在动态变化"精确对应这个行为。
    ///
    /// ## 现在的取舍
    ///
    /// 允许返回 > 1。溢出顾虑靠 `floorTolerance` 收口：静息态档位**永不高于** zoom，
    /// 于是静息态 counter ≤ 1，不存在溢出；counter > 1 只出现在"正在往回缩"的手势中途，
    /// 那恰恰是**必须**放大才能保持屏幕字号恒定的时刻，而且是瞬态。
    /// 宁可手势中途有几帧文字略微探出盒子，也不能让用户看着文字跟着画布一起缩。
    public static func textCounterScale(zoom: CGFloat, layoutZoom: CGFloat) -> CGFloat {
        let z = max(0.01, zoom)
        let l = max(0.01, layoutZoom)
        return l / z
    }

    /// 连续手势（触控板捏合 / 滚轮）停手后多久才允许换档。
    ///
    /// 0.15s → 0.32s：鼠标滚轮的相邻两格间隔常在 0.15~0.3s，旧值让"一次连续缩放"被切成许多段。
    /// 有了阶梯量化后，这个延时其实只是二道保险（同档内根本不会重排），但保留它可以让"跨档的那一次
    /// 重排"发生在用户手停之后，而不是滚动中途。
    public static let settleDelay: TimeInterval = 0.32
}
