import SwiftUI

struct SlotThumbnailView: View {
    let content: SlotContent

    @State private var thumbnail: NSImage?
    @State private var thumbnailLoaded = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))

            switch content.displayKind {
            case .image:
                if let image = thumbnail ?? content.inlineImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    thumbnailPlaceholder
                }
            case .file:
                filePreview
            case .text:
                textPreview
            case .empty:
                emptyPreview
            }
        }
        .frame(height: 120)
        .onAppear { loadThumbnail() }
        .onChange(of: content.preview) { _ in
            thumbnail = nil
            thumbnailLoaded = false
            loadThumbnail()
        }
    }

    // MARK: - Subviews

    private var thumbnailPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.system(size: 24))
                .foregroundColor(.secondary.opacity(0.5))
            Text("加载中…")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var filePreview: some View {
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
    }

    private var textPreview: some View {
        Text(content.preview)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.primary.opacity(0.8))
            .lineLimit(6)
            .truncationMode(.tail)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyPreview: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundColor(.secondary.opacity(0.4))
            Text("空槽位")
                .font(.caption2)
                .foregroundColor(.secondary)
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
        if ["svg", "sketch", "fig", "xd"].contains(ext) { return "paintpalette" }
        return "doc"
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnail() {
        guard !thumbnailLoaded else { return }
        thumbnailLoaded = true

        // Try inline image first
        if let inline = content.inlineImage {
            thumbnail = inline
            return
        }

        // Try QuickLook for file URLs
        guard let url = content.primaryFileURL, content.isImageFile || content.isFileContent else {
            return
        }

        ThumbnailProvider.shared.thumbnail(for: url) { image in
            thumbnail = image
        }
    }
}

struct SlotThumbnailView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 12) {
            SlotThumbnailView(content: SlotContent())
            SlotThumbnailView(content: {
                var c = SlotContent()
                c = c // text preview
                return c
            }())
        }
        .padding()
        .frame(width: 260)
    }
}
