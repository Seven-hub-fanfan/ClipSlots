import SwiftUI

struct SlotCardView: View {
    let slot: Int
    let content: SlotContent
    var label: String = ""
    var saveShortcut: String = ""
    var pasteShortcut: String = ""
    var onPaste: () -> Void
    var onCopy: () -> Void
    var onSave: () -> Void
    var onClear: () -> Void
    var onSetLabel: (String) -> Void

    @State private var editingLabel = false
    @State private var labelText = ""
    @State private var isHovering = false
    @State private var showingPreview = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow

            SlotThumbnailView(content: content)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous))
                .onTapGesture {
                    if content.canPreview {
                        showingPreview = true
                    }
                }
                .help(content.canPreview ? "点击查看大图" : "")

            if !content.metadataSummary.isEmpty {
                Text(content.metadataSummary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 2)
            }

            actionRow
        }
        .padding(AppTheme.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .fill(AppTheme.cardBackground(colorScheme, isEmpty: content.isEmpty))
                .shadow(
                    color: AppTheme.cardShadow(colorScheme, isEmpty: content.isEmpty),
                    radius: isHovering ? 10 : (content.isEmpty ? 3 : 6),
                    y: isHovering ? 5 : 2
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(
                    isHovering
                        ? AppTheme.activeBorder(colorScheme)
                        : (content.isEmpty ? AppTheme.subtleBorder(colorScheme) : AppTheme.activeBorder(colorScheme)),
                    lineWidth: isHovering ? 1.4 : 1
                )
        )
        .scaleEffect(isHovering ? 1.012 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .sheet(isPresented: $showingPreview) {
            SlotPreviewView(content: content)
                .frame(width: 640, height: 500)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(AppTheme.slotBadgeBackground(colorScheme, isEmpty: content.isEmpty))
                    .frame(width: 30, height: 30)

                Text("\(slot)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(content.isEmpty ? .secondary : .white)
            }

            VStack(alignment: .leading, spacing: 2) {
                if editingLabel {
                    TextField("标签", text: $labelText, onCommit: commitLabel)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                        .onExitCommand {
                            editingLabel = false
                        }
                } else {
                    HStack(spacing: 5) {
                        Text(displayTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)

                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary.opacity(isHovering ? 0.85 : 0.0))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        labelText = label
                        editingLabel = true
                    }
                    .help("点击编辑标签")
                }

                Text(content.isEmpty ? "空槽位" : contentTypeTitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !content.isEmpty {
                Text(timeAgo)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(AppTheme.chipBackground(colorScheme)))
            }
        }
    }

    private var contentPreview: some View {
        Group {
            if content.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Image(systemName: "tray")
                            .font(.callout)
                            .foregroundColor(.secondary.opacity(0.55))
                        Text("暂无内容")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    if !saveShortcut.isEmpty {
                        Text("使用 \(saveShortcut) 保存到此槽位")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.72))
                            .lineLimit(1)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: contentTypeIcon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 20)

                    Text(content.preview)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(3)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 7) {
            if !content.isEmpty {
                Button { onPaste() } label: {
                    Label("粘贴", systemImage: "arrow.up.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(pasteShortcut.isEmpty ? "粘贴该槽位内容" : pasteShortcut)

                Button { onCopy() } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button { onClear() } label: {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundColor(AppTheme.danger.opacity(isHovering ? 0.95 : 0.65))
                .help("清空")
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
            .help(saveShortcut.isEmpty ? "保存当前剪贴板内容" : saveShortcut)
        }
    }

    private func commitLabel() {
        editingLabel = false
        onSetLabel(labelText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var displayTitle: String {
        if label.isEmpty { return "槽位 \(slot)" }
        return label
    }

    private var contentTypeIcon: String {
        if content.isEmpty { return "tray" }
        let text = content.preview
        if text.hasPrefix("[富文本]") { return "doc.richtext" }
        if text.hasPrefix("[图片") { return "photo" }
        if text.hasPrefix("[文件") { return "doc" }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return "link" }
        return "doc.text"
    }

    private var contentTypeTitle: String {
        let text = content.preview
        if text.hasPrefix("[富文本]") { return "富文本" }
        if text.hasPrefix("[图片") { return "图片" }
        if text.hasPrefix("[文件") { return "文件" }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return "链接" }
        return "文本"
    }

    private var timeAgo: String {
        let interval = -content.timestamp.timeIntervalSinceNow
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        return "\(Int(interval / 86400)) 天前" }
    }
