import SwiftUI
import ClipSlotsKit
import WebKit

// v2.10.73 (方案③): `ThumbnailState` 已上移至 ThumbnailProvider.swift 作为其状态查询返回类型；
// 原内部 `ThumbnailLoadState`（per-view @StateObject 解码态）已删除——它在卡壳复用时不销毁，
// 且切组两段跳只发一次 onAppear、第二跳漏 reload，是「缩略图卡旧图」回归的根因。

struct SlotThumbnailView: View {
    let content: SlotContent
    let specialSlotId: String
    let slot: Int

    // v2.10.73 (方案③): 观察共享的、以 key 为维度的缩略图缓存（单一数据源）。
    // 本视图的渲染是 `currentKey` 的纯函数：读到什么就画什么，不再持有各自的解码态。
    @ObservedObject private var provider = ThumbnailProvider.shared

    /// The composite key that uniquely identifies this slot version.
    /// When any dimension changes (special slot, slot number, content, or overwrite),
    /// this key changes; the view then reads the new key from the shared provider.
    private var currentKey: String {
        content.thumbnailKey(specialSlotId: specialSlotId, slot: slot)
    }

    // v2.10.87（动画打磨）: 当前 key 是否已拿到图。
    //
    // 它是下方「淡入」的动画驱动键，**刻意不用 currentKey 本身**——这一点是守住
    // 「切组/切页立即刷新、不串图」不变量的关键，详见 body 内注释。
    private var isThumbnailLoaded: Bool {
        if case .loaded = provider.state(for: currentKey) { return true }
        return false
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.04))

            // v2.10.73 (方案③): 渲染完全由 provider 对 currentKey 的状态决定。
            // 命中缓存 → 秒出图；未命中 → loading，异步填充后 objectWillChange 触发重渲染。
            Group {
                switch provider.state(for: currentKey) {
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
            // v2.10.87（动画打磨）: 消除「占位/转圈 → 图片」的硬切。异步解码完成的瞬间，
            // 缩略图原先是「啪」地一下替换上来，跳变感明显；改成淡入后，卡片读起来是
            // 「图片显影」而不是「界面闪了一下」。
            //
            // v2.10.88: 时长从 Anim.status(0.2s easeInOut) 换成专用档 Anim.thumbnailFade(0.09s easeOut)。
            // 0.2s 用在这里被实测反馈为「慢」——缩略图是切组后第一眼要读的信息，淡入一旦超过约 0.1s
            // 就会被读成图片加载得慢。方向性逻辑（下面几条）完全不变，只换曲线与时长。
            //
            // ⚠️ 这里的动画是**有方向的**，写法必须保持 `isLoaded ? Anim.status : nil`，
            // 这是为了不碰「切组/切页立即刷新、不串图」这条被 v2.10.64 / 65 / 86 反复修过的不变量：
            //
            //   • 驱动键是 isThumbnailLoaded（Bool），**不是 currentKey**。因此「图 A → 图 B」
            //     （切到另一组、新 key 已在缓存里命中）时 Bool 不变 → 本修饰器不产生动画 →
            //     依旧是瞬时硬切，绝不会出现两组的图交叠淡化（那才是观感上的「串图」）。
            //   • 「有图 → 占位」（切到未缓存的新组，state 回落 loading）时，新一轮 body 里
            //     isLoaded 已是 false → 动画取 nil → 旧图**立即**消失，不留任何淡出尾巴，
            //     旧组的图一帧都不会拖到新组上。
            //   • 只有「占位 → 有图」这一个方向拿到 Anim.thumbnailFade（新 body 里 isLoaded 为 true），
            //     即真正需要柔化的那一次显影。
            //
            // 换成 `.animation(Anim.thumbnailFade, value: currentKey)` 或无条件 `.animation(...)`
            // 都会破坏上面两条，切组时会看到旧图淡出/交叠——改动此行前请先复现切组场景。
            .animation(isThumbnailLoaded ? Anim.thumbnailFade : nil, value: isThumbnailLoaded)
        }
        // v2.9.25 hotfix: 框高需容纳约 4 行等宽文本（行高≈17pt，4 行≈68pt + padding 8×2≈16pt
        // + 余量 ≈ 116pt）。minHeight 116 / idealHeight 140 保证内容区净高足够放下 4 行；
        // 长内容仍靠 maxHeight:.infinity 自适应撑开。
        .frame(minHeight: 116, idealHeight: 140, maxHeight: .infinity)
        .clipped()
        // v2.10.73 (方案③): 去掉 `.id(currentKey)`——不再靠内部整格重建强刷缩略图；
        // 刷新改由「currentKey 变化 → 读取新 key → provider 状态驱动重渲染」保证。
        .onAppear { loadIfNeeded() }
        .onChange(of: currentKey) { _ in loadIfNeeded() }
        // v2.10.86: 触发解码的第三道保险。卡片身份是 `.id(slot)`（v2.10.73 起为了切组流畅而复用
        // 卡片），所以切组时 `onAppear` 不会再触发，全靠 `onChange(of: currentKey)` 这一个钩子；
        // 一旦它在某个更新时序里没被触发（或触发时状态已被别的路径改写），槽位就会永久停在占位图，
        // 只能靠切走再切回自愈——正是本次回归的表现。`.task(id:)` 与 onChange 相互独立：它在视图
        // 出现以及 id 变化时都会重新执行，且执行点在当轮更新之外。
        // load() 内部对「已缓存 / 正在解码 / 已知失败」都会直接返回，因此重复调用零成本、不会重复解码。
        .task(id: currentKey) { loadIfNeeded() }
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
                // v2.10.82:「正文为空但有附件」的槽位（items 为空、attachments 非空，
                // 故 content.isEmpty 为 false，走到此文本分支）预览解析为占位符 "(空)"。
                // 仅此情形把占位文字在正文内容区水平+垂直居中；有正文文本时仍沿用
                // 左对齐 + 顶部多行铺排，图片/视频缩略图与完全空槽位占位均不经过此分支。
                Text(multilinePreview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.8))
                    .multilineTextAlignment(isEmptyBodyPlaceholder ? .center : .leading)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: isEmptyBodyPlaceholder ? .center : .leading)
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

    // v2.10.82: 正文预览是否为占位符 "(空)"。仅当槽位没有可显示正文（纯附件槽位，
    // items 为空 → content.preview 回退为 "(空)"，且 plainText 无有效文本）时为 true。
    // 用来把 "(空)" 占位在正文内容区水平+垂直居中，其它有正文的文本卡片不受影响。
    private var isEmptyBodyPlaceholder: Bool {
        multilinePreview == "(空)"
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

    // v2.10.73 (方案③): 触发解码的唯一入口。渲染态外置到 ThumbnailProvider（keyed 单一数据源），
    // 本视图只在「当前 key 未命中缓存」时请求 provider.load(...)。所有内容类型判定、后台限流解码、
    // in-flight 去重、失败态记录都在 provider.load 内部完成——本视图不再持有 token / @StateObject。
    private func loadIfNeeded() {
        guard provider.image(for: currentKey) == nil else { return }
        provider.load(key: currentKey, content: content, specialSlotId: specialSlotId, slot: slot)
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
