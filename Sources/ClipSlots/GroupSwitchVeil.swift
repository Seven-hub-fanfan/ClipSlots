import SwiftUI

/// v2.10.47: 切组/切页过渡遮罩。
///
/// 背景：v2.10.42 附件字节外置后，切组时逐槽读盘（含跨进程 flock）挪到了后台队列异步回填，
/// 而切组瞬间旧实现会先把 `slots` 清空成 `[:]`，导致所有槽位在新数据回填前先闪成「空槽位」占位，
/// 顶部已使用数量/附件角标却是对的——只有主体内容预览区有这个闪白中间态，观感很差。
///
/// v2.10.47 改为「切组时保留旧组内容不清空 + 叠一层轻微骨架/淡化遮罩表示切换中」，新数据在后台
/// 就绪后整体淡入替换（见 SlotStoreObservable.loadSlotsAsync）。本视图即那层遮罩：一道循环扫过的
/// 柔和高光（shimmer sweep），叠在已被淡化/轻模糊的旧内容之上，读起来就是「正在加载 / 切换中」。
/// 不预加载、不额外占内存，仅在 `isSwitchingGroup == true` 的极短窗口内存在。
struct GroupSwitchVeil: View {
    @State private var animating = false

    // v2.10.87（动画打磨）: 扫光的两个观感参数。
    //
    // 原实现：0.95s 走完一趟，且起点是 `-bandWidth`（整条光带完全在左侧画面外）。
    // 问题在于这条光带用的是「两端 0 透明度、中心 0.14」的渐变，真正「看得见」要等到光带中心进入
    // 画面——也就是走完约 bandWidth/2、约整趟行程的 1/4，折算 ≈0.22s。而 v2.10.74 之后遮罩只在
    // 「切组确实慢」时才延迟显示，实际存在窗口常常只有两三百毫秒。两者一叠加，结果是这道扫光在绝大
    // 多数真实切组里几乎从没亮起来过：用户看到的只是「内容淡了一下又回来」，没有任何「正在加载」的
    // 交代，切组因此显得是卡了一下而不是在读数据。
    //
    // 修法只动观感、不动任何时序：
    //   • 行程压到 0.72s，峰值亮度提前到 ≈0.17s；
    //   • 起点从 `-bandWidth` 改为 `-bandWidth * 0.5`，光带开局就有半条在画面内，第一帧即可读。
    // 遮罩何时出现/消失仍完全由 isSwitchingGroup + v2.10.74 的延迟 token / 1.2s 兜底决定，与此无关。
    private static let sweepDuration: Double = 0.72
    private static let sweepStartRatio: CGFloat = -0.5

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let bandWidth = w * 0.45

            LinearGradient(
                gradient: Gradient(colors: [
                    Color.white.opacity(0.0),
                    Color.white.opacity(0.14),
                    Color.white.opacity(0.0)
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: bandWidth)
            .frame(maxHeight: .infinity)
            // 从左侧（半露）一直扫到右侧外，循环往复。
            .offset(x: animating ? (w + bandWidth) : bandWidth * Self.sweepStartRatio)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                animating = false
                withAnimation(.linear(duration: Self.sweepDuration).repeatForever(autoreverses: false)) {
                    animating = true
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - v2.10.76 (Phase 1 交互状态下沉) 切组过渡的局部观察子视图
//
// 背景：切组遮罩的两处视觉——① LazyVGrid 的淡化 + 禁点击 + 淡入动画；② 叠在网格上的 shimmer 微光
// 遮罩——原先直接读 `store.isSwitchingGroup`。该状态挂在巨型主 store 上，其置位/复位会让以
// `@ObservedObject store` 观察它的整棵 ContentView.body 重新求值（含 10 张卡片的 LazyVGrid ForEach）。
// v2.10.76 起 isSwitchingGroup 存储迁到 TransientUIStore；下面两个只观察 TransientUIStore 的小视图
// 承接这两处视觉，切组状态变更只重绘它们、不再波及整棵 ContentView.body。
// 注意：视觉表现（0.35 透明度、切换期禁点击、0.16s easeInOut 淡入、shimmer 微光）与迁移前完全一致；
// v2.10.74 的延迟 token / 1.2s 兜底逻辑仍在主 store，未受影响。

/// 应用到 LazyVGrid 上的「切组淡化」修饰器：只观察 TransientUIStore.isSwitchingGroup。
struct GroupSwitchDimModifier: ViewModifier {
    @ObservedObject var ui: TransientUIStore

    func body(content: Content) -> some View {
        content
            .opacity(ui.isSwitchingGroup ? 0.35 : 1)
            .allowsHitTesting(!ui.isSwitchingGroup)
            // v2.10.87: 曲线与时长与此前完全一致，仅把裸 0.16s 换成具名 token（见 AnimationTokens.swift）。
            .animation(Anim.groupSwitch, value: ui.isSwitchingGroup)
    }
}

/// 叠在网格上的切组 shimmer 微光遮罩：只观察 TransientUIStore.isSwitchingGroup。
struct GroupSwitchVeilOverlay: View {
    @ObservedObject var ui: TransientUIStore

    var body: some View {
        if ui.isSwitchingGroup {
            GroupSwitchVeil()
                .transition(.opacity)
        }
    }
}
