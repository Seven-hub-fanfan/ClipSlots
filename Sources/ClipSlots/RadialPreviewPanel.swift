import SwiftUI
import AVKit
import WebKit

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
                RadialVideoPreview(url: url)
            } else if content.isHTMLLikeForPreview {
                RadialHTMLPreview(html: content.htmlPreviewSourceForPreview)
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

// MARK: - v2.7.19 Video Preview

private struct RadialVideoPreview: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                SafeAVPlayerView(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text("视频预览")
                        .font(.system(size: 13, weight: .semibold))
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                }
                .padding(18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92))
        .onAppear {
            if player == nil {
                let p = AVPlayer(url: url)
                player = p
                p.isMuted = true
                p.play()
            }
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - v2.7.22 Safe AVPlayerView Bridge
// Do NOT use SwiftUI.VideoPlayer here. On macOS 15.7.x the private
// _AVKit_SwiftUI framework can abort while instantiating generic metadata.
// Using AppKit AVPlayerView avoids the crashing SwiftUI wrapper.
private struct SafeAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
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

// MARK: - v2.7.29 HTML Live Preview

private struct RadialHTMLPreview: View {
    let html: String
    var body: some View {
        HTMLWebLivePreview(html: html)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
            .padding(14)
    }
}

private struct HTMLWebLivePreview: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        let wrapped = """
        <!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>html,body{margin:0;padding:12px;background:transparent;font:14px -apple-system,BlinkMacSystemFont,sans-serif;} img,video{max-width:100%;height:auto;} *{box-sizing:border-box;}</style></head><body>\(html)</body></html>
        """
        nsView.loadHTMLString(wrapped, baseURL: nil)
    }
}

// MARK: - SlotContent Helper

private extension SlotContent {
    var isHTMLLikeForPreview: Bool {
        let lower = preview.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if primaryFileURL?.pathExtension.lowercased() == "html" || primaryFileURL?.pathExtension.lowercased() == "htm" { return true }
        return lower.hasPrefix("<html") || lower.hasPrefix("<") || lower.contains("<body") || lower.contains("<!doctype html") || lower.contains("</")
    }

    var htmlPreviewSourceForPreview: String {
        if let url = primaryFileURL,
           ["html", "htm"].contains(url.pathExtension.lowercased()),
           let text = try? String(contentsOf: url) {
            return text
        }
        return preview
    }

    var isImageLikeForRadialPreview: Bool {
        inlineImage != nil || isImageFile
    }

    var isDirectoryLike: Bool {
        guard let url = primaryFileURL else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
