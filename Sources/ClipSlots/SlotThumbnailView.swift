import SwiftUI
import ClipSlotsKit
import WebKit

enum ThumbnailState {
    case idle
    case loading
    case loaded(NSImage)
    case failed
}

struct SlotThumbnailView: View {
    let content: SlotContent
    let specialSlotId: String
    let slot: Int

    @State private var state: ThumbnailState = .idle
    @State private var loadToken = UUID()

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

            switch state {
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
        // v2.9.22: 缩略图 minHeight 从 120 收紧到 96，降低短内容卡片整体高度；
        // 长内容仍靠 maxHeight:.infinity 自适应撑开（配合放宽的 lineLimit 显示更多文本）。
        .frame(minHeight: 96, idealHeight: 132, maxHeight: .infinity)
        .clipped()
        .id(currentKey)
        .onAppear { reloadThumbnail() }
        .onChange(of: currentKey) { _ in
            // Force-reset @State when the content identity changes (overwrite,
            // special-slot switch, etc.). This is the key fix for stale thumbnails.
            state = .idle
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
                // v2.8.6: HTML slots now show the plain-text preview here (identical
                // font/style to every other text slot), instead of an inconsistent
                // "HTML" chip + WKWebView render. The HTML tags are stripped upstream
                // in `SlotContent.preview`.
                Text(content.preview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(28)
                    .truncationMode(.tail)
                    .padding(8)
                    // v2.9.22: lineLimit 14 → 28，预览区尽量填满灰框、减少过早省略与空白（截图问题③/🟡）。
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: content.preview.count <= 60 ? .center : .topLeading
                    )
            }
        }
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
        let token = UUID()
        loadToken = token

        guard !content.isEmpty else {
            state = .failed
            return
        }

        // Try inline image data first
        if let image = content.inlineImage {
            state = .loaded(image)
            return
        }

        // v2.7.30: HTML must render as WebView, not fall into QuickLook/file thumbnail.
        // The previous condition treated .html as file content first, so the HTML branch
        // was never reached after thumbnail loading failed.
        if content.isHTMLDocument {
            state = .failed
            return
        }

        // Need a file URL for QuickLook
        guard let url = content.primaryFileURL, content.isImageFile || content.isFileContent else {
            state = .failed
            return
        }

        state = .loading

        ThumbnailProvider.shared.thumbnail(for: url, cacheKey: key) { image, returnedKey in
            // Discard stale callbacks: if the key changed while loading
            // (special-slot switch, overwrite, etc.), don't update state.
            guard returnedKey == currentKey else {
                NSLog("[ClipSlots] SlotThumbnailView discard stale callback slot=\(slot) specialSlot=\(specialSlotId) returnedKey=\(returnedKey) currentKey=\(currentKey)")
                return
            }
            guard loadToken == token else { return }
            if let image = image {
                state = .loaded(image)
            } else {
                state = .failed
            }
        }

        // 3-second timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard loadToken == token else { return }
            guard currentKey == key else { return }
            if case .loading = state {
                state = .failed
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
