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
                        .keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: [.control])
                    Button("保存到槽位 \(slot)") { store.saveToSlot(slot) }
                        .keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: [.control, .option])
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
    @Published var hotkeyRegistrationErrors: [String] = []

    var lastNonClipSlotsApp: NSRunningApplication?

    var onConfigChanged: (() -> Void)?

    let specialStorage = SpecialSlotStorage.shared
    private let clipboard = ClipboardManager.shared
    private var timer: Timer?

    /// Cancellable delayed clipboard restore to prevent race with copy/save.
    private var pendingClipboardRestore: DispatchWorkItem?
    private var pendingClipboardRestoreContent: SlotContent?

    /// Pending paste keystroke work item. Cancelled when switching special slots.
    private var pendingPasteWorkItem: DispatchWorkItem?

    /// The special slot id that current in-memory `slots` / `labels` belong to.
    private var loadedSpecialSlotId: String?

    /// Prevents timer-triggered loadSlots from racing with async saves.
    private var isWritingSlots = false

    init() {
        NSLog("[ClipSlots] SlotStoreObservable init instanceID=\(instanceID)")
        loadSpecialSlots()
        loadSlots()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard !self.isWritingSlots else {
                NSLog("[ClipSlots] timer skip loadSlots: writing in progress")
                return
            }
            self.loadSlots()
        }
    }

    // MARK: - Special Slots

    func loadSpecialSlots() {
        let index = specialStorage.loadIndex()
        specialSlots = index.specialSlots

        let selectedId = index.selectedSpecialSlotId ?? index.currentSpecialSlotId
        let activeId = index.activeHotkeySpecialSlotId ?? index.currentSpecialSlotId

        currentSpecialSlotId = selectedId
        currentSpecialSlot = index.specialSlots.first { $0.id == selectedId }

        activeHotkeySpecialSlotId = activeId
        activeHotkeySpecialSlot = index.specialSlots.first { $0.id == activeId }

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

        isWritingSlots = true
        defer { isWritingSlots = false }

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

        activeHotkeySpecialSlotId = id
        activeHotkeySpecialSlot = specialSlots.first { $0.id == id }

        try? specialStorage.updateActiveHotkeySpecialSlot(id: id)

        refreshTrigger = UUID()
        showToast("Cmd+数字 已切换至「\(activeHotkeySpecialSlot?.name ?? id)」")
    }

    /// Preview AND activate: both UI and Cmd+number switch to this slot.
    func selectAndActivateSpecialSlot(id: String) {
        guard id != currentSpecialSlotId || id != activeHotkeySpecialSlotId else { return }
        guard specialSlots.contains(where: { $0.id == id }) else { return }

        let oldPreview = currentSpecialSlotId
        let oldActive = activeHotkeySpecialSlotId
        NSLog("[ClipSlots] selectAndActivateSpecialSlot preview:\(oldPreview)->\(id) hotkey:\(oldActive)->\(id)")

        cancelPendingPasteOperations(restoreClipboard: true)

        isWritingSlots = true
        defer { isWritingSlots = false }

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

    // MARK: - Delete Special Slot with Confirmation

    func deleteSpecialSlotWithConfirmation(id: String) {
        guard let target = specialSlots.first(where: { $0.id == id }) else { return }

        if specialSlotSettings.confirmBeforeDeleteSpecialSlot {
            let alert = NSAlert()
            alert.messageText = "删除特殊槽位？"
            alert.informativeText = "将删除特殊槽位「\(target.name)」及其全部槽位内容。此操作会移动到回收目录。"
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
        alert.messageText = "清空当前特殊槽位？"
        alert.informativeText = "将清空「\(currentSpecialSlot?.name ?? "当前特殊槽位")」中的全部槽位内容。此操作不会删除特殊槽位本身。"
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

        do {
            isWritingSlots = true
            defer { isWritingSlots = false }

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
            showAlert(message: "当前特殊槽位没有可粘贴的内容")
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
                return
            }

            let content = self.clipboard.capture()
            guard !content.isEmpty else {
                NSLog("[ClipSlots] captureSelectionAndSaveToSlot ignored: empty capture slot=\(slot)")
                return
            }

            self.handleCapturedContentForSave(content, targetSlot: slot)
        }
    }

    // MARK: - Save (lightweight, synchronous)

    func saveToSlot(_ slot: Int) {
        cancelPendingClipboardRestore()

        let content = clipboard.capture()
        guard !content.isEmpty else {
            NSLog("[ClipSlots] SAVE ignored: clipboard empty slot=\(slot)")
            return
        }

        handleCapturedContentForSave(content, targetSlot: slot)
    }

    // MARK: - Copy (lightweight)

    func copySlot(_ slot: Int) {
        cancelPendingClipboardRestore()

        let content = contentForSlot(slot)
        guard !content.isEmpty else {
            NSLog("[ClipSlots] COPY ignored: slot \(slot) empty")
            return
        }

        _ = clipboard.restore(content)
        NSLog("[ClipSlots] COPY slot=\(slot) preview=\(content.preview)")
    }

    // MARK: - Simple Paste (hotkeys, menu)

    func pasteSlot(_ slot: Int) {
        let activeId = currentSpecialSlotId

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

        var newSlots = slots
        newSlots[slot] = SlotContent()
        slots = newSlots

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

    func chooseFolderAndImportIntoCurrentSpecialSlot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择要批量导入的文件夹"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFolderIntoCurrentSpecialSlot(url)
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

            // Clear and import — block timer during writes
            isWritingSlots = true
            defer { isWritingSlots = false }

            try specialStorage.clearAllSlots(in: activeId)

            var successCount = 0
            var failCount = 0
            for (idx, fileURL) in preview.willImportFiles.enumerated() {
                let slotNumber = idx + 1
                let content = folderImportService.makeSlotContent(for: fileURL)
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
            showAlert(message: "已导入 \(successCount) 个文件到当前特殊槽位" + (failCount > 0 ? "，\(failCount) 个失败" : ""))

        } catch {
            NSLog("[ClipSlots] Folder import error: \(error)")
            showAlert(message: "导入失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Dialogs

    private func confirmFolderOverflow(count: Int, max: Int) -> FolderOverflowDecision {
        let alert = NSAlert()
        alert.messageText = "文件数量超过槽位上限"
        alert.informativeText = "当前文件夹包含 \(count) 个可导入文件，但每个特殊槽位最多只能保存 \(max) 个子槽位。是否仅导入排序后的前 \(max) 个文件？"
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
        alert.informativeText = "批量导入会清空当前特殊槽位下已有的子槽位内容。是否继续？"
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

        if folderURLs.count == 1 {
            handleSingleFolderSave(folderURLs[0], targetSlot: targetSlot)
            return
        }
        if folderURLs.count > 1 {
            handleSingleFolderSave(folderURLs[0], targetSlot: targetSlot)
            return
        }

        // Normal save
        isWritingSlots = true
        let success = specialStorage.set(targetSlot, content: content, in: activeId)
        isWritingSlots = false

        guard success else {
            NSLog("[ClipSlots] SAVE FAIL specialSlot=\(activeId) slot=\(targetSlot)")
            return
        }
        var newSlots = slots
        newSlots[targetSlot] = content
        slots = newSlots
        loadedSpecialSlotId = activeId
        refreshTrigger = UUID()
        NSLog("[ClipSlots] SAVE OK specialSlot=\(activeId) slot=\(targetSlot) preview=\(content.preview)")
    }

    private func handleSingleFolderSave(_ folderURL: URL, targetSlot: Int) {
        let alert = NSAlert()
        alert.messageText = "检测到文件夹"
        alert.informativeText = "当前剪贴板内容是文件夹 (\(folderURL.lastPathComponent))。\n你想如何处理？"
        alert.addButton(withTitle: "批量导入到当前特殊槽位")
        alert.addButton(withTitle: "创建新的特殊槽位并导入")
        alert.addButton(withTitle: "作为普通文件保存")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            importFolderIntoCurrentSpecialSlot(folderURL)
        case .alertSecondButtonReturn:
            createSpecialSlotAndImportFolder(folderURL)
        case .alertThirdButtonReturn:
            let content = folderImportService.makeSlotContent(for: folderURL)
            let activeId = currentSpecialSlotId
            isWritingSlots = true
            let success = specialStorage.set(targetSlot, content: content, in: activeId)
            isWritingSlots = false
            guard success else {
                NSLog("[ClipSlots] save folder as normal FAIL specialSlot=\(activeId) slot=\(targetSlot)")
                return
            }
            var newSlots = slots
            newSlots[targetSlot] = content
            slots = newSlots
            loadedSpecialSlotId = activeId
            refreshTrigger = UUID()
        default:
            break
        }
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
            showAlert(message: "创建特殊槽位失败: \(error.localizedDescription)")
        }
    }
}
