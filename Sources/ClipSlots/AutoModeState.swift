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

    // P1-6 (v2.10.34): 三档开关的 getter 此前直接读 @Published 底层存储 `_autoXxxEnabled`，而 setter
    // 在主线程写。后台线程（剪贴板等待、全局键盘事件回调等）会频繁读取这些开关——对同一存储的
    // 非同步跨线程读/写属 data race（TSan 可报、极端时序下可读到撕裂/过期值）。这里用一把轻量
    // NSLock 保护一份「纯值镜像」：所有读走镜像（线程安全、不触发 SwiftUI），写时先同步更新镜像，
    // 再切主线程更新 @Published / UserDefaults。镜像与 @Published 始终由 setter 一起推进，二者一致。
    private let stateLock = NSLock()
    private var autoStoreValue: Bool
    private var autoPasteValue: Bool
    private var autoAdvanceValue: Bool

    private func lockedRead(_ read: () -> Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return read()
    }

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

    private enum LinkedMode: Equatable {
        case store, paste
    }

    /// 处理自动存储/自动粘贴的一次真实状态变化，并把自动切换同步到该事件的新值。
    /// 联动只发生在这两个明确 setter 的 false↔true transition；初始化直接写底层值，
    /// autoAdvance 的手动 setter 也不会反向影响它们，因此不是持续绑定。
    private func setLinkedMode(_ mode: LinkedMode, to newValue: Bool) {
        stateLock.lock()
        let oldValue = mode == .store ? autoStoreValue : autoPasteValue
        guard oldValue != newValue else {
            stateLock.unlock()
            return
        }
        if mode == .store { autoStoreValue = newValue }
        else { autoPasteValue = newValue }
        let advanceChanged = autoAdvanceValue != newValue
        if advanceChanged { autoAdvanceValue = newValue }
        stateLock.unlock()

        writeOnMain {
            if mode == .store {
                self._autoStoreEnabled = newValue
                self.defaults.set(newValue, forKey: Keys.autoStore)
            } else {
                self._autoPasteEnabled = newValue
                self.defaults.set(newValue, forKey: Keys.autoPaste)
            }
            // 目标已是期望值时不发布、也不重复写 UserDefaults。
            if advanceChanged {
                self._autoAdvanceEnabled = newValue
                self.defaults.set(newValue, forKey: Keys.autoAdvance)
            }
        }
    }

    var autoStoreEnabled: Bool {
        get { lockedRead { self.autoStoreValue } }
        set { setLinkedMode(.store, to: newValue) }
    }

    var autoPasteEnabled: Bool {
        get { lockedRead { self.autoPasteValue } }
        set { setLinkedMode(.paste, to: newValue) }
    }

    var autoAdvanceEnabled: Bool {
        get { lockedRead { self.autoAdvanceValue } }
        set {
            stateLock.lock()
            guard autoAdvanceValue != newValue else {
                stateLock.unlock()
                return
            }
            autoAdvanceValue = newValue
            stateLock.unlock()
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
        let store = defaults.bool(forKey: Keys.autoStore)
        let paste = defaults.bool(forKey: Keys.autoPaste)
        // 自动切换：首次安装 / 无历史值时默认【关闭】。
        // 仅当 key 不存在（全新安装）时使用 false；已有用户在 UserDefaults 中的历史选择照常
        // 读取，绝不覆盖。
        let advance: Bool
        if defaults.object(forKey: Keys.autoAdvance) == nil {
            advance = false
        } else {
            advance = defaults.bool(forKey: Keys.autoAdvance)
        }
        self._autoStoreEnabled = store
        self._autoPasteEnabled = paste
        self._autoAdvanceEnabled = advance
        // P1-6 (v2.10.34): 同步初始化纯值镜像，使 getter 从构造起即返回正确值。
        self.autoStoreValue = store
        self.autoPasteValue = paste
        self.autoAdvanceValue = advance
    }
}
