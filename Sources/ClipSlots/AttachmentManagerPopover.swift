import SwiftUI
import ClipSlotsKit
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
    // v2.9.17: drag-and-drop / click upload target highlight. True while a file
    // drag hovers the dropzone (empty state) or the compact bottom dropzone.
    @State private var isDropTargeted = false
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
            // v2.9.17: keep the drag/click hot zone available once attachments
            // exist (empty state already IS a full dropzone).
            if !attachments.isEmpty {
                compactDropzone
            }
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
                Text("粘贴槽位 \(slot) 时会依次带出这些附件")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("\(attachments.count) 项")
                // v2.9.18: 计数徽章由 11pt 提升到 12pt（保留 medium 字重），改善可读。
                .font(.system(size: 12, weight: .medium))
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

    // v2.9.17: empty state is now an interactive dropzone. Click anywhere to open
    // a multi-select file picker; drag files onto it to add them directly. The
    // dashed border + upload glyph make the hot zone obvious.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isDropTargeted ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                .font(.system(size: 34, weight: .regular))
                .foregroundColor(isDropTargeted ? .accentColor : .secondary.opacity(0.55))
            VStack(spacing: 4) {
                Text(isDropTargeted ? "松开以添加附件" : "拖拽文件到这里")
                    .font(.callout.weight(.medium))
                    .foregroundColor(isDropTargeted ? .accentColor : .secondary)
                Text("或点击此区域选择文件（可多选）")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : AppTheme.subtleBorder(scheme),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.5, dash: [7, 5])
                )
        )
        .padding(16)
        .onTapGesture { pickFilesForDropzone() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }

    // v2.9.17: compact dropzone shown above the add bar when attachments exist,
    // so the drag hot zone stays available without dominating the list. Clicking
    // it also opens the multi-select picker.
    private var compactDropzone: some View {
        HStack(spacing: 8) {
            Image(systemName: isDropTargeted ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isDropTargeted ? .accentColor : .secondary)
            Text(isDropTargeted ? "松开以添加附件" : "拖拽文件到此，或点击选择（可多选）")
                .font(.caption)
                .foregroundColor(isDropTargeted ? .accentColor : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : AppTheme.subtleBorder(scheme),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .onTapGesture { pickFilesForDropzone() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
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

    // v2.9.17: multi-select picker used by the dropzone (empty state + compact).
    // Unlike the type-specific 图片/文件 buttons, it accepts anything and
    // classifies each file as image-or-file automatically via `addFileURLs`.
    private func pickFilesForDropzone() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择要作为附件添加的文件（可多选）"
        guard panel.runModal() == .OK else { return }
        addFileURLs(panel.urls)
    }

    // v2.9.17: shared file-adding core for drag-drop and the dropzone picker.
    // Reuses the exact SlotAttachment shape as `pickFile`, classifying each URL
    // as an image or a generic file so image thumbnails/previews still work.
    private func addFileURLs(_ urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            var current = store.attachments(for: slot)
            for url in fileURLs {
                let att = SlotContent.SlotAttachment(
                    name: url.lastPathComponent,
                    type: attachmentType(for: url),
                    path: url.path
                )
                current.append(att)
            }
            store.setAttachments(current, for: slot)
        }
    }

    private func attachmentType(for url: URL) -> SlotContent.AttachmentType {
        if #available(macOS 11.0, *),
           let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .image) {
            return .image
        }
        return .file
    }

    // v2.9.17: resolve dropped file-URL providers to on-disk URLs, then add them.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        let relevant = providers.filter { $0.hasItemConformingToTypeIdentifier(fileURLType) }
        guard !relevant.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [URL] = []

        for provider in relevant {
            group.enter()
            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let url, url.isFileURL {
                    lock.lock(); collected.append(url); lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            addFileURLs(collected)
        }
        return true
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
    // v2.7.86: hover preview now lives in a non-activating, mouse-transparent
    // floating panel (see AttachmentPreviewWindowController) instead of a nested
    // SwiftUI `.popover`. A nested transient popover installed a local mouseDown
    // monitor that dismissed itself on the next press and SWALLOWED that press,
    // so the first click on the × delete control / drag handle while the preview
    // was up did nothing (the residual "click/drag twice" bug). A panel that
    // ignores mouse events is not a popover and never participates in event
    // routing, so the first press always reaches the AppKit first-mouse overlays.
    @State private var hoverToken = 0
    // Backing NSView anchor so the preview panel can be positioned next to the row.
    @State private var anchor = AttachmentRowAnchor()

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

            // v2.8.9: the delete affordance is a plain visual whose click is
            // driven by a first-mouse AppKit overlay. Inside an NSPopover that
            // is not yet the key window, a SwiftUI Button swallows its first
            // mouseDown just to make the window key, so users had to click the
            // red × several times. The overlay overrides acceptsFirstMouse so
            // the very first press deletes reliably.
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(deleteHovered ? Color(red: 1.0, green: 0.27, blue: 0.23) : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .onHover { deleteHovered = $0 }
                .help("删除附件")
                .overlay(FirstMouseClickHandle(action: onDelete))

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
                            hoverToken += 1
                            AttachmentPreviewWindowController.shared.hide()
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
        .background(WindowAnchorView(holder: anchor))
        .onHover { hovering in
            isHovered = hovering
            if hovering && !dragActive {
                hoverToken += 1
                let token = hoverToken
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard isHovered, token == hoverToken, !dragActive,
                          let rect = anchor.screenRect() else { return }
                    AttachmentPreviewWindowController.shared.show(
                        attachment: attachment, scheme: scheme, anchor: rect
                    )
                }
            } else {
                hoverToken += 1
                AttachmentPreviewWindowController.shared.hide(for: attachment.id)
            }
        }
        // Hide the floating preview if the row/popover goes away while shown.
        .onDisappear {
            hoverToken += 1
            AttachmentPreviewWindowController.shared.hide(for: attachment.id)
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
            // v2.8.9: many attachments arrive as `.file` even though they are
            // actually images (e.g. dragged / spilled PNGs). Decode the real
            // pixels so they render a true thumbnail instead of the generic
            // Finder "PNG" document icon.
            if isImage(url), let img = NSImage(contentsOfFile: path) {
                return resized(img, maxPixel: maxPixel)
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
            // v2.8.9: image files stored as `.file` still get a rich preview.
            if isImage(url), let img = NSImage(contentsOfFile: path) { return img }
            return nil
        default:
            return nil
        }
    }

    static func isImage(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .image)
        }
        return false
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
        } else if let path = attachment.path, !path.isEmpty,
                  AttachmentThumbnailProvider.isImage(URL(fileURLWithPath: path)) {
            AsyncPreviewImage(attachment: attachment) {
                fileCard(icon: "photo", title: "图片")
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


// v2.8.9: transparent first-mouse click overlay. Overrides acceptsFirstMouse
// so a single tap fires even while the enclosing NSPopover window is not yet
// key (otherwise SwiftUI's Button eats the first click just to make the window
// key). Fires `action` on mouseUp when released inside bounds, and shows the
// pointing-hand cursor. Scoped to the control it overlays only.
private struct FirstMouseClickHandle: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ClickHandleNSView {
        let view = ClickHandleNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: ClickHandleNSView, context: Context) {
        nsView.action = action
    }
}

final class ClickHandleNSView: NSView {
    var action: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            action?()
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // v2.8.9: drive the whole drag from a single modal event-tracking loop
    // started in mouseDown. Previously we relied on AppKit delivering the
    // follow-up mouseDragged / mouseUp to this same view, but each reorder
    // rebuilds the SwiftUI ForEach and recreates this NSView, which severed the
    // event stream mid-drag and made the handle feel unstable / "sticky". By
    // pumping events with nextEvent(matching:) inside mouseDown, the drag stays
    // owned by this call frame until the mouse is released, independent of any
    // SwiftUI view rebuild triggered by the live reordering.
    override func mouseDown(with event: NSEvent) {
        guard let window = self.window else { return }
        let startY = event.locationInWindow.y
        onChanged?(0)

        // Switch to the closed-hand "grabbing" cursor for the drag duration.
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }

        var dragging = true
        while dragging {
            guard let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                continue
            }
            switch e.type {
            case .leftMouseDragged:
                // SwiftUI DragGesture translation.height is positive downward
                // (top-left origin). NSEvent window coordinates are bottom-left
                // origin (positive upward), so downward motion == startY - y.
                let dy = startY - e.locationInWindow.y
                onChanged?(dy)
            case .leftMouseUp:
                dragging = false
            default:
                break
            }
        }
        onEnded?()
    }
}

// MARK: - Hover Preview Floating Panel (v2.7.86)
//
// Why this exists — the residual "click/drag twice" root cause:
// The hover preview used to be a nested SwiftUI `.popover`, i.e. an NSPopover
// with `.transient` behaviour. A transient popover installs a local mouseDown
// monitor; the next press ANYWHERE outside its content closes it and CONSUMES
// that press. Because the × delete control and the drag handle sit on the very
// row that anchored the preview, the pointer was over them while the preview
// was up, so the first press was eaten by the dismissal and the user had to act
// twice. The AppKit acceptsFirstMouse overlays (v2.7.84/85) could not help —
// the event never reached them, it was swallowed at the window/monitor level.
// Rendering the preview in a non-activating, mouse-transparent floating panel
// removes it from event routing entirely, so the first press always lands.

/// Weak holder for a row's backing NSView so the preview panel can be anchored
/// to the row's on-screen rect.
final class AttachmentRowAnchor {
    weak var view: NSView?

    /// Row rect in screen coordinates (bottom-left origin), or nil if detached.
    func screenRect() -> NSRect? {
        guard let view, let window = view.window else { return nil }
        let inWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }
}

/// Transparent, zero-cost background view that records the row's backing NSView.
private struct WindowAnchorView: NSViewRepresentable {
    let holder: AttachmentRowAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}

/// Panel that can never become key/main so it never steals focus from the
/// attachment-manager popover or the main window.
private final class AttachmentPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the attachment hover preview in a floating, mouse-transparent panel.
/// Because the panel ignores mouse events and is not a popover, it never
/// consumes clicks aimed at the row's delete / drag controls, so a single
/// click / drag always works even while the preview is visible.
final class AttachmentPreviewWindowController {
    static let shared = AttachmentPreviewWindowController()

    private var panel: AttachmentPreviewPanel?
    private var currentID: UUID?
    private let previewSize = NSSize(width: 340, height: 300)

    private init() {}

    func show(attachment: SlotContent.SlotAttachment, scheme: ColorScheme, anchor: NSRect) {
        let hosting = NSHostingView(
            rootView: AttachmentPreviewContent(attachment: attachment, scheme: scheme)
                .frame(width: previewSize.width, height: previewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .environment(\.colorScheme, scheme)
        )

        let panel = self.panel ?? makePanel()
        panel.contentView = hosting
        panel.setContentSize(previewSize)
        position(panel, anchor: anchor)
        panel.orderFrontRegardless()

        self.panel = panel
        self.currentID = attachment.id
    }

    /// Hide only if the given row still owns the visible preview. Prevents a
    /// delayed hover-out from row A from closing a freshly-shown preview for row B.
    func hide(for id: UUID) {
        guard currentID == id else { return }
        hide()
    }

    func hide() {
        currentID = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> AttachmentPreviewPanel {
        let panel = AttachmentPreviewPanel(
            contentRect: NSRect(origin: .zero, size: previewSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu           // above the attachment-manager popover
        panel.ignoresMouseEvents = true    // never intercept clicks -> no swallow
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }

    /// Prefer the trailing side of the row; fall back to the leading side, then
    /// clamp inside the screen's visible frame.
    private func position(_ panel: NSPanel, anchor: NSRect) {
        let size = previewSize
        let gap: CGFloat = 10
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor

        var x = anchor.maxX + gap
        if x + size.width > visible.maxX {
            x = anchor.minX - gap - size.width
        }
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)

        var y = anchor.midY - size.height / 2
        y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
