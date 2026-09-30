import SwiftUI
import AppKit
import ClipSlotsKit

/// 画布的滚轮 / 中键 / 键盘输入路由（v2.11.7 hotfix17、hotfix18 扩展键盘）。
///
/// ## 为什么需要它
///
/// SwiftUI 在 macOS 上没有任何原生手势能表达这两件事：
///   - **滚轮**：`DragGesture` 收不到 `scrollWheel`；把画布塞进 `ScrollView` 又会失去无限画布语义
///     （内容尺寸未知、缩放后滚动区间要重算，而且和 `scaleEffect` 打架）。
///   - **鼠标中键**：SwiftUI 只有左键语义，`otherMouseDown/Dragged/Up` 完全不可见。
///
/// ## 为什么监听器挂在这个 `ObservableObject` 上，而不是挂在 NSView 里
///
/// 第一版把 `NSEvent.addLocalMonitorForEvents` 装在自定义 `NSView.viewDidMoveToWindow` 里，
/// **实测有 bug**：日志显示那个 NSView 每秒被 SwiftUI 摘下再挂上一次（本项目主 store 单一
/// `@Published` 导致的整树重建，是已知技术债），于是监听器跟着反复安装/卸载，
/// 落在空窗期的滚轮与中键事件**全部丢失** —— 表现就是「滚一下有反应，再滚就没反应了」。
///
/// 现在监听器的寿命由 `@StateObject` 持有的这个对象决定（视图重建不影响它），NSView 退化为
/// 纯粹的**几何参照物**：提供画布区域的 bounds 与窗口坐标换算。谁被重挂都不再影响事件流。
///
/// ## 为什么 NSView 对鼠标透明
///
/// AppKit 的 `hitTest` 只认真实 subview，SwiftUI 自绘内容不是 subview —— 任何可命中的 AppKit
/// 子视图都会在命中判定上赢过它上面的节点卡片和浮动按钮。所以锚点视图 `hitTest` 直接返回 nil。
final class CanvasInputRouter: ObservableObject {
    /// (scrollDeltaX, scrollDeltaY, 是否精确滚动增量, 是否按下 Command, 光标在画布坐标系中的位置)
    var onScroll: ((CGFloat, CGFloat, Bool, Bool, CGPoint) -> Void)?
    /// 中键拖动的**增量**位移（画布屏幕空间，y 向下为正）。
    var onMiddleDrag: ((CGSize) -> Void)?
    /// 中键松开。
    var onMiddleDragEnded: (() -> Void)?
    /// 键盘动作（Delete / Cmd+Z / Cmd+Shift+Z）。返回 true 表示已消费，事件不再下派。
    var onKeyAction: ((CanvasKeyBinding.Action) -> Bool)?
    var blocksCanvasInput: (() -> Bool)?
    var usesHandTool: (() -> Bool)?
    var onPointer: ((NSEvent, CGPoint) -> Bool)?
    var canPanAt: ((CGPoint) -> Bool)?
    var onCancelPointer: (() -> Void)?
    var allowsEditorFocus: (() -> Bool)?
    /// 非发布属性：光标移动本身无需触发任何 SwiftUI 更新。
    var cursorPoint: CGPoint = .zero

    /// 几何参照物。弱引用：视图随时可能被 SwiftUI 摘掉，路由器不该把它吊住。
    weak var anchorView: NSView?

    private var monitor: Any?
    private var middleDragging = false
    private var lastMiddlePoint: CGPoint = .zero
    /// 一次滚轮/触控板平移手势是否已经归属给画布。
    ///
    /// v2.16.4：此前每个 scrollWheel 事件都会重新命中测试。如果长距离双指平移时光标扫过
    /// 左侧槽位库里的 `NSScrollView`，事件会突然改派给列表，画布平移当场中断。设计类画布（TapNow /
    /// Figma / Freeform）更接近「手势开始归谁，结束前就一直归谁」；所以这里在画布消费首帧后锁定
    /// 本次滚动序列，直到系统发出 ended/cancelled，或一小段时间内没有后续滚轮事件。
    private var scrollLockedToCanvas = false
    private var scrollUnlockWork: DispatchWorkItem?
    private var spaceHeld = false
    private var spaceDragging = false
    private var resignObserver: NSObjectProtocol?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .otherMouseDown, .otherMouseDragged, .otherMouseUp,
                       .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .keyUp]
        ) { [weak self] event in
            guard let self else { return event }
            let consumed = self.handle(event)
            // #region debug-point A:window-button-routing
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_WINDOW_PROBE"] == "1", event.type == .leftMouseDown || event.type == .leftMouseUp { var r = URLRequest(url: URL(string: "http://127.0.0.1:7786/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "window-lifecycle", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "A", "msg": "[DEBUG] window button pointer routing", "data": ["type": event.type.rawValue, "point": NSStringFromPoint(event.locationInWindow), "consumed": consumed, "contentHit": String(describing: event.window?.contentView?.hitTest(event.locationInWindow)), "frameHit": String(describing: event.window?.contentView?.superview?.hitTest(event.locationInWindow)), "inCanvas": self.anchorView.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false]]); URLSession.shared.dataTask(with: r).resume() }
            #endif
            // #endregion
            // #region debug-point B-C:control-delivery
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_CONTROL_PROBE"] == "1", event.type == .leftMouseDown || event.type == .leftMouseUp { var r = URLRequest(url: URL(string: "http://127.0.0.1:7784/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "slot-input-controls", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "B-C", "msg": "[DEBUG] native control delivery", "data": ["type": event.type.rawValue, "point": NSStringFromPoint(event.locationInWindow), "consumed": consumed, "key": event.window?.isKeyWindow ?? false, "active": NSApp.isActive, "hit": String(describing: event.window?.contentView?.hitTest(event.locationInWindow))]]); URLSession.shared.dataTask(with: r).resume() }
            #endif
            // #endregion
            return consumed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // #region debug-point B:resign
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7780/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-overlay-hit", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "B", "msg": "[DEBUG] window resign", "data": ["window": (notification.object as? NSWindow)?.windowNumber ?? -1, "anchor": self?.anchorView?.window?.windowNumber ?? -1]]); URLSession.shared.dataTask(with: r).resume() }
            #endif
            // #endregion
            guard let self, notification.object as? NSWindow === self.anchorView?.window else { return }
            self.resetHand()
            self.onCancelPointer?()
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        scrollUnlockWork?.cancel()
        scrollLockedToCanvas = false
        middleDragging = false
        resetHand()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    deinit { stop() }

    private func resetHand() {
        if spaceHeld { NSCursor.pop() }
        if spaceDragging || middleDragging { onMiddleDragEnded?() }
        spaceHeld = false
        spaceDragging = false
        middleDragging = false
    }

    #if DEBUG
    func routeForRegression(_ event: NSEvent) -> Bool { handle(event) }
    #endif

    /// 返回 true 表示事件已被画布吃掉，不再往下派发。
    private func handle(_ event: NSEvent) -> Bool {
        guard let anchor = anchorView,
              let window = anchor.window,
              // 只处理落在**本窗口**的事件：App 还有 HUD / 圆盘等其它窗口，
              // 一个全局 monitor 若不做窗口过滤，会把它们的滚轮也算成画布平移。
              event.window === window
        else { return false }

        // v2.17.5: 修复「最小化按钮点不动 / 点击程序坞图标唤不回窗口」。
        // v2.17.4 起本 monitor 开始拦截 `.leftMouseDown`，它是全 App 级 local monitor：
        // **先于** AppKit 的 sendEvent 触发，返回 nil 就把事件吞掉。画布模式下窗口开着
        // `fullSizeContentView`，红绿灯（miniaturize / close / zoom）和标题栏拖拽区都
        // 浮在画布之上，坐标同样会落进 anchor.bounds；只要 `handle` 里任意一个分支返回 true，
        // 那些系统按钮当场失灵，用户体感就是「最小化没反应」。
        //
        // 判据：`contentView.hitTest` 只认 contentView 的 subview 树，红绿灯挂在 titlebar
        // container 上 → 对这些点位返回 nil。命中 nil = 事件不属于 SwiftUI 内容层，一律放行，
        // 交回 AppKit 默认路由，标题栏拖拽、红绿灯、resize 边框都能正常工作。
        if event.type == .leftMouseDown,
           window.contentView?.hitTest(event.locationInWindow) == nil {
            return false
        }

        let local = anchor.convert(event.locationInWindow, from: nil)
        // #region debug-point A:router
        #if DEBUG
        if event.type == .leftMouseDown, ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7777/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-pointer-routing", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "A", "msg": "[DEBUG] router", "data": ["local": NSStringFromPoint(local), "bounds": NSStringFromRect(anchor.bounds)]]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
        if event.type == .keyUp, event.keyCode == 49 {
            let consumed = spaceHeld
            resetHand()
            return consumed
        }
        guard window.attachedSheet == nil else { return false }
        if blocksCanvasInput?() == true {
            resetHand()
            if event.type == .keyDown, event.keyCode == 53 {
                return onKeyAction?(.cancel) ?? false
            }
            // 模态层自行处理点击、滚轮；键盘不再穿透到节点。
            return event.type == .keyDown
        }

        switch event.type {
        case .leftMouseDown:
            cursorPoint = local
            if allowsEditorFocus?() != false,
               let editor = editorUnderPointer(in: window.contentView, point: local, anchor: anchor) {
                // SwiftUI 的浮层宿主有时先吃掉 first mouse；焦点按实际 NSTextView 几何补齐。
                // 事件继续下派，文本系统仍负责插入点、拖选和输入法。
                window.makeFirstResponder(editor)
                return false
            }
            guard spaceHeld || usesHandTool?() == true, anchor.bounds.contains(local),
                  canPanAt?(local) != false,
                  !pointerIsOverScrollView(event, window: window) else { return onPointer?(event, local) ?? false }
            spaceDragging = true
            lastMiddlePoint = local
            NSCursor.closedHand.set()
            return true
        case .leftMouseDragged:
            guard spaceDragging else { return onPointer?(event, local) ?? false }
            onMiddleDrag?(CGSize(width: local.x - lastMiddlePoint.x,
                                 height: local.y - lastMiddlePoint.y))
            lastMiddlePoint = local
            return true
        case .leftMouseUp:
            guard spaceDragging else { return onPointer?(event, local) ?? false }
            spaceDragging = false
            onMiddleDragEnded?()
            NSCursor.openHand.set()
            return true
        case .scrollWheel:
            guard anchor.bounds.contains(local) || scrollLockedToCanvas else { return false }
            // 光标停在左侧槽位库上时，普通单次滚动应该滚那个列表而不是平移画布；
            // 但如果这一串滚动手势已经由画布接手，就继续交给画布，避免长距离双指平移
            // 扫过侧栏时突然中断。
            if !scrollLockedToCanvas && pointerIsOverScrollView(event, window: window) { return false }
            scrollLockedToCanvas = true
            scheduleScrollUnlock(for: event)
            onScroll?(event.scrollingDeltaX,
                      event.scrollingDeltaY,
                      event.hasPreciseScrollingDeltas,
                      event.modifierFlags.contains(.command),
                      local)
            return true

        case .otherMouseDown:
            // buttonNumber 2 = 中键。侧键（3/4）不参与，免得误触发平移。
            guard event.buttonNumber == 2, anchor.bounds.contains(local) else { return false }
            middleDragging = true
            lastMiddlePoint = local
            return true

        case .otherMouseDragged:
            guard middleDragging else { return false }
            // 位移用两点相减算，不用 `event.deltaY` —— 后者在不同输入设备
            //（鼠标 / 触控板 / 远程桌面）上的符号与缩放不一致。
            let delta = CGSize(width: local.x - lastMiddlePoint.x,
                               height: local.y - lastMiddlePoint.y)
            lastMiddlePoint = local
            onMiddleDrag?(delta)
            return true

        case .otherMouseUp:
            guard middleDragging else { return false }
            middleDragging = false
            onMiddleDragEnded?()
            return true

        case .keyDown:
            // 正在编辑文本时一律放行。Delete 在文本框里是「删一个字符」，Cmd+Z 是「撤销一次输入」；
            // 这两件事必须让文本系统自己处理，否则用户在节点里改 prompt 时按退格会把整个节点删掉
            // —— 这是不可撤回的破坏性误伤，不能靠事后 undo 兜。
            guard !isEditingText(window: window) else { return false }
            guard !event.modifierFlags.contains(.control) else { return false }
            if event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .shift]).isEmpty {
                if !spaceHeld { spaceHeld = true; NSCursor.openHand.push() }
                return true
            }
            let action = CanvasKeyBinding.action(keyCode: event.keyCode,
                                                command: event.modifierFlags.contains(.command),
                                                shift: event.modifierFlags.contains(.shift),
                                                option: event.modifierFlags.contains(.option))
            guard action != .none else { return false }
            return onKeyAction?(action) ?? false

        default:
            return false
        }
    }

    /// 焦点是否落在可编辑文本上。
    ///
    /// 判 `NSText.isEditable` 而不是判类型：SwiftUI 的 `TextField` 在获得焦点时把窗口的 field editor
    /// （一个 `NSTextView`）设成 first responder，`TextEditor` 直接就是 `NSTextView`，两者都被这条
    /// 覆盖；而只读的富文本展示视图（`isEditable == false`）不该拦住画布快捷键。
    private func isEditingText(window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let text = responder as? NSText { return text.isEditable }
        return false
    }

    private func editorUnderPointer(in view: NSView?, point: CGPoint, anchor: NSView) -> NSTextView? {
        guard let view, !view.isHiddenOrHasHiddenAncestor else { return nil }
        for child in view.subviews.reversed() {
            if let editor = editorUnderPointer(in: child, point: point, anchor: anchor) { return editor }
        }
        guard let editor = view as? NSTextView, editor.isEditable,
              editor.visibleRect.width > 0, editor.visibleRect.height > 0,
              anchor.convert(editor.visibleRect, from: editor).contains(point) else { return nil }
        return editor
    }

    private func scheduleScrollUnlock(for event: NSEvent) {
        scrollUnlockWork?.cancel()
        if event.phase.contains(.ended) || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            scrollLockedToCanvas = false
            scrollUnlockWork = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.scrollLockedToCanvas = false
            self?.scrollUnlockWork = nil
        }
        scrollUnlockWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// 光标是否停在某个 `NSScrollView`（= SwiftUI `ScrollView`）之上。
    ///
    /// 按「命中点往上找 NSScrollView 祖先」判定，而不是按坐标硬算槽位库面板的矩形：
    /// 面板的宽高、展开状态、以后新增的滚动区域都不需要同步到这里。
    private func pointerIsOverScrollView(_ event: NSEvent, window: NSWindow) -> Bool {
        guard let hit = window.contentView?.hitTest(event.locationInWindow) else { return false }
        var node: NSView? = hit
        while let current = node {
            if current is NSScrollView { return true }
            node = current.superview
        }
        return false
    }
}

/// 画布的几何锚点视图：只为路由器提供 bounds 与坐标换算，对鼠标完全透明。
struct CanvasInputAnchor: NSViewRepresentable {
    let router: CanvasInputRouter

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        router.anchorView = view
        router.start()
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        // 视图被 SwiftUI 重建时重新登记，路由器始终指向当前活着的那一个。
        router.anchorView = nsView
        // 自愈：`start()` 幂等。万一 SwiftUI 只调了 onDisappear 而没有再调 onAppear
        //（视图被复用而非重建时会发生），监听器也能在下一次 body 时恢复，不会静默失效。
        router.start()
    }

    final class AnchorView: NSView {
        /// 与 SwiftUI 对齐：y 向下为正。`CanvasGeometry` 的全部公式都建立在左上原点、y 向下之上。
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
