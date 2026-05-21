import SwiftUI

struct SlotCardView: View {
    let slot: Int
    let content: SlotContent
    var label: String = ""
    var onPaste: () -> Void
    var onCopy: () -> Void
    var onSave: () -> Void
    var onClear: () -> Void
    var onSetLabel: (String) -> Void

    @State private var editingLabel = false
    @State private var labelText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack {
                ZStack {
                    Circle()
                        .fill(content.isEmpty ? Color.secondary.opacity(0.2) : Color.accentColor)
                        .frame(width: 28, height: 28)
                    Text("\(slot)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(content.isEmpty ? .secondary : .white)
                }

                if editingLabel {
                    TextField("标签", text: $labelText, onCommit: {
                        editingLabel = false
                        onSetLabel(labelText.trimmingCharacters(in: .whitespaces))
                    })
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                } else {
                    Text(displayTitle)
                        .font(.headline)
                        .onTapGesture(count: 1) {
                            labelText = label
                            editingLabel = true
                        }
                }

                Spacer()

                if !content.isEmpty {
                    Text(timeAgo)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Content preview
            contentPreview
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 44)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )

            // Action buttons
            HStack(spacing: 6) {
                if !content.isEmpty {
                    Button { onPaste() } label: {
                        Label("粘贴", systemImage: "arrow.up.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button { onCopy() } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button { onClear() } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundColor(.secondary)
                }

                Button { onSave() } label: {
                    if content.isEmpty {
                        Label("保存当前", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("覆盖", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(content.isEmpty ? .accentColor : .orange)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(content.isEmpty
                    ? Color(NSColor.controlBackgroundColor).opacity(0.5)
                    : Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(content.isEmpty ? 0.02 : 0.06), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(content.isEmpty ? Color.secondary.opacity(0.1) : Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }

    private var displayTitle: String {
        if label.isEmpty { return "槽位 \(slot)" }
        return label
    }

    private var contentPreview: some View {
        Group {
            if content.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.callout)
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("空槽位 — 按 \("Ctrl+Option+\(slot)") 保存")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.6))
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: contentTypeIcon)
                        .font(.callout)
                        .foregroundColor(.accentColor)
                        .frame(width: 20)

                    Text(content.preview)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var contentTypeIcon: String {
        if content.isEmpty { return "tray" }
        let text = content.preview
        if text.hasPrefix("[富文本]") { return "doc.richtext" }
        if text.hasPrefix("[图片") { return "photo" }
        if text.hasPrefix("[文件") { return "doc" }
        return "doc.text"
    }

    private var timeAgo: String {
        let interval = -content.timestamp.timeIntervalSinceNow
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        return "\(Int(interval / 86400)) 天前"
    }
}
