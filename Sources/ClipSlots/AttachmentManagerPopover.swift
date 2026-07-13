import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// v2.7.65: Attachment management UI for the node canvas.
//
// Design (confirmed): a 360×480 popover triggered by the 📎 icon on a slot node
// card. Three sections — header, scrollable attachment list, bottom "add" bar with
// five type buttons. All colors route through AppTheme / SlotConnectionColor so the
// component stays consistent with the canvas and adapts to dark / light mode.

// MARK: - Attachment Type Styling

extension SlotContent.AttachmentType {
    var displayName: String {
        switch self {
        case .image:     return "图片"
        case .file:      return "文件"
        case .text:      return "文本"
        case .url:       return "链接"
        case .reference: return "引用"
        }
    }

    var iconName: String {
        switch self {
        case .image:     return "photo"
        case .file:      return "doc.fill"
        case .text:      return "text.alignleft"
        case .url:       return "link"
        case .reference: return "arrow.triangle.branch"
        }
    }

    /// Reuses the canvas connection palette so attachment colors are same-source.
    var accentColor: Color {
        switch self {
        case .image:     return SlotConnectionColor.cyan.swiftUIColor
        case .file:      return SlotConnectionColor.blue.swiftUIColor
        case .text:      return SlotConnectionColor.green.swiftUIColor
        case .url:       return SlotConnectionColor.purple.swiftUIColor
        case .reference: return SlotConnectionColor.orange.swiftUIColor
        }
    }
}

// MARK: - Attachment Manager Popover

struct AttachmentManagerPopover: View {
    let slot: Int
    @ObservedObject var store: SlotStoreObservable
    @Environment(\.colorScheme) private var scheme

    // v2.8.0 (P1-5): the attachment list is derived live from the store instead of
    // an init-time snapshot, so external mutations (e.g. the red-x clear on the
    // node card, or another popover) are reflected immediately. All writes are
    // read-modify-write against the latest store state so they never clobber a
    // concurrent change made elsewhere.
    @State private var inlineEditor: InlineEditorKind?
    @State private var draftName: String = ""
    @State private var draftValue: String = ""
    // v2.8.2 (P2-2): inline validation message shown under the editor field.
    @State private var inlineError: String? = nil
    // v2.8.7: pure DragGesture reordering (no system drag ghost image).
    // draggingId marks the row under the finger, dragTranslation is the raw
    // vertical delta, and dragStartIndex pins the origin so the target index
    // can be derived from the fixed step height.
    @State private var draggingId: UUID? = nil
    @State private var dragTranslation: CGFloat = 0
    @State private var dragStartIndex: Int? = nil
    // Row height (56) + VStack spacing (8) == vertical distance between rows.
    private let rowStep: CGFloat = 64

    enum InlineEditorKind: Equatable { case text, url, reference }

    init(slot: Int, store: SlotStoreObservable) {
        self.slot = slot
        self.store = store
    }

    /// Live view of this slot's attachments straight from the store.
    private var attachments: [SlotContent.SlotAttachment] {
        store.attachments(for: slot)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            listArea
            Divider()
            addBar
        }
        .frame(width: 360, height: 480)
        .background(AppTheme.elevatedBackground(scheme))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14, weight: .semibold))
                    Text("附件")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text("粘贴槽位 \(slot) 时依次带出")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("\(attachments.count) 项")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.chipBackground(scheme)))
        }
        .padding(16)
    }

    // MARK: List

    private var listArea: some View {
        Group {
            if attachments.isEmpty && inlineEditor == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        let items = attachments
                        ForEach(items, id: \.id) { att in
                            attachmentRow(for: att)
                        }

                        if let kind = inlineEditor {
                            inlineEditorView(kind)
                        }
                    }
                    .padding(12)
                }
                .coordinateSpace(name: "attachmentList")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // v2.8.7: offset applied to the row currently being dragged so it tracks the
    // finger. Because live reordering shifts the dragged row between slots, we
    // subtract the slots already crossed (cur - start) * step from the raw
    // translation, keeping the row visually glued to the pointer.
    private var liveDragOffset: CGFloat {
        guard let id = draggingId, let start = dragStartIndex,
              let cur = attachments.firstIndex(where: { $0.id == id }) else { return 0 }
        return dragTranslation - CGFloat(cur - start) * rowStep
    }

    @ViewBuilder
    private func attachmentRow(for att: SlotContent.SlotAttachment) -> some View {
        let isDragging = draggingId == att.id
        AttachmentRow(
            attachment: att,
            scheme: scheme,
            isDragging: isDragging,
            dragActive: draggingId != nil,
            dragOffset: isDragging ? liveDragOffset : 0,
            onDelete: { remove(att) },
            onDragChanged: { translation in handleDragChanged(att.id, translation) },
            onDragEnded: { handleDragEnded() }
        )
        .zIndex(isDragging ? 1 : 0)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "paperclip")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.4))
            Text("还没有附件")
                .font(.callout)
                .foregroundColor(.secondary)
            Text("从下方添加，粘贴时会一起带出")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Inline editor (text / url / reference)

    private func inlineEditorView(_ kind: InlineEditorKind) -> some View {
        let accent: Color = {
            switch kind {
            case .text: return SlotContent.AttachmentType.text.accentColor
            case .url: return SlotContent.AttachmentType.url.accentColor
            case .reference: return SlotContent.AttachmentType.reference.accentColor
            }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            TextField("名称（可选）", text: $draftName)
                .textFieldStyle(.plain)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.searchFieldBackground(scheme)))
            TextField(placeholder(for: kind), text: $draftValue)
                .textFieldStyle(.plain)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.searchFieldBackground(scheme)))
            if let inlineError {
                Text(inlineError)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
            HStack {
                Spacer()
                Button("取消") { cancelInline() }
                    .buttonStyle(.borderless)
                Button("添加") { commitInline(kind) }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(draftValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius).fill(AppTheme.cardBackground(scheme)))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius).stroke(accent.opacity(0.5), lineWidth: 1))
    }

    private func placeholder(for kind: InlineEditorKind) -> String {
        switch kind {
        case .text: return "输入文本内容"
        case .url: return "https://…"
        case .reference: return "引用的槽位序号（1-10）"
        }
    }

    // MARK: Add bar

    private var addBar: some View {
        HStack(spacing: 8) {
            addButton(.image) { pickFile(imagesOnly: true) }
            addButton(.file) { pickFile(imagesOnly: false) }
            addButton(.text) { openInline(.text) }
            addButton(.url) { openInline(.url) }
            addButton(.reference) { openInline(.reference) }
        }
        .padding(12)
    }

    private func addButton(_ type: SlotContent.AttachmentType, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: type.iconName)
                    .font(.system(size: 15, weight: .medium))
                Text(type.displayName)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.softButtonBackground(scheme)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
        .help("添加\(type.displayName)附件")
    }

    // MARK: Actions

    private func openInline(_ kind: InlineEditorKind) {
        draftName = ""
        draftValue = ""
        inlineError = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            inlineEditor = kind
        }
    }

    private func cancelInline() {
        inlineError = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            inlineEditor = nil
        }
    }

    private func commitInline(_ kind: InlineEditorKind) {
        let value = draftValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        var att: SlotContent.SlotAttachment
        switch kind {
        case .text:
            att = SlotContent.SlotAttachment(name: name.isEmpty ? String(value.prefix(20)) : name,
                                             type: .text, data: value.data(using: .utf8))
        case .url:
            att = SlotContent.SlotAttachment(name: name.isEmpty ? value : name, type: .url, url: value)
        case .reference:
            // v2.8.2 (P2-2): validate the referenced slot index is an integer in
            // 1...10 instead of silently accepting arbitrary text that would later
            // resolve to an empty payload at paste time.
            guard let index = Int(value), (1...10).contains(index) else {
                inlineError = "请输入 1-10 之间的槽位序号"
                return
            }
            att = SlotContent.SlotAttachment(name: name.isEmpty ? "引用槽位 \(index)" : name,
                                             type: .reference, path: String(index))
        }
        inlineError = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            var current = store.attachments(for: slot)
            current.append(att)
            store.setAttachments(current, for: slot)
            inlineEditor = nil
        }
    }

    private func pickFile(imagesOnly: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if imagesOnly, #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.image]
        }
        guard panel.runModal() == .OK else { return }
        var current = store.attachments(for: slot)
        for url in panel.urls {
            let type: SlotContent.AttachmentType = imagesOnly ? .image : .file
            let att = SlotContent.SlotAttachment(
                name: url.lastPathComponent,
                type: type,
                path: url.path
            )
            current.append(att)
        }
        store.setAttachments(current, for: slot)
    }

    private func remove(_ att: SlotContent.SlotAttachment) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            var current = store.attachments(for: slot)
            current.removeAll { $0.id == att.id }
            store.setAttachments(current, for: slot)
        }
    }

    // v2.8.7: pure DragGesture reordering. Display order == paste order == add
    // order, so rearranging rows directly rewrites the stored array. The gesture
    // lives on the handle only; the rest of the row keeps hover/preview.
    private func handleDragChanged(_ id: UUID, _ translation: CGFloat) {
        if draggingId != id {
            draggingId = id
            dragStartIndex = attachments.firstIndex(where: { $0.id == id })
        }
        dragTranslation = translation
        guard let start = dragStartIndex else { return }
        var current = store.attachments(for: slot)
        guard let cur = current.firstIndex(where: { $0.id == id }) else { return }
        // Target index derived from the fixed origin plus whole steps crossed.
        let steps = Int((translation / rowStep).rounded())
        let target = max(0, min(current.count - 1, start + steps))
        if target != cur {
            let moved = current.remove(at: cur)
            current.insert(moved, at: target)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                store.setAttachments(current, for: slot)
            }
        }
    }

    private func handleDragEnded() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            draggingId = nil
            dragTranslation = 0
            dragStartIndex = nil
        }
    }
}

// MARK: - Attachment Row

struct AttachmentRow: View {
    let attachment: SlotContent.SlotAttachment
    let scheme: ColorScheme
    let isDragging: Bool
    // v2.8.7: true when any row in the list is being dragged, used to suppress
    // hover previews for every row during a reorder.
    let dragActive: Bool
    // v2.8.7: vertical offset so the dragged row follows the finger.
    let dragOffset: CGFloat
    let onDelete: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var isHovered = false
    @State private var deleteHovered = false
    // v2.8.5: hover preview popover, opened after a short dwell so scrolling past
    // rows does not flash previews. Closed immediately when the pointer leaves.
    @State private var showPreview = false
    @State private var hoverToken = 0

    var body: some View {
        HStack(spacing: 10) {
            AttachmentThumbnail(attachment: attachment)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(deleteHovered ? Color(red: 1.0, green: 0.27, blue: 0.23) : .secondary)
            }
            .buttonStyle(.plain)
            .onHover { deleteHovered = $0 }
            .help("删除附件")

            // v2.8.8: AppKit-backed drag handle. The manager lives inside an
            // NSPopover launched from a sheet; when that popover window is not
            // key yet, a SwiftUI DragGesture loses its first mouseDown (it is
            // consumed only to make the window key, because the backing
            // NSHostingView returns acceptsFirstMouse == false), so the first
            // drag "does nothing" and the user has to press again. This handle
            // overrides acceptsFirstMouse == true, so the very first press is
            // delivered regardless of key state; routing events through a
            // dedicated NSView also keeps the enclosing ScrollView from
            // stealing the drag. Only this handle starts a reorder, so the rest
            // of the row keeps its hover-preview behaviour, and no system drag
            // payload / ghost image is produced.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 36)
                .contentShape(Rectangle())
                .help("拖动排序")
                .overlay(
                    FirstMouseDragHandle(
                        onChanged: { dy in
                            showPreview = false
                            onDragChanged(dy)
                        },
                        onEnded: { onDragEnded() }
                    )
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius).fill(AppTheme.cardBackground(scheme)))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius)
                .stroke(isHovered ? attachment.type.accentColor.opacity(0.5) : AppTheme.subtleBorder(scheme), lineWidth: 1)
        )
        .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: isDragging ? 8 : 0, y: isDragging ? 4 : 0)
        .scaleEffect(isDragging ? 1.02 : 1)
        .offset(y: dragOffset)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering && !dragActive {
                hoverToken += 1
                let token = hoverToken
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if isHovered && token == hoverToken && !dragActive { showPreview = true }
                }
            } else {
                showPreview = false
            }
        }
        .popover(isPresented: $showPreview, arrowEdge: .trailing) {
            AttachmentPreviewContent(attachment: attachment, scheme: scheme)
                .frame(width: 340, height: 300)
        }
    }

    private var subtitle: String {
        switch attachment.type {
        case .image, .file:
            return attachment.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "本地文件"
        case .url:
            return attachment.url ?? ""
        case .text:
            let text = attachment.data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return String(text.prefix(30))
        case .reference:
            return attachment.path.map { "→ 槽位 \($0)" } ?? "引用"
        }
    }
}

// MARK: - Thumbnail
/// v2.8.5: real thumbnail for the left leading cell. Images render their pixels,
/// videos render the first frame, other files render the Finder icon, and
/// text/url/reference fall back to the semantic accent icon. All heavy work runs
/// off the main thread and degrades gracefully to the icon on any failure.
private struct AttachmentThumbnail: View {
    let attachment: SlotContent.SlotAttachment
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(attachment.type.accentColor.opacity(0.15))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: attachment.type.iconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(attachment.type.accentColor)
            }
        }
        .frame(width: 32, height: 32)
        .task(id: attachment.id) {
            let att = attachment
            let loaded = await Task.detached(priority: .utility) {
                AttachmentThumbnailProvider.thumbnail(for: att, maxPixel: 64)
            }.value
            if !Task.isCancelled { image = loaded }
        }
    }
}

enum AttachmentThumbnailProvider {
    /// Returns a small NSImage suitable as a leading cell, or nil to fall back to
    /// the semantic icon. `maxPixel` bounds the longest edge for memory safety.
    static func thumbnail(for att: SlotContent.SlotAttachment, maxPixel: CGFloat) -> NSImage? {
        switch att.type {
        case .image:
            if let path = att.path, !path.isEmpty, let img = NSImage(contentsOfFile: path) {
                return resized(img, maxPixel: maxPixel)
            }
            if let data = att.data, let img = NSImage(data: data) {
                return resized(img, maxPixel: maxPixel)
            }
            return nil
        case .file:
            guard let path = att.path, !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path)
            if isVideo(url), let frame = videoFrame(url: url, maxPixel: maxPixel) {
                return frame
            }
            // Finder icon is always available even for missing files.
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: maxPixel, height: maxPixel)
            return icon
        default:
            return nil
        }
    }

    static func fullImage(for att: SlotContent.SlotAttachment) -> NSImage? {
        switch att.type {
        case .image:
            if let path = att.path, !path.isEmpty, let img = NSImage(contentsOfFile: path) { return img }
            if let data = att.data, let img = NSImage(data: data) { return img }
            return nil
        case .file:
            guard let path = att.path, !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path)
            if isVideo(url) { return videoFrame(url: url, maxPixel: 640) }
            return nil
        default:
            return nil
        }
    }

    static func isVideo(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .movie) || type.conforms(to: .video)
        }
        return false
    }

    static func videoFrame(url: URL, maxPixel: CGFloat) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func resized(_ image: NSImage, maxPixel: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(maxPixel / size.width, maxPixel / size.height, 1)
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let out = NSImage(size: target)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}

// MARK: - Hover Preview Content

/// v2.8.5: rich hover preview. Mirrors the visual language of RadialPreviewPanel
/// (large image, video first-frame card, adaptive text/file cards) but is a
/// standalone lightweight view so it never depends on the radial menu internals.
private struct AttachmentPreviewContent: View {
    let attachment: SlotContent.SlotAttachment
    let scheme: ColorScheme

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .background(AppTheme.elevatedBackground(scheme))
    }

    @ViewBuilder
    private var content: some View {
        switch attachment.type {
        case .image:
            imageOrFallback
        case .file:
            fileContent
        case .text:
            textCard(bodyText)
        case .url:
            textCard(attachment.url ?? attachment.name)
        case .reference:
            referenceCard
        }
    }

    // Image / file first-frame preview
    @ViewBuilder
    private var imageOrFallback: some View {
        AsyncPreviewImage(attachment: attachment) {
            fileCard(icon: "photo", title: "图片缺失")
        }
    }

    @ViewBuilder
    private var fileContent: some View {
        if let path = attachment.path, !path.isEmpty,
           AttachmentThumbnailProvider.isVideo(URL(fileURLWithPath: path)) {
            AsyncPreviewImage(attachment: attachment) {
                fileCard(icon: "play.rectangle.fill", title: "视频")
            }
        } else {
            fileCard(icon: "doc.fill", title: "文件")
        }
    }

    private var bodyText: String {
        attachment.data.flatMap { String(data: $0, encoding: .utf8) } ?? attachment.name
    }

    private func textCard(_ text: String) -> some View {
        ScrollView {
            Text(text.isEmpty ? "空内容" : text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Color(NSColor.labelColor))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(10)
    }

    private var referenceCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(SlotContent.AttachmentType.reference.accentColor)
            Text("引用槽位")
                .font(.system(size: 13, weight: .semibold))
            Text(attachment.path.map { "→ 槽位 \($0)" } ?? attachment.name)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(10)
    }

    private func fileCard(icon: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(attachment.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? attachment.name)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            if let path = attachment.path, !path.isEmpty {
                Text(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(10)
    }
}

/// Loads a large preview image (or video first frame) asynchronously, showing a
/// spinner while loading and the provided fallback on failure.
private struct AsyncPreviewImage<Fallback: View>: View {
    let attachment: SlotContent.SlotAttachment
    @ViewBuilder let fallback: () -> Fallback

    @State private var image: NSImage?
    @State private var loaded = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loaded {
                fallback()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: attachment.id) {
            let att = attachment
            let img = await Task.detached(priority: .userInitiated) {
                AttachmentThumbnailProvider.fullImage(for: att)
            }.value
            if !Task.isCancelled {
                image = img
                loaded = true
            }
        }
    }
}


// v2.8.8: AppKit-backed drag handle that accepts the first mouse.
//
// SwiftUI's DragGesture relies on the backing NSHostingView receiving the
// initial mouseDown. Inside an NSPopover that is not yet the key window (this
// manager is presented from a sheet / the main window), the first click is
// swallowed just to make the window key, so a SwiftUI gesture never starts and
// the user has to press twice. This transparent overlay view overrides
// acceptsFirstMouse -> true and drives the reorder callbacks directly from the
// AppKit mouse events, so the very first press works and the enclosing
// ScrollView cannot steal the drag. It is scoped to the handle only and never
// touches the host window or focus.
private struct FirstMouseDragHandle: NSViewRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> DragHandleNSView {
        let view = DragHandleNSView()
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ nsView: DragHandleNSView, context: Context) {
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
    }
}

final class DragHandleNSView: NSView {
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: (() -> Void)?
    private var startY: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        startY = event.locationInWindow.y
        onChanged?(0)
    }

    override func mouseDragged(with event: NSEvent) {
        // SwiftUI DragGesture translation.height is positive downward (top-left
        // origin). NSEvent window coordinates are bottom-left origin (positive
        // upward), so downward motion == startY - currentY.
        let dy = startY - event.locationInWindow.y
        onChanged?(dy)
    }

    override func mouseUp(with event: NSEvent) {
        onEnded?()
    }
}
