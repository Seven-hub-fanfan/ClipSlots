import AppKit
import AVFoundation
import SwiftUI
import ClipSlotsKit

/// 整个工作区只持有一个按需播放器。解码帧直接交给 AVPlayerLayer，
/// 不发布逐帧进度，也不随节点选择、画布重绘重新创建 AVPlayer。
@MainActor
final class CanvasInlinePlayback: ObservableObject {
    enum Phase { case idle, loading, playing, paused, failed }
    @Published private(set) var nodeID: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var player: AVPlayer?
    private(set) var sourceIdentity: String?
    private var request = UUID()
    private var preparation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var ended = false

    func toggle(nodeID: String, attachment: SlotContent.SlotAttachment) {
        let identity = attachment.canvasSourceIdentity
        if self.nodeID == nodeID, sourceIdentity == identity {
            switch phase {
            case .loading, .playing: pause(); return
            case .paused:
                guard let player else { break }
                if ended { player.seek(to: .zero); ended = false }
                player.play()
                phase = .playing
                return
            case .idle, .failed: break
            }
        }
        stop()
        self.nodeID = nodeID
        sourceIdentity = identity
        phase = .loading
        let ticket = request
        preparation = Task { [weak self] in
            // .bin 别名的文件系统工作与媒体探测均不阻塞鼠标事件。
            let url = await Task.detached(priority: .userInitiated) { attachment.canvasPlaybackURL }.value
            guard let self, self.request == ticket, !Task.isCancelled else { return }
            guard let url else { self.fail(ticket); return }
            let asset = AVURLAsset(url: url)
            do {
                guard try await asset.load(.isPlayable) else { self.fail(ticket); return }
                guard self.request == ticket, !Task.isCancelled else { return }
                self.install(AVPlayerItem(asset: asset), ticket: ticket)
            } catch {
                if !Task.isCancelled { self.fail(ticket) }
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.request == ticket, self.phase == .loading else { return }
            self.fail(ticket)
        }
    }

    private func install(_ item: AVPlayerItem, ticket: UUID) {
        guard request == ticket, phase == .loading else { return }
        player = AVPlayer(playerItem: item)
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor [weak self] in
                guard let self, self.request == ticket else { return }
                if status == .failed { self.fail(ticket) }
                else if status == .readyToPlay, self.phase == .loading {
                    self.timeout?.cancel()
                    self.player?.play()
                    self.phase = .playing
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.request == ticket else { return }
                self.player?.pause()
                self.ended = true
                self.phase = .paused
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fail(ticket) }
        }
    }

    private func fail(_ ticket: UUID) {
        guard request == ticket else { return }
        releasePlayer()
        request = UUID()
        phase = .failed
    }

    func pause() {
        if phase == .loading { stop(); return }
        guard phase == .playing else { return }
        player?.pause()
        phase = .paused
    }

    func stop() {
        request = UUID()
        releasePlayer()
        phase = .idle
        nodeID = nil
        sourceIdentity = nil
        ended = false
    }

    func stop(nodeID: String) {
        if self.nodeID == nodeID { stop() }
    }

    func invalidate(nodeID: String, sourceIdentity: String?) {
        if self.nodeID == nodeID, self.sourceIdentity != sourceIdentity { stop() }
    }

    private func releasePlayer() {
        preparation?.cancel()
        preparation = nil
        timeout?.cancel()
        timeout = nil
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    deinit {
        preparation?.cancel()
        timeout?.cancel()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }
}

struct CanvasInlineVideoPreview: View {
    @ObservedObject var playback: CanvasInlinePlayback
    let nodeID: String
    let sourceIdentity: String
    let scale: CGFloat
    let hovered: Bool

    private var active: Bool { playback.nodeID == nodeID && playback.sourceIdentity == sourceIdentity }
    private var phase: CanvasInlinePlayback.Phase { active ? playback.phase : .idle }

    var body: some View {
        ZStack {
            if active, let player = playback.player {
                CanvasInlinePlayerLayer(player: player)
            }
            if phase == .loading {
                ProgressView().controlSize(.small).colorScheme(.dark)
                    .scaleEffect(scale)
                    .padding(10 * scale).background(Circle().fill(.black.opacity(0.45)))
            } else if phase == .failed {
                VStack(spacing: 4 * scale) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 16 * scale))
                    Text("无法播放此视频").font(.system(size: 12 * scale))
                    Text("格式不受支持或文件已损坏").font(.system(size: 10 * scale))
                }
                .foregroundColor(.white).padding(10 * scale)
                .background(RoundedRectangle(cornerRadius: 8 * scale).fill(.black.opacity(0.7)))
            } else if phase != .playing || hovered {
                Image(systemName: phase == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: max(9, 13 * scale)))
                    .foregroundColor(.white)
                    .padding(max(6, 9 * scale))
                    .background(Circle().fill(.black.opacity(0.45)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel(phase == .playing ? "视频播放中，单击暂停，双击放大" : "单击播放视频，双击放大")
    }
}

/// 仅显示像素，不安装控件/手势或抢键盘；点击、拖拽、双击仍由画布原生路由唯一处理。
private struct CanvasInlinePlayerLayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerView { PlayerView() }
    func updateNSView(_ view: PlayerView, context: Context) {
        if view.videoLayer.player !== player { view.videoLayer.player = player }
    }
    static func dismantleNSView(_ view: PlayerView, coordinator: ()) { view.videoLayer.player = nil }

    final class PlayerView: NSView {
        let videoLayer = AVPlayerLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            videoLayer.videoGravity = .resizeAspect
            layer = videoLayer
            wantsLayer = true
        }
        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
