import SwiftUI
import Cocoa
import Carbon

/// Resolve the virtual key code that produces the letter 'v' on the current keyboard layout.
/// Falls back to 9 (US QWERTY) if the lookup fails.
fileprivate func virtualKeyForCharacterV() -> CGKeyCode {
    guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
        return 9
    }
    guard let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
        return 9
    }
    let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data
    guard let keyboardLayout = layoutData.withUnsafeBytes({ $0.bindMemory(to: UCKeyboardLayout.self).baseAddress }) else {
        return 9
    }

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
        if result == noErr, actualLen == 1, unicodeString[0] == 0x0076 { // 'v'
            return CGKeyCode(keyCode)
        }
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
                Button("关于 ClipSlots") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
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

    var onConfigChanged: (() -> Void)?

    private let storage = SlotStorage.shared
    private let clipboard = ClipboardManager.shared
    private var timer: Timer?

    init() {
        loadSlots()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.loadSlots()
        }
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
        DispatchQueue.main.async {
            self.slots = result
            self.labels = labelMap
            self.refreshTrigger = UUID()
        }
    }

    func pasteSlot(_ slot: Int) {
        let content = storage.get(slot)
        guard !content.isEmpty else { return }

        let types = content.items.flatMap { $0.map { $0.type } }
        NSLog("[ClipSlots] PASTE slot=\(slot) preview=\(content.preview) types=\(types)")

        let previous = clipboard.capture()
        _ = clipboard.restore(content)

        let vKey = virtualKeyForCharacterV()
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)

        clipboard.waitForPasteCompletion { [weak self] in
            guard let self = self else { return }
            let restored = self.clipboard.restore(previous)
            if !restored {
                NSLog("[ClipSlots] WARNING: Failed to restore previous clipboard after paste from slot \(slot)")
            }
        }
    }

    func saveToSlot(_ slot: Int) {
        let content = clipboard.capture()
        storage.set(slot, content: content)
        NSLog("[ClipSlots] SAVE slot=\(slot) preview=\(content.preview)")
        // Force UI update: new dict triggers @Published
        var newSlots = slots
        newSlots[slot] = content
        slots = newSlots
        loadSlots()
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

    func setLabel(_ slot: Int, label: String?) {
        storage.setLabel(slot, label: label)
        loadSlots()
    }

    func updateConfig(_ newConfig: AppConfig) {
        config = newConfig
        if newConfig.slots != slots.count {
            loadSlots()
        }
        onConfigChanged?()
    }
}
