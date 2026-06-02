import SwiftUI

struct ContentView: View {
    @ObservedObject var store: SlotStoreObservable
    @State private var showingSettings = false
    @State private var showingSpecialSlotManagement = false
    @State private var showingHotkeyTemplatePopover = false
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("appearanceMode") private var appearanceModeRaw = ThemeMode.system.rawValue

    // v2.5: Search state
    @State private var searchText: String = ""
    @State private var selectedFilter: SlotFilterType = .all
    @State private var searchScope: SlotSearchScope = .currentGroup
    @State private var globalSearchSortRule: SlotSearchSortRule = .smart

    private func cycleAppearanceMode() {
        let current = ThemeMode(rawValue: appearanceModeRaw) ?? .system
        switch current {
        case .system: appearanceModeRaw = ThemeMode.light.rawValue
        case .light:  appearanceModeRaw = ThemeMode.dark.rawValue
        case .dark:   appearanceModeRaw = ThemeMode.system.rawValue
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                headerView

                // Hotkey error banner
                if !store.hotkeyRegistrationErrors.isEmpty {
                    hotkeyErrorBanner
                }

                // v2.5: Search bar
                searchSection
                    .padding(.horizontal, AppTheme.pagePadding)
                    .padding(.vertical, 8)

                ScrollView {
                    // v2.5: No results hint
                    if searchScope == .currentGroup && isSearchActive && matchedSlotCount == 0 {
                        noResultsView
                            .padding(.top, 32)
                    }

                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 14)
                        ],
                        spacing: 14
                    ) {
                        ForEach(1...store.config.slots, id: \.self) { slot in
                            let content = store.slots[slot] ?? SlotContent()
                            let label = store.labels[slot] ?? ""
                            let isMatched = slotMatched(slot)

                            SlotCardView(
                                slot: slot,
                                content: content,
                                specialSlotId: store.currentSpecialSlotId,
                                label: label,
                                saveShortcut: shortcutPreview(store.config.saveKey, slot: slot),
                                pasteShortcut: shortcutPreview(store.config.pasteKey, slot: slot),
                                onPaste: {
                                    NSLog("[ClipSlots] UI paste button clicked slot=\(slot)")
                                    store.pasteSlotFromUI(slot)
                                },
                                onCopy: {
                                    NSLog("[ClipSlots] UI copy button clicked slot=\(slot)")
                                    store.copySlot(slot)
                                },
                                onSave: {
                                    NSLog("[ClipSlots] UI save/overwrite button clicked slot=\(slot)")
                                    store.saveToSlot(slot)
                                },
                                onClear: {
                                    NSLog("[ClipSlots] UI clear button clicked slot=\(slot)")
                                    store.clearSlotWithConfirmation(slot)
                                },
                                onSetLabel: { newLabel in
                                    store.setLabel(slot, label: newLabel.isEmpty ? nil : newLabel)
                                }
                            )
                            .opacity(!isSearchActive || isMatched ? 1.0 : 0.22)
                            .saturation(!isSearchActive || isMatched ? 1.0 : 0.35)
                            .allowsHitTesting(!isSearchActive || isMatched)
                        }
                    }
                    .padding(AppTheme.pagePadding)
                }
                .background(AppTheme.windowBackground(colorScheme))
                .transaction { $0.animation = nil }

                bottomBar
            }
            .background(AppTheme.windowBackground(colorScheme))

            // Toast overlay
            if let message = store.toastMessage {
                toastView(message)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
            if let notice = store.floatingNotice {
                floatingNoticeView(notice)
                    .transition(.opacity)
                    .zIndex(101)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.toastMessage != nil)
    }

    private var hotkeyErrorBanner: some View {
        VStack(spacing: 4) {
            ForEach(store.hotkeyRegistrationErrors, id: \.self) { error in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.red)
                    Spacer()
                }
            }
            HStack(spacing: 4) {
                Text("💡 建议在设置中尝试 Cmd+Option+数字 以避免冲突")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.red.opacity(0.2), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func floatingNoticeView(_ notice: FloatingNotice) -> some View {
        FloatingNoticeView(notice: notice)
            .allowsHitTesting(false)
            .padding(.top, 8)
    }

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
        if message.contains("覆盖") { return "arrow.triangle.2.circlepath" }
        if message.contains("已保存") || message.contains("保存") { return "checkmark.circle.fill" }
        if message.contains("已复制") || message.contains("复制") { return "doc.on.doc" }
        if message.contains("为空") { return "tray" }
        if message.contains("正在批量") { return "hourglass" }
        if message.contains("失败") { return "xmark.circle.fill" }
        return "info.circle.fill"
    }

    // MARK: - Header Layers

    private var headerView: some View {
        VStack(spacing: 0) {
            titleBar
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.vertical, 14)

            Divider()

            actionBar
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.vertical, 10)

            specialSlotTagBar
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.bottom, 6)

            activeHotkeyLayerNotice
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.bottom, 8)

            Divider()
        }
        .background(.regularMaterial)
        .popover(isPresented: $showingSettings) {
            SettingsView(config: store.config) { newConfig in
                store.updateConfig(newConfig)
                showingSettings = false
            }
            .frame(width: 460, height: 610)
        }
        .popover(isPresented: $showingSpecialSlotManagement) {
            SpecialSlotManagementView(store: store)
        }
    }

    // Layer 1: Title + Stats + Settings
    private var titleBar: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.brandGradient(colorScheme))
                    .frame(width: 44, height: 44)
                    .shadow(color: Color.accentColor.opacity(0.25), radius: 10, y: 4)

                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("ClipSlots")
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                Text("快速保存、调用和粘贴你的常用剪贴板内容")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            statPill(
                title: "已使用",
                value: "\(filledSlotCount)/\(store.config.slots)",
                icon: "checkmark.circle.fill",
                color: AppTheme.success
            )

            Button {
                cycleAppearanceMode()
            } label: {
                Image(systemName: (ThemeMode(rawValue: appearanceModeRaw) ?? .system).icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("外观：\((ThemeMode(rawValue: appearanceModeRaw) ?? .system).title)，点击切换")

            Button {
                showingHotkeyTemplatePopover = true
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("快捷键模板：\(store.config.hotkeyTemplate.kind.title)")
            .popover(isPresented: $showingHotkeyTemplatePopover) {
                HotkeyTemplatePopover(
                    config: store.config,
                    onSave: { newConfig in
                        store.updateConfig(newConfig)
                        showingHotkeyTemplatePopover = false
                    }
                )
                .frame(width: 360)
            }

            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("设置")
        }
    }

    // Layer 2: Page Selector + Actions
    private var actionBar: some View {
        HStack(spacing: 10) {
            // Page selector dropdown (v2.4)
            Menu {
                ForEach(store.pages) { page in
                    Button {
                        store.switchToPage(id: page.id)
                    } label: {
                        Label(
                            page.name,
                            systemImage: page.id == store.currentPageId ? "checkmark.circle.fill" : "square.grid.2x2"
                        )
                    }
                }
                Divider()
                Button("新建页面") { promptCreatePage() }
                if store.pages.count > 1, let page = store.currentPage {
                    Button("重命名当前页面") {
                        promptRenamePage(id: page.id, currentName: page.name)
                    }
                    Button("删除当前页面", role: .destructive) {
                        confirmDeletePage(id: page.id, name: page.name)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11))
                    Text(store.currentPage?.name ?? "默认页面")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            // Action buttons
            Button {
                store.startToolbarImport()
            } label: {
                Label("导入", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("导入文件或文件夹到当前槽位组")

            Button {
                store.pasteAllSlotsWithConfirmation()
            } label: {
                Label("全部粘贴", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .help("按顺序粘贴当前槽位组中的全部内容")

            Button(role: .destructive) {
                store.clearAllSlotsInCurrentSpecialSlotWithConfirmation()
            } label: {
                Label("清空", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("清空当前槽位组中的全部槽位")
        }
    }

    // v2.4: renamed from specialSlotTagBar — shows only current page's slot groups
    private var specialSlotTagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.currentPageSlotGroups) { group in
                    let isCurrent = group.id == store.currentSpecialSlotId

                    Button {
                        store.switchSpecialSlot(id: group.id)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isCurrent ? "folder.fill" : "folder")
                            Text(group.name)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(
                                    isCurrent
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.primary.opacity(0.05)
                                )
                        )
                        .overlay(
                            Capsule()
                                .stroke(
                                    isCurrent
                                    ? Color.accentColor.opacity(0.45)
                                    : Color.secondary.opacity(0.15),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renameSlotGroup(id: group.id, currentName: group.name)
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        if store.currentPageSlotGroups.count > 1 {
                            Button(role: .destructive) {
                                store.deleteSpecialSlotWithConfirmation(id: group.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }

                Button {
                    store.createQuickSpecialSlot()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .padding(7)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .disabled(store.currentPageSlotGroups.count >= store.specialSlotSettings.maxSpecialSlots)
                .help(store.currentPageSlotGroups.count >= store.specialSlotSettings.maxSpecialSlots
                      ? "当前页面的槽位组数量已达到上限" : "新建槽位组")

                Button {
                    showingSpecialSlotManagement = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                        .padding(7)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help("管理槽位组")
            }
        }
    }

    private var activeHotkeyLayerNotice: some View {
        let pageName = store.currentPage?.name ?? "默认页面"
        let groupName = store.currentSpecialSlot?.name ?? "默认槽位组"
        return HStack(spacing: 6) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 10))
                .foregroundColor(.accentColor)
            Text("\(pageName) / \(groupName) · ⌘+1~0 粘贴 · ⌘+← → 切组")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
    }

    // v2.4: renamed from renameSpecialSlot
    private func renameSlotGroup(id: String, currentName: String) {
        let alert = NSAlert()
        alert.messageText = "重命名槽位组"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = currentName
        textField.placeholderString = "输入新名称"
        alert.accessoryView = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty {
                store.renameSpecialSlot(id: id, name: newName)
            }
        }
    }

    // MARK: - Page Dialog Helpers (v2.4)

    private func promptCreatePage() {
        let alert = NSAlert()
        alert.messageText = "新建页面"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.placeholderString = "输入页面名称"
        alert.accessoryView = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                store.createPage(name: name)
            }
        }
    }

    private func promptRenamePage(id: String, currentName: String) {
        let alert = NSAlert()
        alert.messageText = "重命名页面"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = currentName
        textField.placeholderString = "输入新名称"
        alert.accessoryView = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty {
                store.renamePage(id: id, name: newName)
            }
        }
    }

    private func confirmDeletePage(id: String, name: String) {
        let alert = NSAlert()
        alert.messageText = "删除页面？"
        alert.informativeText = "将删除页面「\(name)」及其下所有槽位组和槽位内容。此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            store.deletePage(id: id)
        }
    }

    private func statPill(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(AppTheme.chipBackground(colorScheme)))
    }

    private func humanReadableShortcut(_ template: String) -> String {
        template
            .replacingOccurrences(of: "{n}", with: "数字")
            .replacingOccurrences(of: "cmd", with: "⌘")
            .replacingOccurrences(of: "ctrl", with: "⌃")
            .replacingOccurrences(of: "option", with: "⌥")
            .replacingOccurrences(of: "shift", with: "⇧")
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            keyChip("保存 \(humanReadableShortcut(store.config.saveKey))", icon: "square.and.arrow.down")
            keyChip("粘贴 \(humanReadableShortcut(store.config.pasteKey))", icon: "square.and.arrow.up")
            keyChip("圆盘 \(humanReadableShortcut(store.config.radialKey))", icon: "circle.grid.cross")
            keyChip("← → 切组", icon: "arrow.left.arrow.right")

            Spacer()

            Text("v2.6.4")
                .font(.caption2)
                .foregroundColor(Color.secondary.opacity(0.65))
        }
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func keyChip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(AppTheme.chipBackground(colorScheme)))
    }

    private func shortcutPreview(_ template: String, slot: Int) -> String {
        let token = store.config.hotkeyTemplate.keyToken(for: slot) ?? "\(slot)"
        return template.replacingOccurrences(of: "{n}", with: token)
    }

    private var filledSlotCount: Int {
        store.slots.values.filter { !$0.isEmpty }.count
    }

    // MARK: - Search (v2.5.1)

    private var searchSection: some View {
        VStack(spacing: 4) {
            SlotSearchBar(
                searchText: $searchText,
                selectedFilter: $selectedFilter,
                searchScope: $searchScope
            )

            if isSearchActive {
                if searchScope == .currentGroup {
                    Text(matchedSlotCount == 0
                         ? "组内未找到匹配槽位"
                         : "组内找到 \(matchedSlotCount) 个匹配槽位")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                } else {
                    GlobalSearchResultsView(
                        results: globalSearchResults,
                        currentPageId: store.currentPageId,
                        currentGroupId: store.currentSpecialSlotId,
                        onJump: jumpToSearchResult,
                        sortRule: $globalSearchSortRule
                    )
                    .padding(.top, 2)
                }
            }
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.5))
            Text("未找到匹配槽位")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button("清除搜索") {
                searchText = ""
                selectedFilter = .all
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var isSearchActive: Bool {
        SlotSearchMatcher.isActive(query: searchText, filter: selectedFilter)
    }

    private var matchedSlotCount: Int {
        (1...store.config.slots).filter { slotMatched($0) }.count
    }

    private func slotMatched(_ slot: Int) -> Bool {
        let content = store.slots[slot] ?? SlotContent()
        let label = store.labels[slot] ?? ""
        return SlotSearchMatcher.matches(
            slot: slot,
            content: content,
            label: label,
            query: searchText,
            filter: selectedFilter
        )
    }

    // MARK: - Global Search (v2.5.1)

    private var globalSearchResults: [SlotGlobalSearchResult] {
        guard searchScope == .global, isSearchActive else { return [] }

        let filtered = store.allSearchableSlots()
            .filter { result in
                SlotSearchMatcher.matches(
                    slot: result.slot,
                    content: result.content,
                    label: result.label,
                    query: searchText,
                    filter: selectedFilter
                )
            }

        switch globalSearchSortRule {
        case .smart:
            return filtered.sorted { lhs, rhs in
                let lhsCurrentPage = lhs.pageId == store.currentPageId
                let rhsCurrentPage = rhs.pageId == store.currentPageId
                if lhsCurrentPage != rhsCurrentPage { return lhsCurrentPage }
                let lhsCurrentGroup = lhs.groupId == store.currentSpecialSlotId
                let rhsCurrentGroup = rhs.groupId == store.currentSpecialSlotId
                if lhsCurrentGroup != rhsCurrentGroup { return lhsCurrentGroup }
                if lhs.pageOrder != rhs.pageOrder { return lhs.pageOrder < rhs.pageOrder }
                if lhs.groupOrder != rhs.groupOrder { return lhs.groupOrder < rhs.groupOrder }
                return lhs.slot < rhs.slot
            }
        case .slotOrder:
            return filtered.sorted { lhs, rhs in
                if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
                if lhs.pageOrder != rhs.pageOrder { return lhs.pageOrder < rhs.pageOrder }
                return lhs.groupOrder < rhs.groupOrder
            }
        case .nameAscending:
            return filtered.sorted {
                $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
            }
        case .nameDescending:
            return filtered.sorted {
                $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedDescending
            }
        case .typeOrder:
            return filtered.sorted { lhs, rhs in
                if lhs.contentTypeOrder != rhs.contentTypeOrder {
                    return lhs.contentTypeOrder < rhs.contentTypeOrder
                }
                if lhs.pageOrder != rhs.pageOrder { return lhs.pageOrder < rhs.pageOrder }
                if lhs.groupOrder != rhs.groupOrder { return lhs.groupOrder < rhs.groupOrder }
                return lhs.slot < rhs.slot
            }
        case .pageGroupSlot:
            return filtered.sorted { lhs, rhs in
                if lhs.pageOrder != rhs.pageOrder { return lhs.pageOrder < rhs.pageOrder }
                if lhs.groupOrder != rhs.groupOrder { return lhs.groupOrder < rhs.groupOrder }
                return lhs.slot < rhs.slot
            }
        }
    }

    private func jumpToSearchResult(_ result: SlotGlobalSearchResult) {
        store.switchToPage(id: result.pageId)
        store.switchSpecialSlot(id: result.groupId)
        searchScope = .currentGroup
    }
}

// MARK: - Hotkey Template Popover

struct HotkeyTemplatePopover: View {
    let config: AppConfig
    var onSave: (AppConfig) -> Void

    @State private var kind: HotkeyTemplateKind
    @State private var customKeys: [String]

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        _kind = State(initialValue: config.hotkeyTemplate.kind)
        _customKeys = State(initialValue: config.hotkeyTemplate.customKeys)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("快捷键模板")
                .font(.headline)

            Picker("模板", selection: $kind) {
                ForEach(HotkeyTemplateKind.allCases) { k in
                    Text(k.title).tag(k)
                }
            }
            .pickerStyle(.segmented)

            templatePreview

            if kind == .custom {
                customKeyGrid
            }

            Divider()

            HStack {
                Spacer()
                Button("应用") {
                    var newConfig = config
                    newConfig.hotkeyTemplate.kind = kind
                    newConfig.hotkeyTemplate.customKeys = customKeys
                    newConfig.save()
                    onSave(newConfig)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private var templatePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("槽位映射")
                .font(.subheadline)
                .foregroundColor(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                ForEach(1...10, id: \.self) { slot in
                    let key = currentTemplate.keyToken(for: slot) ?? "-"
                    VStack(spacing: 2) {
                        Text("槽 \(slot)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(key.uppercased())
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                }
            }
        }
    }

    private var currentTemplate: HotkeyTemplate {
        HotkeyTemplate(kind: kind, customKeys: customKeys)
    }

    private var customKeyGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 8) {
            ForEach(0..<10, id: \.self) { index in
                HStack {
                    Text("槽 \(index + 1)")
                        .font(.caption)
                    TextField("", text: Binding(
                        get: { customKeys.indices.contains(index) ? customKeys[index] : "" },
                        set: { v in
                            let trimmed = String(v.prefix(1)).lowercased()
                            guard customKeys.indices.contains(index) else { return }
                            customKeys[index] = trimmed
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                }
            }
        }
    }
}
