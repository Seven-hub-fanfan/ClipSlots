import AppKit
import SwiftUI
import ClipSlotsKit

// v2.10.22: 附件面板改回「跟随主窗口的 NSPopover」承载。
//
// 历史演进：
//   v2.10.19：SemiTransientPopoverAnchor(.semitransient NSPopover) —— 有时序竞态（view.window
//             为 nil）导致部分槽位点击无反应。
//   v2.10.20：改用 .borderless + 透明 NSPanel 浮动窗承载。虽然打开可靠，但因为面板 isOpaque=false /
//             backgroundColor=.clear 且内容背景 AppTheme.elevatedBackground 近乎全透明，视觉上变成
//             「脱离主窗口、悬浮在屏幕上的半透明独立窗口」，与主窗口完全脱节（用户反馈问题 A/C）。
//   v2.10.22（本次）：回到 NSPopover。NSPopover 天然带箭头锚定按钮、跟随主窗口移动，且拥有系统级
//             毛玻璃（vibrant）背景，与「快捷键模板」弹窗观感一致，直接解决 A（脱节）+ C（太透明）。
//
// 关键点：
//   (a) behavior = .semitransient ⇒ 切到其他 App（如 Finder）时 popover 不关闭，可从 Finder 拖文件进来；
//       仅当用户与主窗口自身交互（点击窗口其他区域）时才关闭。
//   (b) 用附件按钮持续上报的 backing NSView 作为锚点，保证该 NSView 已在窗口层级中，
//       避免 v2.10.19 的 view.window == nil 时序竞态；配合 SlotNodeView 的下一 runloop 兜底重试。

/// 记录附件按钮 backing NSView，供 NSPopover 锚定 / 屏幕矩形计算使用。
final class AttachmentButtonScreenAnchor {
    weak var view: NSView?

    /// 锚点 NSView 当前是否已挂到窗口层级（NSPopover.show 的前置条件）。
    var isReady: Bool { view?.window != nil }

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

/// 承载 AttachmentManagerPopover 的 NSPopover 控制器。
final class AttachmentManagerPanelController: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var onClose: (() -> Void)?

    var isVisible: Bool { popover?.isShown ?? false }

    /// 相对附件按钮的 backing NSView 弹出 popover（箭头锚定、跟随主窗口）。
    func show(
        anchor: AttachmentButtonScreenAnchor,
        slot: Int,
        store: SlotStoreObservable,
        onClose: @escaping () -> Void
    ) {
        guard let anchorView = anchor.view, anchorView.window != nil else { return }

        // 已经打开则先收起，避免重复弹出。
        if let existing = popover, existing.isShown {
            existing.performClose(nil)
        }

        self.onClose = onClose

        let hosting = NSHostingController(rootView: AttachmentManagerPopover(slot: slot, store: store))
        let pop = NSPopover()
        pop.contentViewController = hosting
        pop.contentSize = NSSize(width: 360, height: 480)
        // .semitransient：切到其他 App（Finder 拖文件）时不关闭；仅与主窗口交互时关闭。
        pop.behavior = .semitransient
        pop.animates = true
        pop.delegate = self
        pop.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        self.popover = pop
    }

    func close() {
        popover?.performClose(nil)
    }

    // MARK: NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        let cb = onClose
        onClose = nil
        cb?()
    }
}
