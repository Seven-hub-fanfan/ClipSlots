import SwiftUI

struct SlotPreviewView: View {
    let content: SlotContent

    @Environment(\.dismiss) private var dismiss
    @State private var largeImage: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            // Preview area
            ZStack {
                if content.isVideoFile, let url = content.primaryFileURL {
                    if FileManager.default.fileExists(atPath: url.path) {
                        videoFilePreview(url: url)
                    } else {
                        unavailableFilePreview(url: url)
                    }
                } else if let image = largeImage ?? content.inlineImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                } else if content.isImageFile, let url = content.primaryFileURL {
                    if let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(16)
                            .onAppear { largeImage = image }
                    } else {
                        fallbackPreview
                    }
                } else {
                    fallbackPreview
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.03))

            Divider()

            // Bottom bar
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let name = content.fileDisplayName {
                        Text(name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    Text(content.metadataSummary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if content.isVideoFile, let url = content.primaryFileURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("打开文件", systemImage: "play.rectangle")
                    }
                }

                Button {
                    _ = ClipboardManager.shared.restore(content)
                    dismiss()
                } label: {
                    Label("复制到剪贴板", systemImage: "doc.on.doc")
                }

                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            if content.isImageFile {
                loadLargeImage()
            } else if content.isVideoFile, let url = content.primaryFileURL {
                loadVideoThumbnail(url: url)
            }
        }
    }

    // MARK: - Video Preview (no AVKit — stable)

    private func videoFilePreview(url: URL) -> some View {
        VStack(spacing: 16) {
            ZStack {
                if let image = largeImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.08))
                        .frame(height: 260)
                        .overlay {
                            VStack(spacing: 10) {
                                ProgressView()
                                Text("正在生成视频预览…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                }

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.white.opacity(0.92))
                    .shadow(radius: 8)
            }

            VStack(spacing: 4) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("点击下方按钮使用系统播放器打开视频")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("打开视频", systemImage: "play.rectangle")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("在 Finder 中显示", systemImage: "finder")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                } label: {
                    Label("复制文件", systemImage: "doc.on.doc")
                }
            }
        }
        .padding(24)
    }

    private func loadVideoThumbnail(url: URL) {
        ThumbnailProvider.shared.thumbnail(
            for: url,
            cacheKey: "video-preview-\(url.absoluteString)",
            size: CGSize(width: 960, height: 540)
        ) { image, _ in
            largeImage = image
        }
    }

    // MARK: - Unavailable File

    private func unavailableFilePreview(url: URL) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42))
                .foregroundColor(.orange)

            Text("视频文件无法访问")
                .font(.headline)

            Text(url.path)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("在 Finder 中显示", systemImage: "finder")
            }
        }
        .padding(24)
    }

    // MARK: - Fallback & Image

    private var fallbackPreview: some View {
        ScrollView {
            Text(content.preview)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .textSelection(.enabled)
        }
    }

    private func loadLargeImage() {
        guard content.isImageFile, let url = content.primaryFileURL else { return }
        ThumbnailProvider.shared.thumbnail(for: url, cacheKey: "preview-\(url.absoluteString)", size: CGSize(width: 800, height: 600)) { image, _ in
            largeImage = image
        }
    }
}
