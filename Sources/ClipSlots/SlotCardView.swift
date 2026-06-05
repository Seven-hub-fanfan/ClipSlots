import SwiftUI
import AVKit

struct SlotCardView: View {
    let slot: Int
    let content: SlotContent
    let specialSlotId: String
    var label: String = ""
    var saveShortcut: String = ""
    var pasteShortcut: String = ""
    var onPaste: () -> Void
    var onCopy: () -> Void
    var onSave: () -> Void
    var onClear: () -> Void
    var onSetLabel: (String) -> Void
    var onEditText: ((String) -> Void)? = nil
    var onEditHTML: ((String) -> Void)? = nil
    var onDropFiles: (([URL]) -> Void)? = nil

    // v2.7.0: Connection props
    var connectionDotColor: Color? = nil
    var isConnectionMode: Bool = false
    var connectedPorts: Set<SlotPort> = []
    var highlightedPort: SlotPort? = nil
    var isPortVisible: Bool = false
    var onBeginDrag: ((SlotPort, CGPoint) -> Void)?
    var onUpdateDrag: ((CGPoint) -> Void)?
    var onEndDrag: (() -> Void)?

    @State private var editingLabel = false
    @State private var labelText = ""
    @State private var isHovering = false
    @State private var showingPreview = false
    @State private var showingTextEditor = false
    @State private var showingHTMLEditor = false
    @State private var editingText = ""
    @State private var isDropTargeted = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow

            // Thumbnail area — split empty vs filled to prevent @State image reuse
            if content.isEmpty {
                EmptySlotThumbnailView()
            } else if content.isVideoFile, let url = content.primaryFileURL {
                InlineSlotVideoPreview(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous))
                    .onTapGesture {
                        // v2.7.34: restore full-size preview for video cards.
                        showingPreview = true
                    }
                    .help("点击查看视频大图预览")
            } else {
                SlotThumbnailView(content: content, specialSlotId: specialSlotId, slot: slot)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous))
                    .onTapGesture {
                        if content.canPreview {
                            showingPreview = true
                        }
                    }
                    .help(content.canPreview ? "点击查看大图" : "")
            }

            // Metadata — fixed single-line
            Text(content.metadataSummary)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 16, alignment: .leading)
                .padding(.horizontal, 2)

            actionRow
        }
        .frame(height: 270)
        .id(content.thumbnailKey(specialSlotId: specialSlotId, slot: slot))
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
        // v2.7.1: Do not render node-canvas ports on the main card grid.
        // The v2.7.0 port overlay polluted the normal UI with permanent blue handles.
        // Keep only a tiny chain-color dot in the header.
        .scaleEffect(isHovering ? 1.012 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
        .overlay(alignment: .center) {
            if isDropTargeted {
                DropImportOverlay(slot: slot)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor.opacity(0.55) : Color.clear,
                    lineWidth: isDropTargeted ? 1.2 : 0
                )
        )
        .sheet(isPresented: $showingPreview) {
            SlotPreviewView(content: content)
                .frame(width: 640, height: 500)
        }
        .sheet(isPresented: $showingTextEditor) {
            VStack(alignment: .leading, spacing: 12) {
                Text("编辑槽位 \(slot) 文本")
                    .font(.headline)
                TextEditor(text: $editingText)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minWidth: 520, minHeight: 320)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                HStack {
                    Spacer()
                    Button("取消") { showingTextEditor = false }
                    Button("保存") {
                        onEditText?(editingText)
                        showingTextEditor = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(18)
        }
        .sheet(isPresented: $showingHTMLEditor) {
            VStack(alignment: .leading, spacing: 12) {
                Text("编辑槽位 \(slot) HTML")
                    .font(.headline)
                TextEditor(text: $editingText)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minWidth: 620, minHeight: 360)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                HStack {
                    Spacer()
                    Button("取消") { showingHTMLEditor = false }
                    Button("保存") {
                        onEditHTML?(editingText)
                        showingHTMLEditor = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(18)
        }
        .contextMenu {
            // v2.5: Type-specific actions
            typeSpecificMenuItems
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

            // v2.7.9: Connection indicator with capsule badge
            if let dotColor = connectionDotColor {
                HStack(spacing: 4) {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                    Image(systemName: "link")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(dotColor)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Capsule().fill(dotColor.opacity(0.14)))
                .overlay(Capsule().stroke(dotColor.opacity(0.35), lineWidth: 0.8))
                .help("此槽位属于串联链路")
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
        VStack(spacing: 8) {
            if !content.isEmpty {
                HStack(spacing: 8) {
                    Button { onPaste() } label: {
                        Label("粘贴", systemImage: "arrow.up.doc.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .help(pasteShortcut.isEmpty ? "粘贴到目标应用" : pasteShortcut)

                    Button { onCopy() } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("复制到剪贴板")
                }

                HStack(spacing: 8) {
                    if content.isHTMLContent {
                        Button {
                            editingText = content.htmlEditableValue
                            showingHTMLEditor = true
                        } label: {
                            Label("编辑HTML", systemImage: "chevron.left.forwardslash.chevron.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help("编辑 HTML 原文")
                    } else if content.isPlainEditableText {
                        Button {
                            editingText = content.editableTextValue
                            showingTextEditor = true
                        } label: {
                            Label("编辑", systemImage: "pencil")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help("直接编辑此文本槽位")
                    }

                    Button { onSave() } label: {
                        Label("覆盖", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(.orange)
                    .help(saveShortcut.isEmpty ? "用当前剪贴板覆盖此槽位" : saveShortcut)

                    Button(role: .destructive) { onClear() } label: {
                        Label("清空", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("清空槽位内容")
                }
            } else {
                Button { onSave() } label: {
                    Label("保存到槽位 \(slot)", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help(saveShortcut.isEmpty ? "保存当前剪贴板内容到槽位 \(slot)" : saveShortcut)

                Color.clear
            }
        }
        .frame(height: 66)
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
        if content.isVideoFile { return "film" }
        if text.hasPrefix("[文件") { return "doc" }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return "link" }
        return "doc.text"
    }

    private var contentTypeTitle: String {
        let text = content.preview
        if text.hasPrefix("[富文本]") { return "富文本" }
        if text.hasPrefix("[图片") { return "图片" }
        if content.isVideoFile { return "视频" }
        if text.hasPrefix("[文件") { return "文件" }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return "链接" }
        return "文本"
    }

    // MARK: - Context Menu (v2.5)

    @ViewBuilder
    private var typeSpecificMenuItems: some View {
        if let fileURL = content.primaryFileURL {
            Divider()

            let exists = SlotTypeActions.fileExists(fileURL)

            Button("打开文件") {
                SlotTypeActions.openFile(fileURL)
            }
            .disabled(!exists)

            Button("在 Finder 中显示") {
                SlotTypeActions.revealInFinder(fileURL)
            }
            .disabled(!exists)

            Button("复制文件路径") {
                SlotTypeActions.copyFilePath(fileURL)
            }

            Button("复制文件名") {
                SlotTypeActions.copyFileName(fileURL)
            }
        }

        if let webURL = content.detectedWebURL {
            Divider()

            Button("打开链接") {
                SlotTypeActions.openWebURL(webURL)
            }

            Button("复制链接") {
                SlotTypeActions.copyString(webURL.absoluteString)
            }

            Button("复制 Markdown 链接") {
                SlotTypeActions.copyMarkdownLink(webURL)
            }
        }
    }

    private var timeAgo: String {
        let interval = -content.timestamp.timeIntervalSinceNow
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        return "\(Int(interval / 86400)) 天前" }

    // MARK: - v2.7.0 Port Overlay

    @ViewBuilder
    private var portOverlay: some View {
        if isPortVisible || !connectedPorts.isEmpty {
            SlotPortLayer(
                slot: slot,
                size: CGSize(width: 250, height: 270),
                color: connectionDotColor ?? .accentColor,
                isVisible: isPortVisible,
                connectedPorts: connectedPorts,
                highlightedPort: highlightedPort,
                onBeginDrag: onBeginDrag ?? { _, _ in },
                onUpdateDrag: onUpdateDrag ?? { _ in },
                onEndDrag: onEndDrag ?? {}
            )
        }
    }

    // MARK: - v2.7.27 File Drop

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let onDropFiles else { return false }
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let string = String(data: data, encoding: .utf8),
                   let url = URL(string: string) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty { onDropFiles(urls) }
        }
        return true
    }
}

// MARK: - v2.7.27 SlotContent Text Edit Helpers

private extension SlotContent {
    var isHTMLContent: Bool {
        if let htmlSource, !htmlSource.isEmpty { return true }
        if let url = primaryFileURL, ["html", "htm"].contains(url.pathExtension.lowercased()) { return true }
        let raw = (plainText ?? preview).lowercased()
        return raw.contains("<html") || raw.contains("<!doctype html") || raw.contains("<body")
    }
    var htmlEditableValue: String { htmlSource ?? plainText ?? preview }
    var isPlainEditableText: Bool {
        primaryFileURL == nil && inlineImage == nil && !isHTMLContent && !preview.hasPrefix("[图片") && !preview.hasPrefix("[文件") && !preview.hasPrefix("[富文本]")
    }
    var editableTextValue: String { plainText ?? preview }
}

// MARK: - v2.7.23 Inline Video Preview

private struct InlineSlotVideoPreview: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
            if let player {
                SafeInlineAVPlayerView(player: player)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                    Text("视频预览")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.72))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .onAppear {
            guard player == nil else { player?.play(); return }
            let p = AVPlayer(url: url)
            p.isMuted = true
            player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}

private struct SafeInlineAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        // v2.7.34: show the complete video composition in the card thumbnail.
        // resizeAspectFill cropped faces/edges and made the thumbnail look incomplete.
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

// MARK: - v2.7.28 Refined Drop UX

private struct DropImportOverlay: View {
    let slot: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )

            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.16))
                        .frame(width: 46, height: 46)
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.accentColor)
                }

                VStack(spacing: 3) {
                    Text("松开导入到槽位 \(slot)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("支持图片、视频、PDF、文件夹与多文件连续填充")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 18)
        }
    }
}
