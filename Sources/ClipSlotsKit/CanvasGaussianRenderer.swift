import Foundation
import MetalKit
import simd

/// Anisotropic, depth-sorted Gaussian rasterization. The projected covariance
/// uses perspective derivatives; this is not a point-cloud approximation.
public final class CanvasGaussianRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let stagePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    public var modelTransform=matrix_identity_float4x4
    private let splatBuffer: MTLBuffer
    private let shBuffer: MTLBuffer
    private var orderBuffer: MTLBuffer
    private let cloud: CanvasGaussianCloud
    public var target: SIMD3<Float>
    public var yaw: Float = 0
    public var pitch: Float = 0
    public var distance: Float
    private var orderCamera: SIMD3<Float>?
    private var sortVersion = 0
    private var sorting = false
    private let sortQueue = DispatchQueue(label: "clipslots.gaussian.sort", qos: .userInitiated)
    private struct Uniforms {
        var view: simd_float4x4
        var projection: simd_float4x4
        var camera: SIMD4<Float>
        var viewport: SIMD4<Float>
        var degree: SIMD4<UInt32>
        var model: simd_float4x4
    }
    public init(cloud: CanvasGaussianCloud) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CanvasToolError.invalid("Metal 不可用")
        }
        self.device = device; self.queue = queue; self.cloud = cloud
        target = (cloud.minimum + cloud.maximum) / 2
        distance = max(0.1, simd_length(cloud.maximum - cloud.minimum) * 1.2)
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "splatVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "splatFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true; color.rgbBlendOperation = .add; color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.depthAttachmentPixelFormat = .depth32Float
        stagePipeline = try device.makeRenderPipelineState(descriptor:descriptor)
        // SceneKit's Metal renderer uses reversed Z (near = 1, far = 0).
        let depth=MTLDepthStencilDescriptor();depth.depthCompareFunction = .greaterEqual;depth.isDepthWriteEnabled=false
        guard let state=device.makeDepthStencilState(descriptor:depth) else {throw CanvasToolError.invalid("高斯深度状态不可用")}
        depthState=state
        guard let splats = cloud.splats.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }),
              let order = (0..<cloud.splats.count).map(UInt32.init).withUnsafeBytes({
                  device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
              }) else { throw CanvasToolError.invalid("高斯点缓冲区分配失败") }
        splatBuffer = splats; orderBuffer = order
        let sh = cloud.harmonics.isEmpty ? [Float](repeating: 0, count: 3) : cloud.harmonics
        guard let shBuffer = sh.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        else { throw CanvasToolError.invalid("球谐系数缓冲区分配失败") }
        self.shBuffer = shBuffer
        super.init()
    }
    public func reset() {
        yaw = 0; pitch = 0; target = (cloud.minimum + cloud.maximum) / 2
        distance = max(0.1, simd_length(cloud.maximum - cloud.minimum) * 1.2); orderCamera = nil
    }
    public var camera: SIMD3<Float> {
        target + SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
    }
    public func move(forward: Float, right: Float, up: Float) {
        let direction = simd_normalize(target - camera)
        let horizontal = simd_normalize(simd_cross(direction, SIMD3<Float>(0,1,0)))
        target += (direction * forward + horizontal * right + SIMD3<Float>(0,up,0)) * max(0.01, distance * 0.05)
    }
    private func uniforms(size: CGSize) -> Uniforms {
        let eye = camera, forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0,1,0))), up = simd_cross(right, forward)
        let view = simd_float4x4(columns: (SIMD4(right.x,up.x,-forward.x,0),
            SIMD4(right.y,up.y,-forward.y,0), SIMD4(right.z,up.z,-forward.z,0),
            SIMD4(-simd_dot(right,eye),-simd_dot(up,eye),simd_dot(forward,eye),1)))
        let aspect = Float(max(1, size.width) / max(1, size.height)), f: Float = 1 / tan(.pi / 6)
        let near = max(0.0001, distance / 10000), far = max(100, distance * 100)
        let projection = simd_float4x4(columns: (SIMD4(f / aspect,0,0,0), SIMD4(0,f,0,0),
            SIMD4(0,0,far / (near - far),-1), SIMD4(0,0,near * far / (near - far),0)))
        return Uniforms(view: view, projection: projection, camera: SIMD4(eye,1),
            viewport: SIMD4(Float(size.width),Float(size.height), cloud.antialiased ? 0.3 : 0.0,0),
            degree: SIMD4(UInt32(cloud.degree),0,0,0),model:modelTransform)
    }
    private func sortedBuffer(view:simd_float4x4) throws -> MTLBuffer {
        let depths=cloud.splats.map {(view * modelTransform * $0.center).z}
        let indices=depths.indices.sorted { depths[$0]<depths[$1] }.map(UInt32.init)
        guard let buffer=indices.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count)}) else {
            throw CanvasToolError.invalid("高斯排序缓冲区分配失败")
        }
        return buffer
    }
    public func encodeStage(command:MTLCommandBuffer,pass:MTLRenderPassDescriptor,view:simd_float4x4,
                            projection:simd_float4x4,camera:SIMD3<Float>,size:CGSize) throws {
        let order=try sortedBuffer(view:view)
        var uniform=Uniforms(view:view,projection:projection,camera:SIMD4(camera,1),
            viewport:SIMD4(Float(size.width),Float(size.height),cloud.antialiased ? 0.3 : 0,0),
            degree:SIMD4(UInt32(cloud.degree),0,0,0),model:modelTransform)
        guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else {throw CanvasToolError.invalid("高斯深度渲染无法启动")}
        encoder.setRenderPipelineState(stagePipeline);encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(splatBuffer,offset:0,index:0);encoder.setVertexBuffer(order,offset:0,index:1)
        encoder.setVertexBuffer(shBuffer,offset:0,index:2)
        encoder.setVertexBytes(&uniform,length:MemoryLayout<Uniforms>.stride,index:3)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:cloud.splats.count)
        encoder.endEncoding()
    }
    private func requestSort(view: MTKView) {
        let eye = camera
        guard orderCamera != eye, !sorting else { return }
        sorting = true; orderCamera = eye; sortVersion += 1
        let version = sortVersion, direction = simd_normalize(target - eye), cloud = cloud, device = device
        sortQueue.async { [weak self, weak view] in
            let depths = cloud.splats.map { simd_dot(SIMD3($0.center.x,$0.center.y,$0.center.z) - eye, direction) }
            let indices = depths.indices.sorted { depths[$0] > depths[$1] }.map(UInt32.init)
            let buffer = indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.sorting = false
                guard self.sortVersion == version, let buffer else { return }
                self.orderBuffer = buffer; view?.draw()
            }
        }
    }
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    public func photograph(size: CGSize) throws -> NSImage {
        let width = min(4096,max(16,Int(size.width))), height = min(4096,max(16,Int(size.height)))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
        descriptor.usage = [.renderTarget,.shaderRead]; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor:descriptor), let command = queue.makeCommandBuffer() else {
            throw CanvasToolError.invalid("高斯摄影缓冲区分配失败")
        }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.03,0.03,0.03,1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor:pass) else {throw CanvasToolError.invalid("高斯摄影无法启动")}
        var uniform = uniforms(size:CGSize(width:width,height:height))
        let photographOrder=try sortedBuffer(view:uniform.view)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(splatBuffer,offset:0,index:0);encoder.setVertexBuffer(photographOrder,offset:0,index:1)
        encoder.setVertexBuffer(shBuffer,offset:0,index:2)
        encoder.setVertexBytes(&uniform,length:MemoryLayout<Uniforms>.stride,index:3)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:cloud.splats.count)
        encoder.endEncoding();command.commit();command.waitUntilCompleted()
        guard command.status == .completed else {throw command.error ?? CanvasToolError.invalid("高斯摄影渲染失败")}
        let row=width*4;var pixels=[UInt8](repeating:0,count:row*height)
        pixels.withUnsafeMutableBytes {texture.getBytes($0.baseAddress!,bytesPerRow:row,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)}
        guard let provider=CGDataProvider(data:Data(pixels) as CFData),
              let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,
                bytesPerRow:row,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {throw CanvasToolError.invalid("高斯摄影输出失败")}
        return NSImage(cgImage:image,size:CGSize(width:width,height:height))
    }
    public func draw(in view: MTKView) {
        guard view.drawableSize.width > 0, view.drawableSize.height > 0,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        requestSort(view: view)
        var uniform = uniforms(size: view.drawableSize)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(splatBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(orderBuffer, offset: 0, index: 1)
        encoder.setVertexBuffer(shBuffer, offset: 0, index: 2)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<Uniforms>.stride, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: cloud.splats.count)
        encoder.endEncoding(); command.present(drawable); command.commit()
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Splat { float4 center; float4 scale; float4 rotation; float4 color; };
    struct Uniform { float4x4 view; float4x4 projection; float4 camera; float4 viewport; uint4 degree; float4x4 model; };
    struct Out { float4 position [[position]]; float2 gaussian; float4 color; };
    float3x3 quaternion(float4 q) {
        float x=q.x,y=q.y,z=q.z,w=q.w;
        return float3x3(float3(1-2*(y*y+z*z),2*(x*y+z*w),2*(x*z-y*w)),
                        float3(2*(x*y-z*w),1-2*(x*x+z*z),2*(y*z+x*w)),
                        float3(2*(x*z+y*w),2*(y*z-x*w),1-2*(x*x+y*y)));
    }
    vertex Out splatVertex(uint vid [[vertex_id]], uint instance [[instance_id]],
        device const Splat *splats [[buffer(0)]], device const uint *order [[buffer(1)]],
        device const float *sh [[buffer(2)]], constant Uniform &u [[buffer(3)]]) {
        uint id=order[instance]; Splat s=splats[id]; Out out;
        float4 center=u.view*u.model*s.center;
        out.color=s.color; out.gaussian=float2(0);
        if(center.z>=-0.00001 || s.color.a<0.003) {out.position=float4(2,2,2,1);return out;}
        float3x3 r=quaternion(s.rotation);
        float3x3 scaled=float3x3(r[0]*s.scale.x,r[1]*s.scale.y,r[2]*s.scale.z);
        float3x3 v=float3x3(u.view[0].xyz,u.view[1].xyz,u.view[2].xyz);
        float3x3 m=float3x3(u.model[0].xyz,u.model[1].xyz,u.model[2].xyz);
        float3x3 a=v*m*scaled;
        float3x3 covariance=a*transpose(a);
        float z=-center.z;
        float fx=u.projection[0][0]*u.viewport.x*0.5, fy=u.projection[1][1]*u.viewport.y*0.5;
        float3 jx=float3(fx/z,0,fx*center.x/(z*z));
        float3 jy=float3(0,fy/z,fy*center.y/(z*z));
        float xx=dot(jx,covariance*jx), xy=dot(jx,covariance*jy), yy=dot(jy,covariance*jy);
        float determinant=max(0.000001,xx*yy-xy*xy);
        xx+=0.3;yy+=0.3;
        if(u.viewport.z>0) out.color.a*=sqrt(determinant/max(0.000001,xx*yy-xy*xy));
        float mid=(xx+yy)*0.5, spread=sqrt(max(0.000001,(xx-yy)*(xx-yy)*0.25+xy*xy));
        float l1=max(0.000001,mid+spread),l2=max(0.000001,mid-spread);
        float2 axis=abs(xy)>0.000001?normalize(float2(xy,l1-xx)):(xx>=yy?float2(1,0):float2(0,1));
        float2 major=axis*min(4096.0,3*sqrt(l1)),minor=float2(-axis.y,axis.x)*min(4096.0,3*sqrt(l2));
        const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
        float2 corner=corners[vid], offset=(major*corner.x+minor*corner.y)*2/u.viewport.xy;
        float4 clip=u.projection*center;
        out.position=clip+float4(offset*clip.w,0,0);out.gaussian=corner*3;
        uint degree=u.degree.x, count=degree==0?0:(degree==1?3:(degree==2?8:15));
        if(count>0) {
            // The SH coefficients remain in the resource's local frame.
            float3 direction=(u.model*s.center).xyz-u.camera.xyz;
            float3 d=normalize(transpose(m)*direction);float x=d.x,y=d.y,z=d.z;
            float basis[15];
            basis[0]=-0.488602512*y;basis[1]=0.488602512*z;basis[2]=-0.488602512*x;
            basis[3]=1.092548431*x*y;basis[4]=-1.092548431*y*z;
            basis[5]=0.315391565*(2*z*z-x*x-y*y);basis[6]=-1.092548431*x*z;basis[7]=0.546274215*(x*x-y*y);
            basis[8]=-0.590043590*y*(3*x*x-y*y);basis[9]=2.890611443*x*y*z;
            basis[10]=-0.457045799*y*(4*z*z-x*x-y*y);basis[11]=0.373176333*z*(2*z*z-3*x*x-3*y*y);
            basis[12]=-0.457045799*x*(4*z*z-x*x-y*y);basis[13]=1.445305721*z*(x*x-y*y);
            basis[14]=-0.590043590*x*(x*x-3*y*y);
            for(uint k=0;k<count;k++) {uint b=id*count*3+k*3;out.color.rgb+=basis[k]*float3(sh[b],sh[b+1],sh[b+2]);}
        }
        out.color.rgb=max(float3(0),out.color.rgb);return out;
    }
    fragment float4 splatFragment(Out in [[stage_in]]) {
        float radius=dot(in.gaussian,in.gaussian);
        if(radius>9) discard_fragment();
        float alpha=min(0.99,in.color.a*exp(-0.5*radius));
        if(alpha<0.0039215686) discard_fragment();
        return float4(in.color.rgb*alpha,alpha);
    }
    """
}
