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
        // Remember which app is active before showing the menu
        let previousApp = NSWorkspace.shared.frontmostApplication

        radialMenuController.show(
            at: mouseLocation,
            slots: store.slots,
            labels: store.labels,
            slotCount: store.config.slots,
            onSelect: { [weak self] slot in
                self?.radialMenuController.dismiss()
                // Restore clipboard content immediately
                let content = store.storage.snapshot()[slot] ?? SlotContent()
                guard !content.isEmpty else { return }
                _ = ClipboardManager.shared.restore(content)

                // Activate the previous app, then send Cmd+V after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    previousApp?.activate(options: .activateIgnoringOtherApps)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        store.sendPasteKeystroke()
                    }
                }
            },
            onDismiss: { [weak self] in
                self?.radialMenuController.dismiss()
            }
        )
    }
}
