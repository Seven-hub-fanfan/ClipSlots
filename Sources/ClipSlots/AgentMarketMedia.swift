import SwiftUI
import AppKit
import AVKit
import ClipSlotsKit

struct MarketMedia: Identifiable {
    let url: URL
    let video: Bool
    var id: String { url.absoluteString }
    init?(_ raw: JSONValue) {
        guard let text = raw["url"]?.stringValue ?? raw["src"]?.stringValue,
              let url = URL(string: text), url.scheme == "https" else { return nil }
        self.url = url
        video = raw["media_type"]?.stringValue == "video" || raw["type"]?.stringValue == "video"
            || ["mp4", "webm", "mov"].contains(url.pathExtension)
    }
}
struct MarketMediaGallery: View {
    let item: AgentMarketItem
    let onPreview: (MarketMedia) -> Void
    private var media: [MarketMedia] {
        (item.raw["marketing_slots"]?.arrayValue ?? []).prefix(3).compactMap(MarketMedia.init)
    }
    var body: some View {
        if let hero = media.first(where: \.video), media.contains(where: { !$0.video }) {
            HStack(alignment: .bottom, spacing: 8) {
                tile(hero).frame(maxWidth: .infinity)
                VStack(spacing: 8) { ForEach(media.filter { !$0.video }) { tile($0) } }.frame(width: 216)
            }.frame(height: 248)
        } else if !media.isEmpty {
            VStack(spacing: 12) { ForEach(media) { tile($0).frame(height: $0.video ? 248 : 140) } }
        } else {
            ForEach(Array((item.raw["example_prompts"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, prompt in
                Text(prompt.stringValue ?? prompt["prompt"]?.stringValue ?? "")
                    .font(.system(size: 13)).foregroundStyle(TapSkin.secondaryInk)
            }
        }
    }
    private func tile(_ media: MarketMedia) -> some View {
        Button { onPreview(media) } label: {
            ZStack {
                if media.video {
                    MarketVideoTile(url: media.url).allowsHitTesting(false)
                } else {
                    AsyncImage(url: media.url) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                        else if phase.error != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(TapSkin.secondaryInk) }
                        else { ProgressView() }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("market-media-" + (media.video ? "video" : "image"))
    }
}
struct MarketMediaPreview: View {
    let media: MarketMedia
    let onClose: () -> Void
    @State private var player: AVPlayer?
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.8).contentShape(Rectangle()).onTapGesture(perform: onClose)
            if media.video {
                VideoPlayer(player: player).onAppear { player = AVPlayer(url: media.url); player?.play() }
                    .onDisappear { player?.pause(); player = nil }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16).onTapGesture {}
            } else {
                AsyncImage(url: media.url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else if phase.error != nil { Label("图片加载失败", systemImage: "exclamationmark.triangle") }
                    else { ProgressView() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16).onTapGesture {}
            }
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 20)).frame(width:32,height:32) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).padding(20)
                .accessibilityIdentifier("market-media-preview-close")
        }.frame(maxWidth:.infinity,maxHeight:.infinity).onExitCommand(perform: onClose)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("market-media-preview")
    }
}

private struct MarketVideoTile: View {
    let url: URL
    @State private var player: AVQueuePlayer?
    @State private var loop: AVPlayerLooper?
    var body: some View {
        VideoPlayer(player: player).onAppear {
            let player = AVQueuePlayer(); player.isMuted = true
            loop = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            self.player = player; player.play()
        }.onDisappear { player?.pause(); loop = nil; player = nil }
    }
}

struct AgentMarketPreviewPresenter: NSViewRepresentable {
    @Binding var media: MarketMedia?
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class OwnerProbe: NSView {
        var attached: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attached?(window) }
    }
    func makeNSView(context: Context) -> NSView {
        let view = OwnerProbe()
        view.attached = { [weak coordinator = context.coordinator] owner in
            DispatchQueue.main.async { coordinator?.update(owner, media: coordinator?.current?.media) }
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.current = self
        // Read the binding during SwiftUI's tracked update. Reading it only in
        // the queued callback delays presentation until an unrelated redraw.
        let selection = media
        DispatchQueue.main.async { context.coordinator.update(view.window, media: selection) }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }
    @MainActor final class Coordinator {
        final class PreviewPanel: NSPanel { override var canBecomeKey: Bool { true } }
        var current: AgentMarketPreviewPresenter?
        var panel: NSPanel?
        weak var ownerWindow: NSWindow?
        func update(_ window: NSWindow?, media: MarketMedia?) {
            if let window { ownerWindow = window }
            guard let current, current.media?.id == media?.id else { return }
            guard let media else { close(); return }
            guard let window = window ?? ownerWindow else { return }
            guard panel == nil else { return }
            let owner = window.parent ?? window
            guard let content = owner.contentView else { return }
            let frame = owner.convertToScreen(content.convert(content.bounds, to: nil))
            let panel = PreviewPanel(contentRect:frame, styleMask:[.borderless], backing:.buffered, defer:false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.contentView = NSHostingView(rootView: MarketMediaPreview(media:media, onClose:{ [weak self] in
                self?.current?.media = nil; self?.close()
            }))
            panel.setFrame(frame, display: true)
            self.panel = panel
            window.addChildWindow(panel, ordered:.above); panel.makeKeyAndOrderFront(nil)
        }
        func close() {
            if let panel { panel.parent?.removeChildWindow(panel); panel.close() }
            panel = nil
        }
    }
}
