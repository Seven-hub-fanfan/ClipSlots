import SwiftUI

enum ThumbnailState {
    case idle
    case loading
    case loaded(NSImage)
    case failed
}

struct SlotThumbnailView: View {
    let content: SlotContent

    @State private var state: ThumbnailState = .idle
    @State private var loadToken = UUID()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))

            switch state {
            case .idle:
                idleView
            case .loading:
                loadingView
            case .loaded(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            case .failed:
                fallbackView
            }
        }
        .frame(height: 140)
        .clipped()
        .id(content.contentHash)
        .onAppear { reloadThumbnail() }
        .onChange(of: content.contentHash) { _ in
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
                Text(content.preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(6)
                    .truncationMode(.tail)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

        // Need a file URL for QuickLook
        guard let url = content.primaryFileURL, content.isImageFile || content.isFileContent else {
            state = .failed
            return
        }

        state = .loading

        ThumbnailProvider.shared.thumbnail(for: url, cacheKey: content.contentHash) { image in
            guard loadToken == token else { return }
            if let image = image {
                state = .loaded(image)
                return
            } else {
                state = .failed
            }
        }

        // 3-second timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard loadToken == token else { return }
            if case .loading = state {
                state = .failed
            }
        }
    }
}
