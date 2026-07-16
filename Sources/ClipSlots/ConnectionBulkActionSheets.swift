import SwiftUI
import ClipSlotsKit

// MARK: - Export Scope

enum ConnectionExportScope: String, Codable, CaseIterable {
    case currentGroup
    case currentPage
    case all
}

// MARK: - Export Scope Sheet

struct ConnectionExportScopeSheet: View {
    @Binding var suppressNextTime: Bool
    let onCancel: () -> Void
    let onExportCurrentGroup: () -> Void
    let onExportCurrentPage: () -> Void
    let onExportAll: () -> Void

    var body: some View {
        // v2.9.22: 统一弹窗视觉风格——头部图标 + 标题、卡片式范围选项（主要/次要层次）、
        // 圆角/间距对齐整体设计语言，底部主次按钮分区。
        VStack(alignment: .leading, spacing: AppTheme.spacingLarge) {
            // 头部：图标 + 标题 + 说明
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text("导出连接模板")
                        .font(AppTheme.Fonts.title)
                    Text("仅导出连接结构，不含槽位内容、图片或文件。")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 范围选项：卡片式，主要项高亮
            VStack(spacing: AppTheme.spacingSmall) {
                exportOptionRow(
                    icon: "rectangle.stack.fill",
                    title: "当前槽位组",
                    subtitle: "只导出正在编辑的这一组连接",
                    isPrimary: true,
                    action: onExportCurrentGroup
                )
                exportOptionRow(
                    icon: "square.grid.2x2.fill",
                    title: "当前页面全部槽位组",
                    subtitle: "导出本页面下所有槽位组的连接",
                    isPrimary: false,
                    action: onExportCurrentPage
                )
                exportOptionRow(
                    icon: "square.grid.3x3.fill",
                    title: "全部页面 / 全部槽位组",
                    subtitle: "导出整个应用的所有连接",
                    isPrimary: false,
                    action: onExportAll
                )
            }

            Toggle("以后不再提示，默认导出当前槽位组", isOn: $suppressNextTime)
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            // 底部：取消（次要操作）靠右
            HStack(spacing: AppTheme.spacingSmall) {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(AppTheme.sheetPadding)
        .frame(width: 420, alignment: .leading)
    }

    // v2.9.22: 卡片式范围选项行——图标 + 标题 + 说明，主要项加高亮描边与浅底。
    private func exportOptionRow(
        icon: String,
        title: String,
        subtitle: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isPrimary ? .accentColor : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isPrimary ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isPrimary ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Clear Confirm Sheet

struct ConnectionClearConfirmSheet: View {
    @Binding var suppressNextTime: Bool
    let onCancel: () -> Void
    let onClearCurrentGroup: () -> Void
    let onClearCurrentPage: () -> Void
    let onClearAll: () -> Void

    var body: some View {
        // v2.9.18: 弹窗区块间距统一到 AppTheme.spacingLarge。
        VStack(alignment: .leading, spacing: AppTheme.spacingLarge) {
            Text("清除连接")
                // v2.9.18: 标题统一到 AppTheme.Fonts.title（18pt）。
                .font(AppTheme.Fonts.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("只删除连接关系，不删除槽位内容。")
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // v2.9.18: 按钮组间距收敛到 AppTheme.spacingMedium。
            VStack(spacing: AppTheme.spacingMedium) {
                // v2.9.18: 危险按钮 tint 统一到 AppTheme.danger。
                Button(role: .destructive) { onClearCurrentGroup() } label: { Text("清当前组").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.borderedProminent).tint(AppTheme.danger)
                Button(role: .destructive) { onClearCurrentPage() } label: { Text("清当前页").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.bordered).tint(AppTheme.danger)
                Button(role: .destructive) { onClearAll() } label: { Text("清全部").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.bordered).tint(AppTheme.danger)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("以后不再提示，默认清除当前槽位组", isOn: $suppressNextTime)
                .font(.caption)

            // v2.9.18: 底部取消按钮靠右，间距用 AppTheme.spacingSmall。
            HStack(spacing: AppTheme.spacingSmall) { Spacer(); Button("取消") { onCancel() } }
        }
        // v2.9.18: 外层内边距统一到 AppTheme.sheetPadding（取代 24）。
        .padding(AppTheme.sheetPadding)
        .frame(width: 390, alignment: .leading)
    }
}
