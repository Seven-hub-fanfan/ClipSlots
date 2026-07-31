import SwiftUI
import ClipSlotsKit
import Cocoa
import Carbon
import UniformTypeIdentifiers

/// Resolve the virtual key code that produces the letter 'v' on the current keyboard layout.
fileprivate func computeVirtualKeyForCharacterV() -> CGKeyCode {
    guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return 9 }
    guard let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else { return 9 }
    let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data
    guard let keyboardLayout = layoutData.withUnsafeBytes({ $0.bindMemory(to: UCKeyboardLayout.self).baseAddress }) else { return 9 }

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
        if result == noErr, actualLen == 1, unicodeString[0] == 0x0076 { return CGKeyCode(keyCode) }
    }
    return 9
}

/// v2.10.6 (P2-2): cache the 'v' virtual key code. `computeVirtualKeyForCharacterV`
/// walks 128 key codes calling `UCKeyTranslate` (a relatively expensive TIS system
/// call) on every paste, yet the keyboard layout rarely changes. Cache the result
/// and only recompute when the selected keyboard input source actually changes.
fileprivate final class VirtualVKeyCache {
    static let shared = VirtualVKeyCache()

    private let lock = NSLock()
    private var cached: CGKeyCode?

    private init() {
        // Layout change events are posted on the distributed notification center.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(layoutDidChange),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
    }

    @objc private func layoutDidChange() {
        lock.lock(); cached = nil; lock.unlock()
    }

    var keyCode: CGKeyCode {
        lock.lock()
        if let c = cached { lock.unlock(); return c }
        lock.unlock()
        let computed = computeVirtualKeyForCharacterV()
        lock.lock()
        // v2.10.7 (P2-6): 双重检查——若另一线程已在计算期间填充 cached，复用它，避免覆盖竞态。
        if let c = cached { lock.unlock(); return c }
        cached = computed
        lock.unlock()
        return computed
    }
}

fileprivate func virtualKeyForCharacterV() -> CGKeyCode {
    VirtualVKeyCache.shared.keyCode
}

// v2.7.33: Do not define slot keyboardShortcut helpers for foreground menu actions.
// All save/paste shortcuts must be owned by AppConfig + RegisterEventHotKey only.

// v2.9.12: request to open the in-app settings overlay (Cmd+, / menu).
extension Notification.Name {
    static let openInAppSettings = Notification.Name("com.clipslots.openInAppSettings")
}

@main
struct ClipSlotsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = SlotStoreObservable()

    // v2.7.54: startup entry must also default to dark.
    // v2.7.47 changed ContentView/SettingsView, but App root still defaulted to
    // system, so first launch could render as light before ContentView appeared.
    @AppStorage("appearanceMode") private var appearanceModeRaw = ThemeMode.dark.rawValue
    private var appearanceMode: ThemeMode { ThemeMode(rawValue: appearanceModeRaw) ?? .dark }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                // v2.9.23: 增大窗口最小尺寸，防止标题栏/应用图标在缩到最小时被挤压变形。
                .frame(minWidth: 720, minHeight: 560)
                .preferredColorScheme(appearanceMode.preferredColorScheme)
                .onAppear {
                    AppearanceDefaults.ensureDefaultDarkIfNeeded()
                    appDelegate.store = store
                    appDelegate.setupHotKeysAfterStoreReady()
                    store.installLocalHotkeyGuardIfNeeded()
                    // v2.9.8: 方案 Y — 每次启动检测辅助功能权限并引导。
                    AccessibilityPermissionGuide.checkAndGuideOnLaunch()
                    // v2.9.30: 启动时静默同步已安装的 Skill，确保各 Agent 用到最新决策流，
                    // 无需用户再手动点「安装 Skill」。onAppear 已在主线程，直接调用即可。
                    AgentSkillInstallManager().syncInstalledSkillsOnLaunch()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        // v2.9.18: 默认窗口 540×420 装不下 10 个卡片（开箱即需滚动）。放大到 1320×820，
        // 配合自适应网格可一屏 5 列 × 2 行完整显示 10 个槽位，无需滚动。
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("关于 ClipSlots") { NSApp.orderFrontStandardAboutPanel(nil) }
            }
            // v2.9.12: settings are now an in-app overlay (not a separate window).
            // Keep Cmd+, working by broadcasting a request the main window observes.
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    NotificationCenter.default.post(name: .openInAppSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // v2.7.26: Ctrl+Z undo for clear/delete operations
            CommandGroup(after: .undoRedo) {
                Button("撤销清空/删除") {
                    store.undoLastClearIfPossible()
                }
                .keyboardShortcut("z", modifiers: [.control])
            }
            // v2.7.32: Do NOT register hard-coded SwiftUI menu shortcuts here.
            // These keyboardShortcut modifiers bypass AppConfig and remain active
            // inside the app window even after global hotkeys are changed.
            // That is the real reason ctrl+option+number kept saving/HUD while the
            // configured shortcut was cmd+option+number.
            CommandMenu("槽位") {
                ForEach(Array(stride(from: 1, through: store.config.slots, by: 1)), id: \.self) { slot in
                    Button("粘贴槽位 \(slot)") { store.pasteSlot(slot) }
                    Button("保存到槽位 \(slot)") { store.saveToSlot(slot) }
                }
            }
        }
        .onChange(of: NSApplication.shared.keyWindow?.title) { _ in }
    }
}

/// v2.9.38: transient flash-highlight target carrying BOTH the group id and the
/// slot index, so the highlight only lights up the correct card in the correct
/// group (aligns with the group-aware `isLastPasted` check).
struct FlashHighlightTarget: Equatable {
    let groupId: String
    let slot: Int
}

final class SlotStoreObservable: ObservableObject {
    let instanceID = UUID().uuidString

    // P1-4: monotonically-increasing token for global search recompute. NOT @Published;
    // ContentView reads it through the shared reference to reliably detect stale results.
    var globalSearchGeneration: Int = 0

    // MARK: - v2.7.27 Local Hotkey Guard
    // Global hotkeys were fixed in v2.7.26, but the foreground app window can still
    // receive legacy local key equivalents (Ctrl+Option+number) through SwiftUI/AppKit
    // event handling. Install a local monitor that swallows only legacy shortcuts that
    // are no longer equal to the current config.
    private var localHotkeyMonitor: Any?

    func installLocalHotkeyGuardIfNeeded() {
        guard localHotkeyMonitor == nil else { return }
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // v2.7.30: settings UI is a safe zone. No save/paste/radial hotkey may fire
            // while the user is editing shortcuts, even if the old global/local handler
            // still receives keyDown.
            if self.isSettingsPresented { return event }
            if let responder = NSApp.keyWindow?.firstResponder,
               String(describing: type(of: responder)).contains("ShortcutCaptureTextField") {
                return event
            }
            return self.shouldBlockLegacyLocalHotkey(event) ? nil : event
        }
    }

    private func shouldBlockLegacyLocalHotkey(_ event: NSEvent) -> Bool {
        // v2.7.29: only active config decides behavior. Never infer from any
        // Settings draft text. If current config actually is ctrl+option+{n},
        // allow it; otherwise consume the legacy local event without action/HUD.
        if config.saveKey.lowercased() == "ctrl+option+{n}" { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isLegacySave = flags.contains(.control) && flags.contains(.option) && !flags.contains(.command)
        let isNumber = Int(event.charactersIgnoringModifiers ?? "") != nil
        guard isLegacySave && isNumber else { return false }
        return true
    }

    @Published var config = AppConfig.load()
    @Published var slots: [Int: SlotContent] = [:] {
        didSet {
            // P2-28 (v2.10.9): 预计算槽位内容签名（contentId+updatedAt）派生值。此前
            // ContentView 在 .onChange 里对 store.slots.mapValues 每次 body 求值都新建一个
            // [Int:String]，开销随槽位数增长。改为在 slots 变化时计算一次并 @Published，
            // 视图直接观察该派生值即可感知底层内容变化。
            slotsContentSignature = slots.mapValues { "\($0.contentId):\($0.updatedAt)" }
        }
    }
    /// P2-28 (v2.10.9): slots 内容签名派生值，随 slots 变化自动更新（见 slots.didSet）。
    @Published private(set) var slotsContentSignature: [Int: String] = [:]
    @Published var labels: [Int: String] = [:]
    @Published var refreshTrigger = UUID()

    // Special slot state
    @Published var specialSlots: [SpecialSlot] = []
    @Published var currentSpecialSlotId: String = "default"  // UI preview layer
    @Published var currentSpecialSlot: SpecialSlot?
    @Published var activeHotkeySpecialSlotId: String = "default"  // Cmd+number hotkey layer
    @Published var activeHotkeySpecialSlot: SpecialSlot?
    @Published var specialSlotSettings: SpecialSlotSettings = .default
    // v2.10.1: 游标位置可视化预览。指向「下一次触发会落到的槽位」（而非上次落点）：
    // - autoStorePreview：下一次 Opt+1 自动存储会写入的空槽（绿色写游标角标）
    // - autoPastePreview：下一次 Cmd+1 自动粘贴会读取的非空槽（蓝色读游标角标）
    // 随游标推进 / 回退 / 重置、内容变化、拨杆切换实时重算。
    @Published var autoStorePreview: SlotAddress? = nil
    @Published var autoPastePreview: SlotAddress? = nil
    @Published var toastMessage: String?
    @Published var floatingNotice: FloatingNotice?
    @Published var hotkeyRegistrationErrors: [String] = []
    @Published var isSettingsPresented: Bool = false
    @Published var slotRenderTokens: [String: UUID] = [:]
    @Published var isBatchSaving: Bool = false

    // v2.6.7: import options sheet
    @Published var pendingImportSelection: PendingImportSelection?

    // v2.10.14: 打包导出选择 sheet 的呈现状态
    @Published var showingPackExport: Bool = false

    // v2.4 Page state
    @Published var pages: [SlotPage] = []
    @Published var currentPageId: String = "default_page"
    @Published var currentPage: SlotPage?

    // v2.9.36: last paste location (persisted via UserDefaults / @AppStorage keys).
    @Published var lastPastePageId: String = UserDefaults.standard.string(forKey: UserPreferenceKeys.lastPastePageId) ?? ""
    @Published var lastPasteGroupId: String = UserDefaults.standard.string(forKey: UserPreferenceKeys.lastPasteGroupId) ?? ""
    @Published var lastPasteSlotIndex: Int = {
        UserDefaults.standard.object(forKey: UserPreferenceKeys.lastPasteSlotIndex) == nil
            ? -1
            : UserDefaults.standard.integer(forKey: UserPreferenceKeys.lastPasteSlotIndex)
    }()

    // v2.9.37: transient flash-highlight target for the main grid. Set by
    // jumpToLastPaste(); cleared automatically after ~2s. v2.9.38: now carries the
    // group id too so only the matching card in the matching group lights up.
    @Published var flashHighlightSlot: FlashHighlightTarget? = nil
    private var flashHighlightToken: UUID?

    // v2.7.0: Slot connection state
    @Published var currentConnectionMap: SlotConnectionMap = .empty
    @Published var isConnectionModeEnabled: Bool = false
    @Published var hoveredSlot: Int? = nil
    @Published var activeDragConnection: ActiveDragConnection? = nil
    @Published var hoveredPortTarget: SlotPortTarget? = nil

    /// v2.7.0: Whether slot connection feature is enabled in settings
    var isSlotConnectionEnabled: Bool {
        if UserDefaults.standard.object(forKey: UserPreferenceKeys.enableSlotConnection) == nil {
            return true // default enabled
        }
        return UserDefaults.standard.bool(forKey: UserPreferenceKeys.enableSlotConnection)
    }

    /// Slot groups belonging to the current page, sorted by order.
    var currentPageSlotGroups: [SpecialSlot] {
        specialSlots.filter { $0.pageId == currentPageId }.sorted { $0.order < $1.order }
    }

    var lastNonClipSlotsApp: NSRunningApplication?

    var onConfigChanged: (() -> Void)?

    let specialStorage = SpecialSlotStorage.shared
    private let clipboard = ClipboardManager.shared

    /// Cancellable delayed clipboard restore to prevent race with copy/save.
    private var pendingClipboardRestore: DispatchWorkItem?
    private var pendingClipboardRestoreContent: SlotContent?

    /// Pending paste keystroke work item. Cancelled when switching special slots.
    private var pendingPasteWorkItem: DispatchWorkItem?

    /// v2.8.1 (P0-1): monotonically increasing token identifying the current
    /// sequential-paste run. Each scheduled recursion step captures the token it
    /// was started with; if a newer sequence (or a cancel) bumps this value, the
    /// stale step becomes a no-op, so two sequences can never interleave keystrokes.
    private var pasteSequenceGeneration = 0
    /// Clipboard snapshot captured for the in-flight sequence, so a superseding
    /// sequence / cancel can restore it before starting fresh.
    private var inFlightSequencePrevious: SlotContent?
    /// Temp image files spilled for the in-flight sequence, cleaned on supersede.
    private var inFlightSequenceTempFiles: [URL] = []

    /// The special slot id that current in-memory `slots` / `labels` belong to.
    private var loadedSpecialSlotId: String?

    /// APP-1 (v2.10.32): monotonic generation stamp for `reloadAllAsync`. B-1 only dropped a
    /// stale snapshot when the user switched to ANOTHER group (activeId mismatch). But two
    /// reloadAllAsync runs for the SAME group (e.g. rapid back-to-back watcher batches) both pass
    /// the activeId==current check, and there is NO ordering guarantee on when each background
    /// read completes — an older, slower read can land AFTER a newer one and clobber fresh data
    /// with stale-but-same-group content. Each reloadAllAsync bumps this counter and captures its
    /// value; the completion applies its result only if it is still the latest generation.
    /// Main-thread only.
    private var reloadGeneration: Int = 0

    // MARK: - v2.9.4 (Feature #2) Live disk refresh
    /// FSEvents watcher on the storage base dir. External (CLI / other GUI) writes
    /// trigger a debounced `reloadAll()` so the UI reflects disk changes without a
    /// manual group switch or restart.
    private var storageWatcher: StorageDirectoryWatcher?
    /// Debounces bursts of FSEvents into a single reload.
    private var watcherDebounceWorkItem: DispatchWorkItem?
    /// Self-write suppression: bumped to `now + 0.6s` right before every
    /// GUI-initiated disk write. If the debounced watcher handler fires while
    /// `Date() < ignoreWatcherUntil`, the reload is skipped — this prevents a
    /// reload loop/storm from the GUI's OWN writes while still reacting promptly
    /// to genuinely external writes.
    private var ignoreWatcherUntil: Date = .distantPast

    // CR-1 (v2.10.30): `ignoreWatcherUntil` 会被「可能运行在非主线程的 GUI 写入入口」(suppressWatcher)
    // 与「主线程 watcher 回调」并发读写，构成对 Date 的数据竞争。用专用 NSLock 串行化其所有读写，
    // 全部经由下方 setIgnoreWatcherUntil / currentIgnoreWatcherUntil 两个访问器进行，禁止再直接触碰。
    // 注：pendingSelfWriteFingerprints/fingerprintQueue 已由串行队列保护，此锁仅覆盖 ignoreWatcherUntil。
    private let watcherStateLock = NSLock()
    private func setIgnoreWatcherUntil(_ d: Date) {
        watcherStateLock.lock()
        ignoreWatcherUntil = d
        watcherStateLock.unlock()
    }
    private func currentIgnoreWatcherUntil() -> Date {
        watcherStateLock.lock()
        defer { watcherStateLock.unlock() }
        return ignoreWatcherUntil
    }

    // CR-2 / CS-3 (v2.10.30): 自动存储的 capture→找空槽→写入→推进游标 全流程串行化保护标志。
    // 快速连按 Opt+1 时，第二次按下若在第一次的异步剪贴板等待窗口内，会与第一次解析到同一个空槽
    // 造成重复写入。入口处若发现仍在进行中则忽略本次；所有完成/提前返回分支都必须复位为 false。
    // 仅在主线程读写（自动存储流程全程在主线程调度）。
    private var isAutoStoreInFlight = false

    // CS-2 (v2.10.30): 记录「连线链」本轮自动粘贴已粘过的成员（按组 id）。非连续链粘贴后读游标会
    // 推进到 chain.first（为了不跳过链内空档之外的普通槽），若不加记录，链内其余成员会在后续扫描中被
    // 再次选中而重复粘贴。auto-paste 的 isNonEmpty 探针会把命中该集合的槽位视为空跳过，做到「每轮每成员
    // 至多粘贴一次」；读游标重置（一轮结束）时清空。仅在主线程读写。
    private var pastedChainMembersByGroup: [String: Set<Int>] = [:]

    // P2-5 (v2.10.16): 纯时间窗（ignoreWatcherUntil）无法区分「本进程自写」与「恰好落在 0.6s 窗口内
    // 的外部 CLI 写」，后者会被一并吞掉导致 GUI 显示滞后。这里改用「自写内容指纹」辅助判定：每次自写
    // 完成后记录一次 special_slots 目录树指纹；watcher 回调在时间窗内命中时，用当前磁盘指纹与最近自写
    // 指纹比对——匹配才判定为自写并跳过（且消费掉该指纹），不匹配说明窗口内混入了外部写，即使仍在时间窗
    // 内也执行 reload，从而不再误吞外部写。
    // 线程约束：P1-B (v2.10.17) 起，本集合的读写以及指纹计算（整树遍历）统一挪到 fingerprintQueue
    // 串行队列执行，不再占用主线程——记录端（recordSelfWriteFingerprint）与消费端（watcher 回调）都在
    // 同一队列上访问，天然串行，无需额外加锁；主线程只负责最终的 reload/UI 刷新。
    private var pendingSelfWriteFingerprints: [UInt64] = []
    /// 最多保留的自写指纹数量（环形裁剪，覆盖连续多次自写；避免无界增长）。
    private let maxPendingSelfWriteFingerprints = 16
    // P1-B (v2.10.17): 指纹计算是 I/O 密集的整目录树递归 stat，放主线程会在大库写入时造成 UI 卡顿。
    // 统一改到该后台串行队列执行；队列的串行性同时充当 pendingSelfWriteFingerprints 的并发保护。
    private let fingerprintQueue = DispatchQueue(label: "com.clipslots.fingerprint", qos: .utility)

    // P1-1 (v2.10.35): 槽位写盘统一串行队列。MT-1/APP-3（v2.10.30/32）把原先「主线程同步、天然有序」的
    // 写盘挪到了 DispatchQueue.global（并发队列）。并发队列上多个 async 写块在不同线程竞争同一把跨进程
    // flock，而 flock 的获取顺序并非 FIFO，SpecialSlotStorage.set 也不按 updatedAt 拒绝旧写——于是「较早
    // 提交但较晚抢到锁」的旧快照会覆盖较新快照，磁盘与内存缓存双双回退成陈旧值（数据永久丢失）。改为把
    // 所有 App 自身的槽位写盘（persist 快照 / 自动存储 / 文件夹导入 / 单槽保存 / 批量保存）都排入这一条
    // 串行队列：入队顺序即主线程发起编辑的顺序，串行执行保证 last-write-wins 与编辑顺序一致，彻底消除错序。
    private let slotWriteQueue = DispatchQueue(label: "com.clipslots.slotwrite", qos: .userInitiated)

    init() {
        NSLog("[ClipSlots] SlotStoreObservable init instanceID=\(instanceID)")
        loadSpecialSlots()
        loadSlots()
        loadPersistedUndoSnapshot() // v2.9.5 (Feature #3): restore pending undo across restarts
        setupStorageWatcher()
    }

    deinit {
        storageWatcher?.stop()
        storageWatcher = nil
        // v2.10.3 (P2): remove the local key monitor so it isn't leaked/dangling.
        if let monitor = localHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            localHotkeyMonitor = nil
        }
    }

    // MARK: - v2.9.4 Storage Watcher (Feature #2)

    private func setupStorageWatcher() {
        let base = ClipSlotsPaths.specialSlots
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let watcher = StorageDirectoryWatcher(path: base.path) { [weak self] in
            self?.handleStorageChange()
        }
        watcher.start()
        storageWatcher = watcher
    }

    /// Called on the watcher's background queue for every FSEvents batch.
    /// Debounces ~300ms, then reloads on the main queue (unless self-write suppressed).
    private func handleStorageChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.watcherDebounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // CR-1 (v2.10.30): 通过加锁访问器读取，避免与 suppressWatcher 的写入竞争；一次读入本地
                // 变量供后续两处判断使用（消除 TOCTOU）。
                let ignoreUntil = self.currentIgnoreWatcherUntil()
                if Date() < ignoreUntil {
                    // P2-5 (v2.10.16): 不再在时间窗内无条件跳过。
                    // (1) 开放式抑制窗（导入生命周期把 ignoreWatcherUntil 顶到极远未来，见 PK-2 v2.10.15）：
                    //     此时磁盘正被本进程持续写入、指纹频繁变化，仍需保持无条件跳过以避免导入期间反复
                    //     reload 造成的闪烁 / 当前页被重置。用一个较大的阈值区分它与普通自写窗（后者 ≤ 数秒）。
                    if ignoreUntil.timeIntervalSinceNow > 60 {
                        NSLog("[ClipSlots] watcher fired → suppressed (open-ended/import window)")
                        return
                    }
                    // (2) 普通自写窗：用磁盘指纹校验区分自写与外部写。仅当当前磁盘指纹命中本进程最近的自写
                    //     指纹时，才判定为自写并跳过（并消费该指纹，避免后续外部写复用同一指纹被误跳过）；
                    //     否则说明窗口内混入了外部 CLI 写，即使仍在时间窗内也执行 reload。
                    // P1-B (v2.10.17): 指纹计算（整树遍历 + 逐文件 stat）挪到 fingerprintQueue 后台执行，
                    //     不再阻塞主线程；命中自写则直接结束，未命中再回主线程执行 reload。
                    self.fingerprintQueue.async { [weak self] in
                        guard let self else { return }
                        let fp = self.storageDirFingerprint()
                        if let idx = self.pendingSelfWriteFingerprints.lastIndex(of: fp) {
                            self.pendingSelfWriteFingerprints.remove(at: idx)
                            NSLog("[ClipSlots] watcher fired → suppressed (self-write fingerprint match)")
                            return
                        }
                        NSLog("[ClipSlots] watcher fired → external write detected within window (fingerprint mismatch) → reloadAll")
                        DispatchQueue.main.async { [weak self] in self?.performWatcherReload() }
                    }
                    return
                }
                self.performWatcherReload()
            }
            self.watcherDebounceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    /// P1-B (v2.10.17): watcher 命中「需要 reload」时在主线程执行的收尾工作（缓存失效 + UI 刷新）。
    /// 从原 debounce work item 中抽出，供同步（非时间窗）与异步（指纹不匹配回主线程）两条路径共用。
    private func performWatcherReload() {
        NSLog("[ClipSlots] watcher fired → reloadAll")
        // v2.9.15 (fix): an external write (the `clipslots` CLI) changed
        // slot bodies on disk. SlotStorage.get() is cache-backed and would
        // otherwise keep returning the stale in-memory SlotContent, so the
        // body stayed "空槽位 0 B" even though the label (read from disk
        // directly) updated. Drop the content caches so reloadAll re-reads
        // the freshly written bodies from disk.
        self.specialStorage.invalidateContentCaches()
        // P2 (v2.10.13): 一并失效连接缓存。invalidateContentCaches 只清槽位内容缓存，
        // 不清 SlotConnectionStorage；外部删组/删页后 GUI 侧会残留已删除组的陈旧连线。
        // 连接缓存归 GUI 层的 SlotConnectionStorage 管辖（Kit 层无法引用），故在文件
        // 监听回调里一并清理。
        SlotConnectionStorage.shared.invalidateCache()
        // P0-1 (v2.10.30): 改走异步 reload，把逐槽磁盘读移出主线程，避免 CLI 批量写盘时 GUI 卡死。
        // 原先紧跟在 reloadAll 之后的 UI 刷新触发（refreshTrigger）挪到异步完成闭包里，确保在 @Published
        // 赋值完成后再刷新。
        self.reloadAllAsync { [weak self] in
            self?.refreshTrigger = UUID()
        }
    }

    /// Bump the suppression window right before a GUI-initiated disk write so the
    /// resulting FSEvents callback does not trigger a redundant `reloadAll()`.
    /// A single timestamp (rather than per-method bool flags) is simpler and safe
    /// as long as it is bumped at every GUI write entry point.
    func suppressWatcher(_ interval: TimeInterval = 0.6) {
        // CR-1 (v2.10.30): 经加锁访问器写入（本方法可能从非主线程的 GUI 写入入口调用）。
        setIgnoreWatcherUntil(Date().addingTimeInterval(interval))
        // P2-5 (v2.10.16): 记录本次自写完成后的磁盘指纹，供 watcher 回调区分自写 / 外部写。
        // suppressWatcher 在实际写入「之前」调用，故用 main.async 把指纹采集排到当前主线程同步写入
        // 「之后」执行，从而捕获到「写后」磁盘状态（同步写入路径覆盖绝大多数入口）。watcher 的 debounce
        // 有 0.3s 延迟，采集必定先于回调完成，比对时指纹已就绪。
        // 注：开放式导入窗（ignoreWatcherUntil 被顶到极远未来）走 watcher 里的 (1) 分支无条件跳过，
        // 不依赖此处指纹；导入收敛时改调 suppressWatcher(2.0)，届时写入已完成，采集到的即最终磁盘状态，
        // 尾随 FSEvents 可凭指纹匹配被正确跳过。
        DispatchQueue.main.async { [weak self] in
            self?.recordSelfWriteFingerprint()
        }
    }

    /// P2-5 (v2.10.16): 采集当前 special_slots 目录树指纹并登记为一次自写指纹（环形裁剪）。
    /// P1-B (v2.10.17): 指纹计算与集合读写整体挪到 fingerprintQueue 后台串行队列，不再占用主线程。
    /// 由 suppressWatcher 经 main.async 调用（确保排在本次同步写入「之后」），本方法再把重活派发到
    /// fingerprintQueue，主线程仅承担一次 async 派发开销。
    private func recordSelfWriteFingerprint() {
        fingerprintQueue.async { [weak self] in
            guard let self else { return }
            let fp = self.storageDirFingerprint()
            // 去重后追加到尾部（保持“最近”在后），避免重复自写把同一指纹塞满环。
            self.pendingSelfWriteFingerprints.removeAll { $0 == fp }
            self.pendingSelfWriteFingerprints.append(fp)
            if self.pendingSelfWriteFingerprints.count > self.maxPendingSelfWriteFingerprints {
                self.pendingSelfWriteFingerprints.removeFirst(
                    self.pendingSelfWriteFingerprints.count - self.maxPendingSelfWriteFingerprints)
            }
        }
    }

    /// P2-5 (v2.10.16): 计算 special_slots 目录树的内容指纹。
    /// 对每个常规文件的 (相对路径, 大小, 修改时间) 生成局部哈希，用「与顺序无关」的 XOR 聚合，
    /// 再混入文件计数，得到一个对「任意文件的增/删/改」都敏感的 64 位指纹。
    /// - 跳过隐藏文件（.storage.lock / .DS_Store 等）以过滤写锁抖动噪声。
    /// - 指纹仅用于「同一进程运行内」的前后比对（记录 vs 回调时刻），因此使用进程内一致的 Hasher 即可，
    ///   不要求跨进程 / 跨启动稳定。
    private func storageDirFingerprint() -> UInt64 {
        let base = ClipSlotsPaths.specialSlots
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        let basePath = base.path
        var acc: UInt64 = 0
        var count: UInt64 = 0
        for case let url as URL in enumerator {
            guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                  vals.isRegularFile == true else { continue }
            let rel = url.path.hasPrefix(basePath) ? String(url.path.dropFirst(basePath.count)) : url.path
            let size = UInt64(vals.fileSize ?? 0)
            // 毫秒精度足以区分外部写；避免浮点比较误差。
            let mtime = UInt64(max(0, (vals.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000))
            var hasher = Hasher()
            hasher.combine(rel)
            hasher.combine(size)
            hasher.combine(mtime)
            acc ^= UInt64(bitPattern: Int64(hasher.finalize())) // 顺序无关聚合
            count &+= 1
        }
        // 混入文件数，区分「删一个文件」与「改一个文件」等 XOR 抵消场景。
        acc ^= count &* 0x9E3779B97F4A7C15
        return acc
    }

    // MARK: - Special Slots

    func loadSpecialSlots() {
        let index = specialStorage.loadIndex()

        // v2.4: load pages
        pages = index.pages
        currentPageId = index.currentPageId.isEmpty ? (index.pages.first?.id ?? "default_page") : index.currentPageId
        currentPage = index.pages.first { $0.id == currentPageId }

        specialSlots = index.specialSlots

        let fallbackId = index.specialSlots.first?.id ?? "default"

        let selectedId = index.selectedSpecialSlotId ?? index.currentSpecialSlotId
        let activeId = index.activeHotkeySpecialSlotId ?? index.currentSpecialSlotId

        // If the persisted id no longer exists (e.g. after a delete), fall back.
        let validSelectedId = index.specialSlots.contains(where: { $0.id == selectedId }) ? selectedId : fallbackId
        let validActiveId = index.specialSlots.contains(where: { $0.id == activeId }) ? activeId : fallbackId

        currentSpecialSlotId = validSelectedId
        currentSpecialSlot = index.specialSlots.first { $0.id == validSelectedId }

        activeHotkeySpecialSlotId = validActiveId
        activeHotkeySpecialSlot = index.specialSlots.first { $0.id == validActiveId }

        specialSlotSettings = index.settings
    }

    func reloadAll() {
        loadSpecialSlots()
        loadSlots()
        loadConnectionMapForCurrentGroup()
        reloadLastPasteFromDefaults() // v2.10.3 (P2): reflect CLI-side paste into GUI
        recomputeAutoPreviews()
    }

    // P0-1 (v2.10.30): reloadAll 的异步版本，仅供「FSEvents watcher 触发」的 reload 使用。
    // reloadAll 里最重的是 loadSlots 的逐槽磁盘读（N 次跨进程 flock，最长各阻塞 ~5s），此前直接跑在
    // 主线程上，CLI 批量写盘期间会把 GUI 主线程卡到转圈。这里把该重活挪到后台队列，读完再回主线程赋值
    // @Published 并执行其余较轻的收尾步骤。init / 显式切组等其他 reloadAll 调用方保持同步不变。
    // 说明：loadSpecialSlots 只读索引（轻），保留在主线程先跑以拿到最新 currentSpecialSlotId；
    // loadConnectionMapForCurrentGroup / reloadLastPasteFromDefaults / recomputeAutoPreviews 均只做
    // 内存缓存读或轻量 FS-shape 探测且会写 @Published，统一放主线程完成闭包里执行。
    private func reloadAllAsync(completion: (() -> Void)? = nil) {
        loadSpecialSlots()
        let activeId = currentSpecialSlotId
        // APP-1 (v2.10.32): stamp this reload; only the newest generation may commit its snapshot.
        reloadGeneration &+= 1
        let gen = reloadGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let snapshot = self.readSlotsSnapshot(for: activeId)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // B-1 (v2.10.31): the background read above can take up to several seconds (N
                // per-slot cross-process flocks). If the user switched to another group while it
                // ran, `currentSpecialSlotId` no longer equals the `activeId` we snapshotted, and
                // unconditionally assigning `snapshot.slots` would overwrite the now-current group
                // with STALE data from the old group (title shows B, content is A). Drop the stale
                // result — loadSpecialSlots() during the switch already scheduled a fresh reload
                // for the new group. loadSpecialSlots() ran again on the main thread before this
                // block, so `currentSpecialSlotId` here is the up-to-date selection.
                guard activeId == self.currentSpecialSlotId else {
                    NSLog("[ClipSlots] reloadAllAsync: dropping stale snapshot for \(activeId) — active group is now \(self.currentSpecialSlotId)")
                    completion?()
                    return
                }
                // APP-1 (v2.10.32): even for the SAME group, a newer reloadAllAsync may have been
                // scheduled after us; if so its (higher) generation is authoritative. An older read
                // finishing late must NOT clobber the newer group state with stale-but-same-group
                // bytes. Drop this result unless we are still the latest generation.
                guard gen == self.reloadGeneration else {
                    NSLog("[ClipSlots] reloadAllAsync: dropping superseded snapshot gen=\(gen) latest=\(self.reloadGeneration)")
                    completion?()
                    return
                }
                self.slots = snapshot.slots
                self.labels = snapshot.labels
                self.loadedSpecialSlotId = activeId
                self.loadConnectionMapForCurrentGroup()
                self.reloadLastPasteFromDefaults()
                self.recomputeAutoPreviews()
                completion?()
            }
        }
    }

    /// v2.10.3 (P2): re-read the "上次粘贴" location from UserDefaults so a paste made
    /// by the `clipslots` CLI (separate process) is reflected in the GUI after the
    /// storage watcher reload, instead of only updating on relaunch.
    func reloadLastPasteFromDefaults() {
        let d = UserDefaults.standard
        lastPastePageId = d.string(forKey: UserPreferenceKeys.lastPastePageId) ?? ""
        lastPasteGroupId = d.string(forKey: UserPreferenceKeys.lastPasteGroupId) ?? ""
        lastPasteSlotIndex = d.object(forKey: UserPreferenceKeys.lastPasteSlotIndex) == nil
            ? -1
            : d.integer(forKey: UserPreferenceKeys.lastPasteSlotIndex)
    }

    func switchSpecialSlot(id: String) {
        selectAndActivateSpecialSlot(id: id)
    }

    // MARK: - Preview / Activate (Layer model)

    /// Click a tag: preview only, does NOT change Cmd+number binding.
    func selectSpecialSlotForPreview(id: String) {
        guard id != currentSpecialSlotId else { return }

        guard specialSlots.contains(where: { $0.id == id }) else { return }

        let oldId = currentSpecialSlotId
        NSLog("[ClipSlots] selectSpecialSlotForPreview from=\(oldId) to=\(id) activeHotkey=\(activeHotkeySpecialSlotId)")

        cancelPendingPasteOperations(restoreClipboard: true)

        ThumbnailProvider.shared.invalidateSpecialSlot(specialSlotId: oldId)

        slots = [:]
        labels = [:]
        loadedSpecialSlotId = nil

        currentSpecialSlotId = id
        currentSpecialSlot = specialSlots.first { $0.id == id }

        suppressWatcher() // v2.9.4 (#2): self-write
        specialStorage.updateSelectedSpecialSlot(id: id)

        loadSlotsAsync() // APP-2 (v2.10.32): 切组读盘异步化，避免主线程被逐槽 flock 卡死
        loadConnectionMapForCurrentGroup()
        refreshTrigger = UUID()

        // v2.10.19: 游标跟随激活组——每次切到新组时重置读游标，
        // 下一次自动粘贴从「该组第一个非空槽」开始（含 A→B→A 切回 A 也重置到 A 头）。
        try? specialStorage.resetAutoPasteCursor()
        pastedChainMembersByGroup.removeAll() // CS-2 (v2.10.30): 读游标重置=开启新一轮，清空连线链已粘记录

        recomputeAutoPreviews() // v2.10.3 (P2): refresh cursor badges for the new group

        showToast("已预览「\(currentSpecialSlot?.name ?? id)」")
    }

    /// Activate this special slot as the Cmd+number hotkey layer.
    func activateSpecialSlotForHotkeys(id: String) {
        guard specialSlots.contains(where: { $0.id == id }) else { return }

        let oldId = activeHotkeySpecialSlotId
        guard id != oldId else { return }

        NSLog("[ClipSlots] activateSpecialSlotForHotkeys from=\(oldId) to=\(id)")

        cancelPendingPasteOperations(restoreClipboard: true)

        // The hotkey layer is now bound to a different special slot.
        // Invalidate cached thumbnails for the old layer so stale async callbacks
        // don't write into the wrong UI.
        ThumbnailProvider.shared.invalidateSpecialSlot(specialSlotId: oldId)

        activeHotkeySpecialSlotId = id
        activeHotkeySpecialSlot = specialSlots.first { $0.id == id }

        suppressWatcher() // v2.9.4 (#2): self-write
        try? specialStorage.updateActiveHotkeySpecialSlot(id: id)

        refreshTrigger = UUID()
        showToast("Cmd+数字 已切换至「\(activeHotkeySpecialSlot?.name ?? id)」")
    }

    /// Preview AND activate: both UI and Cmd+number switch to this slot.
    /// v2.4: also switches to the page that owns this slot group.
    func selectAndActivateSpecialSlot(id: String) {
        guard id != currentSpecialSlotId || id != activeHotkeySpecialSlotId else { return }
        guard specialSlots.contains(where: { $0.id == id }) else { return }

        let oldPreview = currentSpecialSlotId
        let oldActive = activeHotkeySpecialSlotId
        NSLog("[ClipSlots] selectAndActivateSpecialSlot preview:\(oldPreview)->\(id) hotkey:\(oldActive)->\(id)")

        cancelPendingPasteOperations(restoreClipboard: true)

        ThumbnailProvider.shared.invalidateSpecialSlot(specialSlotId: oldPreview)

        slots = [:]
        labels = [:]
        loadedSpecialSlotId = nil
        refreshTrigger = UUID()

        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.switchToSpecialSlot(id: id)
        } catch {
            NSLog("[ClipSlots] selectAndActivateSpecialSlot save failed: \(error)")
        }

        let index = specialStorage.loadIndex()

        // v2.4: sync page state
        pages = index.pages
        currentPageId = index.currentPageId
        currentPage = index.pages.first { $0.id == currentPageId }

        currentSpecialSlotId = id
        currentSpecialSlot = index.specialSlots.first { $0.id == id }
        activeHotkeySpecialSlotId = id
        activeHotkeySpecialSlot = index.specialSlots.first { $0.id == id }
        specialSlots = index.specialSlots
        specialSlotSettings = index.settings

        loadSlotsAsync() // APP-2 (v2.10.32): 切组读盘异步化，避免主线程被逐槽 flock 卡死
        loadConnectionMapForCurrentGroup()
        refreshTrigger = UUID()

        // v2.10.19: 游标跟随激活组——切组后重置读游标，下一次自动粘贴从「该组第一个非空槽」开始。
        // 注意：自动切换（autoAdvance）跨组时也经由此函数切组并触发本重置；随后 autoPasteFromHotkey
        // 会在粘贴完成回调里 advanceAutoPasteCursor(to:) 把游标重新设到落点，故跨组连续推进不受影响。
        try? specialStorage.resetAutoPasteCursor()
        pastedChainMembersByGroup.removeAll() // CS-2 (v2.10.30): 读游标重置=开启新一轮，清空连线链已粘记录

        recomputeAutoPreviews() // v2.10.3 (P2): refresh cursor badges for the new group

        showToast("已切换至「\(currentSpecialSlot?.name ?? id)」")
    }

    func createSpecialSlot(name: String) {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            let slot = try specialStorage.createSpecialSlot(name: name)
            try specialStorage.switchToSpecialSlot(id: slot.id)
            reloadAll()
            refreshTrigger = UUID()
        } catch SpecialSlotError.duplicateName {
            // v2.9.4 (Feature #4): same-page duplicate names are rejected. Show a
            // non-fatal HUD instead of crashing / force-unwrapping.
            NSLog("[ClipSlots] createSpecialSlot rejected: duplicate name '\(name)'")
            showFloatingNotice(FloatingNotice(
                title: "名称重复",
                subtitle: "当前页面已存在「\(name.trimmingCharacters(in: .whitespacesAndNewlines))」，请换个名字",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
        } catch {
            NSLog("[ClipSlots] createSpecialSlot error: \(error)")
            showFloatingNotice(FloatingNotice(
                title: "创建槽位组失败",
                subtitle: error.localizedDescription,
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
        }
    }

    /// Quick-create a special slot with an auto-numbered name and switch to it.
    func createQuickSpecialSlot() {
        let next = nextAvailableSpecialSlotNumber()
        createSpecialSlot(name: "\(next)")
    }

    private func nextAvailableSpecialSlotNumber() -> Int {
        // v2.4.1: auto-number based on current page's slot groups only
        let existing = Set(currentPageSlotGroups.compactMap { Int($0.name) })
        for i in 1...specialSlotSettings.maxSpecialSlots {
            if !existing.contains(i) { return i }
        }
        return currentPageSlotGroups.count + 1
    }

    func deleteSpecialSlot(id: String) {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.deleteSpecialSlot(id: id)
            reloadAll()
            refreshTrigger = UUID()
        } catch {
            NSLog("[ClipSlots] deleteSpecialSlot error: \(error)")
        }
    }

    func renameSpecialSlot(id: String, name: String) {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.renameSpecialSlot(id: id, name: name)
            loadSpecialSlots()
        } catch {
            NSLog("[ClipSlots] renameSpecialSlot error: \(error)")
        }
    }

    // MARK: - Page Operations (v2.4)

    func createPage(name: String) {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            let page = try specialStorage.createPage(name: name).page
            try specialStorage.switchToPage(id: page.id)
            reloadAll()
            showToast("已创建页面「\(page.name)」")
        } catch {
            NSLog("[ClipSlots] createPage error: \(error)")
            showAlert(message: "创建页面失败: \(error.localizedDescription)")
        }
    }

    func renamePage(id: String, name: String) {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.renamePage(id: id, name: name)
            loadSpecialSlots()
            showToast("页面已重命名")
        } catch {
            NSLog("[ClipSlots] renamePage error: \(error)")
            showAlert(message: "重命名失败: \(error.localizedDescription)")
        }
    }

    func deletePage(id: String) {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.deletePage(id: id)
            reloadAll()
            showToast("页面已删除")
        } catch {
            NSLog("[ClipSlots] deletePage error: \(error)")
            showAlert(message: "删除页面失败: \(error.localizedDescription)")
        }
    }

    func switchToPage(id: String) {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.switchToPage(id: id)
            reloadAllAsync() // P1-3 (v2.10.35): 切页读盘异步化，避免主线程逐槽 flock 卡顿
            if let page = pages.first(where: { $0.id == id }) {
                showToast("已切换至「\(page.name)」")
            }
        } catch {
            NSLog("[ClipSlots] switchToPage error: \(error)")
        }
    }

    // v2.4.1: Cmd+Left / Cmd+Right — cycle through slot groups in current page
    func switchToPreviousSlotGroup() {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.switchToAdjacentSpecialSlot(direction: .previous)
            reloadAllAsync() // P1-3 (v2.10.35): Cmd+Left 相邻切组读盘异步化，避免主线程逐槽 flock 卡顿
            refreshTrigger = UUID()
            if let name = currentSpecialSlot?.name {
                showToast("已切换至「\(name)」")
            }
        } catch {
            NSLog("[ClipSlots] switchToPreviousSlotGroup error: \(error)")
        }
    }

    func switchToNextSlotGroup() {
        suppressWatcher() // v2.9.4 (#2): self-write
        do {
            try specialStorage.switchToAdjacentSpecialSlot(direction: .next)
            reloadAllAsync() // P1-3 (v2.10.35): Cmd+Right 相邻切组读盘异步化，避免主线程逐槽 flock 卡顿
            refreshTrigger = UUID()
            if let name = currentSpecialSlot?.name {
                showToast("已切换至「\(name)」")
            }
        } catch {
            NSLog("[ClipSlots] switchToNextSlotGroup error: \(error)")
        }
    }

    // MARK: - v2.9.31 Auto-Advance After Paste
    //
    // When the "自动切换" toggle is on, pasting the LAST non-empty slot of the
    // current group automatically switches focus + selection to the next group
    // (or the first group of the next page). It never wraps: the last group of
    // the last page simply stays put. When the toggle is off, paste behavior is
    // completely unchanged.

    var isAutoAdvanceEnabled: Bool {
        // v2.10.0: 「自动切换」统一由拨杆3（AutoModeState.autoAdvanceEnabled）控制。
        AutoModeState.shared.autoAdvanceEnabled
    }

    /// Index of the last non-empty slot in the given group, or nil if the group is empty.
    private func lastNonEmptySlot(in specialSlotId: String) -> Int? {
        // v2.9.38: guard against a degenerate `config.slots == 0`, which would make
        // `1...config.slots` an invalid range and crash.
        guard config.slots >= 1 else { return nil }
        var last: Int? = nil
        for slot in 1...config.slots where !specialStorage.isEmpty(slot, in: specialSlotId) {
            last = slot
        }
        return last
    }

    /// Resolve the group we should auto-advance to after finishing `currentGroupId`.
    /// Returns nil when there is nowhere to go (last group of the last page).
    private func autoAdvanceTargetGroupId(from currentGroupId: String) -> String? {
        guard let currentGroup = specialSlots.first(where: { $0.id == currentGroupId }) else { return nil }
        let pageId = currentGroup.pageId

        let groupsInPage = specialSlots
            .filter { $0.pageId == pageId }
            .sorted { $0.order < $1.order }

        if let idx = groupsInPage.firstIndex(where: { $0.id == currentGroupId }),
           idx < groupsInPage.count - 1 {
            // There is a next group within the same page.
            return groupsInPage[idx + 1].id
        }

        // Current group is the last one in its page — move to the next page's first group.
        let sortedPages = pages.sorted { $0.order < $1.order }
        guard let pageIdx = sortedPages.firstIndex(where: { $0.id == pageId }),
              pageIdx < sortedPages.count - 1 else {
            return nil // last page + last group → stop, no wrap.
        }

        let nextPageId = sortedPages[pageIdx + 1].id
        let nextPageGroups = specialSlots
            .filter { $0.pageId == nextPageId }
            .sorted { $0.order < $1.order }
        return nextPageGroups.first?.id
    }

    /// Called after a paste finishes. If auto-advance is enabled and `slot` was the
    /// last non-empty slot of `specialSlotId`, switch to the next group/page
    /// immediately (v2.9.33: no more 0.5s delay) with a subtle animation and a
    /// lightweight toast telling the user where it jumped to.
    // MARK: - v2.9.36 Last Paste Location Tracking

    /// Persist the location of the most recent paste so the footer status bar and
    /// the slot-card "上次粘贴" badge can keep pointing at it (also across relaunches).
    /// Called from every single-slot paste success path (hotkey / radial / UI button).
    func recordLastPaste(slot: Int, in groupId: String) {
        // A group may live on a page that differs from the currently displayed one
        // (e.g. Cmd+number hotkey targets activeHotkeySpecialSlotId). Resolve the
        // group's own page so the recorded location is accurate.
        let pageId = specialSlots.first(where: { $0.id == groupId })?.pageId ?? currentPageId
        let defaults = UserDefaults.standard
        defaults.set(pageId, forKey: UserPreferenceKeys.lastPastePageId)
        defaults.set(groupId, forKey: UserPreferenceKeys.lastPasteGroupId)
        defaults.set(slot, forKey: UserPreferenceKeys.lastPasteSlotIndex)
        // Mirror to @Published so SwiftUI views observing the store refresh promptly.
        lastPastePageId = pageId
        lastPasteGroupId = groupId
        lastPasteSlotIndex = slot
        NSLog("[ClipSlots] recordLastPaste page=\(pageId) group=\(groupId) slot=\(slot)")
    }

    /// Human-readable description for the footer, e.g. "常用页 / 图片组 · 槽位 3".
    /// Returns nil when nothing has been pasted yet or the location no longer exists.
    var lastPasteDescription: String? {
        guard lastPasteSlotIndex >= 0,
              !lastPasteGroupId.isEmpty else { return nil }
        guard let group = specialSlots.first(where: { $0.id == lastPasteGroupId }) else {
            return nil
        }
        let pageName = pages.first(where: { $0.id == lastPastePageId })?.name
            ?? pages.first(where: { $0.id == group.pageId })?.name
        let pagePart = pageName.map { "\($0) / " } ?? ""
        return "\(pagePart)\(group.name) · 槽位 \(lastPasteSlotIndex)"
    }

    /// True when the given slot on the currently displayed group is the last paste target.
    func isLastPasted(slot: Int, groupId: String) -> Bool {
        lastPasteSlotIndex >= 0
            && slot == lastPasteSlotIndex
            && groupId == lastPasteGroupId
    }

    // MARK: - v2.9.37 Jump to Last Paste + flash highlight

    /// Switch the main view to the last-paste page/group and flash-highlight the
    /// slot card for ~2s. Called from the footer "上次粘贴" button.
    func jumpToLastPaste() {
        guard lastPasteSlotIndex >= 0,
              !lastPasteGroupId.isEmpty,
              specialSlots.contains(where: { $0.id == lastPasteGroupId }) else {
            return
        }

        // v2.9.38: switchSpecialSlot (= selectAndActivateSpecialSlot) already syncs
        // the page / currentPageId to the group's own page, so calling switchToPage
        // first was a redundant second reload + animation. Just switch the group.
        if currentSpecialSlotId != lastPasteGroupId {
            withAnimation(.easeInOut(duration: 0.28)) {
                switchSpecialSlot(id: lastPasteGroupId)
            }
        }

        // Flash-highlight the target slot, auto-clearing after 2s (guarded by a
        // token so a newer jump cancels the previous clear).
        let target = FlashHighlightTarget(groupId: lastPasteGroupId, slot: lastPasteSlotIndex)
        let token = UUID()
        flashHighlightToken = token
        withAnimation(.easeInOut(duration: 0.3)) {
            flashHighlightSlot = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.flashHighlightToken == token else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                self.flashHighlightSlot = nil
            }
        }
    }

    /// v2.10.19: 点击「跨组游标提示」跳转到游标所在的组/页并高亮闪烁该槽位（滚动 + 高亮）。
    func jumpToCursorAddress(_ addr: SlotAddress) {
        guard specialSlots.contains(where: { $0.id == addr.groupId }),
              addr.slot >= 1, addr.slot <= config.slots else { return }

        if currentSpecialSlotId != addr.groupId {
            withAnimation(.easeInOut(duration: 0.28)) {
                switchSpecialSlot(id: addr.groupId)
            }
        }

        let target = FlashHighlightTarget(groupId: addr.groupId, slot: addr.slot)
        let token = UUID()
        flashHighlightToken = token
        withAnimation(.easeInOut(duration: 0.3)) {
            flashHighlightSlot = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.flashHighlightToken == token else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                self.flashHighlightSlot = nil
            }
        }
    }

    func maybeAutoAdvance(afterPasting slot: Int, in specialSlotId: String, suppress: Bool = false) {
        guard !suppress else { return } // v2.10.0: 自动粘贴自行管理读游标推进，跳过此处组切换
        guard isAutoAdvanceEnabled else { return }

        // Slots without attachments switch groups immediately. Slots WITH
        // attachments are handled by completeAutoAdvanceAfterAttachments, called
        // from the sequential-paste success callback once every attachment has
        // finished pasting (switching earlier would interrupt the paste).
        performAutoAdvance(afterPasting: slot, in: specialSlotId)
    }

    /// v2.9.37: called from the attachment paste completion handler once all
    /// attachments have finished pasting — it is now safe to advance.
    func completeAutoAdvanceAfterAttachments(afterPasting slot: Int, in specialSlotId: String, suppress: Bool = false) {
        guard !suppress else { return } // v2.10.0: 自动粘贴自行管理读游标推进
        guard isAutoAdvanceEnabled else { return }
        performAutoAdvance(afterPasting: slot, in: specialSlotId)
    }

    // MARK: - v2.10.0 Auto Store / Auto Paste（拨杆状态分流）

    /// 校验持久化游标：若其所属组已不存在或槽位越界，返回 nil（视为从头开始）。
    private func validatedCursor(_ cursor: SpecialSlotCursor?) -> SlotAddress? {
        guard let cursor else { return nil }
        guard specialSlots.contains(where: { $0.id == cursor.groupId }) else { return nil }
        guard cursor.slot >= 1, cursor.slot <= config.slots else { return nil }
        return SlotAddress(groupId: cursor.groupId, slot: cursor.slot)
    }

    /// 拨杆1「自动存储」入口（Opt+1 且 autoStoreEnabled）：
    /// 读取系统剪贴板当前内容 → 找下一个空槽（跨组/跨页由拨杆3决定）→ 写入 → 推进写游标。
    func autoStoreFromHotkey(_ slot: Int) {
        // CR-2 / CS-3 (v2.10.30): 串行化整个 capture→写入→推进游标 流程。若上一次自动存储仍在进行
        // （尚未走完异步剪贴板等待 + 后台写入），忽略本次连按，避免两次按下解析到同一空槽造成重复写入。
        // 注意：以下每一条提前返回分支都必须把标志复位（见各 return 处 / placeCaptured 的所有分支）。
        if isAutoStoreInFlight {
            NSLog("[ClipSlots] autoStoreFromHotkey ignored: previous auto-store still in flight")
            showToast("正在自动存储，请稍候")
            return
        }
        isAutoStoreInFlight = true

        cancelPendingClipboardRestore()

        // v2.10.2: 先模拟 Cmd+C 复制「当前选中内容」，稍等系统完成复制后再读取剪贴板写入下一个空槽。
        // 与不开启自动存储时的 Opt+1 单槽存储体验一致（支持文字/图片/文件等任意类型），区别仅在游标自动推进。
        guard AXIsProcessTrusted() else {
            NSLog("[ClipSlots] Accessibility permission not granted. Cannot capture selection for auto-store.")
            promptAccessibilityPermissionIfNeeded()
            isAutoStoreInFlight = false // CR-2 / CS-3 (v2.10.30): 提前返回，复位在途标志
            return
        }

        let beforeChangeCount = NSPasteboard.general.changeCount
        NSLog("[ClipSlots] autoStoreFromHotkey requested slot=\(slot), beforeChangeCount=\(beforeChangeCount)")

        sendCopyKeystroke()

        waitForClipboardChangeOrDelay(from: beforeChangeCount, timeout: 0.6, interval: 0.03) { [weak self] changed in
            guard let self = self else { return }
            guard changed else {
                NSLog("[ClipSlots] autoStoreFromHotkey ignored: clipboard did not change")
                self.showFloatingNotice(FloatingNotice(
                    title: "自动存储失败",
                    subtitle: "没有捕获到内容，请先选中要复制的内容",
                    iconName: "xmark.circle.fill",
                    kind: .error
                ), duration: 2.5)
                self.isAutoStoreInFlight = false // CR-2 / CS-3 (v2.10.30): 剪贴板未变化，复位在途标志
                return
            }
            self.placeCapturedContentToNextEmptySlot()
        }
    }

    /// v2.10.2: 自动存储的落点写入逻辑——读取剪贴板当前内容并写入下一个空槽（游标自动推进）。
    private func placeCapturedContentToNextEmptySlot() {
        let content = clipboard.capture()
        guard !content.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "剪贴板为空",
                subtitle: "没有可自动存储的内容",
                iconName: "doc.on.clipboard",
                kind: .warning
            ))
            isAutoStoreInFlight = false // CR-2 / CS-3 (v2.10.30): 复位在途标志
            return
        }

        let manager = AutoStoreManager(
            pages: pages,
            groups: specialSlots,
            slotCount: config.slots,
            isEmpty: { [weak self] addr in
                guard let self = self else { return false }
                // PERF: cheap FS-shape probe instead of a full-content read.
                return self.specialStorage.isEmpty(addr.slot, in: addr.groupId)
            }
        )

        let cursor = validatedCursor(specialStorage.autoStoreCursor())
        let autoAdvance = AutoModeState.shared.autoAdvanceEnabled
        let activeGroupId = currentSpecialSlotId

        // CS-1 (v2.10.30): 与 autoPasteFromHotkey 保持一致——扫描起点锁定「当前激活组」。
        // 持久化的写游标若属于别的组（切组 / 跨进程改动），此前会被原样当作扫描起点：在自动切换关闭时
        // 会把内容写进那个「其他组」而非当前激活组。这里把外组游标视为 nil（从当前组头部开始）。
        // 组内推进时仍透传 autoAdvance（组内写满后是否跨组），不改变自动切换 ON 时的既有跨组行为。
        let cursorInActiveGroup: SlotAddress? = (cursor?.groupId == activeGroupId) ? cursor : nil
        let target: SlotAddress?
        if cursorInActiveGroup == nil {
            target = manager.findNextEmptySlot(
                from: nil,
                startGroupId: activeGroupId,
                autoAdvance: false
            )
        } else {
            target = manager.findNextEmptySlot(
                from: cursorInActiveGroup,
                startGroupId: activeGroupId,
                autoAdvance: autoAdvance
            )
        }

        guard let target = target else {
            showFloatingNotice(FloatingNotice(
                title: "所有槽位已满",
                subtitle: autoAdvance ? "全部页面 / 组均无空槽" : "当前组已无空槽",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
            isAutoStoreInFlight = false // CR-2 / CS-3 (v2.10.30): 复位在途标志
            return
        }

        suppressWatcher() // self-write
        // MT-2 / CS-4 (v2.10.30): specialStorage.set 需拿跨进程写锁，锁竞争时最长阻塞 ~5s。把它挪到后台
        // 队列执行，避免卡住主线程；写完再回主线程推进游标 / 切组 / 提示 / 复位在途标志。写入所需的内容与
        // 落点在派发前先固定为不可变快照，后台闭包不读取可变 @Published 状态。
        let capturedContent = content
        let capturedTarget = target
        slotWriteQueue.async { [weak self] in  // P1-1 (v2.10.35): 串行写队列，防并发错序覆盖
            guard let self = self else { return }
            // P2-3 (v2.10.5): 检查 set 返回值（@discardableResult -> Bool）。写入失败时既不推进写游标、
            // 也不弹「已自动存储」成功提示，避免「假成功 + 游标跳过一个未写入的槽位」。
            let ok = self.specialStorage.set(capturedTarget.slot, content: capturedContent, in: capturedTarget.groupId)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // CR-2 / CS-3 (v2.10.30): 无论成功/失败，回到主线程后统一复位在途标志，放行下一次连按。
                defer { self.isAutoStoreInFlight = false }
                guard ok else {
                    self.showFloatingNotice(FloatingNotice(
                        title: "自动存储失败",
                        subtitle: "写入槽位 \(capturedTarget.slot) 未成功，请重试",
                        iconName: "exclamationmark.triangle.fill",
                        kind: .warning
                    ))
                    return
                }
                // 推进写游标（磁盘持久化，跨进程写锁内完成；旧游标压入 prev 供回退）。
                try? self.specialStorage.advanceAutoStoreCursor(to: SpecialSlotCursor(groupId: capturedTarget.groupId, slot: capturedTarget.slot))

                // 让 UI 跟随落点：写到别的组则切过去，否则刷新当前组。
                if capturedTarget.groupId != self.currentSpecialSlotId {
                    self.switchSpecialSlot(id: capturedTarget.groupId)
                } else {
                    self.reloadAllAsync() // P1-3 (v2.10.35): 自动存储回调刷新走异步读盘，避免主线程逐槽 flock 卡顿
                }
                self.recomputeAutoPreviews()

                let groupName = self.specialSlots.first(where: { $0.id == capturedTarget.groupId })?.name ?? ""
                self.showFloatingNotice(FloatingNotice(
                    title: "已自动存储 → 槽位 \(capturedTarget.slot)",
                    subtitle: groupName.isEmpty ? "" : "组「\(groupName)」",
                    iconName: "tray.and.arrow.down.fill",
                    kind: .success
                ))
            }
        }
    }

    /// 拨杆2「自动粘贴」入口（Cmd+1 且 autoPasteEnabled）：
    /// 从读游标位置找下一个非空槽 → 放入系统剪贴板 → 发出 Cmd+V → 推进读游标（跨组/跨页由拨杆3决定）。
    func autoPasteFromHotkey(_ slot: Int) {
        let manager = AutoPasteManager(
            pages: pages,
            groups: specialSlots,
            slotCount: config.slots,
            isNonEmpty: { [weak self] addr in
                guard let self = self else { return false }
                // CS-2 (v2.10.30): 本轮自动粘贴已粘过的连线链成员视为空槽跳过，避免非连续链重复粘贴。
                if self.pastedChainMembersByGroup[addr.groupId]?.contains(addr.slot) == true { return false }
                // PERF: cheap FS-shape probe instead of a full-content read.
                return !self.specialStorage.isEmpty(addr.slot, in: addr.groupId)
            }
        )

        let cursor = validatedCursor(specialStorage.autoPasteCursor())
        let autoAdvance = AutoModeState.shared.autoAdvanceEnabled
        let activeGroupId = currentSpecialSlotId

        // v2.10.19: 自动粘贴游标锁定「当前激活组」，与「自动切换」开关解耦。
        // 此前 autoAdvance=true 且无游标时会走 firstNonEmptySlot()（全局第一页第一组）重启，
        // 而 autoAdvance 状态还间接影响起点，导致：关掉自动切换后游标跑到第一个页面、忽略当前组。
        // 新语义：无论自动切换开/关，起点与轮转范围都以「当前激活组」为基准。
        // - 游标不在当前激活组（切组 / 跨进程改动）→ 视为「在当前组从头开始」，绝不回退全局。
        let cursorInActiveGroup: SlotAddress? = (cursor?.groupId == activeGroupId) ? cursor : nil

        let target: SlotAddress?
        if cursorInActiveGroup == nil {
            // 全新起点：只取「当前激活组」的第一个非空槽（组内域，cursor=nil）。不跨组、不跳全局。
            // 整组为空时返回 nil，走下方「组为空」提示分支。
            target = manager.findNextNonEmptySlot(
                from: nil,
                startGroupId: activeGroupId,
                autoAdvance: false
            )
        } else {
            // 组内推进；autoAdvance 决定「组内粘完后」是否跨组继续（ON 跨组，OFF 组内循环）。
            target = manager.findNextNonEmptySlot(
                from: cursorInActiveGroup,
                startGroupId: activeGroupId,
                autoAdvance: autoAdvance
            )
        }

        guard let target = target else {
            if cursorInActiveGroup == nil {
                // 当前激活组整组为空：明确提示，不静默跳过、不自动切到其他组（无论自动切换开/关）。
                let name = specialSlots.first(where: { $0.id == activeGroupId })?.name ?? "当前组"
                showFloatingNotice(FloatingNotice(
                    title: "「\(name)」没有可粘贴的内容",
                    subtitle: "该组所有槽位均为空，已停止（不会跳到其他组）",
                    iconName: "exclamationmark.triangle.fill",
                    kind: .warning
                ))
                return
            }
            // 自动切换 ON 且已线性推进到全局末尾（后续再无非空组）：重置读游标并提示，不循环卡死。
            try? specialStorage.resetAutoPasteCursor()
            pastedChainMembersByGroup.removeAll() // CS-2 (v2.10.30): 读游标重置=开启新一轮，清空连线链已粘记录
            recomputeAutoPreviews()
            showFloatingNotice(FloatingNotice(
                title: "所有槽位已粘贴完毕",
                subtitle: "读游标已重置，可再次从头开始",
                iconName: "checkmark.circle.fill",
                kind: .success
            ))
            return
        }

        // v2.10.3 (P2): 在推进读游标之前先确认辅助功能权限——否则 pasteSlot 会直接 return，
        // 游标却已前移，导致「粘贴没发生但游标跳过了一个槽位」。
        guard AXIsProcessTrusted() else {
            promptAccessibilityPermissionIfNeeded()
            return
        }

        // 切到目标组，保证 pasteSlot 的 stale-guard（currentSpecialSlotId == activeId）通过。
        if currentSpecialSlotId != target.groupId {
            switchSpecialSlot(id: target.groupId)
        }

        // P2-4 (v2.10.5): 读游标推进改到「粘贴已提交（Cmd+V 已发出 / 附件链已完成）」之后再执行。
        // 此前是先推进游标再调 pasteSlot；若用户在异步 Cmd+V 触发前手动切组，pasteSlot 的
        // stale-guard 会中止粘贴，但游标已前移——导致跳过一个未粘贴的槽位。改用 onCommitted
        // 回调后，只有真正提交粘贴才推进；中止路径不回调，游标保持原位。
        //
        // P1-1 (v2.10.6): 若 target.slot 是一条连线链的链首，pasteSlot 会把整条链依次粘贴，
        // 但旧实现只把游标推进到链首本身，链内后续成员下次触发会被重复粘贴。onCommitted 现在
        // 回传「实际应推进到的槽位」（连线链时为链内最大 slot，可跳过全部成员），据此推进游标。
        pasteSlot(target.slot, suppressAutoAdvance: true) { [weak self] committedSlot in
            guard let self = self else { return }
            try? self.specialStorage.advanceAutoPasteCursor(to: SpecialSlotCursor(groupId: target.groupId, slot: committedSlot))
            self.recomputeAutoPreviews()
        }
    }

    // MARK: - v2.10.1 游标回退 / 重置 / 可视化

    /// 重算「下一次触发的落点」预览（写游标 = 下一个空槽；读游标 = 下一个非空槽），
    /// 用于槽位格子上的绿色 / 蓝色角标。跟随游标推进 / 回退 / 重置、内容变化、拨杆切换调用。
    func recomputeAutoPreviews() {
        let autoAdvance = AutoModeState.shared.autoAdvanceEnabled

        let storeManager = AutoStoreManager(
            pages: pages,
            groups: specialSlots,
            slotCount: config.slots,
            isEmpty: { [weak self] addr in
                guard let self = self else { return false }
                // PERF: cheap FS-shape probe instead of loading full slot content just
                // to check emptiness (this runs on every switch and can scan across
                // groups/pages when 自动切换 is on).
                return self.specialStorage.isEmpty(addr.slot, in: addr.groupId)
            }
        )
        autoStorePreview = storeManager.findNextEmptySlot(
            from: validatedCursor(specialStorage.autoStoreCursor()),
            startGroupId: currentSpecialSlotId,
            autoAdvance: autoAdvance
        )

        let pasteManager = AutoPasteManager(
            pages: pages,
            groups: specialSlots,
            slotCount: config.slots,
            isNonEmpty: { [weak self] addr in
                guard let self = self else { return false }
                // CS-2 (v2.10.30): 预览与实际自动粘贴一致——已粘过的连线链成员视为空槽跳过。
                if self.pastedChainMembersByGroup[addr.groupId]?.contains(addr.slot) == true { return false }
                // PERF: cheap FS-shape probe instead of a full-content read.
                return !self.specialStorage.isEmpty(addr.slot, in: addr.groupId)
            }
        )
        // v2.10.19: 预览角标须与 autoPasteFromHotkey 一致——起点与轮转范围锁定「当前激活组」，
        // 与自动切换开关解耦。游标不在当前组则视为「当前组从头开始」，不回退全局第一页。
        let pasteCursor = validatedCursor(specialStorage.autoPasteCursor())
        let pasteCursorInActiveGroup: SlotAddress? =
            (pasteCursor?.groupId == currentSpecialSlotId) ? pasteCursor : nil
        if pasteCursorInActiveGroup == nil {
            autoPastePreview = pasteManager.findNextNonEmptySlot(
                from: nil,
                startGroupId: currentSpecialSlotId,
                autoAdvance: false
            )
        } else {
            autoPastePreview = pasteManager.findNextNonEmptySlot(
                from: pasteCursorInActiveGroup,
                startGroupId: currentSpecialSlotId,
                autoAdvance: autoAdvance
            )
        }
    }

    /// 写游标回退一步（撤销最近一次自动存储的推进），并刷新预览角标。
    func autoStoreCursorGoBack() {
        _ = try? specialStorage.goBackAutoStoreCursor()
        recomputeAutoPreviews()
        showFloatingNotice(FloatingNotice(
            title: "写游标已回退",
            subtitle: "下一次 Opt+1 从上一个位置重新计算",
            iconName: "arrow.uturn.backward",
            kind: .info
        ))
    }

    /// 写游标重置到初始（从第一个空槽重新开始），并刷新预览角标。
    func autoStoreCursorReset() {
        try? specialStorage.resetAutoStoreCursor()
        recomputeAutoPreviews()
        showFloatingNotice(FloatingNotice(
            title: "写游标已重置",
            subtitle: "下一次 Opt+1 从第一个空槽重新开始",
            iconName: "backward.end",
            kind: .info
        ))
    }

    /// 读游标回退一步（撤销最近一次自动粘贴的推进），并刷新预览角标。
    func autoPasteCursorGoBack() {
        _ = try? specialStorage.goBackAutoPasteCursor()
        recomputeAutoPreviews()
        showFloatingNotice(FloatingNotice(
            title: "读游标已回退",
            subtitle: "下一次 Cmd+1 从上一个位置重新计算",
            iconName: "arrow.uturn.backward",
            kind: .info
        ))
    }

    /// 读游标重置到当前激活组的第一个非空槽（与切组时的自动行为一致），并刷新预览角标。
    func autoPasteCursorReset() {
        try? specialStorage.resetAutoPasteCursor()
        pastedChainMembersByGroup.removeAll() // CS-2 (v2.10.30): 读游标重置=开启新一轮，清空连线链已粘记录
        recomputeAutoPreviews()
        showFloatingNotice(FloatingNotice(
            title: "读游标已重置",
            subtitle: "下一次 Cmd+1 从当前组第一个非空槽重新开始",
            iconName: "backward.end",
            kind: .info
        ))
    }

    private func performAutoAdvance(afterPasting slot: Int, in specialSlotId: String) {
        guard isAutoAdvanceEnabled else { return }
        guard let last = lastNonEmptySlot(in: specialSlotId), slot == last else { return }
        guard let targetId = autoAdvanceTargetGroupId(from: specialSlotId) else {
            NSLog("[ClipSlots] autoAdvance: reached last group of last page, staying put")
            return
        }

        // v2.9.33: guard against the user having manually switched groups already.
        guard currentSpecialSlotId == specialSlotId
                || activeHotkeySpecialSlotId == specialSlotId else {
            NSLog("[ClipSlots] autoAdvance: group changed before advance fired, skipping")
            return
        }

        // Resolve whether this advance crosses a page boundary, and the display names,
        // BEFORE switching so we can craft the right toast message.
        let fromPageId = specialSlots.first(where: { $0.id == specialSlotId })?.pageId
        let targetGroup = specialSlots.first(where: { $0.id == targetId })
        let targetGroupName = targetGroup?.name ?? "下一组"
        let crossedPage = targetGroup?.pageId != nil && targetGroup?.pageId != fromPageId
        let targetPageName = pages.first(where: { $0.id == targetGroup?.pageId })?.name ?? "下一页"

        NSLog("[ClipSlots] autoAdvance: slot=\(slot) is last non-empty in \(specialSlotId), advancing to \(targetId) immediately")

        withAnimation(.easeInOut(duration: 0.28)) {
            self.switchSpecialSlot(id: targetId)
        }

        // v2.9.33: override the generic "已切换至" toast from switchSpecialSlot with a
        // dedicated auto-advance message that stays ~1.5s.
        let message = crossedPage
            ? "已跳转到下一页 · \(targetPageName)"
            : "已切换到「\(targetGroupName)」"
        showToast(message, duration: 1.5)
    }

    // MARK: - Delete Special Slot with Confirmation

    func deleteSpecialSlotWithConfirmation(id: String) {
        guard let target = specialSlots.first(where: { $0.id == id }) else { return }

        if specialSlotSettings.confirmBeforeDeleteSpecialSlot {
            let alert = NSAlert()
            alert.messageText = "删除槽位组？"
            alert.informativeText = "将删除槽位组「\(target.name)」及其全部槽位内容。此操作会移动到回收目录。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")

            let checkbox = NSButton(checkboxWithTitle: "不再提醒", target: nil, action: nil)
            alert.accessoryView = checkbox

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }

            if checkbox.state == .on {
                do {
                    try specialStorage.updateSettings { $0.confirmBeforeDeleteSpecialSlot = false }
                    specialSlotSettings.confirmBeforeDeleteSpecialSlot = false
                } catch {
                    NSLog("[ClipSlots] update confirmBeforeDeleteSpecialSlot failed: \(error)")
                }
            }
        }

        deleteSpecialSlot(id: id)
    }

    // MARK: - Clear All Slots

    // MARK: - v2.7.26 Undo Clear

    // v2.9.5 (Feature #3): the clear/delete undo snapshot is now Codable and
    // persisted to disk so a pending undo survives an app restart.
    private struct SlotUndoSnapshot: Codable {
        let slots: [Int: SlotContent]
        let labels: [Int: String]
        let title: String
        // v2.8.7 (D): remember which group the snapshot belongs to so Undo cannot
        // restore into a different (wrong) group after the user switches groups.
        let specialSlotId: String
    }
    private var lastClearSnapshot: SlotUndoSnapshot?

    // v2.9.5 (Feature #3): on-disk location for the persisted undo snapshot. Lives
    // alongside the special-slot storage so it shares the same lifecycle/backups.
    private var undoSnapshotURL: URL {
        ClipSlotsPaths.specialSlots.appendingPathComponent(".undo/clear_snapshot.json")
    }

    /// Write (or, when nil, delete) the persisted undo snapshot. Never throws — a
    /// persistence failure must not break the clear/undo operation itself.
    private func persistUndoSnapshot(_ snapshot: SlotUndoSnapshot?) {
        let url = undoSnapshotURL
        let fm = FileManager.default
        guard let snapshot else {
            try? fm.removeItem(at: url)
            return
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[ClipSlots] persist undo snapshot failed: \(error)")
        }
    }

    /// Load a previously persisted undo snapshot into memory at launch, so the
    /// most recent clear/delete remains undoable after a restart.
    private func loadPersistedUndoSnapshot() {
        guard let data = try? Data(contentsOf: undoSnapshotURL),
              let snapshot = try? JSONDecoder().decode(SlotUndoSnapshot.self, from: data) else {
            return
        }
        lastClearSnapshot = snapshot
        NSLog("[ClipSlots] restored persisted undo snapshot: \(snapshot.title)")
    }

    private func captureUndoSnapshot(title: String) {
        lastClearSnapshot = SlotUndoSnapshot(slots: slots, labels: labels, title: title, specialSlotId: currentSpecialSlotId)
        // v2.9.5 (Feature #3): persist immediately so the undo survives a restart.
        persistUndoSnapshot(lastClearSnapshot)
    }

    func undoLastClearIfPossible() {
        guard let snapshot = lastClearSnapshot else {
            showFloatingNotice(FloatingNotice(title: "没有可撤销操作", subtitle: "最近没有清空或删除槽位", iconName: "arrow.uturn.backward", kind: .warning))
            return
        }
        // v2.8.7 (D): the snapshot must be restored into the same group it was
        // captured from; otherwise Undo would corrupt whatever group is now active.
        guard snapshot.specialSlotId == currentSpecialSlotId else {
            showFloatingNotice(FloatingNotice(title: "无法撤销", subtitle: "请切回原分组后再撤销", iconName: "arrow.uturn.backward", kind: .warning))
            return
        }
        slots = snapshot.slots
        labels = snapshot.labels
        persistCurrentSpecialSlotData()
        lastClearSnapshot = nil
        // v2.9.5 (Feature #3): consume the persisted snapshot so it cannot be
        // replayed after the next restart.
        persistUndoSnapshot(nil)
        showFloatingNotice(FloatingNotice(title: "已撤销", subtitle: snapshot.title, iconName: "arrow.uturn.backward.circle.fill", kind: .success))
    }

    private func persistCurrentSpecialSlotData() {
        suppressWatcher() // v2.9.4 (#2): our own write — don't let it trigger a reload
        let activeId = currentSpecialSlotId
        // MT-1 (v2.10.30): 逐槽写盘（每次 set/setLabel 需拿跨进程写锁，锁竞争时最长各阻塞 ~5s）此前直接
        // 跑在主线程，拖拽导入 / 文本编辑等会卡住 UI。改为：在主线程先固定 slots/labels 的不可变快照，再把
        // 实际磁盘写入整体挪到后台队列。in-memory 的 slots/labels 变更已由各调用方在主线程完成（UI 立即
        // 更新），此处仅做持久化；写入成功与否不驱动任何后续 UI（与原同步实现一致，均忽略返回值）。
        let slotsSnapshot = slots
        let labelsSnapshot = labels
        slotWriteQueue.async { [weak self] in  // P1-1 (v2.10.35): 串行写队列，防并发错序覆盖
            guard let self = self else { return }
            for (slot, content) in slotsSnapshot {
                self.specialStorage.set(slot, content: content, in: activeId)
            }
            for (slot, label) in labelsSnapshot {
                self.specialStorage.setLabel(slot, label: label, in: activeId)
            }
        }
    }

    // MARK: - v2.7.33 HTML Source Preservation
    // public.html copied from Feishu/Lark is rich HTML. Previous versions stored
    // only '[HTML]' preview + extracted plain text, so preview/edit could never
    // render the original button/chip UI again. Store original HTML separately.
    func saveHTMLToSlot(_ slot: Int, html: String, plainText: String? = nil) {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var content = SlotContent(text: plainText?.isEmpty == false ? plainText! : html)
        content.htmlSource = html
        // v2.7.74: preserve existing attachments when updating slot content.
        // v2.8.7 (A): read via contentForSlot so disk-backed attachments survive a cache miss.
        content.attachments = contentForSlot(slot).attachments
        slots[slot] = content
        persistCurrentSpecialSlotData()
        refreshTrigger = UUID()
        showFloatingNotice(FloatingNotice(title: "已保存 HTML", subtitle: "槽位 \(slot)", iconName: "doc.richtext", kind: .success))
    }

    func updateHTMLSlot(_ slot: Int, html: String) {
        var content = slots[slot] ?? SlotContent(text: html)
        content.htmlSource = html
        // v2.8.0 (P1-1): explicitly carry over existing attachments so editing the
        // HTML source of a slot never silently drops its attachments.
        // v2.8.7 (A): read via contentForSlot so disk-backed attachments survive a cache miss.
        content.attachments = contentForSlot(slot).attachments
        slots[slot] = content
        persistCurrentSpecialSlotData()
        refreshTrigger = UUID()
    }

    // MARK: - v2.7.27 Text Edit / Drag File Import

    func updateTextSlot(_ slot: Int, text: String) {
        let data = text.data(using: .utf8) ?? Data()
        let item = PasteboardItem(type: "public.utf8-plain-text", data: data)
        var content = SlotContent()
        content.items = [[item]]
        content.timestamp = Date()
        // v2.7.74 BUGFIX: editing a slot's text used to build a fresh SlotContent()
        // and overwrite the whole record, silently dropping the slot's attachments.
        // Carry the existing attachments over so editing content keeps them.
        // v2.8.7 (A): read via contentForSlot so disk-backed attachments survive a cache miss.
        content.attachments = contentForSlot(slot).attachments
        slots[slot] = content
        persistCurrentSpecialSlotData()
        showFloatingNotice(FloatingNotice(title: "已更新文本", subtitle: "槽位 \(slot)", iconName: "pencil.circle.fill", kind: .success))
    }

    func importDroppedFiles(_ urls: [URL], toSlot slot: Int) {
        guard let first = urls.first else { return }
        for (offset, url) in urls.enumerated() {
            let target = slot + offset
            guard target <= config.slots else { break }
            var newContent = folderImportService.makeSlotContent(for: url)
            // v2.7.74: preserve existing attachments when replacing slot content.
            newContent.attachments = slots[target]?.attachments ?? []
            slots[target] = newContent
        }
        // MT-1 (v2.10.30): persistCurrentSpecialSlotData 已改为「主线程快照 + 后台写盘」，此处拖拽导入
        // 不再在主线程上逐槽同步写锁写盘。
        persistCurrentSpecialSlotData()
        showFloatingNotice(FloatingNotice(title: "已导入文件", subtitle: urls.count == 1 ? first.lastPathComponent : "\(urls.count) 个文件", iconName: "folder.badge.plus", kind: .success))
    }

    func clearAllSlotsInCurrentSpecialSlotWithConfirmation() {
        captureUndoSnapshot(title: "清空槽位组「\(currentSpecialSlot?.name ?? currentSpecialSlotId)」")
        if !specialSlotSettings.confirmBeforeClearAllSlots {
            clearAllSlotsInCurrentSpecialSlot()
            return
        }

        let alert = NSAlert()
        alert.messageText = "清空当前槽位组？"
        alert.informativeText = "将清空「\(currentSpecialSlot?.name ?? "当前槽位组")」中的全部槽位内容。此操作不会删除槽位组本身。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")

        let checkbox = NSButton(checkboxWithTitle: "不再提醒", target: nil, action: nil)
        alert.accessoryView = checkbox

        // MT-3 (v2.10.30): 原 alert.runModal() 会阻塞主 run loop。改为非阻塞 sheet，确认后的清空动作移到
        // 完成闭包里执行；取不到宿主窗口时回退到 runModal() 以免流程中断。
        let onConfirm: (NSButton) -> Void = { [weak self] checkbox in
            guard let self = self else { return }
            if checkbox.state == .on {
                do {
                    try self.specialStorage.updateSettings { $0.confirmBeforeClearAllSlots = false }
                    self.specialSlotSettings.confirmBeforeClearAllSlots = false
                } catch {
                    NSLog("[ClipSlots] update confirmBeforeClearAllSlots failed: \(error)")
                }
            }
            self.clearAllSlotsInCurrentSpecialSlot()
        }

        guard let window = sheetHostWindow() else {
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
            onConfirm(checkbox)
            return
        }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            onConfirm(checkbox)
        }
    }

    func clearAllSlotsInCurrentSpecialSlot() {
        let activeId = currentSpecialSlotId
        suppressWatcher() // v2.9.4 (#2): self-write
        cancelPendingClipboardRestore()

        ThumbnailProvider.shared.invalidateSpecialSlot(specialSlotId: activeId)

        do {
            // write guard removed (no timer)
            // defer removed (no timer)

            try specialStorage.clearAllSlots(in: activeId)

            var emptySlots: [Int: SlotContent] = [:]
            for slot in 1...config.slots {
                emptySlots[slot] = SlotContent()
            }

            slots = emptySlots
            labels = [:]
            loadedSpecialSlotId = activeId
            refreshTrigger = UUID()

            NSLog("[ClipSlots] CLEAR ALL specialSlot=\(activeId)")
        } catch {
            NSLog("[ClipSlots] CLEAR ALL failed specialSlot=\(activeId) error=\(error)")
            showAlert(message: "清空失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Paste All Slots

    private func orderedNonEmptySlots() -> [(slot: Int, content: SlotContent)] {
        (1...config.slots).compactMap { slot in
            let content = contentForSlot(slot)
            return content.isEmpty ? nil : (slot, content)
        }
    }

    // v2.7.58: radial group-hover preview support.
    func firstNonEmptySlotContent(pageId: String, specialSlotId: String) -> SlotContent? {
        for slot in 1...config.slots {
            let content = specialStorage.get(slot, in: specialSlotId)
            if !content.isEmpty { return content }
        }
        return nil
    }

    // v2.7.59: right-top realtime preview needs both content and its original slot.
    func firstNonEmptySlotSnapshot(pageId: String, specialSlotId: String) -> (slot: Int, content: SlotContent)? {
        for slot in 1...config.slots {
            let content = specialStorage.get(slot, in: specialSlotId)
            if !content.isEmpty { return (slot, content) }
        }
        return nil
    }

    func pasteAllSlotsWithConfirmation() {
        let items = orderedNonEmptySlots()

        guard !items.isEmpty else {
            showAlert(message: "当前槽位组没有可粘贴的内容")
            return
        }

        if specialSlotSettings.confirmBeforePasteAllSlots {
            let alert = NSAlert()
            alert.messageText = "按序粘贴全部槽位？"
            alert.informativeText = "将按 1 到 \(config.slots) 的顺序，粘贴「\(currentSpecialSlot?.name ?? currentSpecialSlotId)」中的 \(items.count) 个非空槽位。"
            alert.addButton(withTitle: "开始粘贴")
            alert.addButton(withTitle: "取消")

            let checkbox = NSButton(checkboxWithTitle: "不再提醒", target: nil, action: nil)
            alert.accessoryView = checkbox

            // MT-3 (v2.10.30): 原 alert.runModal() 会阻塞主 run loop。改为非阻塞 sheet，确认后的粘贴动作
            // 移到完成闭包里执行（并 return 以跳过下方无条件调用）；取不到宿主窗口时回退 runModal()。
            let onConfirm: (NSButton) -> Void = { [weak self] checkbox in
                guard let self = self else { return }
                if checkbox.state == .on {
                    do {
                        try self.specialStorage.updateSettings { $0.confirmBeforePasteAllSlots = false }
                        self.specialSlotSettings.confirmBeforePasteAllSlots = false
                    } catch {
                        NSLog("[ClipSlots] update confirmBeforePasteAllSlots failed: \(error)")
                    }
                }
                self.pasteAllSlotsFromUI()
            }

            guard let window = sheetHostWindow() else {
                let response = alert.runModal()
                guard response == .alertFirstButtonReturn else { return }
                onConfirm(checkbox)
                return
            }
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                onConfirm(checkbox)
            }
            return
        }

        pasteAllSlotsFromUI()
    }

    func pasteAllSlotsFromUI() {
        guard let target = lastNonClipSlotsApp else {
            showAlert(message: "没有可粘贴的目标应用。请先切换到目标应用后再试。")
            return
        }
        pasteAllSlotsToApp(targetApp: target)
    }

    func pasteAllSlotsToApp(targetApp: NSRunningApplication?) {
        let items = orderedNonEmptySlots()

        guard !items.isEmpty else {
            NSLog("[ClipSlots] pasteAll ignored: no content specialSlot=\(currentSpecialSlotId)")
            return
        }

        // P1-2 (v2.10.6): 「粘贴全部」改走带代数号(generation)守卫的统一执行器 runSequentialPaste
        // （经由 pasteSlotChainSequentially）。旧的 pasteItemsSequentially 是一条无中止守卫的递归
        // 链，快速重触发 / 中途切组会与旧序列交织错乱、乱序粘贴。runSequentialPaste 每次开跑都会
        // 领取新的 generation 令牌并作废在飞的旧序列，且统一处理 AX 权限、目标应用激活与剪贴板还原。
        let cleanTarget: NSRunningApplication?
        if isSelfApp(targetApp) {
            cleanTarget = lastNonClipSlotsApp
        } else {
            cleanTarget = targetApp ?? lastNonClipSlotsApp
        }

        let slotNumbers = items.map { $0.slot }
        let count = slotNumbers.count
        pasteSlotChainSequentially(
            slotNumbers,
            noticeTitle: "已粘贴全部 \(count) 个槽位",
            noticeSubtitle: "按顺序依次粘贴",
            activeId: currentSpecialSlotId,
            targetApp: cleanTarget
        )
    }

    // MARK: - Slot Loading

    func loadSlots() {
        let activeId = currentSpecialSlotId
        NSLog("[ClipSlots] loadSlots activeSpecialSlotId=\(activeId)")
        // P0-1 (v2.10.30): 磁盘重读逻辑抽到 readSlotsSnapshot（纯函数，不触碰 @Published）。
        // 同步路径（init / 显式切组）保持原样：读完立即在主线程赋值 @Published。
        let snapshot = readSlotsSnapshot(for: activeId)
        slots = snapshot.slots
        labels = snapshot.labels
        loadedSpecialSlotId = activeId
    }

    // APP-2 (v2.10.32): async variant of loadSlots() for the GROUP-SWITCH path. loadSlots() does
    // N per-slot cross-process flock reads (each up to ~5s under lock contention); running it
    // synchronously on the main thread froze the entire GUI when switching groups while the CLI
    // was writing in batch. The switch functions already clear slots/labels and update the
    // title/@Published selection synchronously (instant visual feedback), and the follow-up
    // recomputeAutoPreviews()/loadConnectionMapForCurrentGroup() do NOT read the in-memory `slots`
    // dict, so the heavy disk read can move to a background queue and back-fill slots/labels when
    // done. Reuses the shared reloadGeneration stamp (also bumped by reloadAllAsync) so a rapid
    // A→B→A switch — or a concurrent watcher reload — can never let an older read clobber the
    // newer group's state.
    private func loadSlotsAsync() {
        let activeId = currentSpecialSlotId
        reloadGeneration &+= 1
        let gen = reloadGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let snapshot = self.readSlotsSnapshot(for: activeId)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard activeId == self.currentSpecialSlotId, gen == self.reloadGeneration else {
                    NSLog("[ClipSlots] loadSlotsAsync: dropping stale/superseded snapshot for \(activeId)")
                    return
                }
                self.slots = snapshot.slots
                self.labels = snapshot.labels
                self.loadedSpecialSlotId = activeId
                self.refreshTrigger = UUID()
            }
        }
    }

    // P0-1 (v2.10.30): 逐槽磁盘读取（每次 get/getLabel 需拿跨进程 flock，最长阻塞 ~5s）。抽为纯函数
    // 返回局部字典，不做任何 @Published 赋值，便于在后台队列调用（见 reloadAllAsync），避免 watcher
    // 触发的 reload 在主线程上被 flock 阻塞导致 GUI 卡死（转圈）。
    private func readSlotsSnapshot(for activeId: String) -> (slots: [Int: SlotContent], labels: [Int: String]) {
        var result: [Int: SlotContent] = [:]
        var labelMap: [Int: String] = [:]
        // P2-7 (v2.10.7): 配置损坏导致 config.slots==0 时，1...0 闭区间会 fatalError；改用 stride 空迭代。
        for slot in stride(from: 1, through: config.slots, by: 1) {
            result[slot] = specialStorage.get(slot, in: activeId)
            if let label = specialStorage.getLabel(slot, in: activeId), !label.isEmpty {
                labelMap[slot] = label
            }
        }
        return (result, labelMap)
    }

    // MARK: - Helpers

    /// Show a transient toast message that auto-dismisses after 1.2s.
    private func showToast(_ message: String, duration: TimeInterval = 1.2) {
        toastMessage = message
        let captured = message
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.toastMessage == captured {
                self?.toastMessage = nil
            }
        }
    }

    /// v2.6.2: Show a floating notice with icon/title/subtitle, auto-dismiss.
    func showFloatingNotice(_ notice: FloatingNotice, duration: TimeInterval = 2.0) {
        floatingNotice = notice
        // v2.6.3: Also show global HUD so the notice is visible when
        // ClipSlots main window is not in front (e.g. hotkey save from Finder).
        FloatingNoticeWindowController.shared.show(notice: notice, duration: duration)
        let noticeId = notice.id
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.floatingNotice?.id == noticeId {
                self?.floatingNotice = nil
            }
        }
    }

    /// v2.7.2: Public accessor for node canvas.
    func slotContent(for slot: Int) -> SlotContent {
        contentForSlot(slot)
    }

    /// Returns slot content: in-memory state first (only if it belongs to current special slot), fallback to disk.
    private func contentForSlot(_ slot: Int) -> SlotContent {
        let activeId = currentSpecialSlotId

        // Only trust memory cache if it belongs to the currently active special slot.
        if loadedSpecialSlotId == activeId, let inMemory = slots[slot], !inMemory.isEmpty {
            NSLog("[ClipSlots] contentForSlot memory specialSlot=\(activeId) slot=\(slot) preview=\(inMemory.preview)")
            return inMemory
        }

        let stored = specialStorage.get(slot, in: activeId)
        NSLog("[ClipSlots] contentForSlot storage specialSlot=\(activeId) slot=\(slot) preview=\(stored.preview) loadedSpecialSlotId=\(loadedSpecialSlotId ?? "nil")")
        return stored
    }

    // MARK: - v2.7.65 Slot Attachments (node canvas)

    /// Attachments of a slot in the currently active group.
    func attachments(for slot: Int) -> [SlotContent.SlotAttachment] {
        specialStorage.get(slot, in: currentSpecialSlotId).attachments
    }

    /// Persist the attachment list for a slot in the currently active group and
    /// refresh in-memory state so the node canvas updates immediately.
    func setAttachments(_ attachments: [SlotContent.SlotAttachment], for slot: Int) {
        let activeId = currentSpecialSlotId
        suppressWatcher() // v2.9.4 (#2): self-write
        // P1-1 (v2.10.36): 修复 v2.10.35 P1-4 引入的附件 lost-update 回归。
        // 上一版把 get + set 整体挪到 slotWriteQueue，并把内存视图 slots[slot] 的更新推迟到「异步写盘完成
        // 回主线程之后」。这段窗口里 in-memory slots[slot] 仍是旧附件，而 App 其它写盘路径
        // （persistCurrentSpecialSlotData / updateTextSlot / saveHTMLToSlot 等）都是「主线程抓 slots 快照 →
        // 整份 content 落盘」，且靠 contentForSlot(优先读内存) 来「保留」附件。于是窗口内一旦触发这些路径，
        // 就会用缺新附件的陈旧快照把刚写进磁盘的附件覆盖掉（串行队列 FIFO 让陈旧写稳定最后落盘 → 稳定丢失），
        // 在写盘队列拥塞（CLI 批量写 / 另一实例持锁 ~5s）时窗口最长、最易复现。
        // 修法：主线程先做同步「乐观内存更新」——用 contentForSlot 取当前最新内容（common case 命中内存、无
        // flock，成本极低）替换 attachments 后立即写回 slots[slot]，关闭 lost-update 窗口；磁盘写盘仍走
        // slotWriteQueue 异步串行（保序、last-write-wins、不卡主线程），保留 P1-4 的防 Beachball 收益。
        var content = contentForSlot(slot)
        content.attachments = attachments
        if loadedSpecialSlotId == activeId {
            slots[slot] = content
        }
        refreshTrigger = UUID()
        let toWrite = content
        slotWriteQueue.async { [weak self] in
            guard let self = self else { return }
            _ = self.specialStorage.set(slot, content: toWrite, in: activeId)
        }
    }

    private func isSelfApp(_ app: NSRunningApplication?) -> Bool {
        guard let app = app else { return false }
        return app.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func cancelPendingClipboardRestore(restoreImmediately: Bool = true) {
        if restoreImmediately, let content = pendingClipboardRestoreContent {
            _ = clipboard.restore(content)
        }
        pendingClipboardRestoreContent = nil
        pendingClipboardRestore?.cancel()
        pendingClipboardRestore = nil
    }

    private func cancelPendingPasteOperations(restoreClipboard: Bool = true) {
        pendingPasteWorkItem?.cancel()
        pendingPasteWorkItem = nil
        abortInFlightSequence(restoreClipboard: restoreClipboard)
        cancelPendingClipboardRestore(restoreImmediately: restoreClipboard)
    }

    /// v2.8.1 (P0-1): synchronously supersede any in-flight sequential paste. Bumps
    /// the generation token (so scheduled recursion steps become no-ops), optionally
    /// restores that sequence's captured clipboard, and cleans its temp image files.
    private func abortInFlightSequence(restoreClipboard: Bool) {
        pasteSequenceGeneration &+= 1
        if let prev = inFlightSequencePrevious {
            if restoreClipboard { _ = clipboard.restore(prev) }
            inFlightSequencePrevious = nil
        }
        if !inFlightSequenceTempFiles.isEmpty {
            cleanupTempFiles(inFlightSequenceTempFiles)
            inFlightSequenceTempFiles = []
        }
    }

    private func promptAccessibilityPermissionIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func waitUntilFrontmost(
        _ app: NSRunningApplication,
        timeout: TimeInterval = 1.2,
        interval: TimeInterval = 0.05,
        completion: @escaping (Bool) -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.processIdentifier == app.processIdentifier {
                completion(true)
                return
            }
            if Date() >= deadline {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { check() }
        }
        check()
    }

    // MARK: - Send Keystroke

    /// Explicit Cmd down → V down → V up → Cmd up
    func sendPasteKeystroke() {
        guard AXIsProcessTrusted() else {
            NSLog("[ClipSlots] Accessibility permission not granted. Cannot send Cmd+V.")
            promptAccessibilityPermissionIfNeeded()
            return
        }

        let vKey = virtualKeyForCharacterV()
        let commandKey: CGKeyCode = 55
        let src = CGEventSource(stateID: .hidSystemState)

        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: true)
        let vDown   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let vUp     = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: false)

        vDown?.flags = .maskCommand
        vUp?.flags   = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        NSLog("[ClipSlots] Sent explicit Cmd+V keystroke, vKey=\(vKey)")
    }

    /// Send explicit Cmd+C keystroke to copy current selection in frontmost app.
    func sendCopyKeystroke() {
        guard AXIsProcessTrusted() else {
            NSLog("[ClipSlots] Accessibility permission not granted. Cannot send Cmd+C.")
            promptAccessibilityPermissionIfNeeded()
            return
        }

        let cKey: CGKeyCode = 8
        let commandKey: CGKeyCode = 55
        let src = CGEventSource(stateID: .hidSystemState)

        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: true)
        let cDown   = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true)
        let cUp     = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: false)

        cDown?.flags = .maskCommand
        cUp?.flags   = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        cDown?.post(tap: .cghidEventTap)
        cUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        NSLog("[ClipSlots] Sent explicit Cmd+C keystroke")
    }

    /// Poll until clipboard changeCount differs from `changeCount` or timeout.
    private func waitForClipboardChangeOrDelay(
        from changeCount: Int,
        timeout: TimeInterval = 0.6,
        interval: TimeInterval = 0.03,
        completion: @escaping (Bool) -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        func check() {
            if NSPasteboard.general.changeCount != changeCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { completion(true) }
                return
            }
            if Date() >= deadline {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { check() }
        }
        check()
    }

    /// For global save hotkey: send Cmd+C to copy current selection, wait for clipboard update, then save.
    func captureSelectionAndSaveToSlot(_ slot: Int) {
        guard !isBatchSaving else {
            showToast("正在批量保存，请稍候")
            return
        }
        cancelPendingClipboardRestore()

        guard AXIsProcessTrusted() else {
            NSLog("[ClipSlots] Accessibility permission not granted. Cannot capture selection.")
            promptAccessibilityPermissionIfNeeded()
            return
        }

        let beforeChangeCount = NSPasteboard.general.changeCount
        NSLog("[ClipSlots] captureSelectionAndSaveToSlot requested slot=\(slot), beforeChangeCount=\(beforeChangeCount)")

        sendCopyKeystroke()

        waitForClipboardChangeOrDelay(from: beforeChangeCount, timeout: 0.6, interval: 0.03) { [weak self] changed in
            guard let self = self else { return }

            guard changed else {
                NSLog("[ClipSlots] captureSelectionAndSaveToSlot ignored: clipboard did not change slot=\(slot)")
                self.showFloatingNotice(FloatingNotice(
                    title: "保存失败",
                    subtitle: "没有捕获到内容，请先复制",
                    iconName: "xmark.circle.fill",
                    kind: .error
                ), duration: 2.5)
                return
            }

            let content = self.clipboard.capture()
            guard !content.isEmpty else {
                NSLog("[ClipSlots] captureSelectionAndSaveToSlot ignored: empty capture slot=\(slot)")
                self.showFloatingNotice(FloatingNotice(
                    title: "保存失败",
                    subtitle: "没有可保存的内容",
                    iconName: "xmark.circle.fill",
                    kind: .error
                ), duration: 2.5)
                return
            }

            // v2.6.1: Overwrite confirmation (was bypassed in v2.6.0)
            let existing = self.contentForSlot(slot)
            if !existing.isEmpty && !UserDefaults.standard.skipOverwriteConfirmation {
                let alert = NSAlert()
                alert.messageText = "覆盖槽位 \(slot)？"
                alert.informativeText = "槽位 \(slot) 已有内容，继续保存会替换原内容。"
                alert.addButton(withTitle: "覆盖")
                alert.addButton(withTitle: "取消")

                let checkbox = NSButton(checkboxWithTitle: "以后覆盖时不再提醒", target: nil, action: nil)
                alert.accessoryView = checkbox

                // MT-3 (v2.10.30): 原 alert.runModal() 会阻塞主 run loop。改为非阻塞 sheet；确认后的保存动作
                // 移到完成闭包（并 return 跳过下方无条件保存）；取不到宿主窗口时回退 runModal()。
                let onConfirm: (NSButton) -> Void = { [weak self] checkbox in
                    guard let self = self else { return }
                    if checkbox.state == .on {
                        UserDefaults.standard.set(true, forKey: UserPreferenceKeys.skipOverwriteConfirmation)
                    }
                    self.handleCapturedContentForSave(content, targetSlot: slot)
                }

                guard let window = self.sheetHostWindow() else {
                    let response = alert.runModal()
                    guard response == .alertFirstButtonReturn else {
                        NSLog("[ClipSlots] SAVE cancelled by user slot=\(slot)")
                        return
                    }
                    onConfirm(checkbox)
                    return
                }
                alert.beginSheetModal(for: window) { response in
                    guard response == .alertFirstButtonReturn else {
                        NSLog("[ClipSlots] SAVE cancelled by user slot=\(slot)")
                        return
                    }
                    onConfirm(checkbox)
                }
                return
            }

            self.handleCapturedContentForSave(content, targetSlot: slot)
        }
    }

    // MARK: - Save (lightweight, synchronous)

    func saveToSlot(_ slot: Int) {
        guard !isBatchSaving else {
            showToast("正在批量保存，请稍候")
            return
        }
        cancelPendingClipboardRestore()

        let content = clipboard.capture()
        guard !content.isEmpty else {
            NSLog("[ClipSlots] SAVE ignored: clipboard empty slot=\(slot)")
            return
        }

        // Check for overwrite confirmation
        let existing = contentForSlot(slot)
        if !existing.isEmpty && !UserDefaults.standard.skipOverwriteConfirmation {
            let alert = NSAlert()
            alert.messageText = "覆盖槽位 \(slot)？"
            alert.informativeText = "槽位 \(slot) 已有内容，继续保存会替换原内容。"
            alert.addButton(withTitle: "覆盖")
            alert.addButton(withTitle: "取消")

            let checkbox = NSButton(checkboxWithTitle: "以后覆盖时不再提醒", target: nil, action: nil)
            alert.accessoryView = checkbox

            // MT-3 (v2.10.30): 与 captureSelectionAndSaveToSlot 的覆盖确认同构——把阻塞的 runModal 改成非阻塞
            // sheet；确认后的保存移到完成闭包（并 return 跳过下方无条件保存）；无宿主窗口时回退 runModal()。
            let onConfirm: (NSButton) -> Void = { [weak self] checkbox in
                guard let self = self else { return }
                if checkbox.state == .on {
                    UserDefaults.standard.set(true, forKey: UserPreferenceKeys.skipOverwriteConfirmation)
                }
                self.handleCapturedContentForSave(content, targetSlot: slot)
            }

            guard let window = sheetHostWindow() else {
                let response = alert.runModal()
                guard response == .alertFirstButtonReturn else {
                    NSLog("[ClipSlots] SAVE cancelled by user slot=\(slot)")
                    return
                }
                onConfirm(checkbox)
                return
            }
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else {
                    NSLog("[ClipSlots] SAVE cancelled by user slot=\(slot)")
                    return
                }
                onConfirm(checkbox)
            }
            return
        }

        handleCapturedContentForSave(content, targetSlot: slot)
    }

    // MARK: - Copy (lightweight)

    func copySlot(_ slot: Int) {
        cancelPendingClipboardRestore()

        let content = contentForSlot(slot)
        // v2.9.3: copySlot only ever restores the slot BODY (items) to the pasteboard
        // via clipboard.restore, which itself guards on items.isEmpty. Guard on
        // items.isEmpty here (not the unified content.isEmpty) so an attachment-only
        // slot is not falsely reported as "已复制" while restore() actually clears the
        // clipboard. This preserves the exact pre-v2.9.3 body-copy behavior.
        guard !content.items.isEmpty else {
            NSLog("[ClipSlots] COPY ignored: slot \(slot) empty")
            if UserDefaults.standard.showCopyToast {
                showToast("槽位 \(slot) 为空")
            }
            return
        }

        _ = clipboard.restore(content)
        NSLog("[ClipSlots] COPY slot=\(slot) preview=\(content.preview)")

        if UserDefaults.standard.showCopyToast {
            let summary = content.noticeSummary
            showFloatingNotice(FloatingNotice(
                title: "已复制槽位 \(slot)",
                subtitle: "\(summary.typeTitle) · \(summary.detail)",
                iconName: summary.iconName,
                kind: .info
            ))
        }
    }

    // MARK: - Simple Paste (hotkeys, menu)

    func pasteSlot(_ slot: Int, suppressAutoAdvance: Bool = false, onCommitted: ((_ committedSlot: Int) -> Void)? = nil) {
        let activeId = activeHotkeySpecialSlotId

        NSLog("[ClipSlots] pasteSlot instanceID=\(instanceID) slot=\(slot) activeSpecialSlotId=\(activeId) loadedSpecialSlotId=\(loadedSpecialSlotId ?? "nil")")

        // v2.7.0: Chain paste check (hotkey path)
        if isSlotConnectionEnabled {
            let chain = currentConnectionMap.chainSlots(startingAt: slot)
            if chain.count > 1 {
                NSLog("[ClipSlots] pasteSlot chain detected, chain=\(chain)")
                // P1-1 (v2.10.6): 旧实现在这里就同步调用 onCommitted?()（早于异步链粘贴），且只把
                // 游标推进到链首，导致链内后续成员下次触发被重复粘贴。现在把回调下沉到 pasteSlotChain
                // 的链尾（Cmd+V 真正发出后），并回传链内最大 slot，使游标一次性跳过整条链的全部成员。
                // P1-2 (v2.10.7): 仅当链为连续递增区间时才把读游标一次性推进到 chain.max()。
                // 非连续链（如 [1,5]）推进到 max 会让中间空档槽被 AutoPasteManager 永久跳过；
                // 此时改为按链首推进，下次自动粘贴从链首的下一个非空槽继续，保证空档不被跳过。
                let sortedChain = chain.sorted()
                let isContiguous = (sortedChain.count > 1)
                    && (sortedChain.last! - sortedChain.first! == sortedChain.count - 1)
                let advanceSlot = isContiguous ? (sortedChain.last ?? slot) : (chain.first ?? slot)
                // CS-2 (v2.10.30): 非连续链在自动粘贴（suppressAutoAdvance）路径下，读游标推进到
                // chain.first 后，链内其余成员会在后续扫描中被再次选中导致重复粘贴。此处在 Cmd+V 真正
                // 提交后的完成闭包内（与 onCommitted 同为主线程）记录本链全部成员为「本轮已粘贴」，之后
                // 自动粘贴扫描经 isNonEmpty 探针把它们视为空跳过；一轮结束（读游标重置）时清空。连续链
                // 因游标已推进到 chain.max 天然跳过全部成员，无需记录。
                let chainGroupId = activeId
                let chainMembers = chain
                pasteSlotChain(chain) { [weak self] in
                    if suppressAutoAdvance && !isContiguous {
                        self?.pastedChainMembersByGroup[chainGroupId, default: []].formUnion(chainMembers)
                    }
                    onCommitted?(advanceSlot)
                }
                return
            }
        }
        
        // v2.8.0 (P0-1/P1-2): Slot attachments auto-chain. If the slot has
        // attachments, paste main content + all attachments in order through the
        // shared central executor, which batches multiple images, restores the
        // original clipboard afterwards, guards against group / app switches, and
        // cleans up any spilled temp image files.
        let content = specialStorage.get(slot, in: activeId)
        if !content.attachments.isEmpty {
            // v2.10.37: 断链本地文件附件（源文件已移动/删除）检测。这些附件在 payload 解析阶段
            // 会被跳过（见 payloadForAttachment / fileURLForFileLikeAttachment 的 fileExists 校验），
            // 这里统计数量以便给出明确提示，杜绝「静默失败」。
            let brokenCount = content.attachments.filter { $0.isBrokenLocalFileRef }.count
            var tempFiles: [URL] = []
            let payloads = slotContentPayloads(slot: slot, activeId: activeId, tempFiles: &tempFiles)
            // 主体为空且全部附件均断链 → 没有任何可粘贴内容，明确报错并终止，不再走空粘贴。
            guard !payloads.isEmpty else {
                cleanupTempFiles(tempFiles)
                showFloatingNotice(FloatingNotice(
                    title: "无法粘贴",
                    subtitle: brokenCount > 0 ? "原始文件已移动或不存在，无法粘贴" : "该槽位没有可粘贴的内容",
                    iconName: "exclamationmark.triangle.fill",
                    kind: brokenCount > 0 ? .error : .info
                ))
                // v2.10.37: 即便无可粘贴内容，也要推进自动粘贴游标，否则游标会永久卡在该断链
                // 槽位（onCommitted 不触发 → 自动粘贴 livelock 卡死）。跳过该槽位继续向后推进。
                onCommitted?(slot)
                return
            }
            let pastedAttachCount = content.attachments.count - brokenCount
            runSequentialPaste(payloads, activeId: activeId, targetApp: nil, tempFiles: tempFiles) { [weak self] in
                self?.recordLastPaste(slot: slot, in: activeId) // v2.9.38: record only after the paste actually succeeds
                if brokenCount > 0 {
                    // 部分附件断链：明确告知已跳过的数量，而非假装全部成功。
                    self?.showFloatingNotice(FloatingNotice(
                        title: "已粘贴主内容 + \(pastedAttachCount) 个附件",
                        subtitle: "\(brokenCount) 个附件的原始文件已移动或不存在，已跳过",
                        iconName: "exclamationmark.triangle.fill",
                        kind: .warning
                    ))
                } else {
                    self?.showFloatingNotice(FloatingNotice(
                        title: "已粘贴主内容 + \(pastedAttachCount) 个附件",
                        subtitle: "主内容与附件已依次粘贴",
                        iconName: "paperclip.circle.fill",
                        kind: .success
                    ))
                }
                self?.completeAutoAdvanceAfterAttachments(afterPasting: slot, in: activeId, suppress: suppressAutoAdvance) // v2.9.37: attachments done → safe to advance
                // P2-4 (v2.10.5): 附件路径确认粘贴完成后再回调，供自动粘贴推进游标。
                onCommitted?(slot)
            }
            return
        }

        guard !content.isEmpty else {
            NSLog("[ClipSlots] pasteSlot ignored: specialSlot=\(activeId) slot=\(slot) empty")
            return
        }

        guard AXIsProcessTrusted() else {
            NSLog("[ClipSlots] Accessibility permission not granted.")
            promptAccessibilityPermissionIfNeeded()
            return
        }

        cancelPendingPasteOperations(restoreClipboard: true)

        let previous = clipboard.capture()
        guard clipboard.restore(content) else {
            NSLog("[ClipSlots] pasteSlot restore failed specialSlot=\(activeId) slot=\(slot)")
            return
        }

        let pasteWorkItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            // If user switched special slot before Cmd+V fires, abort this stale paste.
            guard self.currentSpecialSlotId == activeId else {
                NSLog("[ClipSlots] pasteSlot abort stale paste requestedSpecialSlot=\(activeId) current=\(self.currentSpecialSlotId) slot=\(slot)")
                _ = self.clipboard.restore(previous)
                self.pendingPasteWorkItem = nil
                return
            }

            self.sendPasteKeystroke()

            // P2-1 (v2.10.6): recordLastPaste 从「调度前无条件调用」移到这里——只有 stale 守卫
            // 通过、确认要发 Cmd+V 之后才记录一次粘贴，避免因中止路径记录到从未真正发生的粘贴
            // （与附件路径在完成回调里记录的时机保持一致）。
            self.recordLastPaste(slot: slot, in: activeId)

            // P2-4 (v2.10.5): 文本路径确认发送 Cmd+V 之后再回调，供自动粘贴推进读游标。
            // 若上面的 stale 守卫已中止，则不会走到这里，游标不会被错误推进。
            onCommitted?(slot)

            // v2.9.56 fix: auto-advance MUST fire only after the paste keystroke has
            // been sent. Previously maybeAutoAdvance was called synchronously right
            // after scheduling this work item, so for the last non-empty slot it
            // switched groups (changing currentSpecialSlotId) BEFORE this deferred
            // work item ran — tripping the `currentSpecialSlotId == activeId` guard
            // above and aborting the paste as "stale". Text-only slots therefore
            // jumped without ever pasting; attachment slots were unaffected because
            // they advance from the sequential-paste completion callback instead.
            self.maybeAutoAdvance(afterPasting: slot, in: activeId, suppress: suppressAutoAdvance) // v2.9.31 (moved post-keystroke in v2.9.56)

            // v2.10.3 fix: capture the pasteboard changeCount after our own write.
            // If the user copies new content during the 0.8s restore window, the
            // changeCount will differ — skip the restore so we don't clobber the
            // user's freshly copied data (previously surfaced as "复制失效").
            let expectedChangeCount = self.clipboard.changeCount
            let restoreWorkItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                defer {
                    self.pendingClipboardRestore = nil
                    self.pendingClipboardRestoreContent = nil
                }
                if self.clipboard.changeCount != expectedChangeCount {
                    NSLog("[ClipSlots] pasteSlot skip clipboard restore: user changed clipboard (expected=\(expectedChangeCount) current=\(self.clipboard.changeCount))")
                    return
                }
                _ = self.clipboard.restore(previous)
            }
            self.pendingClipboardRestoreContent = previous
            self.pendingClipboardRestore = restoreWorkItem
            self.pendingPasteWorkItem = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)
        }

        self.pendingPasteWorkItem = pasteWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: pasteWorkItem)

        NSLog("[ClipSlots] pasteSlot scheduled specialSlot=\(activeId) slot=\(slot) preview=\(content.preview)")
    }

    // MARK: - Radial Paste (targetApp activation + waitUntilFrontmost)

    func pasteSlotToApp(_ slot: Int, targetApp: NSRunningApplication?) {
        let activeId = currentSpecialSlotId

        // v2.7.0: Chain paste check (radial menu / UI path)
        if isSlotConnectionEnabled {
            let chain = currentConnectionMap.chainSlots(startingAt: slot)
            if chain.count > 1 {
                NSLog("[ClipSlots] pasteSlotToApp chain detected, chain=\(chain)")
                pasteSlotChainToApp(chain, targetApp: targetApp)
                return
            }
        }

        // Always read from the currently active special slot on disk.
        let content = specialStorage.get(slot, in: activeId)

        // v2.8.0 (P1-2): radial / UI single-slot paste now carries attachments too,
        // via the same central executor used by the hotkey path.
        if !content.attachments.isEmpty {
            var tempFiles: [URL] = []
            let payloads = slotContentPayloads(slot: slot, activeId: activeId, tempFiles: &tempFiles)
            let attachCount = content.attachments.count
            runSequentialPaste(payloads, activeId: activeId, targetApp: targetApp, tempFiles: tempFiles) { [weak self] in
                self?.recordLastPaste(slot: slot, in: activeId) // v2.9.38: record only after the paste actually succeeds
                self?.showFloatingNotice(FloatingNotice(
                    title: "已粘贴主内容 + \(attachCount) 个附件",
                    subtitle: "主内容与附件已依次粘贴",
                    iconName: "paperclip.circle.fill",
                    kind: .success
                ))
                self?.completeAutoAdvanceAfterAttachments(afterPasting: slot, in: activeId) // v2.9.37: attachments done → safe to advance
            }
            return
        }

        guard !content.isEmpty else {
            NSLog("[ClipSlots] radial paste ignored: specialSlot=\(activeId) slot \(slot) empty")
            return
        }

        recordLastPaste(slot: slot, in: activeId) // v2.9.36

        guard AXIsProcessTrusted() else {
            NSLog("[ClipSlots] Accessibility permission not granted.")
            promptAccessibilityPermissionIfNeeded()
            return
        }

        cancelPendingClipboardRestore()

        let cleanTarget: NSRunningApplication?
        if isSelfApp(targetApp) {
            cleanTarget = lastNonClipSlotsApp
        } else {
            cleanTarget = targetApp ?? lastNonClipSlotsApp
        }

        NSLog("[ClipSlots] PASTE radial specialSlot=\(activeId) slot=\(slot) preview=\(content.preview) targetApp=\(cleanTarget?.localizedName ?? "nil")")

        let previous = clipboard.capture()

        let performPaste = { [weak self] in
            guard let self = self else { return }

            // Abort if special slot changed while waiting for app activation.
            guard self.currentSpecialSlotId == activeId else {
                NSLog("[ClipSlots] radial paste abort stale paste requestedSpecialSlot=\(activeId) current=\(self.currentSpecialSlotId) slot=\(slot)")
                _ = self.clipboard.restore(previous)
                return
            }

            guard self.clipboard.restore(content) else {
                NSLog("[ClipSlots] radial paste restore failed specialSlot=\(activeId) slot=\(slot)")
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self = self else { return }

                guard self.currentSpecialSlotId == activeId else {
                    NSLog("[ClipSlots] radial paste abort stale keystroke requestedSpecialSlot=\(activeId) current=\(self.currentSpecialSlotId) slot=\(slot)")
                    _ = self.clipboard.restore(previous)
                    return
                }

                self.sendPasteKeystroke()

                self.maybeAutoAdvance(afterPasting: slot, in: activeId) // v2.9.31

                let restoreWorkItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    _ = self.clipboard.restore(previous)
                    self.pendingClipboardRestore = nil
                    self.pendingClipboardRestoreContent = nil
                }
                self.pendingClipboardRestoreContent = previous
                self.pendingClipboardRestore = restoreWorkItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)
            }
        }

        if let app = cleanTarget {
            app.activate(options: [.activateIgnoringOtherApps])
            waitUntilFrontmost(app, timeout: 1.2) { success in
                NSLog("[ClipSlots] radial waitUntilFrontmost success=\(success)")
                performPaste()
            }
        } else {
            performPaste()
        }
    }

    /// UI paste button fallback
    func pasteSlotFromUI(_ slot: Int) {
        guard let target = lastNonClipSlotsApp else {
            NSLog("[ClipSlots] UI paste has no target app, fallback to copy slot \(slot)")
            copySlot(slot)
            return
        }
        pasteSlotToApp(slot, targetApp: target)
    }

    // MARK: - v2.7.0 Connection Map

    func loadConnectionMapForCurrentGroup() {
        guard let pageId = currentPage?.id ?? Optional(currentPageId),
              !pageId.isEmpty else {
            currentConnectionMap = .empty
            return
        }
        let groupId = currentSpecialSlotId
        currentConnectionMap = SlotConnectionStorage.shared.load(pageId: pageId, groupId: groupId)
        NSLog("[ClipSlots] loadConnectionMap edges=\(currentConnectionMap.edges.count) pageId=\(pageId) groupId=\(groupId)")
    }

    func saveConnectionMapForCurrentGroup() {
        guard let pageId = currentPage?.id ?? Optional(currentPageId),
              !pageId.isEmpty else { return }
        SlotConnectionStorage.shared.save(currentConnectionMap, pageId: pageId, groupId: currentSpecialSlotId)
    }

    // MARK: - v2.7.0 Connect / Disconnect

    func connectSlots(fromSlot: Int, fromPort: SlotPort, toSlot: Int, toPort: SlotPort) {
        do {
            var map = currentConnectionMap
            try map.connect(fromSlot: fromSlot, fromPort: fromPort, toSlot: toSlot, toPort: toPort)
            currentConnectionMap = map
            saveConnectionMapForCurrentGroup()

            let chain = map.fullChain(containing: fromSlot)
            showFloatingNotice(FloatingNotice(
                title: "已连接槽位 \(fromSlot) → \(toSlot)",
                subtitle: "当前链路：\(compactChainDescription(chain))",
                iconName: "link.circle.fill",
                kind: .success
            ))
        } catch let error as SlotConnectionError {
            showFloatingNotice(FloatingNotice(
                title: error.noticeTitle,
                subtitle: error.localizedDescription,
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
        } catch {
            showFloatingNotice(FloatingNotice(
                title: "连接失败",
                subtitle: error.localizedDescription,
                iconName: "xmark.circle.fill",
                kind: .error
            ))
        }
    }

    func disconnectConnectionInvolving(slot: Int, port: SlotPort) {
        var map = currentConnectionMap
        map.disconnectInvolving(slot: slot, port: port)
        currentConnectionMap = map
        saveConnectionMapForCurrentGroup()

        showFloatingNotice(FloatingNotice(
            title: "已断开连接",
            subtitle: "槽位内容未受影响",
            iconName: "link.badge.minus",
            kind: .info
        ))
    }

    // v2.9.20: 按连线 id 断开单条连线（节点画布连线中点 hover 删除入口调用）。
    func disconnectEdge(id: UUID) {
        var map = currentConnectionMap
        map.disconnect(edgeId: id)
        currentConnectionMap = map
        saveConnectionMapForCurrentGroup()

        showFloatingNotice(FloatingNotice(
            title: "已断开连接",
            subtitle: "槽位内容未受影响",
            iconName: "link.badge.minus",
            kind: .info
        ))
    }

    func confirmAndClearCurrentConnections() {
        guard !currentConnectionMap.edges.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "没有可清除的连接",
                subtitle: "当前槽位组没有连接",
                iconName: "info.circle.fill",
                kind: .info
            ))
            return
        }

        let alert = NSAlert()
        alert.messageText = "清除当前槽位组所有连接？"
        alert.informativeText = "这只会清除连接关系，不会删除槽位内容。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清除连接")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        currentConnectionMap = .empty
        saveConnectionMapForCurrentGroup()

        showFloatingNotice(FloatingNotice(
            title: "已清除连接",
            subtitle: "槽位内容未受影响",
            iconName: "trash.fill",
            kind: .success
        ))
    }

    func toggleConnectionMode() {
        isConnectionModeEnabled.toggle()
        if !isConnectionModeEnabled {
            activeDragConnection = nil
            hoveredPortTarget = nil
        }
    }

    // MARK: - v2.7.0 Port Helpers

    func portColor(for slot: Int) -> Color? {
        guard let colorId = currentConnectionMap.colorId(for: slot) else { return nil }
        return SlotConnectionColor.color(for: colorId)
    }

    func connectedPorts(for slot: Int) -> Set<SlotPort> {
        var result = Set<SlotPort>()
        if let outgoing = currentConnectionMap.edgeFrom(slot: slot) {
            result.insert(outgoing.fromPort)
        }
        if let incoming = currentConnectionMap.edgeTo(slot: slot) {
            result.insert(incoming.toPort)
        }
        return result
    }

    func shouldShowPorts(for slot: Int) -> Bool {
        guard isSlotConnectionEnabled else { return false }
        return isConnectionModeEnabled
            || hoveredSlot == slot
            || activeDragConnection?.fromSlot == slot
            || activeDragConnection?.hoverTarget?.slot == slot
            || currentConnectionMap.colorId(for: slot) != nil
    }

    // MARK: - v2.7.0 Drag Connection

    func beginConnectionDrag(fromSlot: Int, fromPort: SlotPort, startPoint: CGPoint) {
        activeDragConnection = ActiveDragConnection(
            fromSlot: fromSlot,
            fromPort: fromPort,
            currentPoint: startPoint,
            hoverTarget: nil
        )
    }

    func updateConnectionDrag(currentPoint: CGPoint, hoverTarget: SlotPortTarget?) {
        guard var active = activeDragConnection else { return }
        active.currentPoint = currentPoint
        active.hoverTarget = hoverTarget
        activeDragConnection = active
        hoveredPortTarget = hoverTarget
    }

    func endConnectionDrag(target: SlotPortTarget?) {
        guard let active = activeDragConnection else { return }
        defer {
            activeDragConnection = nil
            hoveredPortTarget = nil
        }

        guard let target = target else {
            showFloatingNotice(FloatingNotice(
                title: "连接已取消",
                subtitle: "未选择目标槽位",
                iconName: "xmark.circle.fill",
                kind: .info
            ))
            return
        }

        connectSlots(
            fromSlot: active.fromSlot,
            fromPort: active.fromPort,
            toSlot: target.slot,
            toPort: target.port
        )
    }

    // MARK: - v2.7.0 Chain Paste

    func pasteSlotConsideringConnections(_ slot: Int) {
        guard isSlotConnectionEnabled else {
            pasteSlot(slot)
            return
        }

        let chain = currentConnectionMap.chainSlots(startingAt: slot)
        guard chain.count > 1 else {
            pasteSlot(slot)
            return
        }

        pasteSlotChain(chain)
    }

    // MARK: - v2.7.80 Chain paste with per-slot attachments

    /// True if any slot in the chain carries attachments (read from `activeId`).
    private func chainHasAttachments(_ chain: [Int], activeId: String) -> Bool {
        chain.contains { !specialStorage.get($0, in: activeId).attachments.isEmpty }
    }

    /// v2.8.0: Materialises `content → attachments` payloads for a SINGLE slot,
    /// read from the given group (`activeId`). Multiple image attachments are
    /// coalesced into ONE Finder-style multi-file URL payload (即梦AI batch), while
    /// a single image keeps its inline-bitmap payload (WeChat / rich-text). Any temp
    /// files spilled to disk for in-memory images are appended to `tempFiles` so the
    /// caller can clean them up after the paste (P1-4).
    private func slotContentPayloads(slot: Int, activeId: String, tempFiles: inout [URL]) -> [ChainPastePayload] {
        var result: [ChainPastePayload] = []

        // 1) Main content of the slot.
        let contentPayload = mainContentPayload(slot: slot, activeId: activeId)
        if !contentPayload.isEmpty { result.append(contentPayload) }

        // 2) Attachments belonging to THIS slot only.
        let attachments = specialStorage.get(slot, in: activeId).attachments
        guard !attachments.isEmpty else { return result }

        // v2.8.2: ALL file-like attachments (images + .file videos/documents/…) are
        // now unified. Indices are file-like when they can be resolved to a file URL
        // (image with path/data, or .file with a path); everything else (.text /
        // .url / .reference) is a non-file attachment pasted individually in order.
        let fileLikeIndices = attachments.indices.filter { idx in
            let att = attachments[idx]
            switch att.type {
            case .file:
                return (att.path?.isEmpty == false)
            case .image:
                return (att.path?.isEmpty == false) || (att.data?.isEmpty == false)
            default:
                return false
            }
        }

        // 2a) Non-file attachments (.text / .url / .reference) in original order.
        for i in attachments.indices where !fileLikeIndices.contains(i) {
            let p = payloadForAttachment(attachments[i], activeId: activeId)
            if !p.isEmpty { result.append(p) }
        }

        // 2b) File-like attachments:
        //   • exactly one → keep the original single-item payload (inline bitmap for
        //     a lone image → WeChat / rich-text compatibility; a single file URL for
        //     a lone .file), preserving prior proven behaviour.
        //   • two or more → coalesce into ONE Finder-style multi-file URL payload
        //     (single Cmd+V), preserving the original attachment order. Only images
        //     spilled from in-memory data are added to `tempFiles` for cleanup; the
        //     user's original files are never touched.
        if fileLikeIndices.count == 1 {
            let p = payloadForAttachment(attachments[fileLikeIndices[0]], activeId: activeId)
            if !p.isEmpty { result.append(p) }
        } else if fileLikeIndices.count >= 2 {
            let urls = fileLikeIndices.compactMap { fileURLForFileLikeAttachment(attachments[$0], tempFiles: &tempFiles) }
            if !urls.isEmpty {
                result.append(ChainPastePayload(
                    sourceSlot: slot,
                    text: nil,
                    fileURLs: urls,
                    isImage: false,
                    isEmpty: false,
                    image: nil
                ))
            }
        }
        return result
    }

    /// v2.8.0: Expands a connection chain into an ordered payload list
    /// (content → attachments → next slot's content → …) read from `activeId`.
    private func expandedChainPayloads(for chain: [Int], activeId: String, tempFiles: inout [URL]) -> [ChainPastePayload] {
        var result: [ChainPastePayload] = []
        for slot in chain {
            result.append(contentsOf: slotContentPayloads(slot: slot, activeId: activeId, tempFiles: &tempFiles))
        }
        return result
    }

    func pasteSlotChain(_ slots: [Int], onChainCommitted: (() -> Void)? = nil) {
        let activeId = activeHotkeySpecialSlotId

        // v2.8.0: if any slot in the chain has attachments, expand each slot into
        // content → attachments and paste sequentially through the central executor
        // (unified clipboard restore + abort guard + temp cleanup). Attachment-free
        // chains keep the original fast merged behavior below.
        if chainHasAttachments(slots, activeId: activeId) {
            var tempFiles: [URL] = []
            let payloads = expandedChainPayloads(for: slots, activeId: activeId, tempFiles: &tempFiles)
            // v2.10.37: 链路展开后若全部为空（例如成员全是断链本地文件附件），runSequentialPaste 会
            // 早退且不回调 onSuccess → onChainCommitted 不触发，自动粘贴游标永久卡在此链（livelock）。
            // 这里提前拦截：清理临时文件、给出提示，并仍回调 onChainCommitted 推进游标越过该链。
            guard payloads.contains(where: { !$0.isEmpty }) else {
                cleanupTempFiles(tempFiles)
                showFloatingNotice(FloatingNotice(
                    title: "串联粘贴失败",
                    subtitle: "链路内容均已断链或为空",
                    iconName: "exclamationmark.triangle.fill",
                    kind: .warning
                ))
                onChainCommitted?()
                return
            }
            let attachmentTotal = slots.reduce(0) { $0 + specialStorage.get($1, in: activeId).attachments.count }
            let chainForNotice = slots
            let count = payloads.count
            runSequentialPaste(payloads, activeId: activeId, targetApp: nil, tempFiles: tempFiles) { [weak self] in
                self?.showFloatingNotice(FloatingNotice(
                    title: "已串联粘贴 \(count) 段内容",
                    subtitle: "含 \(attachmentTotal) 个附件 · \(compactChainDescription(chainForNotice))",
                    iconName: "link.circle.fill",
                    kind: .success
                ))
                // P1-3 (v2.10.7): 附件链粘贴完成后也记录「上次粘贴」为链首，与单槽/文本链口径一致。
                self?.recordLastPaste(slot: slots.first ?? 0, in: activeId)
                // P1-1 (v2.10.6): 整条链粘贴完成后再回调，供自动粘贴把游标推进到链尾。
                onChainCommitted?()
            }
            return
        }

        let payloads = slots.map { payloadForSlot($0) }
        let nonEmptyPayloads = payloads.filter { !$0.isEmpty }
        let skippedEmptyCount = payloads.count - nonEmptyPayloads.count

        guard !nonEmptyPayloads.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "串联粘贴失败",
                subtitle: "链路中没有可粘贴内容",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
            return
        }

        guard AXIsProcessTrusted() else {
            promptAccessibilityPermissionIfNeeded()
            return
        }

        let kind = chainPasteKind(for: nonEmptyPayloads)

        switch kind {
        case .text:
            let merged = nonEmptyPayloads.compactMap(\.text).joined(separator: "\n\n")
            guard !merged.isEmpty else {
                showFloatingNotice(FloatingNotice(
                    title: "串联粘贴失败",
                    subtitle: "没有可粘贴文本",
                    iconName: "exclamationmark.triangle.fill",
                    kind: .warning
                ))
                return
            }

            cancelPendingPasteOperations(restoreClipboard: true)
            let previous = clipboard.capture()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(merged, forType: .string)

            let pasteWorkItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard self.currentSpecialSlotId == activeId else {
                    _ = self.clipboard.restore(previous)
                    return
                }
                self.sendPasteKeystroke()
                onChainCommitted?() // P1-1 (v2.10.6): 合并文本链的 Cmd+V 已发出，回调推进游标。
                // P1-3 (v2.10.7): 链式粘贴也要记录「上次粘贴」，取链首槽位，与单槽路径口径一致。
                self.recordLastPaste(slot: slots.first ?? 0, in: activeId)
                // P1-1 (v2.10.7): 捕获自身写入后的 changeCount，还原前比对，避免覆盖用户 0.8s 内新复制内容。
                let expectedChangeCount = self.clipboard.changeCount
                let restoreWorkItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    // 用 defer 保证跳过还原时也清理 pending 引用，
                    // 否则下次 cancelPendingClipboardRestore 会用旧内容覆盖用户新复制。
                    defer {
                        self.pendingClipboardRestore = nil
                        self.pendingClipboardRestoreContent = nil
                    }
                    if self.clipboard.changeCount != expectedChangeCount {
                        NSLog("[ClipSlots] skip clipboard restore: user changed clipboard (expected=\(expectedChangeCount) current=\(self.clipboard.changeCount))")
                        return
                    }
                    _ = self.clipboard.restore(previous)
                }
                self.pendingClipboardRestoreContent = previous
                self.pendingClipboardRestore = restoreWorkItem
                self.pendingPasteWorkItem = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)
            }
            self.pendingPasteWorkItem = pasteWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: pasteWorkItem)

            showChainPasteSuccess(slots: slots, pastedCount: nonEmptyPayloads.count, skippedEmptyCount: skippedEmptyCount)

        case .files:
            let urls = nonEmptyPayloads.flatMap(\.fileURLs)
            guard !urls.isEmpty else {
                showFloatingNotice(FloatingNotice(
                    title: "串联粘贴失败",
                    subtitle: "没有可粘贴文件",
                    iconName: "exclamationmark.triangle.fill",
                    kind: .warning
                ))
                return
            }

            cancelPendingPasteOperations(restoreClipboard: true)
            let previous = clipboard.capture()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])

            let pasteWorkItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard self.currentSpecialSlotId == activeId else {
                    _ = self.clipboard.restore(previous)
                    return
                }
                self.sendPasteKeystroke()
                onChainCommitted?() // P1-1 (v2.10.6): 文件链的 Cmd+V 已发出，回调推进游标。
                // P1-3 (v2.10.7): 链式粘贴也要记录「上次粘贴」，取链首槽位，与单槽路径口径一致。
                self.recordLastPaste(slot: slots.first ?? 0, in: activeId)
                // P1-1 (v2.10.7): 捕获自身写入后的 changeCount，还原前比对，避免覆盖用户 0.8s 内新复制内容。
                let expectedChangeCount = self.clipboard.changeCount
                let restoreWorkItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    // 用 defer 保证跳过还原时也清理 pending 引用，
                    // 否则下次 cancelPendingClipboardRestore 会用旧内容覆盖用户新复制。
                    defer {
                        self.pendingClipboardRestore = nil
                        self.pendingClipboardRestoreContent = nil
                    }
                    if self.clipboard.changeCount != expectedChangeCount {
                        NSLog("[ClipSlots] skip clipboard restore: user changed clipboard (expected=\(expectedChangeCount) current=\(self.clipboard.changeCount))")
                        return
                    }
                    _ = self.clipboard.restore(previous)
                }
                self.pendingClipboardRestoreContent = previous
                self.pendingClipboardRestore = restoreWorkItem
                self.pendingPasteWorkItem = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)
            }
            self.pendingPasteWorkItem = pasteWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: pasteWorkItem)

            showFloatingNotice(FloatingNotice(
                title: "已串联粘贴 \(urls.count) 个文件",
                subtitle: compactChainDescription(slots),
                iconName: "link.circle.fill",
                kind: .success
            ))

        case .unsupported:
            // v2.7.4: Instead of rejecting mixed content chains, paste each item
            // sequentially in order (text → Cmd+V → image → Cmd+V → ...).
            pasteSlotChainSequentially(slots, activeId: activeId, onCommitted: onChainCommitted)

        case .empty:
            showFloatingNotice(FloatingNotice(
                title: "串联粘贴失败",
                subtitle: "链路中没有可粘贴内容",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
        }
    }

    func pasteSlotChainToApp(_ slots: [Int], targetApp: NSRunningApplication?) {
        let activeId = currentSpecialSlotId

        // v2.8.0: expand slots into content → attachments when any slot has
        // attachments, so the radial / UI chain paste no longer drops them, routed
        // through the central executor (clipboard restore + abort + temp cleanup).
        if chainHasAttachments(slots, activeId: activeId) {
            var tempFiles: [URL] = []
            let payloads = expandedChainPayloads(for: slots, activeId: activeId, tempFiles: &tempFiles)
            let attachmentTotal = slots.reduce(0) { $0 + specialStorage.get($1, in: activeId).attachments.count }
            let chainForNotice = slots
            let count = payloads.count
            runSequentialPaste(payloads, activeId: activeId, targetApp: targetApp, tempFiles: tempFiles) { [weak self] in
                self?.showFloatingNotice(FloatingNotice(
                    title: "已串联粘贴 \(count) 段内容",
                    subtitle: "含 \(attachmentTotal) 个附件 · \(compactChainDescription(chainForNotice))",
                    iconName: "link.circle.fill",
                    kind: .success
                ))
            }
            return
        }

        let payloads = slots.map { payloadForSlot($0) }
        let nonEmptyPayloads = payloads.filter { !$0.isEmpty }
        let skippedEmptyCount = payloads.count - nonEmptyPayloads.count

        guard !nonEmptyPayloads.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "串联粘贴失败",
                subtitle: "链路中没有可粘贴内容",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
            return
        }

        guard AXIsProcessTrusted() else {
            promptAccessibilityPermissionIfNeeded()
            return
        }

        let kind = chainPasteKind(for: nonEmptyPayloads)

        switch kind {
        case .text:
            let merged = nonEmptyPayloads.compactMap(\.text).joined(separator: "\n\n")
            guard !merged.isEmpty else {
                showFloatingNotice(FloatingNotice(
                    title: "串联粘贴失败",
                    subtitle: "没有可粘贴文本",
                    iconName: "exclamationmark.triangle.fill",
                    kind: .warning
                ))
                return
            }

            cancelPendingClipboardRestore()
            let cleanTarget: NSRunningApplication?
            if isSelfApp(targetApp) { cleanTarget = lastNonClipSlotsApp }
            else { cleanTarget = targetApp ?? lastNonClipSlotsApp }

            let previous = clipboard.capture()
            let performPaste = { [weak self] in
                guard let self = self else { return }
                guard self.currentSpecialSlotId == activeId else {
                    _ = self.clipboard.restore(previous); return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(merged, forType: .string)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    guard let self = self else { return }
                    guard self.currentSpecialSlotId == activeId else {
                        _ = self.clipboard.restore(previous); return
                    }
                    self.sendPasteKeystroke()
                    let restoreWorkItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        _ = self.clipboard.restore(previous)
                        self.pendingClipboardRestore = nil
                        self.pendingClipboardRestoreContent = nil
                    }
                    self.pendingClipboardRestoreContent = previous
                    self.pendingClipboardRestore = restoreWorkItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)
                }
            }
            if let app = cleanTarget {
                app.activate(options: [.activateIgnoringOtherApps])
                waitUntilFrontmost(app, timeout: 1.2) { _ in performPaste() }
            } else {
                performPaste()
            }
            showChainPasteSuccess(slots: slots, pastedCount: nonEmptyPayloads.count, skippedEmptyCount: skippedEmptyCount)

        case .files:
            let urls = nonEmptyPayloads.flatMap(\.fileURLs)
            guard !urls.isEmpty else {
                showFloatingNotice(FloatingNotice(
                    title: "串联粘贴失败",
                    subtitle: "没有可粘贴文件",
                    iconName: "exclamationmark.triangle.fill",
                    kind: .warning
                ))
                return
            }
            cancelPendingClipboardRestore()
            let cleanTarget: NSRunningApplication?
            if isSelfApp(targetApp) { cleanTarget = lastNonClipSlotsApp }
            else { cleanTarget = targetApp ?? lastNonClipSlotsApp }
            let previous = clipboard.capture()
            let performPaste = { [weak self] in
                guard let self = self else { return }
                guard self.currentSpecialSlotId == activeId else {
                    _ = self.clipboard.restore(previous); return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(urls as [NSURL])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    guard let self = self else { return }
                    guard self.currentSpecialSlotId == activeId else {
                        _ = self.clipboard.restore(previous); return
                    }
                    self.sendPasteKeystroke()
                    let restoreWorkItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        _ = self.clipboard.restore(previous)
                        self.pendingClipboardRestore = nil
                        self.pendingClipboardRestoreContent = nil
                    }
                    self.pendingClipboardRestoreContent = previous
                    self.pendingClipboardRestore = restoreWorkItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)
                }
            }
            if let app = cleanTarget {
                app.activate(options: [.activateIgnoringOtherApps])
                waitUntilFrontmost(app, timeout: 1.2) { _ in performPaste() }
            } else {
                performPaste()
            }
            showFloatingNotice(FloatingNotice(
                title: "已串联粘贴 \(urls.count) 个文件",
                subtitle: compactChainDescription(slots),
                iconName: "link.circle.fill",
                kind: .success
            ))

        case .unsupported:
            // P2-3 (v2.10.6): 与快捷键路径 pasteSlotChain 对齐——混合类型链不再直接报「暂不支持」，
            // 而是逐段依次粘贴（text → Cmd+V → image → Cmd+V → …），并把目标应用透传下去。
            let cleanTarget: NSRunningApplication?
            if isSelfApp(targetApp) { cleanTarget = lastNonClipSlotsApp }
            else { cleanTarget = targetApp ?? lastNonClipSlotsApp }
            pasteSlotChainSequentially(slots, activeId: activeId, targetApp: cleanTarget)
        case .empty:
            showFloatingNotice(FloatingNotice(
                title: "串联粘贴失败",
                subtitle: "链路中没有可粘贴内容",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
        }
    }

    private func payloadForSlot(_ slot: Int) -> ChainPastePayload {
        let content = slots[slot] ?? SlotContent()
        // v2.9.3: this builds the slot BODY payload only (attachments are appended
        // separately in slotContentPayloads). Guard on items.isEmpty (not the unified
        // content.isEmpty) so an attachment-only slot does not inject a spurious empty
        // body payload that would clear the clipboard and paste nothing.
        guard !content.items.isEmpty else {
            return ChainPastePayload(sourceSlot: slot, text: nil, fileURLs: [], isImage: false, isEmpty: true, image: nil)
        }
        return ChainPastePayload(
            sourceSlot: slot,
            text: content.plainText,
            fileURLs: content.detectedRegularFileURLs,
            isImage: content.hasImage || content.isImageFile,
            isEmpty: false,
            image: content.inlineImage
        )
    }

    /// v2.8.0 (P0-2): main-content payload read from a *specific* group on disk so
    /// every paste path resolves against the same authoritative data source rather
    /// than mixing the in-memory `slots` dictionary with the active hotkey group.
    private func mainContentPayload(slot: Int, activeId: String) -> ChainPastePayload {
        let content = specialStorage.get(slot, in: activeId)
        // v2.9.3: builds the slot BODY payload only (attachments handled separately in
        // slotContentPayloads). Guard on items.isEmpty (not the unified content.isEmpty)
        // so an attachment-only slot does not produce a non-empty-but-contentless payload
        // that would clear the clipboard and paste nothing during a chain/attachment paste.
        guard !content.items.isEmpty else {
            return ChainPastePayload(sourceSlot: slot, text: nil, fileURLs: [], isImage: false, isEmpty: true, image: nil)
        }
        return ChainPastePayload(
            sourceSlot: slot,
            text: content.plainText,
            fileURLs: content.detectedRegularFileURLs,
            isImage: content.hasImage || content.isImageFile,
            isEmpty: false,
            image: content.inlineImage
        )
    }

    /// v2.8.0 (P1-3): builds a paste payload for an *explicit* attachment value.
    /// This replaces the previous shared `pendingAttachmentContext` mutable state,
    /// so concurrent / nested materialisation can never contaminate each other.
    private func payloadForAttachment(_ att: SlotContent.SlotAttachment, activeId: String) -> ChainPastePayload {
        let empty = ChainPastePayload(sourceSlot: 0, text: nil, fileURLs: [], isImage: false, isEmpty: true, image: nil)
        switch att.type {
        case .text:
            let text = att.data.flatMap { String(data: $0, encoding: .utf8) } ?? att.name
            return ChainPastePayload(sourceSlot: 0, text: text, fileURLs: [], isImage: false, isEmpty: text.isEmpty, image: nil)
        case .url:
            let text = att.url ?? att.name
            return ChainPastePayload(sourceSlot: 0, text: text, fileURLs: [], isImage: false, isEmpty: text.isEmpty, image: nil)
        case .file:
            // v2.10.37: 粘贴前做源文件可达性校验。断链的本地文件引用（源文件已移动/删除）
            // 返回空 payload 而非 `URL(fileURLWithPath:)` 一个不存在的路径——后者会被写进剪贴板
            // 却在真正 Cmd+V 时静默失败。跳过后由调用方统计并给出明确提示。
            guard let path = att.path, !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else { return empty }
            return ChainPastePayload(sourceSlot: 0, text: nil, fileURLs: [URL(fileURLWithPath: path)], isImage: false, isEmpty: false, image: nil)
        case .image:
            if let data = att.data, let image = NSImage(data: data) {
                return ChainPastePayload(sourceSlot: 0, text: nil, fileURLs: [], isImage: true, isEmpty: false, image: image)
            }
            // v2.10.37: 无内联字节时才回退到源文件；同样校验文件存在，断链即跳过。
            if let path = att.path, !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                return ChainPastePayload(sourceSlot: 0, text: nil, fileURLs: [URL(fileURLWithPath: path)], isImage: false, isEmpty: false, image: nil)
            }
            return empty
        case .reference:
            // A reference stores the target slot number as a string in `path`.
            if let path = att.path, let refSlot = Int(path) {
                return mainContentPayload(slot: refSlot, activeId: activeId)
            }
            let text = att.url ?? att.name
            return ChainPastePayload(sourceSlot: 0, text: text, fileURLs: [], isImage: false, isEmpty: text.isEmpty, image: nil)
        }
    }

    private func chainPasteKind(for payloads: [ChainPastePayload]) -> ChainPasteKind {
        let hasText = payloads.contains { $0.text != nil && !($0.text?.isEmpty ?? true) }
        let hasFiles = payloads.contains { !$0.fileURLs.isEmpty }
        let hasImage = payloads.contains { $0.isImage }

        // Image in chain: unsupported for MVP
        if hasImage { return .unsupported }
        // Mixed text + files: unsupported
        if hasText && hasFiles { return .unsupported }
        if hasText { return .text }
        if hasFiles { return .files }
        return .empty
    }

    // v2.7.20: delete/ignore the v2.7.19 pasteAllSlotsInCurrentGroup() helper if it
    // exists locally. The radial "全部粘贴" now calls pasteAllSlotsWithConfirmation(),
    // the same proven path as the main toolbar button. This avoids accidentally using
    // node-connection chain paste and showing misleading "已串联粘贴" HUD.

    // MARK: - v2.7.21 Fast Radial Paste All
    // Radial menu paste-all should be faster than the safe mixed sequential path.
    func pasteAllSlotsFastFromRadialMenu() {
        let nonEmptySlots = (1...max(1, config.slots)).filter { slot in
            !(slots[slot] ?? SlotContent()).isEmpty
        }

        guard !nonEmptySlots.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "当前槽位组为空",
                subtitle: "没有可粘贴内容",
                iconName: "tray",
                kind: .warning
            ))
            return
        }

        let contents = nonEmptySlots.compactMap { slots[$0] }
        guard let target = lastNonClipSlotsApp else {
            showFloatingNotice(FloatingNotice(
                title: "没有可粘贴的目标应用",
                subtitle: "请先切换到目标应用",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
            return
        }

        // P1-4 (v2.10.34): 这里只是判断「这批槽位是否全是纯文本（无文件、无图片）」以决定走文本合并
        // 快路径。原判据 `$0.inlineImage == nil` 会为【每个】槽位触发 inlineImage 的整图解码
        // （NSImage 全分辨率解码，主线程同步），只为拿一个「是否为图」的布尔——一次「全部粘贴」若涉及
        // 多张大图，会在主线程叠加多次全分辨率解码，直接卡顿掉帧。改用 `hasImage`（`!imageTypes.isEmpty`，
        // 只看 item 类型、零解码）这一廉价谓词，语义等价而无解码开销。
        if contents.allSatisfy({ $0.primaryFileURL == nil && !$0.hasImage }) {
            let merged = contents.compactMap { $0.plainText }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(merged, forType: .string)
            target.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.sendPasteKeystroke()
            }
            showFloatingNotice(FloatingNotice(
                title: "已全部粘贴 \(contents.count) 段文本",
                subtitle: "当前槽位组",
                iconName: "square.stack.3d.up.fill",
                kind: .success
            ))
            return
        }

        let urls = contents.compactMap { $0.primaryFileURL }
        if urls.count == contents.count {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            target.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.sendPasteKeystroke()
            }
            showFloatingNotice(FloatingNotice(
                title: "已全部粘贴 \(urls.count) 个文件",
                subtitle: "当前槽位组",
                iconName: "square.stack.3d.up.fill",
                kind: .success
            ))
            return
        }

        // Mixed text + image/file: correctness first, but avoid node-connection HUD wording.
        pasteSlotChainSequentially(nonEmptySlots, noticeTitle: "已全部粘贴 \(contents.count) 段内容", noticeSubtitle: "当前槽位组", targetApp: target)
    }

    // MARK: - v2.7.4 Mixed Chain Sequential Paste

    func pasteSlotChainSequentially(_ slots: [Int], noticeTitle: String? = nil, noticeSubtitle: String? = nil, activeId: String? = nil, targetApp: NSRunningApplication? = nil, onCommitted: (() -> Void)? = nil) {
        let group = activeId ?? currentSpecialSlotId
        let payloads = slots.compactMap { slot -> ChainPastePayload? in
            let payload = payloadForSlot(slot)
            return payload.isEmpty ? nil : payload
        }
        let count = payloads.count
        runSequentialPaste(payloads, activeId: group, targetApp: targetApp, tempFiles: []) { [weak self] in
            guard let self else { return }
            self.showFloatingNotice(FloatingNotice(
                title: noticeTitle ?? "已串联粘贴 \(count) 段内容",
                subtitle: noticeSubtitle ?? compactChainDescription(slots),
                iconName: "link.circle.fill",
                kind: .success
            ))
            // P1-1 (v2.10.6): 混合内容链逐段粘贴完成后回调，供自动粘贴推进游标到链尾。
            onCommitted?()
        }
    }

    // MARK: - v2.8.0 Central sequential paste executor

    /// v2.8.0: The single entry point every attachment / chain / multi-image paste
    /// funnels through. It (1) captures the current clipboard ONCE, (2) optionally
    /// activates the target app, (3) pastes each materialised payload in order while
    /// guarding against special-slot-group switches AND frontmost-app changes, then
    /// (4) restores the original clipboard ~0.8s after the last paste, and finally
    /// (5) deletes any temp image files that were spilled to disk.
    ///
    /// `targetApp == nil` = paste into whatever app is currently frontmost (the
    /// global-hotkey path); a non-nil target is activated first (radial / UI path).
    private func runSequentialPaste(
        _ payloads: [ChainPastePayload],
        activeId: String,
        targetApp: NSRunningApplication?,
        tempFiles: [URL],
        onSuccess: @escaping () -> Void
    ) {
        let nonEmpty = payloads.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else {
            cleanupTempFiles(tempFiles)
            showFloatingNotice(FloatingNotice(
                title: "粘贴失败",
                subtitle: "没有可粘贴内容",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
            return
        }
        guard AXIsProcessTrusted() else {
            cleanupTempFiles(tempFiles)
            promptAccessibilityPermissionIfNeeded()
            return
        }

        // Cancel any in-flight paste/restore (restores its clipboard + cleans its
        // temp files + bumps the generation token) and snapshot the clipboard.
        cancelPendingPasteOperations(restoreClipboard: true)
        let previous = clipboard.capture()
        // v2.8.1 (P0-1): claim a fresh generation token for this run and publish the
        // in-flight bookkeeping so a later sequence / cancel can supersede us cleanly.
        // P2-8 (v2.10.7): cancelPendingPasteOperations 内部（abortInFlightSequence）已自增代际令牌，
        // 无需再手动 +1（否则每次开新序列 generation 跳变 2，仅影响日志可读性）。
        let gen = pasteSequenceGeneration
        inFlightSequencePrevious = previous
        inFlightSequenceTempFiles = tempFiles

        // Resolve the concrete target: nil means "current frontmost" (hotkey path).
        let cleanTarget: NSRunningApplication?
        if targetApp == nil {
            cleanTarget = nil
        } else if isSelfApp(targetApp) {
            cleanTarget = lastNonClipSlotsApp
        } else {
            cleanTarget = targetApp ?? lastNonClipSlotsApp
        }

        let onAbort: () -> Void = { [weak self] in
            guard let self else { return }
            _ = self.clipboard.restore(previous)
            self.cleanupTempFiles(tempFiles)
            if self.pasteSequenceGeneration == gen {
                self.inFlightSequencePrevious = nil
                self.inFlightSequenceTempFiles = []
            }
        }

        let onFinish: () -> Void = { [weak self] in
            guard let self else { return }
            onSuccess()
            // P1-1 (v2.10.7): 序列内部会多次写剪贴板，故在此（最后一次自身写入之后）捕获期望
            // changeCount；还原前比对，避免覆盖用户在 0.8s 窗口内新复制的内容。
            let expectedChangeCount = self.clipboard.changeCount
            let restoreWorkItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // 用 defer 保证跳过还原时也清理 pending/in-flight 引用，
                // 否则下次 cancelPendingClipboardRestore 会用旧内容覆盖用户新复制。
                defer {
                    self.pendingClipboardRestore = nil
                    self.pendingClipboardRestoreContent = nil
                    if self.pasteSequenceGeneration == gen { self.inFlightSequencePrevious = nil }
                }
                if self.clipboard.changeCount != expectedChangeCount {
                    NSLog("[ClipSlots] skip clipboard restore: user changed clipboard (expected=\(expectedChangeCount) current=\(self.clipboard.changeCount))")
                    return
                }
                _ = self.clipboard.restore(previous)
            }
            self.pendingClipboardRestoreContent = previous
            self.pendingClipboardRestore = restoreWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restoreWorkItem)

            // v2.8.1 (P1-4): defer temp-file cleanup well past the clipboard restore.
            // Targets that read spilled image files asynchronously (即梦 / Finder-style
            // drops) still need the files after the paste lands. changeCount polling is
            // unreliable here (our own restore bumps changeCount), so a conservative
            // fixed delay is the safest option.
            //
            // v2.8.2 (P1-A): the sequence has SUCCEEDED, so detach its temp files from
            // the in-flight bookkeeping immediately. Otherwise a superseding sequence
            // that starts within this 3s protection window would call
            // abortInFlightSequence and delete these files out from under the target
            // app while it is still reading them asynchronously. Cleanup of these
            // now-orphaned files is owned solely by the delayed work item below, which
            // captures the local `tempFiles` array and is never touched by abort.
            if self.pasteSequenceGeneration == gen {
                self.inFlightSequenceTempFiles = []
            }
            if !tempFiles.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self else { return }
                    self.cleanupTempFiles(tempFiles)
                }
            }
        }

        let run: () -> Void = { [weak self] in
            guard let self else { return }
            // Expected target = the app we activated, else whatever is frontmost now.
            let expectedPid = cleanTarget?.processIdentifier
                ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
            self.pasteNextPayloadSequentially(
                nonEmpty,
                index: 0,
                activeId: activeId,
                generation: gen,
                expectedPid: expectedPid,
                onAbort: onAbort,
                completion: onFinish
            )
        }

        if let app = cleanTarget {
            app.activate(options: [.activateIgnoringOtherApps])
            waitUntilFrontmost(app, timeout: 1.2) { [weak self] ok in
                guard let self else { return }
                // v2.8.1 (P1-3): if activation failed, abort safely instead of
                // firing keystrokes at the wrong app. Restore clipboard + clean up
                // and surface a warning so the user knows nothing was pasted.
                guard ok else {
                    onAbort()
                    self.showFloatingNotice(FloatingNotice(
                        title: "粘贴失败",
                        subtitle: "目标应用未能激活，请重试",
                        iconName: "exclamationmark.triangle.fill",
                        kind: .warning
                    ))
                    return
                }
                run()
            }
        } else {
            run()
        }
    }

    /// v2.8.0 (P1-4): removes temp image files spilled to disk for a paste.
    private func cleanupTempFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls { try? FileManager.default.removeItem(at: url) }
        NSLog("[ClipSlots] cleaned up \(urls.count) temp image file(s)")
    }

    /// Resolves a usable on-disk file URL for an image attachment. If the
    /// attachment references an existing file, that path is used; otherwise its
    /// in-memory bitmap `data` is spilled to a temp file with the correct
    /// extension. v2.8.0 (P1-4): any temp file created is appended to `tempFiles`
    /// so the caller can delete it once the paste has landed and the clipboard has
    /// been restored (files referencing an existing on-disk path are NOT tracked).
    /// v2.8.2: Resolves ANY file-like attachment (image OR .file) into a file URL
    /// suitable for a Finder-style multi-file paste.
    ///   • `.file` with an existing path → the user's ORIGINAL file (never appended
    ///     to `tempFiles`, so it is never deleted after paste).
    ///   • `.image` with an existing path → the original file (not a temp).
    ///   • `.image` with in-memory data only → spilled to a temp file that IS added
    ///     to `tempFiles` for post-paste cleanup.
    /// Returns nil for non-file-like attachments or unresolvable ones.
    private func fileURLForFileLikeAttachment(_ att: SlotContent.SlotAttachment, tempFiles: inout [URL]) -> URL? {
        switch att.type {
        case .file:
            // v2.10.37: 多附件合并粘贴同样先校验源文件存在，断链附件不加入 URL 列表。
            guard let path = att.path, !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        case .image:
            if let path = att.path, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            guard let data = att.data, !data.isEmpty else { return nil }
            return spillImageDataToTempFile(att, data: data, tempFiles: &tempFiles)
        default:
            return nil
        }
    }

    /// Writes in-memory image data to a temp file and records it in `tempFiles`.
    private func spillImageDataToTempFile(_ att: SlotContent.SlotAttachment, data: Data, tempFiles: inout [URL]) -> URL? {

        let ext = imageFileExtension(forName: att.name, data: data)
        let baseName = (att.name as NSString).deletingPathExtension
        let safeBase = baseName.isEmpty ? "clipslots-image" : baseName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let fileName = "clipslots-\(UUID().uuidString.prefix(8))-\(safeBase).\(ext)"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            tempFiles.append(url)
            return url
        } catch {
            NSLog("[ClipSlots] failed to spill image attachment to temp file: \(error)")
            return nil
        }
    }

    /// Determines an image file extension from the attachment name, falling back
    /// to sniffing the data's magic bytes, then to png.
    private func imageFileExtension(forName name: String, data: Data) -> String {
        let nameExt = (name as NSString).pathExtension.lowercased()
        let allowed: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "webp"]
        if allowed.contains(nameExt) { return nameExt == "jpeg" ? "jpg" : nameExt }

        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "png" }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "jpg" }
        if bytes.count >= 6, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "gif" }
        if bytes.count >= 2, bytes[0] == 0x42, bytes[1] == 0x4D { return "bmp" }
        if bytes.count >= 4, (bytes[0] == 0x49 && bytes[1] == 0x49) || (bytes[0] == 0x4D && bytes[1] == 0x4D) { return "tiff" }
        return "png"
    }

    /// v2.8.0: Pastes the payload at `index`, then recurses after a per-payload
    /// delay. Before each step it re-checks the abort conditions (special-slot group
    /// switch or frontmost-app change); on abort it calls `onAbort` (which restores
    /// the clipboard + cleans temp files) and stops. `expectedPid == nil` disables
    /// the app-change guard (kept for completeness; callers always pass a pid).
    private func pasteNextPayloadSequentially(
        _ payloads: [ChainPastePayload],
        index: Int,
        activeId: String,
        generation: Int,
        expectedPid: pid_t?,
        onAbort: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        // v2.8.1 (P0-1): bail out if a newer sequence (or a cancel) has superseded
        // us. The superseding path already restored the clipboard / cleaned temp
        // files, so this stale step must do nothing (no keystroke, no restore).
        guard generation == pasteSequenceGeneration else {
            NSLog("[ClipSlots] sequential paste superseded (gen \(generation) != \(pasteSequenceGeneration)) at step \(index)")
            return
        }
        guard index < payloads.count else {
            completion()
            return
        }

        // Abort if the user switched special-slot group before this step lands.
        if currentSpecialSlotId != activeId {
            NSLog("[ClipSlots] sequential paste abort: group changed \(activeId) -> \(currentSpecialSlotId) at step \(index)")
            onAbort()
            return
        }
        // Abort if the frontmost target app changed mid-sequence.
        if let expectedPid,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != expectedPid {
            NSLog("[ClipSlots] sequential paste abort: frontmost app changed at step \(index)")
            onAbort()
            return
        }

        writePayloadToPasteboard(payloads[index])
        sendPasteKeystroke()

        // v2.7.80: image / file payloads need more time to be ingested (and to keep
        // the clipboard stable) before the next item overwrites it; plain text is fast.
        let payload = payloads[index]
        let isHeavy = payload.isImage || payload.image != nil || !payload.fileURLs.isEmpty
        let delay = isHeavy ? 0.55 : 0.18

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.pasteNextPayloadSequentially(
                payloads,
                index: index + 1,
                activeId: activeId,
                generation: generation,
                expectedPid: expectedPid,
                onAbort: onAbort,
                completion: completion
            )
        }
    }

    private func writePayloadToPasteboard(_ payload: ChainPastePayload) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let text = payload.text, !text.isEmpty {
            pasteboard.setString(text, forType: .string)
            return
        }

        if !payload.fileURLs.isEmpty {
            pasteboard.writeObjects(payload.fileURLs as [NSURL])
            return
        }

        if let image = payload.image {
            pasteboard.writeObjects([image])
            return
        }
    }

    private func showChainPasteSuccess(slots: [Int], pastedCount: Int, skippedEmptyCount: Int) {
        let subtitle: String
        if skippedEmptyCount > 0 {
            subtitle = "\(compactChainDescription(slots))，跳过 \(skippedEmptyCount) 个空槽位"
        } else {
            subtitle = compactChainDescription(slots)
        }
        showFloatingNotice(FloatingNotice(
            title: "已串联粘贴 \(pastedCount) 个槽位",
            subtitle: subtitle,
            iconName: "link.circle.fill",
            kind: .success
        ))
    }

    // MARK: - v2.7.0 Template Export / Import

    func exportConnectionTemplate() {
        guard !currentConnectionMap.edges.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "没有可导出的连接",
                subtitle: "请先建立槽位连接",
                iconName: "exclamationmark.triangle.fill",
                kind: .warning
            ))
            return
        }

        let panel = NSSavePanel()
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "ClipSlots连接模板-\(df.string(from: Date())).clipslotslink"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [UTType(filenameExtension: "clipslotslink") ?? .json]
        } else {
            panel.allowedFileTypes = ["clipslotslink", "json"]
        }

        let response = panel.runModal()
        guard response == .OK, let rawURL = panel.url else { return }
        let url = SlotConnectionTemplateService.sanitizedExportURL(rawURL)

        do {
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.7.0"
            let template = SlotConnectionTemplateService.makeTemplate(
                from: currentConnectionMap,
                name: "ClipSlots 连接模板",
                appVersion: appVersion
            )
            let data = try SlotConnectionTemplateService.encode(template)
            try data.write(to: url, options: [.atomic])

            let slotCount = Set(currentConnectionMap.edges.flatMap { [$0.fromSlot, $0.toSlot] }).count
            showFloatingNotice(FloatingNotice(
                title: "已导出连接模板",
                subtitle: "包含 \(currentConnectionMap.edges.count) 个连接，\(slotCount) 个槽位",
                iconName: "square.and.arrow.up.fill",
                kind: .success
            ))
        } catch {
            showFloatingNotice(FloatingNotice(
                title: "导出失败",
                subtitle: error.localizedDescription,
                iconName: "xmark.circle.fill",
                kind: .error
            ))
        }
    }

    func importConnectionTemplate() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [UTType(filenameExtension: "clipslotslink") ?? .json]
        } else {
            panel.allowedFileTypes = ["clipslotslink", "json"]
        }

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        suppressWatcher() // v2.9.4 (#2): self-write (template import creates groups on disk)
        do {
            let data = try Data(contentsOf: url)
            
            // 先尝试解码为 Bundle 格式（多组/多页模板）
            // v2.7.65: route through the service (ISO8601 + legacy fallback) and
            // require non-empty entries so a single-group template never gets
            // mis-detected as an (empty) bundle.
            if let bundle = try? SlotConnectionTemplateService.decodeBundle(data), !bundle.entries.isEmpty {
                // v2.7.62: 导入 Bundle 模板时创建多个新槽位组
                // P1-8 (v2.10.35): 根因——旧实现在同一个 do{} 循环里「边校验边建组落盘」，某个靠后的
                // entry 校验失败（循环/越界槽/colorId 越界）直接跳到 catch，但此前迭代已 createSpecialSlot
                // + save 落盘的组不做任何撤销 →「导入失败」提示下页面却残留若干用户并不想要的幽灵组。
                // 修法：改为两阶段——先对全部有效 entry 做 validateConnectionMap 预检（此时尚未落盘任何
                // 组），全部通过后再进入建组+落盘循环；且建组阶段若中途失败（如达每页组上限），回滚
                // （软删除）本次已创建的组，保证导入失败绝不残留半成品。
                // 阶段一：全量预检（过滤空连接 entry，与旧逻辑一致地跳过它们），任一非法立即抛错。
                let validEntries = bundle.entries.filter { !$0.map.edges.isEmpty }
                for entry in validEntries {
                    try validateConnectionMap(entry.map)
                }

                // 阶段二：全部校验通过后才建组 + 落盘；中途任一步失败即回滚已创建的组再抛错。
                var importedCount = 0
                var firstGroupId: String?
                var createdGroupIds: [String] = []
                do {
                    for entry in validEntries {
                        let newGroup = try specialStorage.createSpecialSlot(name: entry.groupName, pageId: currentPageId)
                        createdGroupIds.append(newGroup.id)
                        SlotConnectionStorage.shared.save(entry.map, pageId: currentPageId, groupId: newGroup.id)
                        if firstGroupId == nil { firstGroupId = newGroup.id }
                        importedCount += 1
                    }
                } catch {
                    // P1-8 (v2.10.35): 回滚本次已创建的组，避免导入失败后残留幽灵组。
                    for gid in createdGroupIds { try? specialStorage.deleteSpecialSlot(id: gid) }
                    throw error
                }

                guard importedCount > 0, let firstGroupId else {
                    showFloatingNotice(FloatingNotice(
                        title: "导入失败",
                        subtitle: "模板中没有有效的连接数据",
                        iconName: "exclamationmark.triangle.fill",
                        kind: .warning
                    ))
                    return
                }

                // v2.7.65 BUGFIX: the previous implementation created the groups on
                // disk but never refreshed the in-memory @Published state, so the
                // imported groups stayed invisible until the app restarted (the
                // "导入用不了" symptom). Switching to the first imported group reloads
                // the index, published arrays and the connection map for the canvas.
                selectAndActivateSpecialSlot(id: firstGroupId)

                showFloatingNotice(FloatingNotice(
                    title: "已导入连接模板",
                    subtitle: "包含 \(importedCount) 个槽位组，已切换至首个组",
                    iconName: "square.and.arrow.down.fill",
                    kind: .success
                ))
                return
            }
            
            // 否则解码为单组模板
            let template = try SlotConnectionTemplateService.decode(data)
            let importedMap = SlotConnectionMap(edges: template.edges)
            try validateConnectionMap(importedMap)

            // v2.7.61: Import always creates a new slot group, never overwrites current
            let newGroup = try specialStorage.createSpecialSlot(name: "导入 \(template.name.prefix(12))", pageId: currentPageId)
            SlotConnectionStorage.shared.save(importedMap, pageId: currentPageId, groupId: newGroup.id)
            
            // Switch to the new group
            selectAndActivateSpecialSlot(id: newGroup.id)

            let slotCount = Set(importedMap.edges.flatMap { [$0.fromSlot, $0.toSlot] }).count
            showFloatingNotice(FloatingNotice(
                title: "已导入连接模板",
                subtitle: "包含 \(importedMap.edges.count) 个连接，\(slotCount) 个槽位",
                iconName: "square.and.arrow.down.fill",
                kind: .success
            ))
        } catch let error as SlotConnectionError {
            showFloatingNotice(FloatingNotice(
                title: error.noticeTitle,
                subtitle: error.localizedDescription,
                iconName: "xmark.circle.fill",
                kind: .error
            ))
        } catch {
            // v2.7.66: surface the underlying decode error instead of silently
            // collapsing every failure to a generic "模板格式无效".
            NSLog("[ClipSlots] importConnectionTemplate decode failed: \(error)")
            showFloatingNotice(FloatingNotice(
                title: "导入失败",
                subtitle: "模板格式无效：\(error.localizedDescription)",
                iconName: "xmark.circle.fill",
                kind: .error
            ))
        }
    }

    func applyBuiltInFullChainTemplate() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.7.0"
        let template = SlotConnectionTemplateService.makeFullTenSlotChainTemplate(appVersion: appVersion)
        let map = SlotConnectionMap(edges: template.edges)

        do {
            try validateConnectionMap(map)

            if !currentConnectionMap.edges.isEmpty {
                guard confirmReplaceCurrentConnections() else { return }
            }

            currentConnectionMap = map
            saveConnectionMapForCurrentGroup()

            showFloatingNotice(FloatingNotice(
                title: "已应用十槽位全串联",
                subtitle: "粘贴槽位 1 时会串联 1 → 2 → 3 → … → 10",
                iconName: "link.circle.fill",
                kind: .success
            ))
        } catch {
            showFloatingNotice(FloatingNotice(
                title: "应用失败",
                subtitle: error.localizedDescription,
                iconName: "xmark.circle.fill",
                kind: .error
            ))
        }
    }

    // MARK: - v2.7.53 Batch Apply Current Connection Map

    func applyCurrentConnectionMapToAllGroupsInCurrentPage() {
        let source = currentConnectionMap
        guard !source.edges.isEmpty else {
            showToast("当前没有可批量应用的连接")
            return
        }
        let groups = currentPageSlotGroups
        guard !groups.isEmpty else {
            showToast("当前页面没有槽位组")
            return
        }
        for group in groups {
            SlotConnectionStorage.shared.save(source, pageId: currentPageId, groupId: group.id)
        }
        showToast("已批量应用当前连接到本页 \(groups.count) 个槽位组")
    }

    func applyCurrentConnectionMapToAllPagesAndGroups() {
        let source = currentConnectionMap
        guard !source.edges.isEmpty else {
            showToast("当前没有可批量应用的连接")
            return
        }
        var count = 0
        for page in pages {
            let groups = specialSlots.filter { $0.pageId == page.id }
            for group in groups {
                SlotConnectionStorage.shared.save(source, pageId: page.id, groupId: group.id)
                count += 1
            }
        }
        showToast("已批量应用当前连接到全部页面 \(count) 个槽位组")
    }

    private func confirmReplaceCurrentConnections() -> Bool {
        let alert = NSAlert()
        alert.messageText = "替换当前连接？"
        alert.informativeText = "当前槽位组已有连接。导入模板会替换现有连接，但不会修改槽位内容。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "替换连接")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - v2.7.7 Bulk Export / Clear

    func exportConnectionTemplate(scope: ConnectionExportScope) {
        switch scope {
        case .currentGroup:
            exportConnectionTemplate()
        case .currentPage:
            var entries: [SlotConnectionTemplateBundleEntry] = []
            for group in currentPageSlotGroups {
                let map = SlotConnectionStorage.shared.load(pageId: currentPageId, groupId: group.id)
                if !map.edges.isEmpty {
                    entries.append(SlotConnectionTemplateBundleEntry(
                        pageId: currentPageId,
                        groupId: group.id,
                        groupName: group.name,
                        map: map
                    ))
                }
            }
            guard !entries.isEmpty else {
                showFloatingNotice(FloatingNotice(
                    title: "没有可导出的连接",
                    subtitle: "当前页面没有连接数据",
                    iconName: "exclamationmark.triangle.fill",
                    kind: .warning
                ))
                return
            }
            let panel = NSSavePanel()
            let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
            panel.nameFieldStringValue = "ClipSlots页面模板-\(df.string(from: Date())).clipslotslink"
            panel.canCreateDirectories = true
            if #available(macOS 12.0, *) {
                panel.allowedContentTypes = [UTType(filenameExtension: "clipslotslink") ?? .json]
            } else {
                panel.allowedFileTypes = ["clipslotslink", "json"]
            }
            guard panel.runModal() == .OK, let rawURL = panel.url else { return }
            let url = SlotConnectionTemplateService.sanitizedExportURL(rawURL)
            do {
                let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.7.7"
                let bundle = SlotConnectionTemplateService.makeBundleTemplate(from: entries, name: "ClipSlots 页面连接模板", appVersion: appVersion)
                let data = try SlotConnectionTemplateService.encodeBundle(bundle)
                try data.write(to: url, options: [.atomic])
                showFloatingNotice(FloatingNotice(
                    title: "已导出页面连接模板",
                    subtitle: "包含 \(entries.count) 个槽位组",
                    iconName: "square.and.arrow.up.fill",
                    kind: .success
                ))
            } catch {
                showFloatingNotice(FloatingNotice(title: "导出失败", subtitle: error.localizedDescription, iconName: "xmark.circle.fill", kind: .error))
            }
        case .all:
            let allMaps = SlotConnectionStorage.shared.allCachedMaps()
            var entries: [SlotConnectionTemplateBundleEntry] = []
            for (key, map) in allMaps where !map.edges.isEmpty {
                let parts = key.components(separatedBy: "::")
                let pageId = parts.first ?? ""
                let groupId = parts.count > 1 ? parts[1] : (parts.last ?? "")
                // v2.7.65 BUGFIX: previously used `parts.last` (the groupId / UUID)
                // as the display name, so imported groups were named with raw UUIDs.
                // Resolve the real group name from specialSlots, falling back to a
                // friendly label instead of the opaque id.
                let resolvedName = specialSlots.first { $0.id == groupId }?.name
                    ?? "导入组 \(entries.count + 1)"
                entries.append(SlotConnectionTemplateBundleEntry(
                    pageId: pageId,
                    groupId: groupId,
                    groupName: resolvedName,
                    map: map
                ))
            }
            guard !entries.isEmpty else {
                showFloatingNotice(FloatingNotice(title: "没有可导出的连接", subtitle: "没有找到连接数据", iconName: "exclamationmark.triangle.fill", kind: .warning))
                return
            }
            let panel = NSSavePanel()
            let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
            panel.nameFieldStringValue = "ClipSlots全部模板-\(df.string(from: Date())).clipslotslink"
            panel.canCreateDirectories = true
            if #available(macOS 12.0, *) {
                panel.allowedContentTypes = [UTType(filenameExtension: "clipslotslink") ?? .json]
            } else {
                panel.allowedFileTypes = ["clipslotslink", "json"]
            }
            guard panel.runModal() == .OK, let rawURL = panel.url else { return }
            let url = SlotConnectionTemplateService.sanitizedExportURL(rawURL)
            do {
                let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.7.7"
                let bundle = SlotConnectionTemplateService.makeBundleTemplate(from: entries, name: "ClipSlots 全部连接模板", appVersion: appVersion)
                let data = try SlotConnectionTemplateService.encodeBundle(bundle)
                try data.write(to: url, options: [.atomic])
                showFloatingNotice(FloatingNotice(
                    title: "已导出全部连接模板",
                    subtitle: "包含 \(entries.count) 个槽位组",
                    iconName: "square.and.arrow.up.fill",
                    kind: .success
                ))
            } catch {
                showFloatingNotice(FloatingNotice(title: "导出失败", subtitle: error.localizedDescription, iconName: "xmark.circle.fill", kind: .error))
            }
        }
    }

    func clearCurrentConnectionsWithoutConfirm() {
        currentConnectionMap = .empty
        saveConnectionMapForCurrentGroup()
        showFloatingNotice(FloatingNotice(
            title: "已清除当前槽位组连接",
            subtitle: "槽位内容未受影响",
            iconName: "trash.fill",
            kind: .success
        ))
    }

    func clearCurrentPageConnections() {
        for group in currentPageSlotGroups {
            SlotConnectionStorage.shared.save(.empty, pageId: currentPageId, groupId: group.id)
        }
        currentConnectionMap = .empty
        showFloatingNotice(FloatingNotice(
            title: "已清除当前页面连接",
            subtitle: "槽位内容未受影响",
            iconName: "trash.fill",
            kind: .success
        ))
    }

    func clearAllConnections() {
        SlotConnectionStorage.shared.deleteAll { _, _ in true }
        currentConnectionMap = .empty
        showFloatingNotice(FloatingNotice(
            title: "已清除全部连接",
            subtitle: "槽位内容未受影响",
            iconName: "trash.fill",
            kind: .success
        ))
    }

    func applyFullChainToCurrentPage() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.7.7"
        let template = SlotConnectionTemplateService.makeFullTenSlotChainTemplate(appVersion: appVersion)
        let map = SlotConnectionMap(edges: template.edges)
        for group in currentPageSlotGroups {
            SlotConnectionStorage.shared.save(map, pageId: currentPageId, groupId: group.id)
        }
        currentConnectionMap = map
        showFloatingNotice(FloatingNotice(
            title: "已应用到当前页面全部槽位组",
            subtitle: "粘贴槽位 1 时会串联粘贴整条链",
            iconName: "link.circle.fill",
            kind: .success
        ))
    }

    // MARK: - v2.7.1 Stable Connection Management

    func connectionChainSummaries() -> [[Int]] {
        currentConnectionMap.chainStarts()
            .map { currentConnectionMap.chainSlots(startingAt: $0) }
            .filter { $0.count > 1 }
    }

    func addManagedConnection(fromSlot: Int, toSlot: Int) {
        connectSlots(
            fromSlot: fromSlot,
            fromPort: defaultFromPort(from: fromSlot, to: toSlot),
            toSlot: toSlot,
            toPort: defaultToPort(from: fromSlot, to: toSlot)
        )
    }

    func deleteManagedConnection(_ edgeId: UUID) {
        var map = currentConnectionMap
        map.disconnect(edgeId: edgeId)
        currentConnectionMap = map
        saveConnectionMapForCurrentGroup()
        showFloatingNotice(FloatingNotice(
            title: "已删除连接",
            subtitle: "槽位内容未受影响",
            iconName: "link.badge.minus",
            kind: .info
        ))
    }

    private func defaultFromPort(from: Int, to: Int) -> SlotPort {
        if to == from + 1 { return .right }
        if to == from - 1 { return .left }
        if to == from + 5 { return .bottom }
        if to == from - 5 { return .top }
        return .right
    }

    private func defaultToPort(from: Int, to: Int) -> SlotPort {
        if to == from + 1 { return .left }
        if to == from - 1 { return .right }
        if to == from + 5 { return .top }
        if to == from - 5 { return .bottom }
        return .left
    }

    // MARK: - Clear

    func clearSlot(_ slot: Int) {
        let activeId = currentSpecialSlotId

        suppressWatcher() // v2.9.4 (#2): self-write
        cancelPendingClipboardRestore()
        specialStorage.clear(slot, in: activeId)

        ThumbnailProvider.shared.invalidateSlot(specialSlotId: activeId, slot: slot)

        var newSlots = slots
        newSlots[slot] = SlotContent()
        slots = newSlots
        slotRenderTokens["\(activeId)::\(slot)"] = UUID()

        var newLabels = labels
        newLabels.removeValue(forKey: slot)
        labels = newLabels

        loadedSpecialSlotId = activeId
        refreshTrigger = UUID()
        NSLog("[ClipSlots] CLEAR specialSlot=\(activeId) slot=\(slot)")
        recomputeAutoPreviews()   // P1-5 (v2.10.7): 清空后重算游标角标（下一写入点/读取点）
    }

    /// v2.10.19: 只清空槽位「主体文本内容」（items），保留附件列表不变。
    /// 供槽位卡片内容区的叉号按钮调用，与整体清空（clearSlot）区分。
    func clearSlotBody(_ slot: Int) {
        let activeId = currentSpecialSlotId
        var content = contentForSlot(slot)

        // 已经没有主体内容则无需处理（避免误清附件 / 无谓写盘）。
        guard !content.items.isEmpty || content.htmlSource != nil else { return }

        captureUndoSnapshot(title: "删除槽位 \(slot) 内容")

        suppressWatcher() // v2.9.4 (#2): self-write
        cancelPendingClipboardRestore()

        content.items = []
        content.htmlSource = nil
        content.timestamp = Date()
        // 附件（content.attachments）原样保留。
        _ = specialStorage.set(slot, content: content, in: activeId)

        ThumbnailProvider.shared.invalidateSlot(specialSlotId: activeId, slot: slot)

        var newSlots = slots
        newSlots[slot] = content
        slots = newSlots
        slotRenderTokens["\(activeId)::\(slot)"] = UUID()

        loadedSpecialSlotId = activeId
        refreshTrigger = UUID()
        NSLog("[ClipSlots] CLEAR BODY specialSlot=\(activeId) slot=\(slot) keptAttachments=\(content.attachments.count)")
        recomputeAutoPreviews()
        showFloatingNotice(FloatingNotice(
            title: "已删除内容",
            subtitle: content.attachments.isEmpty ? "槽位 \(slot)" : "槽位 \(slot)（附件已保留）",
            iconName: "xmark.circle",
            kind: .info
        ))
    }

    func clearSlotWithConfirmation(_ slot: Int) {
        captureUndoSnapshot(title: "清空槽位 \(slot)")
        if !specialSlotSettings.confirmBeforeClearSingleSlot {
            clearSlot(slot)
            return
        }

        let alert = NSAlert()
        alert.messageText = "清空槽位 \(slot)？"
        alert.informativeText = "该操作会删除当前槽位中的内容。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")

        let checkbox = NSButton(checkboxWithTitle: "不再提醒", target: nil, action: nil)
        alert.accessoryView = checkbox

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if checkbox.state == .on {
            do {
                try specialStorage.updateSettings { $0.confirmBeforeClearSingleSlot = false }
                specialSlotSettings.confirmBeforeClearSingleSlot = false
            } catch {
                NSLog("[ClipSlots] update confirmBeforeClearSingleSlot failed: \(error)")
            }
        }

        clearSlot(slot)
    }

    // MARK: - Label

    func setLabel(_ slot: Int, label: String?) {
        let activeId = currentSpecialSlotId

        suppressWatcher() // v2.9.4 (#2): self-write
        specialStorage.setLabel(slot, label: label, in: activeId)

        var newLabels = labels
        if let label = label, !label.isEmpty {
            newLabels[slot] = label
        } else {
            newLabels.removeValue(forKey: slot)
        }
        labels = newLabels
        loadedSpecialSlotId = activeId

        NSLog("[ClipSlots] setLabel specialSlot=\(activeId) slot=\(slot) label=\(label ?? "")")
    }

    // MARK: - v2.7.26 Hotkey Generation Guard
    // When config changes, remove old hotkeys before registering new ones.
    // Otherwise previous ctrl+option+number shortcuts can still fire and show HUD.
    func updateConfig(_ newConfig: AppConfig) {
        // v2.7.33: atomic replacement. Settings draft must not be active before
        // Save; after Save, no old hotkey reference may survive.
        HotKeyManager.shared.unregisterAll()
        hotkeyRegistrationErrors.removeAll()
        config = newConfig.normalizedForRuntime()
        config.save()
        onConfigChanged?()
        refreshTrigger = UUID()
        installLocalHotkeyGuardIfNeeded()
        objectWillChange.send()
    }

    // MARK: - Folder Import

    private let folderImportService = FolderImportService()
    private let batchImportService = BatchImportService()

    // MARK: - Toolbar Import (v2.6.4)

    /// Opens NSOpenPanel for multi-select files + folders, then shows import options.
    /// v2.10.14: 智能适配——若选中 .clipslotspack 则走「槽位包导入」，否则保持原有
    /// 批量导入图片/文件夹逻辑。文件类型放开为「图片/任意文件 + .clipslotspack」。
    func startToolbarImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.message = "选择要导入的文件、文件夹或槽位包（.clipslotspack）"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        // 优先识别槽位包：只要选择里包含 .clipslotspack，就走包导入（取第一个）。
        if let packURL = panel.urls.first(where: { $0.pathExtension.lowercased() == "clipslotspack" }) {
            importPack(from: packURL)
            return
        }
        presentImportOptions(for: panel.urls)
    }

    // MARK: - Pack Export / Import (v2.10.14)

    /// 打开「打包导出」选择 sheet。无内容时直接提示。
    func startPackExport() {
        guard !specialSlots.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "暂无可导出的内容",
                subtitle: "请先创建页面或槽位组",
                iconName: "shippingbox",
                kind: .warning))
            return
        }
        showingPackExport = true
    }

    /// sheet 确认后：后台预估体积 → 必要时二次确认 → 弹 NSSavePanel → 后台导出。
    func performPackExport(_ selection: PackExportSelection) {
        showingPackExport = false
        guard !selection.isEmpty else { return }

        let exporter = PackExporter(
            maxChildSlots: specialSlotSettings.maxChildSlotsPerSpecialSlot,
            appVersion: appVersionString())

        DispatchQueue.global(qos: .userInitiated).async {
            let bytes = exporter.estimateBytes(for: selection)
            DispatchQueue.main.async {
                let sizeMB = Double(bytes) / (1024.0 * 1024.0)
                if sizeMB > 50 {
                    let alert = NSAlert()
                    alert.messageText = "包体积较大"
                    alert.informativeText = String(format: "包体积约 %.1f MB，确认导出？", sizeMB)
                    alert.addButton(withTitle: "确认导出")
                    alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                self.presentPackSavePanelAndExport(selection: selection, exporter: exporter)
            }
        }
    }

    private func presentPackSavePanelAndExport(selection: PackExportSelection, exporter: PackExporter) {
        let panel = NSSavePanel()
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "ClipSlots_pack_\(df.string(from: Date())).clipslotspack"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [UTType(filenameExtension: "clipslotspack") ?? .data]
        } else {
            panel.allowedFileTypes = ["clipslotspack"]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // P1-3 (v2.10.36): 接住导出结果里的 failedAttachments——旧实现丢弃返回值、无论是否有附件
                // 因源文件缺失/为空而被跳过，都无脑弹「导出成功」，用户完全不知道附件已丢。现在若有附件未能
                // 打包，改弹 warning 明确告知数量，避免「以为导全了、实际缺附件」的静默数据丢失。
                let result = try exporter.export(selection, to: url)
                DispatchQueue.main.async {
                    let failedCount = result.failedAttachments.count
                    if failedCount > 0 {
                        self.showFloatingNotice(FloatingNotice(
                            title: "导出完成，但有 \(failedCount) 个附件未能打包",
                            subtitle: "源文件缺失或不可读，已跳过；其余内容已导出",
                            iconName: "exclamationmark.triangle.fill",
                            kind: .warning))
                    } else {
                        self.showFloatingNotice(FloatingNotice(
                            title: "导出成功",
                            subtitle: "已导出 \(selection.totalGroupCount) 个槽位组",
                            iconName: "square.and.arrow.up.fill",
                            kind: .success))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.showFloatingNotice(FloatingNotice(
                        title: "导出失败",
                        subtitle: error.localizedDescription,
                        iconName: "xmark.circle.fill",
                        kind: .error))
                }
            }
        }
    }

    /// 导入 .clipslotspack：解析 manifest → 逐一解决页/组名冲突 → 写回存储 → 刷新。
    ///
    /// PK-1 (v2.10.15): 整个导入（大包 unzip + JSON 解码 + 逐槽位持锁写入）此前全部同步跑在
    /// 主线程，大包会阻塞 runloop 导致转圈/无响应（导出早已后台化，导入却没有）。改为把整个
    /// 导入放到后台队列执行；仅「冲突弹窗」（必须主线程）与最终 UI 更新回到主线程。冲突弹窗通过
    /// DispatchQueue.main.sync 同步取用户选择后继续在后台推进。
    func importPack(from packURL: URL) {
        let importer = PackImporter(maxChildSlots: specialSlotSettings.maxChildSlotsPerSpecialSlot)

        DispatchQueue.global(qos: .userInitiated).async {
            // 先校验是否为有效槽位包（readManifest 只解出 manifest.json，放后台即可）。
            let manifest: PackManifest
            do {
                manifest = try importer.readManifest(from: packURL)
            } catch {
                DispatchQueue.main.async {
                    self.showFloatingNotice(FloatingNotice(
                        title: "无法导入",
                        subtitle: error.localizedDescription,
                        iconName: "xmark.circle.fill",
                        kind: .error))
                }
                return
            }
            guard !manifest.pages.isEmpty else {
                DispatchQueue.main.async {
                    self.showFloatingNotice(FloatingNotice(
                        title: "槽位包为空",
                        subtitle: "包内没有可导入的页面",
                        iconName: "tray",
                        kind: .warning))
                }
                return
            }

            // 冲突解决：逐一弹窗，支持「对后续所有冲突应用此选择」。
            // PK-1: resolver 在后台线程被同步调用，NSAlert 必须主线程，故通过 main.sync 取选择。
            var pageDecisionForAll: PackConflictResolution?
            var groupDecisionForAll: PackConflictResolution?

            let resolvePage: (String) -> PackConflictResolution = { name in
                if let d = pageDecisionForAll { return d }
                var decision: PackConflictResolution = .skip
                DispatchQueue.main.sync {
                    let (d, applyAll) = self.askPackConflict(kind: "页面", name: name)
                    decision = d
                    if applyAll { pageDecisionForAll = d }
                }
                return decision
            }
            let resolveGroup: (String, String) -> PackConflictResolution = { pageName, groupName in
                if let d = groupDecisionForAll { return d }
                var decision: PackConflictResolution = .skip
                DispatchQueue.main.sync {
                    let (d, applyAll) = self.askPackConflict(kind: "槽位组", name: "\(pageName) / \(groupName)")
                    decision = d
                    if applyAll { groupDecisionForAll = d }
                }
                return decision
            }

            // PK-2 (v2.10.15): 用开放式抑制窗口覆盖整个导入生命周期（含 >2s 的模态冲突弹窗），
            // 取代原先固定 2s 窗口——固定窗口会在用户停留弹窗期间过期，使导入写入触发 FSEvents 让
            // StorageDirectoryWatcher 反复 reloadAll（闪烁 / 当前页被重置）。此处置为 distantFuture，
            // 待完成后再收敛为 suppressWatcher(2.0) 覆盖尾随 FSEvents 并自然恢复。
            // CR-1 (v2.10.30): 改用加锁访问器直接写入，去掉原 `DispatchQueue.main.sync { ... }` 包裹——
            // 该 sync 若碰巧已在主线程执行会死锁；锁本身即保证线程安全，无需再切主队列。
            self.setIgnoreWatcherUntil(.distantFuture)

            do {
                let result = try importer.importPack(
                    from: packURL,
                    resolvePageConflict: resolvePage,
                    resolveGroupConflict: resolveGroup)
                DispatchQueue.main.async {
                    self.suppressWatcher(2.0) // 收敛抑制窗口，覆盖导入写入的尾随 FSEvents 后恢复。
                    self.reloadAll()
                    var subtitle = "导入 \(result.importedGroups) 组 / \(result.importedSlots) 槽位"
                    if result.skippedGroups > 0 { subtitle += "，跳过 \(result.skippedGroups) 组" }
                    self.showFloatingNotice(FloatingNotice(
                        title: "导入完成",
                        subtitle: subtitle,
                        iconName: "square.and.arrow.down.fill",
                        kind: .success))
                }
            } catch {
                DispatchQueue.main.async {
                    self.suppressWatcher(2.0) // 收敛抑制窗口（PK-3 回滚也在磁盘写入，需覆盖其 FSEvents）。
                    self.reloadAll()
                    self.showFloatingNotice(FloatingNotice(
                        title: "导入失败",
                        subtitle: error.localizedDescription,
                        iconName: "xmark.circle.fill",
                        kind: .error))
                }
            }
        }
    }

    /// 弹出冲突处理弹窗，返回 (选择, 是否应用到后续全部同类冲突)。
    private func askPackConflict(kind: String, name: String) -> (PackConflictResolution, Bool) {
        let alert = NSAlert()
        alert.messageText = "\(kind)「\(name)」已存在"
        alert.informativeText = "选择处理方式：追加新建（名称后加 -导入）、覆盖同名内容，或跳过。"
        alert.addButton(withTitle: "追加新建")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "覆盖")        // .alertSecondButtonReturn
        alert.addButton(withTitle: "跳过")        // .alertThirdButtonReturn
        let suppress = NSButton(checkboxWithTitle: "对后续所有\(kind)冲突应用此选择", target: nil, action: nil)
        suppress.sizeToFit()
        alert.accessoryView = suppress

        let response = alert.runModal()
        let applyAll = suppress.state == .on
        switch response {
        case .alertFirstButtonReturn: return (.append, applyAll)
        case .alertSecondButtonReturn: return (.overwrite, applyAll)
        default: return (.skip, applyAll)
        }
    }

    private func appVersionString() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.10.14"
    }

    /// Show import mode picker for the selected URLs, then execute. (v2.6.7: SwiftUI sheet)
    func presentImportOptions(for urls: [URL]) {
        // Classify selection
        var folderCount = 0
        var fileCount = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { continue }
            if values.isDirectory == true { folderCount += 1 }
            else if values.isRegularFile == true { fileCount += 1 }
        }

        let totalItems = fileCount + folderCount
        guard totalItems > 0 else {
            showFloatingNotice(FloatingNotice(
                title: "没有可导入的文件",
                iconName: "tray", kind: .warning))
            return
        }

        // Single file: import directly without options
        if fileCount == 1 && folderCount == 0, let fileURL = urls.first {
            executeToolbarImport(urls: [fileURL], mode: .allTotal, sortRule: specialSlotSettings.folderImportSortRule)
            return
        }

        // v2.6.7: Show SwiftUI sheet instead of NSAlert
        let summary = ImportSelectionSummary(fileCount: fileCount, folderCount: folderCount)
        pendingImportSelection = PendingImportSelection(
            urls: urls,
            summary: summary,
            startSlot: 1,
            source: .toolbar
        )
    }

    /// Called when user confirms import options from the sheet. (v2.6.7)
    func executeImportSelection(_ selection: PendingImportSelection, choice: ImportChoiceMode) {
        let mode = resolveExpansionMode(choice: choice, summary: selection.summary)
        let expansion = folderImportService.expandSelection(
            urls: selection.urls,
            mode: mode,
            sortRule: specialSlotSettings.folderImportSortRule
        )

        guard !expansion.items.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "没有可导入的文件",
                subtitle: expansion.folderCount > 0 ? "文件夹为空或无可读取文件" : "",
                iconName: "tray",
                kind: .warning
            ))
            return
        }

        handleBatchSave(
            items: expansion.items,
            startSlot: selection.startSlot,
            expansion: expansion
        )
    }

    /// Expand URLs using the given mode and delegate to handleBatchSave.
    func executeToolbarImport(urls: [URL], mode: ImportLimitMode, sortRule: FolderImportSortRule) {
        let expansion = folderImportService.expandSelection(urls: urls, mode: mode, sortRule: sortRule)

        guard !expansion.items.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "没有可导入的文件",
                subtitle: expansion.folderCount > 0 ? "文件夹为空或无可读取文件" : "",
                iconName: "tray",
                kind: .warning
            ))
            return
        }

        handleBatchSave(
            items: expansion.items,
            startSlot: 1,
            expansion: expansion
        )
    }

    func importFolderIntoCurrentSpecialSlot(_ folderURL: URL) {
        suppressWatcher() // v2.9.4 (#2): self-write
        let activeId = currentSpecialSlotId
        let options = FolderImportOptions(
            maxFiles: specialSlotSettings.maxChildSlotsPerSpecialSlot,
            includeHiddenFiles: false,
            recursive: false,
            sortRule: specialSlotSettings.folderImportSortRule
        )

        do {
            let preview = try folderImportService.preview(folderURL: folderURL, options: options)

            guard preview.totalImportableCount > 0 else {
                showAlert(message: "该文件夹中没有可导入文件")
                return
            }

            // Overflow check
            if preview.overflowed, !specialSlotSettings.suppressFolderOverflowWarning {
                let decision = confirmFolderOverflow(count: preview.totalImportableCount, max: options.maxFiles)
                switch decision {
                case .cancel: return
                case .confirm(let suppress):
                    if suppress {
                        try? specialStorage.updateSettings { $0.suppressFolderOverflowWarning = true }
                        specialSlotSettings.suppressFolderOverflowWarning = true
                    }
                }
            }

            // Overwrite check
            let hasContent = (1...config.slots).contains { !specialStorage.isEmpty($0, in: activeId) }
            if hasContent && specialSlotSettings.confirmBeforeOverwrite {
                guard confirmOverwriteCurrentSpecialSlot() else { return }
            }

            // Clear and import
            ThumbnailProvider.shared.invalidateSpecialSlot(specialSlotId: activeId)

            suppressWatcher() // v2.9.4 (#2): re-bump after any modal so the write burst below stays suppressed

            // APP-3 (v2.10.32): the clear + per-file makeSlotContent + set() burst (each set() a
            // cross-process flock, plus big-file bytes loaded by makeSlotContent) previously ran
            // synchronously on the main thread — a folder of hundreds of files froze the GUI. Move
            // the whole burst to a background serial queue and commit the reload/toast back on main.
            let willImportFiles = preview.willImportFiles
            slotWriteQueue.async { [weak self] in  // P1-1 (v2.10.35): 串行写队列，防并发错序覆盖
                guard let self = self else { return }
                do {
                    try self.specialStorage.clearAllSlots(in: activeId)

                    var successCount = 0
                    var failCount = 0
                    for (idx, fileURL) in willImportFiles.enumerated() {
                        self.suppressWatcher() // keep the self-write window fresh during a long import
                        let slotNumber = idx + 1
                        var content = self.folderImportService.makeSlotContent(for: fileURL)
                        // Regenerate identity so thumbnails and SwiftUI views refresh.
                        content.contentId = UUID().uuidString
                        content.updatedAt = Date().timeIntervalSince1970
                        if self.specialStorage.set(slotNumber, content: content, in: activeId) {
                            successCount += 1
                        } else {
                            failCount += 1
                        }
                    }

                    try? self.specialStorage.updateCurrentSpecialSlotSource(
                        sourceType: .folderImport,
                        sourcePath: folderURL.path
                    )

                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.reloadAllAsync()
                        self.refreshTrigger = UUID()
                        self.suppressWatcher(2.0)
                        // v2.6.2: Floating notice instead of blocking alert
                        self.showFloatingNotice(FloatingNotice(
                            title: "已导入 \(successCount) 个文件",
                            subtitle: failCount > 0 ? "\(failCount) 个失败" : "当前槽位组",
                            iconName: failCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                            kind: failCount > 0 ? .warning : .success
                        ))
                    }
                } catch {
                    NSLog("[ClipSlots] Folder import (bg) error: \(error)")
                    DispatchQueue.main.async { [weak self] in
                        self?.showAlert(message: "导入失败: \(error.localizedDescription)")
                    }
                }
            }

        } catch {
            NSLog("[ClipSlots] Folder import error: \(error)")
            showAlert(message: "导入失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Dialogs

    private func confirmFolderOverflow(count: Int, max: Int) -> FolderOverflowDecision {
        let alert = NSAlert()
        alert.messageText = "文件数量超过槽位上限"
        alert.informativeText = "当前文件夹包含 \(count) 个可导入文件，但每个槽位组最多只能保存 \(max) 个子槽位。是否仅导入排序后的前 \(max) 个文件？"
        alert.addButton(withTitle: "确认导入前 \(max) 个")
        alert.addButton(withTitle: "取消")

        let checkbox = NSButton(checkboxWithTitle: "不再提醒", target: nil, action: nil)
        alert.accessoryView = checkbox

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            return .confirm(suppressFutureWarning: checkbox.state == .on)
        }
        return .cancel
    }

    private func confirmOverwriteCurrentSpecialSlot() -> Bool {
        let alert = NSAlert()
        alert.messageText = "是否覆盖当前槽位内容？"
        alert.informativeText = "批量导入会清空当前槽位组下已有的子槽位内容。是否继续？"
        alert.addButton(withTitle: "继续并覆盖")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    // MT-3 (v2.10.30): 为「把阻塞的 alert.runModal() 改成非阻塞 beginSheetModal(for:)」提供宿主窗口。
    // 优先 keyWindow（非面板），退回第一个可见的非面板窗口。取不到窗口时返回 nil，调用方回退到 runModal()。
    private func sheetHostWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, !(key is NSPanel) { return key }
        return NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible })
    }

    // MARK: - File Detection

    func handleCapturedContentForSave(_ content: SlotContent, targetSlot: Int) {
        suppressWatcher() // v2.9.4 (#2): self-write (covers all save/import sub-paths below)
        let activeId = currentSpecialSlotId
        let folderURLs = content.detectedFolderURLs

        // v2.6.4: Route multi-folder to import mode picker
        if folderURLs.count > 1 {
            presentImportModePickerForFolder(folderURLs, startSlot: targetSlot)
            return
        }
        if folderURLs.count == 1 {
            handleSingleFolderSave(folderURLs[0], targetSlot: targetSlot)
            return
        }

        // v2.6.0: Detect batch file save
        if let batchItems = batchImportService.detectBatchItems(from: content),
           batchItems.count > 1 {
            handleBatchSave(items: batchItems, startSlot: targetSlot)
            return
        }

        // Check if overwriting (before save)
        let existingBeforeSave = specialStorage.get(targetSlot, in: activeId)

        // Normal save — regenerate identity so thumbnails and SwiftUI views refresh.
        var savedContent = content
        savedContent.contentId = UUID().uuidString
        savedContent.updatedAt = Date().timeIntervalSince1970
        // v2.7.74: overwriting a slot's main content should keep its attachments,
        // which belong to the slot rather than the captured clipboard payload.
        savedContent.attachments = existingBeforeSave.attachments

        ThumbnailProvider.shared.invalidateSlot(specialSlotId: activeId, slot: targetSlot)

        // MT-1 (v2.10.30): 单槽保存写盘同样走跨进程写锁（锁竞争时最长阻塞 ~5s），从主线程挪到后台队列，
        // 写完再回主线程更新内存 @Published / 标签 / 提示。要写入的内容在派发前固定为不可变快照，后台
        // 闭包不读取可变 @Published 状态。callers（saveToSlot / captureSelectionAndSaveToSlot）不依赖本
        // 方法的同步返回，故异步化安全。
        let contentToWrite = savedContent
        let existingSnapshot = existingBeforeSave
        slotWriteQueue.async { [weak self] in  // P1-1 (v2.10.35): 串行写队列，防并发错序覆盖
            guard let self = self else { return }
            let success = self.specialStorage.set(targetSlot, content: contentToWrite, in: activeId)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard success else {
                    NSLog("[ClipSlots] SAVE FAIL specialSlot=\(activeId) slot=\(targetSlot)")
                    self.showFloatingNotice(FloatingNotice(
                        title: "保存失败",
                        subtitle: "槽位 \(targetSlot) 写入失败，请重试",
                        iconName: "xmark.circle.fill",
                        kind: .error
                    ), duration: 2.5)
                    return
                }
                // P1-2 (v2.10.34): 组一致性守卫。本闭包在后台写盘（最长阻塞 ~5s 抢锁）完成后才回到
                // 主线程，这期间用户可能已切到别的组（currentSpecialSlotId 变了）。磁盘写已按捕获的
                // activeId 落到正确的组，但下面的内存刷新（slots / render token / loadedSpecialSlotId）
                // 与 setLabel（其内部按【当前】currentSpecialSlotId 写盘+内存）若无条件执行，会把「旧组
                // 的内容」灌进「新当前组」的内存视图，并把文件名标签持久化到错组——即污染错组内存 +
                // 标签写错组。故仅当仍停留在 activeId 时才刷新内存并走 setLabel；已切组时跳过内存刷新，
                // 且仅把文件名标签按 activeId 直接持久化到正确组的磁盘（不碰任何内存），避免标签丢失。
                let stillOnActiveGroup = (self.currentSpecialSlotId == activeId)
                if stillOnActiveGroup {
                    var newSlots = self.slots
                    newSlots[targetSlot] = contentToWrite
                    self.slots = newSlots
                    self.slotRenderTokens["\(activeId)::\(targetSlot)"] = UUID()
                    self.loadedSpecialSlotId = activeId
                    self.refreshTrigger = UUID()

                    // Update label to file name if present
                    if let fileURL = contentToWrite.primaryFileURL {
                        self.setLabel(targetSlot, label: fileURL.lastPathComponent)
                    }
                } else {
                    NSLog("[ClipSlots] SAVE 回调发现已切组（active=\(activeId) current=\(self.currentSpecialSlotId)），"
                        + "跳过内存刷新，仅按 activeId 持久化标签，避免污染错组内存 / 标签写错组")
                    if let fileURL = contentToWrite.primaryFileURL {
                        self.suppressWatcher() // 自写，避免文件监听回灌
                        _ = self.specialStorage.setLabel(targetSlot, label: fileURL.lastPathComponent, in: activeId)
                    }
                }

                NSLog("[ClipSlots] SAVE OK specialSlot=\(activeId) slot=\(targetSlot) contentId=\(contentToWrite.contentId) preview=\(contentToWrite.preview)")

                // v2.6.2: Floating notice with content summary
                if UserDefaults.standard.showSaveToast {
                    let summary = contentToWrite.noticeSummary
                    let isOverwrite = !existingSnapshot.isEmpty
                    self.showFloatingNotice(FloatingNotice(
                        title: isOverwrite ? "已覆盖槽位 \(targetSlot)" : "已保存到槽位 \(targetSlot)",
                        subtitle: "\(summary.typeTitle) · \(summary.detail)",
                        iconName: summary.iconName,
                        kind: .success
                    ))
                }
            }
        }
    }

    // MARK: - Batch Save (v2.6.1)

    private let maxAutoCreatePages: Int = 20

    private func handleBatchSave(
        items: [BatchImportItem],
        startSlot: Int,
        expansion: BatchImportExpansionResult? = nil
    ) {
        suppressWatcher() // v2.9.4 (#2): self-write (batch); re-bumped in the loop below
        // v2.6.2: Safety guards
        guard !isBatchSaving else {
            showFloatingNotice(FloatingNotice(
                title: "正在批量保存，请稍候", iconName: "hourglass", kind: .info))
            return
        }

        guard !items.isEmpty else {
            showFloatingNotice(FloatingNotice(
                title: "没有可保存的文件", iconName: "tray", kind: .warning))
            return
        }

        guard (1...config.slots).contains(startSlot) else {
            showFloatingNotice(FloatingNotice(
                title: "起始槽位无效", iconName: "exclamationmark.triangle.fill", kind: .error))
            return
        }

        guard currentPage != nil, currentSpecialSlot != nil else {
            showFloatingNotice(FloatingNotice(
                title: "页面或槽位组不存在", iconName: "exclamationmark.triangle.fill", kind: .error))
            return
        }

        let activeId = currentSpecialSlotId
        let originalPageId = currentPageId
        let pageGroups = currentPageSlotGroups
        let allPages = pages

        // Build target slot list: [(specialSlotId, slot)]
        var targets: [(specialSlotId: String, slot: Int)] = []

        // Current group from startSlot
        for s in startSlot...config.slots {
            targets.append((activeId, s))
        }

        // Find current group index
        let currentGroupIdx = pageGroups.firstIndex(where: { $0.id == activeId }) ?? 0

        // Subsequent existing groups in this page
        for i in (currentGroupIdx + 1)..<pageGroups.count {
            for s in 1...config.slots {
                targets.append((pageGroups[i].id, s))
            }
        }

        // Capacity: groups in current page + new groups we can create
        let existingCount = pageGroups.count
        let maxNewGroupsInPage = max(0, specialSlotSettings.maxSpecialSlots - existingCount)
        let newGroupsNeededInPage = min(maxNewGroupsInPage,
            max(0, (items.count - targets.count + config.slots - 1) / config.slots))

        // Calculate page-level capacity
        let capacityInPage = targets.count + newGroupsNeededInPage * config.slots
        var remainingAfterPage = max(0, items.count - capacityInPage)
        let pagesNeeded = min(maxAutoCreatePages,
            (remainingAfterPage + specialSlotSettings.maxSpecialSlots * config.slots - 1)
                / (specialSlotSettings.maxSpecialSlots * config.slots))

        let totalCapacity = capacityInPage + pagesNeeded * specialSlotSettings.maxSpecialSlots * config.slots

        let plan = BatchSavePlan(
            items: items,
            startSlot: startSlot,
            willOverwriteCount: countOverwrites(targets: targets.prefix(items.count)),
            needsNewGroups: newGroupsNeededInPage + pagesNeeded * specialSlotSettings.maxSpecialSlots,
            skippedFolderCount: 0,
            skippedUnsupportedCount: 0,
            availableCapacity: totalCapacity
        )

        // Show confirmation (updated to include page info)
        if !UserDefaults.standard.skipBatchSaveConfirmation || plan.willOverwriteCount > 0 {
            guard confirmBatchSaveV2(plan,
                currentGroupName: currentSpecialSlot?.name ?? "槽位组",
                pagesNeeded: pagesNeeded) else {
                return
            }
        }

        // Check capacity
        if plan.willSkipCount > 0 {
            guard confirmPartialBatchSave(plan) else {
                return
            }
        }

        isBatchSaving = true

        suppressWatcher() // v2.9.4 (#2): re-bump after confirmation modals, before the create/write burst

        // APP-3 (v2.10.32): the entire create-groups / create-pages + per-item makeSlotContent +
        // get + set + setLabel burst (each set/setLabel a cross-process flock, plus big-file bytes
        // loaded by makeSlotContent) previously ran SYNCHRONOUSLY on the main thread. MT-1 only
        // moved the single-slot write off-main; this batch call site was left behind, so importing
        // a folder of dozens~hundreds of files froze the GUI for seconds to minutes with no
        // response and no way to cancel — approaching a P0 under lock contention. isBatchSaving
        // only blocked re-entry; it did not yield the main thread. Fix: run the whole burst on a
        // background serial queue over an immutable item snapshot, then hop back to the main thread
        // to update @Published state, reloadAllAsync, and show the toast, clearing isBatchSaving
        // only after that completes.
        let cfgSlots = config.slots
        let maxSpecial = specialSlotSettings.maxSpecialSlots
        slotWriteQueue.async { [weak self] in  // P1-1 (v2.10.35): 串行写队列，防并发错序覆盖
            guard let self = self else { return }
            var savedCount = 0
            var failedCount = 0
            var overwrittenCount = 0
            var createdGroupCount = 0
            var createdPageCount = 0
            let itemsToSave = plan.willSaveCount
            var targets = targets

            // Create new groups in current page
            if newGroupsNeededInPage > 0 {
            for n in 1...newGroupsNeededInPage {
                let groupName = self.uniqueImportGroupName(existingNames: Set(pageGroups.map { $0.name }), startNumber: n)
                do {
                    let newGroup = try self.specialStorage.createSpecialSlot(name: groupName, pageId: originalPageId)
                    for s in 1...cfgSlots {
                        targets.append((newGroup.id, s))
                    }
                    createdGroupCount += 1
                } catch {
                    NSLog("[ClipSlots] Batch save: failed to create group '\(groupName)': \(error)")
                    break
                }
            }
            } // end if newGroupsNeededInPage > 0

            // Create new pages if needed
            let remainingAfterPage = max(0, itemsToSave - targets.count)
            let actualPagesNeeded = min(pagesNeeded,
                (remainingAfterPage + maxSpecial * cfgSlots - 1)
                    / (maxSpecial * cfgSlots))

            let existingPageNames = Set(allPages.map { $0.name })
            if actualPagesNeeded > 0 {
            for pn in 1...actualPagesNeeded {
                let pageName = self.uniqueImportPageName(existingNames: existingPageNames, startNumber: pn + createdPageCount)
                do {
                    let newPage = try self.specialStorage.createPage(name: pageName, withDefaultGroup: false).page
                    createdPageCount += 1
                    // Create groups in the new page (up to maxSpecialSlots)
                    let groupsNeededInPage = min(maxSpecial,
                        max(0, (itemsToSave - targets.count + cfgSlots - 1) / cfgSlots))
                    if groupsNeededInPage > 0 {
                    for gn in 1...groupsNeededInPage {
                        let groupName = "导入 \(gn)"
                        do {
                            let newGroup = try self.specialStorage.createSpecialSlot(name: groupName, pageId: newPage.id)
                            for s in 1...cfgSlots {
                                targets.append((newGroup.id, s))
                            }
                            createdGroupCount += 1
                        } catch {
                            NSLog("[ClipSlots] Batch save: failed to create group in page '\(pageName)': \(error)")
                            break
                        }
                    }
                    } // end if groupsNeededInPage > 0
                } catch {
                    NSLog("[ClipSlots] Batch save: failed to create page: \(error)")
                    break
                }
            }
            } // end if actualPagesNeeded > 0

            // Save items to targets
            for (index, item) in items.enumerated() {
                guard index < itemsToSave, index < targets.count else { break }
                self.suppressWatcher() // v2.9.4 (#2): keep the self-write window fresh during a long batch
                let target = targets[index]
                var content = self.batchImportService.makeSlotContent(for: item.fileURL)
                content.contentId = UUID().uuidString
                content.updatedAt = Date().timeIntervalSince1970

                // Check if overwriting
                let existing = self.specialStorage.get(target.slot, in: target.specialSlotId)
                let isOverwrite = !existing.isEmpty

                let ok = self.specialStorage.set(target.slot, content: content, in: target.specialSlotId)
                if ok {
                    if isOverwrite { overwrittenCount += 1 }
                    // Set label to file name
                    self.specialStorage.setLabel(target.slot, label: item.fileName, in: target.specialSlotId)
                    savedCount += 1
                } else {
                    failedCount += 1
                }
            }

            // Switch back to original page if we navigated away
            if pagesNeeded > 0 {
                try? self.specialStorage.switchToPage(id: originalPageId)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Refresh state (must touch @Published on the main thread)
                let refreshedIndex = self.specialStorage.loadIndex()
                self.specialSlots = refreshedIndex.specialSlots
                self.pages = refreshedIndex.pages

                // Reload current slots and show toast
                self.reloadAllAsync()
                self.refreshTrigger = UUID()

                // Count source folders
                let sourceFolderNames = Set(items.prefix(itemsToSave).compactMap { $0.sourceFolderName })
                let folderSourceCount = sourceFolderNames.count

                var parts: [String] = []
                parts.append("已保存 \(savedCount) 个文件")
                if overwrittenCount > 0 { parts.append("覆盖 \(overwrittenCount) 个槽位") }
                if createdPageCount > 0 { parts.append("新建 \(createdPageCount) 个页面") }
                if createdGroupCount > 0 { parts.append("新建 \(createdGroupCount) 个槽位组") }
                if folderSourceCount > 0 { parts.append("来自 \(folderSourceCount) 个文件夹") }
                if failedCount > 0 { parts.append("\(failedCount) 个失败") }

                // v2.6.4: Include expansion context when available
                if let exp = expansion, exp.limitedByMode {
                    switch exp.mode {
                    case .firstTenTotal:
                        parts.append("已按设置只导入前 10 个")
                    case .firstTenPerFolder:
                        parts.append("每个文件夹前 10 个")
                    default:
                        break
                    }
                }

                let toast = parts.joined(separator: "，")
                if UserDefaults.standard.showSaveToast {
                    let iconName = failedCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    self.showFloatingNotice(FloatingNotice(
                        title: "已批量保存 \(savedCount) 个文件",
                        subtitle: parts.dropFirst().joined(separator: "，"),
                        iconName: iconName,
                        kind: failedCount > 0 ? .warning : .success
                    ), duration: 2.5)
                }
                self.suppressWatcher(2.0) // 收敛抑制窗口，覆盖批量写入的尾随 FSEvents
                self.isBatchSaving = false
                NSLog("[ClipSlots] Batch save complete: \(toast)")
            }
        }
    }

    private func countOverwrites(targets: ArraySlice<(specialSlotId: String, slot: Int)>) -> Int {
        targets.filter { target in
            !specialStorage.isEmpty(target.slot, in: target.specialSlotId)
        }.count
    }

    private func uniqueImportGroupName(existingNames: Set<String>, startNumber: Int) -> String {
        var n = startNumber
        while true {
            let name = "导入 \(n)"
            if !existingNames.contains(name) { return name }
            n += 1
        }
    }

    private func uniqueImportPageName(existingNames: Set<String>, startNumber: Int) -> String {
        var n = startNumber
        while true {
            let name = "导入页面 \(n)"
            if !existingNames.contains(name) { return name }
            n += 1
        }
    }

    private func confirmBatchSaveV2(_ plan: BatchSavePlan, currentGroupName: String, pagesNeeded: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "批量保存文件？"
        alert.alertStyle = .informational

        var lines: [String] = []
        lines.append("即将保存 \(plan.items.count) 个文件。")
        lines.append("")
        let pageName = currentPage?.name ?? "页面"
        lines.append("起点：页面「\(pageName)」/ \(currentGroupName) / 槽位 \(plan.startSlot)")
        if pagesNeeded > 0 {
            lines.append("将新建：\(pagesNeeded) 个页面")
        }
        if plan.needsNewGroups > 0 {
            lines.append("将新建：\(plan.needsNewGroups) 个槽位组")
        }
        if plan.willOverwriteCount > 0 {
            lines.append("将覆盖：\(plan.willOverwriteCount) 个已有槽位")
        }

        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "开始保存")
        alert.addButton(withTitle: "取消")

        if plan.willOverwriteCount > 0 {
            let checkbox = NSButton(checkboxWithTitle: "以后覆盖时不再提醒", target: nil, action: nil)
            alert.accessoryView = checkbox
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if checkbox.state == .on {
                    UserDefaults.standard.set(true, forKey: UserPreferenceKeys.skipOverwriteConfirmation)
                }
                return true
            }
            return false
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmBatchSave(_ plan: BatchSavePlan, currentGroupName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "批量保存文件？"
        alert.alertStyle = .informational

        var lines: [String] = []
        lines.append("即将保存 \(plan.items.count) 个文件。")
        lines.append("")
        let pageName = currentPage?.name ?? "页面"
        lines.append("起点：页面「\(pageName)」/ \(currentGroupName) / 槽位 \(plan.startSlot)")
        if plan.needsNewGroups > 0 {
            lines.append("将新建：\(plan.needsNewGroups) 个槽位组")
        }
        if plan.willOverwriteCount > 0 {
            lines.append("将覆盖：\(plan.willOverwriteCount) 个已有槽位")
        }

        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "开始保存")
        alert.addButton(withTitle: "取消")

        if plan.willOverwriteCount > 0 {
            let checkbox = NSButton(checkboxWithTitle: "以后覆盖时不再提醒", target: nil, action: nil)
            alert.accessoryView = checkbox
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if checkbox.state == .on {
                    UserDefaults.standard.set(true, forKey: UserPreferenceKeys.skipOverwriteConfirmation)
                }
                return true
            }
            return false
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmPartialBatchSave(_ plan: BatchSavePlan) -> Bool {
        let alert = NSAlert()
        alert.messageText = "只能保存部分文件"
        alert.informativeText = "当前可用容量只能保存前 \(plan.willSaveCount) 个文件，剩余 \(plan.willSkipCount) 个文件无法保存。\n\n原因：当前页面的槽位组数量已达到上限（\(specialSlotSettings.maxSpecialSlots) 个）。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存可用部分")
        alert.addButton(withTitle: "取消")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func handleSingleFolderSave(_ folderURL: URL, targetSlot: Int) {
        let alert = NSAlert()
        alert.messageText = "检测到文件夹"
        alert.informativeText = "当前剪贴板内容是文件夹 (\(folderURL.lastPathComponent))。\n你想如何处理？"
        alert.addButton(withTitle: "批量导入文件...")
        alert.addButton(withTitle: "作为普通文件保存")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // v2.6.4: Show import mode picker (first 10 / all)
            presentImportModePickerForFolder([folderURL], startSlot: targetSlot)
        case .alertSecondButtonReturn:
            let activeId = currentSpecialSlotId
            ThumbnailProvider.shared.invalidateSlot(specialSlotId: activeId, slot: targetSlot)
            suppressWatcher() // v2.9.4 (#2): self-write (bump right before the write, after the modal)
            // P1-4 (v2.10.35): makeSlotContent（可能读入大文件字节）+ specialStorage.set（跨进程 flock，
            // 锁竞争时最长阻塞 ~5s）此前同步跑在主线程，把文件夹当普通文件保存时会卡住 UI。改为把内容构造与
            // 写盘挪到统一串行写队列（与其他槽位写盘保序），写完再回主线程更新 @Published 视图与提示。
            slotWriteQueue.async { [weak self] in
                guard let self = self else { return }
                var content = self.folderImportService.makeSlotContent(for: folderURL)
                content.contentId = UUID().uuidString
                content.updatedAt = Date().timeIntervalSince1970
                let success = self.specialStorage.set(targetSlot, content: content, in: activeId)
                let committed = content
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    guard success else {
                        NSLog("[ClipSlots] save folder as normal FAIL specialSlot=\(activeId) slot=\(targetSlot)")
                        return
                    }
                    // 回主线程时可能已切组：仅当仍停留在原组才刷新内存视图，避免污染错组。
                    guard self.currentSpecialSlotId == activeId else { return }
                    var newSlots = self.slots
                    newSlots[targetSlot] = committed
                    self.slots = newSlots
                    self.slotRenderTokens["\(activeId)::\(targetSlot)"] = UUID()
                    self.loadedSpecialSlotId = activeId
                    self.refreshTrigger = UUID()
                    let summary = committed.noticeSummary
                    self.showFloatingNotice(FloatingNotice(
                        title: "已保存到槽位 \(targetSlot)",
                        subtitle: "\(summary.typeTitle) · \(summary.detail)",
                        iconName: summary.iconName,
                        kind: .success
                    ))
                }
            }
        default:
            break
        }
    }

    /// Show import mode picker for hotkey-sourced folder import. (v2.6.7: SwiftUI sheet)
    private func presentImportModePickerForFolder(_ folderURLs: [URL], startSlot: Int) {
        let folderCount = folderURLs.count
        let summary = ImportSelectionSummary(fileCount: 0, folderCount: folderCount)
        // v2.6.7: Bring window forward so the sheet is visible
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        pendingImportSelection = PendingImportSelection(
            urls: folderURLs,
            summary: summary,
            startSlot: startSlot,
            source: .hotkey
        )
    }

    func createSpecialSlotAndImportFolder(_ folderURL: URL) {
        suppressWatcher() // v2.9.4 (#2): self-write (creates + switches group, then imports)
        do {
            let name = folderURL.lastPathComponent
            let slot = try specialStorage.createSpecialSlot(
                name: name,
                sourceType: .folderImport,
                sourcePath: folderURL.path
            )
            try specialStorage.switchToSpecialSlot(id: slot.id)
            reloadAll()
            importFolderIntoCurrentSpecialSlot(folderURL)
        } catch {
            NSLog("[ClipSlots] createSpecialSlotAndImportFolder error: \(error)")
            showAlert(message: "创建槽位组失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Global Search (v2.5.2)

    /// Return all searchable slots across all pages and groups (read-only).
    func allSearchableSlots() -> [SlotGlobalSearchResult] {
        var results: [SlotGlobalSearchResult] = []

        for page in pages {
            let groups = specialSlots.filter { $0.pageId == page.id }.sorted { $0.order < $1.order }
            for group in groups {
                let storage = specialStorage.slotStorage(for: group.id)
                let snapshot = storage.snapshot()
                for (slot, content) in snapshot {
                    let label = storage.getLabel(slot) ?? ""
                    results.append(SlotGlobalSearchResult(
                        pageId: page.id,
                        pageName: page.name,
                        groupId: group.id,
                        groupName: group.name,
                        slot: slot,
                        content: content,
                        label: label,
                        pageOrder: page.order,
                        groupOrder: group.order
                    ))
                }
            }
        }

        return results
    }
}

// MARK: - v2.7.33 HTML Text Extractor

private enum HTMLTextExtractor {
    static func plainText(from html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              ) else { return html }
        return attr.string
    }
}

// MARK: - v2.7.33 Config Normalizer

private extension AppConfig {
    func normalizedForRuntime() -> AppConfig {
        var copy = self
        copy.saveKey = HotkeyTemplateNormalizer.normalizedShortcut(saveKey, allowsSlotPlaceholder: true)
        copy.pasteKey = HotkeyTemplateNormalizer.normalizedShortcut(pasteKey, allowsSlotPlaceholder: true)
        copy.radialKey = HotkeyTemplateNormalizer.normalizedShortcut(radialKey, allowsSlotPlaceholder: false)
        return copy
    }
}

// MARK: - v2.7.34 HTML String Helpers

private extension String {
    func clipSlotsPlainTextFromHTML() -> String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clipSlotsHTMLPreviewSummary(fallback: String) -> String {
        let text = clipSlotsPlainTextFromHTML()
        if !text.isEmpty { return text }
        return fallback.isEmpty ? "[HTML]" : fallback
    }
}

enum AppearanceDefaults {
    static func ensureDefaultDarkIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "appearanceMode") == nil else { return }
        defaults.set(ThemeMode.dark.rawValue, forKey: "appearanceMode")
    }
}
