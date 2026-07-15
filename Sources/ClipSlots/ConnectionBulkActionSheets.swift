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
        // v2.9.18: 弹窗区块间距统一到 AppTheme.spacingLarge。
        VStack(alignment: .leading, spacing: AppTheme.spacingLarge) {
            Text("导出连接模板")
                // v2.9.18: 标题统一到 AppTheme.Fonts.title（18pt）。
                .font(AppTheme.Fonts.title)
            Text("请选择要导出的连接范围。导出内容只包含连接结构，不包含槽位内容、图片或文件。")
                .font(.callout)
                .foregroundColor(.secondary)

            // v2.9.18: 按钮组间距收敛到 AppTheme.spacingMedium。
            VStack(spacing: AppTheme.spacingMedium) {
                Button("导出当前槽位组") { onExportCurrentGroup() }
                    .buttonStyle(.borderedProminent)
                Button("导出当前页面全部槽位组") { onExportCurrentPage() }
                    .buttonStyle(.bordered)
                Button("导出全部页面 / 全部槽位组") { onExportAll() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("以后不再提示，默认导出当前槽位组", isOn: $suppressNextTime)
                .font(.caption)

            // v2.9.18: 底部取消按钮靠右，间距用 AppTheme.spacingSmall。
            HStack(spacing: AppTheme.spacingSmall) { Spacer(); Button("取消") { onCancel() } }
        }
        // v2.9.18: 外层内边距统一到 AppTheme.sheetPadding（取代 24）。
        .padding(AppTheme.sheetPadding)
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
