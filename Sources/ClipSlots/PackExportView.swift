import SwiftUI
import ClipSlotsKit

// MARK: - 打包导出选择 Sheet (v2.10.14)

/// 让用户多选「页面 + 槽位组」（页面粒度与组粒度可混选）后触发导出。
/// 体积预估与 >50MB 二次确认、NSSavePanel 均在 store 侧处理，本视图只负责收集选择。
struct PackExportView: View {
    @ObservedObject var store: SlotStoreObservable
    let onCancel: () -> Void
    let onExport: (PackExportSelection) -> Void

    @State private var selectedGroupIds: Set<String> = []
    @State private var didInit = false

    // 页面（按 order） -> 该页槽位组（按 order）。
    private var pageGroups: [(page: SlotPage, groups: [SpecialSlot])] {
        store.pages
            .sorted { $0.order < $1.order }
            .map { page in
                (page, store.specialSlots.filter { $0.pageId == page.id }.sorted { $0.order < $1.order })
            }
    }

    private var selectedCount: Int { selectedGroupIds.count }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spacingLarge) {
            header
            Divider()
            scopeList
            Divider()
            footer
        }
        .padding(AppTheme.sheetPadding)
        .frame(width: 460, height: 560)
        .onAppear {
            guard !didInit else { return }
            // 默认全选所有组。
            selectedGroupIds = Set(store.specialSlots.map { $0.id })
            didInit = true
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("打包导出")
                    .font(.system(size: 16, weight: .bold))
                Text("选择要导出的页面和槽位组，可按页面或按组混选。导出为 .clipslotspack 文件。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: 选择列表

    private var scopeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.spacingSmall) {
                if pageGroups.isEmpty {
                    Text("暂无可导出的页面")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                }
                ForEach(pageGroups, id: \.page.id) { entry in
                    pageSection(page: entry.page, groups: entry.groups)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pageSection(page: SlotPage, groups: [SpecialSlot]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // 页面行：勾选框切换整页所有组。
            Button(action: { togglePage(groups: groups) }) {
                HStack(spacing: 8) {
                    checkboxIcon(state: pageState(groups: groups))
                        .foregroundColor(.accentColor)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(page.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text("(\(groups.count) 组)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 组行（缩进）。
            if groups.isEmpty {
                Text("该页暂无槽位组")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 30)
            } else {
                ForEach(groups) { group in
                    Button(action: { toggleGroup(group.id) }) {
                        HStack(spacing: 8) {
                            checkboxIcon(state: selectedGroupIds.contains(group.id) ? .all : .none)
                                .foregroundColor(.accentColor)
                            Image(systemName: group.icon.isEmpty ? "folder" : group.icon)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text(group.name)
                                .font(.system(size: 12))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 22)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Text("已选 \(selectedCount) 个槽位组")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Button("取消", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("导出") {
                onExport(buildSelection())
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selectedCount == 0)
        }
    }

    // MARK: 选择逻辑

    private enum CheckState { case all, partial, none }

    private func pageState(groups: [SpecialSlot]) -> CheckState {
        guard !groups.isEmpty else { return .none }
        let selected = groups.filter { selectedGroupIds.contains($0.id) }.count
        if selected == 0 { return .none }
        if selected == groups.count { return .all }
        return .partial
    }

    private func checkboxIcon(state: CheckState) -> some View {
        let name: String
        switch state {
        case .all: name = "checkmark.square.fill"
        case .partial: name = "minus.square.fill"
        case .none: name = "square"
        }
        return Image(systemName: name).font(.system(size: 14))
    }

    private func togglePage(groups: [SpecialSlot]) {
        let ids = groups.map { $0.id }
        let allSelected = !ids.isEmpty && ids.allSatisfy { selectedGroupIds.contains($0) }
        if allSelected {
            ids.forEach { selectedGroupIds.remove($0) }
        } else {
            ids.forEach { selectedGroupIds.insert($0) }
        }
    }

    private func toggleGroup(_ id: String) {
        if selectedGroupIds.contains(id) {
            selectedGroupIds.remove(id)
        } else {
            selectedGroupIds.insert(id)
        }
    }

    private func buildSelection() -> PackExportSelection {
        let pages: [PackExportSelection.PageSelection] = pageGroups.compactMap { entry in
            let selected = entry.groups.filter { selectedGroupIds.contains($0.id) }
            guard !selected.isEmpty else { return nil }
            return PackExportSelection.PageSelection(page: entry.page, groups: selected)
        }
        return PackExportSelection(pages: pages)
    }
}
