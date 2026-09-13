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
            // v2.11.7: 顺带把皮肤缓存对齐一次。SettingsView 切换时是先走 AppSkinCenter.apply 再写
            // defaults，这里只会判等直接返回；真正用得上的是「外部写入」——CLI / 调试时
            // `defaults write ... appearanceSkin`，或将来多窗口场景下另一处入口改了它。
            AppSkinCenter.syncFromDefaults()
            let raw = UserDefaults.standard.string(forKey: "appearanceMode")
                ?? ThemeMode.dark.rawValue
            guard raw != self.lastAppliedAppearanceRaw else { return }
            self.applyAppAppearance()
        }
    }

    /// v2.11.7 hotfix6：把主题同步提前到 `willFinishLaunching`。
    ///
    /// 原来它在 `didFinishLaunching` 里，而 SwiftUI 的第一帧比那更早——首帧渲染时
    /// `NSApp.effectiveAppearance` 还是系统值而不是用户选的档位。表面色是动态色不受影响，
    /// 但任何在求值期读 appearance 的地方都会拿到错的档（这正是 hotfix6 修的
    /// 「新开 App 工具栏漂浮」）。阴影 token 已改成动态色从根上免疫，这里再把时序也修正一次：
    /// 两道保险，且顺带让首帧的 AppKit 界面（菜单栏、弹窗）就是对的。
    /// 把主窗口的标题栏样式**钉死成 macOS 标准样式**，与皮肤无关。
    ///
    /// 用户报「多彩模式有标题栏、切到简洁模式标题栏就没了，界面变成无边框悬浮窗」。
    /// 代码里没有任何一处按皮肤改 `styleMask`——真正的原因是标题栏的**观感**依赖它背后透出来的东西：
    /// 多彩模式那层复古海报氛围底有纹理和渐变，标题栏区域于是有明显的材质分界；简洁模式换成一张
    /// 纯色底，标题栏和内容区同色同质，那条带子就「看不见了」，只剩三颗按钮悬在一片纯色上。
    ///
    /// 所以修法不是去解绑某个不存在的绑定，而是**显式声明标题栏必须由 AppKit 自己画**：
    /// 不透明、标题可见、不做 fullSizeContentView。这样两种皮肤下窗口 chrome 完全一致，
    /// 也不会再随背景层的实现变化而漂移。切皮肤后重新跑一次，防止 SwiftUI 重建窗口时改回去。
    private func normalizeMainWindowChrome() {
        // SwiftUI 建窗有时晚于 didFinishLaunching，拿不到就下一轮再试（最多几次，避免死循环）。
        func apply(retry: Int) {
            guard let window = NSApp.windows.first(where: {
                $0.styleMask.contains(.titled) && !($0 is NSPanel)
            }) else {
                guard retry > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { apply(retry: retry - 1) }
                return
            }
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.isMovableByWindowBackground = false
        }
        apply(retry: 10)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        applyAppAppearance()
        // 皮肤缓存也在首帧前对齐，避免首帧用默认皮肤画一遍再被通知刷成用户选的那套。
        AppSkinCenter.syncFromDefaults()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // v2.10.91: 启动即把 App 主题同步到 NSApp.appearance，并持续跟随后续切换。
        // 修复「NSAlert 等 AppKit 弹窗不跟随 App 主题、没有浅色界面」。详见 applyAppAppearance。
        // hotfix6 起 willFinishLaunching 已经跑过一次，这里保留是为了「delegate 被晚装」的场景。
        applyAppAppearance()

        // v2.11.7 hotfix6: 窗口 chrome 与皮肤解绑（见 normalizeMainWindowChrome）。
        normalizeMainWindowChrome()
        NotificationCenter.default.addObserver(
            forName: AppSkinCenter.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.normalizeMainWindowChrome()
        }
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
