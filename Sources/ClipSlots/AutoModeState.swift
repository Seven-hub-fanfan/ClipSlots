import Combine
import Foundation

// MARK: - Auto Mode State (v2.10.0)
//
// 三档金属拨杆的共享开关状态。每个开关持久化到 UserDefaults，App 重启后保留。
//
// - autoStoreEnabled  拨杆1「自动存储」：Opt+1 触发时，把剪贴板写入下一个空槽（而非固定槽位1）
// - autoPasteEnabled  拨杆2「自动粘贴」：Cmd+1 触发时，从读游标取下一个非空槽粘贴（而非固定槽位1）
// - autoAdvanceEnabled 拨杆3「自动切换」：ON = 自动存储/粘贴与粘贴后推进可跨组/跨页；OFF = 只在当前组内推进
//
// 说明：拨杆3 统一收编了历史上分散在 SlotSearchBar 里的「自动切换」开关，
// 复用同一个 UserDefaults key `autoAdvanceEnabled`，因此两处 UI 始终同步。
final class AutoModeState: ObservableObject {
    static let shared = AutoModeState()

    // UserDefaults keys（复用 UserPreferenceKeys 常量，保持单一事实来源）。
    enum Keys {
        static let autoStore = UserPreferenceKeys.autoStoreEnabled
        static let autoPaste = UserPreferenceKeys.autoPasteEnabled
        static let autoAdvance = UserPreferenceKeys.autoAdvanceEnabled
    }

    private let defaults: UserDefaults

    @Published var autoStoreEnabled: Bool {
        // P2-2: ensure the UserDefaults side-effect runs on the main thread.
        didSet {
            // P2-8 (v2.10.9): @Published mutation must occur on the main thread —
            // objectWillChange fires synchronously here, and SwiftUI observers
            // updating off-main is undefined behavior. Assert in debug to catch a
            // background-thread assignment at its source (no-op in release, so
            // behavior is identical when already on main).
            assert(Thread.isMainThread, "AutoModeState.autoStoreEnabled must be mutated on the main thread")
            let v = autoStoreEnabled
            if Thread.isMainThread { defaults.set(v, forKey: Keys.autoStore) }
            else { DispatchQueue.main.async { self.defaults.set(v, forKey: Keys.autoStore) } }
        }
    }

    @Published var autoPasteEnabled: Bool {
        // P2-2: ensure the UserDefaults side-effect runs on the main thread.
        didSet {
            // P2-8 (v2.10.9): @Published mutation must occur on the main thread (see
            // autoStoreEnabled). Assert in debug; no-op in release.
            assert(Thread.isMainThread, "AutoModeState.autoPasteEnabled must be mutated on the main thread")
            let v = autoPasteEnabled
            if Thread.isMainThread { defaults.set(v, forKey: Keys.autoPaste) }
            else { DispatchQueue.main.async { self.defaults.set(v, forKey: Keys.autoPaste) } }
        }
    }

    @Published var autoAdvanceEnabled: Bool {
        // P2-2: ensure the UserDefaults side-effect runs on the main thread.
        didSet {
            // P2-8 (v2.10.9): @Published mutation must occur on the main thread (see
            // autoStoreEnabled). Assert in debug; no-op in release.
            assert(Thread.isMainThread, "AutoModeState.autoAdvanceEnabled must be mutated on the main thread")
            let v = autoAdvanceEnabled
            if Thread.isMainThread { defaults.set(v, forKey: Keys.autoAdvance) }
            else { DispatchQueue.main.async { self.defaults.set(v, forKey: Keys.autoAdvance) } }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 自动存储 / 自动粘贴：默认关闭（key 不存在 → false）
        self.autoStoreEnabled = defaults.bool(forKey: Keys.autoStore)
        self.autoPasteEnabled = defaults.bool(forKey: Keys.autoPaste)
        // 自动切换：默认开启（key 不存在时回退到 true）
        if defaults.object(forKey: Keys.autoAdvance) == nil {
            self.autoAdvanceEnabled = true
        } else {
            self.autoAdvanceEnabled = defaults.bool(forKey: Keys.autoAdvance)
        }
    }
}
