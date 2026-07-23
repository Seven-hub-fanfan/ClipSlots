import SwiftUI
import ClipSlotsKit

// MARK: - Slot Search Bar (v2.5.1)

struct SlotSearchBar: View {
    @Binding var searchText: String
    @Binding var selectedFilter: SlotFilterType
    @Binding var searchScope: SlotSearchScope
    @Environment(\.colorScheme) private var colorScheme
    // v2.10.1: 独立「自动切换」按钮已移除——自动切换统一由顶部拨杆3控制，避免双入口。

    var body: some View {
        // v2.9.18: 搜索行与筛选行的散落 spacing 统一收敛到 AppTheme.spacingSmall。
        VStack(spacing: AppTheme.spacingSmall) {
            // Search field + scope picker
            // v2.9.18: 显式声明 .center，确保放大镜、输入框、清除按钮、scope picker 垂直居中对齐。
            HStack(alignment: .center, spacing: AppTheme.spacingSmall) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))

                TextField("搜索槽位、标签、文件名、路径...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }

                // Scope picker
                Picker("", selection: $searchScope) {
                    ForEach(SlotSearchScope.allCases) { scope in
                        Label(scope.title, systemImage: scope.systemImage)
                            .tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.searchFieldBackground(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.searchFieldStroke(colorScheme), lineWidth: 1)
            )

            // Filter chips（v2.10.1: 移除行尾独立「自动切换」按钮，统一走顶部拨杆3）
            ScrollView(.horizontal, showsIndicators: false) {
                // v2.9.18: chip 间距收敛到 AppTheme.spacingSmall，与搜索行保持一致节奏。
                HStack(spacing: AppTheme.spacingSmall) {
                    ForEach(SlotFilterType.allCases) { filter in
                        filterChip(filter)
                    }
                }
            }
        }
    }

    private func filterChip(_ filter: SlotFilterType) -> some View {
        let selected = selectedFilter == filter

        return Button {
            selectedFilter = filter
        } label: {
            // v2.9.18: chip 内图标↔文字间距收敛到 AppTheme.spacingTight。
            HStack(spacing: AppTheme.spacingTight) {
                Image(systemName: filter.systemImage)
                    .font(.system(size: 10, weight: .semibold))

                Text(filter.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(selected
                        ? AppTheme.filterChipSelectedBackground(colorScheme)
                        : AppTheme.filterChipBackground(colorScheme)
                    )
            )
            .foregroundColor(selected
                ? AppTheme.filterChipSelectedText(colorScheme)
                : AppTheme.filterChipText(colorScheme)
            )
        }
        .buttonStyle(.plain)
    }
}
