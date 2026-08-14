import SwiftUI
import ClipSlotsKit

// v2.7.5: SlotNodeView is now a pure card display. All port handles and
// drag logic have been moved to NodePortOverlay at the canvas level, fixing
// the z-index / hit-testing issue where only the last-rendered node (slot 10)
// could receive hover/drag events.

struct SlotNodeView: View {
    let slot: Int
    let content: SlotContent?
    let colorId: Int?
    let isHovered: Bool
    // v2.7.65: store is optional so existing pure-display call sites keep working.
    // v2.7.68: when store is provided, a bottom attachment bar (📎 + count) is
    // shown inside the card; the canvas-level bottom port sits just below it.
    var store: SlotStoreObservable? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("\(slot)")
                        .font(.system(size: 13, weight: .bold))
                        // v2.9.18: 彩色圆底上的编号文字统一到 AppTheme.onAccentText。
                        .foregroundColor(AppTheme.onAccentText)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(SlotConnectionColor.color(for: colorId) == .clear ? .accentColor : SlotConnectionColor.color(for: colorId)))
                    Text(slotDisplayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if let colorId {
                        Circle().fill(SlotConnectionColor.color(for: colorId)).frame(width: 7, height: 7)
                    }
                }
                Text(nodePreview)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(12)

            // v2.7.69: reserve the bottom bar space here (divider + fixed height)
            // for layout, but the INTERACTIVE attachment button is rendered by a
            // dedicated canvas-level overlay (NodeAttachmentBarOverlay) at the
            // highest zIndex so its taps are never swallowed by NodePortOverlay.
            if store != nil {
                Divider()
                Color.clear.frame(height: SlotNodeLayout.attachmentBarHeight)
            }
        }
        // v2.9.18: 卡片圆角硬编码 14 收敛到 AppTheme.cornerRadius（不改布局尺寸逻辑）。
        .background(RoundedRectangle(cornerRadius: AppTheme.cornerRadius).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.cornerRadius).stroke(SlotConnectionColor.color(for: colorId).opacity(colorId == nil ? 0.18 : 0.8), lineWidth: colorId == nil ? 1 : 2))
        // v2.9.19: hover 时叠加蓝色高亮描边。此前 isHovered 参数被接收却从未在 body 中使用，
        // 导致节点 hover 没有视觉反馈；这里用 accentColor 描边，深浅色均自动适配。
        // 未 hover 时 opacity=0 且不加动画，鼠标移出立即消失（无拖尾）。
        .overlay(RoundedRectangle(cornerRadius: AppTheme.cornerRadius).stroke(Color.accentColor.opacity(isHovered ? 0.9 : 0), lineWidth: 2))
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)
    }

    // v2.7.9: Node title shows slot name, not content preview.
    private var slotDisplayName: String { "槽位 \(slot)" }

    private var nodePreview: String {
        guard let content else { return "拖拽端口建立连接" }
        let text = content.plainText ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if content.hasImage || content.isImageFile { return "[图片]" }
        if content.isFileContent { return "[文件] \(content.fileDisplayName ?? "")" }
        return content.preview
    }
}

// MARK: - Attachment Button (canvas-level overlay)

// Shared layout constants so the card reserves exactly the space the overlay
// button occupies.
enum SlotNodeLayout {
    static let attachmentBarHeight: CGFloat = 30
}

// v2.7.69: A labelled 📎「附件」pill. Rendered by NodeAttachmentBarOverlay at the
// canvas level ABOVE NodePortOverlay so its taps are never swallowed.
struct NodeAttachmentButton: View {
    let slot: Int
    @ObservedObject var store: SlotStoreObservable
    @State private var showingAttachments = false
    @State private var showingClearConfirm = false
    @State private var isHoveringAttachmentControl = false
    // v2.7.75: local mirror of the "不再提醒" toggle inside the confirm popover.
    @State private var suppressConfirmToggle = false

    // v2.10.22: 附件面板改回跟随主窗口的 NSPopover 承载（见 AttachmentManagerPanel.swift）。
    // v2.10.23: 控制器改用全局单例 AttachmentManagerPanelController.shared，所有槽位共用同一个
    //           NSPopover 生命周期，切换槽位时「关→开」串行化，消除动画打架/卡顿。
    private var panelController: AttachmentManagerPanelController { .shared }
    @State private var buttonAnchor = AttachmentButtonScreenAnchor()

    // v2.7.75: persisted preference — when true, the red ✕ clears attachments
    // immediately without showing the confirm popover. Shared across all nodes.
    private static let suppressClearConfirmKey = "suppressAttachmentClearConfirm"
    private var suppressClearConfirm: Bool {
        UserDefaults.standard.bool(forKey: Self.suppressClearConfirmKey)
    }

    // v2.10.89 (perf · ★hover 切槽位卡顿的第二条根因：主线程同步 I/O): 附件数改为「调用方传入优先」。
    //
    // v2.10.88 已修掉 hover 路径上两处**渲染**开销（阴影模糊半径逐帧重算、scaleEffect 作用于未拍平
    // 子树）。但卡顿还有一条与渲染无关的来源：本按钮在 body 里反复做同步存储读。
    //
    // 原实现是 `private var attachmentCount: Int { store.attachments(for: slot).count }`，而
    // `store.attachments(for:)` → `specialStorage.get(slot, in:)` → `SlotStorage.loadContentOrUnknown`
    // 是一次**存储读**：即便走的是不加 flock 的快路径，也仍要付 `dirFingerprint()` 的 `stat(2)`
    // 系统调用 + 一次 `queue.sync` 串行队列跳转（若该队列正被后台读盘占用，主线程会直接被阻塞）。
    //
    // 致命之处在于它是 computed property，而 body 与 `pill` 里对 `attachmentCount` 的引用有
    // **9 处**（pill 的 icon / label×2 / foregroundColor / background / overlay，body 的 help×2、
    // `if attachmentCount > 0`）——即一次 body 求值就是 9 次存储读。本按钮又内嵌在每张槽位卡片里
    // （×10），且以 `@ObservedObject store` 观察巨型主 store，**绕过了卡片 `.equatable()` 的短路**，
    // 于是任何主 store 变更、以及任何一次卡片 body 重算，都会放大成约 90 次主线程 stat + queue.sync。
    //
    // 对 hover 的影响：hover 改的是卡片自身的 @State（Equatable 拦不住），离开的卡 + 进入的卡各重算
    // 一次 body → 约 18 次同步 I/O 正好压在缩放动画的头几帧上。
    // 影响面其实远大于 hover：每次保存 / 清空 / 弹 Toast / 切组，只要主 store 发一次 objectWillChange，
    // 就会触发这约 90 次主线程存储读。
    //
    // 修法两层：
    //   1) 调用方若已持有权威内容（主网格的 SlotCardView 有 `content`），直接把 count 传进来 →
    //      热路径**零存储读**；
    //   2) 未传时仍回退存储读，但 body 内**只求值一次**（见 body 里的 `let count`），9 次降为 1 次。
    var attachmentCountOverride: Int? = nil

    /// 解析出本次渲染要用的附件数。**只应在 body 顶部求值一次**，然后把结果传下去。
    private var resolvedAttachmentCount: Int {
        if let attachmentCountOverride { return attachmentCountOverride }
        return store.attachments(for: slot).count
    }

    private var isClearButtonVisible: Bool {
        isHoveringAttachmentControl || showingClearConfirm
    }

    var body: some View {
        // v2.10.88: 整个 body（含 pill 与确认弹窗）共用这一次求值，杜绝重复存储读。
        let count = resolvedAttachmentCount

        // v2.7.74: pill (open manager) + red ✕ clear entry as SIBLING buttons in the
        // same top-most (zIndex 30) overlay layer, so both taps land reliably.
        return ZStack(alignment: .topTrailing) {
            Button {
                NSLog("[ClipSlots] attachment button tapped slot=\(slot) count=\(count)")
                toggleAttachmentPanel()
            } label: {
                pill(count: count)
            }
            .buttonStyle(.plain)
            .help(count > 0 ? "附件：\(count) 个，点击管理" : "添加附件")
            // v2.10.20: 用透明背景视图持续上报按钮的屏幕矩形，供浮动面板定位与关闭判断。
            .background(AttachmentButtonAnchorReporter(holder: buttonAnchor))

            if count > 0 {
                Button {
                    // v2.7.75: honor the persisted "不再提醒" preference.
                    if suppressClearConfirm {
                        store.setAttachments([], for: slot)
                    } else {
                        suppressConfirmToggle = false
                        showingClearConfirm = true
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .symbolRenderingMode(.palette)
                        // v2.9.18: 裸写 .white/.red 收敛到 AppTheme.onAccentText / AppTheme.danger。
                        .foregroundStyle(AppTheme.onAccentText, AppTheme.danger)
                        .background(Circle().fill(Color.white).frame(width: 10, height: 10))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("清空该槽位全部附件")
                .offset(x: 5, y: -6)
                .opacity(isClearButtonVisible ? 1 : 0)
                .allowsHitTesting(isClearButtonVisible)
                .animation(Anim.interactive, value: isClearButtonVisible)
                .popover(isPresented: $showingClearConfirm, arrowEdge: .top) {
                    clearConfirmPopover(count: count)
                }
            }
        }
        .onHover { isHoveringAttachmentControl = $0 }
    }

    // v2.10.22: 再次点击切换开合；打开时用附件按钮 backing NSView 锚定 NSPopover。
    // 带兜底重试：若首帧 view.window 尚未就绪（isReady == false），下一 runloop 再试一次，
    // 避免 v2.10.19 时序竞态导致「部分槽位点击无反应」。
    private func toggleAttachmentPanel() {
        // v2.10.23: 用共享控制器判断「当前展示的是否正是本槽位」——
        //   是 → 再次点击同一按钮，收起面板；
        //   否（未显示 / 显示的是别的槽位）→ present，控制器内部会串行「关旧→开新」。
        if panelController.isVisible(forSlot: slot) {
            panelController.close()
            showingAttachments = false
            return
        }
        presentAttachmentPanel(retry: true)
    }

    private func presentAttachmentPanel(retry: Bool) {
        guard buttonAnchor.isReady else {
            if retry {
                DispatchQueue.main.async { self.presentAttachmentPanel(retry: false) }
            }
            return
        }
        panelController.show(
            anchor: buttonAnchor,
            slot: slot,
            store: store,
            onClose: { showingAttachments = false }
        )
        showingAttachments = true
    }

    // v2.7.75: custom confirm popover carrying a "不再提醒" toggle.
    private func clearConfirmPopover(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 18))
                    // v2.9.18: 裸写 .red 收敛到 AppTheme.danger。
                    .foregroundColor(AppTheme.danger)
                Text("清空该槽位的全部附件？")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text("将删除该槽位当前的 \(count) 个附件，此操作无法撤销。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("不再提醒", isOn: $suppressConfirmToggle)
                .toggleStyle(.checkbox)
                .font(.caption)

            HStack(spacing: 8) {
                Spacer()
                Button("取消") { showingClearConfirm = false }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    if suppressConfirmToggle {
                        UserDefaults.standard.set(true, forKey: Self.suppressClearConfirmKey)
                    }
                    store.setAttachments([], for: slot)
                    showingClearConfirm = false
                } label: {
                    Text("清空 \(count) 个附件")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private func pill(count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: count > 0 ? "paperclip.circle.fill" : "paperclip")
                .font(.system(size: 12, weight: .semibold))
            Text(count > 0 ? "附件 \(count)" : "附件")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        // v2.9.18: 品牌渐变胶囊上的文字统一到 AppTheme.onAccentText。
        .foregroundColor(count > 0 ? AppTheme.onAccentText : .secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            Capsule().fill(
                count > 0
                    ? AnyShapeStyle(AppTheme.brandGradient(.light))
                    : AnyShapeStyle(Color(NSColor.controlBackgroundColor))
            )
        )
        .overlay(Capsule().stroke(Color.secondary.opacity(count > 0 ? 0 : 0.35), lineWidth: 1))
        .contentShape(Capsule())
    }
}
