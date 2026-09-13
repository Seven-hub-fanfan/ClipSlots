import SwiftUI
import ClipSlotsKit
import AppKit

// MARK: - 主窗口定位（v2.11.7 hotfix13）

extension NSApplication {

    /// 找出「用户此刻正在看的那扇主窗口」。
    ///
    /// 不能写成 `windows.first { !($0 is NSPanel) }` 再去读它的状态 —— hotfix13 的第一个构建就是
    /// 这么写的，结果日志里出现 `visible=false mini=true`，而屏幕上主窗口分明开着：SwiftUI 进程里
    /// 除了真正的文档窗口，还可能挂着隐藏 / 最小化的附属窗口，`windows` 的顺序又不是 z 序，
    /// 取到附属窗口就会把「窗口好好开着」误判成不可见，于是通知永远走 HUD、窗内通道形同废弃。
    ///
    /// 所以要**按优先级挑**，而不是取第一个：main/key 窗口 → 可见且未被遮挡的 → 可见的 → 兜底。
    /// NSPanel 全部排除（HUD 自己、轮盘菜单、各类浮层都是 panel）。
    var clipSlotsPrimaryWindow: NSWindow? {
        let candidates = windows.filter { !($0 is NSPanel) }
        return candidates.first { $0 === mainWindow || $0 === keyWindow }
            ?? candidates.first { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
            ?? candidates.first { $0.isVisible && !$0.isMiniaturized }
            ?? candidates.first
    }
}

// MARK: - 窗口可见性快照（v2.11.7 hotfix13）

extension NoticeWindowState {

    /// 从 AppKit 读出当前的主窗口可见性，交给 `NoticePresentationRouter` 决定投递通道。
    ///
    /// `occlusionState` 这一项容易被忽略但很关键：窗口 `isVisible == true` 只表示「没被 orderOut、
    /// 没最小化」，被别的 App 全屏窗口盖住时它依然是 true。此时窗内卡片等于画在看不见的地方，
    /// 必须走 HUD。
    ///
    /// 必须在主线程调用（读 `NSApp.windows`）。万一在后台线程被调到，直接返回「主窗口不可见」，
    /// 让路由选 HUD —— HUD 通道内部自己会 hop 到主线程，是这两条路里唯一线程安全的那条。
    static func current() -> NoticeWindowState {
        guard Thread.isMainThread else {
            return NoticeWindowState(appActive: false,
                                     mainWindowVisible: false,
                                     mainWindowMiniaturized: false,
                                     mainWindowOccluded: true)
        }
        if ProcessInfo.processInfo.environment["CLIPSLOTS_NOTICE_WINDOW_DUMP"] == "1" {
            for w in NSApp.windows {
                NSLog("[ClipSlots] window dump class=\(type(of: w)) title=\(w.title) visible=\(w.isVisible) mini=\(w.isMiniaturized) occl=\(w.occlusionState.contains(.visible)) frame=\(w.frame)")
            }
        }
        guard let window = NSApp.clipSlotsPrimaryWindow else {
            return NoticeWindowState(appActive: NSApp.isActive,
                                     mainWindowVisible: false,
                                     mainWindowMiniaturized: false,
                                     mainWindowOccluded: true)
        }
        return NoticeWindowState(
            appActive: NSApp.isActive,
            mainWindowVisible: window.isVisible,
            mainWindowMiniaturized: window.isMiniaturized,
            mainWindowOccluded: !window.occlusionState.contains(.visible)
        )
    }
}

// MARK: - Global HUD Window Controller (v2.6.3)

/// Displays an auto-dismissing non-activating HUD window that is visible
/// across all apps/spaces, regardless of whether the ClipSlots main window
/// is visible. Used for save/copy/batch feedback from hotkey operations.
///
/// v2.11.7 hotfix13: 本面板现在是 `showFloatingNotice` **二选一**的通道之一（另一个是窗内
/// 覆盖层），不再与窗内卡片同时出现 —— 那正是「同一次保存弹两张卡」的根因。定位也改为
/// 「贴主窗口顶部居中」，与窗内通道同一个落点，避免 Toast 在两种场景下位置跳动。
final class FloatingNoticeWindowController {
    static let shared = FloatingNoticeWindowController()

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    func show(notice: FloatingNotice, duration: TimeInterval = 2.0) {
        DispatchQueue.main.async {
            self.dismissWorkItem?.cancel()

            // v2.6.7: Pass App colorScheme to the independent HUD panel
            let modeRaw = UserDefaults.standard.string(forKey: "appearanceMode") ?? ThemeMode.system.rawValue
            let themeMode = ThemeMode(rawValue: modeRaw) ?? .system
            let effectiveColorScheme: ColorScheme = {
                if let preferred = themeMode.preferredColorScheme {
                    return preferred
                }
                let appearance = NSApp.effectiveAppearance
                if appearance.name == .darkAqua || appearance.name == .vibrantDark {
                    return .dark
                }
                return .light
            }()

            // v2.11.7 hotfix13: 四周留出投影空间。NSPanel 的 contentView 会裁掉超出边界的绘制，
            // 原来的 `.padding(1)` 会把多彩模式那圈 blur 12 的柔阴影切成硬边框。
            let hostingView = NSHostingView(
                rootView: FloatingNoticeView(notice: notice)
                    .environment(\.colorScheme, effectiveColorScheme)
                    .padding(NoticeMetrics.hudShadowPadding)
            )

            let panel = self.panel ?? self.makePanel()
            panel.contentView = hostingView

            // Size: use fittingSize with a fallback
            let fitting = hostingView.fittingSize
            let fallbackSize = NSSize(
                width: NoticeMetrics.maxWidth + NoticeMetrics.hudShadowPadding * 2,
                height: (notice.subtitle.isEmpty ? 40 : 58) + NoticeMetrics.hudShadowPadding * 2
            )
            let size = fitting.width > 0 && fitting.height > 0 ? fitting : fallbackSize
            panel.setContentSize(size)

            self.position(panel)
            panel.orderFrontRegardless()

            self.panel = panel

            let workItem = DispatchWorkItem { [weak self] in
                self?.panel?.orderOut(nil)
            }
            self.dismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + duration,
                execute: workItem
            )
        }
    }

    /// Immediately hide the HUD.
    func dismiss() {
        DispatchQueue.main.async {
            self.dismissWorkItem?.cancel()
            self.dismissWorkItem = nil
            self.panel?.orderOut(nil)
        }
    }

    // MARK: - Private

    private func makePanel() -> NSPanel {
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: NoticeMetrics.maxWidth, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 1.0   // v2.6.7: ensure no transparency
        panel.hasShadow = false  // v2.6.5: ensure no shadow
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .transient,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        // Ensure it never becomes key
        panel.becomesKeyOnlyIfNeeded = false

        return panel
    }

    /// v2.11.7 hotfix13: 贴**主窗口**顶部居中（距窗口顶沿 `NoticeMetrics.topInset`），
    /// 与窗内覆盖层同一个落点；主窗口不可见时回退到「鼠标所在屏幕」顶部居中。
    /// 几何计算在 `NoticeMetrics.hudOrigin`（Kit 纯函数，有 smoke 断言）。
    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        // 与 `NoticeWindowState.current()` 用同一个「主窗口」口径（见 clipSlotsPrimaryWindow），
        // 否则会出现「路由认为窗口可见、定位却找不到窗口 → 回退屏幕顶部」这种自相矛盾。
        let primary = NSApp.clipSlotsPrimaryWindow
        let mainWindow = (primary?.isVisible == true && primary?.isMiniaturized == false) ? primary : nil
        let targetScreen = mainWindow?.screen
            ?? NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main

        guard let screen = targetScreen else { return }

        // 用**内容区**（去掉标题栏）而不是 window.frame 当锚：窗内通道的 16pt 是从内容区顶部量的，
        // 这里若用 frame 顶部，同一条通知在两条通道下会差一个标题栏的高度（约 28pt）。
        let anchorFrame: CGRect? = mainWindow.map { window in
            let content = window.contentLayoutRect
            return CGRect(x: window.frame.minX + content.minX,
                          y: window.frame.minY + content.minY,
                          width: content.width,
                          height: content.height)
        }

        let origin = NoticeMetrics.hudOrigin(
            windowFrame: anchorFrame,
            contentSize: panel.frame.size,
            screenVisibleFrame: screen.visibleFrame
        )
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
    }
}

// MARK: - Non-Activating Panel

/// A panel that can NEVER become key or main. This prevents the HUD
/// from stealing focus from the current app (Finder, browser, etc.).
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
