import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: SlotStoreObservable?
    private let hotkeyManager = HotKeyManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupHotKeys()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregisterAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func setupHotKeys() {
        guard let store = store else { return }
        hotkeyManager.register(
            config: store.config,
            onPaste: { [weak self] slot in
                self?.store?.pasteSlot(slot)
            },
            onSave: { [weak self] slot in
                self?.store?.saveToSlot(slot)
            }
        )
    }

    func reloadHotkeys() {
        hotkeyManager.unregisterAll()
        setupHotKeys()
    }
}
