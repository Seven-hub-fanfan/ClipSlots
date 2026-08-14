import SwiftUI

// MARK: - v2.10.76 (Phase 3 · 动画体系统一)
//
// 全仓此前散落着大量「就地手写」的动画曲线 / 时长（.easeInOut(0.2)、.easeOut(0.18)、
// .spring(response:0.3,...)、.smooth(0.26) 等），量值与语义各不统一，导致同类交互在不同控件上
// 快慢/回弹手感不一致，观感碎片化。这里收敛为三档语义 token，全仓按「就近语义」归类替换：
//
//   • interactive —— 指针级即时反馈（hover、按压、开关拨动、即时高亮）。要求“跟手、干脆”，
//     用短 easeOut，避免拖泥带水。
//   • status ——     状态/信息层的淡入淡出（Toast、浮层、角标、切换态提示等）。中性 easeInOut，
//     不抢注意力。
//   • transition —— 元素进出场 / 位置变化等“有存在感”的过渡。带轻微回弹的 spring，柔和自然。
//
// 说明：切组遮罩（GroupSwitchDimModifier / loadSlotsAsync 淡入）沿用其既有 0.16s 曲线与
// v2.10.74 token/兜底机制，不纳入本 token 体系，避免触碰那条对时序敏感的路径。
enum Anim {
    /// 指针级即时反馈：hover / 按压 / 开关 / 即时高亮。跟手、干脆。
    static let interactive: Animation = .easeOut(duration: 0.12)

    /// 状态 / 信息淡入淡出：Toast / 浮层 / 角标 / 提示。中性、不抢眼。
    static let status: Animation = .easeInOut(duration: 0.2)

    /// 元素进出场 / 位置变化过渡：带轻微回弹，柔和自然。
    ///
    /// PERF-5 (v2.10.84): response 从 0.35 收紧到 0.28。0.35s + dampingFraction 0.82 的组合会拖出
    /// 一条较长的收敛尾巴，在这种「高频连续操作」的工具型 App 里，即使帧率满格也会被感知成
    /// 「软件反应慢」——因为下一次操作要等上一段过渡走完才显得干净。0.28s 仍保留回弹质感，
    /// 但把等待感明显压短。纯观感参数，不改变任何状态语义。
    static let transition: Animation = .spring(response: 0.28, dampingFraction: 0.82)
}
