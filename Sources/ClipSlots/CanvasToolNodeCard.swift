import SwiftUI
import AVFoundation
import SceneKit
import ClipSlotsKit

/// Tool-specific surfaces retain the canvas's external name tag and controls.
/// Expensive media decoding is off the UI thread and cancels on unmount.
struct CanvasToolNodeCard: View {
    let node: CanvasNode
    let attachments: [SlotContent.SlotAttachment]
    let selected: Bool
    let renderScale: CGFloat
    let onOpen: () -> Void
    let onHover: (Bool) -> Void
    @State private var waveform: [Float] = []
    @State private var player: AVPlayer?
    @State private var audioLease: CanvasMediaFileLease?
    @State private var playing = false
    @State private var scene: SCNScene?
    @State private var cloud: CanvasGaussianCloud?
    private var config: CanvasToolConfiguration { node.tools ?? .init() }
    private var resource: SlotContent.SlotAttachment? {
        attachments.first { $0.id.uuidString == config.resourceAttachmentID }
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(CanvasSkin.cardEmptyFill)
            if node.kind == .timeline {
                HStack(spacing: 6) {
                    Image(systemName: "film.stack").font(.system(size: 20))
                    if config.timeline.clips.isEmpty {
                        Text("添加片段，开始剪辑").foregroundColor(CanvasSkin.secondaryInk)
                    } else {
                        ForEach(config.timeline.clips.prefix(20)) { clip in
                            Text(clip.name).font(.system(size: 10)).lineLimit(2).padding(8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(CanvasSkin.nodeAccent(clip.isAudio ? .audio : .video).opacity(0.2))
                                .cornerRadius(6)
                        }
                        Text(String(format:"%.1f s",config.timeline.duration)).font(.caption.monospacedDigit())
                    }
                }.padding(16)
            } else if node.kind == .audio && !waveform.isEmpty {
                VStack(spacing: 18) {
                    Text(resource?.name ?? "音频").font(.system(size: 12)).lineLimit(1)
                    CanvasWaveform(values: waveform).frame(height: 72)
                    Button {
                        playing.toggle()
                        if playing { player?.seek(to: .zero); player?.play() } else { player?.pause() }
                    } label: { Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 24)) }
                        .buttonStyle(.plain).canvasControlRegion("tool-audio-play-\(node.id)")
                }.padding(28)
            } else if let cloud {
                CanvasGaussianPreview(cloud: cloud).id(resource?.id)
                    .canvasControlRegion("tool-3d-preview-\(node.id)")
            } else if let scene {
                CanvasScenePreview(scene: scene, stage: node.kind == .stage ? config.stage : nil)
                    .canvasControlRegion("tool-3d-preview-\(node.id)")
            } else {
                VStack(spacing: 16) {
                    Image(systemName: node.kind.symbolName).font(.system(size: 30, weight: .light)).foregroundColor(CanvasSkin.cardEmptyGlyph)
                        .frame(width: 64, height: 64).background(RoundedRectangle(cornerRadius: 18).fill(CanvasSkin.subtleFill))
                    Text(summary).font(.system(size: 12)).foregroundColor(CanvasSkin.secondaryInk).lineLimit(2)
                    Button(node.kind == .stage ? "进入片场" : node.kind == .threeD ? "打开 3D" : "创作音频") { onOpen() }
                        .buttonStyle(CanvasToolButtonStyle()).canvasControlRegion("tool-open-\(node.id)")
                }.padding(20)
            }
            if selected {
                VStack { HStack { Spacer(); Button { onOpen() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").padding(8)
                }.buttonStyle(.plain).background(CanvasSkin.chromeFill).cornerRadius(7)
                    .canvasControlRegion("tool-editor-\(node.id)")
                }; Spacer() }.padding(12)
            }
        }
        .foregroundColor(CanvasSkin.ink)
        .frame(width: node.width, height: node.height)
        .overlay(alignment: .topLeading) {
            Label(node.kind.displayName,systemImage:node.kind.symbolName).font(.system(size: 11))
                .foregroundColor(CanvasSkin.tagInk).offset(y: -24)
        }
        .onHover(perform:onHover)
        .onTapGesture(count:2, perform:onOpen)
        .scaleEffect(renderScale,anchor:.topLeading)
        .frame(width:node.width * renderScale,height:node.height * renderScale,alignment:.topLeading)
        .onDisappear { player?.pause() }
        .task(id: node.tools) {
            waveform = []; scene = nil; cloud = nil; player?.pause(); player = nil; audioLease = nil
            let urls: [String: (url: URL, name: String)] = Dictionary(uniqueKeysWithValues: attachments.compactMap { item in
                guard let path = [item.storagePath,item.path,item.originalPath].compactMap({$0})
                    .first(where:{FileManager.default.fileExists(atPath:$0)}) else {return nil}
                return (item.id.uuidString,(URL(fileURLWithPath:path),item.name))
            })
            do {
                if node.kind == .stage {
                    let result = try await CanvasToolMedia.worker {try CanvasStageRenderer.scene(config.stage,urls:urls)}
                    if !Task.isCancelled {scene = result}
                } else if let resource,let url = urls[resource.id.uuidString]?.url {
                    if node.kind == .audio {
                        let result = try await CanvasToolMedia.worker {try CanvasToolMedia.waveform(url,bars:80)}
                        if !Task.isCancelled {
                            let lease=try CanvasMediaFileLease(source:url,name:resource.name)
                            waveform=result;audioLease=lease;player=AVPlayer(url:lease.url)
                        }
                    } else if node.kind == .threeD {
                        if (resource.name as NSString).pathExtension.lowercased() == "spz" {
                            let result = try await CanvasToolMedia.worker {try CanvasSPZ.load(url)}
                            if !Task.isCancelled {cloud = result}
                        } else {
                            let result = try await CanvasToolMedia.worker {try CanvasGLBScene.load(url,name:resource.name)}
                            if !Task.isCancelled {scene = result}
                        }
                    }
                }
            } catch { }
        }
    }
    private var summary: String {
        switch node.kind {
        case .audio: return "音乐 · 配音 · 音效"
        case .threeD: return resource?.name ?? "GLB 对象 · SPZ 世界"
        case .stage: return config.stage.entities.isEmpty ? "布置场景，创建镜头" : "\(config.stage.entities.count) 个对象 · \(config.stage.shots.count) 个镜头"
        default: return ""
        }
    }
}
