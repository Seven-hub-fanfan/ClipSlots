import SwiftUI
import Cocoa

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
        .onChange(of: NSApplication.shared.keyWindow?.title) { _ in
            // Keep app responsive
        }

        Settings {
            SettingsView(config: store.config) { newConfig in
                store.updateConfig(newConfig)
                appDelegate.reloadHotkeys()
            }
        }
    }
}

// Observable object to bridge AppDelegate and SwiftUI
final class SlotStoreObservable: ObservableObject {
    @Published var config = AppConfig.load()
    @Published var slots: [Int: SlotContent] = [:]
    @Published var labels: [Int: String] = [:]
    @Published var refreshTrigger = UUID()

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
        let previous = clipboard.capture()
        _ = clipboard.restore(content)

        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            _ = self?.clipboard.restore(previous)
        }
    }

    func saveToSlot(_ slot: Int) {
        let content = clipboard.capture()
        storage.set(slot, content: content)
        loadSlots()
    }

    func clearSlot(_ slot: Int) {
        storage.clear(slot)
        loadSlots()
    }

    func copySlot(_ slot: Int) {
        let content = storage.get(slot)
        guard !content.isEmpty else { return }
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
    }
}
