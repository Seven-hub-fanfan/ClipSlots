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

    // AU-2 (v2.10.15): @Published 写入（objectWillChange 的触发）必须发生在主线程。历史方案
    // 仅把 UserDefaults 副作用切回主线程并在 debug 断言，但 release 下后台线程（剪贴板等待 /
    // 键盘事件回调等）直接赋值仍会让 objectWillChange 在非主线程触发，导致 SwiftUI 更新时序
    // 异常甚至崩溃。改为：底层用私有 @Published 存储真正的值，公开属性保持可写 var（因此
    // `$autoMode.xxx` 经 ObservedObject 的 keyPath 依旧生成 Binding，公开 API 不变），其 setter
    // 统一切回主线程后再改写底层存储 + 持久化，使 objectWillChange 恒在主线程触发。
    @Published private var _autoStoreEnabled: Bool
    @Published private var _autoPasteEnabled: Bool
    @Published private var _autoAdvanceEnabled: Bool

    /// 保证闭包在主线程执行：已在主线程则同步执行（避免多余派发与时序问题），
    /// 否则切回主线程异步执行，从而让后台线程调用方也安全。
    private func writeOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

    var autoStoreEnabled: Bool {
        get { _autoStoreEnabled }
        set {
            writeOnMain {
                self._autoStoreEnabled = newValue
                self.defaults.set(newValue, forKey: Keys.autoStore)
            }
        }
    }

    var autoPasteEnabled: Bool {
        get { _autoPasteEnabled }
        set {
            writeOnMain {
                self._autoPasteEnabled = newValue
                self.defaults.set(newValue, forKey: Keys.autoPaste)
            }
        }
    }

    var autoAdvanceEnabled: Bool {
        get { _autoAdvanceEnabled }
        set {
            writeOnMain {
                self._autoAdvanceEnabled = newValue
                self.defaults.set(newValue, forKey: Keys.autoAdvance)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // AU-2 (v2.10.15): 初始化阶段直接写入底层 @Published 存储（构造发生在主线程、此时尚无
        // 观察者），无需经过切主线程的 setter。
        // 自动存储 / 自动粘贴：默认关闭（key 不存在 → false）
        self._autoStoreEnabled = defaults.bool(forKey: Keys.autoStore)
        self._autoPasteEnabled = defaults.bool(forKey: Keys.autoPaste)
        // 自动切换：首次安装 / 无历史值时默认【开启】。
        // v2.10.33: 用户明确要求自动切换默认打开（自动存储/自动粘贴仍默认关闭不变）。
        // 仅当 key 不存在（全新安装）时用 true；已有用户在 UserDefaults 中的历史选择照常
        // 读取，绝不覆盖。
        if defaults.object(forKey: Keys.autoAdvance) == nil {
            self._autoAdvanceEnabled = true
        } else {
            self._autoAdvanceEnabled = defaults.bool(forKey: Keys.autoAdvance)
        }
    }
}
