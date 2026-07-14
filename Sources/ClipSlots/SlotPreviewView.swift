import SwiftUI
import ClipSlotsKit
import AVKit

struct SlotPreviewView: View {
    let content: SlotContent

    @Environment(\.dismiss) private var dismiss
    @State private var largeImage: NSImage?
    @State private var videoPlayer: AVPlayer?
    // v2.8.7 (E): track that the async image load has finished but produced no image
    // (broken / missing file) so the preview shows a fallback instead of spinning forever.
    @State private var imageLoadFailed = false

    var body: some View {
        VStack(spacing: 0) {
            // Preview area
            ZStack {
                if content.isVideoFile, let url = content.primaryFileURL {
                    if FileManager.default.fileExists(atPath: url.path) {
                        VideoLargePreview(url: url, player: $videoPlayer)
                    } else {
                        unavailableFilePreview(url: url)
                    }
                } else if let image = largeImage ?? content.inlineImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                } else if content.isImageFile, content.primaryFileURL != nil {
                    // v2.8.4 (perf): previously this branch called NSImage(contentsOf:)
                    // synchronously inside body, decoding the FULL-resolution image on the
                    // main thread — opening the preview stalled/dropped frames for large
                    // images. loadLargeImage() (onAppear) now performs the decode off the
                    // main thread via ThumbnailProvider; show a spinner until it lands.
                    // v2.8.7 (E): if the async load finished with no image (broken/missing
                    // file), stop spinning and show a fallback instead of hanging forever.
                    if imageLoadFailed {
                        brokenImagePreview
                    } else {
                        ProgressView()
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
                // v2.7.35: the preview sheet should play the video directly, like image large preview.
                // No extra click, no jump to system player.
                if videoPlayer == nil {
                    let player = AVPlayer(url: url)
                    player.isMuted = true
                    videoPlayer = player
                    player.play()
                }
            }
        }
        .onDisappear {
            videoPlayer?.pause()
            videoPlayer = nil
        }
    }

    // MARK: - Video Large Preview (v2.7.35)

    // Legacy video thumbnail still used as poster fallback
    private func loadVideoThumbnail(url: URL) {
        guard largeImage == nil else { return }
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

    // v2.8.7 (E): shown when an image slot's file can't be decoded/loaded.
    private var brokenImagePreview: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42))
                .foregroundColor(.orange)
            Text("图片无法加载")
                .font(.headline)
            if let url = content.primaryFileURL {
                Text(url.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(24)
    }

    private func loadLargeImage() {
        guard content.isImageFile, let url = content.primaryFileURL else { return }
        ThumbnailProvider.shared.thumbnail(for: url, cacheKey: "preview-\(url.absoluteString)", size: CGSize(width: 800, height: 600)) { image, _ in
            // v2.8.7 (E): always terminate the loading state; if no image came back,
            // flag the failure so the view shows a fallback instead of spinning forever.
            largeImage = image
            imageLoadFailed = (image == nil)
        }
    }
}

// MARK: - v2.7.35 Video Large Preview

private struct VideoLargePreview: View {
    let url: URL
    @Binding var player: AVPlayer?

    var body: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor).opacity(0.55)
            if let player {
                SafePreviewAVPlayerView(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else {
                ProgressView()
            }
        }
        .padding(16)
        .overlay(alignment: .topLeading) {
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(10)
        }
    }
}

private struct SafePreviewAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
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
