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
struct CanvasWindowAppearancePin: NSViewRepresentable {
    final class Host: NSView {
        /// 记住实际被改过的那个窗口 + 它的原值，还原时只还原它，不去动别人。
        private weak var pinned: NSWindow?
        private var savedTitlebarTransparent: Bool?
        private var savedBackground: NSColor?

        /// SwiftUI 建窗晚于 `makeNSView`，视图挂上窗口这一刻才是能拿到 window 的时机。
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            pin()
        }

        func pin() {
            guard let window = window, pinned !== window else { return }
            pinned = window
            if savedTitlebarTransparent == nil {
                savedTitlebarTransparent = window.titlebarAppearsTransparent
                savedBackground = window.backgroundColor
            }
            // 只设 appearance 不够：实测 `window.appearance = .darkAqua` 之后
            // `effectiveAppearance` 确实变成 NSAppearanceNameDarkAqua，但标题栏仍旧渲染成
            // 亮度 241 的浅色条——AppKit 没有按新 appearance 重画这块 chrome。
            // 所以改成让标题栏**透明**、由窗口底色透上来，底色钉黑，从而拿到 TapNow 那种
            // 「标题栏与画布连成一片」的整窗纯黑；appearance 仍设深色，好让标题文字与
            // 红绿灯按钮切到深色底应有的配色。
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .black
            // 为什么还要逐级往上设 appearance：只设 `window.appearance` 时实测
            // `NSTitlebarView.effectiveAppearance` 已经是 DarkAqua，可那块 chrome 仍旧画成
            // 亮度 241 的浅色条；显式给 `NSTitlebarView` / `NSTitlebarContainerView` / `NSThemeFrame`
            // 各设一次 darkAqua 之后才真正重画成深色（实测 49,49,49）。
            //
            // 到 49 就是这条路的地板：试过给 NSTitlebarView 开 layer 再把底色钉成纯黑，
            // 实测仍是 49 —— 标题栏的材质层画在图层底色之上，盖不住。真要做到 TapNow 那种
            // 「黑到窗口顶边、只剩红绿灯浮在画布上」，得上 fullSizeContentView + 隐藏标题，
            // 同时给侧栏/画布 chrome 补一条约 28pt 顶部内缩避开红绿灯，属于布局改动，留给后续版本。
            var node: NSView? = window.standardWindowButton(.closeButton)?.superview
            while let view = node {
                view.appearance = NSAppearance(named: .darkAqua)
                node = view.superview
            }
        }

        func unpin() {
            guard let window = pinned else { return }
            window.appearance = nil
            if let t = savedTitlebarTransparent { window.titlebarAppearsTransparent = t }
            window.backgroundColor = savedBackground ?? .windowBackgroundColor
            savedTitlebarTransparent = nil
            savedBackground = nil
            pinned = nil
        }
    }

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.pin()
        return view
    }

    func updateNSView(_ view: Host, context: Context) {
        view.pin()
    }

    static func dismantleNSView(_ view: Host, coordinator: ()) {
        view.unpin()
    }
}
