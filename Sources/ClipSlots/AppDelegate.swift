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
        let previousApp = NSWorkspace.shared.frontmostApplication
        NSLog("[ClipSlots] RADIAL show menu at (\(mouseLocation.x), \(mouseLocation.y)), previousApp=\(previousApp?.localizedName ?? "nil")")

        radialMenuController.show(
            at: mouseLocation,
            slots: store.slots,
            labels: store.labels,
            slotCount: store.config.slots,
            onSelect: { [weak self] slot in
                NSLog("[ClipSlots] RADIAL onSelect slot=\(slot)")
                self?.radialMenuController.dismiss()

                let content = store.storage.snapshot()[slot] ?? SlotContent()
                guard !content.isEmpty else {
                    NSLog("[ClipSlots] RADIAL slot \(slot) is empty, aborting")
                    return
                }

                let restored = ClipboardManager.shared.restore(content)
                NSLog("[ClipSlots] RADIAL clipboard restore slot=\(slot) preview=\(content.preview) ok=\(restored)")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let frontmost = NSWorkspace.shared.frontmostApplication
                    NSLog("[ClipSlots] RADIAL current frontmost=\(frontmost?.localizedName ?? "nil"), activating=\(previousApp?.localizedName ?? "nil")")
                    previousApp?.activate(options: .activateIgnoringOtherApps)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSLog("[ClipSlots] RADIAL sending Cmd+V")
                        store.sendPasteKeystroke()
                    }
                }
            },
            onDismiss: { [weak self] in
                NSLog("[ClipSlots] RADIAL onDismiss")
                self?.radialMenuController.dismiss()
            }
        )
    }
}
