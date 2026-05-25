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

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 460, minHeight: 360)
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
    var lastNonClipSlotsApp: NSRunningApplication?

    var onConfigChanged: (() -> Void)?

    let storage = SlotStorage.shared
    private let clipboard = ClipboardManager.shared

    init() {
        loadSlots()
        // Timer disabled to avoid overwriting UI state with stale disk data.
        // Re-enable after verifying saveToSlot stability.
        // timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
        //     self?.loadSlots()
        // }
    }

    func loadSlots() {
        var result: [Int: SlotContent] = [:]
        var labelMap: [Int: String] = [:]
        for slot in 1...config.slots {
            result[slot] = storage.get(slot)
            if let label = storage.getLabel(slot), !label.isEmpty {
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

    private func promptAccessibilityPermissionIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Poll until targetApp becomes frontmost or timeout.
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

    // MARK: - Unified Paste

    func pasteSlot(_ slot: Int, activate targetApp: NSRunningApplication? = nil) {
        let content = storage.get(slot)
        guard !content.isEmpty else {
            NSLog("[ClipSlots] pasteSlot ignored: slot \(slot) is empty")
            return
        }

        // Filter out self
        let cleanTargetApp: NSRunningApplication?
        if isSelfApp(targetApp) {
            cleanTargetApp = lastNonClipSlotsApp
        } else {
            cleanTargetApp = targetApp ?? lastNonClipSlotsApp
        }

        let types = content.items.flatMap { $0.map { $0.type } }
        NSLog("[ClipSlots] PASTE requested slot=\(slot) preview=\(content.preview) types=\(types) targetApp=\(cleanTargetApp?.localizedName ?? "nil")")

        guard AXIsProcessTrusted() else {
            NSLog("[ClipSlots] Accessibility permission not granted. Cannot paste.")
            promptAccessibilityPermissionIfNeeded()
            return
        }

        let previous = clipboard.capture()

        let doPasteAfterActivation = { [weak self] in
            guard let self = self else { return }

            let restored = self.clipboard.restore(content)
            guard restored else {
                NSLog("[ClipSlots] pasteSlot failed: restore slot \(slot) to clipboard failed")
                return
            }

            NSLog("[ClipSlots] Clipboard restored for slot \(slot), sending Cmd+V soon")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.sendPasteKeystroke()

                // Fixed delay to recover previous clipboard (instead of unreliable changeCount polling)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.80) {
                    _ = self.clipboard.restore(previous)
                    NSLog("[ClipSlots] Restored previous clipboard after paste")
                }
            }
        }

        if let app = cleanTargetApp {
            NSLog("[ClipSlots] Activating target app: \(app.localizedName ?? "unknown") pid=\(app.processIdentifier)")
            app.activate(options: [.activateIgnoringOtherApps])

            waitUntilFrontmost(app, timeout: 1.2) { success in
                let current = NSWorkspace.shared.frontmostApplication
                NSLog("[ClipSlots] waitUntilFrontmost result=\(success), current=\(current?.localizedName ?? "nil")")

                if success {
                    doPasteAfterActivation()
                } else {
                    NSLog("[ClipSlots] Target app did not become frontmost in time; trying paste anyway")
                    doPasteAfterActivation()
                }
            }
        } else {
            NSLog("[ClipSlots] No target app, pasting into current frontmost app")
            doPasteAfterActivation()
        }
    }

    /// Fallback: if no target app, copy to clipboard instead of pasting to self
    func pasteSlotFromUI(_ slot: Int) {
        guard let target = lastNonClipSlotsApp else {
            NSLog("[ClipSlots] UI paste has no target app, fallback to copy slot \(slot)")
            copySlot(slot)
            return
        }
        pasteSlot(slot, activate: target)
    }

    /// Send explicit Cmd+V keystroke: Cmd down → V down → V up → Cmd up
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

    // MARK: - Save

    func saveToSlot(_ slot: Int) {
        NSLog("[ClipSlots] saveToSlot requested slot=\(slot)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self = self else { return }

            let content = self.clipboard.capture()
            let types = content.items.flatMap { $0.map { $0.type } }

            NSLog("[ClipSlots] saveToSlot captured slot=\(slot), empty=\(content.isEmpty), preview=\(content.preview), types=\(types)")

            guard !content.isEmpty else {
                NSLog("[ClipSlots] saveToSlot ignored: clipboard is empty")
                return
            }

            self.storage.set(slot, content: content)

            DispatchQueue.main.async {
                var newSlots = self.slots
                newSlots[slot] = content
                self.slots = newSlots
                self.refreshTrigger = UUID()

                NSLog("[ClipSlots] saveToSlot updated UI slot=\(slot) preview=\(content.preview)")
            }
        }
    }

    func clearSlot(_ slot: Int) {
        storage.clear(slot)
        NSLog("[ClipSlots] CLEAR slot=\(slot)")
        loadSlots()
    }

    func copySlot(_ slot: Int) {
        let content = storage.get(slot)
        guard !content.isEmpty else { return }
        NSLog("[ClipSlots] COPY slot=\(slot) preview=\(content.preview)")
        _ = clipboard.restore(content)
    }

    // MARK: - Label

    func setLabel(_ slot: Int, label: String?) {
        storage.setLabel(slot, label: label)

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
}
