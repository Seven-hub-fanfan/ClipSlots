import Foundation
import SceneKit
import MetalKit

/// SceneKit meshes write their actual depth first. Splats share the same camera,
/// projection, color target and depth buffer, preserving mesh occlusion.
public final class CanvasStageComposite: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    public let scene: SCNScene
    public var config: CanvasStageConfiguration
    public var time: Double = 0
    private let queue: MTLCommandQueue
    private let renderer: SCNRenderer
    private let camera: SCNNode
    private let gaussian: CanvasGaussianRenderer
    private let entityID: String
    public init(scene:SCNScene,config:CanvasStageConfiguration,cloud:CanvasGaussianCloud,entityID:String) throws {
        let gaussian=try CanvasGaussianRenderer(cloud:cloud)
        guard let queue=gaussian.device.makeCommandQueue(),
              let camera=scene.rootNode.childNode(withName:"clipslots-camera",recursively:false) else {throw CanvasToolError.invalid("片场相机不可用")}
        self.device=gaussian.device;self.scene=scene;self.config=config;self.gaussian=gaussian
        self.camera=camera;self.queue=queue;self.entityID=entityID
        // HDR post-processing switches SceneKit to an internal depth target.
        // Shared SPZ depth rendering uses the direct SDR target instead.
        camera.camera?.wantsHDR=false
        renderer=SCNRenderer(device:gaussian.device,options:nil);renderer.scene=scene;renderer.pointOfView=camera
        super.init()
    }
    private func encode(command:MTLCommandBuffer,pass:MTLRenderPassDescriptor,size:CGSize) throws {
        try CanvasStageRenderer.apply(config,time:time,scene:scene)
        guard let cam=camera.camera,let entity=scene.rootNode.childNode(withName:entityID,recursively:false) else {throw CanvasToolError.missingMedia}
        let aspect=Float(size.width/max(1,size.height)),near=Float(cam.zNear),far=Float(cam.zFar)
        let f=Float(2 * cam.focalLength / cam.sensorHeight)
        // Explicit OpenGL camera projection for SceneKit; Metal splats use the
        // corresponding 0…1 depth projection.
        let gl=simd_float4x4(columns:(SIMD4(f/aspect,0,0,0),SIMD4(0,f,0,0),
            SIMD4(0,0,(far+near)/(near-far),-1),SIMD4(0,0,2*near*far/(near-far),0)))
        let metal=simd_float4x4(columns:(SIMD4(f/aspect,0,0,0),SIMD4(0,f,0,0),
            SIMD4(0,0,near/(far-near),-1),SIMD4(0,0,near*far/(far-near),0)))
        cam.projectionTransform=SCNMatrix4(gl)
        renderer.render(atTime:time,viewport:CGRect(origin:.zero,size:size),commandBuffer:command,passDescriptor:pass)
        pass.colorAttachments[0].loadAction = .load
        pass.depthAttachment.loadAction = .load
        gaussian.modelTransform=entity.simdWorldTransform
        try gaussian.encodeStage(command:command,pass:pass,view:camera.simdWorldTransform.inverse,
                                 projection:metal,camera:camera.simdWorldPosition,size:size)
    }
    public func photograph(size:CGSize) throws -> NSImage {
        guard size.width.isFinite,size.height.isFinite else {throw CanvasToolError.invalid("输出尺寸无效")}
        let width=min(4096,max(16,Int(size.width))),height=min(4096,max(16,Int(size.height)))
        let colorDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
        colorDescriptor.usage=[.renderTarget,.shaderRead];colorDescriptor.storageMode = .shared
        let depthDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:width,height:height,mipmapped:false)
        depthDescriptor.usage=[.renderTarget,.shaderRead];depthDescriptor.storageMode = .private
        guard let color=device.makeTexture(descriptor:colorDescriptor),let depth=device.makeTexture(descriptor:depthDescriptor),
              let command=queue.makeCommandBuffer() else {throw CanvasToolError.invalid("片场渲染缓冲区不可用")}
        let pass=MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture=color;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        let background=CanvasStageRenderer.color(config.background).usingColorSpace(.deviceRGB) ?? .black
        pass.colorAttachments[0].clearColor=MTLClearColorMake(background.redComponent,background.greenComponent,background.blueComponent,1)
        pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .store;pass.depthAttachment.clearDepth=0
        try encode(command:command,pass:pass,size:CGSize(width:width,height:height))
        command.commit();command.waitUntilCompleted()
        guard command.status == .completed else {throw command.error ?? CanvasToolError.invalid("片场合成失败")}
        var bytes=[UInt8](repeating:0,count:width*height*4)
        bytes.withUnsafeMutableBytes {color.getBytes($0.baseAddress!,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)}
        guard let provider=CGDataProvider(data:Data(bytes) as CFData),
              let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {throw CanvasToolError.invalid("片场像素输出失败")}
        return NSImage(cgImage:image,size:CGSize(width:width,height:height))
    }
    public func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize) {}
    public func draw(in view:MTKView) {
        guard view.drawableSize.width>0,view.drawableSize.height>0,let pass=view.currentRenderPassDescriptor,
              let drawable=view.currentDrawable,let command=queue.makeCommandBuffer() else {return}
        pass.depthAttachment.storeAction = .store
        do {try encode(command:command,pass:pass,size:view.drawableSize)}
        catch {return}
        command.present(drawable);command.commit()
    }
}
