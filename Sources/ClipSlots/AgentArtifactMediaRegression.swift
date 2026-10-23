#if DEBUG
import AppKit
import AVKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runAgentArtifactMediaProbe(directory: URL, check: (Bool, String) -> Void) async {
    guard let fixtures = ProcessInfo.processInfo.environment["CLIPSLOTS_ARTIFACT_MEDIA_FIXTURES"] else { return }
    let root = URL(fileURLWithPath: fixtures)
    func wait(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    let model = AgentArtifactMediaPreview.MediaModel()
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { model.clear(); window.close() }
    do {
        for (kind, name) in [(AgentArtifactKind.video, "motion-fixture.mp4"), (.audio, "audio-fixture.wav")] {
            let bytes = try Data(contentsOf: root.appendingPathComponent(name))
            if kind == .video {
                let captured = try await Task.detached {
                    try AgentAttachmentImport.capture(root.appendingPathComponent(name))
                }.value
                check(captured.sampledFrames?.count == 3 && captured.textSnapshot?.contains("未读取音轨") == true,
                      "video input captures three actual frames and declares sampling limits")
                let message = AgentMessage(role: .user, content: "描述抽帧", attachments: [captured])
                var config = AgentConfig(); config.supportsImageInput = true
                try AgentAttachmentImport.validateImageSupport(history: [message], supported: true)
                let wire = AgentService.requestBody(history: [message], config: config, tools: [])
                check(wire["messages"]?.arrayValue?.last?["content"]?.arrayValue?.count == 4,
                      "video input emits text plus three image parts in actual backend body")
                let saved = try JSONDecoder().decode(AgentAttachment.self, from: JSONEncoder().encode(captured))
                check(saved.sampledFrames == captured.sampledFrames, "video sampled bytes survive history persistence")
                do {
                    try AgentAttachmentImport.validateImageSupport(history: [message], supported: false)
                    check(false, "video frame input requires declared image capability")
                } catch { check(true, "video frame input requires declared image capability") }
            }
            await model.prepare(bytes, kind: kind, path: name)
            await wait { !model.loading }
            guard let player = model.player, let item = player.currentItem else {
                check(false, "\(kind.rawValue) reaches AVPlayer: \(model.error ?? "not ready")"); continue
            }
            check(item.status == .readyToPlay && model.error == nil, "\(kind.rawValue) AVPlayer decodes local artifact")
            let temporaryURL = (item.asset as? AVURLAsset)?.url
            check(temporaryURL != nil && temporaryURL != root.appendingPathComponent(name),
                  "\(kind.rawValue) player owns a disposable preview copy")
            if let temporaryURL {
                let permissions = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.posixPermissions] as? NSNumber
                check(permissions?.intValue == 0o600, "\(kind.rawValue) preview copy is owner-only")
                check(try Data(contentsOf: temporaryURL) == bytes, "\(kind.rawValue) preview copy preserves artifact bytes")
            }
            let host = NSHostingView(rootView: AgentArtifactMediaPreview.PlayerView(player: player))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            player.isMuted = true
            player.play()
            await wait { player.currentTime().seconds >= 0.2 }
            check(player.currentTime().seconds >= 0.2 && player.error == nil,
                  "\(kind.rawValue) actual playback clock advances")
            player.pause()
            let sought = await withCheckedContinuation { continuation in
                player.seek(to: CMTime(seconds: 0.4, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero) { continuation.resume(returning: $0) }
            }
            check(sought && abs(player.currentTime().seconds - 0.4) < 0.05,
                  "\(kind.rawValue) actual seek reaches requested timestamp")
            if kind == .video {
                let generator = AVAssetImageGenerator(asset: item.asset)
                generator.appliesPreferredTrackTransform = true
                let frame = try generator.copyCGImage(at: CMTime(seconds: 0.4, preferredTimescale: 600), actualTime: nil)
                check(frame.width == 320 && frame.height == 180, "video frame decodes at original 16:9 dimensions")
                // AVPlayerView's video layer is not included by NSView bitmap
                // caching while locked. Keep a separately labelled decoded frame.
                let bitmap = NSBitmapImageRep(cgImage: frame)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("artifact-video-decoded-frame.png"))
            } else {
                let tracks = try await item.asset.loadTracks(withMediaType: .audio)
                check(!tracks.isEmpty, "audio artifact includes a decoded audio track")
            }
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = bitmap.representation(using: .png, properties: [:])
                try png?.write(to: directory.appendingPathComponent("artifact-\(kind.rawValue)-native.png"))
                check(png != nil, "\(kind.rawValue) mounts in native AVPlayerView")
            } else { check(false, "\(kind.rawValue) native AVPlayerView capture") }
            model.clear()
            check(player.rate == 0 && model.player == nil && model.image == nil, "\(kind.rawValue) teardown pauses and releases media")
            check(temporaryURL.map { !FileManager.default.fileExists(atPath: $0.path) } == true,
                  "\(kind.rawValue) teardown removes its disposable copy")
        }
        await model.prepare(Data("invalid media bytes".utf8), kind: .video, path: "broken.mp4")
        await wait { !model.loading }
        check(model.error != nil && model.player == nil, "invalid media reports decode failure without an endless spinner")
        await model.prepare(try Data(contentsOf: root.appendingPathComponent("motion-fixture.mp4")),
                            kind: .video, path: "recovered.mp4")
        await wait { !model.loading }
        check(model.error == nil && model.player?.currentItem?.status == .readyToPlay,
              "valid replacement recovers from the previous media error")
    } catch { check(false, "native artifact media: \(error.localizedDescription)") }
}
#endif
