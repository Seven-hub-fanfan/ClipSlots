import AppKit

/// 全局热键 / 圆盘菜单 → 画布的单向桥（v2.11.7 hotfix18）。
///
/// ## 为什么需要一层桥
///
/// Cmd+1~0 是 Carbon 全局热键（`HotKeyManager` 里 `RegisterEventHotKey`），回调落在
/// `AppDelegate`；圆盘菜单的扇区确认回调也落在 `AppDelegate`。而「当前选中了哪个画布节点」
/// 这件事只有画布视图树知道 —— `AppDelegate` 既拿不到 `CanvasStore`，也不该去认识它
/// （AppDelegate 已经是本项目最重的耦合点之一，再往里塞画布依赖等于让画布无法独立演进）。
///
/// 所以反过来：**画布视图在上台时把「怎么处理一次槽位命令」这段能力登记进来，下台时撤掉。**
/// `AppDelegate` 只需要问一句「这次槽位命令有人接吗」，接了就收手。
///
/// ## 可见性与命令目标
///
/// handler 只表示画布已挂载；缩到程序坞、隐藏或切到其他 App 时它仍然存在。
/// 每次派发都读取真实窗口状态，只有前台画布主窗口可以消费命令。
///
/// ## 线程契约
///
/// 刻意**不标 `@MainActor`**：唯一的调用方是 Carbon 全局热键回调与圆盘菜单回调，两者都在
/// `AppDelegate` 里以同步 nonisolated 上下文运行（那条链路是 C 回调，加不了 actor 标注）。
/// 若这个类标了 `@MainActor`，调用点就只能包一层 `DispatchQueue.main.async`，把一次同步的
/// 「画布接不接这个键」判断变成异步 —— 而调用方必须**立即**知道结果才能决定要不要继续走
/// 剪贴板粘贴。异步化会让两条路径都执行一遍（画布填了节点，剪贴板也被改了）。
///
/// 所以约定：本类的读写只允许发生在主线程。上述两个回调本身就在主线程，登记/撤销登记发生在
/// SwiftUI 的 onAppear/onDisappear（同样是主线程），契约天然成立。
final class CanvasCommandBridge {
    static let shared = CanvasCommandBridge()
    private init() {}

    /// 画布视图登记的槽位命令处理器。返回 true = 本次命令已由画布消费，调用方不要再走剪贴板粘贴。
    var slotCommandHandler: ((Int) -> Bool)?
    /// Resolve the live canvas window at dispatch time; onAppear can precede attachment.
    var commandWindowProvider: (() -> NSWindow?)?

    var acceptsSlotCommands: Bool {
        guard slotCommandHandler != nil, NSApp.isActive,
              let window = commandWindowProvider?() else { return false }
        return window.isVisible && !window.isMiniaturized && window.isOnActiveSpace
            && NSApp.keyWindow === window
    }

    /// 尝试把一次「取第 N 槽位」的命令交给画布。
    func handleSlotCommand(_ slot: Int) -> Bool {
        guard acceptsSlotCommands,
              let handler = slotCommandHandler else { return false }
        return handler(slot)
    }
}
