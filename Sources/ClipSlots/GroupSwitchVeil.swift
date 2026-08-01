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
            // 从左侧外一直扫到右侧外，循环往复。
            .offset(x: animating ? (w + bandWidth) : -bandWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                animating = false
                withAnimation(.linear(duration: 0.95).repeatForever(autoreverses: false)) {
                    animating = true
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
