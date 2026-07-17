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
    // v2.7.75: local mirror of the "不再提醒" toggle inside the confirm popover.
    @State private var suppressConfirmToggle = false

    // v2.7.75: persisted preference — when true, the red ✕ clears attachments
    // immediately without showing the confirm popover. Shared across all nodes.
    private static let suppressClearConfirmKey = "suppressAttachmentClearConfirm"
    private var suppressClearConfirm: Bool {
        UserDefaults.standard.bool(forKey: Self.suppressClearConfirmKey)
    }

    private var attachmentCount: Int { store.attachments(for: slot).count }

    private var label: String {
        attachmentCount > 0 ? "附件 \(attachmentCount)" : "附件"
    }

    var body: some View {
        // v2.7.74: pill (open manager) + red ✕ clear entry as SIBLING buttons in the
        // same top-most (zIndex 30) overlay layer, so both taps land reliably.
        ZStack(alignment: .topTrailing) {
            Button {
                NSLog("[ClipSlots] attachment button tapped slot=\(slot) count=\(attachmentCount)")
                showingAttachments = true
            } label: {
                pill
            }
            .buttonStyle(.plain)
            .help(attachmentCount > 0 ? "附件：\(attachmentCount) 个，点击管理" : "添加附件")
            .popover(isPresented: $showingAttachments, arrowEdge: .top) {
                AttachmentManagerPopover(slot: slot, store: store)
            }
            // v2.9.37: when the attachment panel closes, run any auto-advance that
            // was deferred because this slot had attachments (avoids interrupting
            // attachment pasting by switching groups too early).
            .onChange(of: showingAttachments) { isShowing in
                if !isShowing {
                    store.firePendingAutoAdvanceOnPanelClose(for: slot)
                }
            }

            if attachmentCount > 0 {
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
                .popover(isPresented: $showingClearConfirm, arrowEdge: .top) {
                    clearConfirmPopover
                }
            }
        }
    }

    // v2.7.75: custom confirm popover carrying a "不再提醒" toggle.
    private var clearConfirmPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 18))
                    // v2.9.18: 裸写 .red 收敛到 AppTheme.danger。
                    .foregroundColor(AppTheme.danger)
                Text("清空该槽位的全部附件？")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text("将删除该槽位当前的 \(attachmentCount) 个附件，此操作无法撤销。")
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
                    Text("清空 \(attachmentCount) 个附件")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private var pill: some View {
        HStack(spacing: 4) {
            Image(systemName: attachmentCount > 0 ? "paperclip.circle.fill" : "paperclip")
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        // v2.9.18: 品牌渐变胶囊上的文字统一到 AppTheme.onAccentText。
        .foregroundColor(attachmentCount > 0 ? AppTheme.onAccentText : .secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            Capsule().fill(
                attachmentCount > 0
                    ? AnyShapeStyle(AppTheme.brandGradient(.light))
                    : AnyShapeStyle(Color(NSColor.controlBackgroundColor))
            )
        )
        .overlay(Capsule().stroke(Color.secondary.opacity(attachmentCount > 0 ? 0 : 0.35), lineWidth: 1))
        .contentShape(Capsule())
    }
}
