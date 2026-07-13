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
    // v2.7.66: the attachment entry is now rendered by NodeAttachmentButtonOverlay
    // at canvas level (above NodePortOverlay) so it always receives clicks; this
    // view stays a pure card display again.
    var store: SlotStoreObservable? = nil

    var body: some View {
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
                // v2.7.66: leave room on the top-right for the canvas-level
                // attachment button overlay so it never overlaps the color dot.
                if store != nil {
                    Color.clear.frame(width: 20, height: 20)
                }
                if let colorId {
                    Circle().fill(SlotConnectionColor.color(for: colorId)).frame(width: 7, height: 7)
                }
            }
            Text(nodePreview)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(12)
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

// v2.7.66: Rendered ABOVE NodePortOverlay at the canvas level so the 📎 button
// always receives clicks (previously it lived inside SlotNodeView, which sits
// below the port overlay's zIndex and could have its taps swallowed). The entry
// is always available so users can add the first attachment on an empty slot.
struct NodeAttachmentButton: View {
    let slot: Int
    @ObservedObject var store: SlotStoreObservable
    @State private var showingAttachments = false

    private var attachmentCount: Int { store.attachments(for: slot).count }

    var body: some View {
        Button {
            showingAttachments = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: attachmentCount > 0 ? "paperclip.circle.fill" : "paperclip")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(attachmentCount > 0 ? .accentColor : .secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color(NSColor.controlBackgroundColor)))
                    .contentShape(Circle())
                if attachmentCount > 0 {
                    Text("\(attachmentCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(AppTheme.brandGradient(.light)))
                        .offset(x: 6, y: -6)
                        .contentTransition(.numericText())
                }
            }
        }
        .buttonStyle(.plain)
        .help(attachmentCount > 0 ? "附件：\(attachmentCount) 个，点击管理" : "添加附件")
        .popover(isPresented: $showingAttachments, arrowEdge: .top) {
            AttachmentManagerPopover(slot: slot, store: store)
        }
    }
}
