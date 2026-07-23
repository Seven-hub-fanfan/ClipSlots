import Cocoa
import ClipSlotsKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: SlotStoreObservable?
    private let hotkeyManager = HotKeyManager.shared
    private let radialMenuController = RadialMenuWindowController()
    private var hotKeysReady = false

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

        NSLog("[ClipSlots] App launched, will setup hotkeys after store is set")
    }

    /// Called by main.swift after store is assigned. Idempotent — only sets up once.
    func setupHotKeysAfterStoreReady() {
        guard !hotKeysReady else { return }
        guard let store = store else {
            NSLog("[ClipSlots] ERROR: setupHotKeysAfterStoreReady called but store is nil")
            return
        }

        hotKeysReady = true

        NSLog("[ClipSlots] setupHotKeys storeInstanceID=\(store.instanceID) currentSpecialSlotId=\(store.currentSpecialSlotId) activeHotkeySpecialSlotId=\(store.activeHotkeySpecialSlotId)")

        store.onConfigChanged = { [weak self] in
            self?.reloadHotkeys()
        }

        setupHotKeys()
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

        let failures = hotkeyManager.register(
            config: store.config,
            onPaste: { [weak store] slot in
                guard let store = store else { return }
                NSLog("[ClipSlots] onPaste slot=\(slot) storeInstanceID=\(store.instanceID) activeHotkeySpecialSlotId=\(store.activeHotkeySpecialSlotId)")
                // v2.10.0: 方案A —— 拨杆状态分流。拨杆2「自动粘贴」开 → 走游标自动粘贴；关 → 原有单槽粘贴。
                if AutoModeState.shared.autoPasteEnabled {
                    store.autoPasteFromHotkey(slot)
                } else {
                    store.pasteSlot(slot)
                }
            },
            onSave: { [weak store] slot in
                guard let store = store else { return }
                NSLog("[ClipSlots] onSave slot=\(slot) storeInstanceID=\(store.instanceID) activeHotkeySpecialSlotId=\(store.activeHotkeySpecialSlotId)")
                // v2.10.0: 方案A —— 拨杆状态分流。拨杆1「自动存储」开 → 走空槽自动存储；关 → 原有单槽保存。
                if AutoModeState.shared.autoStoreEnabled {
                    store.autoStoreFromHotkey(slot)
                } else {
                    store.captureSelectionAndSaveToSlot(slot)
                }
            },
            onRadial: { [weak self] in
                self?.showRadialMenu()
            },
            onPrevious: { [weak store] in
                store?.switchToPreviousSlotGroup()
            },
            onNext: { [weak store] in
                store?.switchToNextSlotGroup()
            }
        )

        if !failures.isEmpty {
            store.hotkeyRegistrationErrors = failures
            NSLog("[ClipSlots] Hotkey registration failures: \(failures)")
        } else {
            store.hotkeyRegistrationErrors = []
        }
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
                    if let previousApp = previousApp ?? self.store?.lastNonClipSlotsApp {
                        self.store?.lastNonClipSlotsApp = previousApp
                    }
                    self.store?.pasteSlot(slot)
                }
            },
            onDismiss: { [weak self] in
                self?.radialMenuController.dismiss()
            }
        )
    }
}
