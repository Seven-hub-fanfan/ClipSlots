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
// v2.10.74 token/兜底机制，不纳入 interactive/status/transition 这三档通用语义。
// v2.10.87 把那个散落的 0.16s 收敛成下面的 `Anim.groupSwitch`：**数值与曲线一字未改**，仅从
// GroupSwitchVeil.swift 的魔法数变成一个具名常量，便于一眼看出「切组自成一档节奏」。
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

    /// 切组 / 切页过渡遮罩专用档（v2.10.87 收敛自 GroupSwitchVeil.swift 里的裸 0.16s）。
    ///
    /// ⚠️ 这一档**刻意独立于上面三档**，且不要随意调大：
    /// 切组是「旧内容保留并淡化 → 后台异步读盘 → 新内容整体淡入替换」的时序敏感路径
    /// （v2.10.47 建立、v2.10.74 加延迟 token 与 1.2s 兜底、v2.10.86 又修过一次通知合并把
    /// 唯一一次 send 吞掉的回归）。0.16s 比 status(0.2s) 更短是有意的——遮罩本身只该是
    /// 「一闪而过的加载感」，而不是一段要等它走完的动画；拉长会直接让切组显得变慢。
    static let groupSwitch: Animation = .easeInOut(duration: 0.16)
}
