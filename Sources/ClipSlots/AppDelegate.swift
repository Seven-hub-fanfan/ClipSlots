import Cocoa
import ClipSlotsKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: SlotStoreObservable?
    private let hotkeyManager = HotKeyManager.shared
    private let radialMenuController = RadialMenuWindowController()
    private var hotKeysReady = false
    // P2-9 (v2.10.9): 保证「存储锁降级为无锁」通知只弹一次可见提示。
    private var didShowLocklessNotice = false

    // v2.10.49 (perf 第一批 P2「缓存内存压力回收」): 监听系统内存压力事件。图库很大时缩略图缓存
    // (ThumbnailProvider) 与内联图/缩略图/元数据解码缓存 (SlotContent) 会持续占用内存；收到
    // .warning/.critical 时主动清空这些「可重建」缓存（下次访问自动重新解码/生成），把内存让给系统。
    // 纯增益：只清可重建的内存缓存，绝不触碰磁盘数据。
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    // MARK: - v2.10.91 App 外观同步（修复 AppKit 弹窗缺浅色）

    /// 上一次已应用的主题原始值，用于在 UserDefaults 变更通知里过滤掉与外观无关的写入。
    private var lastAppliedAppearanceRaw: String?

    /// 把 App 内选择的主题同步到 `NSApp.appearance`。
    ///
    /// 背景：主题原先**只**经 SwiftUI 的 `.preferredColorScheme` 生效，作用域仅限 SwiftUI 视图层级。
    /// `NSAlert`（删除槽位组 / 清空 / 覆盖等确认框）、`NSMenu`、`NSOpenPanel` 这些由 AppKit 拥有、
    /// 不在 SwiftUI 层级内的界面，跟随的是 `NSApp.effectiveAppearance`；而 `NSApp.appearance` 一直是
    /// nil（= 跟随系统）。所以「App 选浅色 + 系统深色」时这些弹窗全是深色，看起来就是「弹窗没有浅色界面」。
    ///
    /// 设置 `NSApp.appearance` 后一处生效、覆盖全部 AppKit 界面，不必逐个 NSAlert 去设 window.appearance。
    /// `.system` 时置 nil，保持「跟随系统」语义不变。这只影响外观呈现，不改变任何主题偏好的存储与语义。
    private func applyAppAppearance() {
        let raw = UserDefaults.standard.string(forKey: "appearanceMode")
            ?? ThemeMode.dark.rawValue
        let mode = ThemeMode(rawValue: raw) ?? .dark
        lastAppliedAppearanceRaw = raw
        NSApp.appearance = mode.nsAppearance
    }

    /// 监听主题偏好变化。主题由 SwiftUI 侧的 `@AppStorage("appearanceMode")` 写入 UserDefaults，
    /// 这里观察 UserDefaults 变更并在原始值真的变化时才重新应用，避免无关写入触发多余的外观刷新。
    private func startObservingAppearancePreference() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let raw = UserDefaults.standard.string(forKey: "appearanceMode")
                ?? ThemeMode.dark.rawValue
            guard raw != self.lastAppliedAppearanceRaw else { return }
            self.applyAppAppearance()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // v2.10.91: 启动即把 App 主题同步到 NSApp.appearance，并持续跟随后续切换。
        // 修复「NSAlert 等 AppKit 弹窗不跟随 App 主题、没有浅色界面」。详见 applyAppAppearance。
        applyAppAppearance()
        startObservingAppearancePreference()

        setupMemoryPressureMonitor()

        // P2-9 (v2.10.9): 跨进程存储锁降级为「无锁」时，另一 Agent 侧的 StorageLock 会且仅会
        // post 一次 Notification.Name("ClipSlotsStorageLockLockless")。这里注册 GUI 观察者，
        // 复用 FloatingNotice / FloatingNoticeWindowController 弹一次可见提示，告知用户多进程
        // 并发写入可能相互覆盖。用 didShowLocklessNotice 保证整个进程生命周期内只提示一次。
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ClipSlotsStorageLockLockless"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self, !self.didShowLocklessNotice else { return }
            self.didShowLocklessNotice = true
            let reason = (note.userInfo?["reason"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            FloatingNoticeWindowController.shared.show(
                notice: FloatingNotice(
                    title: "存储锁不可用",
                    subtitle: reason.isEmpty
                        ? "多进程并发写入可能相互覆盖"
                        : "多进程并发写入可能相互覆盖（\(reason)）",
                    iconName: "exclamationmark.triangle.fill",
                    kind: .warning
                ),
                duration: 6.0
            )
        }

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
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    // v2.10.49 (perf 第一批 P2): 建立系统内存压力监听。收到 warning/critical 时清空可重建的
    // 缩略图缓存与内联图/缩略图/元数据解码缓存（下次访问会自动重建），主动回收内存。事件在主队列
    // 回调；ThumbnailProvider.clearCache 内部持 NSLock、SlotContent 缓存为 NSCache，均线程安全。
    private func setupMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak source] in
            let event = source?.data ?? []
            let level = event.contains(.critical) ? "critical" : "warning"
            NSLog("[ClipSlots] memory pressure (\(level)) → 清空缩略图/内联图缓存回收内存")
            ThumbnailProvider.shared.clearCache()
            SlotContent.purgeAllInlineImageCaches()
        }
        source.resume()
        memoryPressureSource = source
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
                        previousApp.activate(options: .activateIgnoringOtherApps)   // P1-3
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
