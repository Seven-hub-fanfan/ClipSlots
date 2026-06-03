import SwiftUI
import Cocoa
import Carbon

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

/// Safe keyboard-shortcut helper: slot 10 maps to "0", slot > 10 has no shortcut.
fileprivate extension View {
    @ViewBuilder
    func keyboardShortcut(slot: Int, modifiers: SwiftUI.EventModifiers) -> some View {
        if slot < 10 {
            self.keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: modifiers)
        } else if slot == 10 {
            self.keyboardShortcut("0", modifiers: modifiers)
        }
    }
}

@main
struct ClipSlotsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = SlotStoreObservable()

    @AppStorage("appearanceMode") private var appearanceModeRaw = ThemeMode.system.rawValue
    private var appearanceMode: ThemeMode {
        ThemeMode(rawValue: appearanceModeRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 460, minHeight: 360)
                .preferredColorScheme(appearanceMode.preferredColorScheme)
                .onAppear {
                    appDelegate.store = store
                    appDelegate.setupHotKeysAfterStoreReady()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 540, height: 420)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("关于 ClipSlots") { NSApp.orderFrontStandardAboutPanel(nil) }
            }
            CommandMenu("槽位") {
                ForEach(1...store.config.slots, id: \.self) { slot in
                    Button("粘贴槽位 \(slot)") { store.pasteSlot(slot) }
                        .keyboardShortcut(slot: slot, modifiers: [.control])
                    Button("保存到槽位 \(slot)") { store.saveToSlot(slot) }
                        .keyboardShortcut(slot: slot, modifiers: [.control, .option])
                }
            }
        }
        .onChange(of: NSApplication.shared.keyWindow?.title) { _ in }

        Settings {
            SettingsView(config: store.config) { newConfig in
                store.updateConfig(newConfig)
                appDelegate.reloadHotkeys()
            }
        }
    }
}

final class SlotStoreObservable: ObservableObject {
    let instanceID = UUID().uuidString

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
    @Published var slotRenderTokens: [String: UUID] = [:]
    @Published var isBatchSaving: Bool = false

    // v2.6.7: import options sheet
    @Published var pendingImportSelection: PendingImportSelection?

    // v2.4 Page state
    @Published var pages: [SlotPage] = []
    @Published var currentPageId: String = "default_page"
    @Published var currentPage: SlotPage?

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

    /// The special slot id that current in-memory `slots` / `labels` belong to.
    private var loadedSpecialSlotId: String?

    init() {
        NSLog("[ClipSlots] SlotStoreObservable init instanceID=\(instanceID)")
        loadSpecialSlots()
        loadSlots()
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

        specialStorage.updateSelectedSpecialSlot(id: id)

        loadSlots()
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
        refreshTrigger = UUID()

        showToast("已切换至「\(currentSpecialSlot?.name ?? id)」")
    }

    func createSpecialSlot(name: String) {
        do {
            let slot = try specialStorage.createSpecialSlot(name: name)
            try specialStorage.switchToSpecialSlot(id: slot.id)
            reloadAll()
            refreshTrigger = UUID()
        } catch {
            NSLog("[ClipSlots] createSpecialSlot error: \(error)")
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
        do {
            try specialStorage.deleteSpecialSlot(id: id)
            reloadAll()
            refreshTrigger = UUID()
        } catch {
            NSLog("[ClipSlots] deleteSpecialSlot error: \(error)")
        }
    }

    func renameSpecialSlot(id: String, name: String) {
        do {
            try specialStorage.renameSpecialSlot(id: id, name: name)
            loadSpecialSlots()
        } catch {
            NSLog("[ClipSlots] renameSpecialSlot error: \(error)")
        }
    }

    // MARK: - Page Operations (v2.4)

    func createPage(name: String) {
        do {
            let page = try specialStorage.createPage(name: name)
            try specialStorage.switchToPage(id: page.id)
            reloadAll()
            showToast("已创建页面「\(page.name)」")
        } catch {
            NSLog("[ClipSlots] createPage error: \(error)")
            showAlert(message: "创建页面失败: \(error.localizedDescription)")
        }
    }

    func renamePage(id: String, name: String) {
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

    func clearAllSlotsInCurrentSpecialSlotWithConfirmation() {
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
    private func showToast(_ message: String) {
        toastMessage = message
        let captured = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
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
        cancelPendingClipboardRestore(restoreImmediately: restoreClipboard)
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
        guard !content.isEmpty else {
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

        // Global hotkey paste: always read directly from the current special slot on disk.
        let content = specialStorage.get(slot, in: activeId)

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
    }

    // MARK: - Radial Paste (targetApp activation + waitUntilFrontmost)

    func pasteSlotToApp(_ slot: Int, targetApp: NSRunningApplication?) {
        let activeId = currentSpecialSlotId

        // Always read from the currently active special slot on disk.
        let content = specialStorage.get(slot, in: activeId)

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

    // MARK: - Clear

    func clearSlot(_ slot: Int) {
        let activeId = currentSpecialSlotId

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

    func updateConfig(_ newConfig: AppConfig) {
        config = newConfig
        if newConfig.slots != slots.count {
            loadSlots()
        }
        onConfigChanged?()
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
                let newPage = try specialStorage.createPage(name: pageName)
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
