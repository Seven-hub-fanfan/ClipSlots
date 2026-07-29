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
/// 出现卡顿 / 动画打架。现在所有槽位共用同一个控制器与同一个 NSPopover 生命周期：
///   - 未显示 → 直接 show（无动画竞态）。
///   - 已显示（切到另一个槽位）→ 先 performClose，待 `popoverDidClose` 回调后再在下一
///     runloop show 新槽位，彻底串行化「关→开」，避免并发动画。
final class AttachmentManagerPanelController: NSObject, NSPopoverDelegate {
    /// 全局共享控制器：所有槽位的附件面板共用同一个 NSPopover 生命周期。
    static let shared = AttachmentManagerPanelController()

    private var popover: NSPopover?
    // AT-4 (v2.10.30): hold a strong reference to the current content hosting
    // controller so it can be explicitly dismantled before a new one is created.
    // Previously each `reallyShow` built a fresh NSHostingController and replaced
    // the popover's contentView without tearing down the old controller; rapid
    // slot switching could accumulate un-released SwiftUI render trees.
    private var hosting: NSHostingController<AttachmentManagerPopover>?
    private var onClose: (() -> Void)?
    /// 当前 popover 正在展示的槽位号（用于「点同一个按钮再切换关闭」判断）。
    private(set) var currentSlot: Int?
    /// 关闭进行中时挂起的下一次 show 请求（切换槽位时用），在 popoverDidClose 后执行。
    private var pendingShow: (() -> Void)?

    var isVisible: Bool { popover?.isShown ?? false }

    /// 指定槽位的面板是否正在显示（点同一个附件按钮时用于切换关闭）。
    func isVisible(forSlot slot: Int) -> Bool {
        isVisible && currentSlot == slot
    }

    /// 相对附件按钮的 backing NSView 弹出 popover（箭头锚定、跟随主窗口）。
    ///
    /// v2.10.29 性能优化：连续点击不同槽位的附件按钮时，旧逻辑是「动画关旧 popover →
    /// 等 popoverDidClose 回调 → 下一 runloop 再动画开新 popover」——一次切换要串起
    /// 「淡出动画 + runloop 跳转 + 淡入动画」，用户看到的就是「卡顿一下再弹出」。
    /// 现改为：切换槽位时**同步无动画关闭旧 popover 并立即无动画展示新 popover**，
    /// 消除双段动画与 runloop 空窗，切换瞬时完成；首次打开（无 popover 在显示）仍带动画。
    func show(
        anchor: AttachmentButtonScreenAnchor,
        slot: Int,
        store: SlotStoreObservable,
        onClose: @escaping () -> Void
    ) {
        guard anchor.view?.window != nil else { return }

        // 已经打开（可能是别的槽位）→ 直接同步无动画切换，不再走「关→等回调→开」的异步链。
        if let existing = popover, existing.isShown {
            // 关掉旧 popover：摘掉 delegate，避免其 popoverDidClose 触发 pendingShow 逻辑；
            // 关掉动画让收起瞬时完成（无淡出）。
            pendingShow = nil
            existing.delegate = nil
            existing.animates = false
            existing.close()
            popover = nil
            // 手动回调上一个槽位的 onClose（原本由 popoverDidClose 负责）。
            let previousOnClose = self.onClose
            self.onClose = nil
            previousOnClose?()
            currentSlot = nil

            // 立即无动画展示新槽位面板，切换瞬时可见，无卡顿空窗。
            // AT-3 (v2.10.30): defer `reallyShow` by one main-loop tick. The
            // `previousOnClose?()` above may drive a parent SwiftUI state update
            // that re-lays-out (or momentarily tears down) the attachment button's
            // backing NSView; anchoring synchronously in the same RunLoop can then
            // hit a niled `anchor.view`/`window` and silently fail to pop. Deferring
            // lets that redraw settle so the anchor is valid when we show. This is a
            // micro-defer (no animation), so the instant-switch feel is preserved.
            DispatchQueue.main.async { [weak self] in
                self?.reallyShow(anchor: anchor, slot: slot, store: store, onClose: onClose, animates: false)
            }
        } else {
            // 首次打开：保留原有淡入动画。
            reallyShow(anchor: anchor, slot: slot, store: store, onClose: onClose, animates: true)
        }
    }

    /// 真正创建并展示 popover。要求锚点 NSView 已在窗口层级中。
    /// - Parameter animates: 是否带淡入动画。首次打开为 true；连续切换槽位时为 false（瞬时切换，去卡顿）。
    private func reallyShow(
        anchor: AttachmentButtonScreenAnchor,
        slot: Int,
        store: SlotStoreObservable,
        onClose: @escaping () -> Void,
        animates: Bool
    ) {
        guard let anchorView = anchor.view, anchorView.window != nil else { return }

        self.onClose = onClose
        self.currentSlot = slot

        // AT-4 (v2.10.30): tear down any previous hosting controller before
        // building a new one so switching content can't leak SwiftUI render trees.
        tearDownHosting()

        let hosting = NSHostingController(rootView: AttachmentManagerPopover(slot: slot, store: store))
        let pop = NSPopover()
        pop.contentViewController = hosting
        pop.contentSize = NSSize(width: 360, height: 480)
        // .semitransient：切到其他 App（Finder 拖文件）时不关闭；仅与主窗口交互时关闭。
        pop.behavior = .semitransient
        pop.animates = animates
        pop.delegate = self
        pop.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        self.popover = pop
        self.hosting = hosting
    }

    // AT-4 (v2.10.30): detach and release the current content hosting controller.
    // Removing its view from the hierarchy and dropping the strong reference lets
    // the SwiftUI render tree deallocate instead of lingering behind a replaced
    // popover.
    private func tearDownHosting() {
        hosting?.view.removeFromSuperview()
        hosting?.removeFromParent()
        hosting = nil
    }

    func close() {
        pendingShow = nil
        popover?.performClose(nil)
    }

    // MARK: NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        currentSlot = nil
        // AT-4 (v2.10.30): release the hosting controller once the popover is gone.
        tearDownHosting()
        let cb = onClose
        onClose = nil
        cb?()

        // 若在关闭前挂起了「切换到另一个槽位」的请求，此刻串行执行（下一 runloop 保证
        // 旧 popover 动画/资源彻底释放，新 popover 从零开始，无动画打架）。
        if let pending = pendingShow {
            pendingShow = nil
            DispatchQueue.main.async(execute: pending)
        }
    }
}
