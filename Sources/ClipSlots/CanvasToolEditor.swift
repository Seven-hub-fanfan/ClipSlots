import SwiftUI
import AVKit
import SceneKit
import ClipSlotsKit

struct CanvasToolEditor: View {
    @ObservedObject var session: CanvasToolSession
    @ObservedObject var canvas: CanvasStore
    @State private var draft = CanvasToolConfiguration()
    @State private var selectedClip: String?
    @State private var selectedEntity: String?
    @State private var selectedShot: String?
    @State private var reset = 0
    @State private var playing = false
    @State private var time: Double = 0
    @State private var duration: Double = 0
    @State private var observer: Any?
    @State private var previewTask: Task<Void, Never>?
    private let stageTimer = Timer.publish(every: 1.0/30, on: .main, in: .common).autoconnect()
    private var kind: CanvasNodeKind { session.node?.kind ?? .audio }
    private var dirty: Bool { draft != session.configuration }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbolName).font(.system(size: 15))
                    .frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 10).fill(CanvasSkin.subtleFill))
                Text(kind.displayName).font(.system(size: 13, weight: .semibold))
                InterfaceHelpButton(title: "\(kind.displayName)使用说明", text: helpText,
                                    identifier: "tool-editor-help")
                Spacer()
                Button { canvas.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!canvas.canUndo || session.busy).help("撤销").accessibilityLabel("撤销")
                Button { canvas.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!canvas.canRedo || session.busy).help("重做").accessibilityLabel("重做")
                Button { session.chooseImport() } label: { Label("导入", systemImage: "plus") }
                exportMenu
                if session.busy { ProgressView().controlSize(.small); Button("取消") { session.cancel() } }
            }.padding(.horizontal, 16).padding(.vertical, 12).background(CanvasSkin.chromeFill)
            Divider()
            if session.node == nil {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle").font(.largeTitle)
                    Text("请回到此节点所在项目继续编辑")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    VStack(spacing: 10) {
                        preview.frame(minHeight: 140).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(CanvasSkin.cardEmptyFill).clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(CanvasSkin.border, lineWidth: 0.5))
                            .layoutPriority(1)
                        playback
                        if kind == .audio || kind == .threeD {
                            CanvasCloudControls(session: session, draft: $draft, isAudio: kind == .audio,
                                generateSpeech: { applyAndExport("wav", attach: true) })
                        }
                        if kind == .timeline { timeline.frame(height: 145) }
                        if kind == .stage { shots.frame(height: 88) }
                    }.padding(14).frame(minWidth: 430)
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                switch kind {
                                case .audio: audioControls
                                case .threeD: resourceControls
                                case .timeline: clipControls
                                case .stage: stageControls
                                default: EmptyView()
                                }
                            }.padding(12)
                        }
                        Divider()
                        HStack {
                            Text(dirty ? "修改待保存" : "已同步到节点").font(.system(size: 10)).foregroundColor(CanvasSkin.secondaryInk)
                            Spacer(minLength: 4)
                            Button(kind == .threeD ? "使用该资源" : "应用修改") {
                                session.save(draft, detail: "编辑\(kind.displayName)")
                            }
                            .buttonStyle(CanvasToolButtonStyle(prominent: true)).disabled(!dirty || session.busy)
                            .accessibilityIdentifier("tool-apply")
                        }.padding(12)
                    }.frame(minWidth: 250, idealWidth: 280, maxWidth: 320).background(CanvasSkin.void)
                }.disabled(session.busy)
            }
            if !session.message.isEmpty {
                Divider()
                HStack {
                    Text(session.message).font(.system(size: 11))
                        .foregroundColor(CanvasSkin.secondaryInk).lineLimit(2)
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .foregroundColor(CanvasSkin.ink).background(CanvasSkin.void)
        .font(.system(size: 11))
        .buttonStyle(CanvasToolButtonStyle()).textFieldStyle(CanvasToolFieldStyle())
        .toggleStyle(.switch).controlSize(.small)
        .onAppear {
            draft = session.configuration
            observer = session.player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                queue: .main) { value in
                    Task { @MainActor in
                    time = value.seconds.isFinite ? value.seconds : 0
                    let seconds = session.player.currentItem?.duration.seconds ?? 0
                    duration = seconds.isFinite ? seconds : 0
                    session.previewTime = time
                    if duration > 0 && time >= duration - 0.02 {
                        if draft.audio.loop && kind == .audio { session.player.seek(to: .zero); session.player.play() }
                        else { playing = false }
                    }
                    }
                }
            refresh()
        }
        .onChange(of: session.node?.tools) { _ in
            draft = session.configuration; refresh()
        }
        .onReceive(stageTimer) { _ in
            guard playing,(kind == .stage || kind == .threeD),!session.busy else { return }
            session.previewTime += 1.0/30
            let end=kind == .stage ? session.configuration.stage.duration : session.scene.map {CanvasGLBScene.animationDuration($0.rootNode)} ?? 0
            if session.previewTime >= end { session.previewTime=0;playing=false }
        }
        .onChange(of: canvas.activeProjectId) { _ in session.cancel() }
        .onChange(of: session.attachments) { _ in refresh() }
        .onReceive(session.store.$canvasSlotRevision) { _ in
            if let node = session.node {
                let live = session.store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
                if session.attachments != live { session.attachments = live }
            }
        }
        .onDisappear {
            previewTask?.cancel(); session.cancel()
            if let observer { session.player.removeTimeObserver(observer) }; observer = nil
        }
    }
    private func refresh() {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            do { try await session.refreshPreview() }
            catch is CancellationError {}
            catch { session.message = error.localizedDescription }
        }
    }
    private var helpText: String {
        switch kind {
        case .audio: return "导入音乐 / 音效；文字转语音使用 macOS 本机声音"
        case .threeD: return "拖动环绕 · 滚轮缩放 · SPZ：WASD 移动，Q/E 升降，R 重置"
        case .timeline: return "选择片段后裁剪、分割或调整顺序；合并回画布可继续引用"
        case .stage: return "对象和镜头独立保存；相邻镜头之间插值运动，支持摄影和 MP4 导出"
        default: return ""
        }
    }
    @ViewBuilder private var preview: some View {
        if kind == .audio {
            VStack(spacing: 20) {
                if session.waveform.isEmpty {
                    CanvasToolEmptyPreview(title: "创作你的声音", subtitle: "导入音频，或在下方描述音乐与音效", symbol: "waveform")
                } else {
                    Text(session.attachments.first(where: { $0.id.uuidString == draft.resourceAttachmentID })?.name ?? "音频")
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    CanvasWaveform(values: session.waveform, progress: duration > 0 ? time / duration : 0)
                        .frame(height: 80).padding(.horizontal, 24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if kind == .timeline {
            if session.player.currentItem != nil { VideoPlayer(player: session.player) }
            else { emptyPreview("添加视频与音频片段", symbol: "film.stack") }
        } else if let composite=session.composite,kind == .stage {
            CanvasStageCompositePreview(composite:composite,time:session.previewTime,capture:{session.capturePreview=$0})
        } else if let cloud = session.cloud {
            CanvasGaussianPreview(cloud: cloud, resetToken: reset, capture: {session.capturePreview=$0}).id(draft.resourceAttachmentID)
        } else if let scene = session.scene {
            CanvasScenePreview(scene: scene, time: session.previewTime,
                stage: kind == .stage ? session.configuration.stage : nil, resetToken: reset, capture: {session.capturePreview=$0})
        } else { emptyPreview(kind == .stage ? "添加对象，布置片场" : "导入 GLB 模型或 SPZ 世界", symbol: kind.symbolName) }
    }
    private func emptyPreview(_ text: String, symbol: String) -> some View {
        VStack(spacing: 0) {
            CanvasToolEmptyPreview(title: text, subtitle: kind == .timeline ? "片段会显示在下方时间线中" : "拖动环绕 · 滚轮缩放", symbol: symbol)
            Button("导入素材") { session.chooseImport() }
                .padding(.bottom, 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private var playback: some View {
        if kind == .audio || kind == .timeline {
            HStack(spacing: 12) {
                Button { playing.toggle(); if playing { session.player.play() } else { session.player.pause() } } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                }.disabled(session.player.currentItem == nil)
                Slider(value: Binding(get: { time }, set: {
                    time = $0; session.previewTime = $0
                    session.player.seek(to: CMTime(seconds: $0, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }), in: 0...max(0.001,duration))
                Text(String(format: "%.1f / %.1f s", time, duration)).font(.system(size: 11, design: .monospaced)).frame(width: 110)
            }
        } else {
            HStack {
                Button("重置视角") { reset += 1 }
                if kind == .stage {
                    Button(playing ? "暂停" : "播放") { playing.toggle() }
                    Slider(value: Binding(get: { session.previewTime }, set: { session.previewTime = $0 }),
                        in: 0...max(0.001,session.configuration.stage.duration))
                    Text(String(format: "%.1f s", session.previewTime)).font(.caption.monospacedDigit())
                }
                if kind == .threeD,let scene=session.scene,CanvasGLBScene.animationCount(scene.rootNode)>0 {
                    Button(playing ? "暂停动画" : "播放动画") { playing.toggle() }
                    Slider(value:$session.previewTime,in:0...max(0.001,CanvasGLBScene.animationDuration(scene.rootNode)))
                }
                Spacer()
            }
        }
    }
    private var exportMenu: some View {
        Menu {
            if kind == .audio {
                if draft.audio.scene == .speech {
                    Button("导出本机配音 WAV") { applyAndExport("wav") }
                    Button("配音生成到节点") { applyAndExport("wav", attach: true) }
                }
                if let id = draft.resourceAttachmentID, let url = session.urls[id] {
                    let name = session.attachments.first { $0.id.uuidString == id }?.name ?? "音频.wav"
                    Button("导出原始音频") {
                        if session.save(draft, detail: "编辑音频") {
                            session.chooseExport((name as NSString).pathExtension, original: true)
                        }
                    }
                    Button("显示原始音频") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            } else if kind == .timeline {
                let type = draft.timeline.clips.contains { !$0.isAudio } ? "mp4" : "m4a"
                Button("合并导出 \(type.uppercased())") { applyAndExport(type) }
                Button("合并回画布") { applyAndExport(type, attach: true) }
            } else if kind == .threeD {
                Button("摄影 PNG") { applyAndExport("png") }
                Button("摄影回画布") { applyAndExport("png", attach:true) }
            } else {
                Button("摄影 PNG") { applyAndExport("png") }
                Button("摄影回画布") { applyAndExport("png", attach: true) }
                Button("渲染镜头 MP4") { applyAndExport("mp4") }
                Button("镜头回画布") { applyAndExport("mp4", attach: true) }
            }
        } label: { CanvasToolMenuLabel(title: "导出", symbol: "square.and.arrow.up") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(session.busy).accessibilityIdentifier("tool-export")
    }
    private func applyAndExport(_ type: String, attach: Bool = false) {
        if session.save(draft, detail: "编辑\(kind.displayName)") { session.chooseExport(type, attach: attach) }
    }
    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if draft.audio.scene == .speech {
                CanvasToolSection(title: "本机配音", symbol: "text.bubble") {
                    CanvasToolChoice(title: "声音", selection: $draft.audio.voiceID,
                        choices: [("", "系统中文声音")] + AVSpeechSynthesisVoice.speechVoices()
                            .sorted { $0.language + $0.name < $1.language + $1.name }.map { ($0.identifier, "\($0.name) · \($0.language)") })
                    number("语速", value: $draft.audio.rate, range: 0.1...0.6)
                    number("音高", value: $draft.audio.pitch, range: 0.5...2)
                    number("音量", value: $draft.audio.volume, range: 0...1)
                }
            }
            CanvasToolSection(title: "音频素材", symbol: "waveform") {
                CanvasToolChoice(title: "音频素材", selection: $draft.resourceAttachmentID,
                    choices: [(String?.none, "未选择素材")] + session.attachments.map { (Optional($0.id.uuidString), $0.name) })
                Button("导入\(draft.audio.scene.title)") { session.chooseImport() }
                Toggle("循环播放", isOn: $draft.audio.loop)
            }
        }
    }
    private var resourceControls: some View {
        CanvasToolSection(title: session.cloud == nil ? "3D 对象" : "高斯世界", symbol: "cube") {
            CanvasToolChoice(title: "资源", selection: $draft.resourceAttachmentID,
                choices: [(String?.none, "选择资源")] + session.attachments.map { (Optional($0.id.uuidString), $0.name) })
            if let cloud = session.cloud {
                Text("\(cloud.splats.count.formatted()) 个高斯点 · SH \(cloud.degree)")
                    .font(.caption).foregroundColor(CanvasSkin.secondaryInk)
            }
            Button("导入 3D 素材") { session.chooseImport() }
            Button("重置视角") { reset += 1 }
            if let id = draft.resourceAttachmentID, let url = session.urls[id] {
                Button("显示原始模型") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
    private var timeline: some View {
        GeometryReader { geometry in
            let total = max(1,draft.timeline.duration), scale = max(1,geometry.size.width - 60) / total
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("视频").frame(width: 45); track(audio: false, scale: scale) }
                HStack { Text("音频").frame(width: 45); track(audio: true, scale: scale) }
            }.font(.caption).padding(.top, 12)
        }.background(CanvasSkin.chromeFill).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func track(audio: Bool, scale: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(CanvasSkin.subtleFill).frame(height: 54)
            ForEach(draft.timeline.clips.filter { $0.isAudio == audio }) { clip in
                Button { selectedClip = clip.id } label: {
                    Text(clip.name).font(.system(size: 10)).lineLimit(2).padding(6)
                        .frame(width: max(24,clip.duration * scale), height: 52, alignment: .leading)
                        .background(CanvasSkin.nodeAccent(audio ? .audio : .video).opacity(selectedClip == clip.id ? 0.5 : 0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selectedClip == clip.id ? CanvasSkin.ink : .clear))
                }.buttonStyle(.plain).offset(x: clip.timelineStart * scale)
            }
            Rectangle().fill(CanvasSkin.ink).frame(width: 1,height: 56).offset(x: time * scale)
        }.frame(height: 56).clipped()
    }
    @ViewBuilder private var clipControls: some View {
        CanvasToolSection(title: "片段", symbol: "film.stack") {
        if draft.timeline.clips.isEmpty {
            Text("导入素材后，在时间线选择片段进行裁剪。")
                .foregroundColor(CanvasSkin.secondaryInk).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(draft.timeline.clips) { clip in
            Button { selectedClip = clip.id } label: {
                HStack { Image(systemName: clip.isAudio ? "waveform" : "film"); Text(clip.name).lineLimit(1); Spacer() }
                    .padding(8).background(selectedClip == clip.id ? CanvasSkin.subtleFill : .clear).cornerRadius(6)
            }.buttonStyle(.plain)
        }
        if let id = selectedClip, let index = draft.timeline.clips.firstIndex(where: { $0.id == id }) {
            number("源起点 / 秒", value: $draft.timeline.clips[index].sourceStart, range: 0...86400)
            number("源终点 / 秒", value: $draft.timeline.clips[index].sourceEnd, range: 0...86400)
            if draft.timeline.clips[index].isAudio {
                number("时间线起点", value: $draft.timeline.clips[index].timelineStart, range: 0...86400)
            }
            number("音量", value: $draft.timeline.clips[index].volume, range: 0...2)
            HStack {
                Button("前移") { moveClip(index, delta: -1) }.disabled(index == 0)
                Button("后移") { moveClip(index, delta: 1) }.disabled(index == draft.timeline.clips.count - 1)
            }
            Button("在播放头分割") {
                if !draft.timeline.split(id: id, at: time) { session.message = "请将播放头放在片段内部" }
            }
            Button("移除片段") { draft.timeline.clips.remove(at: index); draft.timeline.reflowVideo(); selectedClip = nil }
            if let url = session.urls[draft.timeline.clips[index].attachmentID] {
                Button("显示原始片段") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        Button("添加视频 / 音频") { session.chooseImport() }
        }
        outputControls(width: $draft.timeline.width, height: $draft.timeline.height, fps: $draft.timeline.fps)
    }
    private func moveClip(_ index: Int, delta: Int) {
        let next = index + delta
        guard draft.timeline.clips.indices.contains(next) else { return }
        draft.timeline.clips.swapAt(index,next); draft.timeline.reflowVideo()
    }
    private var shots: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.stage.shots) { shot in
                    Button {
                        selectedShot = shot.id
                        selectedEntity = nil
                        session.previewTime=draft.stage.shots.prefix(while:{$0.id != shot.id}).reduce(0) {$0+$1.duration}
                    } label: {
                        VStack(alignment: .leading) { Text(shot.name); Text(String(format: "%.1f 秒 · %.0f mm",shot.duration,shot.focalLength)).font(.caption) }
                            .padding(12).background(selectedShot == shot.id ? CanvasSkin.nodeAccent(.stage).opacity(0.25) : CanvasSkin.subtleFill).cornerRadius(8)
                    }.buttonStyle(.plain).accessibilityIdentifier("tool-shot-\(shot.id)")
                }
                Button { var shot = CanvasStageShot(); shot.name = "镜头 \(draft.stage.shots.count + 1)"; draft.stage.shots.append(shot); selectedShot = shot.id; selectedEntity = nil } label: {
                    Label("添加镜头",systemImage:"plus")
                }
            }.padding(8)
        }
    }
    @ViewBuilder private var stageControls: some View {
        stageObjects
        stageSelection
        stageEnvironment
        stageAnimation
        outputControls(width: $draft.stage.width, height: $draft.stage.height, fps: $draft.stage.fps)
    }
    private var stageObjects: some View {
        CanvasToolSection(title: "场景对象", symbol: "cube.transparent") {
        if draft.stage.entities.isEmpty {
            Text("添加模型、几何体或灯光，开始布置场景。")
                .foregroundColor(CanvasSkin.secondaryInk).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(draft.stage.entities) { entity in
            Button { selectedEntity = entity.id; selectedShot = nil } label: {
                HStack { Image(systemName: entity.shape == .light ? "lightbulb" : "cube"); Text(entity.name).lineLimit(1); Spacer() }
                    .padding(8).background(selectedEntity == entity.id ? CanvasSkin.subtleFill : .clear).cornerRadius(6)
            }.buttonStyle(.plain).accessibilityIdentifier("tool-entity-\(entity.id)")
        }
        Menu {
            Button("导入模型") { session.chooseImport() }
            ForEach(session.canvasResources) { node in
                Button("引用画布 · \(node.displayName) #\(node.slot)") {
                    if session.save(draft,detail:"保存片场") {session.referenceResource(node)}
                }
            }
            Button("立方体") { addEntity(.box, name: "立方体") }
            Button("球体") { addEntity(.sphere, name: "球体") }
            Button("地面") {
                var entity = CanvasStageEntity(name: "地面", shape: .plane); entity.rotation.x = -90; entity.position.y = -0.5
                draft.stage.entities.append(entity); selectedEntity = entity.id
            }
            Button("灯光") { addEntity(.light, name: "灯光") }
        } label: { CanvasToolMenuLabel(title: "添加对象", symbol: "plus") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
    @ViewBuilder private var stageSelection: some View {
        if let id = selectedEntity, let index = draft.stage.entities.firstIndex(where: { $0.id == id }) {
            CanvasToolSection(title: "对象参数", symbol: "slider.horizontal.3") {
            TextField("名称", text: $draft.stage.entities[index].name)
            Toggle("显示", isOn: $draft.stage.entities[index].visible)
            vectorControls("位置", value: $draft.stage.entities[index].position)
            vectorControls("旋转 / 度", value: $draft.stage.entities[index].rotation)
            vectorControls("缩放", value: $draft.stage.entities[index].scale)
            TextField("颜色 #RRGGBB", text: $draft.stage.entities[index].color)
            Button("移除对象") {
                draft.stage.entities.remove(at:index)
                draft.stage.animation.tracks.removeAll {$0.ownerID==id}
                draft.stage.animation.roles.removeAll {$0.entityID==id}
                selectedEntity=nil
            }
            Menu {
                Button("位置") { draft.stage.recordKeyframe(ownerID:id,property:.position,time:session.previewTime,value:draft.stage.entities[index].position) }
                Button("旋转") { draft.stage.recordKeyframe(ownerID:id,property:.rotation,time:session.previewTime,value:draft.stage.entities[index].rotation) }
                Button("缩放") { draft.stage.recordKeyframe(ownerID:id,property:.scale,time:session.previewTime,value:draft.stage.entities[index].scale) }
            } label: { CanvasToolMenuLabel(title: "记录关键帧", symbol: "diamond") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            if draft.stage.entities[index].shape == .resource {
                if let roleIndex=draft.stage.animation.roles.firstIndex(where:{$0.entityID==id}) {
                    TextField("角色名称",text:Binding(get:{draft.stage.animation.roles[roleIndex].name},set:{draft.stage.animation.roles[roleIndex].name=$0}))
                    TextField("动画编号（从 0 开始）",value:Binding(get:{draft.stage.animation.roles[roleIndex].animationIndex},set:{draft.stage.animation.roles[roleIndex].animationIndex=$0}),format:.number)
                    number("动画速度",value:Binding(get:{draft.stage.animation.roles[roleIndex].animationSpeed},set:{draft.stage.animation.roles[roleIndex].animationSpeed=$0}),range:0...10)
                    Button("解除角色绑定") { draft.stage.animation.roles.remove(at:roleIndex) }
                } else {
                    Button("绑定为角色") { draft.stage.animation.roles.append(.init(name:draft.stage.entities[index].name,entityID:id)) }
                }
            }
            }
        }
        if let id = selectedShot, let index = draft.stage.shots.firstIndex(where: { $0.id == id }) {
            CanvasToolSection(title: "镜头参数", symbol: "camera") {
            TextField("名称", text: $draft.stage.shots[index].name)
            number("时长 / 秒", value: $draft.stage.shots[index].duration, range: 0.1...600)
            number("焦距 / mm", value: $draft.stage.shots[index].focalLength, range: 8...300)
            vectorControls("相机位置", value: $draft.stage.shots[index].camera)
            vectorControls("观察目标", value: $draft.stage.shots[index].target)
            Menu {
                Button("相机位置") { draft.stage.recordKeyframe(ownerID:id,property:.camera,time:session.previewTime,value:draft.stage.shots[index].camera) }
                Button("观察目标") { draft.stage.recordKeyframe(ownerID:id,property:.target,time:session.previewTime,value:draft.stage.shots[index].target) }
                Button("焦距") { draft.stage.recordKeyframe(ownerID:id,property:.focalLength,time:session.previewTime,value:CanvasVector3(draft.stage.shots[index].focalLength)) }
            } label: { CanvasToolMenuLabel(title: "记录镜头关键帧", symbol: "diamond") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            HStack {
                Button("前移镜头") { draft.stage.shots.swapAt(index,index-1) }.disabled(index==0)
                Button("后移镜头") { draft.stage.shots.swapAt(index,index+1) }.disabled(index==draft.stage.shots.count-1)
            }
            Button("移除镜头") {
                draft.stage.shots.remove(at:index);draft.stage.animation.tracks.removeAll {$0.ownerID==id};selectedShot=nil
            }.disabled(draft.stage.shots.count <= 1)
            }
        }
    }
    private var stageEnvironment: some View {
        CanvasToolSection(title: "环境与布景", symbol: "sun.max") {
        TextField("背景 #RRGGBB", text: $draft.stage.background)
        Button("导入 HDRI / 环境图片") {
            if session.save(draft,detail:"保存片场") { session.chooseEnvironment() }
        }
        number("环境旋转 / 度",value:Binding(get:{draft.stage.animation.environment.rotation},set:{draft.stage.animation.environment.rotation=$0}),range:-360...360)
        number("环境强度",value:Binding(get:{draft.stage.animation.environment.intensity},set:{draft.stage.animation.environment.intensity=$0}),range:0...10)
        number("曝光",value:Binding(get:{draft.stage.animation.environment.exposure},set:{draft.stage.animation.environment.exposure=$0}),range:-10...10)
        Toggle("镜头之间直接切换",isOn:Binding(get:{draft.stage.animation.cutShots},set:{draft.stage.animation.cutShots=$0}))
        Button("保存当前布景") { draft.stage.captureSetup(name:"布景 \(draft.stage.animation.setups.count+1)") }
        ForEach(draft.stage.animation.setups) { setup in
            HStack {
                Button("恢复 \(setup.name)") { _=draft.stage.restoreSetup(id:setup.id,expectedRevision:draft.stage.animation.revision) }
                Button { draft.stage.animation.setups.removeAll {$0.id==setup.id} } label:{ Image(systemName:"trash") }
            }
        }
        }
    }
    @ViewBuilder private var stageAnimation: some View {
        if !draft.stage.animation.tracks.isEmpty {
        CanvasToolSection(title: "关键帧", symbol: "diamond") {
        ForEach(draft.stage.animation.tracks) { track in
            DisclosureGroup("\(track.property.rawValue) · \(track.frames.count) 帧") {
                ForEach(track.frames.sorted {$0.time<$1.time}) { frame in
                    HStack {
                        Text(String(format:"%.2f s",frame.time))
                        CanvasToolChoice(title:"插值",selection:Binding(get:{frame.interpolation},set:{mode in
                            if let ti=draft.stage.animation.tracks.firstIndex(where:{$0.id==track.id}),
                               let fi=draft.stage.animation.tracks[ti].frames.firstIndex(where:{$0.id==frame.id}) {
                                draft.stage.animation.tracks[ti].frames[fi].interpolation=mode
                            }
                        }), choices: CanvasStageKeyframe.Interpolation.allCases.map { ($0, $0.rawValue) })
                        Button { if let ti=draft.stage.animation.tracks.firstIndex(where:{$0.id==track.id}) {
                            draft.stage.animation.tracks[ti].frames.removeAll {$0.id==frame.id}
                        } } label:{Image(systemName:"trash")}
                    }
                }
            }
        }
        }
        }
    }
    private func addEntity(_ shape: CanvasStageEntity.Shape, name: String) {
        let entity = CanvasStageEntity(name: name, shape: shape)
        draft.stage.entities.append(entity); selectedEntity = entity.id; selectedShot = nil
    }
    private func vectorControls(_ title: String, value: Binding<CanvasVector3>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(CanvasSkin.secondaryInk)
            HStack(spacing: 6) {
                axis("X", value: value.x)
                axis("Y", value: value.y)
                axis("Z", value: value.z)
            }
        }
    }
    private func axis(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9)).foregroundColor(CanvasSkin.faintInk)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
        }
    }
    private func number(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack { Text(title).font(.system(size: 11)); Spacer(); TextField(title, value: value, format: .number.precision(.fractionLength(0...3))).frame(width: 78) }
    }
    private func outputControls(width: Binding<Int>, height: Binding<Int>, fps: Binding<Int>) -> some View {
        CanvasToolSection(title: "输出", symbol: "square.and.arrow.up") {
            HStack { TextField("宽", value: width, format: .number); Text("×"); TextField("高", value: height, format: .number) }
            CanvasToolChoice(title: "帧率", selection: fps, choices: [24,25,30,60].map { ($0, "\($0) fps") })
        }
    }
}
