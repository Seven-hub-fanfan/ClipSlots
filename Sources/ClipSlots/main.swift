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
                    store.onConfigChanged = { [weak appDelegate] in
                        appDelegate?.reloadHotkeys()
                    }
                    appDelegate.setupHotKeys()
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
    @Published var config = AppConfig.load()
    @Published var slots: [Int: SlotContent] = [:]
    @Published var labels: [Int: String] = [:]
    @Published var refreshTrigger = UUID()

    // Special slot state
    @Published var specialSlots: [SpecialSlot] = []
    @Published var currentSpecialSlotId: String = "default"
    @Published var currentSpecialSlot: SpecialSlot?
    @Published var specialSlotSettings: SpecialSlotSettings = .default

    var lastNonClipSlotsApp: NSRunningApplication?

    var onConfigChanged: (() -> Void)?

    let specialStorage = SpecialSlotStorage.shared
    private let clipboard = ClipboardManager.shared
    private var timer: Timer?

    /// Cancellable delayed clipboard restore to prevent race with copy/save.
    private var pendingClipboardRestore: DispatchWorkItem?

    init() {
        loadSpecialSlots()
        loadSlots()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.loadSlots()
        }
    }

    // MARK: - Special Slots

    func loadSpecialSlots() {
        let index = specialStorage.loadIndex()
        specialSlots = index.specialSlots
        currentSpecialSlotId = index.currentSpecialSlotId
        currentSpecialSlot = index.specialSlots.first { $0.id == index.currentSpecialSlotId }
        specialSlotSettings = index.settings
    }

    func reloadAll() {
        loadSpecialSlots()
        loadSlots()
    }

    func switchSpecialSlot(id: String) {
        do {
            try specialStorage.switchToSpecialSlot(id: id)
            reloadAll()
            refreshTrigger = UUID()
        } catch {
            NSLog("[ClipSlots] switchSpecialSlot error: \(error)")
        }
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

    // MARK: - Slot Loading

    func loadSlots() {
        var result: [Int: SlotContent] = [:]
        var labelMap: [Int: String] = [:]
        for slot in 1...config.slots {
            result[slot] = specialStorage.get(slot)
            if let label = specialStorage.getLabel(slot), !label.isEmpty {
                labelMap[slot] = label
            }
        }
        slots = result
        labels = labelMap
    }

    // MARK: - Helpers

    private func isSelfApp(_ app: NSRunningApplication?) -> Bool {
        guard let app = app else { return false }
        return app.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func cancelPendingClipboardRestore() {
        pendingClipboardRestore?.cancel()
        pendingClipboardRestore = nil
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

        let content = specialStorage.get(slot)
        guard !content.isEmpty else {
            NSLog("[ClipSlots] COPY ignored: slot \(slot) empty")
            return
        }

        _ = clipboard.restore(content)
        NSLog("[ClipSlots] COPY slot=\(slot) preview=\(content.preview)")
    }

    // MARK: - Simple Paste (hotkeys, menu)

    func pasteSlot(_ slot: Int) {
        let content = specialStorage.get(slot)
        guard !content.isEmpty else {
            NSLog("[ClipSlots] pasteSlot ignored: slot \(slot) empty")
            return
        }

        guard AXIsProcessTrusted() else {
            NSLog("[ClipSlots] Accessibility permission not granted.")
            promptAccessibilityPermissionIfNeeded()
            return
        }

        cancelPendingClipboardRestore()

        let previous = clipboard.capture()
        guard clipboard.restore(content) else {
            NSLog("[ClipSlots] pasteSlot restore failed slot=\(slot)")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self = self else { return }
            self.sendPasteKeystroke()

            let restoreWorkItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                _ = self.clipboard.restore(previous)
                self.pendingClipboardRestore = nil
            }
            self.pendingClipboardRestore = restoreWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)
        }
    }

    // MARK: - Radial Paste (targetApp activation + waitUntilFrontmost)

    func pasteSlotToApp(_ slot: Int, targetApp: NSRunningApplication?) {
        let content = specialStorage.get(slot)
        guard !content.isEmpty else {
            NSLog("[ClipSlots] radial paste ignored: slot \(slot) empty")
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

        NSLog("[ClipSlots] PASTE radial slot=\(slot) preview=\(content.preview) targetApp=\(cleanTarget?.localizedName ?? "nil")")

        let previous = clipboard.capture()

        let performPaste = { [weak self] in
            guard let self = self else { return }

            guard self.clipboard.restore(content) else {
                NSLog("[ClipSlots] radial paste restore failed slot=\(slot)")
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self = self else { return }
                self.sendPasteKeystroke()

                let restoreWorkItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    _ = self.clipboard.restore(previous)
                    self.pendingClipboardRestore = nil
                }
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
        cancelPendingClipboardRestore()
        specialStorage.clear(slot)
        NSLog("[ClipSlots] CLEAR slot=\(slot)")
        loadSlots()
    }

    // MARK: - Label

    func setLabel(_ slot: Int, label: String?) {
        specialStorage.setLabel(slot, label: label)

        var newLabels = labels
        if let label = label, !label.isEmpty {
            newLabels[slot] = label
        } else {
            newLabels.removeValue(forKey: slot)
        }
        labels = newLabels

        NSLog("[ClipSlots] setLabel slot=\(slot) label=\(label ?? "")")
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
            let hasContent = (1...config.slots).contains { !specialStorage.get($0).isEmpty }
            if hasContent && specialSlotSettings.confirmBeforeOverwrite {
                guard confirmOverwriteCurrentSpecialSlot() else { return }
            }

            // Clear and import
            try specialStorage.clearAllSlotsInCurrentSpecialSlot()

            for (idx, fileURL) in preview.willImportFiles.enumerated() {
                let slotNumber = idx + 1
                let content = folderImportService.makeSlotContent(for: fileURL)
                specialStorage.set(slotNumber, content: content)
            }

            try specialStorage.updateCurrentSpecialSlotSource(
                sourceType: .folderImport,
                sourcePath: folderURL.path
            )

            reloadAll()
            refreshTrigger = UUID()
            showAlert(message: "已导入 \(preview.willImportFiles.count) 个文件到当前特殊槽位")

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
        specialStorage.set(targetSlot, content: content)
        var newSlots = slots
        newSlots[targetSlot] = content
        slots = newSlots
        refreshTrigger = UUID()
        NSLog("[ClipSlots] SAVE slot=\(targetSlot) preview=\(content.preview)")
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
            specialStorage.set(targetSlot, content: content)
            var newSlots = slots
            newSlots[targetSlot] = content
            slots = newSlots
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
