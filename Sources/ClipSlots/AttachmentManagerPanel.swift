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
    // C-6 (v2.10.31): 恢复 pendingShow token 机制。切换槽位时 reallyShow 会被 defer 到
    // 下一个 main-loop tick 执行；若用户连续快速切换槽位，早前排队的异步 show 可能在更
    // 新的 show 之后才执行，从而用过期的槽位/store 覆盖最新状态（竞态）。为此给每次 show
    // 分配一个递增 token，异步回调里校验 token 仍是最新才真正展示，过期请求直接丢弃。
    private var pendingShowToken: Int = 0

    // UX (v2.10.46): 切换槽位时的淡入淡出时长。此前（v2.10.29）为消卡顿改成硬切/瞬切，
    // 现性能已 OK，补回极短过渡：旧面板内容淡出 → 关闭 → 新面板内容淡入，形成柔和过手感。
    private let switchFadeDuration: TimeInterval = 0.12
    // 正在淡出、尚未真正关闭的旧 popover。用于在下一次 show 到来时立即硬关，避免叠加。
    private var fadingOutPopover: NSPopover?

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
    /// v2.10.29 曾改成同步无动画硬切消卡顿；v2.10.46 性能已 OK，补回极短过渡：
    /// 旧面板内容淡出 0.12s → 瞬时关闭 → 新面板内容淡入 0.12s，形成柔和过手感，
    /// 且用 fadingOutPopover 硬关兜底避免连点叠加。首次打开仍走系统淡入动画。
    func show(
        anchor: AttachmentButtonScreenAnchor,
        slot: Int,
        store: SlotStoreObservable,
        onClose: @escaping () -> Void
    ) {
        guard anchor.view?.window != nil else { return }

        // C-6 (v2.10.31): 每次 show 领取一个新 token，作废所有在途的 pending show 请求。
        pendingShowToken &+= 1
        let token = pendingShowToken

        // UX (v2.10.46): 若上一次切换的旧面板还在淡出，立即硬关，避免两个 popover 叠加。
        hardCloseFadingOut()

        // 已经打开（可能是别的槽位）→ 淡出旧面板内容后关闭，再淡入新面板。
        if let existing = popover, existing.isShown {
            pendingShow = nil
            existing.delegate = nil
            // 手动回调上一个槽位的 onClose（原本由 popoverDidClose 负责）。
            let previousOnClose = self.onClose
            self.onClose = nil
            previousOnClose?()
            currentSlot = nil
            popover = nil

            // 交给淡出通道：内容 alpha 1→0（0.12s），完成后关闭旧 popover 并淡入新面板。
            fadingOutPopover = existing
            fadeOutContent(of: existing, duration: switchFadeDuration) { [weak self] in
                guard let self else { return }
                if self.fadingOutPopover === existing {
                    existing.animates = false
                    existing.close()
                    self.fadingOutPopover = nil
                }
                // C-6 (v2.10.31): 仅当仍是最新一次 show 请求时才真正展示；否则说明用户
                // 已再次切换槽位，本次为过期请求，直接丢弃，避免覆盖新状态。
                // 淡出完成回调发生在当前 runloop 之后，附件按钮 backing NSView 的重排也已
                // settle（原 AT-3 的一个 runloop micro-defer 由 0.12s 淡出自然覆盖）。
                guard token == self.pendingShowToken else { return }
                self.reallyShow(anchor: anchor, slot: slot, store: store, onClose: onClose, animates: false, fadeIn: true)
            }
        } else {
            // 首次打开：保留原有系统淡入动画。
            reallyShow(anchor: anchor, slot: slot, store: store, onClose: onClose, animates: true, fadeIn: false)
        }
    }

    /// 立即硬关正在淡出的旧 popover（无动画），用于下一次 show 到来时防叠加。
    private func hardCloseFadingOut() {
        guard let fading = fadingOutPopover else { return }
        fading.delegate = nil
        fading.animates = false
        fading.close()
        fadingOutPopover = nil
    }

    /// 将 popover 内容视图的 alpha 在 duration 内淡出到 0，完成后回调。
    private func fadeOutContent(of popover: NSPopover, duration: TimeInterval, completion: @escaping () -> Void) {
        guard let view = popover.contentViewController?.view else { completion(); return }
        view.wantsLayer = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.allowsImplicitAnimation = true
            view.animator().alphaValue = 0
        }, completionHandler: completion)
    }

    /// 真正创建并展示 popover。要求锚点 NSView 已在窗口层级中。
    /// - Parameter animates: 是否带系统淡入动画（首次打开为 true）。
    /// - Parameter fadeIn: 切换槽位时是否对新内容做 0.12s 自定义淡入（瞬时定位 + 内容淡入，去卡顿）。
    private func reallyShow(
        anchor: AttachmentButtonScreenAnchor,
        slot: Int,
        store: SlotStoreObservable,
        onClose: @escaping () -> Void,
        animates: Bool,
        fadeIn: Bool
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
        // UX (v2.10.46): 切换场景先把内容置透明，show 后再淡入，避免硬切跳变。
        if fadeIn {
            hosting.view.wantsLayer = true
            hosting.view.alphaValue = 0
        }
        pop.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        self.popover = pop
        self.hosting = hosting

        if fadeIn {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = switchFadeDuration
                ctx.allowsImplicitAnimation = true
                hosting.view.animator().alphaValue = 1
            }
        }
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
