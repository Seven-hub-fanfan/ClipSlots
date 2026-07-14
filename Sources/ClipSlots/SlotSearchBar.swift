import SwiftUI
import ClipSlotsKit

// MARK: - Slot Search Bar (v2.5.1)

struct SlotSearchBar: View {
    @Binding var searchText: String
    @Binding var selectedFilter: SlotFilterType
    @Binding var searchScope: SlotSearchScope
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            // Search field + scope picker
            HStack(spacing: 8) {
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

            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
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
            HStack(spacing: 4) {
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
