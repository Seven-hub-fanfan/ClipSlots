import SwiftUI
import AVKit

struct SlotPreviewView: View {
    let content: SlotContent

    @Environment(\.dismiss) private var dismiss
    @State private var largeImage: NSImage?
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            // Preview area
            ZStack {
                if content.isVideoFile, let url = content.primaryFileURL {
                    VideoPlayer(player: player)
                        .padding(16)
                        .onAppear {
                            player = AVPlayer(url: url)
                            player?.play()
                        }
                        .onDisappear {
                            player?.pause()
                            player = nil
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
            loadLargeImage()
        }
    }

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
