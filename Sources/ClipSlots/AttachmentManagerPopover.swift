import SwiftUI
import AppKit
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
                        ForEach(attachments) { att in
                            AttachmentRow(attachment: att, scheme: scheme) {
                                remove(att)
                            }
                        }
                        .onMove(perform: move)

                        if let kind = inlineEditor {
                            inlineEditorView(kind)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func move(from offsets: IndexSet, to destination: Int) {
        var current = store.attachments(for: slot)
        current.move(fromOffsets: offsets, toOffset: destination)
        store.setAttachments(current, for: slot)
    }
}

// MARK: - Attachment Row

struct AttachmentRow: View {
    let attachment: SlotContent.SlotAttachment
    let scheme: ColorScheme
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var deleteHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(attachment.type.accentColor.opacity(0.15))
                Image(systemName: attachment.type.iconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(attachment.type.accentColor)
            }
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius).fill(AppTheme.cardBackground(scheme)))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius)
                .stroke(isHovered ? attachment.type.accentColor.opacity(0.5) : AppTheme.subtleBorder(scheme), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
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
