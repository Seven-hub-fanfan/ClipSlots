import SwiftUI

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
                        .foregroundColor(.white)
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
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(SlotConnectionColor.color(for: colorId).opacity(colorId == nil ? 0.18 : 0.8), lineWidth: colorId == nil ? 1 : 2))
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

    private var attachmentCount: Int { store.attachments(for: slot).count }

    private var label: String {
        attachmentCount > 0 ? "附件 \(attachmentCount)" : "附件"
    }

    var body: some View {
        Button {
            NSLog("[ClipSlots] attachment button tapped slot=\(slot) count=\(attachmentCount)")
            showingAttachments = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: attachmentCount > 0 ? "paperclip.circle.fill" : "paperclip")
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(attachmentCount > 0 ? .white : .secondary)
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
        .buttonStyle(.plain)
        .help(attachmentCount > 0 ? "附件：\(attachmentCount) 个，点击管理" : "添加附件")
        .popover(isPresented: $showingAttachments, arrowEdge: .top) {
            AttachmentManagerPopover(slot: slot, store: store)
        }
    }
}
