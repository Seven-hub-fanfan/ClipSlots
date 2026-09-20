import SwiftUI
import AppKit

/// 画布的 **TapNow 皮肤**（v2.16.0）——一处集中的视觉常量表。
///
/// ## 为什么是独立一套 token，而不是继续用 `AppTheme`
///
/// `AppTheme` 是**双皮肤 × 双色彩模式**的矩阵（`colorful/minimal` × `light/dark`），
/// 每个颜色都得在四个格子里都说得通。画布不是这样的地方：它是一块**摄影棚**——
/// TapNow / Figma 暗色 / Crate 全都是"永远深色、内容自己发光"，因为画布上的主角是
/// 用户的图片和视频，任何浅色底都会把媒体的对比度吃掉一半。
///
/// 所以这套 token **不随系统色彩模式变**。这不是偷懒，是刻意：v2.15.0 之前画布跟着
/// `AppTheme.canvasSurface` 走，浅色模式下同一张卡要在 `#F5F5F7` 和 `#1B1C1F` 两种底上
/// 都好看，结果两边都只能算"能看"。
///
/// ## 数值来源
///
/// 全部**实测**自本机安装的 TapNow.app（Retina 2x 截图 → 逐像素采样 → 除 2 换算成点）：
/// 画布底 `#000000`、点阵间距 16pt / 直径 1.2pt / 色 `#4A4A4A`、卡片圆角 12pt、
/// 空卡填充 `#1F1F1F`（选中 `#343434`）、名签 `#939393`、连线 `#909090` 1pt、
/// 工具条 44pt 高 / `#1E1E1E`、端口圆 18pt / 圆心距卡边 28pt。
///
/// ## 三条实测得到的**反直觉**结论（它们是这一版返工的主因）
///
/// 1. **卡片在任何状态下都没有描边** —— idle / hover / 选中三张截图在卡片边界处逐像素相同。
///    我第一眼以为看到了"选中高亮环"，实际是图片自身亮部贴着纯黑底产生的错觉。
///    选中与否靠**工具条和端口出现**来表达，卡片本身永远是一块干净的圆角媒体。
/// 2. **连线没有箭头、没有端点圆、没有流动虚线**，就是一条 1pt 灰线。v2.15.0 我按"节点编辑器
///    常识"加的箭头 + 起点圆 + 运行流动虚线，方向正好是反的。
/// 3. **拖动节点不吸附网格** —— 实测卡片左边缘落在 16pt 网格的非整数倍上。吸附是 ClipSlots
///    "不丝滑"的一大来源：每一步都在最近格点上跳。
enum TapSkin {

    // MARK: - 画布

    /// 画布底：纯黑。不是 `#0A0A0A` 之类的"近黑"——实测就是 0,0,0。
    /// 纯黑的意义在于媒体卡的圆角不需要抗锯齿混色，边缘看起来是刀切的。
    static let void = Color.black

    /// 点阵网格颜色。`#4A4A4A` 看着很亮，但点只有 1.2pt，视觉密度极低。
    static let gridDot = Color(red: 0.29, green: 0.29, blue: 0.29)
    /// 网格间距（画布坐标，会随 zoom 缩放）。
    static let gridStep: CGFloat = 16
    /// 点直径。低于 1pt 在非 Retina 上会被抹掉，高于 1.5pt 就开始"有颗粒感"。
    static let gridDotSize: CGFloat = 1.2

    // MARK: - 卡片

    static let cardRadius: CGFloat = 12
    /// 空卡填充（没有媒体时那块灰）。
    static let cardEmptyFill = Color(red: 0.122, green: 0.122, blue: 0.122)     // #1F1F1F
    /// 选中时空卡提亮一档。实测 `#343434`——这是**唯一**一处选中态改了卡片本身的地方，
    /// 而且只在空卡上看得出来（有媒体时媒体自己盖住了填充）。
    static let cardEmptySelectedFill = Color(red: 0.204, green: 0.204, blue: 0.204) // #343434
    /// 空态中心 glyph。
    static let cardEmptyGlyph = Color(red: 0.42, green: 0.42, blue: 0.42)
    static let cardEmptyGlyphSize: CGFloat = 24

    // MARK: - 名签（卡片外、上方）

    static let tagInk = Color(red: 0.576, green: 0.576, blue: 0.576)            // #939393
    /// hover / 选中时名签提亮。TapNow 实测 hover 态名签明显比 idle 亮。
    static let tagInkActive = Color(red: 0.902, green: 0.902, blue: 0.902)      // #E6E6E6
    static let tagFontSize: CGFloat = 11
    static let tagGlyphSize: CGFloat = 10.5
    /// 名签基线到卡片顶的间距。
    static let tagGap: CGFloat = 6
    static let tagHeight: CGFloat = 14

    // MARK: - 连线

    static let edgeInk = Color(red: 0.565, green: 0.565, blue: 0.565)           // #909090
    static let edgeInkActive = Color(red: 0.902, green: 0.902, blue: 0.902)
    static let edgeWidth: CGFloat = 1
    static let edgeWidthActive: CGFloat = 1.4
    /// 命中带半宽。线只有 1pt，靠视觉宽度去点是点不中的；这一条与视觉宽度**刻意脱钩**。
    static let edgeHitSlop: CGFloat = 7

    // MARK: - 端口

    static let portDiameter: CGFloat = 18
    /// 端口圆心到卡片边缘的距离。实测 29pt，取 28。
    static let portOffset: CGFloat = 28
    static let portStroke = Color(red: 0.541, green: 0.541, blue: 0.541)
    static let portStrokeActive = Color.white
    static let portStrokeWidth: CGFloat = 1.4
    static let portGlyphSize: CGFloat = 9

    // MARK: - 工具条 / 浮层

    static let chromeFill = Color(red: 0.118, green: 0.118, blue: 0.118)       // #1E1E1E
    static let chromeInk = Color(red: 0.941, green: 0.941, blue: 0.941)
    static let chromeInkDim = Color(red: 0.62, green: 0.62, blue: 0.62)
    static let chromeDivider = Color(red: 0.29, green: 0.29, blue: 0.29)
    static let toolbarHeight: CGFloat = 44

    /// 画布走 `fullSizeContentView`（黑到窗口顶边，见 `CanvasWindowAppearancePin`）之后，
    /// 窗口顶部这 28pt 归标题栏所有：红绿灯画在这里，点这里是拖窗口而不是点内容。
    /// 所以画布上的 chrome（侧栏、项目切换器、右上按钮）都要从这条线以下开始排，
    /// 而网格与节点照旧 full-bleed 铺到顶边 —— TapNow 就是这样：点阵到顶，控件避开。
    static let titlebarInset: CGFloat = 28
    static let toolbarRadius: CGFloat = 22
    static let toolbarIconSize: CGFloat = 14
    static let toolbarItemSpacing: CGFloat = 12
    /// 工具条底边到名签顶的间距。
    static let toolbarGap: CGFloat = 10

    /// 卡内浮动 chip（hover 才出现的「替换 / 入库」那类）。
    static let chipFill = Color(red: 0.173, green: 0.173, blue: 0.173).opacity(0.92)
    static let chipInk = Color.white
    static let chipHeight: CGFloat = 26
    static let chipRadius: CGFloat = 13
    static let chipInset: CGFloat = 8
    static let chipFontSize: CGFloat = 11

    /// 菜单面板。
    static let menuFill = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let menuRadius: CGFloat = 14
    static let menuRowHoverFill = Color(red: 0.149, green: 0.149, blue: 0.149)
    static let menuTileFill = Color(red: 0.169, green: 0.169, blue: 0.169)
    static let menuSectionInk = Color(red: 0.49, green: 0.49, blue: 0.49)

    // MARK: - 动效

    /// 状态切换（hover / 选中 / 端口出现 / 工具条）。
    ///
    /// 0.14s 不是随手写的：低于 0.1s 人眼读不到"它在动"，只感觉画面闪了一下；高于 0.2s
    /// 在快速扫过多个节点时会出现"上一张还没淡完、下一张已经亮了"的拖影。
    static let stateAnim: Animation = .easeOut(duration: 0.14)

    /// 节点落位。用 `interactiveSpring` 而不是 `easeOut`：拖拽松手那一刻手指的速度信息
    /// 应该被继承下来，卡片"滑一点点再停"才像有质量的东西。
    static let placeAnim: Animation = .interactiveSpring(response: 0.26, dampingFraction: 0.86)
}

/// 给一块区域挂 `NSCursor`（v2.16.0）。
///
/// ## 为什么不用 `.onHover { NSCursor.x.push()/pop() }`
///
/// 那是这个项目原来的做法在其他页面上能凑合，但在画布上不行：
/// - `onHover` 的 false 事件在**快速划过**时会丢（SwiftUI 已知行为），push/pop 不配对，
///   于是手型光标黏在屏幕上直到用户去点别的窗口；
/// - 拖拽过程中鼠标已经被系统捕获，`onHover` 根本不再触发，而"拖动时要变成握拳手"恰恰
///   发生在这段时间里。
///
/// `NSView.addCursorRect` + `cursorUpdate` 是 AppKit 为此提供的正规通道：矩形跟随布局，
/// 光标由窗口统一管理，不存在配对问题。
struct CursorArea: NSViewRepresentable {
    var cursor: NSCursor

    func makeNSView(context: Context) -> CursorNSView {
        let v = CursorNSView()
        v.cursor = cursor
        return v
    }

    func updateNSView(_ nsView: CursorNSView, context: Context) {
        guard nsView.cursor != cursor else { return }
        nsView.cursor = cursor
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    final class CursorNSView: NSView {
        var cursor: NSCursor = .arrow

        /// 光标区域必须**不**参与命中测试：它铺在卡片之上，参与命中就会把点击、双击、
        /// 拖拽全吃掉——那是比"光标不对"严重得多的故障。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }
    }
}

extension View {
    /// 悬停在这块区域上时的光标。
    func tapCursor(_ cursor: NSCursor) -> some View {
        overlay(CursorArea(cursor: cursor).allowsHitTesting(false))
    }
}

/// v2.16.0：进入画布时把**窗口标题栏**也钉成深色。
///
/// 画布本体在 v2.16.0 已脱离主题体系固定纯黑（见 `TapSkin.void` 与 `AppTheme` 里那批钉死的
/// canvas chrome token），但窗口 chrome 仍由 `NSApp.appearance` 决定。于是「App 主题＝浅色」时
/// 会出现一条亮度 241 的白标题栏直接压在纯黑画布上方——实测截图里这是整窗唯一一处大面积亮区，
/// 也是与 TapNow 观感差异最明显的残留（TapNow 整窗同色，标题栏与画布连成一片）。
///
/// 为什么不走 `NSApp.windows.first(where: titled && !isPanel)`：实测钉不上。App 里还有环形菜单、
/// 悬浮提示这些**同样 titled、同样不是 NSPanel** 的窗口控制器，它们可能比主窗口更早进 `NSApp.windows`，
/// `first` 于是把深色钉到了一个不可见的窗口上。所以这里改成挂一个零尺寸宿主视图，直接用
/// `view.window` 拿到**真正承载画布的那个窗口**，不做任何猜测。
///
/// 作用域刻意收窄到「承载窗口 + 画布模式期间」：置 `darkAqua` 让 AppKit 自己把标题栏画成深色；
/// 视图销毁（切回编辑）时还原为 `nil`，即重新继承 `NSApp.appearance`，用户的主题偏好与
/// `applyAppAppearance()` 的语义都不受影响。不动 `styleMask`，因此 `normalizeMainWindowChrome()`
/// 钉下的「标题栏由 AppKit 画、不做 fullSizeContentView」那套约定继续成立。
/// 画布模式下的窗口 chrome 管理者（v2.16.1 重写）。
///
/// ## 为什么是「单例 + 引用计数」而不是每个视图各存一份原值
///
/// v2.16.0 的写法是把原值存在 `NSViewRepresentable` 的 `Host` 实例里：`pin()` 时记下来，
/// `dismantleNSView` 时还原。看着对称，实际在 SwiftUI 里是坏的 —— 宿主视图**会被反复重建**
/// （`.background(...)` 里的 representable 随外层状态刷新而换实例），而重建的顺序是
/// **先 make 新的、后 dismantle 旧的**。于是每次刷新都在做：
///
///   新 Host.pin()   → 透明标题栏 + darkAqua ✅
///   旧 Host.unpin() → 按它自己记的「原值」还原成不透明 + appearance=nil ❌（把新的覆盖掉）
///
/// 净效果就是钉不住。实测日志（同一个窗口 `0xc7733c600`，写完同步读是生效的，隔 0.8s 再读
/// 就回去了）：
///
/// ```text
/// sync@pin  before(transparent=1 app=DarkAqua)  afterSyncRead(transparent=1 app=DarkAqua)
/// +0.8      before(transparent=0 app=Aqua)      afterSyncRead(transparent=1 app=DarkAqua)
/// +2.5      before(transparent=0 app=Aqua)      afterSyncRead(transparent=1 app=DarkAqua)
/// ```
///
/// 屏幕上的表现是标题栏始终是浅色横带 (231,231,232)、红绿灯是浅色版，和纯黑画布顶边硬碰一条缝。
/// 顺带解释了 v2.16.0 那条「fullSizeContentView 没生效」的错觉 —— `styleMask` 其实进去了
/// （contentView 高度等于窗口高度），只有 `titlebarAppearsTransparent` 被还原掉了。
///
/// 所以原值必须是**窗口维度的、全局一份**，并且用引用计数决定何时还原：
/// 画布在台上期间任意多次重建都只是 `retain +1/-1`，计数归零（真的离开画布）才还原。
///
/// ## 为什么这里**不**碰 `titlebarAppearsTransparent` 和 `window.appearance`
///
/// 碰不过 —— 这两项由 SwiftUI 自己按场景环境算，每次环境更新都会重写回去。swizzle setter
/// 抓到的调用栈（v2.16.1 实测）：
///
/// ```text
/// setTitlebarAppearsTransparent(false)  <- SwiftUI.BarAppearanceBridge.updateWindowToolbar…
/// setAppearance(nil)                    <- SwiftUI.AppKitWindowController.hostingView(_:willUpdate:)
/// ```
///
/// 手写值在同一个 runloop 里读回来是对的，隔一帧就被刷掉，所以这条路是死的。正确的开关在
/// SwiftUI 那一侧，画布视图上挂：
///
/// ・`.toolbarBackground(.hidden, for: .windowToolbar)` → 标题栏不再画那层浅色材质，
///   `fullSizeContentView` 铺到顶的黑画布直接透出来；
/// ・`.preferredColorScheme(.dark)` → 让 SwiftUI 自己把窗口 appearance 设成深色（红绿灯、
///   系统菜单跟着深色走），而不是我们去写 `window.appearance`。
///
/// 留给这个类的就只有 SwiftUI 不管的两项：`styleMask` 的 `fullSizeContentView` 和窗口底色。
///
/// 只在主线程使用（SwiftUI 的 representable 回调与 AppDelegate 都在主线程）。
final class CanvasChromePin {
    static let shared = CanvasChromePin()

    private struct Saved {
        let hadFullSizeContentView: Bool
        let titleVisibility: NSWindow.TitleVisibility
        let backgroundColor: NSColor?
    }

    /// 改 `styleMask` 会连带改「内容区」的高度：插入 `fullSizeContentView` 时内容区多出标题栏
    /// 那 28pt，移除时又少回去。SwiftUI 紧接着会按内容的理想尺寸反推窗口大小，于是**每进出一次
    /// 画布，窗口就长高一截**（v2.16.1 实测连续三次启动：904 → 932 → 949）。
    /// 所以每次动 styleMask 都把 frame 原样按回去。
    private func preservingFrame(_ window: NSWindow, _ body: () -> Void) {
        let frame = window.frame
        body()
        if window.frame != frame {
            window.setFrame(frame, display: false)
        }
    }

    private weak var window: NSWindow?
    private var saved: Saved?
    private var retainCount = 0

    private init() {}

    /// 画布是否正在钉窗口 chrome。`AppDelegate.normalizeMainWindowChrome()` 要认这个标记，
    /// 否则它会在启动 retry 与每次皮肤切换时把 chrome 掰回「不透明标题栏」。
    var isActive: Bool { retainCount > 0 }

    func acquire(_ window: NSWindow) {
        if self.window !== window {
            // 换窗口了（多窗口 / 窗口重建）：先把上一个还原干净，避免把别人的 chrome 留在深色上。
            restoreIfNeeded()
            self.window = window
            saved = Saved(hadFullSizeContentView: window.styleMask.contains(.fullSizeContentView),
                          titleVisibility: window.titleVisibility,
                          backgroundColor: window.backgroundColor)
        }
        retainCount += 1
        apply(to: window)
    }

    /// 视图刷新 / 皮肤切换后重新压一遍。计数为 0 时什么都不做。
    func reapply(_ window: NSWindow) {
        guard retainCount > 0, self.window === window else { return }
        apply(to: window)
    }

    func release() {
        guard retainCount > 0 else { return }
        retainCount -= 1
        guard retainCount == 0 else { return }
        restoreIfNeeded()
    }

    /// TapNow 的窗口没有标题栏那条横带：纯黑一直铺到窗口顶边，只剩红绿灯浮在画布上。
    ///
    /// 写之前都先判等：`updateNSView` 每帧都会调进来，无脑重写会让 AppKit 反复重画 chrome。
    private func apply(to window: NSWindow) {
        if !window.styleMask.contains(.fullSizeContentView) {
            preservingFrame(window) { window.styleMask.insert(.fullSizeContentView) }
        }
        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
        }
        if window.backgroundColor != .black {
            window.backgroundColor = .black
        }
    }

    private func restoreIfNeeded() {
        guard let window, let saved else {
            self.window = nil
            self.saved = nil
            return
        }
        if !saved.hadFullSizeContentView {
            preservingFrame(window) { window.styleMask.remove(.fullSizeContentView) }
        }
        window.titleVisibility = saved.titleVisibility
        window.backgroundColor = saved.backgroundColor ?? .windowBackgroundColor
        self.window = nil
        self.saved = nil
    }
}

/// 把 `CanvasChromePin` 挂到画布视图树上的零尺寸宿主。
///
/// 它只负责「画布在不在台上」这一个事实：挂上 = acquire，拆掉 = release，刷新 = reapply。
/// 原值与还原时机都在 `CanvasChromePin` 里，见那边关于重建顺序的注释。
struct CanvasWindowAppearancePin: NSViewRepresentable {
    final class Host: NSView {
        private var acquired = false
        private var skinObserver: NSObjectProtocol?

        /// SwiftUI 建窗晚于 `makeNSView`，视图挂上窗口这一刻才是能拿到 window 的时机。
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            guard let window else { return }
            if acquired {
                CanvasChromePin.shared.reapply(window)
            } else {
                acquired = true
                CanvasChromePin.shared.acquire(window)
            }
            if skinObserver == nil {
                // 皮肤切换会触发 `normalizeMainWindowChrome()`；它是异步 retry 的，
                // 所以排到它之后再压一遍。
                skinObserver = NotificationCenter.default.addObserver(
                    forName: AppSkinCenter.didChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, let window = self.window else { return }
                        CanvasChromePin.shared.reapply(window)
                    }
                }
            }
        }

        func detach() {
            if let skinObserver {
                NotificationCenter.default.removeObserver(skinObserver)
                self.skinObserver = nil
            }
            guard acquired else { return }
            acquired = false
            CanvasChromePin.shared.release()
        }
    }

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.attach()
        return view
    }

    func updateNSView(_ view: Host, context: Context) {
        view.attach()
    }

    static func dismantleNSView(_ view: Host, coordinator: ()) {
        view.detach()
    }
}


