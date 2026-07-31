import SwiftUI
import ClipSlotsKit

// MARK: - Global Search Results View (v2.5.3)

struct GlobalSearchResultsView: View {
    let results: [SlotGlobalSearchResult]
    let currentPageId: String
    let currentGroupId: String
    var onJump: (SlotGlobalSearchResult) -> Void
    @Binding var sortRule: SlotSearchSortRule

    @State private var selectedResultId: String?
    @Environment(\.colorScheme) private var colorScheme

    private var previewResult: SlotGlobalSearchResult? {
        if let id = selectedResultId,
           let selected = results.first(where: { $0.id == id }) {
            return selected
        }
        return results.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if results.isEmpty {
                emptyView
            } else {
                HStack(alignment: .top, spacing: 12) {
                    resultList
                        .frame(maxWidth: .infinity, alignment: .leading)

                    previewPanel
                        .frame(width: 260)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.caption)
                .foregroundColor(.accentColor)

            Text(results.isEmpty
                 ? "全局未找到匹配槽位"
                 : "全局找到 \(results.count) 个匹配槽位")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            Spacer()

            if !results.isEmpty {
                Picker("排序", selection: $sortRule) {
                    ForEach(SlotSearchSortRule.allCases) { rule in
                        Text(rule.title).tag(rule)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .help("结果排序方式")
            }
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            Text("没有匹配的全局结果")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    // MARK: - Result List (Left)

    private var resultList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 6) {
                ForEach(results) { result in
                    resultRow(result)
                }
            }
            .padding(.trailing, 4)
        }
        .frame(minHeight: 120, maxHeight: 260)
    }

    private func resultRow(_ result: SlotGlobalSearchResult) -> some View {
        let isCurrent = result.pageId == currentPageId && result.groupId == currentGroupId
        let isSelected = selectedResultId == result.id

        return HStack(spacing: 10) {
            // Slot badge
            Text("\(result.slot)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isCurrent {
                        Text("当前")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .foregroundColor(.accentColor)
                    }

                    Text(result.displayTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }

                Text(result.displaySubtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSelected
                    ? Color.accentColor.opacity(0.50)
                    : Color.secondary.opacity(0.10),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                selectedResultId = result.id
            }
        }
        .onTapGesture {
            selectedResultId = result.id
            onJump(result)
        }
        .help("点击跳转到该槽位")
    }

    // MARK: - Preview Panel (Right)

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result = previewResult {
                Text(result.displayTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)

                Text(result.displaySubtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                previewContent(for: result)

                actionButtons(for: result)
            } else {
                Spacer(minLength: 0)
                Text("暂无预览")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(minHeight: 120, maxHeight: 260, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    // MARK: - Preview Content (v2.5.3: real thumbnail support)

    @ViewBuilder
    private func previewContent(for result: SlotGlobalSearchResult) -> some View {
        // Try real image preview first (v2.8.0 perf H4: the image branch now loads
        // any on-disk image asynchronously instead of decoding it on the main thread
        // inside the view body).
        if hasImagePreview(for: result) {
            SearchResultPreviewImage(content: result.content)
                // v2.9.18: 预览图最大高度由 120 放大到 160，提升缩略图可读性。
                .frame(maxWidth: .infinity, maxHeight: 160)
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let webURL = result.content.detectedWebURL {
            VStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                Text(webURL.host ?? webURL.absoluteString)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundColor(.secondary)
                Text(webURL.absoluteString)
                    .font(.caption2)
                    .lineLimit(2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 90)
        } else if let fileURL = result.content.primaryFileURL {
            VStack(spacing: 6) {
                Image(systemName: result.previewIconName)
                    .font(.system(size: 30))
                    .foregroundColor(.secondary)
                Text(fileURL.lastPathComponent)
                    .font(.caption2)
                    .lineLimit(2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 90)
        } else {
            Text(result.content.preview)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        }
    }

    // MARK: - Preview Image Helper

    /// Whether this result should render an image preview. Cheap and synchronous:
    /// `hasImage` only inspects item type strings and the file branch only checks
    /// existence, never decodes. The actual pixel load happens asynchronously in
    /// `SearchResultPreviewImage`.
    private func hasImagePreview(for result: SlotGlobalSearchResult) -> Bool {
        // ATT-2 (v2.10.32): use the cheap `hasImage` type check instead of `inlineImage`.
        // This runs for every result row; `inlineImage` would fully decode a pasted
        // image on the main thread. This was previously masked by the grid warming the
        // full-res cache, but the grid now decodes only a downsampled thumbnail.
        if result.content.hasImage { return true }
        if let fileURL = result.content.primaryFileURL,
           result.content.isImageFile,
           FileManager.default.fileExists(atPath: fileURL.path) {
            return true
        }
        return false
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private func actionButtons(for result: SlotGlobalSearchResult) -> some View {
        VStack(spacing: 4) {
            // Jump
            Button {
                onJump(result)
            } label: {
                Label("跳转", systemImage: "arrow.right.circle")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            // File actions
            if let fileURL = result.content.primaryFileURL {
                let exists = FileManager.default.fileExists(atPath: fileURL.path)

                Button {
                    SlotTypeActions.openFile(fileURL)
                } label: {
                    Label("打开文件", systemImage: "doc")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(!exists)

                Button {
                    SlotTypeActions.revealInFinder(fileURL)
                } label: {
                    Label("打开所在目录", systemImage: "folder")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(!exists)

                Button {
                    SlotTypeActions.copyFilePath(fileURL)
                } label: {
                    Label("复制路径", systemImage: "doc.on.doc")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            // URL actions
            if let webURL = result.content.detectedWebURL {
                Button {
                    SlotTypeActions.openWebURL(webURL)
                } label: {
                    Label("打开链接", systemImage: "safari")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    SlotTypeActions.copyString(webURL.absoluteString)
                } label: {
                    Label("复制链接", systemImage: "link")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    SlotTypeActions.copyMarkdownLink(webURL)
                } label: {
                    Label("复制 Markdown", systemImage: "text.badge.plus")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Async Preview Image (v2.8.0 perf H4)

/// Renders the selected search result's image preview. Inline (pasteboard) images
/// come from the cached `inlineImage` (v2.8.0 H1) and appear immediately; on-disk
/// image files are decoded on a background queue and swapped in when ready, so
/// selecting an image-file result no longer stalls the main thread while a
/// full-resolution `NSImage(contentsOf:)` decodes.
private struct SearchResultPreviewImage: View {
    let content: SlotContent
    @State private var fileImage: NSImage?
    // ATT-2 (v2.10.32): inline (pasteboard) image decoded off the main thread.
    @State private var inlineImage: NSImage?

    // P1-5 (v2.10.35): 内容标识键。用 contentId::updatedAt + 文件路径唯一标识一条结果的图片。
    // 当右侧预览从图片结果 A 切到图片结果 B 时，二者命中同一 `if hasImagePreview` 分支、SwiftUI 复用同一
    // 视图实例仅更新 content 常量、视图身份不变 → 旧的 `.onAppear` 只触发一次、@State 保留 A 的旧图，导致
    // B 的预览显示 A 的图。改用 `.task(id:)` 绑定该键：键变即重跑加载，先清空旧图再按新 content 解码。
    private var previewKey: String {
        "\(content.contentId)::\(content.updatedAt)::\(content.primaryFileURL?.path ?? "")"
    }

    var body: some View {
        ZStack {
            if let image = inlineImage ?? fileImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // P1-5 (v2.10.35): 随内容标识刷新（替换只触发一次的 .onAppear）。切换结果时先清空上一张的解码结果，
        // 再按当前 content 重新加载，彻底消除 A→B 预览残影。
        .task(id: previewKey) {
            inlineImage = nil
            fileImage = nil
            loadImageIfNeeded()
        }
    }

    private func loadImageIfNeeded() {
        // ATT-2 (v2.10.32): previously the body read `content.inlineImage` directly,
        // which fully decodes a pasted image on the main thread when a result is
        // selected. Decode it (and on-disk image files) off the main thread instead.
        // P1-5 (v2.10.35): 捕获发起时的内容键，异步完成回主线程时若已切到别的结果则丢弃，防串图。
        let keyAtDispatch = previewKey
        if content.hasImage, inlineImage == nil {
            let snapshot = content
            DispatchQueue.global(qos: .userInitiated).async {
                let decoded = snapshot.decodedInlineImage()
                DispatchQueue.main.async {
                    guard self.previewKey == keyAtDispatch else { return }
                    self.inlineImage = decoded
                }
            }
            return
        }
        guard fileImage == nil,
              let url = content.primaryFileURL, content.isImageFile else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // P1-6 (v2.10.35): 此前用 NSImage(contentsOf:) 把磁盘图片文件全尺寸解码进内存，一张几十 MB 的
            // 高分辨率图会在预览时造成内存尖峰。改走 ImageIO 下采样（长边 ≤ 2048px，增量解码，全尺寸位图
            // 永不落内存）；极少数 ImageIO 无法解码的格式再回退到 NSImage 兜底。
            let image = ClipSlotsImageIO.downsampledImage(url: url, maxPixel: 2048) ?? NSImage(contentsOf: url)
            DispatchQueue.main.async {
                guard self.previewKey == keyAtDispatch else { return }
                self.fileImage = image
            }
        }
    }
}
