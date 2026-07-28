import AppKit
import SwiftUI
import ClipSlotsKit

// v2.10.20: 附件管理面板改用「非激活浮动 NSPanel」承载，替代 v2.10.19 的
// SemiTransientPopoverAnchor(.semitransient NSPopover)。原方案存在打开卡顿、
// 部分槽位点击无反应（时序竞态 / view.window 为 nil 静默失败）等问题。
//
// 该方案参考本仓库已验证流畅的 AttachmentPreviewWindowController：
//   .borderless + .nonactivatingPanel、hidesOnDeactivate = false、isFloatingPanel、
//   orderFrontRegardless()。
// 特点：
//   (a) 打开丝滑可靠（无 popover 动画/布局竞态）；
//   (b) 用按钮屏幕矩形定位，所有槽位都能稳定打开（带兜底重试）；
//   (c) hidesOnDeactivate = false + 非激活面板 ⇒ 切到 Finder 拖文件时面板不关闭。
//
// 关闭时机：点击本 App 内、面板之外（本地事件监听）；Esc；再次点击附件按钮切换。
// 切到其他 App（失焦）不会触发本地监听，因此面板保持打开。

/// 记录附件按钮 backing NSView 的透明锚点，用于计算按钮的屏幕矩形。
final class AttachmentButtonScreenAnchor {
    weak var view: NSView?

    func screenRect() -> NSRect? {
        guard let view, let window = view.window else { return nil }
        let inWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }
}

/// 透明背景视图，持续把附件按钮的 backing NSView 上报给锚点。
struct AttachmentButtonAnchorReporter: NSViewRepresentable {
    let holder: AttachmentButtonScreenAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}

/// 非激活浮动面板：切到其他 App 不隐藏、不抢占主窗口焦点。
private final class AttachmentManagerFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 承载 AttachmentManagerPopover 的浮动面板控制器。
final class AttachmentManagerPanelController {
    private var panel: AttachmentManagerFloatingPanel?
    private var localMonitor: Any?
    private var anchorProvider: (() -> NSRect?)?
    private var onClose: (() -> Void)?
    private let panelSize = NSSize(width: 360, height: 480)

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 在锚点矩形下方展示附件面板。anchorProvider 用于关闭判断时复算按钮矩形。
    func show(
        anchor: NSRect,
        slot: Int,
        store: SlotStoreObservable,
        anchorProvider: @escaping () -> NSRect?,
        onClose: @escaping () -> Void
    ) {
        self.anchorProvider = anchorProvider
        self.onClose = onClose

        let hosting = NSHostingController(rootView: AttachmentManagerPopover(slot: slot, store: store))

        let panel = self.panel ?? makePanel()
        panel.contentViewController = hosting
        panel.setContentSize(panelSize)
        position(panel, anchor: anchor)
        panel.orderFrontRegardless()
        self.panel = panel

        installMonitor()
    }

    func close() {
        removeMonitor()
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        let cb = onClose
        onClose = nil
        anchorProvider = nil
        cb?()
    }

    private func makePanel() -> AttachmentManagerFloatingPanel {
        let panel = AttachmentManagerFloatingPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false          // 关键：失焦（切 Finder）不关闭
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    /// 面板定位在按钮下方，超出屏幕时向上/水平夹紧到可见区域。
    private func position(_ panel: NSPanel, anchor: NSRect) {
        let size = panelSize
        let gap: CGFloat = 6
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor

        var x = anchor.minX
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)

        // 屏幕坐标 y 向上为正：按钮「下方」= 更小的 y。
        var y = anchor.minY - gap - size.height
        if y < visible.minY + 4 {
            // 下方空间不足，放到按钮上方。
            y = anchor.maxY + gap
        }
        y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installMonitor() {
        removeMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }

            // Esc 关闭并吞掉事件。
            if event.type == .keyDown {
                if event.keyCode == 53 { // Esc
                    self.close()
                    return nil
                }
                return event
            }

            let loc = NSEvent.mouseLocation

            // 点击附件按钮自身：交给按钮的 toggle 处理，避免关闭又立刻重开。
            if let btnRect = self.anchorProvider?(), btnRect.insetBy(dx: -4, dy: -4).contains(loc) {
                return event
            }
            // 点击面板内部：保持打开。
            if let panel = self.panel, panel.frame.contains(loc) {
                return event
            }
            // 点击本 App 其他区域：关闭。（切到其他 App 不会触发本地监听 ⇒ 失焦不关闭）
            self.close()
            return event
        }
    }

    private func removeMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}
