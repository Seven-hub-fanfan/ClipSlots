import SwiftUI

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

/// 顶部标题栏的金属拨杆簇：自动存储 / 自动粘贴两个 ToggleLeverView + 其下「回退 / 重置」游标按钮。
/// 局部观察 autoMode，拨杆翻动仅重绘本簇；开关变动后异步触发预览角标重算（store.recomputeAutoPreviews）。
struct LeverClusterView: View {
    let store: SlotStoreObservable
    @ObservedObject var autoMode: AutoModeState

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Divider().frame(height: 26)

            leverWithCursorControls(
                lever: ToggleLeverView(isOn: $autoMode.autoStoreEnabled, label: "自动存储",
                                       help: "开启后按 Opt+1 会把剪贴板写入下一个空槽",
                                       indicatorColor: .green),
                enabled: autoMode.autoStoreEnabled,
                tint: .green,
                onBack: { store.autoStoreCursorGoBack() },
                onReset: { store.autoStoreCursorReset() },
                backHelp: "回退写游标：撤销最近一次自动存储的推进（回到上一个槽位）",
                resetHelp: "重置写游标：下次 Opt+1 从第一个空槽重新开始"
            )

            leverWithCursorControls(
                lever: ToggleLeverView(isOn: $autoMode.autoPasteEnabled, label: "自动粘贴",
                                       help: "开启后按 Cmd+1 会从读游标取下一个非空槽粘贴",
                                       indicatorColor: .blue),
                enabled: autoMode.autoPasteEnabled,
                tint: .blue,
                onBack: { store.autoPasteCursorGoBack() },
                onReset: { store.autoPasteCursorReset() },
                backHelp: "回退读游标：可连续点击，逐个非空槽往回退，直到回到开头",
                resetHelp: "重置读游标：下次 Cmd+1 从当前组第一个非空槽重新开始"
            )

            Divider().frame(height: 26)
        }
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

    // v2.10.1: 拨杆 + 下方一对「回退 / 重置」游标控制按钮（拨杆关时置灰不可点）。
    private func leverWithCursorControls(
        lever: ToggleLeverView,
        enabled: Bool,
        tint: Color,
        onBack: @escaping () -> Void,
        onReset: @escaping () -> Void,
        backHelp: String,
        resetHelp: String
    ) -> some View {
        VStack(spacing: 3) {
            lever
            HStack(spacing: 5) {
                cursorControlButton(system: "arrow.uturn.backward", tint: tint, enabled: enabled, help: backHelp, action: onBack)
                cursorControlButton(system: "backward.end", tint: tint, enabled: enabled, help: resetHelp, action: onReset)
            }
        }
    }

    private func cursorControlButton(system: String, tint: Color, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(enabled ? tint : Color.secondary.opacity(0.4))
                .frame(width: 18, height: 15)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(enabled ? tint.opacity(0.14) : Color.primary.opacity(0.04))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

/// actionBar 里的「自动切换」胶囊按钮。局部观察 autoMode.autoAdvanceEnabled，翻动仅重绘本按钮。
struct AutoAdvanceToggleView: View {
    @ObservedObject var autoMode: AutoModeState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            autoMode.autoAdvanceEnabled.toggle()
        } label: {
            HStack(spacing: AppTheme.spacingTight) {
                Image(systemName: autoMode.autoAdvanceEnabled ? "arrow.forward.circle.fill" : "arrow.forward.circle")
                    .font(.system(size: 10, weight: .semibold))
                Text("自动切换")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(autoMode.autoAdvanceEnabled
                ? Color.accentColor.opacity(0.18)
                : AppTheme.filterChipBackground(colorScheme)))
            .overlay(Capsule().stroke(autoMode.autoAdvanceEnabled
                ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1))
            .foregroundColor(autoMode.autoAdvanceEnabled
                ? Color.accentColor : AppTheme.filterChipText(colorScheme))
            .animation(Anim.status, value: autoMode.autoAdvanceEnabled)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("开启后：自动存储/粘贴可跨组、跨页推进；关闭则只在当前组内循环")
    }
}
