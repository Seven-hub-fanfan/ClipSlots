import SwiftUI
import ClipSlotsKit

// MARK: - v2.10.79 (改动A 观察下沉): 拨杆簇 / 自动切换按钮独立子视图
//
// 背景：此前 ContentView 顶部持有 `@ObservedObject var autoMode = AutoModeState.shared`，
// 任何一次拨杆开关（autoStore/autoPaste/autoAdvance）翻动都会触发 autoMode.objectWillChange，
// 进而让整棵 2400+ 行的 ContentView.body 重新求值 / diff，是「拨动金属摇杆卡顿」的最重根因。
//
// 做法：把仅有的两处「响应式读取 autoMode」的 UI —— 顶部摇杆簇（两个 ToggleLeverView + 其下
// 回退/重置迷你按钮）与 actionBar 里的「自动切换」胶囊按钮 —— 各抽成独立子视图，由它们各自
// `@ObservedObject var autoMode` 局部观察。ContentView 改为持有非观察的 `let autoMode` 引用，
// 仅把该引用透传给这些子视图（以及既有的 CursorBadgesView / CrossGroupCursorHintView）。
// 拨杆翻动只重绘这两个小簇，不再波及整棵 ContentView。开关的实际功能（绑定、落盘、角标重算）
// 与迁移前逐像素、逐语义一致。
//
// 判断依据：grep 全量确认 ContentView 内对 autoMode 的响应式读取只出现在 leverCluster 与
// autoAdvanceToggle；其余两处（1505/1519）只是把 autoMode 引用透传给已各自 @ObservedObject 的
// 子视图、无需 ContentView 自身刷新。故可安全地把这两簇整体下沉、并撤掉 ContentView 的整体订阅。

/// 顶部标题栏的自动存储 / 自动粘贴开关面板（v2.11.8 按新拟物设计稿重做）。
///
/// 结构照着设计稿：一块白色浮动面板，内部左右两区（细线分隔），每区 = 状态点 + 名称 +
/// 垂直滑块开关 + 下方「回退 / 重置」两颗小凸起按钮。
///
/// 替换掉的是 v2.10.0 的金属拨杆（ToggleLeverView）。语义一模一样——点击切换、两档、上开下关、
/// 关时游标按钮置灰——换的只是材质：拟真金属的镜面高光在哑光新拟物面板上是唯一的异类。
///
/// 保留 v2.10.79 的性能结构：局部 @ObservedObject 观察 autoMode，开关翻动只重绘本簇，
/// 不牵连整棵 ContentView.body。
struct LeverClusterView: View {
    let store: SlotStoreObservable
    @ObservedObject var autoMode: AutoModeState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            switchColumn(
                isOn: $autoMode.autoStoreEnabled,
                label: "自动存储",
                statusColor: .green,
                help: "开启后按 Opt+1 会把剪贴板写入下一个空槽",
                onBack: { store.autoStoreCursorGoBack() },
                onReset: { store.autoStoreCursorReset() },
                backHelp: "回退写游标：撤销最近一次自动存储的推进（回到上一个槽位）",
                resetHelp: "重置写游标：下次 Opt+1 从第一个空槽重新开始"
            )

            // 两区之间的细线分隔（设计稿里就一条发丝线，不是 Divider 的实线）。
            Rectangle()
                .fill(Neu.hairlineStrong)
                .frame(width: 1, height: 74)

            switchColumn(
                isOn: $autoMode.autoPasteEnabled,
                label: "自动粘贴",
                statusColor: .blue,
                help: "开启后按 Cmd+1 会从读游标取下一个非空槽粘贴",
                onBack: { store.autoPasteCursorGoBack() },
                onReset: { store.autoPasteCursorReset() },
                backHelp: "回退读游标：可连续点击，逐个非空槽往回退，直到回到开头",
                resetHelp: "重置读游标：下次 Cmd+1 从当前组第一个非空槽重新开始"
            )
        }
        // v2.11.7 hotfix4: 去掉这一簇自己的浮动面板底（原 `.neuPanel(radius: 14)`）。
        // 它和工具栏面板一起构成了「小卡片浮在大面板上」的两层嵌套，是割裂感最重的地方。
        // 现在两区直接坐在工具栏所在的画布上，分组关系只靠中间那条发丝线 + 各自的标题表达；
        // 凹凸质感仍在（滑道内凹、滑块与游标按钮微凸），只是不再有「一块板」。
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .fixedSize()
        .onChange(of: autoMode.autoStoreEnabled) { _ in
            DispatchQueue.main.async { store.recomputeAutoPreviews() }
        }
        .onChange(of: autoMode.autoPasteEnabled) { _ in
            DispatchQueue.main.async { store.recomputeAutoPreviews() }
        }
        .onChange(of: autoMode.autoAdvanceEnabled) { _ in
            DispatchQueue.main.async { store.recomputeAutoPreviews() }
        }
    }

    /// 面板内的一区：开关 + 其下一对游标按钮（开关关闭时按钮置灰不可点）。
    private func switchColumn(
        isOn: Binding<Bool>,
        label: String,
        statusColor: Color,
        help: String,
        onBack: @escaping () -> Void,
        onReset: @escaping () -> Void,
        backHelp: String,
        resetHelp: String
    ) -> some View {
        VStack(spacing: 6) {
            NeuVerticalSwitch(isOn: isOn, statusColor: statusColor, label: label, help: help)

            HStack(spacing: 5) {
                NeuMiniButton(title: "回退", icon: "arrow.uturn.backward",
                              tint: isOn.wrappedValue ? statusColor : nil,
                              enabled: isOn.wrappedValue, action: onBack)
                    .help(backHelp)
                NeuMiniButton(title: "重置", icon: "backward.end",
                              tint: isOn.wrappedValue ? statusColor : nil,
                              enabled: isOn.wrappedValue, action: onReset)
                    .help(resetHelp)
            }
        }
    }
}

/// actionBar 里的「自动切换」按钮（v2.11.8 新拟物版）。
/// 选中态 = 黑色凸起块 + 白字（多彩模式换成品牌渐变），静息态 = 普通凸起块。
/// 局部观察 autoMode.autoAdvanceEnabled，翻动仅重绘本按钮。
struct AutoAdvanceToggleView: View {
    @ObservedObject var autoMode: AutoModeState
    @State private var isHovering = false

    var body: some View {
        let isOn = autoMode.autoAdvanceEnabled
        Button {
            autoMode.autoAdvanceEnabled.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "arrow.forward.circle.fill" : "arrow.forward.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text("自动切换")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(isOn ? Neu.sliderInk : Neu.ink)
            .padding(.horizontal, 10)
            .frame(height: NeumorphicMetrics.actionHeight)
            .contentShape(RoundedRectangle(cornerRadius: NeumorphicMetrics.actionRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .neuRaised(radius: NeumorphicMetrics.actionRadius,
                   hovering: isHovering,
                   fill: isOn ? Neu.selectedFill : nil)
        .animation(Anim.status, value: isOn)
        .onHover { isHovering = $0 }
        .fixedSize()
        .help("开启后：自动存储/粘贴可跨组、跨页推进；关闭则只在当前组内循环")
    }
}
