import Foundation
import AppKit
import SceneKit
import AVFoundation
import Metal

public enum CanvasStageRenderer {
    public static func color(_ hex: String) -> NSColor {
        let string = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return .darkGray }
        return NSColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    public static func scene(_ config: CanvasStageConfiguration, urls: [String: (url: URL, name: String)]) throws -> SCNScene {
        try Task.checkCancellation()
        var validation = CanvasToolConfiguration(); validation.stage = config
        if let error = validation.validationError(for: .stage) { throw CanvasToolError.invalid(error) }
        guard config.entities.count <= 200, config.shots.count <= 100,
              (16...4096).contains(config.width), (16...4096).contains(config.height),
              (1...60).contains(config.fps), config.duration.isFinite, config.duration <= 600
        else { throw CanvasToolError.invalid("片场参数无效（最多 200 个对象、10 分钟）") }
        let scene = SCNScene(); scene.background.contents = color(config.background)
        let environment=config.animation.environment
        let exposure=pow(2,environment.exposure)
        if let id=environment.attachmentID {
            guard let resource=urls[id] else { throw CanvasToolError.missingMedia }
            let lease=try CanvasMediaFileLease(source:resource.url,name:resource.name)
            guard let image=NSImage(contentsOf:lease.url) else { throw CanvasToolError.invalid("环境图片无法解码") }
            scene.lightingEnvironment.contents=image
            scene.lightingEnvironment.intensity=CGFloat(environment.intensity * exposure)
            scene.lightingEnvironment.contentsTransform=SCNMatrix4MakeRotation(CGFloat(environment.rotation * .pi / 180),0,1,0)
        }
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = 500 * CGFloat(exposure); scene.rootNode.addChildNode(ambient)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .omni
        key.light?.intensity = 1200 * CGFloat(exposure); key.position = SCNVector3(3,5,4); scene.rootNode.addChildNode(key)
        for entity in config.entities where entity.visible {
            guard entity.position.isFinite, entity.rotation.isFinite, entity.scale.isFinite,
                  [entity.scale.x, entity.scale.y, entity.scale.z].allSatisfy({ abs($0) > 0.00001 && abs($0) <= 10000 })
            else { throw CanvasToolError.invalid("「\(entity.name)」变换参数无效") }
            let node: SCNNode
            switch entity.shape {
            case .resource:
                guard let id = entity.attachmentID, let resource = urls[id] else { throw CanvasToolError.missingMedia }
                node = SCNNode()
                if (resource.name as NSString).pathExtension.lowercased() != "spz" {
                let resourceScene = try CanvasGLBScene.load(resource.url, name: resource.name)
                // Keep the original decoded hierarchy so skeleton references
                // remain attached to the same joints as mesh instances.
                for child in resourceScene.rootNode.childNodes { node.addChildNode(child) }
                if let animation=resourceScene.rootNode.clipslotsGLBData["clipslots-glb-animation"] {
                    node.clipslotsGLBData["clipslots-glb-animation"]=animation
                }
                }
            case .box: node = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.025))
            case .sphere: node = SCNNode(geometry: SCNSphere(radius: 0.5))
            case .plane:
                node = SCNNode(geometry: SCNPlane(width: 10, height: 10))
            case .light:
                node = SCNNode(); node.light = SCNLight(); node.light?.type = .omni
                node.light?.intensity = 1000 * CGFloat(exposure); node.light?.color = color(entity.color)
            }
            node.name = entity.id
            node.position = vector(entity.position); node.eulerAngles = vector(entity.rotation, factor: .pi / 180)
            node.scale = vector(entity.scale)
            if entity.shape != .resource {
                let material = SCNMaterial(); material.lightingModel = .physicallyBased
                material.diffuse.contents = color(entity.color); material.roughness.contents = 0.6
                material.isDoubleSided = true; node.geometry?.materials = [material]
            }
            scene.rootNode.addChildNode(node)
        }
        let camera = SCNNode(); camera.name = "clipslots-camera"; camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01; camera.camera?.zFar = 100000; camera.camera?.wantsHDR = false
        camera.camera?.exposureOffset=CGFloat(environment.exposure)
        scene.rootNode.addChildNode(camera)
        try apply(config,time:0,scene:scene)
        return scene
    }
    public static func vector(_ vector: CanvasVector3, factor: Double = 1) -> SCNVector3 {
        SCNVector3(vector.x * factor, vector.y * factor, vector.z * factor)
    }
    public static func applyCamera(_ config: CanvasStageConfiguration, time: Double, node: SCNNode) throws {
        guard !config.shots.isEmpty, config.shots.allSatisfy({
            $0.duration.isFinite && $0.duration > 0 && $0.duration <= 600
                && $0.camera.isFinite && $0.target.isFinite && $0.camera != $0.target
                && $0.focalLength.isFinite && (8...300).contains($0.focalLength)
        }) else { throw CanvasToolError.invalid("镜头位置、时长或焦距无效") }
        var cursor: Double = 0, selected = config.shots.count - 1, progress: Double = 1
        for index in config.shots.indices {
            let shot = config.shots[index]
            if time < cursor + shot.duration {
                selected = index; progress = max(0, min(1, (time - cursor) / shot.duration)); break
            }
            cursor += shot.duration
        }
        let shot = config.shots[selected]
        let next = config.shots[min(selected + 1, config.shots.count - 1)]
        func lerp(_ a: CanvasVector3, _ b: CanvasVector3) -> CanvasVector3 {
            CanvasVector3(a.x + (b.x - a.x) * progress, a.y + (b.y - a.y) * progress, a.z + (b.z - a.z) * progress)
        }
        if config.animation.cutShots { progress=0 }
        func sampled(_ property:CanvasStageTrack.Property,_ fallback:CanvasVector3) -> CanvasVector3 {
            config.animation.tracks.first(where:{$0.ownerID==shot.id && $0.property==property})?.sample(at:time) ?? fallback
        }
        node.position = vector(sampled(.camera,lerp(shot.camera,next.camera)))
        let target = vector(sampled(.target,lerp(shot.target,next.target)))
        let position = node.position
        if position.x != target.x || position.y != target.y || position.z != target.z { node.look(at: target) }
        node.camera?.focalLength = CGFloat(sampled(.focalLength,CanvasVector3(shot.focalLength + (next.focalLength - shot.focalLength) * progress)).x)
    }
    public static func apply(_ config:CanvasStageConfiguration,time:Double,scene:SCNScene) throws {
        guard time.isFinite else { throw CanvasToolError.invalid("播放时间无效") }
        if let camera=scene.rootNode.childNode(withName:"clipslots-camera",recursively:false) {
            try applyCamera(config,time:time,node:camera)
        }
        for entity in config.entities {
            guard let node=scene.rootNode.childNode(withName:entity.id,recursively:false) else { continue }
            node.position=vector(entity.position);node.eulerAngles=vector(entity.rotation,factor:.pi/180);node.scale=vector(entity.scale)
            for track in config.animation.tracks where track.ownerID==entity.id {
                guard let value=track.sample(at:time) else { continue }
                switch track.property {
                case .position:node.position=vector(value)
                case .rotation:node.eulerAngles=vector(value,factor:.pi/180)
                case .scale:node.scale=vector(value)
                default:break
                }
            }
            let role=config.animation.roles.first(where:{$0.entityID==entity.id})
            try CanvasGLBScene.sample(node:node,time:time * (role?.animationSpeed ?? 1) + (role?.animationOffset ?? 0),
                                      animationIndex:role?.animationIndex ?? 0)
        }
    }
    public static func photograph(_ config: CanvasStageConfiguration, urls: [String: (url: URL, name: String)],
                                  time: Double, to url: URL,metadata:[String:CanvasCloudResourceMetadata]=[:]) throws {
        let scene = try scene(config, urls: urls)
        guard let camera = scene.rootNode.childNode(withName: "clipslots-camera", recursively: false),
              let device = MTLCreateSystemDefaultDevice() else { throw CanvasToolError.invalid("3D 渲染不可用") }
        try apply(config,time:time,scene:scene)
        let renderer = SCNRenderer(device: device, options: nil); renderer.scene = scene; renderer.pointOfView = camera
        let composite=try composite(config,scene:scene,urls:urls,metadata:metadata)
        composite?.time=time
        let image = try composite?.photograph(size:CGSize(width:config.width,height:config.height))
            ?? renderer.snapshot(atTime: time, with: CGSize(width: config.width, height: config.height), antialiasingMode: .multisampling4X)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw CanvasToolError.invalid("摄影输出失败") }
        try png.write(to: url, options: .atomic)
    }
    public static func exportVideo(_ config: CanvasStageConfiguration, urls: [String: (url: URL, name: String)],
                                   to url: URL,metadata:[String:CanvasCloudResourceMetadata]=[:]) async throws {
        let scene = try scene(config, urls: urls)
        guard config.duration > 0, let camera = scene.rootNode.childNode(withName: "clipslots-camera", recursively: false),
              let device = MTLCreateSystemDefaultDevice() else { throw CanvasToolError.invalid("3D 渲染不可用") }
        let renderer = SCNRenderer(device: device, options: nil); renderer.scene = scene; renderer.pointOfView = camera
        let composite=try composite(config,scene:scene,urls:urls,metadata:metadata)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: config.width, AVVideoHeightKey: config.height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: config.width, kCVPixelBufferHeightKey as String: config.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw CanvasToolError.invalid("视频编码器不可用") }
        writer.add(input); input.expectsMediaDataInRealTime = false
        guard writer.startWriting() else { throw writer.error ?? CanvasToolError.invalid("无法启动编码") }
        writer.startSession(atSourceTime: .zero)
        do {
            for frame in 0..<Int(ceil(config.duration * Double(config.fps))) {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard writer.status == .writing else { throw writer.error ?? CanvasToolError.invalid("编码中断") }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                let time = Double(frame) / Double(config.fps)
                try autoreleasepool {
                    try apply(config,time:time,scene:scene)
                    composite?.time=time
                    let image = try composite?.photograph(size:CGSize(width:config.width,height:config.height))
                        ?? renderer.snapshot(atTime: time, with: CGSize(width: config.width, height: config.height),antialiasingMode: .multisampling4X)
                    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let pool = adaptor.pixelBufferPool else { throw CanvasToolError.invalid("帧渲染失败") }
                    var pixel: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else {
                        throw CanvasToolError.invalid("帧缓冲区分配失败")
                    }
                    CVPixelBufferLockBaseAddress(pixel, [])
                    defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
                    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: config.width,
                        height: config.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
                    else { throw CanvasToolError.invalid("帧画布创建失败") }
                    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: config.width, height: config.height))
                    guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(config.fps))) else {
                        throw writer.error ?? CanvasToolError.invalid("写入视频帧失败")
                    }
                }
            }
            input.markAsFinished()
            await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? CanvasToolError.invalid("视频导出失败") }
        } catch { writer.cancelWriting(); try? FileManager.default.removeItem(at: url); throw error }
    }
    public static func composite(_ config:CanvasStageConfiguration,scene:SCNScene,
                                 urls:[String:(url:URL,name:String)],metadata:[String:CanvasCloudResourceMetadata]=[:]) throws -> CanvasStageComposite? {
        let worlds=config.entities.filter {entity in
            entity.visible && entity.shape == .resource && entity.attachmentID.flatMap {urls[$0]?.name}.map {($0 as NSString).pathExtension.lowercased()=="spz"} == true
        }
        guard worlds.count<=1 else {throw CanvasToolError.invalid("一个片场暂支持一个 SPZ 世界，可同时布置多个 GLB 对象")}
        guard let entity=worlds.first,let id=entity.attachmentID,let resource=urls[id] else {return nil}
        let cloud=CanvasSPZ.transformed(try CanvasSPZ.load(resource.url),metadata:metadata[id])
        return try CanvasStageComposite(scene:scene,config:config,cloud:cloud,entityID:entity.id)
    }
}
