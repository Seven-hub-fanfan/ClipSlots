import SwiftUI
import AppKit
import AVKit
import ImageIO
import ClipSlotsKit

struct AgentArtifactMediaPreview: View {
    let content: Data
    let kind: AgentArtifactKind
    let path: String
    @StateObject private var model = MediaModel()

    private struct MediaIdentity: Equatable {
        let content: Data
        let kind: AgentArtifactKind
        let path: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = model.image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if let player = model.player {
                PlayerView(player: player)
            } else if model.loading {
                ProgressView("正在载入媒体…")
            }
            if let error = model.error {
                Text(error)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(kind == .image ? "图片" : kind == .video ? "视频" : "音频") · \(content.count) 字节")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: MediaIdentity(content: content, kind: kind, path: path)) {
            await model.prepare(content, kind: kind, path: path)
        }
        .onDisappear { model.clear() }
    }

    @MainActor
    final class MediaModel: ObservableObject {
        @Published var image: NSImage?
        @Published var player: AVPlayer?
        @Published var loading = false
        @Published var error: String?
        private var temporaryURL: URL?
        private var observer: NSKeyValueObservation?
        private var generation = UUID()

        func clear() {
            generation = UUID()
            observer = nil
            player?.pause(); player = nil; image = nil; loading = false; error = nil
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            temporaryURL = nil
        }

        func prepare(_ data: Data, kind: AgentArtifactKind, path: String) async {
            clear(); loading = true
            let ticket = generation
            guard data.count <= 64 * 1024 * 1024 else {
                error = "媒体过大，无法预览。"; loading = false; return
            }
            if kind == .image {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = props[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = props[kCGImagePropertyPixelHeight] as? NSNumber,
                      width.doubleValue > 0, height.doubleValue > 0,
                      width.doubleValue * height.doubleValue <= 40_000_000,
                      let image = NSImage(data: data) else {
                    error = "图片无法解码或尺寸过大。"
                    loading = false; return
                }
                self.image = image; loading = false
                return
            }
            let suffix = (path as NSString).pathExtension.lowercased()
            let safeSuffix = ["mp4", "mov", "m4v", "webm", "mp3", "m4a", "wav", "aac"].contains(suffix)
                ? suffix : (kind == .video ? "mp4" : "m4a")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("clipslots-artifact-\(UUID()).\(safeSuffix)")
            do {
                // This is a disposable copy of bounded artifact bytes, never a path from HTML.
                try await Task.detached {
                    try data.write(to: url, options: [.atomic])
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }.value
                guard ticket == generation, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url); return
                }
                temporaryURL = url
                let item = AVPlayerItem(url: url)
                player = AVPlayer(playerItem: item)
                observer = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let status = item.status
                    let message = item.error?.localizedDescription
                    Task { @MainActor in
                        guard let self, self.generation == ticket else { return }
                        if status == .failed {
                            self.error = "媒体预览失败：\(message ?? "不支持此格式。")"
                            self.player?.pause(); self.player = nil; self.loading = false
                        } else if status == .readyToPlay { self.loading = false }
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                guard ticket == generation else { return }
                self.error = "媒体预览失败：\(error.localizedDescription)"; loading = false
            }
        }
    }

    struct PlayerView: NSViewRepresentable {
        let player: AVPlayer
        func makeNSView(context: Context) -> AVPlayerView {
            let view = AVPlayerView()
            view.controlsStyle = .inline
            view.videoGravity = .resizeAspect
            view.player = player
            return view
        }
        func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
        static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
            view.player?.pause(); view.player = nil
        }
    }
}
