import SwiftUI

/// v2.10.52 (perf 第四批 · 巨型 @Published Store 拆分)
///
/// 把高频触发的「瞬态覆盖层」UI 状态（Toast / 浮层提示）从主 `SlotStoreObservable` 里剥离到本
/// 独立的 `ObservableObject`。
///
/// 背景：`toastMessage` / `floatingNotice` 原本是主 store 上的 `@Published`。每次 `showToast` /
/// `showFloatingNotice`（切组、保存、复制、覆盖、批量等几乎所有操作都会触发）都会让
/// `store.objectWillChange` 发射，从而令观察 store 的整棵 `ContentView.body`（标题栏 / 搜索区 /
/// 槽位网格 / 底栏）全部重新求值、所有槽位卡片重建。而 Toast 本身只是顶部一个一闪即逝的胶囊，
/// 与主网格内容毫无关系。
///
/// 拆分后：这两个状态只由独立的 `TransientOverlayView` 通过 `@ObservedObject` 单独观察。Toast /
/// 浮层的弹出与消失只会重绘该覆盖层子视图，不再波及主网格与标题栏的渲染。
///
/// 注意：本对象由 `SlotStoreObservable` 以只读引用 `let transientUI` 持有，生命周期与主 store
/// 一致；`ContentView` 通过 `store.transientUI`（普通引用读取，不建立 @Published 依赖）拿到它，
/// 再单独交给 `TransientOverlayView` 观察。
final class TransientUIStore: ObservableObject {
    /// 顶部短暂 Toast 文案；`nil` 表示不显示。默认约 1.2s 自动消失（见 `showToast`）。
    @Published var toastMessage: String?

    /// 顶部浮层提示（保存 / 覆盖 / 复制结果摘要等）；`nil` 表示不显示。
    @Published var floatingNotice: FloatingNotice?

    // v2.10.76 (架构治本 · Phase 1 交互状态下沉):
    //
    // 把「纯交互 / 瞬态高频」状态从巨型主 `SlotStoreObservable`（30+ @Published）继续下沉到这里。
    // 背景：主 store 的任一 @Published 变更都会令 `objectWillChange` 发射，从而让以
    // `@ObservedObject store` 观察它的整棵 `ContentView.body`（含 10 张槽位卡片的 LazyVGrid）全部
    // 重新求值。而下列状态只影响极小的局部视觉（切组遮罩 / 游标角标 / 连线口 hover），与主网格内容
    // 无关，却因挂在主 store 上而波及全网格重算。迁到本独立 store 后，由专门观察 `TransientUIStore`
    // 的小型子视图（GroupSwitchDimModifier / GroupSwitchVeilOverlay / CursorBadgesView /
    // CrossGroupCursorHintView）单独承接，其高频变更不再触发主 store.objectWillChange。
    //
    // 主 store 侧保留同名「转发计算属性」（见 main.swift），内部逻辑读写不变，仅存储落到这里；
    // 因此 v2.10.74 的延迟遮罩 token 机制、endGroupSwitchTransition、1.2s 兜底关闭全部等价保留
    // （token/定时器仍在主 store，只是 isSwitchingGroup 的最终读写落到本 store 的 @Published）。

    /// v2.10.47/74: 切组/切页过渡态。为 true 时表示「已切到新组、新数据尚在后台异步读盘」。
    /// 仅驱动切组遮罩与旧内容淡化，token/兜底逻辑仍在主 store 的 begin/endGroupSwitchTransition。
    @Published var isSwitchingGroup: Bool = false

    /// v2.10.1: 下一次 Opt+1 自动存储会写入的空槽（绿色写游标角标）。
    @Published var autoStorePreview: SlotAddress? = nil
    /// v2.10.1: 下一次 Cmd+1 自动粘贴会读取的非空槽（蓝色读游标角标）。
    @Published var autoPastePreview: SlotAddress? = nil

    /// v2.7.0: 当前 hover 的槽位（连线口显隐判定用）。历史上从未被写入（卡片 hover 用卡片内部
    /// @State），此处下沉以统一交互态归属，不改变行为。
    @Published var hoveredSlot: Int? = nil

    // v2.10.87 (perf · 交互状态继续下沉):
    //
    // 导入进度原为主 `SlotStoreObservable` 上的 @Published。它是全仓「更新频率最高」的状态之一：
    // 槽位包导入 / 批量文件导入 / 文件夹导入 / 打包导出每处理一个条目就上报一次，几百个文件就是
    // 几百次上报。而它挂在主 store 上，于是每一次进度百分比的微小前进都会让 store.objectWillChange
    // 发射，令整棵 ContentView.body（标题栏 / 搜索区 / 含 10 张卡片的 LazyVGrid / 底栏）重新求值。
    // 卡片有 Equatable 兜底不会真重绘像素，但视图树 Diff 本身就占满了导入期间的主线程 —— 表现为
    // 「导入大批文件时整个界面发涩、hover/滚动不跟手」。
    //
    // 迁到这里后，进度浮层由只观察本 store 的 `ImportProgressOverlayView` 单独承接，进度推进只重绘
    // 那一条 340pt 宽的浮层，不再波及主网格。
    //
    // 注意：主 store 侧保留同名转发计算属性（见 main.swift），`publishImportProgress` 的
    // v2.10.56 generation 代次守卫逻辑与调用方全部不变，仅最终存储落到本 store 的 @Published。
    @Published var importProgress: ImportProgress?
}

/// v2.10.52 (perf 第四批): 独立承载 Toast + 浮层提示的覆盖层子视图，只观察 `TransientUIStore`。
///
/// 从主 `ContentView.body` 抽离后，Toast / 浮层的弹出与消失只重绘本子视图，不再触发主网格、
/// 标题栏、底栏等的重新求值。视觉表现（顶部居中、圆角胶囊、进出场动画、层级 zIndex）与
/// 抽离前保持完全一致；`allowsHitTesting(false)` 保证覆盖层不拦截下方槽位的点击。
struct TransientOverlayView: View {
    @ObservedObject var ui: TransientUIStore

    var body: some View {
        ZStack(alignment: .top) {
            if let message = ui.toastMessage {
                toastView(message)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
            if let notice = ui.floatingNotice {
                FloatingNoticeView(notice: notice)
                    .allowsHitTesting(false)
                    .padding(.top, 8)
                    .transition(.opacity)
                    .zIndex(101)
            }
        }
        // 覆盖层纯展示、不接受交互，避免顶部区域拦截下方槽位/工具栏点击。
        .allowsHitTesting(false)
        .animation(Anim.status, value: ui.toastMessage != nil)
        .animation(Anim.status, value: ui.floatingNotice != nil)
    }

    // MARK: - Toast (从 ContentView 原样迁入，样式不变)

    private func toastView(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: toastIcon(for: message))
                .font(.system(size: 11, weight: .semibold))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: Color.black.opacity(0.12), radius: 6, y: 3)
        )
        .padding(.top, 8)
    }

    private func toastIcon(for message: String) -> String {
        if message.contains("已切换到") || message.contains("下一页") { return "arrow.forward.circle.fill" }
        if message.contains("覆盖") { return "arrow.triangle.2.circlepath" }
        if message.contains("已保存") || message.contains("保存") { return "checkmark.circle.fill" }
        if message.contains("已复制") || message.contains("复制") { return "doc.on.doc" }
        if message.contains("为空") { return "tray" }
        if message.contains("正在批量") { return "hourglass" }
        if message.contains("失败") { return "xmark.circle.fill" }
        return "info.circle.fill"
    }
}
