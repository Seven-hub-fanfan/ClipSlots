import SwiftUI
import ClipSlotsKit

/// 顶部工具栏中间的工作区三段切换（v2.11.7）。
///
/// 三个工作区是**并列的一级视图**，不是弹窗也不是抽屉：
///   - `.canvas` 无限画布（生图工作台）
///   - `.edit`   槽位卡片主界面（默认）
///   - `.agent`  尚未开放
enum WorkspaceMode: String, CaseIterable, Identifiable, Equatable {
    case canvas
    case edit
    case agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .canvas: return "画布"
        case .edit: return "编辑"
        case .agent: return "Agent"
        }
    }

    var symbolName: String {
        switch self {
        case .canvas: return "square.grid.3x3.topleft.filled"
        case .edit: return "rectangle.stack"
        case .agent: return "sparkles.rectangle.stack"
        }
    }

    /// 是否可切换。Agent 还没有任何实现，给它一个明确的「不可用」态而不是切进去看空页面。
    var isAvailable: Bool { self != .agent }
}

/// 三段切换控件。
///
/// 刻意**没有**复用 `NeuSegmentedControl`：那个控件的契约是「每一段都可选」，而这里 Agent 段必须
/// 是灰的、不可点、但仍然可见（用户需要知道它即将到来）。把「某段禁用」硬塞进通用控件会让它的
/// `@Binding selection` 出现「选中了一个不可选值」的非法中间态；这里单独实现，禁用逻辑就地闭合。
struct WorkspaceModeSwitcher: View {
    @Binding var selection: WorkspaceMode

    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceMode.allCases) { mode in
                segment(mode)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.chipBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.subtleBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func segment(_ mode: WorkspaceMode) -> some View {
        let isSelected = selection == mode
        let label = HStack(spacing: 5) {
            Image(systemName: mode.symbolName)
                .font(.system(size: 10, weight: .semibold))
            Text(mode.title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(foreground(mode, isSelected: isSelected))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 62)
        .background {
            if isSelected {
                // matchedGeometryEffect 让选中背景在三段之间**滑动**而不是闪现。
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.elevatedBackground)
                    .shadow(color: AppTheme.cardShadow(isEmpty: true), radius: 3, x: 0, y: 1)
                    .matchedGeometryEffect(id: "workspaceModeIndicator", in: indicator)
            }
        }
        .contentShape(Rectangle())

        if mode.isAvailable {
            Button {
                guard selection != mode else { return }
                withAnimation(Anim.transition) { selection = mode }
            } label: { label }
            .buttonStyle(.plain)
            .help(mode.title)
        } else {
            // 不用 `Button().disabled(true)`：那样 `.help` 在部分 macOS 版本上也一并失效，
            // 用户既点不动又看不到原因。这里保留一个纯展示的 label + tooltip。
            label
                .opacity(0.42)
                .help("\(mode.title)：即将推出")
        }
    }

    private func foreground(_ mode: WorkspaceMode, isSelected: Bool) -> Color {
        guard mode.isAvailable else { return .secondary }
        return isSelected ? AppTheme.chromeAccentInk : .secondary.opacity(0.85)
    }
}

/// Agent 工作区占位。
///
/// 目前进不来（切换器里 Agent 段不可点），但仍然实现它 —— 这样 `switch workspaceMode` 是穷尽的，
/// 未来放开入口时不需要回来补分支。
struct AgentPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(.secondary.opacity(0.3))
            Text("Agent 即将推出")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.6))
            Text("在这里用自然语言驱动槽位与画布")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.42))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.windowBackground)
    }
}
