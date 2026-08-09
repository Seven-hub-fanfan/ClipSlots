import SwiftUI
import ClipSlotsKit
import WebKit

enum ThumbnailState {
    case idle
    case loading
    case loaded(NSImage)
    case failed
}

@MainActor
private final class ThumbnailLoadState: ObservableObject {
    @Published var state: ThumbnailState = .idle

    private var key = ""
    private var token = UUID()

    func begin(key: String) -> UUID {
        self.key = key
        token = UUID()
        state = .idle
        return token
    }

    func update(_ state: ThumbnailState, key: String, token: UUID) {
        guard self.key == key, self.token == token else { return }
        self.state = state
    }

    func isCurrent(key: String, token: UUID) -> Bool {
        self.key == key && self.token == token
    }
}

struct SlotThumbnailView: View {
    let content: SlotContent
    let specialSlotId: String
    let slot: Int

    @StateObject private var loadState = ThumbnailLoadState()

    /// The composite key that uniquely identifies this slot version.
    /// When any dimension changes (special slot, slot number, content, or overwrite),
    /// this key changes and the view is force-rebuilt.
    private var currentKey: String {
        content.thumbnailKey(specialSlotId: specialSlotId, slot: slot)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.04))

            switch loadState.state {
            case .idle:
                idleView
            case .loading:
                loadingView
            case .loaded(let image):
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)

                    if content.isVideoFile {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.white.opacity(0.9))
                            .shadow(radius: 4)
                    }
                }
            case .failed:
                fallbackView
            }
        }
        // v2.9.25 hotfix: 框高需容纳约 4 行等宽文本（行高≈17pt，4 行≈68pt + padding 8×2≈16pt
        // + 余量 ≈ 116pt）。minHeight 116 / idealHeight 140 保证内容区净高足够放下 4 行；
        // 长内容仍靠 maxHeight:.infinity 自适应撑开。
        .frame(minHeight: 116, idealHeight: 140, maxHeight: .infinity)
        .clipped()
        .id(currentKey)
        .onAppear { reloadThumbnail() }
        .onChange(of: currentKey) { _ in
            reloadThumbnail()
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        ProgressView()
            .scaleEffect(0.7)
    }

    private var idleView: some View {
        fallbackView
    }

    private var fallbackView: some View {
        Group {
            if content.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("空槽位")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else if content.isFileContent {
                VStack(spacing: 8) {
                    Image(systemName: fileIconName)
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text(content.fileDisplayName ?? "文件")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(content.metadataSummary)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            } else {
                Text(multilinePreview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.8))
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    // v2.9.25 hotfix3: 卡片文本预览专用的多行文本源。content.preview 会被上游截断为 30 字符，
    // 只能显示约 2 行；这里用 plainText 全文（截到 240 字符足够铺满 4 行），非纯文本槽回退到 preview。
    private var multilinePreview: String {
        if let text = content.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text.count > 240 ? String(text.prefix(240)) + "…" : text
        }
        return content.preview
    }

    private var fileIconName: String {
        guard let url = content.primaryFileURL else { return "doc" }
        let ext = url.pathExtension.lowercased()
        if ["pdf"].contains(ext) { return "doc.richtext" }
        if ["zip", "tar", "gz", "7z", "rar"].contains(ext) { return "archivebox" }
        if ["mp4", "mov", "avi", "mkv"].contains(ext) { return "film" }
        if ["mp3", "wav", "aac", "flac"].contains(ext) { return "music.note" }
        if content.isImageFile { return "photo" }
        return "doc"
    }

    // MARK: - Loading

    private func reloadThumbnail() {
        let key = currentKey
        let token = loadState.begin(key: key)

        guard !content.isEmpty else {
            loadState.update(.failed, key: key, token: token)
            return
        }

        // C-1 (v2.10.31): decode inline images off the main thread.
        // Previously this synchronously read `content.inlineImage`, which runs
        // `NSImage(data:)` on the full-resolution data on the main thread. For an
        // uncached large image (e.g. an 8K screenshot) that blocked the UI ~200-500ms
        // and dropped frames when the card appeared / scrolled. v2.10.30 already added
        // the async background decoder (InlineImageView / decodedInlineImage) but the
        // main grid thumbnail never adopted it. We now mirror InlineImageView's pattern:
        // decode on a detached background Task, then hop back to the main actor and only
        // assign if this cell still represents the same content version (guard against
        // stale callbacks from cell reuse via key + loadToken).
        if content.hasImage {
            loadState.update(.loading, key: key, token: token)
            let snapshot = content
            Task {
                // P0-4 (v2.10.38): gate the decode through the global ThumbnailDecodeLimiter so
                // that a burst of image cells appearing at once (big group scroll / post-import
                // refresh) can't fire hundreds of concurrent ImageIO decodes and swamp CPU/memory.
                let decoded = await ThumbnailDecodeLimiter.shared.run {
                    await Task.detached(priority: .userInitiated) { () -> NSImage? in
                        // ATT-1/ATT-2 (v2.10.32): the grid cell is small, so decode a
                        // DOWNSAMPLED thumbnail (longest edge ≤ 512px) via ImageIO rather
                        // than the full-resolution NSImage. This keeps an 8K screenshot from
                        // decompressing ~135MB just to draw a ~140pt cell, and stores it in a
                        // dedicated thumbnail cache (full-res stays in the enlarge-preview
                        // path). Falls back to the full-res decode if downsampling fails.
                        snapshot.decodedInlineThumbnail(maxPixel: 512) ?? snapshot.decodedInlineImage()
                    }.value
                }
                await MainActor.run {
                    // Discard if the cell was reused / content version changed while
                    // decoding, or a newer reload superseded this one.
                    guard loadState.isCurrent(key: key, token: token) else { return }
                    loadState.update(decoded.map(ThumbnailState.loaded) ?? .failed, key: key, token: token)
                }
            }
            return
        }

        // v2.7.30: HTML must render as WebView, not fall into QuickLook/file thumbnail.
        // The previous condition treated .html as file content first, so the HTML branch
        // was never reached after thumbnail loading failed.
        if content.isHTMLDocument {
            loadState.update(.failed, key: key, token: token)
            return
        }

        // Need a file URL for QuickLook
        guard let url = content.primaryFileURL, content.isImageFile || content.isFileContent else {
            loadState.update(.failed, key: key, token: token)
            return
        }

        loadState.update(.loading, key: key, token: token)

        ThumbnailProvider.shared.thumbnail(for: url, cacheKey: key) { image, returnedKey in
            Task { @MainActor in
                guard returnedKey == key else {
                    NSLog("[ClipSlots] SlotThumbnailView discard stale callback slot=\(slot) specialSlot=\(specialSlotId) returnedKey=\(returnedKey) currentKey=\(key)")
                    return
                }
                loadState.update(image.map(ThumbnailState.loaded) ?? .failed, key: key, token: token)
            }
        }

        // 3-second timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard loadState.isCurrent(key: key, token: token) else { return }
            if case .loading = loadState.state {
                loadState.update(.failed, key: key, token: token)
            }
        }
    }
}

// MARK: - v2.7.29 HTML Card Preview

private struct HTMLCardPreview: View {
    let html: String
    var body: some View {
        HTMLWebPreview(html: html)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                Text("HTML")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(6)
            }
    }
}

private struct HTMLWebPreview: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.isHidden = false
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        let source = html.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalHTML: String
        if source.lowercased().contains("<html") || source.lowercased().contains("<!doctype") {
            finalHTML = source
        } else {
            finalHTML = """
            <!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>html,body{margin:0;padding:8px;background:transparent;font:13px -apple-system,BlinkMacSystemFont,sans-serif;overflow:hidden;} img,video{max-width:100%;height:auto;} *{box-sizing:border-box;}</style></head><body>\(source)</body></html>
            """
        }
        nsView.loadHTMLString(finalHTML, baseURL: context.coordinator.baseURL)
    }
    func makeCoordinator() -> Coordinator { Coordinator(baseURL: nil) }
    final class Coordinator: NSObject, WKNavigationDelegate {
        let baseURL: URL?
        init(baseURL: URL?) { self.baseURL = baseURL }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(.allow) }
    }
}

// MARK: - v2.7.33 HTML Source Priority

private extension SlotContent {
    var preferredHTMLSourceForPreview: String? {
        if let htmlSource, !htmlSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return htmlSource }
        if let url = primaryFileURL, ["html", "htm"].contains(url.pathExtension.lowercased()),
           let html = try? String(contentsOf: url, encoding: .utf8) { return html }
        let raw = plainText ?? preview
        let lower = raw.lowercased()
        if lower.contains("<html") || lower.contains("<!doctype html") || lower.contains("<body") { return raw }
        return nil
    }
}

private var htmlUnavailableView: some View {
    VStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.orange)
        Text("HTML 原文缺失")
            .font(.caption)
            .fontWeight(.semibold)
        Text("请重新拖入 .html 文件或重新保存网页内容")
            .font(.caption2)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
    }
    .padding(10)
}
