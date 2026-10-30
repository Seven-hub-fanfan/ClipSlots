#if DEBUG
import SwiftUI
import AVFoundation
import SceneKit
import MetalKit
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor func runTapNowToolProbe(directory: URL) async {
        var passed = 0, failures = [String]()
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failures.append(name) }
            NSLog("[TapNowTools] \(value ? "PASS" : "FAIL") \(name)")
        }
        func rejects(_ name: String, body: () throws -> Void) {
            do { try body(); check(false,name) } catch { check(true,name) }
        }
        guard let fixturePath = ProcessInfo.processInfo.environment["CLIPSLOTS_TOOL_FIXTURES"] else { return }
        let fixtures = URL(fileURLWithPath:fixturePath)
        func file(_ name: String) -> URL { fixtures.appendingPathComponent(name) }
        var sessions = [CanvasNodeKind: CanvasToolSession]()
        do {
            for (index,kind) in [CanvasNodeKind.audio,.threeD,.timeline,.stage].enumerated() {
                guard let node = createNode(kind:kind,at:CGPoint(x:300+index*600,y:400),parentNodeId:nil,beginEditing:false) else {
                    check(false,"create \(kind.rawValue)");continue
                }
                check(node.kind.cardForm == .tool && !node.canGenerate,"tool route \(kind.rawValue)")
                let encoded = try JSONEncoder().encode(node), decoded = try JSONDecoder().decode(CanvasNode.self,from:encoded)
                check(decoded == node,"node persistence \(kind.rawValue)")
                sessions[kind] = CanvasToolSession(canvas:canvas,store:store,node:node,attachments:[])
            }
            check(CanvasNodeSizing.initialSize(for:.timeline) == CGSize(width:960,height:104),"TapNow timeline 960x104")
            check(CanvasNodeSizing.initialSize(for:.audio) == CGSize(width:480,height:270),"audio 16:9")
            check(CanvasNodeSizing.initialSize(for:.threeD) == CGSize(width:480,height:320),"3D 3:2")
            if let audio = sessions[.audio] {
                try await audio.ingest(file("tone.wav"))
                check(audio.waveform.count == 160 && (audio.waveform.max() ?? 0)>0.9,"real audio waveform")
                check(audio.player.currentItem != nil,"audio native player")
                for _ in 0..<30 {
                    if audio.player.currentItem?.status == .readyToPlay {break}
                    try await Task.sleep(nanoseconds:100_000_000)
                }
                check(audio.player.currentItem?.status == .readyToPlay,"audio ready to play")
                audio.player.play(); try await Task.sleep(nanoseconds:600_000_000)
                check(audio.player.currentTime().seconds>0,"audio playback time advances");audio.player.pause()
                await audio.player.seek(to:CMTime(seconds:1,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
                try await Task.sleep(nanoseconds:150_000_000)
                check(abs(audio.player.currentTime().seconds-1)<0.1,"audio seek")
                var config=audio.configuration;config.audio.scene = .speech
                config.audio.text = "ClipSlots 原生配音测试。";audio.save(config,detail:"配音配置")
                check(canvas.undo() != nil && audio.configuration.audio.text.isEmpty,"audio configuration undo")
                check(canvas.redo() != nil && audio.configuration.audio.text == config.audio.text,"audio configuration redo")
                let exporter=CanvasSpeechExporter(),output=directory.appendingPathComponent("speech.wav")
                _ = try await exporter.export(config.audio,to:output)
                let facts=try await CanvasToolMedia.inspect(output)
                check(facts.duration>0 && !facts.video,"local speech actual WAV decode")
                let original=directory.appendingPathComponent("original.wav")
                try await audio.renderExport("wav",to:original,original:true)
                check(try Data(contentsOf:original) == Data(contentsOf:file("tone.wav")),"original audio exact export bytes")
                var invalid=audio.configuration;invalid.audio.pitch = .nan
                check(!audio.save(invalid,detail:"invalid") && audio.configuration==config,"invalid audio cannot overwrite configuration")
            }
            if let model=sessions[.threeD] {
                try await model.ingest(file("triangle.glb"))
                check(model.scene?.rootNode.childNodes.isEmpty == false,"GLB actual geometry loaded")
                let before=model.configuration
                try await model.ingest(file("gaussians-v3.spz"))
                check(model.cloud?.splats.count == 121 && model.scene == nil,"SPZ Gaussian world loaded")
                _ = canvas.undo()
                model.attachments=store.canvasSlotAttachments(groupId:model.node!.groupId,slot:model.node!.slot)
                check(model.configuration==before && model.attachments.count==1,"3D import undo bytes and graph")
                _ = canvas.redo()
                model.attachments=store.canvasSlotAttachments(groupId:model.node!.groupId,slot:model.node!.slot)
                try await model.refreshPreview()
                check(model.attachments.count==2 && model.cloud?.splats.count==121,"3D import redo bytes and graph")
            }
            for version in 1...3 {
                let cloud=try CanvasSPZ.load(file("gaussians-v\(version).spz"))
                check(cloud.splats.count==121 && cloud.splats[0].center.x < -0.74,"SPZ version \(version) positions")
                let renderer = try CanvasGaussianRenderer(cloud:cloud)
                check(true,"Metal Gaussian shader compilation v\(version)")
                let image=try renderer.photograph(size:CGSize(width:320,height:240))
                if let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let data=bitmap.representation(using:.png,properties:[:]) {
                    try data.write(to:directory.appendingPathComponent("spz-v\(version).png"))
                    let pixel=bitmap.colorAt(x:160,y:120)
                    check((pixel?.blueComponent ?? 0)>0.2,"anisotropic Gaussian pixels v\(version)")
                } else {check(false,"Gaussian photograph pixels")}
            }
            rejects("reject truncated GLB") { _=try CanvasGLBScene.load(file("invalid.glb"),name:"invalid.glb") }
            rejects("reject corrupt SPZ") { _=try CanvasSPZ.load(file("invalid.spz")) }
            if let stage=sessions[.stage] {
                var config=stage.configuration
                config.stage.width=320;config.stage.height=180;config.stage.fps=24;config.stage.shots[0].duration=0.5
                config.stage.entities=[CanvasStageEntity(name:"球体",shape:.sphere)]
                stage.save(config,detail:"布置片场");try await stage.refreshPreview()
                check(stage.scene?.rootNode.childNode(withName:config.stage.entities[0].id,recursively:false) != nil,"stage object scene")
                let png=directory.appendingPathComponent("stage.png"),video=directory.appendingPathComponent("stage.mp4")
                try await CanvasToolMedia.worker { try CanvasStageRenderer.photograph(config.stage,urls:[:],time:0,to:png) }
                check(NSImage(contentsOf:png)?.size == CGSize(width:320,height:180),"stage photograph PNG pixels")
                try await CanvasStageRenderer.exportVideo(config.stage,urls:[:],to:video)
                let facts=try await CanvasToolMedia.inspect(video)
                check(facts.video && abs(facts.duration-0.5)<0.05 && facts.size == CGSize(width:320,height:180),"stage actual video export")
                func decodedFrame(_ url: URL, name: String) async throws {
                    let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.appliesPreferredTrackTransform=true
                    let frame=try await generator.image(at:CMTime(seconds:0.1,preferredTimescale:600)).image
                    let bitmap=NSBitmapImageRep(cgImage:frame)
                    let middle=bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)?.usingColorSpace(.deviceRGB)
                    let corner=bitmap.colorAt(x:5,y:5)?.usingColorSpace(.deviceRGB)
                    check(abs((middle?.blueComponent ?? 0)-(corner?.blueComponent ?? 0))>0.1,"\(name) decoded visible object pixels")
                    try bitmap.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("\(name)-decoded.png"))
                }
                try await decodedFrame(video,name:"stage-video")
                var invalid=config;invalid.stage.entities[0].scale.x=0
                check(!stage.save(invalid,detail:"invalid") && stage.configuration==config,"zero scale rejected before persistence")
                invalid=config;invalid.stage.shots[0].target=invalid.stage.shots[0].camera
                check(!stage.save(invalid,detail:"invalid"),"degenerate camera rejected before persistence")
                invalid=config;invalid.stage.width=321
                check(!stage.save(invalid,detail:"invalid"),"odd encoding dimensions rejected")
                var motion=config.stage
                var second=motion.shots[0];second.id=UUID().uuidString;second.camera.x=4;second.focalLength=70
                motion.shots.append(second)
                let camera=SCNNode();camera.camera=SCNCamera()
                try CanvasStageRenderer.applyCamera(motion,time:0.25,node:camera)
                check(abs(camera.position.x-2)<0.001 && abs((camera.camera?.focalLength ?? 0)-52.5)<0.001,"camera shot position and focal interpolation")
                try await stage.ingest(file("triangle.glb"))
                let imported=stage.configuration.stage.entities.last!
                check(stage.scene?.rootNode.childNode(withName:imported.id,recursively:false)?.childNodes.isEmpty == false,"persisted .bin GLB stage resource decoded")
                _=canvas.undo();stage.attachments=store.canvasSlotAttachments(groupId:stage.node!.groupId,slot:stage.node!.slot)
                check(stage.configuration==config && stage.attachments.isEmpty,"stage resource import undo")
                if let output=try await stage.receiveExport(png,type:"png",expected:config) {
                    check(output.kind == .image && output.isMediaSource && canvas.edges.contains{$0.fromNodeId==stage.nodeID && $0.toNodeId==output.id},"stage photography real downstream image and edge")
                    _=canvas.undo()
                    check(canvas.node(id:output.id)==nil && store.canvasSlotAttachments(groupId:output.groupId,slot:output.slot).isEmpty,"stage export undo node edge and bytes")
                    _=canvas.redo()
                    check(canvas.node(id:output.id) != nil && store.canvasSlotAttachments(groupId:output.groupId,slot:output.slot).count==1,"stage export redo node edge and bytes")
                } else {check(false,"stage downstream output")}
                let cancelURL=directory.appendingPathComponent("cancelled.mp4")
                let task=Task { try await CanvasStageRenderer.exportVideo(config.stage,urls:[:],to:cancelURL) }
                task.cancel()
                do {try await task.value;check(false,"cancelled stage encoder")} catch {check(!FileManager.default.fileExists(atPath:cancelURL.path),"cancelled stage encoder leaves no file")}
                if let timeline=sessions[.timeline] {
                    try await timeline.ingest(video);try await timeline.ingest(video);try await timeline.ingest(file("tone.wav"))
                    check(timeline.configuration.timeline.clips.count==3,"timeline video/audio imports")
                    var config=timeline.configuration
                    config.timeline.width=320;config.timeline.height=180;config.timeline.fps=24
                    let first=config.timeline.clips[0].id
                    check(config.timeline.split(id:first,at:0.25),"timeline source/time split")
                    check(abs(config.timeline.clips[1].sourceStart-0.25)<0.001,"split source trim continuity")
                    config.timeline.clips[0].sourceEnd=0.2;config.timeline.reflowVideo()
                    timeline.save(config,detail:"裁剪时间线")
                    let composition=try await CanvasToolMedia.composition(config.timeline,urls:timeline.urls)
                    let output=directory.appendingPathComponent("timeline.mp4")
                    try await CanvasToolMedia.export(composition,to:output)
                    let result=try await CanvasToolMedia.inspect(output)
                    check(result.video && abs(result.duration-2)<0.1,"timeline merge mixed audio/video actual output")
                    check(result.size == CGSize(width:320,height:180),"timeline preserves 16:9 output")
                    try await decodedFrame(output,name:"timeline-video")
                    check(canvas.undo() != nil && timeline.configuration.timeline.clips.count==3,"timeline trim undo")
                    check(canvas.redo() != nil && timeline.configuration.timeline.clips.count==4,"timeline trim redo")
                    var invalid=config.timeline;invalid.clips[0].sourceEnd=500
                    var bad=timeline.configuration;bad.timeline=invalid
                    check(!timeline.save(bad,detail:"invalid") && timeline.configuration==config,"source bounds rejected before timeline save")
                    do { _=try await CanvasToolMedia.composition(invalid,urls:timeline.urls);check(false,"reject out-of-source trim") }
                    catch { check(true,"reject out-of-source trim") }
                    if let media=try await timeline.receiveExport(output,type:"mp4",expected:config) {
                        check(media.kind == .video && media.isMediaSource,"timeline merges to real downstream video")
                        check(canvas.edges.contains{$0.fromNodeId==timeline.nodeID && $0.toNodeId==media.id},"timeline output graph edge")
                        let bytes=try Data(contentsOf:URL(fileURLWithPath:store.canvasSlotAttachments(groupId:media.groupId,slot:media.slot)[0].storagePath!))
                        check(try bytes == Data(contentsOf:output),"timeline downstream exact MP4 bytes")
                        _=canvas.undo()
                        check(canvas.node(id:media.id)==nil && !canvas.edges.contains{$0.toNodeId==media.id} && store.canvasSlotAttachments(groupId:media.groupId,slot:media.slot).isEmpty,"timeline merge undo all bytes node edge")
                        _=canvas.redo()
                        check(canvas.node(id:media.id) != nil && store.canvasSlotAttachments(groupId:media.groupId,slot:media.slot).count==1,"timeline merge redo all bytes node edge")
                    } else {check(false,"timeline downstream output")}
                    do {try await timeline.receiveExport(output,type:"mp4",expected:bad);check(false,"stale export guard")}
                    catch {check(true,"stale export guard")}
                    let count=canvas.nodes.count
                    let cancelled=Task {try await timeline.receiveExport(output,type:"mp4",expected:config)}
                    cancelled.cancel()
                    do {try await cancelled.value;check(false,"cancelled output transaction")}
                    catch {check(canvas.nodes.count==count,"cancelled output transaction no partial node")}
                }
            }
            await CanvasCloudRegression.run(fixtures:fixtures,directory:directory,check:check)
            if let model=sessions[.threeD] { await CanvasCloudRegression.session(model,fixtures:fixtures,check:check) }
            // Render the real production editor and card tree in all four themes.
            for skin in AppSkin.allCases {
                AppSkinCenter.apply(skin)
                for dark in [false,true] {
                    for kind in [CanvasNodeKind.audio,.threeD,.timeline,.stage] {
                        guard let session=sessions[kind] else {continue}
                        let host=NSHostingView(rootView:CanvasToolEditor(session:session,canvas:canvas))
                        let editor=NSWindow(contentRect:NSRect(x:0,y:0,width:1080,height:740),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
                        editor.appearance=NSAppearance(named:dark ? .darkAqua : .aqua);editor.contentView=host;editor.makeKeyAndOrderFront(nil)
                        editor.displayIfNeeded();host.layoutSubtreeIfNeeded()
                        try await Task.sleep(nanoseconds:250_000_000)
                        let suffix="\(skin.rawValue)-\(dark ? "dark":"light")"
                        if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                            host.cacheDisplay(in:host.bounds,to:bitmap)
                            if let data=bitmap.representation(using:.png,properties:[:]) {
                                try data.write(to:directory.appendingPathComponent("\(kind.rawValue)-\(suffix).png"))
                                check(bitmap.pixelsWide>0 && bitmap.pixelsHigh>0,"mounted \(kind.rawValue) \(suffix)")
                            } else {check(false,"capture editor")}
                        } else {check(false,"capture mounted editor")}
                        editor.orderOut(nil)
                    }
                }
            }
            try await CanvasToolUIRegression.run(sessions:sessions,canvas:canvas,directory:directory,check:check)
            check(canvas.flushSave(),"tool document durable save")
            let stored=CanvasStorage().load(projectId:canvas.activeProjectId)
            check(stored.nodes.filter{$0.kind.cardForm == .tool}.count==4 && stored.nodes.count==6,"four tools and two outputs reload from storage")
            if ProcessInfo.processInfo.environment["CLIPSLOTS_TOOL_KEEP_OPEN"] == "1",let node=sessions[.stage]?.node {
                openTool(node)
            }
        } catch {check(false,"tools exception: \(error.localizedDescription)")}
        let report:[String:Any]=["complete":true,"passed":passed,"failures":failures,
            "scope":"native tool editors; waveform/play/seek/speech; GLB/SPZ; stage still/video; timeline trim/split/mix/export; durable graph and undo"]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:directory.appendingPathComponent("report.json"))
        }
        if ProcessInfo.processInfo.environment["CLIPSLOTS_TOOL_KEEP_OPEN"] != "1" {NSApp.terminate(nil)}
    }
}
#endif
