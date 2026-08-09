import SwiftUI
import ClipSlotsKit

// MARK: - Compact slot search bar

struct SlotSearchBar: View {
    @Binding var searchText: String
    @Binding var selectedFilter: SlotFilterType
    @Binding var searchScope: SlotSearchScope
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.spacingSmall) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: AppTheme.spacingSmall) {
                    searchField
                        .layoutPriority(2)
                    ViewThatFits(in: .horizontal) {
                        filterStrip
                        filterMenu
                    }
                }

                HStack(alignment: .center, spacing: AppTheme.spacingTight) {
                    searchField
                        .layoutPriority(2)
                    filterMenu
                }
            }
        }
    }

    private var searchField: some View {
        HStack(alignment: .center, spacing: AppTheme.spacingSmall) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))

            TextField("搜索槽位…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(minWidth: 90)

            if !searchText.isEmpty || selectedFilter != .all {
                Button {
                    if !searchText.isEmpty { searchText = "" } else { selectedFilter = .all }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }

            ViewThatFits(in: .horizontal) {
                Picker("", selection: $searchScope) {
                    ForEach(SlotSearchScope.allCases) { scope in
                        Label(scope.title, systemImage: scope.systemImage).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 104)

                Menu {
                    ForEach(SlotSearchScope.allCases) { scope in
                        Button {
                            searchScope = scope
                        } label: {
                            Label(scope.title, systemImage: searchScope == scope ? "checkmark" : scope.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: searchScope.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(AppTheme.filterChipBackground(colorScheme)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("搜索范围：\(searchScope.title)")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppTheme.searchFieldBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(AppTheme.searchFieldStroke(colorScheme), lineWidth: 1)
        )
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.spacingTight) {
                ForEach(SlotFilterType.allCases) { filter in filterChip(filter) }
            }
        }
        .frame(minWidth: 150, idealWidth: 330, maxWidth: 390)
    }

    private var filterMenu: some View {
        Menu {
            ForEach(SlotFilterType.allCases) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    Label(filter.title, systemImage: selectedFilter == filter ? "checkmark" : filter.systemImage)
                }
            }
        } label: {
            Label(selectedFilter.title, systemImage: "line.3.horizontal.decrease.circle")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Capsule().fill(AppTheme.filterChipBackground(colorScheme)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("筛选槽位类型")
    }

    private func filterChip(_ filter: SlotFilterType) -> some View {
        let selected = selectedFilter == filter
        return Button { selectedFilter = filter } label: {
            HStack(spacing: AppTheme.spacingTight) {
                Image(systemName: filter.systemImage).font(.system(size: 9, weight: .semibold))
                Text(filter.title).font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected
                ? AppTheme.filterChipSelectedBackground(colorScheme)
                : AppTheme.filterChipBackground(colorScheme)))
            .foregroundColor(selected
                ? AppTheme.filterChipSelectedText(colorScheme)
                : AppTheme.filterChipText(colorScheme))
        }
        .buttonStyle(.plain)
    }
}
