import SwiftUI
import ClipSlotsKit

/// 皮肤的运行时持有者（v2.11.7）。
///
/// 为什么不能像 `ThemeMode` 那样只靠 `@AppStorage` + dynamic NSColor？
/// ------------------------------------------------------------------
/// 深浅色切换之所以能做到「不重算 body、只重绘」，是因为颜色 token 是 `NSColor(name:dynamicProvider:)`
/// 包出来的动态色，**系统 appearance 变化本身就会让所有图层重绘**，重绘时 provider 自然解析出新值。
///
/// 皮肤不一样：它是我们自己的一个全局变量，改了它系统不会知道，也就没有任何东西被标记为「需要重绘」。
/// 如果只把皮肤塞进 provider 闭包里，切换后只有恰好因别的原因重绘的视图会变色，
/// 屏幕上会出现一半新皮肤一半旧皮肤的花屏。所以皮肤切换必须**显式让视图树重建一次**：
/// `ContentView` 用 `.id(skin)` 承接，代价是一次性的整树重建（切皮肤是低频显式操作，可以接受）。
///
/// 另一方面，AppKit 侧的界面（圆盘窗口、悬浮提示、NSAlert）不在 SwiftUI 树里，靠
/// `.appSkinDidChange` 通知自行刷新。
enum AppSkinCenter {

    /// 当前皮肤。绘制路径上会被高频读取（每个 token 一次），所以是内存里的缓存值，
    /// 不是每次都去读 UserDefaults——`UserDefaults.string(forKey:)` 在卡片网格里每帧要跑上百次。
    private(set) static var current: AppSkin = AppSkin.load(from: .standard)

    /// 皮肤变更通知。SwiftUI 侧靠 `@AppStorage` + `.id()` 自动重建，这个通知是给 AppKit 侧用的。
    static let didChangeNotification = Notification.Name("ClipSlotsAppSkinDidChange")

    /// 显式切换皮肤（设置页 / 工具栏入口调用）。
    ///
    /// 先更新内存缓存再写盘：`@AppStorage` 的 setter 会同步触发依赖它的视图重建，
    /// 若此时缓存还是旧值，重建出来的第一帧会用旧皮肤画，紧接着又被通知刷一次——闪一下。
    static func apply(_ skin: AppSkin) {
        guard skin != current else { return }
        current = skin
        skin.store(in: .standard)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// 跟随外部写入（比如别的进程或调试时直接改 defaults）刷新缓存。
    /// 与 `AppDelegate.startObservingAppearancePreference` 同样的路子：只在原始值真的变了才动。
    static func syncFromDefaults() {
        let stored = AppSkin.load(from: .standard)
        guard stored != current else { return }
        current = stored
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
