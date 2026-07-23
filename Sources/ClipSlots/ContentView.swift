import SwiftUI
import ClipSlotsKit

struct ContentView: View {
    @ObservedObject var store: SlotStoreObservable
    // v2.10.0: 三档金属拨杆共享状态（自动存储 / 自动粘贴 / 自动切换）。
    @ObservedObject private var autoMode = AutoModeState.shared
    @State private var showingSettings = false
    @State private var showingSpecialSlotManagement = false
    @State private var showingHotkeyTemplatePopover = false
    // v2.9.8: plugins page popover.
    @State private var showingPlugins = false
    // v2.9.8: update checker.
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @State private var showingConnectionFullscreen = false
    // v2.9.37: hover state for the footer "上次粘贴" button (subtle hover highlight).
    @State private var lastPasteHovering = false
    @Environment(\.colorScheme) private var colorScheme

    // v2.7.47: new installs should open in dark mode by default.
// AppStorage's default only applies when UserDefaults has no value, so existing
// users who already selected system/light/dark are not overwritten.
@AppStorage("appearanceMode") private var appearanceModeRaw = ThemeMode.dark.rawValue

    // v2.5: Search state
    @State private var searchText: String = ""
    @State private var selectedFilter: SlotFilterType = .all
    // v2.7.23: global search is the default. Users can still switch back to group scope.
@State private var searchScope: SlotSearchScope = .global
    @State private var globalSearchSortRule: SlotSearchSortRule = .smart
    // v2.8.0 (perf M1/M2): debounced + cached global search. `searchText` changes on
    // every keystroke, but the expensive cross-page/group scan should only run after
    // the user pauses typing (debounce), and its result is cached in state so that
    // unrelated view re-renders (e.g. thumbnails finishing load) no longer re-run the
    // whole scan+sort on the main thread.
    @State private var globalSearchResultsCache: [SlotGlobalSearchResult] = []
    @State private var searchDebounceWorkItem: DispatchWorkItem?

    // v2.7.1: stable connection sheet replaces broken node-canvas UI.
    @State private var showingConnectionManagement = false
    // v2.7.2: Independent node canvas (does NOT draw lines on the main grid).
    @State private var showingNodeCanvas = false

    // v2.9.17: theme switch now takes effect instantly with no transition effect.
    // The previous water-ripple overlay (v2.7.45) was removed per product request.
    private func cycleAppearanceMode() {
        let current = ThemeMode(rawValue: appearanceModeRaw) ?? .system
        switch current {
        // v2.7.41: toolbar theme switch only toggles light/dark.
        // Keep "follow system" only in Settings to avoid confusing three-state cycling.
        case .system: appearanceModeRaw = ThemeMode.dark.rawValue
        case .light:  appearanceModeRaw = ThemeMode.dark.rawValue
        case .dark:   appearanceModeRaw = ThemeMode.light.rawValue
        }
    }

    // v2.9.12: Obsidian-style in-app settings overlay. Dimmed backdrop + centered
    // two-pane panel. Lives inside the main window ZStack, so it follows the window.
    private var settingsOverlay: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeSettings() }

                SettingsView(
                    config: store.config,
                    onSave: { newConfig in
                        store.updateConfig(newConfig)
                        closeSettings()
                    },
                    onClose: { closeSettings() },
                    // v2.9.17: sidebar「插件市场」→ close settings, open the
                    // independent plugin marketplace popover (anchored on toolbar).
                    onOpenPlugins: {
                        showingSettings = false
                        store.isSettingsPresented = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            showingPlugins = true
                        }
                    }
                )
                // Fill the main window with small insets so it reads as an in-app
                // panel (like Obsidian), while staying usable in small windows.
                .frame(
                    width: min(max(geo.size.width - 32, 480), 880),
                    height: min(max(geo.size.height - 32, 380), 660)
                )
                .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func closeSettings() {
        withAnimation(.easeInOut(duration: 0.2)) { showingSettings = false }
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

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        // v2.5: No results hint
                        if searchScope == .currentGroup && isSearchActive && matchedSlotCount == 0 {
                            noResultsView
                                .padding(.top, 32)
                        }

                        LazyVGrid(
                            columns: [
                                // v2.7.37: rollback the over-compressed v2.7.36 grid.
                                // The aggressive 218px cards caused text / thumbnails / buttons to overlap.
                                GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 14)
                            ],
                            spacing: 14
                        ) {
                            ForEach(1...store.config.slots, id: \.self) { slot in
                                slotCardView(slot: slot)
                                    .id(slot)
                            }
                        }
                        .padding(AppTheme.pagePadding)
                    }
                    .background(AppTheme.windowBackground(colorScheme))
                    .transaction { $0.animation = nil }
                    // v2.9.37: when the footer "上次粘贴" button flashes a slot, scroll it
                    // into view so the highlighted card is always visible after the jump.
                    .onChange(of: store.flashHighlightSlot) { target in
                        guard let target else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scrollProxy.scrollTo(target.slot, anchor: .center)
                        }
                    }
                }


                bottomBar
            }
            .background(
                RetroPosterAmbientBackground()
                    .ignoresSafeArea()
            )

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

            // v2.9.12: in-app settings overlay (Obsidian-style two-pane).
            // Rendered inside the main window's ZStack so it stays attached to the
            // window and moves together when the window is dragged.
            if showingSettings {
                settingsOverlay
                    .transition(.opacity)
                    .zIndex(200)
            }

        }
        .onAppear {
            AppearanceDefaults.ensureDefaultDarkIfNeeded()
        }
        .animation(.easeInOut(duration: 0.25), value: store.toastMessage != nil)
        // v2.9.12: settings overlay is a modal hotkey-editing safe zone; keep the
        // store flag in sync so business hotkeys don't fire while it is open.
        .onChange(of: showingSettings) { store.isSettingsPresented = $0 }
        // v2.9.12: Cmd+, / "设置…" menu opens the in-app overlay.
        .onReceive(NotificationCenter.default.publisher(for: .openInAppSettings)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { showingSettings = true }
        }
        // v2.6.7: Import options sheet
        .sheet(item: $store.pendingImportSelection) { selection in
            ImportOptionsSheet(
                selection: selection,
                onCancel: {
                    store.pendingImportSelection = nil
                },
                onConfirm: { choice in
                    store.pendingImportSelection = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        store.executeImportSelection(selection, choice: choice)
                    }
                }
            )
        }
        // v2.7.1: stable connection manager replaces broken node-canvas UI.
        .sheet(isPresented: $showingConnectionManagement) {
            ConnectionManagementSheet(store: store)
                .frame(width: 540, height: 620)
        }
        // v2.7.2: Independent node canvas. Do NOT draw connection lines on the main slot grid.
        .sheet(isPresented: $showingNodeCanvas) {
            NodeCanvasSheet(store: store)
                .frame(minWidth: 980, minHeight: 680)
        }
        .sheet(isPresented: $showingConnectionFullscreen) {
            ConnectionFullscreenView(
                store: store,
                onClose: { showingConnectionFullscreen = false },
                onOpenNodeCanvas: { showingNodeCanvas = true; showingConnectionFullscreen = false },
                onOpenManager: { showingConnectionManagement = true; showingConnectionFullscreen = false }
            )
                .frame(minWidth: 720, minHeight: 560)
        }
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
        if message.contains("已切换到") || message.contains("下一页") { return "arrow.forward.circle.fill" }
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
                .padding(.vertical, 12)

            Divider()

            actionBar
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.top, 6)
                .padding(.bottom, 4)

            specialSlotTagBar
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.bottom, 4)

            // v2.7.37: remove the upper shortcut hint completely.
            // It duplicated the bottom bar and consumed vertical space for slots.
            // activeHotkeyLayerNotice intentionally not rendered here.

            Divider()
        }
        .background(.regularMaterial)
        .popover(isPresented: $showingSpecialSlotManagement) {
            SpecialSlotManagementView(store: store)
        }
        // v2.8.0 (perf M1/M2): drive the cached global-search results from explicit
        // input changes instead of recomputing inside the view body on every render.
        .onChange(of: searchText) { _ in scheduleGlobalSearchRecompute(debounced: true) }
        .onChange(of: selectedFilter) { _ in scheduleGlobalSearchRecompute(debounced: false) }
        .onChange(of: searchScope) { _ in scheduleGlobalSearchRecompute(debounced: false) }
        .onChange(of: globalSearchSortRule) { _ in scheduleGlobalSearchRecompute(debounced: false) }
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

            // v2.9.8: 检查更新入口（标题右侧空白区，月亮图标左边那一排）
            Button {
                updateChecker.checkForUpdates()
            } label: {
                HStack(spacing: 5) {
                    if updateChecker.isChecking {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(updateChecker.isChecking ? "检查中…" : "检查更新")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.12))
                .foregroundColor(.accentColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.borderless)
            .disabled(updateChecker.isChecking)
            .help("检查是否有新版本")

            // v2.9.22: 版本号从右下角迁移到左上角「检查更新」按钮右侧，靠近版本相关操作更合理。
            Text("v\(AppVersion.current)")
                .font(.caption2)
                .foregroundColor(Color.secondary.opacity(0.75))
                .help("当前版本 v\(AppVersion.current)\n首次打开 ClipSlots.app 时，macOS 可能提示“无法验证开发者”，请右键点击 App → 选择「打开」→ 点击「打开」确认即可。")

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

            // v2.9.8: 插件入口（月亮与键盘图标之间）
            Button {
                showingPlugins = true
            } label: {
                // v2.9.23: 干净简洁的主题色拼图图标（去掉层次渲染灰色锯齿与红点通知），
                // 与相邻工具栏图标（外观/键盘）保持一致的样式。
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("插件")
            .popover(isPresented: $showingPlugins) {
                PluginsView {
                    showingPlugins = false
                }
            }

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

            // v2.9.12: settings now open as an in-app overlay (Obsidian-style),
            // embedded in the main window so it follows the window when dragged.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showingSettings = true }
            } label: {
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
        HStack(alignment: .center, spacing: 10) {
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
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // v2.10.0: 三档金属拨杆（自动存储 / 自动粘贴 / 自动切换）。
            leverCluster

            Spacer()

            toolbarActions
        }
        .frame(minHeight: 36, alignment: .center)
    }

    // v2.10.0: 三个金属拨杆并排，与现有操作按钮用分隔线区分。
    private var leverCluster: some View {
        HStack(alignment: .center, spacing: 10) {
            Divider().frame(height: 26)

            ToggleLeverView(isOn: $autoMode.autoStoreEnabled, label: "自动存储",
                            help: "开启后按 Opt+1 会把剪贴板写入下一个空槽")
            ToggleLeverView(isOn: $autoMode.autoPasteEnabled, label: "自动粘贴",
                            help: "开启后按 Cmd+1 会从读游标取下一个非空槽粘贴")
            ToggleLeverView(isOn: $autoMode.autoAdvanceEnabled, label: "自动切换",
                            help: "开启后自动存储/粘贴可跨组、跨页推进；关闭则只在当前组内循环")

            Divider().frame(height: 26)
        }
        .fixedSize()
    }

    // v2.7.39: keep the top-right action group vertically centered and easier to hit.
    // The previous system Button styles had inconsistent intrinsic heights, making the
    // group look stuck to the top of the row.
    private var toolbarActions: some View {
        HStack(alignment: .center, spacing: 8) {
            ToolbarActionButton(
                title: "导入",
                icon: "folder.badge.plus",
                role: .normal,
                prominent: false,
                action: { store.startToolbarImport() }
            )
            .help("导入文件或文件夹到当前槽位组")

            ToolbarActionButton(
                title: "全部粘贴",
                icon: "text.line.first.and.arrowtriangle.forward",
                role: .accent,
                prominent: true,
                action: { store.pasteAllSlotsWithConfirmation() }
            )
            .help("按顺序粘贴当前槽位组中的全部内容")

            ToolbarActionButton(
                title: "清空",
                icon: "trash",
                role: .destructive,
                prominent: true,
                action: { store.clearAllSlotsInCurrentSpecialSlotWithConfirmation() }
            )
            .help("清空当前槽位组中的全部槽位")
        }
        .frame(height: 36, alignment: .center)
        .padding(.horizontal, 2)
    }

    // v2.9.31: "自动切换" toggle moved to the filter row (see SlotSearchBar, v2.9.33).

    // v2.4: renamed from specialSlotTagBar — shows only current page's slot groups
    private var specialSlotTagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
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
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
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
                        .padding(6)
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
                        .padding(6)
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
        return HStack(spacing: 8) {
            Label("\(pageName) / \(groupName)", systemImage: "folder.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)

            ShortcutBadge(title: "粘贴", shortcut: shortcutDisplay(store.config.pasteKey, slotToken: "数字"), icon: "square.and.arrow.up")
            ShortcutBadge(title: "保存", shortcut: shortcutDisplay(store.config.saveKey, slotToken: "数字"), icon: "square.and.arrow.down")
            ShortcutBadge(title: "圆盘", shortcut: shortcutDisplay(store.config.radialKey), icon: "circle.grid.cross")
            ShortcutBadge(title: "切组", shortcut: "⌘ ← / ⌘ →", icon: "arrow.left.arrow.right")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
        .id("\(store.config.saveKey)|\(store.config.pasteKey)|\(store.config.radialKey)|\(store.config.hotkeyTemplate.kind.rawValue)")
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
        shortcutDisplay(template, slotToken: "数字")
    }

    private func shortcutDisplay(_ template: String, slotToken: String = "") -> String {
        let rawParts = template
            .replacingOccurrences(of: "{n}", with: slotToken)
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        let mapped = rawParts.map { part -> String in
            switch part {
            case "cmd", "command", "⌘": return "⌘"
            case "ctrl", "control", "⌃": return "⌃"
            case "option", "opt", "alt", "⌥": return "⌥"
            case "shift", "⇧": return "⇧"
            case "space", "spacebar": return "Space"
            case "left", "arrowleft", "←": return "←"
            case "right", "arrowright", "→": return "→"
            case "up", "arrowup", "↑": return "↑"
            case "down", "arrowdown", "↓": return "↓"
            default: return part.uppercased()
            }
        }
        return mapped.joined(separator: " ")
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // v2.7.37: keep the shortcut hint only in the bottom bar, because it is compact
            // and leaves the top content area to the slot grid.
            ShortcutBadge(title: "保存", shortcut: shortcutDisplay(store.config.saveKey, slotToken: "数字"), icon: "square.and.arrow.down")
            ShortcutBadge(title: "粘贴", shortcut: shortcutDisplay(store.config.pasteKey, slotToken: "数字"), icon: "square.and.arrow.up")
            ShortcutBadge(title: "圆盘", shortcut: shortcutDisplay(store.config.radialKey), icon: "circle.grid.cross")
            ShortcutBadge(title: "切组", shortcut: "⌘ ← / ⌘ →", icon: "arrow.left.arrow.right")

            // v2.9.36: persistent "上次粘贴" status, styled subtly so it never
            // competes with the shortcut chips for attention.
            lastPasteStatusView

            Spacer()

            // Connection stays as a separate tool and is moved to the right side.
            // v2.9.24: 当「槽位连接」开关关闭时，底部「连接」入口按钮彻底隐藏（不占位）。
            if store.isSlotConnectionEnabled {
                connectionToolButton
            }
            // v2.9.22: 版本号已迁移到左上角「检查更新」按钮右侧，底部不再重复展示。
        }
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // v2.9.37: footer "上次粘贴" status, redesigned to be low-key (small icon +
    // secondary text, no coloured capsule) so it blends into the footer text.
    // It is now a button: hover gives a subtle highlight, click jumps + scrolls to
    // the last-paste group and flashes the corresponding card for 2s.
    private var lastPasteStatusView: some View {
        Button {
            store.jumpToLastPaste()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.forward.circle")
                    .font(.system(size: 11, weight: .semibold))
                if let desc = store.lastPasteDescription {
                    Text("上次粘贴 ")
                    + Text(desc)
                        .foregroundColor(lastPasteHovering ? .primary : .secondary)
                } else {
                    Text("上次粘贴 —")
                }
            }
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundColor(lastPasteHovering ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(lastPasteHovering ? AppTheme.chipBackground(colorScheme) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.lastPasteDescription == nil)
        .onHover { hovering in
            // Only highlight when the button is actionable (there is a location).
            lastPasteHovering = hovering && store.lastPasteDescription != nil
        }
        .animation(.easeInOut(duration: 0.15), value: lastPasteHovering)
        .help(store.lastPasteDescription.map { "点击跳转到上次粘贴位置：\($0)" } ?? "尚未粘贴过任何槽位")
    }

    // v2.7.9: prominent connection button with current-group state.
    // v2.7.36: standalone connection button, not mixed with shortcut chips.
    private var connectionToolButton: some View {
        Button {
            showingConnectionFullscreen = true
        } label: {
            connectionMenuLabel
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    private var connectionMenuLabel: some View {
        let edgeCount = store.currentConnectionMap.edges.count
        let hasConnections = edgeCount > 0
        // v2.9.22: 「连接」按钮升级——更贴切的节点连线图标 + 渐变胶囊 + 描边/投影，
        // 提升质感并与整体设计语言统一；有连接时用强调色渐变，无连接时用中性玻璃底。
        return HStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .bold))
                .symbolRenderingMode(.hierarchical)
            Text(hasConnections ? "连接 · \(edgeCount)" : "连接")
                .font(.caption.weight(.semibold))
        }
        .foregroundColor(hasConnections ? .white : .accentColor)
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(
                    hasConnections
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.accentColor.opacity(0.10))
                )
        )
        .overlay(
            Capsule().stroke(
                hasConnections ? Color.white.opacity(0.35) : Color.accentColor.opacity(0.35),
                lineWidth: 1)
        )
        .shadow(
            color: hasConnections ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.06),
            radius: hasConnections ? 6 : 2, x: 0, y: hasConnections ? 2 : 1)
        .scaleEffect(hasConnections ? 1.02 : 1.0)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: edgeCount)
        .help(hasConnections ? "当前槽位组已有 \(edgeCount) 条连接" : "打开节点连接工具")
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

    // MARK: - v2.7.0 Connection Mode Bar

    // v2.7.1: connection mode bar disabled — use ConnectionManagementSheet instead.
    private var connectionModeBar: some View {
        EmptyView()
    }

    // MARK: - v2.7.0 Slot Card Helper

    @ViewBuilder
    private func slotCardView(slot: Int) -> some View {
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
            onPaste: { store.pasteSlotFromUI(slot) },
            onCopy: { store.copySlot(slot) },
            onSave: { store.saveToSlot(slot) },
            onClear: { store.clearSlotWithConfirmation(slot) },
            onSetLabel: { newLabel in store.setLabel(slot, label: newLabel.isEmpty ? nil : newLabel) },
            onEditText: { newText in store.updateTextSlot(slot, text: newText) },
            onEditHTML: { html in store.updateHTMLSlot(slot, html: html) },
            onDropFiles: { urls in store.importDroppedFiles(urls, toSlot: slot) },
            isLastPasted: store.isLastPasted(slot: slot, groupId: store.currentSpecialSlotId),
            isFlashHighlighted: store.flashHighlightSlot == FlashHighlightTarget(groupId: store.currentSpecialSlotId, slot: slot),
            store: store,
            connectionDotColor: store.portColor(for: slot),
            isConnectionMode: false,
            connectedPorts: [],
            highlightedPort: nil,
            isPortVisible: false,
            onBeginDrag: nil,
            onUpdateDrag: nil,
            onEndDrag: nil
        )
        .opacity(!isSearchActive || isMatched ? 1.0 : 0.22)
        .saturation(!isSearchActive || isMatched ? 1.0 : 0.35)
        .allowsHitTesting(!isSearchActive || isMatched)
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
                        results: globalSearchResultsCache,
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

    /// v2.8.0 (perf M1/M2): recompute the debounced/cached global search results.
    /// Called only when a search input actually changes (text, filter, scope, sort),
    /// not on every view re-render. Text changes are debounced by the caller.
    /// v2.8.7 (F): the cross-page scan (`allSearchableSlots()` reads every group's disk
    /// snapshot) used to run synchronously on the main thread, causing typing lag on
    /// large libraries. It now runs off the main thread; results are applied back on the
    /// main thread and only if the search inputs are still current (stale-query guard).
    private func recomputeGlobalSearchResults() {
        // Capture the current inputs on the main thread.
        let query = searchText
        let filter = selectedFilter
        let scope = searchScope
        let sortRule = globalSearchSortRule

        guard scope == .global, SlotSearchMatcher.isActive(query: query, filter: filter) else {
            globalSearchResultsCache = []
            return
        }

        let store = self.store
        let currentPageId = store.currentPageId
        let currentSpecialSlotId = store.currentSpecialSlotId

        DispatchQueue.global(qos: .userInitiated).async {
            // Heavy cross-page scan + filter + sort runs off the main thread.
            let all = store.allSearchableSlots()
            let results = ContentView.filterAndSortGlobalSearch(
                all: all,
                query: query,
                filter: filter,
                sortRule: sortRule,
                currentPageId: currentPageId,
                currentSpecialSlotId: currentSpecialSlotId
            )
            DispatchQueue.main.async {
                // Stale-query guard: only apply if the inputs haven't changed since
                // this background work was scheduled.
                guard self.searchText == query,
                      self.selectedFilter == filter,
                      self.searchScope == scope,
                      self.globalSearchSortRule == sortRule else { return }
                self.globalSearchResultsCache = results
            }
        }
    }

    /// Schedule a global-search recompute. Keystroke-driven changes are debounced so
    /// the cross-page scan runs once after the user pauses typing; structural changes
    /// (filter/scope/sort) recompute immediately.
    private func scheduleGlobalSearchRecompute(debounced: Bool) {
        searchDebounceWorkItem?.cancel()
        searchDebounceWorkItem = nil

        guard searchScope == .global, isSearchActive else {
            globalSearchResultsCache = []
            return
        }

        if debounced {
            let work = DispatchWorkItem { recomputeGlobalSearchResults() }
            searchDebounceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        } else {
            recomputeGlobalSearchResults()
        }
    }

    /// Pure filter + sort over an already-collected slot list. Static so it can run on a
    /// background thread without touching `@State`/view state (v2.8.7 F).
    private static func filterAndSortGlobalSearch(
        all: [SlotGlobalSearchResult],
        query: String,
        filter: SlotFilterType,
        sortRule: SlotSearchSortRule,
        currentPageId: String,
        currentSpecialSlotId: String
    ) -> [SlotGlobalSearchResult] {
        let filtered = all
            .filter { result in
                SlotSearchMatcher.matches(
                    slot: result.slot,
                    content: result.content,
                    label: result.label,
                    query: query,
                    filter: filter
                )
            }

        switch sortRule {
        case .smart:
            return filtered.sorted { lhs, rhs in
                let lhsCurrentPage = lhs.pageId == currentPageId
                let rhsCurrentPage = rhs.pageId == currentPageId
                if lhsCurrentPage != rhsCurrentPage { return lhsCurrentPage }
                let lhsCurrentGroup = lhs.groupId == currentSpecialSlotId
                let rhsCurrentGroup = rhs.groupId == currentSpecialSlotId
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

// MARK: - v2.7.21 Shortcut Badge

private struct ShortcutBadge: View {
    let title: String
    let shortcut: String
    let icon: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(shortcut)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.045)))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.14), lineWidth: 0.7))
    }
}

// MARK: - v2.7.39 Toolbar Action Button

private struct ToolbarActionButton: View {
    enum Role {
        case normal
        case accent
        case destructive
    }

    let title: String
    let icon: String
    let role: Role
    let prominent: Bool
    let action: () -> Void
    @State private var isHovering = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(minWidth: minWidth, minHeight: 30)
            .padding(.horizontal, 9)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundColor(foregroundColor)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 0.8)
        )
        .shadow(color: shadowColor, radius: prominent ? 4 : 0, x: 0, y: prominent ? 1 : 0)
        .scaleEffect(isHovering ? 1.035 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var minWidth: CGFloat {
        switch role {
        case .normal: return 70
        case .accent: return 92
        case .destructive: return 66
        }
    }

    private var foregroundColor: Color {
        switch role {
        case .normal:
            return .primary
        case .accent, .destructive:
            return .white
        }
    }

    private var backgroundColor: Color {
        switch role {
        case .normal:
            return Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07)
        case .accent:
            return Color.accentColor
        case .destructive:
            return Color.red
        }
    }

    private var borderColor: Color {
        switch role {
        case .normal:
            return Color.secondary.opacity(0.16)
        case .accent:
            return Color.white.opacity(0.22)
        case .destructive:
            return Color.white.opacity(0.20)
        }
    }

    private var shadowColor: Color {
        switch role {
        case .normal:
            return .clear
        case .accent:
            return Color.accentColor.opacity(0.20)
        case .destructive:
            return Color.red.opacity(0.18)
        }
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

// MARK: - v2.7.0 Slot Frame Preference Key

struct SlotFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - v2.7.43 Always-on Poster Ambient Background

private struct RetroPosterAmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            AppTheme.windowBackground(colorScheme)

            Circle()
                .fill(colorScheme == .dark ? Color(red: 0.22, green: 0.27, blue: 0.48).opacity(0.24) : Color(red: 0.70, green: 0.75, blue: 0.88).opacity(0.46))
                .frame(width: 820, height: 820)
                .offset(x: 130, y: -40)
                .blur(radius: 1.5)

            RadialGradient(colors: [Color.red.opacity(colorScheme == .dark ? 0.28 : 0.22), Color.red.opacity(colorScheme == .dark ? 0.12 : 0.08), .clear], center: .center, startRadius: 0, endRadius: 460)
                .frame(width: 720, height: 580)
                .offset(x: -470, y: -230)
                .blur(radius: 50)
                .blendMode(.screen)

            RadialGradient(colors: [Color.white.opacity(colorScheme == .dark ? 0.18 : 0.48), Color.orange.opacity(colorScheme == .dark ? 0.18 : 0.16), .clear], center: .center, startRadius: 0, endRadius: 520)
                .frame(width: 760, height: 580)
                .offset(x: 560, y: -250)
                .blur(radius: 58)
                .blendMode(.screen)

            Rectangle()
                .fill(LinearGradient(colors: [.clear, Color.white.opacity(colorScheme == .dark ? 0.055 : 0.26), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 130)
                .rotationEffect(.degrees(-2.5))
                .offset(y: -210)
                .blur(radius: 32)
                .blendMode(.screen)

            Rectangle()
                .fill(LinearGradient(colors: [.clear, Color.red.opacity(colorScheme == .dark ? 0.08 : 0.06), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 220)
                .rotationEffect(.degrees(5))
                .offset(y: 110)
                .blur(radius: 58)
                .blendMode(.screen)

            RetroPosterGrain(opacity: colorScheme == .dark ? 0.060 : 0.050)
        }
        // v2.8.4 (perf): flatten the whole poster background (base fill + 4 large
        // blur/`.screen` gradient layers + grain) into ONE offscreen GPU texture.
        // Previously CoreAnimation had to composite ~7 blurred/blended layers every
        // frame while the window resized/zoomed, which contributed to the dropped-frame
        // feel. drawingGroup keeps the identical look (screen blends still composite
        // against the base fill inside the group) but collapses the overdraw into a
        // single Metal pass, off the main thread.
        .drawingGroup()
    }
}

private struct RetroPosterGrain: View {
    let opacity: Double

    // v2.8.4 (perf): the grain used to be a full-window `Canvas` that ran a nested
    // per-pixel loop (step=3) over the ENTIRE window on EVERY redraw. During live
    // window resize / title-bar double-click zoom this fired dozens of times per
    // second on the main thread (a maximized window = 200k+ fill() calls per frame),
    // stalling the run loop so the frame lagged behind the mouse and dropped frames.
    // The grain is a purely decorative, static noise texture, so we now rasterize a
    // single tile ONCE (cached) and tile it across the window — resize/zoom becomes a
    // near-free bitmap stretch/tile instead of a main-thread pixel loop.
    var body: some View {
        Image(nsImage: RetroPosterGrain.tileImage)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }

    /// Deterministic noise tile, generated exactly once on first access and reused
    /// for the lifetime of the process. Alpha per pixel matches the old formula
    /// (0.35 + value*0.65); the per-theme `opacity` is applied on the Image so one
    /// tile serves both light and dark modes.
    private static let tileImage: NSImage = makeTile(side: 240, step: 3)

    private static func makeTile(side: CGFloat, step: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        var x: CGFloat = 0
        while x <= side {
            var y: CGFloat = 0
            while y <= side {
                let value = abs(sin(Double(x * 12.9898 + y * 78.233)))
                let alpha = 0.35 + value * 0.65
                NSColor(white: 1, alpha: alpha).setFill()
                NSBezierPath(rect: NSRect(x: x, y: y, width: 1, height: 1)).fill()
                y += step
            }
            x += step
        }
        image.unlockFocus()
        return image
    }
}

// MARK: - v2.7.40 Fullscreen Connection Mode

private struct ConnectionFullscreenView: View {
    @ObservedObject var store: SlotStoreObservable
    var onClose: () -> Void
    var onOpenNodeCanvas: () -> Void
    var onOpenManager: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppTheme.windowBackground(colorScheme),
                    Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.08),
                    AppTheme.windowBackground(colorScheme)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 54, height: 54)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.18), lineWidth: 1))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("连接模式")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("为当前槽位组规划串联路径、模板与批量粘贴顺序")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("完成") { onClose() }
                        .keyboardShortcut(.escape, modifiers: [])
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 34)
                .padding(.top, 28)

                HStack(spacing: 14) {
                    ConnectionMetricCard(title: "当前连接", value: "\(store.currentConnectionMap.edges.count)", icon: "link.circle.fill")
                    ConnectionMetricCard(title: "槽位数量", value: "\(store.config.slots)", icon: "rectangle.grid.2x2.fill")
                    ConnectionMetricCard(title: "当前组", value: store.currentSpecialSlot?.name ?? "默认", icon: "folder.fill")
                }
                .padding(.horizontal, 34)

                HStack(spacing: 16) {
                    ConnectionFullscreenAction(title: "打开节点画布", subtitle: "可视化拖拽连接槽位", icon: "point.3.connected.trianglepath.dotted", tint: .accentColor, action: onOpenNodeCanvas)
                    ConnectionFullscreenAction(title: "应用全串联模板", subtitle: "一键生成 1→2→3…", icon: "list.number", tint: .orange, action: { store.applyBuiltInFullChainTemplate() })
                }
                .padding(.horizontal, 34)

                Spacer()
            }
        }
    }
}

private struct ConnectionMetricCard: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).lineLimit(1)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

private struct ConnectionFullscreenAction: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(tint)
                Text(title).font(.system(size: 17, weight: .bold))
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(tint.opacity(hovering ? 0.45 : 0.18), lineWidth: 1))
            .scaleEffect(hovering ? 1.025 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.76), value: hovering)
    }
}
