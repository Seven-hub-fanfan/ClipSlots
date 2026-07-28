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
/// v2.10.24：切换槽位改为「并行开新关旧」方案（立即 show 新 popover + 异步 performClose 旧
/// popover）。但该方案存在严重时序竞态：`reallyShow` 中 `self.popover = pop` 在 `pop.show()`
/// **之后**才赋值，展示新 popover 时若同步触发旧 popover 的 `popoverDidClose`，此刻
/// `self.popover` 仍指向旧实例，guard 误判为「当前 popover」从而复位状态 / 触发 onClose，
/// 表现为「附件面板打开后立即被关闭」。
///
/// v2.10.25（本次）：彻底放弃「同时关旧 / 开新」思路，改为**复用同一个单例 NSPopover**：
///   - 控制器持有唯一的 `popover` 实例（init 时创建，delegate/behavior 固定），生命周期内不销毁。
///   - 切换槽位时只更新 `contentViewController`（换绑新槽位数据）并重新 `show(relativeTo:)`
///     锚定到新按钮——**不调用 close，也不等待任何关闭动画**。系统会把同一个 popover 自然地
///     从旧按钮移动到新按钮，切换瞬时完成，且完全不会触发 close 回调，从根本上杜绝
///     「刚打开就被关」的竞态。
///   - `popoverDidClose` 只在用户真正收起面板（点窗口其他区域、再次点同一按钮）时触发，
///     用于复位 `currentSlot` 并回调 onClose。
final class AttachmentManagerPanelController: NSObject, NSPopoverDelegate {
    /// 全局共享控制器：所有槽位的附件面板共用同一个控制器与同一个 NSPopover。
    static let shared = AttachmentManagerPanelController()

    /// 唯一复用的 popover 实例；生命周期内不重建，切换槽位时只更新内容 + 重新锚定。
    private let popover: NSPopover
    private var onClose: (() -> Void)?
    /// 当前 popover 正在展示的槽位号（用于「点同一个按钮再切换关闭」判断）。
    private(set) var currentSlot: Int?

    override init() {
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 360, height: 480)
        // .semitransient：切到其他 App（Finder 拖文件）时不关闭；仅与主窗口交互时关闭。
        pop.behavior = .semitransient
        pop.animates = true
        self.popover = pop
        super.init()
        pop.delegate = self
    }

    var isVisible: Bool { popover.isShown }

    /// 指定槽位的面板是否正在显示（点同一个附件按钮时用于切换关闭）。
    func isVisible(forSlot slot: Int) -> Bool {
        isVisible && currentSlot == slot
    }

    /// 相对附件按钮的 backing NSView 弹出 / 移动 popover（箭头锚定、跟随主窗口）。
    ///
    /// 复用单例（v2.10.25）：无论首次打开还是切换槽位，都只更新内容并重新锚定，绝不 close，
    /// 因此不会触发任何 close 回调，切换瞬时且无自关闭竞态。
    func show(
        anchor: AttachmentButtonScreenAnchor,
        slot: Int,
        store: SlotStoreObservable,
        onClose: @escaping () -> Void
    ) {
        guard let anchorView = anchor.view, anchorView.window != nil else { return }

        self.onClose = onClose
        self.currentSlot = slot

        // 复用同一 popover：换绑新槽位内容，再重新锚定到新按钮。已显示时系统会把它移动到新锚点，
        // 不调用 close、不等待动画，因此不会产生 close 回调，从根本上避免「打开即关闭」竞态。
        popover.contentViewController = NSHostingController(
            rootView: AttachmentManagerPopover(slot: slot, store: store)
        )
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
    }

    func close() {
        popover.performClose(nil)
    }

    // MARK: NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // 只处理本控制器自己的 popover 的真实关闭（用户点窗口其他区域 / 再次点同一按钮收起）。
        // 切换槽位走的是 show（不 close），不会进入这里，因此不存在旧实例误清空新面板的问题。
        guard let closed = notification.object as? NSPopover, closed === popover else {
            return
        }

        currentSlot = nil
        let cb = onClose
        onClose = nil
        cb?()
    }
}
