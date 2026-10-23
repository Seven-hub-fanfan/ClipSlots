import SwiftUI
import AVFoundation
import ClipSlotsKit

struct CanvasGenerationBackdrop: View {
    let attachment: SlotContent.SlotAttachment
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    var body: some View {
        ZStack {
            CanvasAttachmentPreviewImage(attachment: attachment, maxPixel: 900, contentMode: .fill)
            if attachment.canvasIsVideoLike, !reducedMotion {
                CanvasGenerationVideoBackdrop(attachment: attachment)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CanvasGenerationVideoBackdrop: NSViewRepresentable {
    let attachment: SlotContent.SlotAttachment
    func makeNSView(context: Context) -> BackdropView { BackdropView() }
    func updateNSView(_ view: BackdropView, context: Context) { view.load(attachment) }
    static func dismantleNSView(_ view: BackdropView, coordinator: ()) { view.stop() }

    final class BackdropView: NSView {
        private let video = AVPlayerLayer()
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var task: Task<Void, Never>?
        private var identity: String?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            video.videoGravity = .resizeAspectFill
            layer = video; wantsLayer = true
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
        func load(_ attachment: SlotContent.SlotAttachment) {
            guard identity != attachment.canvasSourceIdentity else { return }
            stop()
            identity = attachment.canvasSourceIdentity
            let ticket = identity
            task = Task { @MainActor [weak self] in
                let url = await Task.detached { attachment.canvasPlaybackURL }.value
                guard let self, !Task.isCancelled, self.identity == ticket, let url else { return }
                let asset = AVURLAsset(url: url)
                guard (try? await asset.load(.isPlayable)) == true,
                      !Task.isCancelled, self.identity == ticket else { return }
                let player = AVQueuePlayer()
                player.isMuted = true
                self.player = player
                self.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
                self.video.player = player
                player.play()
            }
        }
        func stop() {
            task?.cancel(); task = nil
            player?.pause(); looper?.disableLooping(); looper = nil
            player?.removeAllItems(); player = nil; video.player = nil; identity = nil
        }
        deinit { task?.cancel() }
    }
}
