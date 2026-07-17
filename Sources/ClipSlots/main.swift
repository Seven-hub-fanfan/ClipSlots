import SwiftUI
import ClipSlotsKit
import Cocoa
import Carbon
import UniformTypeIdentifiers

/// Resolve the virtual key code that produces the letter 'v' on the current keyboard layout.
fileprivate func virtualKeyForCharacterV() -> CGKeyCode {
    guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return 9 }
    guard let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else { return 9 }
    let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data
    guard let keyboardLayout = layoutData.withUnsafeBytes({ $0.bindMemory(to: UCKeyboardLayout.self).baseAddress }) else { return 9 }

    var deadKeyState: UInt32 = 0
    let maxLen = 4
    var actualLen = 0
    var unicodeString = [UniChar](repeating: 0, count: maxLen)

    for keyCode in UInt16(0)..<128 {
        let result = UCKeyTranslate(
            keyboardLayout, keyCode, UInt16(kUCKeyActionDisplay),
            0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState, maxLen, &actualLen, &unicodeString
        )
        if result == noErr, actualLen == 1, unicodeString[0] == 0x0076 { return CGKeyCode(keyCode) }
    }
    return 9
}

// v2.7.33: Do not define slot keyboardShortcut helpers for foreground menu actions.
// All save/paste shortcuts must be owned by AppConfig + RegisterEventHotKey only.

// v2.9.12: request to open the in-app settings overlay (Cmd+, / menu).
extension Notification.Name {
    static let openInAppSettings = Notification.Name("com.clipslots.openInAppSettings")
}

@main
struct ClipSlotsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = SlotStoreObservable()

    // v2.7.54: startup entry must also default to dark.
    // v2.7.47 changed ContentView/SettingsView, but App root still defaulted to
    // system, so first launch could render as light before ContentView appeared.
    @AppStorage("appearanceMode") private var appearanceModeRaw = ThemeMode.dark.rawValue
    private var appearanceMode: ThemeMode { ThemeMode(rawValue: appearanceModeRaw) ?? .dark }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                // v2.9.23: 增大窗口最小尺寸，防止标题栏/应用图标在缩到最小时被挤压变形。
                .frame(minWidth: 720, minHeight: 560)
                .preferredColorScheme(appearanceMode.preferredColorScheme)
                .onAppear {
                    AppearanceDefaults.ensureDefaultDarkIfNeeded()
                    appDelegate.store = store
                    appDelegate.setupHotKeysAfterStoreReady()
                    store.installLocalHotkeyGuardIfNeeded()
                    // v2.9.8: 方案 Y — 每次启动检测辅助功能权限并引导。
                    AccessibilityPermissionGuide.checkAndGuideOnLaunch()
                    // v2.9.30: 启动时静默同步已安装的 Skill，确保各 Agent 用到最新决策流，
                    // 无需用户再手动点「安装 Skill」。onAppear 已在主线程，直接调用即可。
                    AgentSkillInstallManager().syncInstalledSkillsOnLaunch()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        // v2.9.18: 默认窗口 540×420 装不下 10 个卡片（开箱即需滚动）。放大到 1320×820，
        // 配合自适应网格可一屏 5 列 × 2 行完整显示 10 个槽位，无需滚动。
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("关于 ClipSlots") { NSApp.orderFrontStandardAboutPanel(nil) }
            }
            // v2.9.12: settings are now an in-app overlay (not a separate window).
            // Keep Cmd+, working by broadcasting a request the main window observes.
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    NotificationCenter.default.post(name: .openInAppSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // v2.7.26: Ctrl+Z undo for clear/delete operations
            CommandGroup(after: .undoRedo) {
                Button("撤销清空/删除") {
                    store.undoLastClearIfPossible()
                }
                .keyboardShortcut("z", modifiers: [.control])
            }
            // v2.7.32: Do NOT register hard-coded SwiftUI menu shortcuts here.
            // These keyboardShortcut modifiers bypass AppConfig and remain active
            // inside the app window even after global hotkeys are changed.
            // That is the real reason ctrl+option+number kept saving/HUD while the
            // configured shortcut was cmd+option+number.
            CommandMenu("槽位") {
                ForEach(1...store.config.slots, id: \.self) { slot in
                    Button("粘贴槽位 \(slot)") { store.pasteSlot(slot) }
                    Button("保存到槽位 \(slot)") { store.saveToSlot(slot) }
                }
            }
        }
        .onChange(of: NSApplication.shared.keyWindow?.title) { _ in }
    }
}

final class SlotStoreObservable: ObservableObject {
    let instanceID = UUID().uuidString

    // MARK: - v2.7.27 Local Hotkey Guard
    // Global hotkeys were fixed in v2.7.26, but the foreground app window can still
    // receive legacy local key equivalents (Ctrl+Option+number) through SwiftUI/AppKit
    // event handling. Install a local monitor that swallows only legacy shortcuts that
    // are no longer equal to the current config.
    private var localHotkeyMonitor: Any?

    func installLocalHotkeyGuardIfNeeded() {
        guard localHotkeyMonitor == nil else { return }
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // v2.7.30: settings UI is a safe zone. No save/paste/radial hotkey may fire
            // while the user is editing shortcuts, even if the old global/local handler
            // still receives keyDown.
            if self.isSettingsPresented { return event }
            if let responder = NSApp.keyWindow?.firstResponder,
               String(describing: type(of: responder)).contains("ShortcutCaptureTextField") {
                return event
            }
            return self.shouldBlockLegacyLocalHotkey(event) ? nil : event
        }
    }

    private func shouldBlockLegacyLocalHotkey(_ event: NSEvent) -> Bool {
        // v2.7.29: only active config decides behavior. Never infer from any
        // Settings draft text. If current config actually is ctrl+option+{n},
        // allow it; otherwise consume the legacy local event without action/HUD.
        if config.saveKey.lowercased() == "ctrl+option+{n}" { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isLegacySave = flags.contains(.control) && flags.contains(.option) && !flags.contains(.command)
        let isNumber = Int(event.charactersIgnoringModifiers ?? "") != nil
        guard isLegacySave && isNumber else { return false }
        return true
    }

    @Published var config = AppConfig.load()
    @Published var slots: [Int: SlotContent] = [:]
    @Published var labels: [Int: String] = [:]
    @Published var refreshTrigger = UUID()

    // Special slot state
    @Published var specialSlots: [SpecialSlot] = []
    @Published var currentSpecialSlotId: String = "default"  // UI preview layer
    @Published var currentSpecialSlot: SpecialSlot?
    @Published var activeHotkeySpecialSlotId: String = "default"  // Cmd+number hotkey layer
    @Published var activeHotkeySpecialSlot: SpecialSlot?
    @Published var specialSlotSettings: SpecialSlotSettings = .default
    @Published var toastMessage: String?
    @Published var floatingNotice: FloatingNotice?
    @Published var hotkeyRegistrationErrors: [String] = []
    @Published var isSettingsPresented: Bool = false
    @Published var slotRenderTokens: [String: UUID] = [:]
    @Published var isBatchSaving: Bool = false

    // v2.6.7: import options sheet
    @Published var pendingImportSelection: PendingImportSelection?

    // v2.4 Page state
    @Published var pages: [SlotPage] = []
    @Published var currentPageId: String = "default_page"
    @Published var currentPage: SlotPage?

    // v2.7.0: Slot connection state
    @Published var currentConnectionMap: SlotConnectionMap = .empty
    @Published var isConnectionModeEnabled: Bool = false
    @Published var hoveredSlot: Int? = nil
    @Published var activeDragConnection: ActiveDragConnection? = nil
    @Published var hoveredPortTarget: SlotPortTarget? = nil

    /// v2.7.0: Whether slot connection feature is enabled in settings
    var isSlotConnectionEnabled: Bool {
        if UserDefaults.standard.object(forKey: UserPreferenceKeys.enableSlotConnection) == nil {
            return true // default enabled
        }
        return UserDefaults.standard.bool(forKey: UserPreferenceKeys.enableSlotConnection)
    }

    /// Slot groups belonging to the current page, sorted by order.
    var currentPageSlotGroups: [SpecialSlot] {
        specialSlots.filter { $0.pageId == currentPageId }.sorted { $0.order < $1.order }
    }

    var lastNonClipSlotsApp: NSRunningApplication?

    var onConfigChanged: (() -> Void)?

    let specialStorage = SpecialSlotStorage.shared
    private let clipboard = ClipboardManager.shared

    /// Cancellable delayed clipboard restore to prevent race with copy/save.
    private var pendingClipboardRestore: DispatchWorkItem?
    private var pendingClipboardRestoreContent: SlotContent?

    /// Pending paste keystroke work item. Cancelled when switching special slots.
    private var pendingPasteWorkItem: DispatchWorkItem?

    /// v2.8.1 (P0-1): monotonically increasing token identifying the current
    /// sequential-paste run. Each scheduled recursion step captures the token it
    /// was started with; if a newer sequence (or a cancel) bumps this value, the
    /// stale step becomes a no-op, so two sequences can never interleave keystrokes.
    private var pasteSequenceGeneration = 0
    /// Clipboard snapshot captured for the in-flight sequence, so a superseding
    /// sequence / cancel can restore it before starting fresh.
    private var inFlightSequencePrevious: SlotContent?
    /// Temp image files spilled for the in-flight sequence, cleaned on supersede.
    private var inFlightSequenceTempFiles: [URL] = []

    /// The special slot id that current in-memory `slots` / `labels` belong to.
    private var loadedSpecialSlotId: String?

    // MARK: - v2.9.4 (Feature #2) Live disk refresh
    /// FSEvents watcher on the storage base dir. External (CLI / other GUI) writes
    /// trigger a debounced `reloadAll()` so the UI reflects disk changes without a
    /// manual group switch or restart.
    private var storageWatcher: StorageDirectoryWatcher?
    /// Debounces bursts of FSEvents into a single reload.
    private var watcherDebounceWorkItem: DispatchWorkItem?
    /// Self-write suppression: bumped to `now + 0.6s` right before every
    /// GUI-initiated disk write. If the debounced watcher handler fires while
    /// `Date() < ignoreWatcherUntil`, the reload is skipped — this prevents a
    /// reload loop/storm from the GUI's OWN writes while still reacting promptly
    /// to genuinely external writes.
    private var ignoreWatcherUntil: Date = .distantPast

    init() {
        NSLog("[ClipSlots] SlotStoreObservable init instanceID=\(instanceID)")
        loadSpecialSlots()
        loadSlots()
        loadPersistedUndoSnapshot() // v2.9.5 (Feature #3): restore pending undo across restarts
        setupStorageWatcher()
    }

    deinit {
        storageWatcher?.stop()
        storageWatcher = nil
    }

    // MARK: - v2.9.4 Storage Watcher (Feature #2)

    private func setupStorageWatcher() {
        let base = ClipSlotsPaths.specialSlots
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let watcher = StorageDirectoryWatcher(path: base.path) { [weak self] in
            self?.handleStorageChange()
        }
        watcher.start()
        storageWatcher = watcher
    }

    /// Called on the watcher's background queue for every FSEvents batch.
    /// Debounces ~300ms, then reloads on the main queue (unless self-write suppressed).
    private func handleStorageChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.watcherDebounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if Date() < self.ignoreWatcherUntil {
                    NSLog("[ClipSlots] watcher fired → suppressed (self-write)")
                    return
                }
                NSLog("[ClipSlots] watcher fired → reloadAll")
                // v2.9.15 (fix): an external write (the `clipslots` CLI) changed
                // slot bodies on disk. SlotStorage.get() is cache-backed and would
                // otherwise keep returning the stale in-memory SlotContent, so the
                // body stayed "空槽位 0 B" even though the label (read from disk
                // directly) updated. Drop the content caches so reloadAll re-reads
                // the freshly written bodies from disk.
                self.specialStorage.invalidateContentCaches()
                self.reloadAll()
                self.refreshTrigger = UUID()
            }
            self.watcherDebounceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    /// Bump the suppression window right before a GUI-initiated disk write so the
    /// resulting FSEvents callback does not trigger a redundant `reloadAll()`.
    /// A single timestamp (rather than per-method bool flags) is simpler and safe
    /// as long as it is bumped at every GUI write entry point.
    func suppressWatcher(_ interval: TimeInterval = 0.6) {
        ignoreWatcherUntil = Date().addingTimeInterval(interval)
    }

    // MARK: - Special Slots

    func loadSpecialSlots() {
        let index = specialStorage.loadIndex()

        // v2.4: load pages
        pages = index.pages
        currentPageId = index.currentPageId.isEmpty ? (index.pages.first?.id ?? "default_page") : index.currentPageId
        currentPage = index.pages.first { $0.id == currentPageId }

        specialSlots = index.specialSlots

        let fallbackId = index.specialSlots.first?.id ?? "default"

        let selectedId = index.selectedSpecialSlotId ?? index.currentSpecialSlotId
        let activeId = index.activeHotkeySpecialSlotId ?? index.currentSpecialSlotId

        // If the persisted id no longer exists (e.g. after a delete), fall back.
        let validSelectedId = index.specialSlots.contains(where: { $0.id == selectedId }) ? selectedId : fallbackId
        let validActiveId = index.specialSlots.contains(where: { $0.id == activeId }) ? activeId : fallbackId

        currentSpecialSlotId = validSelectedId
        currentSpecialSlot = index.specialSlots.first { $0.id == validSelectedId }

        activeHotkeySpecialSlotId = validActiveId
        activeHotkeySpecialSlot = index.specialSlots.first { $0.id == validActiveId }

        specialSlotSettings = index.settings
    }

    func reloadAll() {
        loadSpecialSlots()
        loadSlots()
        loadConnectionMapForCurrentGroup()
    }

    func switchSpecialSlot(id: String) {
        selectAndActivateSpecialSlot(id: id)
    }

    // MARK: - Preview / Activate (Layer model)

    /// Click a tag: preview only, does NOT change Cmd+number binding.
    func selectSpecialSlotForPreview(id: String) {
        guard id != currentSpecialSlotId else { return }

        guard specialSlots.contains(where: { $0.id == id }) else { return }

        let oldId = currentSpecialSlotId
        NSLog("[ClipSlots] selectSpecialSlotForPreview from=\(oldId) to=\(id) activeHotkey=\(activeHotkeySpecialSlotId)")

        cancelPendingPasteOperations(restoreClipboard: true)

        ThumbnailProvider.shared.invalidateSpecialSlot(specialSlotId: oldId)

        slots = [:]
        labels = [:]
        loadedSpecialSlotId = nil

        currentSpecialSlotId = id
        currentSpecialSlot = specialSlots.first { $0.id == id }

        suppressWatcher() // v2.9.4 (#2): self-write
        specialStorage.updateSelectedSpecialSlot(id: id)

        loadSlots()
        loadConnectionMapForCurrentGroup()
        refreshTrigger = UUID()

        showToast("已预览「\(currentSpecialSlot?.name ?? id)」")
    }

    /// Activate this special slot as the Cmd+number hotkey layer.
    func activateSpecialSlotForHotkeys(id: String) {
        guard specialSlots.contains(where: { $0.id == id }) else { return }

        let oldId = activeHotkeySpecialSlotId
        guard id != oldId else { return }

        NSLog("[ClipSlots] activateSpecialSlotForHotkeys from=\(oldId) to=\(id)")

        cancelPendingPasteOperations(restoreClipboard: true)

        // The hotkey layer is now bound to a different special slot.
        // Invalidate cached thumbnails for the old layer so stale async callbacks
        // don't write into the wrong UI.
        ThumbnailProvider.shared.invalidateSpecialSlot(specialSlotId: oldId)

        activeHotkeySpecialSlotId = id
        activeHotkeySpecialSlot = specialSlots.first { $0.id == id }

        suppressWatcher() // v2.9.4 (#2): self-write
        try? specialStorage.updateActiveHotkeySpecialSlot(id: id)

        refreshTrigger = UUID()
        showToast("Cmd+数字 已切换至「\(activeHotkeySpecialSlot?.name ?? id)」")
    }

    /// Preview AND activate: both UI and Cmd+number switch to this slot.
    /// v2.4: also switches to the page that owns this slot group.
    func selectAndActivateSpecialSlot(id: String) {
        guard id != currentSpecialSlotId || id != activeHotkeySpecialSlotId else { return }
        guard specialSlots.contains(where: { $0.id == id }) else { return }

        let oldPreview = currentSpecialSlotId
        let oldActive = activeHotkeySpecialSlotId
        NSLog("[ClipSlots] selectAndActivateSpecialSlot preview:\(oldPreview)->\(id) hotkey:\(oldActive)->\(id)")

        cancelPendingPasteOperations(restoreClipboard: true)

        ThumbnailProvider.shared.invalidateSpecialSlot(specialSlotId: oldPreview)

        slots = [:]
        labels = [:]
        loadedSpecialSlotId = nil
        refreshTrigger = UUID()

        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.switchToSpecialSlot(id: id)
        } catch {
            NSLog("[ClipSlots] selectAndActivateSpecialSlot save failed: \(error)")
        }

        let index = specialStorage.loadIndex()

        // v2.4: sync page state
        pages = index.pages
        currentPageId = index.currentPageId
        currentPage = index.pages.first { $0.id == currentPageId }

        currentSpecialSlotId = id
        currentSpecialSlot = index.specialSlots.first { $0.id == id }
        activeHotkeySpecialSlotId = id
        activeHotkeySpecialSlot = index.specialSlots.first { $0.id == id }
        specialSlots = index.specialSlots
        specialSlotSettings = index.settings

        loadSlots()
        loadConnectionMapForCurrentGroup()
        refreshTrigger = UUID()

        showToast("已切换至「\(currentSpecialSlot?.name ?? id)」")
    }

    func createSpecialSlot(name: String) {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            let slot = try specialStorage.createSpecialSlot(name: name)
            try specialStorage.switchToSpecialSlot(id: slot.id)
            reloadAll()
            refreshTrigger = UUID()
        } catch SpecialSlotError.duplicateName {
            // v2.9.4 (Feature #4): same-page duplicate names are rejected. Show a
            // non-fatal HUD instead of crashing / force-unwrapping.
            NSLog("[ClipSlots] createSpecialSlot rejected: duplicate name '\(name)'")
            showFloatingNotice(FloatingNotice(
                title: "名称重复",
                subtitle: "当前页面已存在「\(name.trimmingCharacters(in: .whitespacesAndNewlines))」，请换个名字",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
        } catch {
            NSLog("[ClipSlots] createSpecialSlot error: \(error)")
            showFloatingNotice(FloatingNotice(
                title: "创建槽位组失败",
                subtitle: error.localizedDescription,
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
        }
    }

    /// Quick-create a special slot with an auto-numbered name and switch to it.
    func createQuickSpecialSlot() {
        let next = nextAvailableSpecialSlotNumber()
        createSpecialSlot(name: "\(next)")
    }

    private func nextAvailableSpecialSlotNumber() -> Int {
        // v2.4.1: auto-number based on current page's slot groups only
        let existing = Set(currentPageSlotGroups.compactMap { Int($0.name) })
        for i in 1...specialSlotSettings.maxSpecialSlots {
            if !existing.contains(i) { return i }
        }
        return currentPageSlotGroups.count + 1
    }

    func deleteSpecialSlot(id: String) {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.deleteSpecialSlot(id: id)
            reloadAll()
            refreshTrigger = UUID()
        } catch {
            NSLog("[ClipSlots] deleteSpecialSlot error: \(error)")
        }
    }

    func renameSpecialSlot(id: String, name: String) {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.renameSpecialSlot(id: id, name: name)
            loadSpecialSlots()
        } catch {
            NSLog("[ClipSlots] renameSpecialSlot error: \(error)")
        }
    }

    // MARK: - Page Operations (v2.4)

    func createPage(name: String) {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            let page = try specialStorage.createPage(name: name).page
            try specialStorage.switchToPage(id: page.id)
            reloadAll()
            showToast("已创建页面「\(page.name)」")
        } catch {
            NSLog("[ClipSlots] createPage error: \(error)")
            showAlert(message: "创建页面失败: \(error.localizedDescription)")
        }
    }

    func renamePage(id: String, name: String) {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.renamePage(id: id, name: name)
            loadSpecialSlots()
            showToast("页面已重命名")
        } catch {
            NSLog("[ClipSlots] renamePage error: \(error)")
            showAlert(message: "重命名失败: \(error.localizedDescription)")
        }
    }

    func deletePage(id: String) {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.deletePage(id: id)
            reloadAll()
            showToast("页面已删除")
        } catch {
            NSLog("[ClipSlots] deletePage error: \(error)")
            showAlert(message: "删除页面失败: \(error.localizedDescription)")
        }
    }

    func switchToPage(id: String) {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.switchToPage(id: id)
            reloadAll()
            if let page = pages.first(where: { $0.id == id }) {
                showToast("已切换至「\(page.name)」")
            }
        } catch {
            NSLog("[ClipSlots] switchToPage error: \(error)")
        }
    }

    // v2.4.1: Cmd+Left / Cmd+Right — cycle through slot groups in current page
    func switchToPreviousSlotGroup() {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.switchToAdjacentSpecialSlot(direction: .previous)
            reloadAll()
            refreshTrigger = UUID()
            if let name = currentSpecialSlot?.name {
                showToast("已切换至「\(name)」")
            }
        } catch {
            NSLog("[ClipSlots] switchToPreviousSlotGroup error: \(error)")
        }
    }

    func switchToNextSlotGroup() {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.switchToAdjacentSpecialSlot(direction: .next)
            reloadAll()
            refreshTrigger = UUID()
            if let name = currentSpecialSlot?.name {
                showToast("已切换至「\(name)」")
            }
        } catch {
            NSLog("[ClipSlots] switchToNextSlotGroup error: \(error)")
        }
    }

    // MARK: - v2.9.31 Auto-Advance After Paste
    //
    // When the "自动切换" toggle is on, pasting the LAST non-empty slot of the
    // current group automatically switches focus + selection to the next group
    // (or the first group of the next page). It never wraps: the last group of
    // the last page simply stays put. When the toggle is off, paste behavior is
    // completely unchanged.

    var isAutoAdvanceEnabled: Bool {
        UserDefaults.standard.bool(forKey: UserPreferenceKeys.autoAdvanceAfterPaste)
    }

    /// Index of the last non-empty slot in the given group, or nil if the group is empty.
    private func lastNonEmptySlot(in specialSlotId: String) -> Int? {
        var last: Int? = nil
        for slot in 1...config.slots where !specialStorage.get(slot, in: specialSlotId).isEmpty {
            last = slot
        }
        return last
    }

    /// Resolve the group we should auto-advance to after finishing `currentGroupId`.
    /// Returns nil when there is nowhere to go (last group of the last page).
    private func autoAdvanceTargetGroupId(from currentGroupId: String) -> String? {
        guard let currentGroup = specialSlots.first(where: { $0.id == currentGroupId }) else { return nil }
        let pageId = currentGroup.pageId

        let groupsInPage = specialSlots
            .filter { $0.pageId == pageId }
            .sorted { $0.order < $1.order }

        if let idx = groupsInPage.firstIndex(where: { $0.id == currentGroupId }),
           idx < groupsInPage.count - 1 {
            // There is a next group within the same page.
            return groupsInPage[idx + 1].id
        }

        // Current group is the last one in its page — move to the next page's first group.
        let sortedPages = pages.sorted { $0.order < $1.order }
        guard let pageIdx = sortedPages.firstIndex(where: { $0.id == pageId }),
              pageIdx < sortedPages.count - 1 else {
            return nil // last page + last group → stop, no wrap.
        }

        let nextPageId = sortedPages[pageIdx + 1].id
        let nextPageGroups = specialSlots
            .filter { $0.pageId == nextPageId }
            .sorted { $0.order < $1.order }
        return nextPageGroups.first?.id
    }

    /// Called after a paste finishes. If auto-advance is enabled and `slot` was the
    /// last non-empty slot of `specialSlotId`, switch to the next group/page
    /// immediately (v2.9.33: no more 0.5s delay) with a subtle animation and a
    /// lightweight toast telling the user where it jumped to.
    func maybeAutoAdvance(afterPasting slot: Int, in specialSlotId: String) {
        guard isAutoAdvanceEnabled else { return }
        guard let last = lastNonEmptySlot(in: specialSlotId), slot == last else { return }
        guard let targetId = autoAdvanceTargetGroupId(from: specialSlotId) else {
            NSLog("[ClipSlots] autoAdvance: reached last group of last page, staying put")
            return
        }

        // v2.9.33: guard against the user having manually switched groups already.
        guard currentSpecialSlotId == specialSlotId
                || activeHotkeySpecialSlotId == specialSlotId else {
            NSLog("[ClipSlots] autoAdvance: group changed before advance fired, skipping")
            return
        }

        // Resolve whether this advance crosses a page boundary, and the display names,
        // BEFORE switching so we can craft the right toast message.
        let fromPageId = specialSlots.first(where: { $0.id == specialSlotId })?.pageId
        let targetGroup = specialSlots.first(where: { $0.id == targetId })
        let targetGroupName = targetGroup?.name ?? "下一组"
        let crossedPage = targetGroup?.pageId != nil && targetGroup?.pageId != fromPageId
        let targetPageName = pages.first(where: { $0.id == targetGroup?.pageId })?.name ?? "下一页"

        NSLog("[ClipSlots] autoAdvance: slot=\(slot) is last non-empty in \(specialSlotId), advancing to \(targetId) immediately")

        withAnimation(.easeInOut(duration: 0.28)) {
            self.switchSpecialSlot(id: targetId)
        }

        // v2.9.33: override the generic "已切换至" toast from switchSpecialSlot with a
        // dedicated auto-advance message that stays ~1.5s.
        let message = crossedPage
            ? "已跳转到下一页 · \(targetPageName)"
            : "已切换到「\(targetGroupName)」"
        showToast(message, duration: 1.5)
    }

    // MARK: - Delete Special Slot with Confirmation

    func deleteSpecialSlotWithConfirmation(id: String) {
        guard let target = specialSlots.first(where: { $0.id == id }) else { return }

        if specialSlotSettings.confirmBeforeDeleteSpecialSlot {
            let alert = NSAlert()
            alert.messageText = "删除槽位组？"
            alert.informativeText = "将删除槽位组「\(target.name)」及其全部槽位内容。此操作会移动到回收目录。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")

            let checkbox = NSButton(checkboxWithTitle: "不再提醒", target: nil, action: nil)
            alert.accessoryView = checkbox

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }

            if checkbox.state == .on {
                do {
                    try specialStorage.updateSettings { $0.confirmBeforeDeleteSpecialSlot = false }
                    specialSlotSettings.confirmBeforeDeleteSpecialSlot = false
                } catch {
                    NSLog("[ClipSlots] update confirmBeforeDeleteSpecialSlot failed: \(error)")
                }
            }
        }

        deleteSpecialSlot(id: id)
    }

    // MARK: - Clear All Slots

    // MARK: - v2.7.26 Undo Clear

    // v2.9.5 (Feature #3): the clear/delete undo snapshot is now Codable and
    // persisted to disk so a pending undo survives an app restart.
    private struct SlotUndoSnapshot: Codable {
        let slots: [Int: SlotContent]
        let labels: [Int: String]
        let title: String
        // v2.8.7 (D): remember which group the snapshot belongs to so Undo cannot
        // restore into a different (wrong) group after the user switches groups.
        let specialSlotId: String
    }
    private var lastClearSnapshot: SlotUndoSnapshot?

    // v2.9.5 (Feature #3): on-disk location for the persisted undo snapshot. Lives
    // alongside the special-slot storage so it shares the same lifecycle/backups.
    private var undoSnapshotURL: URL {
        ClipSlotsPaths.specialSlots.appendingPathComponent(".undo/clear_snapshot.json")
    }

    /// Write (or, when nil, delete) the persisted undo snapshot. Never throws — a
    /// persistence failure must not break the clear/undo operation itself.
    private func persistUndoSnapshot(_ snapshot: SlotUndoSnapshot?) {
        let url = undoSnapshotURL
        let fm = FileManager.default
        guard let snapshot else {
            try? fm.removeItem(at: url)
            return
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[ClipSlots] persist undo snapshot failed: \(error)")
        }
    }

    /// Load a previously persisted undo snapshot into memory at launch, so the
    /// most recent clear/delete remains undoable after a restart.
    private func loadPersistedUndoSnapshot() {
        guard let data = try? Data(contentsOf: undoSnapshotURL),
              let snapshot = try? JSONDecoder().decode(SlotUndoSnapshot.self, from: data) else {
            return
        }
        lastClearSnapshot = snapshot
        NSLog("[ClipSlots] restored persisted undo snapshot: \(snapshot.title)")
    }

    private func captureUndoSnapshot(title: String) {
        lastClearSnapshot = SlotUndoSnapshot(slots: slots, labels: labels, title: title, specialSlotId: currentSpecialSlotId)
        // v2.9.5 (Feature #3): persist immediately so the undo survives a restart.
        persistUndoSnapshot(lastClearSnapshot)
    }

    func undoLastClearIfPossible() {
        guard let snapshot = lastClearSnapshot else {
            showFloatingNotice(FloatingNotice(title: "没有可撤销操作", subtitle: "最近没有清空或删除槽位", iconName: "arrow.uturn.backward", kind: .warning))
            return
        }
        // v2.8.7 (D): the snapshot must be restored into the same group it was
        // captured from; otherwise Undo would corrupt whatever group is now active.
        guard snapshot.specialSlotId == currentSpecialSlotId else {
            showFloatingNotice(FloatingNotice(title: "无法撤销", subtitle: "请切回原分组后再撤销", iconName: "arrow.uturn.backward", kind: .warning))
            return
        }
        slots = snapshot.slots
        labels = snapshot.labels
        persistCurrentSpecialSlotData()
        lastClearSnapshot = nil
        // v2.9.5 (Feature #3): consume the persisted snapshot so it cannot be
        // replayed after the next restart.
        persistUndoSnapshot(nil)
        showFloatingNotice(FloatingNotice(title: "已撤销", subtitle: snapshot.title, iconName: "arrow.uturn.backward.circle.fill", kind: .success))
    }

    private func persistCurrentSpecialSlotData() {
        suppressWatcher() // v2.9.4 (#2): our own write — don't let it trigger a reload
        let activeId = currentSpecialSlotId
        for (slot, content) in slots {
            specialStorage.set(slot, content: content, in: activeId)
        }
        for (slot, label) in labels {
            specialStorage.setLabel(slot, label: label, in: activeId)
        }
    }

    // MARK: - v2.7.33 HTML Source Preservation
    // public.html copied from Feishu/Lark is rich HTML. Previous versions stored
    // only '[HTML]' preview + extracted plain text, so preview/edit could never
    // render the original button/chip UI again. Store original HTML separately.
    func saveHTMLToSlot(_ slot: Int, html: String, plainText: String? = nil) {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var content = SlotContent(text: plainText?.isEmpty == false ? plainText! : html)
        content.htmlSource = html
        // v2.7.74: preserve existing attachments when updating slot content.
        // v2.8.7 (A): read via contentForSlot so disk-backed attachments survive a cache miss.
        content.attachments = contentForSlot(slot).attachments
        slots[slot] = content
        persistCurrentSpecialSlotData()
        refreshTrigger = UUID()
        showFloatingNotice(FloatingNotice(title: "已保存 HTML", subtitle: "槽位 \(slot)", iconName: "doc.richtext", kind: .success))
    }

    func updateHTMLSlot(_ slot: Int, html: String) {
        var content = slots[slot] ?? SlotContent(text: html)
        content.htmlSource = html
        // v2.8.0 (P1-1): explicitly carry over existing attachments so editing the
        // HTML source of a slot never silently drops its attachments.
        // v2.8.7 (A): read via contentForSlot so disk-backed attachments survive a cache miss.
        content.attachments = contentForSlot(slot).attachments
        slots[slot] = content
        persistCurrentSpecialSlotData()
        refreshTrigger = UUID()
    }

    // MARK: - v2.7.27 Text Edit / Drag File Import

    func updateTextSlot(_ slot: Int, text: String) {
        let data = text.data(using: .utf8) ?? Data()
        let item = PasteboardItem(type: "public.utf8-plain-text", data: data)
        var content = SlotContent()
        content.items = [[item]]
        content.timestamp = Date()
        // v2.7.74 BUGFIX: editing a slot's text used to build a fresh SlotContent()
        // and overwrite the whole record, silently dropping the slot's attachments.
        // Carry the existing attachments over so editing content keeps them.
        // v2.8.7 (A): read via contentForSlot so disk-backed attachments survive a cache miss.
        content.attachments = contentForSlot(slot).attachments
        slots[slot] = content
        persistCurrentSpecialSlotData()
        showFloatingNotice(FloatingNotice(title: "已更新文本", subtitle: "槽位 \(slot)", iconName: "pencil.circle.fill", kind: .success))
    }

    func importDroppedFiles(_ urls: [URL], toSlot slot: Int) {
        guard let first = urls.first else { return }
        for (offset, url) in urls.enumerated() {
            let target = slot + offset
            guard target <= config.slots else { break }
            var newContent = folderImportService.makeSlotContent(for: url)
            // v2.7.74: preserve existing attachments when replacing slot content.
            newContent.attachments = slots[target]?.attachments ?? []
            slots[target] = newContent
        }
        persistCurrentSpecialSlotData()
        showFloatingNotice(FloatingNotice(title: "已导入文件", subtitle: urls.count == 1 ? first.lastPathComponent : "\(urls.count) 个文件", iconName: "folder.badge.plus", kind: .success))
    }

    func clearAllSlotsInCurrentSpecialSlotWithConfirmation() {
        captureUndoSnapshot(title: "清空槽位组「\(currentSpecialSlot?.name ?? currentSpecialSlotId)」")
        if !specialSlotSettings.confirmBeforeClearAllSlots {
            clearAllSlotsInCurrentSpecialSlot()
            return
        }

        let alert = NSAlert()
        alert.messageText = "清空当前槽位组？"
        alert.informativeText = "将清空「\(currentSpecialSlot?.name ?? "当前槽位组")」中的全部槽位内容。此操作不会删除槽位组本身。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")

        let checkbox = NSButton(checkboxWithTitle: "不再提醒", target: nil, action: nil)
        alert.accessoryView = checkbox

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if checkbox.state == .on {
            do {
                try specialStorage.updateSettings { $0.confirmBeforeClearAllSlots = false }
                specialSlotSettings.confirmBeforeClearAllSlots = false
            } catch {
                NSLog("[ClipSlots] update confirmBeforeClearAllSlots failed: \(error)")
            }
        }

        clearAllSlotsInCurrentSpecialSlot()
    }

    func clearAllSlotsInCurrentSpecialSlot() {
        let activeId = currentSpecialSlotId
        suppressWatcher() // v2.9.4 (#2): self-write
        cancelPendingClipboardRestore()

        ThumbnailProvider.shared.invalidateSpecialSlot(specialSlotId: activeId)

        do {
            // write guard removed (no timer)
            // defer removed (no timer)

            try specialStorage.clearAllSlots(in: activeId)

            var emptySlots: [Int: SlotContent] = [:]
            for slot in 1...config.slots {
                emptySlots[slot] = SlotContent()
            }

            slots = emptySlots
            labels = [:]
            loadedSpecialSlotId = activeId
            refreshTrigger = UUID()

            NSLog("[ClipSlots] CLEAR ALL specialSlot=\(activeId)")
        } catch {
            NSLog("[ClipSlots] CLEAR ALL failed specialSlot=\(activeId) error=\(error)")
            showAlert(message: "清空失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Paste All Slots

    private func orderedNonEmptySlots() -> [(slot: Int, content: SlotContent)] {
        (1...config.slots).compactMap { slot in
            let content = contentForSlot(slot)
            return content.isEmpty ? nil : (slot, content)
        }
    }

    // v2.7.58: radial group-hover preview support.
    func firstNonEmptySlotContent(pageId: String, specialSlotId: String) -> SlotContent? {
        for slot in 1...config.slots {
            let content = specialStorage.get(slot, in: specialSlotId)
            if !content.isEmpty { return content }
        }
        return nil
    }

    // v2.7.59: right-top realtime preview needs both content and its original slot.
    func firstNonEmptySlotSnapshot(pageId: String, specialSlotId: String) -> (slot: Int, content: SlotContent)? {
        for slot in 1...config.slots {
            let content = specialStorage.get(slot, in: specialSlotId)
            if !content.isEmpty { return (slot, content) }
        }
        return nil
    }

    func pasteAllSlotsWithConfirmation() {
        let items = orderedNonEmptySlots()

        guard !items.isEmpty else {
            showAlert(message: "当前槽位组没有可粘贴的内容")
            return
        }

        if specialSlotSettings.confirmBeforePasteAllSlots {
            let alert = NSAlert()
            alert.messageText = "按序粘贴全部槽位？"
            alert.informativeText = "将按 1 到 \(config.slots) 的顺序，粘贴「\(currentSpecialSlot?.name ?? currentSpecialSlotId)」中的 \(items.count) 个非空槽位。"
            alert.addButton(withTitle: "开始粘贴")
            alert.addButton(withTitle: "取消")

            let checkbox = NSButton(checkboxWithTitle: "不再提醒", target: nil, action: nil)
            alert.accessoryView = checkbox

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }

            if checkbox.state == .on {
                do {
                    try specialStorage.updateSettings { $0.confirmBeforePasteAllSlots = false }
                    specialSlotSettings.confirmBeforePasteAllSlots = false
                } catch {
                    NSLog("[ClipSlots] update confirmBeforePasteAllSlots failed: \(error)")
                }
            }
        }

        pasteAllSlotsFromUI()
    }

    func pasteAllSlotsFromUI() {
        guard let target = lastNonClipSlotsApp else {
            showAlert(message: "没有可粘贴的目标应用。请先切换到目标应用后再试。")
            return
        }
        pasteAllSlotsToApp(targetApp: target)
    }

    func pasteAllSlotsToApp(targetApp: NSRunningApplication?) {
        let items = orderedNonEmptySlots()

        guard !items.isEmpty else {
            NSLog("[ClipSlots] pasteAll ignored: no content specialSlot=\(currentSpecialSlotId)")
            return
        }

        guard AXIsProcessTrusted() else {
            promptAccessibilityPermissionIfNeeded()
            return
        }

        cancelPendingClipboardRestore()

        let cleanTarget: NSRunningApplication?
        if isSelfApp(targetApp) {
            cleanTarget = lastNonClipSlotsApp
        } else {
            cleanTarget = targetApp ?? lastNonClipSlotsApp
        }

        let previous = clipboard.capture()

        let startSequence = { [weak self] in
            guard let self = self else { return }
            self.pasteItemsSequentially(items, index: 0, previousClipboard: previous)
        }

        if let app = cleanTarget {
            app.activate(options: [.activateIgnoringOtherApps])
            waitUntilFrontmost(app, timeout: 1.2) { success in
                NSLog("[ClipSlots] pasteAll waitUntilFrontmost success=\(success)")
                startSequence()
            }
        } else {
            startSequence()
        }
    }

    private func pasteItemsSequentially(
        _ items: [(slot: Int, content: SlotContent)],
        index: Int,
        previousClipboard: SlotContent
    ) {
        guard index < items.count else {
            let restoreWorkItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                _ = self.clipboard.restore(previousClipboard)
                self.pendingClipboardRestore = nil
                self.pendingClipboardRestoreContent = nil
            }
            pendingClipboardRestoreContent = previousClipboard
            pendingClipboardRestore = restoreWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)
            NSLog("[ClipSlots] pasteAll completed specialSlot=\(currentSpecialSlotId) count=\(items.count)")
            return
        }

        let item = items[index]

        guard clipboard.restore(item.content) else {
            NSLog("[ClipSlots] pasteAll restore failed slot=\(item.slot)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.pasteItemsSequentially(items, index: index + 1, previousClipboard: previousClipboard)
            }
            return
        }

        NSLog("[ClipSlots] pasteAll paste specialSlot=\(currentSpecialSlotId) slot=\(item.slot) index=\(index) preview=\(item.content.preview)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self = self else { return }
            self.sendPasteKeystroke()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.pasteItemsSequentially(items, index: index + 1, previousClipboard: previousClipboard)
            }
        }
    }

    // MARK: - Slot Loading

    func loadSlots() {
        let activeId = currentSpecialSlotId
        NSLog("[ClipSlots] loadSlots activeSpecialSlotId=\(activeId)")
        var result: [Int: SlotContent] = [:]
        var labelMap: [Int: String] = [:]
        for slot in 1...config.slots {
            result[slot] = specialStorage.get(slot, in: activeId)
            if let label = specialStorage.getLabel(slot, in: activeId), !label.isEmpty {
                labelMap[slot] = label
            }
        }
        slots = result
        labels = labelMap
        loadedSpecialSlotId = activeId
    }

    // MARK: - Helpers

    /// Show a transient toast message that auto-dismisses after 1.2s.
    private func showToast(_ message: String, duration: TimeInterval = 1.2) {
        toastMessage = message
        let captured = message
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.toastMessage == captured {
                self?.toastMessage = nil
            }
        }
    }

    /// v2.6.2: Show a floating notice with icon/title/subtitle, auto-dismiss.
    func showFloatingNotice(_ notice: FloatingNotice, duration: TimeInterval = 2.0) {
        floatingNotice = notice
        // v2.6.3: Also show global HUD so the notice is visible when
        // ClipSlots main window is not in front (e.g. hotkey save from Finder).
        FloatingNoticeWindowController.shared.show(notice: notice, duration: duration)
        let noticeId = notice.id
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.floatingNotice?.id == noticeId {
                self?.floatingNotice = nil
            }
        }
    }

    /// v2.7.2: Public accessor for node canvas.
    func slotContent(for slot: Int) -> SlotContent {
        contentForSlot(slot)
    }

    /// Returns slot content: in-memory state first (only if it belongs to current special slot), fallback to disk.
    private func contentForSlot(_ slot: Int) -> SlotContent {
        let activeId = currentSpecialSlotId

        // Only trust memory cache if it belongs to the currently active special slot.
        if loadedSpecialSlotId == activeId, let inMemory = slots[slot], !inMemory.isEmpty {
            NSLog("[ClipSlots] contentForSlot memory specialSlot=\(activeId) slot=\(slot) preview=\(inMemory.preview)")
            return inMemory
        }

        let stored = specialStorage.get(slot, in: activeId)
        NSLog("[ClipSlots] contentForSlot storage specialSlot=\(activeId) slot=\(slot) preview=\(stored.preview) loadedSpecialSlotId=\(loadedSpecialSlotId ?? "nil")")
        return stored
    }

    // MARK: - v2.7.65 Slot Attachments (node canvas)

    /// Attachments of a slot in the currently active group.
    func attachments(for slot: Int) -> [SlotContent.SlotAttachment] {
        specialStorage.get(slot, in: currentSpecialSlotId).attachments
    }

    /// Persist the attachment list for a slot in the currently active group and
    /// refresh in-memory state so the node canvas updates immediately.
    func setAttachments(_ attachments: [SlotContent.SlotAttachment], for slot: Int) {
        let activeId = currentSpecialSlotId
        suppressWatcher() // v2.9.4 (#2): self-write
        var content = specialStorage.get(slot, in: activeId)
        content.attachments = attachments
        _ = specialStorage.set(slot, content: content, in: activeId)
        if loadedSpecialSlotId == activeId {
            slots[slot] = content
        }
        refreshTrigger = UUID()
    }

    private func isSelfApp(_ app: NSRunningApplication?) -> Bool {
        guard let app = app else { return false }
        return app.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func cancelPendingClipboardRestore(restoreImmediately: Bool = true) {
        if restoreImmediately, let content = pendingClipboardRestoreContent {
            _ = clipboard.restore(content)
        }
        pendingClipboardRestoreContent = nil
        pendingClipboardRestore?.cancel()
        pendingClipboardRestore = nil
    }

    private func cancelPendingPasteOperations(restoreClipboard: Bool = true) {
        pendingPasteWorkItem?.cancel()
        pendingPasteWorkItem = nil
        abortInFlightSequence(restoreClipboard: restoreClipboard)
        cancelPendingClipboardRestore(restoreImmediately: restoreClipboard)
    }

    /// v2.8.1 (P0-1): synchronously supersede any in-flight sequential paste. Bumps
    /// the generation token (so scheduled recursion steps become no-ops), optionally
    /// restores that sequence's captured clipboard, and cleans its temp image files.
    private func abortInFlightSequence(restoreClipboard: Bool) {
        pasteSequenceGeneration &+= 1
        if let prev = inFlightSequencePrevious {
            if restoreClipboard { _ = clipboard.restore(prev) }
            inFlightSequencePrevious = nil
        }
        if !inFlightSequenceTempFiles.isEmpty {
            cleanupTempFiles(inFlightSequenceTempFiles)
            inFlightSequenceTempFiles = []
        }
    }

    private func promptAccessibilityPermissionIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func waitUntilFrontmost(
        _ app: NSRunningApplication,
        timeout: TimeInterval = 1.2,
        interval: TimeInterval = 0.05,
        completion: @escaping (Bool) -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.processIdentifier == app.processIdentifier {
                completion(true)
                return
            }
            if Date() >= deadline {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { check() }
        }
        check()
    }

    // MARK: - Send Keystroke

    /// Explicit Cmd down → V down → V up → Cmd up
    func sendPasteKeystroke() {
        guard AXIsProcessTrusted() else {
            NSLog("[ClipSlots] Accessibility permission not granted. Cannot send Cmd+V.")
            promptAccessibilityPermissionIfNeeded()
            return
        }

        let vKey = virtualKeyForCharacterV()
        let commandKey: CGKeyCode = 55
        let src = CGEventSource(stateID: .hidSystemState)

        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: true)
        let vDown   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let vUp     = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: false)

        vDown?.flags = .maskCommand
        vUp?.flags   = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        NSLog("[ClipSlots] Sent explicit Cmd+V keystroke, vKey=\(vKey)")
    }

    /// Send explicit Cmd+C keystroke to copy current selection in frontmost app.
    func sendCopyKeystroke() {
        guard AXIsProcessTrusted() else {
            NSLog("[ClipSlots] Accessibility permission not granted. Cannot send Cmd+C.")
            promptAccessibilityPermissionIfNeeded()
            return
        }

        let cKey: CGKeyCode = 8
        let commandKey: CGKeyCode = 55
        let src = CGEventSource(stateID: .hidSystemState)

        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: true)
        let cDown   = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true)
        let cUp     = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: false)

        cDown?.flags = .maskCommand
        cUp?.flags   = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        cDown?.post(tap: .cghidEventTap)
        cUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        NSLog("[ClipSlots] Sent explicit Cmd+C keystroke")
    }

    /// Poll until clipboard changeCount differs from `changeCount` or timeout.
    private func waitForClipboardChangeOrDelay(
        from changeCount: Int,
        timeout: TimeInterval = 0.35,
        interval: TimeInterval = 0.03,
        completion: @escaping (Bool) -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        func check() {
            if NSPasteboard.general.changeCount != changeCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { completion(true) }
                return
            }
            if Date() >= deadline {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { check() }
        }
        check()
    }

    /// For global save hotkey: send Cmd+C to copy current selection, wait for clipboard update, then save.
    func captureSelectionAndSaveToSlot(_ slot: Int) {
        guard !isBatchSaving else {
            showToast("正在批量保存，请稍候")
            return
        }
        cancelPendingClipboardRestore()

        guard AXIsProcessTrusted() else {
            NSLog("[ClipSlots] Accessibility permission not granted. Cannot capture selection.")
            promptAccessibilityPermissionIfNeeded()
            return
        }

        let beforeChangeCount = NSPasteboard.general.changeCount
        NSLog("[ClipSlots] captureSelectionAndSaveToSlot requested slot=\(slot), beforeChangeCount=\(beforeChangeCount)")

        sendCopyKeystroke()

        waitForClipboardChangeOrDelay(from: beforeChangeCount, timeout: 0.35, interval: 0.03) { [weak self] changed in
            guard let self = self else { return }

            guard changed else {
                NSLog("[ClipSlots] captureSelectionAndSaveToSlot ignored: clipboard did not change slot=\(slot)")
                self.showFloatingNotice(FloatingNotice(
                    title: "保存失败",
                    subtitle: "没有捕获到内容，请先复制",
                    iconName: "xmark.circle.fill",
                    kind: .error
                ), duration: 2.5)
                return
            }

            let content = self.clipboard.capture()
            guard !content.isEmpty else {
                NSLog("[ClipSlots] captureSelectionAndSaveToSlot ignored: empty capture slot=\(slot)")
                self.showFloatingNotice(FloatingNotice(
                    title: "保存失败",
                    subtitle: "没有可保存的内容",
                    iconName: "xmark.circle.fill",
                    kind: .error
                ), duration: 2.5)
                return
            }

            // v2.6.1: Overwrite confirmation (was bypassed in v2.6.0)
            let existing = self.contentForSlot(slot)
            if !existing.isEmpty && !UserDefaults.standard.skipOverwriteConfirmation {
                let alert = NSAlert()
                alert.messageText = "覆盖槽位 \(slot)？"
                alert.informativeText = "槽位 \(slot) 已有内容，继续保存会替换原内容。"
                alert.addButton(withTitle: "覆盖")
                alert.addButton(withTitle: "取消")

                let checkbox = NSButton(checkboxWithTitle: "以后覆盖时不再提醒", target: nil, action: nil)
                alert.accessoryView = checkbox

                let response = alert.runModal()
                guard response == .alertFirstButtonReturn else {
                    NSLog("[ClipSlots] SAVE cancelled by user slot=\(slot)")
                    return
                }

                if checkbox.state == .on {
                    UserDefaults.standard.set(true, forKey: UserPreferenceKeys.skipOverwriteConfirmation)
                }
            }

            self.handleCapturedContentForSave(content, targetSlot: slot)
        }
    }

    // MARK: - Save (lightweight, synchronous)

    func saveToSlot(_ slot: Int) {
        guard !isBatchSaving else {
            showToast("正在批量保存，请稍候")
            return
        }
        cancelPendingClipboardRestore()

        let content = clipboard.capture()
        guard !content.isEmpty else {
            NSLog("[ClipSlots] SAVE ignored: clipboard empty slot=\(slot)")
            return
        }

        // Check for overwrite confirmation
        let existing = contentForSlot(slot)
        if !existing.isEmpty && !UserDefaults.standard.skipOverwriteConfirmation {
            let alert = NSAlert()
            alert.messageText = "覆盖槽位 \(slot)？"
            alert.informativeText = "槽位 \(slot) 已有内容，继续保存会替换原内容。"
            alert.addButton(withTitle: "覆盖")
            alert.addButton(withTitle: "取消")

            let checkbox = NSButton(checkboxWithTitle: "以后覆盖时不再提醒", target: nil, action: nil)
            alert.accessoryView = checkbox

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else {
                NSLog("[ClipSlots] SAVE cancelled by user slot=\(slot)")
                return
            }

            if checkbox.state == .on {
                UserDefaults.standard.set(true, forKey: UserPreferenceKeys.skipOverwriteConfirmation)
            }
        }

        handleCapturedContentForSave(content, targetSlot: slot)
    }

    // MARK: - Copy (lightweight)

    func copySlot(_ slot: Int) {
        cancelPendingClipboardRestore()

        let content = contentForSlot(slot)
        // v2.9.3: copySlot only ever restores the slot BODY (items) to the pasteboard
        // via clipboard.restore, which itself guards on items.isEmpty. Guard on
        // items.isEmpty here (not the unified content.isEmpty) so an attachment-only
        // slot is not falsely reported as "已复制" while restore() actually clears the
        // clipboard. This preserves the exact pre-v2.9.3 body-copy behavior.
        guard !content.items.isEmpty else {
            NSLog("[ClipSlots] COPY ignored: slot \(slot) empty")
            if UserDefaults.standard.showCopyToast {
                showToast("槽位 \(slot) 为空")
            }
            return
        }

        _ = clipboard.restore(content)
        NSLog("[ClipSlots] COPY slot=\(slot) preview=\(content.preview)")

        if UserDefaults.standard.showCopyToast {
            let summary = content.noticeSummary
            showFloatingNotice(FloatingNotice(
                title: "已复制槽位 \(slot)",
                subtitle: "\(summary.typeTitle) · \(summary.detail)",
                iconName: summary.iconName,
                kind: .info
            ))
        }
    }

    // MARK: - Simple Paste (hotkeys, menu)

    func pasteSlot(_ slot: Int) {
        let activeId = activeHotkeySpecialSlotId

        NSLog("[ClipSlots] pasteSlot instanceID=\(instanceID) slot=\(slot) activeSpecialSlotId=\(activeId) loadedSpecialSlotId=\(loadedSpecialSlotId ?? "nil")")

        // v2.7.0: Chain paste check (hotkey path)
        if isSlotConnectionEnabled {
            let chain = currentConnectionMap.chainSlots(startingAt: slot)
            if chain.count > 1 {
                NSLog("[ClipSlots] pasteSlot chain detected, chain=\(chain)")
                pasteSlotChain(chain)
                return
            }
        }
        
        // v2.8.0 (P0-1/P1-2): Slot attachments auto-chain. If the slot has
        // attachments, paste main content + all attachments in order through the
        // shared central executor, which batches multiple images, restores the
        // original clipboard afterwards, guards against group / app switches, and
        // cleans up any spilled temp image files.
        let content = specialStorage.get(slot, in: activeId)
        if !content.attachments.isEmpty {
            var tempFiles: [URL] = []
            let payloads = slotContentPayloads(slot: slot, activeId: activeId, tempFiles: &tempFiles)
            let attachCount = content.attachments.count
            runSequentialPaste(payloads, activeId: activeId, targetApp: nil, tempFiles: tempFiles) { [weak self] in
                self?.showFloatingNotice(FloatingNotice(
                    title: "已粘贴主内容 + \(attachCount) 个附件",
                    subtitle: "主内容与附件已依次粘贴",
                    iconName: "paperclip.circle.fill",
                    kind: .success
                ))
                self?.maybeAutoAdvance(afterPasting: slot, in: activeId) // v2.9.31
            }
            return
        }

        guard !content.isEmpty else {
            NSLog("[ClipSlots] pasteSlot ignored: specialSlot=\(activeId) slot=\(slot) empty")
            return
        }

        guard AXIsProcessTrusted() else {
            NSLog("[ClipSlots] Accessibility permission not granted.")
            promptAccessibilityPermissionIfNeeded()
            return
        }

        cancelPendingPasteOperations(restoreClipboard: true)

        let previous = clipboard.capture()
        guard clipboard.restore(content) else {
            NSLog("[ClipSlots] pasteSlot restore failed specialSlot=\(activeId) slot=\(slot)")
            return
        }

        let pasteWorkItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            // If user switched special slot before Cmd+V fires, abort this stale paste.
            guard self.currentSpecialSlotId == activeId else {
                NSLog("[ClipSlots] pasteSlot abort stale paste requestedSpecialSlot=\(activeId) current=\(self.currentSpecialSlotId) slot=\(slot)")
                _ = self.clipboard.restore(previous)
                self.pendingPasteWorkItem = nil
                return
            }

            self.sendPasteKeystroke()

            let restoreWorkItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                _ = self.clipboard.restore(previous)
                self.pendingClipboardRestore = nil
                self.pendingClipboardRestoreContent = nil
            }
            self.pendingClipboardRestoreContent = previous
            self.pendingClipboardRestore = restoreWorkItem
            self.pendingPasteWorkItem = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)
        }

        self.pendingPasteWorkItem = pasteWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: pasteWorkItem)

        NSLog("[ClipSlots] pasteSlot scheduled specialSlot=\(activeId) slot=\(slot) preview=\(content.preview)")

        maybeAutoAdvance(afterPasting: slot, in: activeId) // v2.9.31
    }

    // MARK: - Radial Paste (targetApp activation + waitUntilFrontmost)

    func pasteSlotToApp(_ slot: Int, targetApp: NSRunningApplication?) {
        let activeId = currentSpecialSlotId

        // v2.7.0: Chain paste check (radial menu / UI path)
        if isSlotConnectionEnabled {
            let chain = currentConnectionMap.chainSlots(startingAt: slot)
            if chain.count > 1 {
                NSLog("[ClipSlots] pasteSlotToApp chain detected, chain=\(chain)")
                pasteSlotChainToApp(chain, targetApp: targetApp)
                return
            }
        }

        // Always read from the currently active special slot on disk.
        let content = specialStorage.get(slot, in: activeId)

        // v2.8.0 (P1-2): radial / UI single-slot paste now carries attachments too,
        // via the same central executor used by the hotkey path.
        if !content.attachments.isEmpty {
            var tempFiles: [URL] = []
            let payloads = slotContentPayloads(slot: slot, activeId: activeId, tempFiles: &tempFiles)
            let attachCount = content.attachments.count
            runSequentialPaste(payloads, activeId: activeId, targetApp: targetApp, tempFiles: tempFiles) { [weak self] in
                self?.showFloatingNotice(FloatingNotice(
                    title: "已粘贴主内容 + \(attachCount) 个附件",
                    subtitle: "主内容与附件已依次粘贴",
                    iconName: "paperclip.circle.fill",
                    kind: .success
                ))
                self?.maybeAutoAdvance(afterPasting: slot, in: activeId) // v2.9.31
            }
            return
        }

        guard !content.isEmpty else {
            NSLog("[ClipSlots] radial paste ignored: specialSlot=\(activeId) slot \(slot) empty")
            return
        }

        guard AXIsProcessTrusted() else {
            NSLog("[ClipSlots] Accessibility permission not granted.")
            promptAccessibilityPermissionIfNeeded()
            return
        }

        cancelPendingClipboardRestore()

        let cleanTarget: NSRunningApplication?
        if isSelfApp(targetApp) {
            cleanTarget = lastNonClipSlotsApp
        } else {
            cleanTarget = targetApp ?? lastNonClipSlotsApp
        }

        NSLog("[ClipSlots] PASTE radial specialSlot=\(activeId) slot=\(slot) preview=\(content.preview) targetApp=\(cleanTarget?.localizedName ?? "nil")")

        let previous = clipboard.capture()

        let performPaste = { [weak self] in
            guard let self = self else { return }

            // Abort if special slot changed while waiting for app activation.
            guard self.currentSpecialSlotId == activeId else {
                NSLog("[ClipSlots] radial paste abort stale paste requestedSpecialSlot=\(activeId) current=\(self.currentSpecialSlotId) slot=\(slot)")
                _ = self.clipboard.restore(previous)
                return
            }

            guard self.clipboard.restore(content) else {
                NSLog("[ClipSlots] radial paste restore failed specialSlot=\(activeId) slot=\(slot)")
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self = self else { return }

                guard self.currentSpecialSlotId == activeId else {
                    NSLog("[ClipSlots] radial paste abort stale keystroke requestedSpecialSlot=\(activeId) current=\(self.currentSpecialSlotId) slot=\(slot)")
                    _ = self.clipboard.restore(previous)
                    return
                }

                self.sendPasteKeystroke()

                self.maybeAutoAdvance(afterPasting: slot, in: activeId) // v2.9.31

                let restoreWorkItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    _ = self.clipboard.restore(previous)
                    self.pendingClipboardRestore = nil
                    self.pendingClipboardRestoreContent = nil
                }
                self.pendingClipboardRestoreContent = previous
                self.pendingClipboardRestore = restoreWorkItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)
            }
        }

        if let app = cleanTarget {
            app.activate(options: [.activateIgnoringOtherApps])
            waitUntilFrontmost(app, timeout: 1.2) { success in
                NSLog("[ClipSlots] radial waitUntilFrontmost success=\(success)")
                performPaste()
            }
        } else {
            performPaste()
        }
    }

    /// UI paste button fallback
    func pasteSlotFromUI(_ slot: Int) {
        guard let target = lastNonClipSlotsApp else {
            NSLog("[ClipSlots] UI paste has no target app, fallback to copy slot \(slot)")
            copySlot(slot)
            return
        }
        pasteSlotToApp(slot, targetApp: target)
    }

    // MARK: - v2.7.0 Connection Map

    func loadConnectionMapForCurrentGroup() {
        guard let pageId = currentPage?.id ?? Optional(currentPageId),
              !pageId.isEmpty else {
            currentConnectionMap = .empty
            return
        }
        let groupId = currentSpecialSlotId
        currentConnectionMap = SlotConnectionStorage.shared.load(pageId: pageId, groupId: groupId)
        NSLog("[ClipSlots] loadConnectionMap edges=\(currentConnectionMap.edges.count) pageId=\(pageId) groupId=\(groupId)")
    }

    func saveConnectionMapForCurrentGroup() {
        guard let pageId = currentPage?.id ?? Optional(currentPageId),
              !pageId.isEmpty else { return }
        SlotConnectionStorage.shared.save(currentConnectionMap, pageId: pageId, groupId: currentSpecialSlotId)
    }

    // MARK: - v2.7.0 Connect / Disconnect

    func connectSlots(fromSlot: Int, fromPort: SlotPort, toSlot: Int, toPort: SlotPort) {
        do {
            var map = currentConnectionMap
            try map.connect(fromSlot: fromSlot, fromPort: fromPort, toSlot: toSlot, toPort: toPort)
            currentConnectionMap = map
            saveConnectionMapForCurrentGroup()

            let chain = map.fullChain(containing: fromSlot)
            showFloatingNotice(FloatingNotice(
                title: "已连接槽位 \(fromSlot) → \(toSlot)",
                subtitle: "当前链路：\(compactChainDescription(chain))",
                iconName: "link.circle.fill",
                kind: .success
            ))
        } catch let error as SlotConnectionError {
            showFloatingNotice(FloatingNotice(
                title: error.noticeTitle,
                subtitle: error.localizedDescription,
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
        } catch {
            showFloatingNotice(FloatingNotice(
                title: "连接失败",
                subtitle: error.localizedDescription,
                iconName: "xmark.circle.fill",
                kind: .error
            ))
        }
    }

    func disconnectConnectionInvolving(slot: Int, port: SlotPort) {
        var map = currentConnectionMap
        map.disconnectInvolving(slot: slot, port: port)
        currentConnectionMap = map
        saveConnectionMapForCurrentGroup()

        showFloatingNotice(FloatingNotice(
            title: "已断开连接",
            subtitle: "槽位内容未受影响",
            iconName: "link.badge.minus",
            kind: .info
        ))
    }

    // v2.9.20: 按连线 id 断开单条连线（节点画布连线中点 hover 删除入口调用）。
    func disconnectEdge(id: UUID) {
        var map = currentConnectionMap
        map.disconnect(edgeId: id)
        currentConnectionMap = map
        saveConnectionMapForCurrentGroup()

        showFloatingNotice(FloatingNotice(
            title: "已断开连接",
            subtitle: "槽位内容未受影响",
            iconName: "link.badge.minus",
            kind: .info
        ))
    }

    func confirmAndClearCurrentConnections() {
        guard !currentConnectionMap.edges.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "没有可清除的连接",
                subtitle: "当前槽位组没有连接",
                iconName: "info.circle.fill",
                kind: .info
            ))
            return
        }

        let alert = NSAlert()
        alert.messageText = "清除当前槽位组所有连接？"
        alert.informativeText = "这只会清除连接关系，不会删除槽位内容。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清除连接")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        currentConnectionMap = .empty
        saveConnectionMapForCurrentGroup()

        showFloatingNotice(FloatingNotice(
            title: "已清除连接",
            subtitle: "槽位内容未受影响",
            iconName: "trash.fill",
            kind: .success
        ))
    }

    func toggleConnectionMode() {
        isConnectionModeEnabled.toggle()
        if !isConnectionModeEnabled {
            activeDragConnection = nil
            hoveredPortTarget = nil
        }
    }

    // MARK: - v2.7.0 Port Helpers

    func portColor(for slot: Int) -> Color? {
        guard let colorId = currentConnectionMap.colorId(for: slot) else { return nil }
        return SlotConnectionColor.color(for: colorId)
    }

    func connectedPorts(for slot: Int) -> Set<SlotPort> {
        var result = Set<SlotPort>()
        if let outgoing = currentConnectionMap.edgeFrom(slot: slot) {
            result.insert(outgoing.fromPort)
        }
        if let incoming = currentConnectionMap.edgeTo(slot: slot) {
            result.insert(incoming.toPort)
        }
        return result
    }

    func shouldShowPorts(for slot: Int) -> Bool {
        guard isSlotConnectionEnabled else { return false }
        return isConnectionModeEnabled
            || hoveredSlot == slot
            || activeDragConnection?.fromSlot == slot
            || activeDragConnection?.hoverTarget?.slot == slot
            || currentConnectionMap.colorId(for: slot) != nil
    }

    // MARK: - v2.7.0 Drag Connection

    func beginConnectionDrag(fromSlot: Int, fromPort: SlotPort, startPoint: CGPoint) {
        activeDragConnection = ActiveDragConnection(
            fromSlot: fromSlot,
            fromPort: fromPort,
            currentPoint: startPoint,
            hoverTarget: nil
        )
    }

    func updateConnectionDrag(currentPoint: CGPoint, hoverTarget: SlotPortTarget?) {
        guard var active = activeDragConnection else { return }
        active.currentPoint = currentPoint
        active.hoverTarget = hoverTarget
        activeDragConnection = active
        hoveredPortTarget = hoverTarget
    }

    func endConnectionDrag(target: SlotPortTarget?) {
        guard let active = activeDragConnection else { return }
        defer {
            activeDragConnection = nil
            hoveredPortTarget = nil
        }

        guard let target = target else {
            showFloatingNotice(FloatingNotice(
                title: "连接已取消",
                subtitle: "未选择目标槽位",
                iconName: "xmark.circle.fill",
                kind: .info
            ))
            return
        }

        connectSlots(
            fromSlot: active.fromSlot,
            fromPort: active.fromPort,
            toSlot: target.slot,
            toPort: target.port
        )
    }

    // MARK: - v2.7.0 Chain Paste

    func pasteSlotConsideringConnections(_ slot: Int) {
        guard isSlotConnectionEnabled else {
            pasteSlot(slot)
            return
        }

        let chain = currentConnectionMap.chainSlots(startingAt: slot)
        guard chain.count > 1 else {
            pasteSlot(slot)
            return
        }

        pasteSlotChain(chain)
    }

    // MARK: - v2.7.80 Chain paste with per-slot attachments

    /// True if any slot in the chain carries attachments (read from `activeId`).
    private func chainHasAttachments(_ chain: [Int], activeId: String) -> Bool {
        chain.contains { !specialStorage.get($0, in: activeId).attachments.isEmpty }
    }

    /// v2.8.0: Materialises `content → attachments` payloads for a SINGLE slot,
    /// read from the given group (`activeId`). Multiple image attachments are
    /// coalesced into ONE Finder-style multi-file URL payload (即梦AI batch), while
    /// a single image keeps its inline-bitmap payload (WeChat / rich-text). Any temp
    /// files spilled to disk for in-memory images are appended to `tempFiles` so the
    /// caller can clean them up after the paste (P1-4).
    private func slotContentPayloads(slot: Int, activeId: String, tempFiles: inout [URL]) -> [ChainPastePayload] {
        var result: [ChainPastePayload] = []

        // 1) Main content of the slot.
        let contentPayload = mainContentPayload(slot: slot, activeId: activeId)
        if !contentPayload.isEmpty { result.append(contentPayload) }

        // 2) Attachments belonging to THIS slot only.
        let attachments = specialStorage.get(slot, in: activeId).attachments
        guard !attachments.isEmpty else { return result }

        // v2.8.2: ALL file-like attachments (images + .file videos/documents/…) are
        // now unified. Indices are file-like when they can be resolved to a file URL
        // (image with path/data, or .file with a path); everything else (.text /
        // .url / .reference) is a non-file attachment pasted individually in order.
        let fileLikeIndices = attachments.indices.filter { idx in
            let att = attachments[idx]
            switch att.type {
            case .file:
                return (att.path?.isEmpty == false)
            case .image:
                return (att.path?.isEmpty == false) || (att.data?.isEmpty == false)
            default:
                return false
            }
        }

        // 2a) Non-file attachments (.text / .url / .reference) in original order.
        for i in attachments.indices where !fileLikeIndices.contains(i) {
            let p = payloadForAttachment(attachments[i], activeId: activeId)
            if !p.isEmpty { result.append(p) }
        }

        // 2b) File-like attachments:
        //   • exactly one → keep the original single-item payload (inline bitmap for
        //     a lone image → WeChat / rich-text compatibility; a single file URL for
        //     a lone .file), preserving prior proven behaviour.
        //   • two or more → coalesce into ONE Finder-style multi-file URL payload
        //     (single Cmd+V), preserving the original attachment order. Only images
        //     spilled from in-memory data are added to `tempFiles` for cleanup; the
        //     user's original files are never touched.
        if fileLikeIndices.count == 1 {
            let p = payloadForAttachment(attachments[fileLikeIndices[0]], activeId: activeId)
            if !p.isEmpty { result.append(p) }
        } else if fileLikeIndices.count >= 2 {
            let urls = fileLikeIndices.compactMap { fileURLForFileLikeAttachment(attachments[$0], tempFiles: &tempFiles) }
            if !urls.isEmpty {
                result.append(ChainPastePayload(
                    sourceSlot: slot,
                    text: nil,
                    fileURLs: urls,
                    isImage: false,
                    isEmpty: false,
                    image: nil
                ))
            }
        }
        return result
    }

    /// v2.8.0: Expands a connection chain into an ordered payload list
    /// (content → attachments → next slot's content → …) read from `activeId`.
    private func expandedChainPayloads(for chain: [Int], activeId: String, tempFiles: inout [URL]) -> [ChainPastePayload] {
        var result: [ChainPastePayload] = []
        for slot in chain {
            result.append(contentsOf: slotContentPayloads(slot: slot, activeId: activeId, tempFiles: &tempFiles))
        }
        return result
    }

    func pasteSlotChain(_ slots: [Int]) {
        let activeId = activeHotkeySpecialSlotId

        // v2.8.0: if any slot in the chain has attachments, expand each slot into
        // content → attachments and paste sequentially through the central executor
        // (unified clipboard restore + abort guard + temp cleanup). Attachment-free
        // chains keep the original fast merged behavior below.
        if chainHasAttachments(slots, activeId: activeId) {
            var tempFiles: [URL] = []
            let payloads = expandedChainPayloads(for: slots, activeId: activeId, tempFiles: &tempFiles)
            let attachmentTotal = slots.reduce(0) { $0 + specialStorage.get($1, in: activeId).attachments.count }
            let chainForNotice = slots
            let count = payloads.count
            runSequentialPaste(payloads, activeId: activeId, targetApp: nil, tempFiles: tempFiles) { [weak self] in
                self?.showFloatingNotice(FloatingNotice(
                    title: "已串联粘贴 \(count) 段内容",
                    subtitle: "含 \(attachmentTotal) 个附件 · \(compactChainDescription(chainForNotice))",
                    iconName: "link.circle.fill",
                    kind: .success
                ))
            }
            return
        }

        let payloads = slots.map { payloadForSlot($0) }
        let nonEmptyPayloads = payloads.filter { !$0.isEmpty }
        let skippedEmptyCount = payloads.count - nonEmptyPayloads.count

        guard !nonEmptyPayloads.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "串联粘贴失败",
                subtitle: "链路中没有可粘贴内容",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
            return
        }

        guard AXIsProcessTrusted() else {
            promptAccessibilityPermissionIfNeeded()
            return
        }

        let kind = chainPasteKind(for: nonEmptyPayloads)

        switch kind {
        case .text:
            let merged = nonEmptyPayloads.compactMap(\.text).joined(separator: "\n\n")
            guard !merged.isEmpty else {
                showFloatingNotice(FloatingNotice(
                    title: "串联粘贴失败",
                    subtitle: "没有可粘贴文本",
                    iconName: "exclamationmark.triangle.fill",
                    kind: .warning
                ))
                return
            }

            cancelPendingPasteOperations(restoreClipboard: true)
            let previous = clipboard.capture()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(merged, forType: .string)

            let pasteWorkItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard self.currentSpecialSlotId == activeId else {
                    _ = self.clipboard.restore(previous)
                    return
                }
                self.sendPasteKeystroke()
                let restoreWorkItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    _ = self.clipboard.restore(previous)
                    self.pendingClipboardRestore = nil
                    self.pendingClipboardRestoreContent = nil
                }
                self.pendingClipboardRestoreContent = previous
                self.pendingClipboardRestore = restoreWorkItem
                self.pendingPasteWorkItem = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)
            }
            self.pendingPasteWorkItem = pasteWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: pasteWorkItem)

            showChainPasteSuccess(slots: slots, pastedCount: nonEmptyPayloads.count, skippedEmptyCount: skippedEmptyCount)

        case .files:
            let urls = nonEmptyPayloads.flatMap(\.fileURLs)
            guard !urls.isEmpty else {
                showFloatingNotice(FloatingNotice(
                    title: "串联粘贴失败",
                    subtitle: "没有可粘贴文件",
                    iconName: "exclamationmark.triangle.fill",
                    kind: .warning
                ))
                return
            }

            cancelPendingPasteOperations(restoreClipboard: true)
            let previous = clipboard.capture()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])

            let pasteWorkItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard self.currentSpecialSlotId == activeId else {
                    _ = self.clipboard.restore(previous)
                    return
                }
                self.sendPasteKeystroke()
                let restoreWorkItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    _ = self.clipboard.restore(previous)
                    self.pendingClipboardRestore = nil
                    self.pendingClipboardRestoreContent = nil
                }
                self.pendingClipboardRestoreContent = previous
                self.pendingClipboardRestore = restoreWorkItem
                self.pendingPasteWorkItem = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)
            }
            self.pendingPasteWorkItem = pasteWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: pasteWorkItem)

            showFloatingNotice(FloatingNotice(
                title: "已串联粘贴 \(urls.count) 个文件",
                subtitle: compactChainDescription(slots),
                iconName: "link.circle.fill",
                kind: .success
            ))

        case .unsupported:
            // v2.7.4: Instead of rejecting mixed content chains, paste each item
            // sequentially in order (text → Cmd+V → image → Cmd+V → ...).
            pasteSlotChainSequentially(slots, activeId: activeId)

        case .empty:
            showFloatingNotice(FloatingNotice(
                title: "串联粘贴失败",
                subtitle: "链路中没有可粘贴内容",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
        }
    }

    func pasteSlotChainToApp(_ slots: [Int], targetApp: NSRunningApplication?) {
        let activeId = currentSpecialSlotId

        // v2.8.0: expand slots into content → attachments when any slot has
        // attachments, so the radial / UI chain paste no longer drops them, routed
        // through the central executor (clipboard restore + abort + temp cleanup).
        if chainHasAttachments(slots, activeId: activeId) {
            var tempFiles: [URL] = []
            let payloads = expandedChainPayloads(for: slots, activeId: activeId, tempFiles: &tempFiles)
            let attachmentTotal = slots.reduce(0) { $0 + specialStorage.get($1, in: activeId).attachments.count }
            let chainForNotice = slots
            let count = payloads.count
            runSequentialPaste(payloads, activeId: activeId, targetApp: targetApp, tempFiles: tempFiles) { [weak self] in
                self?.showFloatingNotice(FloatingNotice(
                    title: "已串联粘贴 \(count) 段内容",
                    subtitle: "含 \(attachmentTotal) 个附件 · \(compactChainDescription(chainForNotice))",
                    iconName: "link.circle.fill",
                    kind: .success
                ))
            }
            return
        }

        let payloads = slots.map { payloadForSlot($0) }
        let nonEmptyPayloads = payloads.filter { !$0.isEmpty }
        let skippedEmptyCount = payloads.count - nonEmptyPayloads.count

        guard !nonEmptyPayloads.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "串联粘贴失败",
                subtitle: "链路中没有可粘贴内容",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
            return
        }

        guard AXIsProcessTrusted() else {
            promptAccessibilityPermissionIfNeeded()
            return
        }

        let kind = chainPasteKind(for: nonEmptyPayloads)

        switch kind {
        case .text:
            let merged = nonEmptyPayloads.compactMap(\.text).joined(separator: "\n\n")
            guard !merged.isEmpty else {
                showFloatingNotice(FloatingNotice(
                    title: "串联粘贴失败",
                    subtitle: "没有可粘贴文本",
                    iconName: "exclamationmark.triangle.fill",
                    kind: .warning
                ))
                return
            }

            cancelPendingClipboardRestore()
            let cleanTarget: NSRunningApplication?
            if isSelfApp(targetApp) { cleanTarget = lastNonClipSlotsApp }
            else { cleanTarget = targetApp ?? lastNonClipSlotsApp }

            let previous = clipboard.capture()
            let performPaste = { [weak self] in
                guard let self = self else { return }
                guard self.currentSpecialSlotId == activeId else {
                    _ = self.clipboard.restore(previous); return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(merged, forType: .string)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    guard let self = self else { return }
                    guard self.currentSpecialSlotId == activeId else {
                        _ = self.clipboard.restore(previous); return
                    }
                    self.sendPasteKeystroke()
                    let restoreWorkItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        _ = self.clipboard.restore(previous)
                        self.pendingClipboardRestore = nil
                        self.pendingClipboardRestoreContent = nil
                    }
                    self.pendingClipboardRestoreContent = previous
                    self.pendingClipboardRestore = restoreWorkItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)
                }
            }
            if let app = cleanTarget {
                app.activate(options: [.activateIgnoringOtherApps])
                waitUntilFrontmost(app, timeout: 1.2) { _ in performPaste() }
            } else {
                performPaste()
            }
            showChainPasteSuccess(slots: slots, pastedCount: nonEmptyPayloads.count, skippedEmptyCount: skippedEmptyCount)

        case .files:
            let urls = nonEmptyPayloads.flatMap(\.fileURLs)
            guard !urls.isEmpty else {
                showFloatingNotice(FloatingNotice(
                    title: "串联粘贴失败",
                    subtitle: "没有可粘贴文件",
                    iconName: "exclamationmark.triangle.fill",
                    kind: .warning
                ))
                return
            }
            cancelPendingClipboardRestore()
            let cleanTarget: NSRunningApplication?
            if isSelfApp(targetApp) { cleanTarget = lastNonClipSlotsApp }
            else { cleanTarget = targetApp ?? lastNonClipSlotsApp }
            let previous = clipboard.capture()
            let performPaste = { [weak self] in
                guard let self = self else { return }
                guard self.currentSpecialSlotId == activeId else {
                    _ = self.clipboard.restore(previous); return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(urls as [NSURL])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    guard let self = self else { return }
                    guard self.currentSpecialSlotId == activeId else {
                        _ = self.clipboard.restore(previous); return
                    }
                    self.sendPasteKeystroke()
                    let restoreWorkItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        _ = self.clipboard.restore(previous)
                        self.pendingClipboardRestore = nil
                        self.pendingClipboardRestoreContent = nil
                    }
                    self.pendingClipboardRestoreContent = previous
                    self.pendingClipboardRestore = restoreWorkItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)
                }
            }
            if let app = cleanTarget {
                app.activate(options: [.activateIgnoringOtherApps])
                waitUntilFrontmost(app, timeout: 1.2) { _ in performPaste() }
            } else {
                performPaste()
            }
            showFloatingNotice(FloatingNotice(
                title: "已串联粘贴 \(urls.count) 个文件",
                subtitle: compactChainDescription(slots),
                iconName: "link.circle.fill",
                kind: .success
            ))

        case .unsupported:
            showFloatingNotice(FloatingNotice(
                title: "串联粘贴失败",
                subtitle: "暂不支持混合类型",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
        case .empty:
            showFloatingNotice(FloatingNotice(
                title: "串联粘贴失败",
                subtitle: "链路中没有可粘贴内容",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
        }
    }

    private func payloadForSlot(_ slot: Int) -> ChainPastePayload {
        let content = slots[slot] ?? SlotContent()
        // v2.9.3: this builds the slot BODY payload only (attachments are appended
        // separately in slotContentPayloads). Guard on items.isEmpty (not the unified
        // content.isEmpty) so an attachment-only slot does not inject a spurious empty
        // body payload that would clear the clipboard and paste nothing.
        guard !content.items.isEmpty else {
            return ChainPastePayload(sourceSlot: slot, text: nil, fileURLs: [], isImage: false, isEmpty: true, image: nil)
        }
        return ChainPastePayload(
            sourceSlot: slot,
            text: content.plainText,
            fileURLs: content.detectedRegularFileURLs,
            isImage: content.hasImage || content.isImageFile,
            isEmpty: false,
            image: content.inlineImage
        )
    }

    /// v2.8.0 (P0-2): main-content payload read from a *specific* group on disk so
    /// every paste path resolves against the same authoritative data source rather
    /// than mixing the in-memory `slots` dictionary with the active hotkey group.
    private func mainContentPayload(slot: Int, activeId: String) -> ChainPastePayload {
        let content = specialStorage.get(slot, in: activeId)
        // v2.9.3: builds the slot BODY payload only (attachments handled separately in
        // slotContentPayloads). Guard on items.isEmpty (not the unified content.isEmpty)
        // so an attachment-only slot does not produce a non-empty-but-contentless payload
        // that would clear the clipboard and paste nothing during a chain/attachment paste.
        guard !content.items.isEmpty else {
            return ChainPastePayload(sourceSlot: slot, text: nil, fileURLs: [], isImage: false, isEmpty: true, image: nil)
        }
        return ChainPastePayload(
            sourceSlot: slot,
            text: content.plainText,
            fileURLs: content.detectedRegularFileURLs,
            isImage: content.hasImage || content.isImageFile,
            isEmpty: false,
            image: content.inlineImage
        )
    }

    /// v2.8.0 (P1-3): builds a paste payload for an *explicit* attachment value.
    /// This replaces the previous shared `pendingAttachmentContext` mutable state,
    /// so concurrent / nested materialisation can never contaminate each other.
    private func payloadForAttachment(_ att: SlotContent.SlotAttachment, activeId: String) -> ChainPastePayload {
        let empty = ChainPastePayload(sourceSlot: 0, text: nil, fileURLs: [], isImage: false, isEmpty: true, image: nil)
        switch att.type {
        case .text:
            let text = att.data.flatMap { String(data: $0, encoding: .utf8) } ?? att.name
            return ChainPastePayload(sourceSlot: 0, text: text, fileURLs: [], isImage: false, isEmpty: text.isEmpty, image: nil)
        case .url:
            let text = att.url ?? att.name
            return ChainPastePayload(sourceSlot: 0, text: text, fileURLs: [], isImage: false, isEmpty: text.isEmpty, image: nil)
        case .file:
            guard let path = att.path, !path.isEmpty else { return empty }
            return ChainPastePayload(sourceSlot: 0, text: nil, fileURLs: [URL(fileURLWithPath: path)], isImage: false, isEmpty: false, image: nil)
        case .image:
            if let data = att.data, let image = NSImage(data: data) {
                return ChainPastePayload(sourceSlot: 0, text: nil, fileURLs: [], isImage: true, isEmpty: false, image: image)
            }
            if let path = att.path, !path.isEmpty {
                return ChainPastePayload(sourceSlot: 0, text: nil, fileURLs: [URL(fileURLWithPath: path)], isImage: false, isEmpty: false, image: nil)
            }
            return empty
        case .reference:
            // A reference stores the target slot number as a string in `path`.
            if let path = att.path, let refSlot = Int(path) {
                return mainContentPayload(slot: refSlot, activeId: activeId)
            }
            let text = att.url ?? att.name
            return ChainPastePayload(sourceSlot: 0, text: text, fileURLs: [], isImage: false, isEmpty: text.isEmpty, image: nil)
        }
    }

    private func chainPasteKind(for payloads: [ChainPastePayload]) -> ChainPasteKind {
        let hasText = payloads.contains { $0.text != nil && !($0.text?.isEmpty ?? true) }
        let hasFiles = payloads.contains { !$0.fileURLs.isEmpty }
        let hasImage = payloads.contains { $0.isImage }

        // Image in chain: unsupported for MVP
        if hasImage { return .unsupported }
        // Mixed text + files: unsupported
        if hasText && hasFiles { return .unsupported }
        if hasText { return .text }
        if hasFiles { return .files }
        return .empty
    }

    // v2.7.20: delete/ignore the v2.7.19 pasteAllSlotsInCurrentGroup() helper if it
    // exists locally. The radial "全部粘贴" now calls pasteAllSlotsWithConfirmation(),
    // the same proven path as the main toolbar button. This avoids accidentally using
    // node-connection chain paste and showing misleading "已串联粘贴" HUD.

    // MARK: - v2.7.21 Fast Radial Paste All
    // Radial menu paste-all should be faster than the safe mixed sequential path.
    func pasteAllSlotsFastFromRadialMenu() {
        let nonEmptySlots = (1...max(1, config.slots)).filter { slot in
            !(slots[slot] ?? SlotContent()).isEmpty
        }

        guard !nonEmptySlots.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "当前槽位组为空",
                subtitle: "没有可粘贴内容",
                iconName: "tray",
                kind: .warning
            ))
            return
        }

        let contents = nonEmptySlots.compactMap { slots[$0] }
        guard let target = lastNonClipSlotsApp else {
            showFloatingNotice(FloatingNotice(
                title: "没有可粘贴的目标应用",
                subtitle: "请先切换到目标应用",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
            return
        }

        if contents.allSatisfy({ $0.primaryFileURL == nil && $0.inlineImage == nil }) {
            let merged = contents.map { $0.preview }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(merged, forType: .string)
            target.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.sendPasteKeystroke()
            }
            showFloatingNotice(FloatingNotice(
                title: "已全部粘贴 \(contents.count) 段文本",
                subtitle: "当前槽位组",
                iconName: "square.stack.3d.up.fill",
                kind: .success
            ))
            return
        }

        let urls = contents.compactMap { $0.primaryFileURL }
        if urls.count == contents.count {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            target.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.sendPasteKeystroke()
            }
            showFloatingNotice(FloatingNotice(
                title: "已全部粘贴 \(urls.count) 个文件",
                subtitle: "当前槽位组",
                iconName: "square.stack.3d.up.fill",
                kind: .success
            ))
            return
        }

        // Mixed text + image/file: correctness first, but avoid node-connection HUD wording.
        pasteSlotChainSequentially(nonEmptySlots, noticeTitle: "已全部粘贴 \(contents.count) 段内容", noticeSubtitle: "当前槽位组", targetApp: target)
    }

    // MARK: - v2.7.4 Mixed Chain Sequential Paste

    func pasteSlotChainSequentially(_ slots: [Int], noticeTitle: String? = nil, noticeSubtitle: String? = nil, activeId: String? = nil, targetApp: NSRunningApplication? = nil) {
        let group = activeId ?? currentSpecialSlotId
        let payloads = slots.compactMap { slot -> ChainPastePayload? in
            let payload = payloadForSlot(slot)
            return payload.isEmpty ? nil : payload
        }
        let count = payloads.count
        runSequentialPaste(payloads, activeId: group, targetApp: targetApp, tempFiles: []) { [weak self] in
            guard let self else { return }
            self.showFloatingNotice(FloatingNotice(
                title: noticeTitle ?? "已串联粘贴 \(count) 段内容",
                subtitle: noticeSubtitle ?? compactChainDescription(slots),
                iconName: "link.circle.fill",
                kind: .success
            ))
        }
    }

    // MARK: - v2.8.0 Central sequential paste executor

    /// v2.8.0: The single entry point every attachment / chain / multi-image paste
    /// funnels through. It (1) captures the current clipboard ONCE, (2) optionally
    /// activates the target app, (3) pastes each materialised payload in order while
    /// guarding against special-slot-group switches AND frontmost-app changes, then
    /// (4) restores the original clipboard ~0.8s after the last paste, and finally
    /// (5) deletes any temp image files that were spilled to disk.
    ///
    /// `targetApp == nil` = paste into whatever app is currently frontmost (the
    /// global-hotkey path); a non-nil target is activated first (radial / UI path).
    private func runSequentialPaste(
        _ payloads: [ChainPastePayload],
        activeId: String,
        targetApp: NSRunningApplication?,
        tempFiles: [URL],
        onSuccess: @escaping () -> Void
    ) {
        let nonEmpty = payloads.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else {
            cleanupTempFiles(tempFiles)
            showFloatingNotice(FloatingNotice(
                title: "粘贴失败",
                subtitle: "没有可粘贴内容",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
            return
        }
        guard AXIsProcessTrusted() else {
            cleanupTempFiles(tempFiles)
            promptAccessibilityPermissionIfNeeded()
            return
        }

        // Cancel any in-flight paste/restore (restores its clipboard + cleans its
        // temp files + bumps the generation token) and snapshot the clipboard.
        cancelPendingPasteOperations(restoreClipboard: true)
        let previous = clipboard.capture()
        // v2.8.1 (P0-1): claim a fresh generation token for this run and publish the
        // in-flight bookkeeping so a later sequence / cancel can supersede us cleanly.
        pasteSequenceGeneration &+= 1
        let gen = pasteSequenceGeneration
        inFlightSequencePrevious = previous
        inFlightSequenceTempFiles = tempFiles

        // Resolve the concrete target: nil means "current frontmost" (hotkey path).
        let cleanTarget: NSRunningApplication?
        if targetApp == nil {
            cleanTarget = nil
        } else if isSelfApp(targetApp) {
            cleanTarget = lastNonClipSlotsApp
        } else {
            cleanTarget = targetApp ?? lastNonClipSlotsApp
        }

        let onAbort: () -> Void = { [weak self] in
            guard let self else { return }
            _ = self.clipboard.restore(previous)
            self.cleanupTempFiles(tempFiles)
            if self.pasteSequenceGeneration == gen {
                self.inFlightSequencePrevious = nil
                self.inFlightSequenceTempFiles = []
            }
        }

        let onFinish: () -> Void = { [weak self] in
            guard let self else { return }
            onSuccess()
            let restoreWorkItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                _ = self.clipboard.restore(previous)
                self.pendingClipboardRestore = nil
                self.pendingClipboardRestoreContent = nil
                if self.pasteSequenceGeneration == gen { self.inFlightSequencePrevious = nil }
            }
            self.pendingClipboardRestoreContent = previous
            self.pendingClipboardRestore = restoreWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)

            // v2.8.1 (P1-4): defer temp-file cleanup well past the clipboard restore.
            // Targets that read spilled image files asynchronously (即梦 / Finder-style
            // drops) still need the files after the paste lands. changeCount polling is
            // unreliable here (our own restore bumps changeCount), so a conservative
            // fixed delay is the safest option.
            //
            // v2.8.2 (P1-A): the sequence has SUCCEEDED, so detach its temp files from
            // the in-flight bookkeeping immediately. Otherwise a superseding sequence
            // that starts within this 3s protection window would call
            // abortInFlightSequence and delete these files out from under the target
            // app while it is still reading them asynchronously. Cleanup of these
            // now-orphaned files is owned solely by the delayed work item below, which
            // captures the local `tempFiles` array and is never touched by abort.
            if self.pasteSequenceGeneration == gen {
                self.inFlightSequenceTempFiles = []
            }
            if !tempFiles.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self else { return }
                    self.cleanupTempFiles(tempFiles)
                }
            }
        }

        let run: () -> Void = { [weak self] in
            guard let self else { return }
            // Expected target = the app we activated, else whatever is frontmost now.
            let expectedPid = cleanTarget?.processIdentifier
                ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
            self.pasteNextPayloadSequentially(
                nonEmpty,
                index: 0,
                activeId: activeId,
                generation: gen,
                expectedPid: expectedPid,
                onAbort: onAbort,
                completion: onFinish
            )
        }

        if let app = cleanTarget {
            app.activate(options: [.activateIgnoringOtherApps])
            waitUntilFrontmost(app, timeout: 1.2) { [weak self] ok in
                guard let self else { return }
                // v2.8.1 (P1-3): if activation failed, abort safely instead of
                // firing keystrokes at the wrong app. Restore clipboard + clean up
                // and surface a warning so the user knows nothing was pasted.
                guard ok else {
                    onAbort()
                    self.showFloatingNotice(FloatingNotice(
                        title: "粘贴失败",
                        subtitle: "目标应用未能激活，请重试",
                        iconName: "exclamationmark.triangle.fill",
                        kind: .warning
                    ))
                    return
                }
                run()
            }
        } else {
            run()
        }
    }

    /// v2.8.0 (P1-4): removes temp image files spilled to disk for a paste.
    private func cleanupTempFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls { try? FileManager.default.removeItem(at: url) }
        NSLog("[ClipSlots] cleaned up \(urls.count) temp image file(s)")
    }

    /// Resolves a usable on-disk file URL for an image attachment. If the
    /// attachment references an existing file, that path is used; otherwise its
    /// in-memory bitmap `data` is spilled to a temp file with the correct
    /// extension. v2.8.0 (P1-4): any temp file created is appended to `tempFiles`
    /// so the caller can delete it once the paste has landed and the clipboard has
    /// been restored (files referencing an existing on-disk path are NOT tracked).
    /// v2.8.2: Resolves ANY file-like attachment (image OR .file) into a file URL
    /// suitable for a Finder-style multi-file paste.
    ///   • `.file` with an existing path → the user's ORIGINAL file (never appended
    ///     to `tempFiles`, so it is never deleted after paste).
    ///   • `.image` with an existing path → the original file (not a temp).
    ///   • `.image` with in-memory data only → spilled to a temp file that IS added
    ///     to `tempFiles` for post-paste cleanup.
    /// Returns nil for non-file-like attachments or unresolvable ones.
    private func fileURLForFileLikeAttachment(_ att: SlotContent.SlotAttachment, tempFiles: inout [URL]) -> URL? {
        switch att.type {
        case .file:
            guard let path = att.path, !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        case .image:
            if let path = att.path, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            guard let data = att.data, !data.isEmpty else { return nil }
            return spillImageDataToTempFile(att, data: data, tempFiles: &tempFiles)
        default:
            return nil
        }
    }

    /// Writes in-memory image data to a temp file and records it in `tempFiles`.
    private func spillImageDataToTempFile(_ att: SlotContent.SlotAttachment, data: Data, tempFiles: inout [URL]) -> URL? {

        let ext = imageFileExtension(forName: att.name, data: data)
        let baseName = (att.name as NSString).deletingPathExtension
        let safeBase = baseName.isEmpty ? "clipslots-image" : baseName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let fileName = "clipslots-\(UUID().uuidString.prefix(8))-\(safeBase).\(ext)"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            tempFiles.append(url)
            return url
        } catch {
            NSLog("[ClipSlots] failed to spill image attachment to temp file: \(error)")
            return nil
        }
    }

    /// Determines an image file extension from the attachment name, falling back
    /// to sniffing the data's magic bytes, then to png.
    private func imageFileExtension(forName name: String, data: Data) -> String {
        let nameExt = (name as NSString).pathExtension.lowercased()
        let allowed: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "webp"]
        if allowed.contains(nameExt) { return nameExt == "jpeg" ? "jpg" : nameExt }

        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "png" }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "jpg" }
        if bytes.count >= 6, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "gif" }
        if bytes.count >= 2, bytes[0] == 0x42, bytes[1] == 0x4D { return "bmp" }
        if bytes.count >= 4, (bytes[0] == 0x49 && bytes[1] == 0x49) || (bytes[0] == 0x4D && bytes[1] == 0x4D) { return "tiff" }
        return "png"
    }

    /// v2.8.0: Pastes the payload at `index`, then recurses after a per-payload
    /// delay. Before each step it re-checks the abort conditions (special-slot group
    /// switch or frontmost-app change); on abort it calls `onAbort` (which restores
    /// the clipboard + cleans temp files) and stops. `expectedPid == nil` disables
    /// the app-change guard (kept for completeness; callers always pass a pid).
    private func pasteNextPayloadSequentially(
        _ payloads: [ChainPastePayload],
        index: Int,
        activeId: String,
        generation: Int,
        expectedPid: pid_t?,
        onAbort: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        // v2.8.1 (P0-1): bail out if a newer sequence (or a cancel) has superseded
        // us. The superseding path already restored the clipboard / cleaned temp
        // files, so this stale step must do nothing (no keystroke, no restore).
        guard generation == pasteSequenceGeneration else {
            NSLog("[ClipSlots] sequential paste superseded (gen \(generation) != \(pasteSequenceGeneration)) at step \(index)")
            return
        }
        guard index < payloads.count else {
            completion()
            return
        }

        // Abort if the user switched special-slot group before this step lands.
        if currentSpecialSlotId != activeId {
            NSLog("[ClipSlots] sequential paste abort: group changed \(activeId) -> \(currentSpecialSlotId) at step \(index)")
            onAbort()
            return
        }
        // Abort if the frontmost target app changed mid-sequence.
        if let expectedPid,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != expectedPid {
            NSLog("[ClipSlots] sequential paste abort: frontmost app changed at step \(index)")
            onAbort()
            return
        }

        writePayloadToPasteboard(payloads[index])
        sendPasteKeystroke()

        // v2.7.80: image / file payloads need more time to be ingested (and to keep
        // the clipboard stable) before the next item overwrites it; plain text is fast.
        let payload = payloads[index]
        let isHeavy = payload.isImage || payload.image != nil || !payload.fileURLs.isEmpty
        let delay = isHeavy ? 0.55 : 0.18

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.pasteNextPayloadSequentially(
                payloads,
                index: index + 1,
                activeId: activeId,
                generation: generation,
                expectedPid: expectedPid,
                onAbort: onAbort,
                completion: completion
            )
        }
    }

    private func writePayloadToPasteboard(_ payload: ChainPastePayload) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let text = payload.text, !text.isEmpty {
            pasteboard.setString(text, forType: .string)
            return
        }

        if !payload.fileURLs.isEmpty {
            pasteboard.writeObjects(payload.fileURLs as [NSURL])
            return
        }

        if let image = payload.image {
            pasteboard.writeObjects([image])
            return
        }
    }

    private func showChainPasteSuccess(slots: [Int], pastedCount: Int, skippedEmptyCount: Int) {
        let subtitle: String
        if skippedEmptyCount > 0 {
            subtitle = "\(compactChainDescription(slots))，跳过 \(skippedEmptyCount) 个空槽位"
        } else {
            subtitle = compactChainDescription(slots)
        }
        showFloatingNotice(FloatingNotice(
            title: "已串联粘贴 \(pastedCount) 个槽位",
            subtitle: subtitle,
            iconName: "link.circle.fill",
            kind: .success
        ))
    }

    // MARK: - v2.7.0 Template Export / Import

    func exportConnectionTemplate() {
        guard !currentConnectionMap.edges.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "没有可导出的连接",
                subtitle: "请先建立槽位连接",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
            return
        }

        let panel = NSSavePanel()
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "ClipSlots连接模板-\(df.string(from: Date())).clipslotslink"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [UTType(filenameExtension: "clipslotslink") ?? .json]
        } else {
            panel.allowedFileTypes = ["clipslotslink", "json"]
        }

        let response = panel.runModal()
        guard response == .OK, let rawURL = panel.url else { return }
        let url = SlotConnectionTemplateService.sanitizedExportURL(rawURL)

        do {
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.7.0"
            let template = SlotConnectionTemplateService.makeTemplate(
                from: currentConnectionMap,
                name: "ClipSlots 连接模板",
                appVersion: appVersion
            )
            let data = try SlotConnectionTemplateService.encode(template)
            try data.write(to: url, options: [.atomic])

            let slotCount = Set(currentConnectionMap.edges.flatMap { [$0.fromSlot, $0.toSlot] }).count
            showFloatingNotice(FloatingNotice(
                title: "已导出连接模板",
                subtitle: "包含 \(currentConnectionMap.edges.count) 个连接，\(slotCount) 个槽位",
                iconName: "square.and.arrow.up.fill",
                kind: .success
            ))
        } catch {
            showFloatingNotice(FloatingNotice(
                title: "导出失败",
                subtitle: error.localizedDescription,
                iconName: "xmark.circle.fill",
                kind: .error
            ))
        }
    }

    func importConnectionTemplate() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [UTType(filenameExtension: "clipslotslink") ?? .json]
        } else {
            panel.allowedFileTypes = ["clipslotslink", "json"]
        }

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        suppressWatcher() // v2.9.4 (#2): self-write (template import creates groups on disk)
        do {
            let data = try Data(contentsOf: url)
            
            // 先尝试解码为 Bundle 格式（多组/多页模板）
            // v2.7.65: route through the service (ISO8601 + legacy fallback) and
            // require non-empty entries so a single-group template never gets
            // mis-detected as an (empty) bundle.
            if let bundle = try? SlotConnectionTemplateService.decodeBundle(data), !bundle.entries.isEmpty {
                // v2.7.62: 导入 Bundle 模板时创建多个新槽位组
                var importedCount = 0
                var firstGroupId: String?
                for entry in bundle.entries {
                    guard !entry.map.edges.isEmpty else { continue }
                    try validateConnectionMap(entry.map)
                    let newGroup = try specialStorage.createSpecialSlot(name: entry.groupName, pageId: currentPageId)
                    SlotConnectionStorage.shared.save(entry.map, pageId: currentPageId, groupId: newGroup.id)
                    if firstGroupId == nil { firstGroupId = newGroup.id }
                    importedCount += 1
                }

                guard importedCount > 0, let firstGroupId else {
                    showFloatingNotice(FloatingNotice(
                        title: "导入失败",
                        subtitle: "模板中没有有效的连接数据",
                        iconName: "exclamationmark.triangle.fill",
                        kind: .warning
                    ))
                    return
                }

                // v2.7.65 BUGFIX: the previous implementation created the groups on
                // disk but never refreshed the in-memory @Published state, so the
                // imported groups stayed invisible until the app restarted (the
                // "导入用不了" symptom). Switching to the first imported group reloads
                // the index, published arrays and the connection map for the canvas.
                selectAndActivateSpecialSlot(id: firstGroupId)

                showFloatingNotice(FloatingNotice(
                    title: "已导入连接模板",
                    subtitle: "包含 \(importedCount) 个槽位组，已切换至首个组",
                    iconName: "square.and.arrow.down.fill",
                    kind: .success
                ))
                return
            }
            
            // 否则解码为单组模板
            let template = try SlotConnectionTemplateService.decode(data)
            let importedMap = SlotConnectionMap(edges: template.edges)
            try validateConnectionMap(importedMap)

            // v2.7.61: Import always creates a new slot group, never overwrites current
            let newGroup = try specialStorage.createSpecialSlot(name: "导入 \(template.name.prefix(12))", pageId: currentPageId)
            SlotConnectionStorage.shared.save(importedMap, pageId: currentPageId, groupId: newGroup.id)
            
            // Switch to the new group
            selectAndActivateSpecialSlot(id: newGroup.id)

            let slotCount = Set(importedMap.edges.flatMap { [$0.fromSlot, $0.toSlot] }).count
            showFloatingNotice(FloatingNotice(
                title: "已导入连接模板",
                subtitle: "包含 \(importedMap.edges.count) 个连接，\(slotCount) 个槽位",
                iconName: "square.and.arrow.down.fill",
                kind: .success
            ))
        } catch let error as SlotConnectionError {
            showFloatingNotice(FloatingNotice(
                title: error.noticeTitle,
                subtitle: error.localizedDescription,
                iconName: "xmark.circle.fill",
                kind: .error
            ))
        } catch {
            // v2.7.66: surface the underlying decode error instead of silently
            // collapsing every failure to a generic "模板格式无效".
            NSLog("[ClipSlots] importConnectionTemplate decode failed: \(error)")
            showFloatingNotice(FloatingNotice(
                title: "导入失败",
                subtitle: "模板格式无效：\(error.localizedDescription)",
                iconName: "xmark.circle.fill",
                kind: .error
            ))
        }
    }

    func applyBuiltInFullChainTemplate() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.7.0"
        let template = SlotConnectionTemplateService.makeFullTenSlotChainTemplate(appVersion: appVersion)
        let map = SlotConnectionMap(edges: template.edges)

        do {
            try validateConnectionMap(map)

            if !currentConnectionMap.edges.isEmpty {
                guard confirmReplaceCurrentConnections() else { return }
            }

            currentConnectionMap = map
            saveConnectionMapForCurrentGroup()

            showFloatingNotice(FloatingNotice(
                title: "已应用十槽位全串联",
                subtitle: "粘贴槽位 1 时会串联 1 → 2 → 3 → … → 10",
                iconName: "link.circle.fill",
                kind: .success
            ))
        } catch {
            showFloatingNotice(FloatingNotice(
                title: "应用失败",
                subtitle: error.localizedDescription,
                iconName: "xmark.circle.fill",
                kind: .error
            ))
        }
    }

    // MARK: - v2.7.53 Batch Apply Current Connection Map

    func applyCurrentConnectionMapToAllGroupsInCurrentPage() {
        let source = currentConnectionMap
        guard !source.edges.isEmpty else {
            showToast("当前没有可批量应用的连接")
            return
        }
        let groups = currentPageSlotGroups
        guard !groups.isEmpty else {
            showToast("当前页面没有槽位组")
            return
        }
        for group in groups {
            SlotConnectionStorage.shared.save(source, pageId: currentPageId, groupId: group.id)
        }
        showToast("已批量应用当前连接到本页 \(groups.count) 个槽位组")
    }

    func applyCurrentConnectionMapToAllPagesAndGroups() {
        let source = currentConnectionMap
        guard !source.edges.isEmpty else {
            showToast("当前没有可批量应用的连接")
            return
        }
        var count = 0
        for page in pages {
            let groups = specialSlots.filter { $0.pageId == page.id }
            for group in groups {
                SlotConnectionStorage.shared.save(source, pageId: page.id, groupId: group.id)
                count += 1
            }
        }
        showToast("已批量应用当前连接到全部页面 \(count) 个槽位组")
    }

    private func confirmReplaceCurrentConnections() -> Bool {
        let alert = NSAlert()
        alert.messageText = "替换当前连接？"
        alert.informativeText = "当前槽位组已有连接。导入模板会替换现有连接，但不会修改槽位内容。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "替换连接")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - v2.7.7 Bulk Export / Clear

    func exportConnectionTemplate(scope: ConnectionExportScope) {
        switch scope {
        case .currentGroup:
            exportConnectionTemplate()
        case .currentPage:
            var entries: [SlotConnectionTemplateBundleEntry] = []
            for group in currentPageSlotGroups {
                let map = SlotConnectionStorage.shared.load(pageId: currentPageId, groupId: group.id)
                if !map.edges.isEmpty {
                    entries.append(SlotConnectionTemplateBundleEntry(
                        pageId: currentPageId,
                        groupId: group.id,
                        groupName: group.name,
                        map: map
                    ))
                }
            }
            guard !entries.isEmpty else {
                showFloatingNotice(FloatingNotice(
                    title: "没有可导出的连接",
                    subtitle: "当前页面没有连接数据",
                    iconName: "exclamationmark.triangle.fill",
                    kind: .warning
                ))
                return
            }
            let panel = NSSavePanel()
            let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
            panel.nameFieldStringValue = "ClipSlots页面模板-\(df.string(from: Date())).clipslotslink"
            panel.canCreateDirectories = true
            if #available(macOS 12.0, *) {
                panel.allowedContentTypes = [UTType(filenameExtension: "clipslotslink") ?? .json]
            } else {
                panel.allowedFileTypes = ["clipslotslink", "json"]
            }
            guard panel.runModal() == .OK, let rawURL = panel.url else { return }
            let url = SlotConnectionTemplateService.sanitizedExportURL(rawURL)
            do {
                let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.7.7"
                let bundle = SlotConnectionTemplateService.makeBundleTemplate(from: entries, name: "ClipSlots 页面连接模板", appVersion: appVersion)
                let data = try SlotConnectionTemplateService.encodeBundle(bundle)
                try data.write(to: url, options: [.atomic])
                showFloatingNotice(FloatingNotice(
                    title: "已导出页面连接模板",
                    subtitle: "包含 \(entries.count) 个槽位组",
                    iconName: "square.and.arrow.up.fill",
                    kind: .success
                ))
            } catch {
                showFloatingNotice(FloatingNotice(title: "导出失败", subtitle: error.localizedDescription, iconName: "xmark.circle.fill", kind: .error))
            }
        case .all:
            let allMaps = SlotConnectionStorage.shared.allCachedMaps()
            var entries: [SlotConnectionTemplateBundleEntry] = []
            for (key, map) in allMaps where !map.edges.isEmpty {
                let parts = key.components(separatedBy: "::")
                let pageId = parts.first ?? ""
                let groupId = parts.count > 1 ? parts[1] : (parts.last ?? "")
                // v2.7.65 BUGFIX: previously used `parts.last` (the groupId / UUID)
                // as the display name, so imported groups were named with raw UUIDs.
                // Resolve the real group name from specialSlots, falling back to a
                // friendly label instead of the opaque id.
                let resolvedName = specialSlots.first { $0.id == groupId }?.name
                    ?? "导入组 \(entries.count + 1)"
                entries.append(SlotConnectionTemplateBundleEntry(
                    pageId: pageId,
                    groupId: groupId,
                    groupName: resolvedName,
                    map: map
                ))
            }
            guard !entries.isEmpty else {
                showFloatingNotice(FloatingNotice(title: "没有可导出的连接", subtitle: "没有找到连接数据", iconName: "exclamationmark.triangle.fill", kind: .warning))
                return
            }
            let panel = NSSavePanel()
            let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
            panel.nameFieldStringValue = "ClipSlots全部模板-\(df.string(from: Date())).clipslotslink"
            panel.canCreateDirectories = true
            if #available(macOS 12.0, *) {
                panel.allowedContentTypes = [UTType(filenameExtension: "clipslotslink") ?? .json]
            } else {
                panel.allowedFileTypes = ["clipslotslink", "json"]
            }
            guard panel.runModal() == .OK, let rawURL = panel.url else { return }
            let url = SlotConnectionTemplateService.sanitizedExportURL(rawURL)
            do {
                let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.7.7"
                let bundle = SlotConnectionTemplateService.makeBundleTemplate(from: entries, name: "ClipSlots 全部连接模板", appVersion: appVersion)
                let data = try SlotConnectionTemplateService.encodeBundle(bundle)
                try data.write(to: url, options: [.atomic])
                showFloatingNotice(FloatingNotice(
                    title: "已导出全部连接模板",
                    subtitle: "包含 \(entries.count) 个槽位组",
                    iconName: "square.and.arrow.up.fill",
                    kind: .success
                ))
            } catch {
                showFloatingNotice(FloatingNotice(title: "导出失败", subtitle: error.localizedDescription, iconName: "xmark.circle.fill", kind: .error))
            }
        }
    }

    func clearCurrentConnectionsWithoutConfirm() {
        currentConnectionMap = .empty
        saveConnectionMapForCurrentGroup()
        showFloatingNotice(FloatingNotice(
            title: "已清除当前槽位组连接",
            subtitle: "槽位内容未受影响",
            iconName: "trash.fill",
            kind: .success
        ))
    }

    func clearCurrentPageConnections() {
        for group in currentPageSlotGroups {
            SlotConnectionStorage.shared.save(.empty, pageId: currentPageId, groupId: group.id)
        }
        currentConnectionMap = .empty
        showFloatingNotice(FloatingNotice(
            title: "已清除当前页面连接",
            subtitle: "槽位内容未受影响",
            iconName: "trash.fill",
            kind: .success
        ))
    }

    func clearAllConnections() {
        SlotConnectionStorage.shared.deleteAll { _, _ in true }
        currentConnectionMap = .empty
        showFloatingNotice(FloatingNotice(
            title: "已清除全部连接",
            subtitle: "槽位内容未受影响",
            iconName: "trash.fill",
            kind: .success
        ))
    }

    func applyFullChainToCurrentPage() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.7.7"
        let template = SlotConnectionTemplateService.makeFullTenSlotChainTemplate(appVersion: appVersion)
        let map = SlotConnectionMap(edges: template.edges)
        for group in currentPageSlotGroups {
            SlotConnectionStorage.shared.save(map, pageId: currentPageId, groupId: group.id)
        }
        currentConnectionMap = map
        showFloatingNotice(FloatingNotice(
            title: "已应用到当前页面全部槽位组",
            subtitle: "粘贴槽位 1 时会串联粘贴整条链",
            iconName: "link.circle.fill",
            kind: .success
        ))
    }

    // MARK: - v2.7.1 Stable Connection Management

    func connectionChainSummaries() -> [[Int]] {
        currentConnectionMap.chainStarts()
            .map { currentConnectionMap.chainSlots(startingAt: $0) }
            .filter { $0.count > 1 }
    }

    func addManagedConnection(fromSlot: Int, toSlot: Int) {
        connectSlots(
            fromSlot: fromSlot,
            fromPort: defaultFromPort(from: fromSlot, to: toSlot),
            toSlot: toSlot,
            toPort: defaultToPort(from: fromSlot, to: toSlot)
        )
    }

    func deleteManagedConnection(_ edgeId: UUID) {
        var map = currentConnectionMap
        map.disconnect(edgeId: edgeId)
        currentConnectionMap = map
        saveConnectionMapForCurrentGroup()
        showFloatingNotice(FloatingNotice(
            title: "已删除连接",
            subtitle: "槽位内容未受影响",
            iconName: "link.badge.minus",
            kind: .info
        ))
    }

    private func defaultFromPort(from: Int, to: Int) -> SlotPort {
        if to == from + 1 { return .right }
        if to == from - 1 { return .left }
        if to == from + 5 { return .bottom }
        if to == from - 5 { return .top }
        return .right
    }

    private func defaultToPort(from: Int, to: Int) -> SlotPort {
        if to == from + 1 { return .left }
        if to == from - 1 { return .right }
        if to == from + 5 { return .top }
        if to == from - 5 { return .bottom }
        return .left
    }

    // MARK: - Clear

    func clearSlot(_ slot: Int) {
        let activeId = currentSpecialSlotId

        suppressWatcher() // v2.9.4 (#2): self-write
        cancelPendingClipboardRestore()
        specialStorage.clear(slot, in: activeId)

        ThumbnailProvider.shared.invalidateSlot(specialSlotId: activeId, slot: slot)

        var newSlots = slots
        newSlots[slot] = SlotContent()
        slots = newSlots
        slotRenderTokens["\(activeId)::\(slot)"] = UUID()

        var newLabels = labels
        newLabels.removeValue(forKey: slot)
        labels = newLabels

        loadedSpecialSlotId = activeId
        refreshTrigger = UUID()
        NSLog("[ClipSlots] CLEAR specialSlot=\(activeId) slot=\(slot)")
    }

    func clearSlotWithConfirmation(_ slot: Int) {
        captureUndoSnapshot(title: "清空槽位 \(slot)")
        if !specialSlotSettings.confirmBeforeClearSingleSlot {
            clearSlot(slot)
            return
        }

        let alert = NSAlert()
        alert.messageText = "清空槽位 \(slot)？"
        alert.informativeText = "该操作会删除当前槽位中的内容。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")

        let checkbox = NSButton(checkboxWithTitle: "不再提醒", target: nil, action: nil)
        alert.accessoryView = checkbox

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if checkbox.state == .on {
            do {
                try specialStorage.updateSettings { $0.confirmBeforeClearSingleSlot = false }
                specialSlotSettings.confirmBeforeClearSingleSlot = false
            } catch {
                NSLog("[ClipSlots] update confirmBeforeClearSingleSlot failed: \(error)")
            }
        }

        clearSlot(slot)
    }

    // MARK: - Label

    func setLabel(_ slot: Int, label: String?) {
        let activeId = currentSpecialSlotId

        suppressWatcher() // v2.9.4 (#2): self-write
        specialStorage.setLabel(slot, label: label, in: activeId)

        var newLabels = labels
        if let label = label, !label.isEmpty {
            newLabels[slot] = label
        } else {
            newLabels.removeValue(forKey: slot)
        }
        labels = newLabels
        loadedSpecialSlotId = activeId

        NSLog("[ClipSlots] setLabel specialSlot=\(activeId) slot=\(slot) label=\(label ?? "")")
    }

    // MARK: - v2.7.26 Hotkey Generation Guard
    // When config changes, remove old hotkeys before registering new ones.
    // Otherwise previous ctrl+option+number shortcuts can still fire and show HUD.
    func updateConfig(_ newConfig: AppConfig) {
        // v2.7.33: atomic replacement. Settings draft must not be active before
        // Save; after Save, no old hotkey reference may survive.
        HotKeyManager.shared.unregisterAll()
        hotkeyRegistrationErrors.removeAll()
        config = newConfig.normalizedForRuntime()
        config.save()
        onConfigChanged?()
        refreshTrigger = UUID()
        installLocalHotkeyGuardIfNeeded()
        objectWillChange.send()
    }

    // MARK: - Folder Import

    private let folderImportService = FolderImportService()
    private let batchImportService = BatchImportService()

    // MARK: - Toolbar Import (v2.6.4)

    /// Opens NSOpenPanel for multi-select files + folders, then shows import options.
    func startToolbarImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.message = "选择要导入的文件或文件夹（可多选）"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        presentImportOptions(for: panel.urls)
    }

    /// Show import mode picker for the selected URLs, then execute. (v2.6.7: SwiftUI sheet)
    func presentImportOptions(for urls: [URL]) {
        // Classify selection
        var folderCount = 0
        var fileCount = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { continue }
            if values.isDirectory == true { folderCount += 1 }
            else if values.isRegularFile == true { fileCount += 1 }
        }

        let totalItems = fileCount + folderCount
        guard totalItems > 0 else {
            showFloatingNotice(FloatingNotice(
                title: "没有可导入的文件",
                iconName: "tray", kind: .warning))
            return
        }

        // Single file: import directly without options
        if fileCount == 1 && folderCount == 0, let fileURL = urls.first {
            executeToolbarImport(urls: [fileURL], mode: .allTotal, sortRule: specialSlotSettings.folderImportSortRule)
            return
        }

        // v2.6.7: Show SwiftUI sheet instead of NSAlert
        let summary = ImportSelectionSummary(fileCount: fileCount, folderCount: folderCount)
        pendingImportSelection = PendingImportSelection(
            urls: urls,
            summary: summary,
            startSlot: 1,
            source: .toolbar
        )
    }

    /// Called when user confirms import options from the sheet. (v2.6.7)
    func executeImportSelection(_ selection: PendingImportSelection, choice: ImportChoiceMode) {
        let mode = resolveExpansionMode(choice: choice, summary: selection.summary)
        let expansion = folderImportService.expandSelection(
            urls: selection.urls,
            mode: mode,
            sortRule: specialSlotSettings.folderImportSortRule
        )

        guard !expansion.items.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "没有可导入的文件",
                subtitle: expansion.folderCount > 0 ? "文件夹为空或无可读取文件" : "",
                iconName: "tray",
                kind: .warning
            ))
            return
        }

        handleBatchSave(
            items: expansion.items,
            startSlot: selection.startSlot,
            expansion: expansion
        )
    }

    /// Expand URLs using the given mode and delegate to handleBatchSave.
    func executeToolbarImport(urls: [URL], mode: ImportLimitMode, sortRule: FolderImportSortRule) {
        let expansion = folderImportService.expandSelection(urls: urls, mode: mode, sortRule: sortRule)

        guard !expansion.items.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "没有可导入的文件",
                subtitle: expansion.folderCount > 0 ? "文件夹为空或无可读取文件" : "",
                iconName: "tray",
                kind: .warning
            ))
            return
        }

        handleBatchSave(
            items: expansion.items,
            startSlot: 1,
            expansion: expansion
        )
    }

    func importFolderIntoCurrentSpecialSlot(_ folderURL: URL) {
        suppressWatcher() // v2.9.4 (#2): self-write
        let activeId = currentSpecialSlotId
        let options = FolderImportOptions(
            maxFiles: specialSlotSettings.maxChildSlotsPerSpecialSlot,
            includeHiddenFiles: false,
            recursive: false,
            sortRule: specialSlotSettings.folderImportSortRule
        )

        do {
            let preview = try folderImportService.preview(folderURL: folderURL, options: options)

            guard preview.totalImportableCount > 0 else {
                showAlert(message: "该文件夹中没有可导入文件")
                return
            }

            // Overflow check
            if preview.overflowed, !specialSlotSettings.suppressFolderOverflowWarning {
                let decision = confirmFolderOverflow(count: preview.totalImportableCount, max: options.maxFiles)
                switch decision {
                case .cancel: return
                case .confirm(let suppress):
                    if suppress {
                        try? specialStorage.updateSettings { $0.suppressFolderOverflowWarning = true }
                        specialSlotSettings.suppressFolderOverflowWarning = true
                    }
                }
            }

            // Overwrite check
            let hasContent = (1...config.slots).contains { !specialStorage.get($0, in: activeId).isEmpty }
            if hasContent && specialSlotSettings.confirmBeforeOverwrite {
                guard confirmOverwriteCurrentSpecialSlot() else { return }
            }

            // Clear and import
            ThumbnailProvider.shared.invalidateSpecialSlot(specialSlotId: activeId)

            suppressWatcher() // v2.9.4 (#2): re-bump after any modal so the write burst below stays suppressed
            try specialStorage.clearAllSlots(in: activeId)

            var successCount = 0
            var failCount = 0
            for (idx, fileURL) in preview.willImportFiles.enumerated() {
                let slotNumber = idx + 1
                var content = folderImportService.makeSlotContent(for: fileURL)
                // Regenerate identity so thumbnails and SwiftUI views refresh.
                content.contentId = UUID().uuidString
                content.updatedAt = Date().timeIntervalSince1970
                if specialStorage.set(slotNumber, content: content, in: activeId) {
                    successCount += 1
                } else {
                    failCount += 1
                }
            }

            try specialStorage.updateCurrentSpecialSlotSource(
                sourceType: .folderImport,
                sourcePath: folderURL.path
            )

            reloadAll()
            refreshTrigger = UUID()
            // v2.6.2: Floating notice instead of blocking alert
            showFloatingNotice(FloatingNotice(
                title: "已导入 \(successCount) 个文件",
                subtitle: failCount > 0 ? "\(failCount) 个失败" : "当前槽位组",
                iconName: failCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                kind: failCount > 0 ? .warning : .success
            ))

        } catch {
            NSLog("[ClipSlots] Folder import error: \(error)")
            showAlert(message: "导入失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Dialogs

    private func confirmFolderOverflow(count: Int, max: Int) -> FolderOverflowDecision {
        let alert = NSAlert()
        alert.messageText = "文件数量超过槽位上限"
        alert.informativeText = "当前文件夹包含 \(count) 个可导入文件，但每个槽位组最多只能保存 \(max) 个子槽位。是否仅导入排序后的前 \(max) 个文件？"
        alert.addButton(withTitle: "确认导入前 \(max) 个")
        alert.addButton(withTitle: "取消")

        let checkbox = NSButton(checkboxWithTitle: "不再提醒", target: nil, action: nil)
        alert.accessoryView = checkbox

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            return .confirm(suppressFutureWarning: checkbox.state == .on)
        }
        return .cancel
    }

    private func confirmOverwriteCurrentSpecialSlot() -> Bool {
        let alert = NSAlert()
        alert.messageText = "是否覆盖当前槽位内容？"
        alert.informativeText = "批量导入会清空当前槽位组下已有的子槽位内容。是否继续？"
        alert.addButton(withTitle: "继续并覆盖")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    // MARK: - File Detection

    func handleCapturedContentForSave(_ content: SlotContent, targetSlot: Int) {
        suppressWatcher() // v2.9.4 (#2): self-write (covers all save/import sub-paths below)
        let activeId = currentSpecialSlotId
        let folderURLs = content.detectedFolderURLs

        // v2.6.4: Route multi-folder to import mode picker
        if folderURLs.count > 1 {
            presentImportModePickerForFolder(folderURLs, startSlot: targetSlot)
            return
        }
        if folderURLs.count == 1 {
            handleSingleFolderSave(folderURLs[0], targetSlot: targetSlot)
            return
        }

        // v2.6.0: Detect batch file save
        if let batchItems = batchImportService.detectBatchItems(from: content),
           batchItems.count > 1 {
            handleBatchSave(items: batchItems, startSlot: targetSlot)
            return
        }

        // Check if overwriting (before save)
        let existingBeforeSave = specialStorage.get(targetSlot, in: activeId)

        // Normal save — regenerate identity so thumbnails and SwiftUI views refresh.
        var savedContent = content
        savedContent.contentId = UUID().uuidString
        savedContent.updatedAt = Date().timeIntervalSince1970
        // v2.7.74: overwriting a slot's main content should keep its attachments,
        // which belong to the slot rather than the captured clipboard payload.
        savedContent.attachments = existingBeforeSave.attachments

        ThumbnailProvider.shared.invalidateSlot(specialSlotId: activeId, slot: targetSlot)

        let success = specialStorage.set(targetSlot, content: savedContent, in: activeId)

        guard success else {
            NSLog("[ClipSlots] SAVE FAIL specialSlot=\(activeId) slot=\(targetSlot)")
            showFloatingNotice(FloatingNotice(
                title: "保存失败",
                subtitle: "槽位 \(targetSlot) 写入失败，请重试",
                iconName: "xmark.circle.fill",
                kind: .error
            ), duration: 2.5)
            return
        }
        var newSlots = slots
        newSlots[targetSlot] = savedContent
        slots = newSlots
        slotRenderTokens["\(activeId)::\(targetSlot)"] = UUID()
        loadedSpecialSlotId = activeId
        refreshTrigger = UUID()

        // Update label to file name if present
        if let fileURL = savedContent.primaryFileURL {
            setLabel(targetSlot, label: fileURL.lastPathComponent)
        }

        NSLog("[ClipSlots] SAVE OK specialSlot=\(activeId) slot=\(targetSlot) contentId=\(savedContent.contentId) preview=\(savedContent.preview)")

        // v2.6.2: Floating notice with content summary
        if UserDefaults.standard.showSaveToast {
            let summary = savedContent.noticeSummary
            let isOverwrite = !existingBeforeSave.isEmpty
            showFloatingNotice(FloatingNotice(
                title: isOverwrite ? "已覆盖槽位 \(targetSlot)" : "已保存到槽位 \(targetSlot)",
                subtitle: "\(summary.typeTitle) · \(summary.detail)",
                iconName: summary.iconName,
                kind: .success
            ))
        }
    }

    // MARK: - Batch Save (v2.6.1)

    private let maxAutoCreatePages: Int = 20

    private func handleBatchSave(
        items: [BatchImportItem],
        startSlot: Int,
        expansion: BatchImportExpansionResult? = nil
    ) {
        suppressWatcher() // v2.9.4 (#2): self-write (batch); re-bumped in the loop below
        // v2.6.2: Safety guards
        guard !isBatchSaving else {
            showFloatingNotice(FloatingNotice(
                title: "正在批量保存，请稍候", iconName: "hourglass", kind: .info))
            return
        }

        guard !items.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "没有可保存的文件", iconName: "tray", kind: .warning))
            return
        }

        guard (1...config.slots).contains(startSlot) else {
            showFloatingNotice(FloatingNotice(
                title: "起始槽位无效", iconName: "exclamationmark.triangle.fill", kind: .error))
            return
        }

        guard currentPage != nil, currentSpecialSlot != nil else {
            showFloatingNotice(FloatingNotice(
                title: "页面或槽位组不存在", iconName: "exclamationmark.triangle.fill", kind: .error))
            return
        }

        let activeId = currentSpecialSlotId
        let originalPageId = currentPageId
        let pageGroups = currentPageSlotGroups
        let allPages = pages

        // Build target slot list: [(specialSlotId, slot)]
        var targets: [(specialSlotId: String, slot: Int)] = []

        // Current group from startSlot
        for s in startSlot...config.slots {
            targets.append((activeId, s))
        }

        // Find current group index
        let currentGroupIdx = pageGroups.firstIndex(where: { $0.id == activeId }) ?? 0

        // Subsequent existing groups in this page
        for i in (currentGroupIdx + 1)..<pageGroups.count {
            for s in 1...config.slots {
                targets.append((pageGroups[i].id, s))
            }
        }

        // Capacity: groups in current page + new groups we can create
        let existingCount = pageGroups.count
        let maxNewGroupsInPage = max(0, specialSlotSettings.maxSpecialSlots - existingCount)
        let newGroupsNeededInPage = min(maxNewGroupsInPage,
            max(0, (items.count - targets.count + config.slots - 1) / config.slots))

        // Calculate page-level capacity
        let capacityInPage = targets.count + newGroupsNeededInPage * config.slots
        var remainingAfterPage = max(0, items.count - capacityInPage)
        let pagesNeeded = min(maxAutoCreatePages,
            (remainingAfterPage + specialSlotSettings.maxSpecialSlots * config.slots - 1)
                / (specialSlotSettings.maxSpecialSlots * config.slots))

        let totalCapacity = capacityInPage + pagesNeeded * specialSlotSettings.maxSpecialSlots * config.slots

        let plan = BatchSavePlan(
            items: items,
            startSlot: startSlot,
            willOverwriteCount: countOverwrites(targets: targets.prefix(items.count)),
            needsNewGroups: newGroupsNeededInPage + pagesNeeded * specialSlotSettings.maxSpecialSlots,
            skippedFolderCount: 0,
            skippedUnsupportedCount: 0,
            availableCapacity: totalCapacity
        )

        // Show confirmation (updated to include page info)
        if !UserDefaults.standard.skipBatchSaveConfirmation || plan.willOverwriteCount > 0 {
            guard confirmBatchSaveV2(plan,
                currentGroupName: currentSpecialSlot?.name ?? "槽位组",
                pagesNeeded: pagesNeeded) else {
                return
            }
        }

        // Check capacity
        if plan.willSkipCount > 0 {
            guard confirmPartialBatchSave(plan) else {
                return
            }
        }

        isBatchSaving = true
        defer { isBatchSaving = false }

        suppressWatcher() // v2.9.4 (#2): re-bump after confirmation modals, before the create/write burst

        var savedCount = 0
        var failedCount = 0
        var overwrittenCount = 0
        var createdGroupCount = 0
        var createdPageCount = 0
        let itemsToSave = plan.willSaveCount

        // Create new groups in current page
        if newGroupsNeededInPage > 0 {
        for n in 1...newGroupsNeededInPage {
            let groupName = uniqueImportGroupName(existingNames: Set(pageGroups.map { $0.name }), startNumber: n)
            do {
                let newGroup = try specialStorage.createSpecialSlot(name: groupName, pageId: originalPageId)
                for s in 1...config.slots {
                    targets.append((newGroup.id, s))
                }
                createdGroupCount += 1
            } catch {
                NSLog("[ClipSlots] Batch save: failed to create group '\(groupName)': \(error)")
                break
            }
        }
        } // end if newGroupsNeededInPage > 0

        // Create new pages if needed
        remainingAfterPage = max(0, itemsToSave - targets.count)
        let actualPagesNeeded = min(pagesNeeded,
            (remainingAfterPage + specialSlotSettings.maxSpecialSlots * config.slots - 1)
                / (specialSlotSettings.maxSpecialSlots * config.slots))

        let existingPageNames = Set(allPages.map { $0.name })
        if actualPagesNeeded > 0 {
        for pn in 1...actualPagesNeeded {
            let pageName = uniqueImportPageName(existingNames: existingPageNames, startNumber: pn + createdPageCount)
            do {
                let newPage = try specialStorage.createPage(name: pageName, withDefaultGroup: false).page
                createdPageCount += 1
                // Create groups in the new page (up to maxSpecialSlots)
                let groupsNeededInPage = min(specialSlotSettings.maxSpecialSlots,
                    max(0, (itemsToSave - targets.count + config.slots - 1) / config.slots))
                if groupsNeededInPage > 0 {
                for gn in 1...groupsNeededInPage {
                    let groupName = "导入 \(gn)"
                    do {
                        let newGroup = try specialStorage.createSpecialSlot(name: groupName, pageId: newPage.id)
                        for s in 1...config.slots {
                            targets.append((newGroup.id, s))
                        }
                        createdGroupCount += 1
                    } catch {
                        NSLog("[ClipSlots] Batch save: failed to create group in page '\(pageName)': \(error)")
                        break
                    }
                }
                } // end if groupsNeededInPage > 0
            } catch {
                NSLog("[ClipSlots] Batch save: failed to create page: \(error)")
                break
            }
        }
        } // end if actualPagesNeeded > 0

        // Refresh state
        specialSlots = specialStorage.loadIndex().specialSlots
        pages = specialStorage.loadIndex().pages

        // Save items to targets
        for (index, item) in items.enumerated() {
            guard index < itemsToSave, index < targets.count else { break }
            suppressWatcher() // v2.9.4 (#2): keep the self-write window fresh during a long batch
            let target = targets[index]
            var content = batchImportService.makeSlotContent(for: item.fileURL)
            content.contentId = UUID().uuidString
            content.updatedAt = Date().timeIntervalSince1970

            // Check if overwriting
            let existing = specialStorage.get(target.slot, in: target.specialSlotId)
            let isOverwrite = !existing.isEmpty

            let ok = specialStorage.set(target.slot, content: content, in: target.specialSlotId)
            if ok {
                if isOverwrite { overwrittenCount += 1 }
                // Set label to file name
                specialStorage.setLabel(target.slot, label: item.fileName, in: target.specialSlotId)
                savedCount += 1
            } else {
                failedCount += 1
            }
        }

        // Switch back to original page if we navigated away
        if pagesNeeded > 0 {
            try? specialStorage.switchToPage(id: originalPageId)
        }

        // Reload current slots and show toast
        reloadAll()
        refreshTrigger = UUID()

        // Count source folders
        let sourceFolderNames = Set(items.prefix(itemsToSave).compactMap { $0.sourceFolderName })
        let folderSourceCount = sourceFolderNames.count

        var parts: [String] = []
        parts.append("已保存 \(savedCount) 个文件")
        if overwrittenCount > 0 { parts.append("覆盖 \(overwrittenCount) 个槽位") }
        if createdPageCount > 0 { parts.append("新建 \(createdPageCount) 个页面") }
        if createdGroupCount > 0 { parts.append("新建 \(createdGroupCount) 个槽位组") }
        if folderSourceCount > 0 { parts.append("来自 \(folderSourceCount) 个文件夹") }
        if failedCount > 0 { parts.append("\(failedCount) 个失败") }

        // v2.6.4: Include expansion context when available
        if let exp = expansion, exp.limitedByMode {
            switch exp.mode {
            case .firstTenTotal:
                parts.append("已按设置只导入前 10 个")
            case .firstTenPerFolder:
                parts.append("每个文件夹前 10 个")
            default:
                break
            }
        }

        let toast = parts.joined(separator: "，")
        if UserDefaults.standard.showSaveToast {
            let iconName = failedCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
            showFloatingNotice(FloatingNotice(
                title: "已批量保存 \(savedCount) 个文件",
                subtitle: parts.dropFirst().joined(separator: "，"),
                iconName: iconName,
                kind: failedCount > 0 ? .warning : .success
            ), duration: 2.5)
        }

        NSLog("[ClipSlots] Batch save complete: \(toast)")
    }

    private func countOverwrites(targets: ArraySlice<(specialSlotId: String, slot: Int)>) -> Int {
        targets.filter { target in
            !specialStorage.get(target.slot, in: target.specialSlotId).isEmpty
        }.count
    }

    private func uniqueImportGroupName(existingNames: Set<String>, startNumber: Int) -> String {
        var n = startNumber
        while true {
            let name = "导入 \(n)"
            if !existingNames.contains(name) { return name }
            n += 1
        }
    }

    private func uniqueImportPageName(existingNames: Set<String>, startNumber: Int) -> String {
        var n = startNumber
        while true {
            let name = "导入页面 \(n)"
            if !existingNames.contains(name) { return name }
            n += 1
        }
    }

    private func confirmBatchSaveV2(_ plan: BatchSavePlan, currentGroupName: String, pagesNeeded: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "批量保存文件？"
        alert.alertStyle = .informational

        var lines: [String] = []
        lines.append("即将保存 \(plan.items.count) 个文件。")
        lines.append("")
        let pageName = currentPage?.name ?? "页面"
        lines.append("起点：页面「\(pageName)」/ \(currentGroupName) / 槽位 \(plan.startSlot)")
        if pagesNeeded > 0 {
            lines.append("将新建：\(pagesNeeded) 个页面")
        }
        if plan.needsNewGroups > 0 {
            lines.append("将新建：\(plan.needsNewGroups) 个槽位组")
        }
        if plan.willOverwriteCount > 0 {
            lines.append("将覆盖：\(plan.willOverwriteCount) 个已有槽位")
        }

        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "开始保存")
        alert.addButton(withTitle: "取消")

        if plan.willOverwriteCount > 0 {
            let checkbox = NSButton(checkboxWithTitle: "以后覆盖时不再提醒", target: nil, action: nil)
            alert.accessoryView = checkbox
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if checkbox.state == .on {
                    UserDefaults.standard.set(true, forKey: UserPreferenceKeys.skipOverwriteConfirmation)
                }
                return true
            }
            return false
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmBatchSave(_ plan: BatchSavePlan, currentGroupName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "批量保存文件？"
        alert.alertStyle = .informational

        var lines: [String] = []
        lines.append("即将保存 \(plan.items.count) 个文件。")
        lines.append("")
        let pageName = currentPage?.name ?? "页面"
        lines.append("起点：页面「\(pageName)」/ \(currentGroupName) / 槽位 \(plan.startSlot)")
        if plan.needsNewGroups > 0 {
            lines.append("将新建：\(plan.needsNewGroups) 个槽位组")
        }
        if plan.willOverwriteCount > 0 {
            lines.append("将覆盖：\(plan.willOverwriteCount) 个已有槽位")
        }

        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "开始保存")
        alert.addButton(withTitle: "取消")

        if plan.willOverwriteCount > 0 {
            let checkbox = NSButton(checkboxWithTitle: "以后覆盖时不再提醒", target: nil, action: nil)
            alert.accessoryView = checkbox
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if checkbox.state == .on {
                    UserDefaults.standard.set(true, forKey: UserPreferenceKeys.skipOverwriteConfirmation)
                }
                return true
            }
            return false
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmPartialBatchSave(_ plan: BatchSavePlan) -> Bool {
        let alert = NSAlert()
        alert.messageText = "只能保存部分文件"
        alert.informativeText = "当前可用容量只能保存前 \(plan.willSaveCount) 个文件，剩余 \(plan.willSkipCount) 个文件无法保存。\n\n原因：当前页面的槽位组数量已达到上限（\(specialSlotSettings.maxSpecialSlots) 个）。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存可用部分")
        alert.addButton(withTitle: "取消")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func handleSingleFolderSave(_ folderURL: URL, targetSlot: Int) {
        let alert = NSAlert()
        alert.messageText = "检测到文件夹"
        alert.informativeText = "当前剪贴板内容是文件夹 (\(folderURL.lastPathComponent))。\n你想如何处理？"
        alert.addButton(withTitle: "批量导入文件...")
        alert.addButton(withTitle: "作为普通文件保存")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // v2.6.4: Show import mode picker (first 10 / all)
            presentImportModePickerForFolder([folderURL], startSlot: targetSlot)
        case .alertSecondButtonReturn:
            var content = folderImportService.makeSlotContent(for: folderURL)
            content.contentId = UUID().uuidString
            content.updatedAt = Date().timeIntervalSince1970
            let activeId = currentSpecialSlotId
            ThumbnailProvider.shared.invalidateSlot(specialSlotId: activeId, slot: targetSlot)
            suppressWatcher() // v2.9.4 (#2): self-write (bump right before the write, after the modal)
            let success = specialStorage.set(targetSlot, content: content, in: activeId)
            guard success else {
                NSLog("[ClipSlots] save folder as normal FAIL specialSlot=\(activeId) slot=\(targetSlot)")
                return
            }
            var newSlots = slots
            newSlots[targetSlot] = content
            slots = newSlots
            slotRenderTokens["\(activeId)::\(targetSlot)"] = UUID()
            loadedSpecialSlotId = activeId
            refreshTrigger = UUID()
            let summary = content.noticeSummary
            showFloatingNotice(FloatingNotice(
                title: "已保存到槽位 \(targetSlot)",
                subtitle: "\(summary.typeTitle) · \(summary.detail)",
                iconName: summary.iconName,
                kind: .success
            ))
        default:
            break
        }
    }

    /// Show import mode picker for hotkey-sourced folder import. (v2.6.7: SwiftUI sheet)
    private func presentImportModePickerForFolder(_ folderURLs: [URL], startSlot: Int) {
        let folderCount = folderURLs.count
        let summary = ImportSelectionSummary(fileCount: 0, folderCount: folderCount)
        // v2.6.7: Bring window forward so the sheet is visible
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        pendingImportSelection = PendingImportSelection(
            urls: folderURLs,
            summary: summary,
            startSlot: startSlot,
            source: .hotkey
        )
    }

    func createSpecialSlotAndImportFolder(_ folderURL: URL) {
        suppressWatcher() // v2.9.4 (#2): self-write (creates + switches group, then imports)
        do {
            let name = folderURL.lastPathComponent
            let slot = try specialStorage.createSpecialSlot(
                name: name,
                sourceType: .folderImport,
                sourcePath: folderURL.path
            )
            try specialStorage.switchToSpecialSlot(id: slot.id)
            reloadAll()
            importFolderIntoCurrentSpecialSlot(folderURL)
        } catch {
            NSLog("[ClipSlots] createSpecialSlotAndImportFolder error: \(error)")
            showAlert(message: "创建槽位组失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Global Search (v2.5.2)

    /// Return all searchable slots across all pages and groups (read-only).
    func allSearchableSlots() -> [SlotGlobalSearchResult] {
        var results: [SlotGlobalSearchResult] = []

        for page in pages {
            let groups = specialSlots.filter { $0.pageId == page.id }.sorted { $0.order < $1.order }
            for group in groups {
                let storage = specialStorage.slotStorage(for: group.id)
                let snapshot = storage.snapshot()
                for (slot, content) in snapshot {
                    let label = storage.getLabel(slot) ?? ""
                    results.append(SlotGlobalSearchResult(
                        pageId: page.id,
                        pageName: page.name,
                        groupId: group.id,
                        groupName: group.name,
                        slot: slot,
                        content: content,
                        label: label,
                        pageOrder: page.order,
                        groupOrder: group.order
                    ))
                }
            }
        }

        return results
    }
}

// MARK: - v2.7.33 HTML Text Extractor

private enum HTMLTextExtractor {
    static func plainText(from html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              ) else { return html }
        return attr.string
    }
}

// MARK: - v2.7.33 Config Normalizer

private extension AppConfig {
    func normalizedForRuntime() -> AppConfig {
        var copy = self
        copy.saveKey = HotkeyTemplateNormalizer.normalizedShortcut(saveKey, allowsSlotPlaceholder: true)
        copy.pasteKey = HotkeyTemplateNormalizer.normalizedShortcut(pasteKey, allowsSlotPlaceholder: true)
        copy.radialKey = HotkeyTemplateNormalizer.normalizedShortcut(radialKey, allowsSlotPlaceholder: false)
        return copy
    }
}

// MARK: - v2.7.34 HTML String Helpers

private extension String {
    func clipSlotsPlainTextFromHTML() -> String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clipSlotsHTMLPreviewSummary(fallback: String) -> String {
        let text = clipSlotsPlainTextFromHTML()
        if !text.isEmpty { return text }
        return fallback.isEmpty ? "[HTML]" : fallback
    }
}

enum AppearanceDefaults {
    static func ensureDefaultDarkIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "appearanceMode") == nil else { return }
        defaults.set(ThemeMode.dark.rawValue, forKey: "appearanceMode")
    }
}
