import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: SlotStoreObservable?
    private let hotkeyManager = HotKeyManager.shared
    private let radialMenuController = RadialMenuWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else {
                return
            }
            self.store?.lastNonClipSlotsApp = app
        }

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

        NSLog("[ClipSlots] setupHotKeys storeInstanceID=\(store.instanceID) currentSpecialSlotId=\(store.currentSpecialSlotId)")

        hotkeyManager.register(
            config: store.config,
            onPaste: { [weak store] slot in
                guard let store = store else { return }
                NSLog("[ClipSlots] onPaste slot=\(slot) storeInstanceID=\(store.instanceID) currentSpecialSlotId=\(store.currentSpecialSlotId)")
                store.pasteSlot(slot)
            },
            onSave: { [weak store] slot in
                guard let store = store else { return }
                NSLog("[ClipSlots] onSave slot=\(slot) storeInstanceID=\(store.instanceID) currentSpecialSlotId=\(store.currentSpecialSlotId)")
                store.captureSelectionAndSaveToSlot(slot)
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
        let frontmost = NSWorkspace.shared.frontmostApplication

        // Filter out ClipSlots itself
        let previousApp: NSRunningApplication?
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            previousApp = store.lastNonClipSlotsApp
        } else {
            previousApp = frontmost
            if let frontmost = frontmost {
                store.lastNonClipSlotsApp = frontmost
            }
        }

        NSLog("[ClipSlots] RADIAL show menu, previousApp=\(previousApp?.localizedName ?? "nil"), frontmost=\(frontmost?.localizedName ?? "nil")")

        radialMenuController.show(
            at: mouseLocation,
            store: store,
            onSelectSlot: { [weak self] slot in
                guard let self = self else { return }
                NSLog("[ClipSlots] RADIAL selected slot=\(slot)")
                self.radialMenuController.dismiss()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.store?.pasteSlotToApp(slot, targetApp: previousApp ?? self.store?.lastNonClipSlotsApp)
                }
            },
            onDismiss: { [weak self] in
                self?.radialMenuController.dismiss()
            }
        )
    }
}
