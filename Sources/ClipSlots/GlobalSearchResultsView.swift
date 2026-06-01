import SwiftUI

// MARK: - Global Search Results View (v2.5.2)

struct GlobalSearchResultsView: View {
    let results: [SlotGlobalSearchResult]
    let currentPageId: String
    let currentGroupId: String
    var onJump: (SlotGlobalSearchResult) -> Void

    @State private var isExpanded = false
    @State private var hoveredResultId: String?
    @State private var pinnedPreviewId: String?
    @Environment(\.colorScheme) private var colorScheme

    private var visibleResults: [SlotGlobalSearchResult] {
        Array(results.prefix(isExpanded ? 20 : 5))
    }

    private var previewResult: SlotGlobalSearchResult? {
        if let id = pinnedPreviewId,
           let pinned = results.first(where: { $0.id == id }) {
            return pinned
        }
        if let id = hoveredResultId,
           let hovered = results.first(where: { $0.id == id }) {
            return hovered
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

                footer
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
            VStack(spacing: 5) {
                ForEach(visibleResults) { result in
                    resultRow(result)
                }
            }
        }
        .frame(maxHeight: isExpanded ? 300 : 150)
    }

    private func resultRow(_ result: SlotGlobalSearchResult) -> some View {
        let isCurrent = result.pageId == currentPageId && result.groupId == currentGroupId
        let isPinned = pinnedPreviewId == result.id

        return HStack(spacing: 8) {
            // Slot badge
            Text("\(result.slot)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if isCurrent {
                        Text("当前")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
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

            // Eye button
            Button {
                if pinnedPreviewId == result.id {
                    pinnedPreviewId = nil
                } else {
                    pinnedPreviewId = result.id
                }
            } label: {
                Image(systemName: isPinned ? "eye.fill" : "eye")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help(isPinned ? "取消固定预览" : "固定预览")

            // Jump button
            Button {
                onJump(result)
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("跳转到该槽位")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isPinned ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isCurrent ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.10), lineWidth: 1)
        )
        .onHover { hovering in
            hoveredResultId = hovering ? result.id : nil
        }
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
                Text("悬停结果可预览")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxHeight: isExpanded ? 300 : 150, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    @ViewBuilder
    private func previewContent(for result: SlotGlobalSearchResult) -> some View {
        if let fileURL = result.content.primaryFileURL {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: result.content.isImageFile ? "photo" : "doc")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)

                Text(fileURL.lastPathComponent)
                    .font(.caption2)
                    .lineLimit(2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        } else if let webURL = result.content.detectedWebURL {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)

                Text(webURL.absoluteString)
                    .font(.caption2)
                    .lineLimit(3)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        } else {
            Text(result.content.preview)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(5)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        }
    }

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

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if results.count > 5 {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(
                        isExpanded ? "收起" : "展开更多 \(results.count - 5) 个结果",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            if isExpanded && results.count > 20 {
                Text("还有 \(results.count - 20) 个结果未显示，请继续细化关键词")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}
