import SwiftUI

/// v2.7.13: clean image-only preview. No material background, no rounded container,
/// no AppKit shadow. The HStack toolbar is the only top bar.
/// v2.7.15: supports all storable types (text, image, file, folder, video).
struct RadialPreviewPanel: View {
    let title: String
    let subtitle: String
    let content: AnyView
    @Binding var isPinned: Bool
    @State private var scale: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            // v2.7.13: use this app toolbar as the only top bar.
            HStack(spacing: 10) {
                Image(systemName: "eye")
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("实时预览").font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Button { scale = max(0.75, scale - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { scale = min(1.8, scale + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                Button { isPinned.toggle() } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .foregroundColor(isPinned ? .accentColor : .secondary)
                        .padding(6)
                        .background(Circle().fill(isPinned ? Color.accentColor.opacity(0.16) : Color.clear))
                }
                .help(isPinned ? "已置顶：拖到哪里就固定到哪里" : "置顶预览窗")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .frame(height: 54)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.96))

            Divider()

            ZStack {
                // v2.7.17: smart background. Only show opaque background when there
                // is actual content to preview. Empty state / image preview remain
                // transparent / unobtrusive.
                content
                    .scaleEffect(scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .frame(minWidth: 260, minHeight: 220)
        // v2.7.17: window remains transparent. Background is only drawn inside the
        // individual text/file preview cards, not the entire window.
        .background(Color.clear)
    }
}

// MARK: - v2.7.15 Live Preview Content (all storable types)

struct RadialLivePreviewContent: View {
    @ObservedObject var store: SlotStoreObservable
    @State private var hoveredSlot: Int?

    var body: some View {
        Group {
            if let slot = hoveredSlot,
               let content = store.slots[slot],
               !content.isEmpty {
                RadialUniversalPreview(content: content)
                    .id(slot)
            } else {
                // v2.7.17: empty state remains fully transparent. No background, no watermark,
                // no placeholder text. Only the toolbar is visible.
                Color.clear
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .radialMenuHoveredSlotChanged)) { note in
            hoveredSlot = note.object as? Int
        }
    }
}

// MARK: - v2.7.15 Universal Preview

private struct RadialUniversalPreview: View {
    let content: SlotContent

    var body: some View {
        Group {
            if let image = content.inlineImage {
                RadialImagePreview(image: image)
            } else if content.isImageFile, let url = content.primaryFileURL {
                RadialImageFilePreview(url: url)
            } else if content.isVideoFile, let url = content.primaryFileURL {
                RadialFileCardPreview(url: url, icon: "play.rectangle.fill", title: "视频文件")
            } else if let url = content.primaryFileURL {
                RadialFileCardPreview(url: url, icon: content.isDirectoryLike ? "folder.fill" : "doc.fill", title: content.isDirectoryLike ? "文件夹" : "文件")
            } else {
                RadialTextPreview(text: content.preview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RadialImagePreview: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RadialImageFilePreview: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                RadialImagePreview(image: image)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear {
            if image == nil { image = NSImage(contentsOf: url) }
        }
    }
}

private struct RadialTextPreview: View {
    let text: String

    var body: some View {
        // v2.7.17: text preview gets its own adaptive background card.
        // The card size fits the text content, not the full window.
        ScrollView {
            Text(text.isEmpty ? "空文本" : text)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundColor(Color(NSColor.labelColor))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        .padding(14)
        .animation(.easeOut(duration: 0.12), value: text)
    }
}

private struct RadialFileCardPreview: View {
    let url: URL
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            Text(url.deletingLastPathComponent().path)
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.75))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // v2.7.17: file preview also gets its own adaptive card.
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        .padding(14)
        .animation(.easeOut(duration: 0.12), value: url)
    }
}

// MARK: - Deprecated image-only preview kept for compatibility

private struct RadialImageOnlyPreview: View {
    let content: SlotContent
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let img = image ?? content.inlineImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadImageIfNeeded() }
    }

    private func loadImageIfNeeded() {
        guard image == nil else { return }
        if let inline = content.inlineImage { image = inline; return }
        guard content.isImageFile, let url = content.primaryFileURL else { return }
        if let img = NSImage(contentsOf: url) { image = img }
    }
}

// MARK: - SlotContent Helper

private extension SlotContent {
    var isImageLikeForRadialPreview: Bool {
        inlineImage != nil || isImageFile
    }

    var isDirectoryLike: Bool {
        guard let url = primaryFileURL else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
