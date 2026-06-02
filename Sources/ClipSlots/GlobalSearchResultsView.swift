import SwiftUI

// MARK: - Global Search Results View (v2.5.3)

struct GlobalSearchResultsView: View {
    let results: [SlotGlobalSearchResult]
    let currentPageId: String
    let currentGroupId: String
    var onJump: (SlotGlobalSearchResult) -> Void

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
        // Try real image preview first
        if let nsImage = previewImage(for: result) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 120)
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

    private func previewImage(for result: SlotGlobalSearchResult) -> NSImage? {
        // 1. Inline image data from pasteboard
        if let inline = result.content.inlineImage {
            return inline
        }

        // 2. Image file: load from file path
        if let fileURL = result.content.primaryFileURL,
           result.content.isImageFile,
           FileManager.default.fileExists(atPath: fileURL.path),
           let image = NSImage(contentsOf: fileURL) {
            return image
        }

        return nil
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
