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
        VStack(alignment: .leading, spacing: 18) {
            Text("导出连接模板")
                .font(.system(size: 18, weight: .semibold))
            Text("请选择要导出的连接范围。导出内容只包含连接结构，不包含槽位内容、图片或文件。")
                .font(.callout)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
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

            HStack { Spacer(); Button("取消") { onCancel() } }
        }
        .padding(24)
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
        VStack(alignment: .leading, spacing: 18) {
            Text("清除连接")
                .font(.system(size: 18, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("只删除连接关系，不删除槽位内容。")
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                Button(role: .destructive) { onClearCurrentGroup() } label: { Text("清当前组").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.borderedProminent).tint(.red)
                Button(role: .destructive) { onClearCurrentPage() } label: { Text("清当前页").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.bordered).tint(.red)
                Button(role: .destructive) { onClearAll() } label: { Text("清全部").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.bordered).tint(.red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("以后不再提示，默认清除当前槽位组", isOn: $suppressNextTime)
                .font(.caption)

            HStack { Spacer(); Button("取消") { onCancel() } }
        }
        .padding(24)
        .frame(width: 390, alignment: .leading)
    }
}
