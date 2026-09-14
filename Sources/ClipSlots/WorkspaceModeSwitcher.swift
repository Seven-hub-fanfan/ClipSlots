import SwiftUI
import ClipSlotsKit

/// 工作区切换（v2.11.7 hotfix17）。
///
/// 两个工作区是**并列的一级视图**，不是弹窗也不是抽屉：
///   - `.edit`   槽位卡片主界面（默认）
///   - `.canvas` 无限画布（生图工作台）
///
/// ★ 为什么删掉了 Agent 段：Agent 不是第三个页面，而是要**嵌进每个页面的侧边栏**。放在这里当第三段
/// 会把它误传达成「和编辑/画布并列的另一块工作区」，而且一个永远点不动的灰段在顶栏正中央只是噪声。
/// 等侧边栏落地时它会出现在两个页面各自的右侧，而不是回到这个控件里。
enum WorkspaceMode: String, CaseIterable, Identifiable, Equatable {
    case edit
    case canvas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit: return "编辑"
        case .canvas: return "画布"
        }
    }

    var symbolName: String {
        switch self {
        case .edit: return "rectangle.stack"
        case .canvas: return "square.grid.3x3.topleft.filled"
        }
    }
}

/// 两段切换控件。
///
/// 刻意**没有**复用 `NeuSegmentedControl`：那个控件跟槽位业务（自动切换/范围）绑得比较死，
/// 而这里只需要一个纯粹的视图路由器；两边各自演化互不牵连。
struct WorkspaceModeSwitcher: View {
    @Binding var selection: WorkspaceMode

    /// 控件的固定宽度。
    ///
    /// v2.11.7 hotfix20：顶栏改成「流内放等宽透明占位 + overlay 里放真控件」来实现几何真居中，
    /// 两处必须**用同一个数**，否则占位与实体不等宽，居中就会差出那点差值。所以这里把宽度从
    /// 「由内容自然撑开」改成一个显式常量：段宽 62 × 2 + 段间距 2 + 外圈 padding 3 × 2。
    static let preferredWidth: CGFloat = 62 * 2 + 2 + 3 * 2

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

    private func segment(_ mode: WorkspaceMode) -> some View {
        let isSelected = selection == mode
        return Button {
            guard selection != mode else { return }
            withAnimation(Anim.transition) { selection = mode }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                Text(mode.title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(isSelected ? AppTheme.chromeAccentInk : .secondary.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minWidth: 62)
            .background {
                if isSelected {
                    // matchedGeometryEffect 让选中背景在两段之间**滑动**而不是闪现。
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.elevatedBackground)
                        .shadow(color: AppTheme.cardShadow(isEmpty: true), radius: 3, x: 0, y: 1)
                        .matchedGeometryEffect(id: "workspaceModeIndicator", in: indicator)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.title)
    }
}
