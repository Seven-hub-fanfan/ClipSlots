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
///
/// v2.10.23：改为**全局单例**（`shared`）。此前每个 SlotNodeView 各持有一个 @State 实例，
/// 切换槽位时是「A 的 popover 还在关、B 的 popover 已在开」两个独立控制器的动画同时进行，
/// 出现卡顿 / 动画打架。现在所有槽位共用同一个控制器管理 NSPopover 生命周期。
///
/// v2.10.24（本次）：切换槽位改为**并行**方案。v2.10.23 的「先 performClose 旧的、待
/// popoverDidClose 回调后再 show 新的」串行策略需要等待旧 popover 的关闭动画（约
/// 0.2s），切换时有明显等待/卡顿感。现在改为：
///   - 未显示 → 直接 show。
///   - 已显示（切到另一个槽位）→ **立即** show 新 popover，同时异步 performClose 旧的，
///     两者动画并行进行。效果：切换附件和第一次打开一样快，无等待感。
///   - 为防止旧 popover 关闭时的 popoverDidClose 回调误清空「新 popover」的状态，
///     控制器只在关闭的 popover 正是当前 `self.popover` 时才复位状态（陈旧的旧实例关闭被忽略）。
final class AttachmentManagerPanelController: NSObject, NSPopoverDelegate {
    /// 全局共享控制器：所有槽位的附件面板共用同一个控制器。
    static let shared = AttachmentManagerPanelController()

    /// 当前正在展示（或最近一次展示）的 popover。
    private var popover: NSPopover?
    private var onClose: (() -> Void)?
    /// 当前 popover 正在展示的槽位号（用于「点同一个按钮再切换关闭」判断）。
    private(set) var currentSlot: Int?

    var isVisible: Bool { popover?.isShown ?? false }

    /// 指定槽位的面板是否正在显示（点同一个附件按钮时用于切换关闭）。
    func isVisible(forSlot slot: Int) -> Bool {
        isVisible && currentSlot == slot
    }

    /// 相对附件按钮的 backing NSView 弹出 popover（箭头锚定、跟随主窗口）。
    ///
    /// 并行切换（v2.10.24）：若已有别的槽位的 popover 在展示，先立即展示新的，再异步关闭旧的，
    /// 让「开新」与「关旧」动画并行，消除切换时的等待感。
    func show(
        anchor: AttachmentButtonScreenAnchor,
        slot: Int,
        store: SlotStoreObservable,
        onClose: @escaping () -> Void
    ) {
        guard anchor.view?.window != nil else { return }

        // 记下旧 popover（可能是别的槽位）；它将与新 popover 的展示动画并行关闭。
        let oldPopover = popover

        // 立即展示新 popover（reallyShow 会把 self.popover 指向新实例）。
        reallyShow(anchor: anchor, slot: slot, store: store, onClose: onClose)

        // 并行关闭旧的：异步 performClose，与新 popover 的展开动画同时进行，不阻塞、不等待。
        if let oldPopover, oldPopover.isShown {
            DispatchQueue.main.async { oldPopover.performClose(nil) }
        }
    }

    /// 真正创建并展示 popover。要求锚点 NSView 已在窗口层级中。
    private func reallyShow(
        anchor: AttachmentButtonScreenAnchor,
        slot: Int,
        store: SlotStoreObservable,
        onClose: @escaping () -> Void
    ) {
        guard let anchorView = anchor.view, anchorView.window != nil else { return }

        self.onClose = onClose
        self.currentSlot = slot

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
        // 并行切换时旧 popover 会晚于新 popover 关闭；只有当关闭的正是「当前 popover」时
        // 才复位状态与触发 onClose，避免旧实例的关闭误清空刚展示的新 popover。
        guard let closed = notification.object as? NSPopover, closed === popover else {
            return
        }

        popover = nil
        currentSlot = nil
        let cb = onClose
        onClose = nil
        cb?()
    }
}
