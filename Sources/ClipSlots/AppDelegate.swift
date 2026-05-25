import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: SlotStoreObservable?
    private let hotkeyManager = HotKeyManager.shared
    private let radialMenuController = RadialMenuWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSLog("[ClipSlots] App launched, awaiting window for hotkey registration")
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregisterAll()
        radialMenuController.dismiss()
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
            },
            onRadial: { [weak self] in
                self?.showRadialMenu()
            }
        )
    }

    func reloadHotkeys() {
        hotkeyManager.unregisterAll()
        setupHotKeys()
    }

    private func showRadialMenu() {
        guard let store = store else { return }

        let mouseLocation = NSEvent.mouseLocation

        radialMenuController.show(
            at: mouseLocation,
            slots: store.slots,
            labels: store.labels,
            slotCount: store.config.slots,
            onSelect: { [weak self] slot in
                self?.radialMenuController.dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.store?.pasteSlot(slot)
                }
            },
            onDismiss: { [weak self] in
                self?.radialMenuController.dismiss()
            }
        )
    }
}
