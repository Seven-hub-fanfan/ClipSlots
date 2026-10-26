import AppKit
import SceneKit
import simd
import ClipSlotsKit

/// Authored volumetric replacement at the original model pivots and camera.
/// The controller deforms the leg mesh in depth; it never scales a flat image.
// A live scene belongs exclusively to HeaderMascotRenderer's serial queue.
// Standalone regression scenes are used synchronously by their caller.
final class HeaderMascotScene {
    private struct Mesh: Decodable {
        struct Range: Decodable { let offset:Int; let count:Int }
        let name:String; let part:String
        let positions:Range; let normals:Range; let uv:Range; let indices:Range
        let color:[Double]; let emission:Bool; let sticker:Bool?
    }
    private struct Part {
        let node:SCNNode; let kind:String
        let positions:[SIMD3<Float>]; let normals:[SIMD3<Float>]
        let uv:[SIMD2<Float>]; let indices:[UInt32]
    }
    let scene=SCNScene()
    let renderer=SCNRenderer(device:nil,options:nil)
    let world=SCNNode()
    let model=SCNNode()
    let head=SCNNode()
    let camera=SCNNode()
    private var parts:[Part]=[]
    private var expressionNodes:[SCNNode]=[]
    private var concernedBrows:[SCNNode]=[]
    private var concernGlow:SCNNode?
    private var activityTracks:[String:[String:Any]]=[:]
    private var lastPose:MascotPose?
    private var lastActivity:MascotMotion.Activity?
    private(set) var computerGaze = (yaw: 0.0, pitch: 26.0)
    private let headRest=simd_quatf(ix:-0.0658900354,iy:-0.0428641721,iz:0.012898743,r:0.9968223455)
    // Rotate at the neck, not at the rear crown. Compensating the rest
    // translation keeps the authored neutral silhouette unchanged.
    private let headCenter=SIMD3<Float>(0,0.035,-0.025)
    private var headPosition:SIMD3<Float> { SIMD3(0.026227125,0.0008692615,-0.03371167)+headRest.act(headCenter) }
    private var headInverse=matrix_identity_float4x4
    private var pointerCameraTransform=matrix_identity_float4x4
    private var lastHeadTransform:simd_float4x4?
    private var lastContactTransform:simd_float4x4?
    private var lastContactLift:Float=0
    private(set) var neckAttachmentValid=true
    private(set) var neckSurfaceValid=true
    private(set) var headBodyClearanceValid=true
    private let neckSlices=40,neckRings=32
    private let neckLower:Float = -0.18
    private let neckUpper:Float = 0.26
    private let collisionGrid=96
    private var shoulderHeight:[Float]=[]
    private var headContactPoints:[SIMD3<Float>]=[]
    private let hip:Float = -0.56455332
    private let attachment:Float = -0.59701014
    private(set) var ready=false
    private(set) var pixelsPerY=0.0
    private(set) var legPixels=0.0
    private(set) var geometryInsideFrustum=true
    private(set) var facialSurfaceValid=true
    private var verifyGeometry=false

    private func faceSurface(x:Float,y:Float,offset:Float=0.007)->(SIMD3<Float>,SIMD3<Float>) {
        let z:Float=0.005+0.47*sqrt(max(0.001,1-pow(x/0.67,2)-pow((y-0.505)/0.50,2)))
        let normal=simd_normalize(SIMD3(x/(0.67*0.67),(y-0.505)/(0.50*0.50),(z-0.005)/(0.47*0.47)))
        return (SIMD3(x,y,z)+normal*offset,normal)
    }
    private func facialPatch(name:String,cx:Float,cy:Float,width:Float,height:Float,
                             angle:Float=0,color:NSColor)->SCNNode {
        var p:[SIMD3<Float>]=[],n:[SIMD3<Float>]=[],indices:[UInt32]=[]
        let nx=12,ny=6
        for y in 0...ny { for x in 0...nx {
            let dx=(Float(x)/Float(nx)-0.5)*width,dy=(0.5-Float(y)/Float(ny))*height
            let (point,normal)=faceSurface(x:cx+dx*cos(angle)-dy*sin(angle),y:cy+dx*sin(angle)+dy*cos(angle))
            p.append(point);n.append(normal)
        }}
        for y in 0..<ny { for x in 0..<nx {
            let a=UInt32(y*(nx+1)+x),b=a+1,c=a+UInt32(nx+1),d=c+1
            indices += [a,c,b,b,c,d]
        }}
        let node=SCNNode();node.name=name
        let part=Part(node:node,kind:"expression",positions:p,normals:n,uv:[],indices:indices)
        node.geometry=geometry(part,positions:p,normals:n)
        let mat=SCNMaterial();mat.lightingModel = .constant;mat.diffuse.contents=color
        mat.isDoubleSided=false;mat.readsFromDepthBuffer=true;mat.writesToDepthBuffer=true
        node.geometry?.materials=[mat];node.opacity=0;head.addChildNode(node)
        return node
    }

    init(directory:URL?=nil) {
        verifyGeometry=directory != nil
        #if DEBUG
        verifyGeometry=true
        #endif
        guard let url=directory?.appendingPathComponent("scene.json") ?? MascotResources.url("scene"),
              let descriptors=try? JSONDecoder().decode([Mesh].self,from:Data(contentsOf:url)),
              let data=try? Data(contentsOf:url.deletingLastPathComponent().appendingPathComponent("scene.mesh")) else { return }
        let texture=NSImage(contentsOf:url.deletingLastPathComponent().appendingPathComponent("stickers.png"))
        let cloth=NSImage(contentsOf:url.deletingLastPathComponent().appendingPathComponent("cloth.png"))
        let clothNormal=NSImage(contentsOf:url.deletingLastPathComponent().appendingPathComponent("cloth-normal.png"))
        let clothRoughness=NSImage(contentsOf:url.deletingLastPathComponent().appendingPathComponent("cloth-roughness.png"))
        let hoodCloth=NSImage(contentsOf:url.deletingLastPathComponent().appendingPathComponent("hood-cloth.png")) ?? cloth
        let hoodNormal=NSImage(contentsOf:url.deletingLastPathComponent().appendingPathComponent("hood-cloth-normal.png")) ?? clothNormal
        let hoodRoughness=NSImage(contentsOf:url.deletingLastPathComponent().appendingPathComponent("hood-cloth-roughness.png")) ?? clothRoughness
        if let data=try? Data(contentsOf:url.deletingLastPathComponent().appendingPathComponent("activity-motion.json")),
           let tracks=try? JSONSerialization.jsonObject(with:data) as? [String:[String:Any]] { activityTracks=tracks }
        func vectors(_ range:Mesh.Range,dimensions:Int)->[[Float]] {
            guard range.offset>=0,range.count>=0,range.offset+range.count*dimensions*4<=data.count else { return [] }
            return data.withUnsafeBytes { bytes in
                (0..<range.count).map { i in
                    (0..<dimensions).map { j in
                        Float(bitPattern:UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:range.offset+(i*dimensions+j)*4,as:UInt32.self)))
                    }
                }
            }
        }
        scene.rootNode.addChildNode(world);world.addChildNode(model);model.addChildNode(head)
        model.simdPosition=SIMD3(-0.046049592,-0.39683509,0.09383806)
        model.simdOrientation=simd_quatf(ix:0.0546650733,iy:0.298319071,iz:0.028456836,r:0.952474498)
        head.simdPosition=headPosition
        head.simdOrientation=headRest
        headInverse=simd_inverse(head.simdWorldTransform)
        for m in descriptors {
            let p=vectors(m.positions,dimensions:3).map { SIMD3($0[0],$0[1],$0[2]) }
            let n=vectors(m.normals,dimensions:3).map { SIMD3($0[0],$0[1],$0[2]) }
            let uv=vectors(m.uv,dimensions:2).map { SIMD2($0[0],1-$0[1]) }
            guard p.count==m.positions.count,n.count==p.count,
                  m.indices.offset+m.indices.count*4<=data.count else { return }
            let indices:[UInt32]=data.withUnsafeBytes { bytes in
                (0..<m.indices.count).map { UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:m.indices.offset+$0*4,as:UInt32.self)) }
            }
            guard indices.allSatisfy({ Int($0)<p.count }) else { return }
            let node=SCNNode();node.name=m.name
            let mat=SCNMaterial()
            mat.lightingModel=m.emission ? .constant : .physicallyBased
            mat.diffuse.contents=NSColor(calibratedRed:m.color[0],green:m.color[1],blue:m.color[2],alpha:1)
            mat.roughness.contents=m.part=="head" || m.name.hasPrefix("cape") ? 0.65 : 0.42
            mat.metalness.contents=m.part=="laptop" ? 0.3 : 0.0
            mat.isDoubleSided=true
            if m.part=="voiceHead" {
                let metal=m.name.contains("earcup") || m.name.contains("telescopic") ||
                    m.name.contains("digital-crown") || m.name.contains("noise-control")
                mat.metalness.contents=metal ? 0.72 : 0
                mat.roughness.contents=metal ? 0.32 : 0.72
            }
            if m.name=="hood-shell" || m.name=="hood-rim" || m.name.hasPrefix("cape") ||
               m.name.hasPrefix("collar") || m.name.hasPrefix("sleeve") || m.name=="tunic" {
                let hoodFabric=m.name=="hood-shell" || m.name=="hood-rim"
                mat.diffuse.contents=hoodFabric ? hoodCloth : cloth
                mat.roughness.contents=(hoodFabric ? hoodRoughness : clothRoughness) ?? NSColor(calibratedWhite:0.85,alpha:1)
                mat.normal.contents=hoodFabric ? hoodNormal : clothNormal
                mat.normal.intensity=0.11
                mat.metalness.contents=0
                mat.diffuse.wrapS = .repeat;mat.diffuse.wrapT = .repeat
                mat.normal.wrapS = .repeat;mat.normal.wrapT = .repeat
            }
            if m.emission { mat.emission.contents=NSColor(calibratedRed:0.02,green:0.9,blue:0.95,alpha:1) }
            if m.sticker == true {
                mat.diffuse.contents=texture;mat.lightingModel = .constant
                mat.transparencyMode = .aOne;node.renderingOrder=2
                mat.diffuse.magnificationFilter = .linear;mat.diffuse.minificationFilter = .linear
                mat.diffuse.mipFilter = .linear
            } else if m.part=="laptop" {
                // Keep separate aluminium, display, keys, ports and teal lid.
                // A single green override erased the old laptop's materials.
                mat.metalness.contents=m.name.contains("unibody") || m.name.contains("frame") ? 0.65 : 0.12
                mat.roughness.contents=m.name.contains("display") ? 0.3 : 0.5
            }
            if m.part.hasPrefix("eye") {
                mat.isDoubleSided=false
                mat.readsFromDepthBuffer=true;mat.writesToDepthBuffer=true
                mat.roughness.contents=0.35
            }
            let surfaceUV:[SIMD2<Float>]
            if uv.isEmpty {
                surfaceUV=p.map { SIMD2(($0.x+0.75)/1.5,($0.y+0.1)/1.3) }
            } else { surfaceUV=uv }
            let part=Part(node:node,kind:m.part,positions:p,normals:n,uv:surfaceUV,indices:indices)
            if m.name=="macbook-display", !p.isEmpty {
                // Look at the upper screen from the eyes in the resting head's
                // coordinates. Keep the established safe neck rotation limits.
                let center=p.reduce(SIMD3<Float>.zero,+)/Float(p.count)
                let top=p.max { $0.y < $1.y }?.y ?? center.y
                let target=center+SIMD3<Float>(0,(top-center.y)*0.60,(top-center.y)*0.60*tan(20 * .pi/180))
                let eyes=headPosition+headRest.act(SIMD3(0,0.352,0.43)-headCenter)
                let direction=headRest.inverse.act(target-eyes)
                computerGaze=(max(-65,min(65,atan2(Double(direction.x),Double(direction.z))*180 / .pi)),
                    max(-30,min(30,atan2(Double(-direction.y),hypot(Double(direction.x),Double(direction.z)))*180 / .pi)))
            }
            if m.name=="macbook-apple-logo" || m.name=="macbook-apple-leaf" {
                mat.diffuse.contents=NSColor(calibratedWhite:0.06,alpha:1)
                mat.metalness.contents=0;mat.roughness.contents=0.6
                mat.emission.contents=NSColor.white;mat.emission.intensity=0.18
            }
            node.geometry=geometry(part,positions:p,normals:n);node.geometry?.materials=[mat]
            if ["head","eyeLeft","eyeRight","voiceHead"].contains(m.part) { head.addChildNode(node) }
            else { model.addChildNode(node) }
            if m.part.hasPrefix("voice") { node.isHidden=true }
            parts.append(part)
        }
        buildShoulderSurface()
        // Closed cloth sleeve: the lower rings remain inside the tunic and
        // the upper rings remain inside the chin. It bends between the two
        // attachments instead of translating a detached rigid collar.
        var neckP:[SIMD3<Float>]=[],neckN:[SIMD3<Float>]=[],neckUV:[SIMD2<Float>]=[],neckI:[UInt32]=[]
        let slices=neckSlices,rings=neckRings
        for j in 0...rings {
            let t=Float(j)/Float(rings)
            let radius:Float=0.24+0.10*t+0.026*pow(sin(t * .pi*4),2)
            for i in 0...slices {
                let a=Float(i)*2 * .pi/Float(slices)
                neckP.append(SIMD3(radius*cos(a),neckLower+(neckUpper-neckLower)*t,0.65*radius*sin(a)-0.025))
                neckN.append(simd_normalize(SIMD3(cos(a),-(0.10+0.026 * .pi*4*sin(8 * .pi*t))/(neckUpper-neckLower),sin(a)/0.65)))
                neckUV.append(SIMD2(Float(i)/Float(slices),t))
            }
        }
        for j in 0..<rings { for i in 0..<slices {
            let a=UInt32(j*(slices+1)+i),b=a+1,c=a+UInt32(slices+1),d=c+1
            neckI += [a,c,b,b,c,d]
        }}
        // End caps are hidden inside the closed torso and face surfaces.
        for j in [0,rings] {
            let center=UInt32(neckP.count)
            neckP.append(SIMD3(0,neckLower+(neckUpper-neckLower)*Float(j)/Float(rings),-0.025))
            neckN.append(SIMD3(0,j==0 ? -1 : 1,0));neckUV.append(SIMD2(0.5,0.5))
            for i in 0..<slices {
                let a=UInt32(j*(slices+1)+i)
                neckI += j==0 ? [center,a,a+1] : [center,a+1,a]
            }
        }
        let neck=SCNNode();neck.name="neck-cloth-bridge"
        let neckPart=Part(node:neck,kind:"neck",positions:neckP,normals:neckN,uv:neckUV,indices:neckI)
        neck.geometry=geometry(neckPart,positions:neckP,normals:neckN)
        let neckMat=SCNMaterial();neckMat.lightingModel = .physicallyBased
        neckMat.diffuse.contents=cloth;neckMat.roughness.contents=clothRoughness
        neckMat.normal.contents=clothNormal;neckMat.normal.intensity=0.11
        neck.geometry?.materials=[neckMat];model.addChildNode(neck);parts.append(neckPart)
        camera.camera=SCNCamera()
        camera.position=SCNVector3(0.03525296,-0.31239878,9.4005538)
        let fov=2*atan(tan(15.18928673718289 * .pi/360)/1.042)*180 / .pi
        var projection=SCNMatrix4MakePerspective(fov * .pi/180,1,0.1,30)
        // Centre the complete motion envelope before zooming. The old camera
        // spent a quarter of the canvas on empty space below/right, making
        // the character small even though its extreme crown fit the view.
        projection.m11/=1.82;projection.m22/=1.82
        projection.m31 = -0.247;projection.m32 = 0.376
        camera.camera?.zNear=0.1;camera.camera?.zFar=30
        camera.camera?.fieldOfView=2*atan(tan(fov * .pi/360)*1.82)*180 / .pi
        camera.camera?.projectionTransform=projection
        scene.rootNode.addChildNode(camera)
        renderer.scene=scene;renderer.pointOfView=camera
        renderer.autoenablesDefaultLighting=false
        scene.background.contents=NSColor.clear
        // Mirrored sockets and pupils are actual curved mesh surfaces.
        // Each layer keeps its own depth during a blink, with no image crop.
        for (kind,cx) in [("eyeLeft",-0.255),("eyeRight",0.255)] {
            expressionNodes.append(facialPatch(name:"drag-"+kind,cx:Float(cx),cy:0.405,width:0.13,height:0.13,
                color:NSColor(calibratedRed:0.7,green:1,blue:1,alpha:1)))
        }
        expressionNodes.append(facialPatch(name:"drag-mouth",cx:0,cy:0.245,width:0.30,height:0.055,
            color:NSColor(calibratedRed:0.7,green:1,blue:1,alpha:1)))
        for sign in [-1.0,1.0] {
            concernedBrows.append(facialPatch(name:"concern-brow",cx:Float(sign*0.25),cy:0.565,
                width:0.16,height:0.027,angle:Float(sign*0.72),
                color:NSColor(calibratedWhite:0.045,alpha:1)))
        }
        let glow=SCNNode();glow.light=SCNLight();glow.light?.type = .omni
        glow.light?.color=NSColor(calibratedRed:0.95,green:0.19,blue:0.13,alpha:1)
        glow.position=SCNVector3(0,0.54,0.85);glow.light?.intensity=0
        glow.light?.attenuationStartDistance=0;glow.light?.attenuationEndDistance=0.75
        head.addChildNode(glow);concernGlow=glow
        func light(_ type:SCNLight.LightType,_ pos:SCNVector3,_ intensity:CGFloat,_ color:NSColor) {
            let node=SCNNode();node.light=SCNLight();node.light?.type=type
            node.light?.intensity=intensity;node.light?.color=color;node.position=pos
            if type != .ambient { node.look(at:SCNVector3(0,0,0)) }
            scene.rootNode.addChildNode(node)
        }
        light(.ambient,SCNVector3Zero,220,NSColor(calibratedWhite:0.9,alpha:1))
        light(.directional,SCNVector3(-4,6,7),600,.white)
        light(.directional,SCNVector3(6,3,4),180,.white)
        light(.directional,SCNVector3(1,4,-6),350,.white)
        let shadow=SCNNode(geometry:SCNPlane(width:1.5,height:0.8))
        shadow.eulerAngles.x = -.pi/2;shadow.position=SCNVector3(0,-1.39,0.15)
        let shadowMat=SCNMaterial();shadowMat.lightingModel = .constant
        let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:128,pixelsHigh:64,bitsPerSample:8,samplesPerPixel:4,
            hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        for y in 0..<64 { for x in 0..<128 {
            let a=0.15*exp(-4*(pow((Double(x)-64)/48,2)+pow((Double(y)-32)/23,2)))
            rep.setColor(NSColor(calibratedWhite:0,alpha:a),atX:x,y:y)
        }}
        let shadowImage=NSImage(size:NSSize(width:128,height:64));shadowImage.addRepresentation(rep)
        shadowMat.diffuse.contents=shadowImage;shadowMat.isDoubleSided=true
        shadow.geometry?.materials=[shadowMat];scene.rootNode.addChildNode(shadow)
        // The authored renderer projects to NDC before multiplying by 96/2.
        // SCNRenderer.projectPoint depends on its last snapshot viewport.
        func project(_ v:SIMD4<Float>)->Double {
            let z=Double(v.z)-9.400553755854418
            return (Double(v.y)+0.31239878124715875)*Double(projection.m22)/(-z)
        }
        pixelsPerY=abs(project(SIMD4(0,1,0,1))-project(SIMD4(0,0,0,1)))*96*0.85/2
        // Reference projection contains the original fixed hip and shortest foot.
        let lp=parts.filter { $0.kind.hasPrefix("leg") }.flatMap(\.positions)
        let projected=lp.map { p -> Double in
            let v=model.simdWorldTransform*SIMD4(p,1)
            return project(v)
        }
        let bottom=projected.min() ?? 0
        let foot=lp.min { l,r in
            let a=model.simdWorldTransform*SIMD4(l,1),b=model.simdWorldTransform*SIMD4(r,1)
            return project(a) < project(b)
        } ?? SIMD3(0,-0.91335332,0)
        let hv=model.simdWorldTransform*SIMD4(foot.x,hip,foot.z,1)
        legPixels=abs(project(hv)-bottom)*96*0.85/2
        // Calibrated from the packaged head center, fixed hip and lowest
        // original foot, rather than the new character's silhouette.
        // Shift child geometry into the pivot's coordinates. The compensated
        // rest translation preserves the neutral pose and keeps world-space
        // vertex checks identical to what SceneKit actually renders.
        for node in head.childNodes { node.simdPosition-=headCenter }
        pixelsPerY=28.538486839707254
        legPixels=10.308069221890811
        pointerCameraTransform=camera.simdWorldTransform
        ready=true
    }
    private func geometry(_ part:Part,positions:[SIMD3<Float>],normals:[SIMD3<Float>])->SCNGeometry {
        func source(_ values:[SIMD3<Float>],_ semantic:SCNGeometrySource.Semantic)->SCNGeometrySource {
            let data=values.withUnsafeBytes { Data($0) }
            return SCNGeometrySource(data:data,semantic:semantic,vectorCount:values.count,
                usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:0,dataStride:MemoryLayout<SIMD3<Float>>.stride)
        }
        var sources=[source(positions,.vertex),source(normals,.normal)]
        if !part.uv.isEmpty {
            let data=part.uv.withUnsafeBytes { Data($0) }
            sources.append(SCNGeometrySource(data:data,semantic:.texcoord,vectorCount:part.uv.count,
                usesFloatComponents:true,componentsPerVector:2,bytesPerComponent:4,dataOffset:0,dataStride:8))
        }
        let data=part.indices.withUnsafeBytes { Data($0) }
        return SCNGeometry(sources:sources,elements:[SCNGeometryElement(data:data,primitiveType:.triangles,
            primitiveCount:part.indices.count/3,bytesPerIndex:4)])
    }
    private func buildShoulderSurface() {
        // Cache the top of the actual torso, collar and mantle triangles in
        // model coordinates. No disk or triangle traversal occurs per frame.
        shoulderHeight=Array(repeating:-2,count:collisionGrid*collisionGrid)
        let step:Float=3/Float(collisionGrid-1)
        for part in parts where part.kind=="body" && part.node.name != "knot" &&
            !(part.node.name ?? "").hasPrefix("tie") {
            for i in stride(from:0,to:part.indices.count,by:3) {
                let a=part.positions[Int(part.indices[i])],b=part.positions[Int(part.indices[i+1])],
                    c=part.positions[Int(part.indices[i+2])]
                let determinant=(b.z-c.z)*(a.x-c.x)+(c.x-b.x)*(a.z-c.z)
                guard abs(determinant)>0.0000001 else { continue }
                let x0=max(0,Int(floor((min(a.x,b.x,c.x)+1.5)/step)))
                let x1=min(collisionGrid-1,Int(ceil((max(a.x,b.x,c.x)+1.5)/step)))
                let z0=max(0,Int(floor((min(a.z,b.z,c.z)+1.5)/step)))
                let z1=min(collisionGrid-1,Int(ceil((max(a.z,b.z,c.z)+1.5)/step)))
                guard x0<=x1,z0<=z1 else { continue }
                for z in z0...z1 { for x in x0...x1 {
                    let px=Float(x)*step-1.5,pz=Float(z)*step-1.5
                    let u=((b.z-c.z)*(px-c.x)+(c.x-b.x)*(pz-c.z))/determinant
                    let v=((c.z-a.z)*(px-c.x)+(a.x-c.x)*(pz-c.z))/determinant
                    if u>=0 && v>=0 && u+v<=1 {
                        let index=z*collisionGrid+x
                        shoulderHeight[index]=max(shoulderHeight[index],u*a.y+v*b.y+(1-u-v)*c.y)
                    }
                }}
            }
        }
        // Preserve narrow collar peaks between samples. Interpolation of
        // this upper envelope stays continuous and cannot cut the edge down.
        let surface=shoulderHeight
        for z in 1..<(collisionGrid-1) { for x in 1..<(collisionGrid-1) {
            shoulderHeight[z*collisionGrid+x]=(-1...1).flatMap { dz in
                (-1...1).map { dx in surface[(z+dz)*collisionGrid+x+dx] }
            }.max() ?? -2
        }}
        headContactPoints=parts.filter { $0.kind=="head" }.flatMap(\.positions).filter { $0.y<0.65 }
    }
    private func shoulderY(_ point:SIMD3<Float>)->Float {
        let x=(point.x+1.5)*Float(collisionGrid-1)/3,z=(point.z+1.5)*Float(collisionGrid-1)/3
        guard x>=0,z>=0,x<Float(collisionGrid-1),z<Float(collisionGrid-1) else { return -2 }
        let ix=Int(x),iz=Int(z),tx=x-Float(ix),tz=z-Float(iz)
        let a=shoulderHeight[iz*collisionGrid+ix],b=shoulderHeight[iz*collisionGrid+ix+1],
            c=shoulderHeight[(iz+1)*collisionGrid+ix],d=shoulderHeight[(iz+1)*collisionGrid+ix+1]
        return (a+(b-a)*tx)*(1-tz)+(c+(d-c)*tx)*tz
    }
    private func resolveShoulderContact() {
        let transform=head.simdTransform
        if lastContactTransform == transform {
            head.simdPosition.y+=lastContactLift
            return
        }
        // SceneKit getters cross Objective-C and derive quaternions. Capture
        // them once for the entire mesh, preserving the exact vertex formula.
        let position=head.simdPosition,orientation=head.simdOrientation
        var lift:Float=0
        for p in headContactPoints {
            let point=position+orientation.act(p-headCenter)
            lift=max(lift,shoulderY(point)+0.022-point.y)
        }
        lastContactTransform=transform;lastContactLift=lift
        head.simdPosition.y+=lift
        headBodyClearanceValid=true
        if verifyGeometry {
            let lifted=head.simdPosition
            headBodyClearanceValid=headContactPoints.allSatisfy {
                let p=lifted+orientation.act($0-headCenter)
                return p.y>=shoulderY(p)+0.021
            }
        }
    }
    private func updateNeckAttachment() {
        let current=head.simdTransform
        guard lastHeadTransform != current else { return }
        lastHeadTransform=current;neckAttachmentValid=true;neckSurfaceValid=true
        let position=head.simdPosition,headOrientation=head.simdOrientation
        func rest(_ p:SIMD3<Float>)->SIMD3<Float> { headPosition+headRest.act(p-headCenter) }
        func moved(_ p:SIMD3<Float>)->SIMD3<Float> { position+headOrientation.act(p-headCenter) }
        // Transport each cloth ring along the centreline with a quaternion.
        // A blend of rotation matrices pinched the wide collar during yaw.
        let restRotation=simd_float3x3(headRest),rotation=simd_float3x3(headOrientation)
        func blend(_ y:Float)->Float {
            let t=max(0,min(1,(y-neckLower)/(neckUpper-neckLower)))
            return t*t*(3-2*t)
        }
        // Cache one frame per ring: the collar has many angular vertices,
        // but their centreline and quaternion derivative are identical.
        var frames:[Float:(SIMD3<Float>,SIMD3<Float>,simd_float3x3,simd_float3x3)]=[:]
        func frame(_ y:Float)->(SIMD3<Float>,SIMD3<Float>,simd_float3x3,simd_float3x3) {
            if let cached=frames[y] { return cached }
            let t=max(0,min(1,(y-neckLower)/(neckUpper-neckLower)))
            let weight=t*t*(3-2*t)
            let derivative=6*t*(1-t)/(neckUpper-neckLower)
            let center=SIMD3<Float>(0,y,-0.025)
            let a=rest(center),b=moved(center)
            let orientation=simd_float3x3(simd_slerp(headRest,headOrientation,weight))
            let epsilon:Float=0.0005
            let next=simd_float3x3(simd_slerp(headRest,headOrientation,blend(y+epsilon)))
            let prior=simd_float3x3(simd_slerp(headRest,headOrientation,blend(y-epsilon)))
            let value=(a+(b-a)*weight,
                restRotation.columns.1*(1-weight)+rotation.columns.1*weight+(b-a)*derivative,
                orientation,(next-prior)*(1/(2*epsilon)))
            frames[y]=value
            return value
        }
        for part in parts where part.kind=="neck" {
            var positions=part.positions,normals=part.normals
            for i in part.positions.indices {
                let p=part.positions[i]
                let (center,tangent,orientation,derivative)=frame(p.y)
                let offset=SIMD3<Float>(p.x,0,p.z+0.025)
                let position=center+orientation*offset
                let jacobian=simd_float3x3(columns:(
                    orientation.columns.0,tangent+derivative*offset,orientation.columns.2))
                let determinant=simd_determinant(jacobian)
                neckAttachmentValid=neckAttachmentValid && determinant.isFinite && determinant>0.05
                let normal=determinant>0.05
                    ? simd_normalize(simd_transpose(simd_inverse(jacobian))*part.normals[i])
                    : headRest.act(part.normals[i])
                positions[i]=position;normals[i]=normal
                if p.y==neckLower || p.y==neckUpper {
                    neckAttachmentValid=neckAttachmentValid &&
                        simd_distance(position,p.y==neckLower ? rest(p) : moved(p))<0.00001
                }
            }
            if verifyGeometry {
                // Outer triangles must face the transported outward normals;
                // inward winding would disappear with back-face culling.
                for i in stride(from:0,to:neckRings*neckSlices*6,by:3) {
                    let a=Int(part.indices[i]),b=Int(part.indices[i+1]),c=Int(part.indices[i+2])
                    let surface=simd_cross(positions[b]-positions[a],positions[c]-positions[a])
                    neckSurfaceValid=neckSurfaceValid &&
                        simd_dot(surface,normals[a]+normals[b]+normals[c])>0
                }
            }
            let materials=part.node.geometry?.materials ?? []
            part.node.geometry=geometry(part,positions:positions,normals:normals)
            part.node.geometry?.materials=materials
        }
    }
    func pointer(x:Double,y:Double)->(Double,Double) {
        var direction=SIMD4<Float>(Float(x),Float(-y),180,0)
        // Both projection matrices are immutable after construction. Pointer
        // sampling must never read the live SceneKit graph from the UI thread.
        direction=pointerCameraTransform*direction
        direction=headInverse*direction
        let v=simd_normalize(SIMD3(direction.x,direction.y,direction.z))
        return (max(-65,min(65,atan2(Double(v.x),Double(v.z))*180 / .pi)),
                max(-30,min(30,atan2(Double(-v.y),hypot(Double(v.x),Double(v.z)))*180 / .pi)))
    }
    func render(_ pose:MascotPose,size:Int,activity:MascotMotion.Activity)->NSBitmapImageRep? {
        guard ready else { return nil }
        SCNTransaction.begin();SCNTransaction.animationDuration=0
        world.position.y=[MascotMotion.Activity.waiting,.completed].contains(activity) ? 0 : CGFloat(pose.lift/max(1,pixelsPerY))
        let yaw=simd_quatf(angle:Float(pose.yaw * .pi/180),axis:SIMD3(0,1,0))
        let pitch=simd_quatf(angle:Float(pose.pitch * .pi/180),axis:SIMD3(1,0,0))
        head.simdOrientation=headRest*yaw*pitch
        func track(_ key:String)->[Double] {
            guard let frames=activityTracks[activity.rawValue]?[key] as? [[Double]], !frames.isEmpty else { return [0,0] }
            let a=frames[pose.activityFrame%frames.count],b=frames[(pose.activityFrame+1)%frames.count]
            let amount=MascotMotion.smooth(pose.activityProgress)
            return zip(a,b).map { $0+($1-$0)*amount }
        }
        if let frames=activityTracks[activity.rawValue]?["headQuaternion"] as? [[Double]],
           !frames.isEmpty {
            let a=frames[pose.activityFrame%frames.count],b=frames[(pose.activityFrame+1)%frames.count]
            if a.count==4 && b.count==4 {
                func quaternion(_ q:[Double])->simd_quatf {
                    simd_quatf(ix:Float(q[0]),iy:Float(q[1]),iz:Float(q[2]),r:Float(q[3]))
                }
                var q=simd_slerp(quaternion(a),quaternion(b),Float(MascotMotion.smooth(pose.activityProgress)))
                if activity == .voice {
                    q=simd_slerp(simd_quatf(angle:0,axis:SIMD3(0,1,0)),q,Float(0.18+0.82*pose.voiceLevel))
                }
                head.simdOrientation=headRest*q*yaw*pitch
            }
        }
        let h=track("head"),sourceUnits=80/max(1,pixelsPerY)
        let response=activity == .voice ? 0.18+0.82*pose.voiceLevel : 1
        let base=headPosition
        head.position=SCNVector3(Double(base.x)+h[0]*sourceUnits*response,
            Double(base.y)-h[1]*sourceUnits*response,Double(base.z))
        resolveShoulderContact()
        updateNeckAttachment()
        expressionNodes.forEach { $0.opacity=CGFloat(pose.expression) }
        concernedBrows.forEach { $0.opacity=activity == .superBusy ? 1 : 0 }
        concernGlow?.light?.intensity=activity == .superBusy ? 1 : 0
        if lastPose?.blink != pose.blink { facialSurfaceValid=true }
        for part in parts {
            if part.node.name=="macbook-apple-logo" || part.node.name=="macbook-apple-leaf" {
                part.node.geometry?.firstMaterial?.emission.intensity=CGFloat(pose.logoIntensity)
            }
            if part.kind=="laptop" {
                part.node.isHidden=activity == .voice
                let a=track("laptop")
                part.node.position=SCNVector3(a[0]*sourceUnits,-a[1]*sourceUnits,0)
            }
            if part.kind.hasPrefix("voice") { part.node.isHidden=activity != .voice }
            if part.kind=="voiceBoard" {
                let a=track("board");part.node.position=SCNVector3(a[0]*sourceUnits,-a[1]*sourceUnits,0)
            }
            if part.kind=="voicePen" {
                let a=track("pen");part.node.position=SCNVector3(a[0]*sourceUnits,-a[1]*sourceUnits,0)
            }
            if activity == .voice && (part.kind=="voiceArmLeft" || part.kind=="voiceArmRight") {
                let a=track(part.kind=="voiceArmRight" ? "pen" : "leftArm")
                if lastActivity != activity || lastPose?.activityFrame != pose.activityFrame ||
                    lastPose?.activityProgress != pose.activityProgress {
                    let delta=SIMD3<Float>(Float(a[0]*sourceUnits),Float(-a[1]*sourceUnits),0)
                    let p=part.positions.map { position -> SIMD3<Float> in
                        let blend=Float(MascotMotion.smooth(Double((position.z+0.10)/0.55)))
                        return position+delta*blend
                    }
                    let materials=part.node.geometry!.materials
                    part.node.geometry=geometry(part,positions:p,normals:part.normals)
                    part.node.geometry?.materials=materials
                }
            }
            if part.kind.hasPrefix("arm") {
                let a=track(part.kind=="armLeft" ? "leftArm" : "rightArm")
                part.node.isHidden=activity == .voice
                let delta=SIMD3<Float>(Float(a[0]*sourceUnits),Float(-a[1]*sourceUnits),0)
                if activity != .voice && (lastActivity != activity || lastPose?.activityFrame != pose.activityFrame ||
                    lastPose?.activityProgress != pose.activityProgress) {
                // Pin sleeves at the shoulder while the fingertip follows the
                // source typing trajectory; moving the complete limb detaches it.
                let p=part.positions.map { position -> SIMD3<Float> in
                    let blend=Float(MascotMotion.smooth(Double((position.z+0.10)/0.55)))
                    return position+delta*blend
                }
                let materials=part.node.geometry!.materials
                part.node.geometry=geometry(part,positions:p,normals:part.normals)
                part.node.geometry?.materials=materials
                }
            }
            if part.kind.hasPrefix("leg") && (lastPose?.legScale != pose.legScale || lastPose?.legAngle != pose.legAngle) {
                let scale=Float(pose.legScale),angle=Float(pose.legAngle)
                let r=sin(part.kind=="legLeft" ? -angle : angle),t=hip*(1-scale)
                let p=part.positions.map { SIMD3($0.x,$0.y*scale+t,$0.z+r*max(0,attachment-$0.y)) }
                let n=part.normals.enumerated().map { i,v -> SIMD3<Float> in
                    let shear:Float=part.positions[i].y<=attachment ? -r : 0
                    return simd_normalize(SIMD3(v.x,(v.y-shear*v.z)/max(0.01,scale),v.z))
                }
                let mat=part.node.geometry!.materials
                part.node.geometry=geometry(part,positions:p,normals:n);part.node.geometry?.materials=mat
            }
            if part.kind.hasPrefix("eye") {
                if lastPose?.blink != pose.blink {
                    let scale=Float(max(0.04,1-pose.blink*0.96))
                    var p:[SIMD3<Float>]=[],n:[SIMD3<Float>]=[]
                    for point in part.positions {
                        let base=faceSurface(x:point.x,y:point.y,offset:0).0
                        let offset=max(0.007,simd_length(point-base))
                        let (position,normal)=faceSurface(x:point.x,y:0.352+(point.y-0.352)*scale,offset:offset)
                        p.append(position);n.append(normal)
                    }
                    let mat=part.node.geometry!.materials
                    part.node.geometry=geometry(part,positions:p,normals:n);part.node.geometry?.materials=mat
                    facialSurfaceValid=facialSurfaceValid && p.allSatisfy { point in
                        let implicit=pow(point.x/0.67,2)+pow((point.y-0.505)/0.50,2)+pow((point.z-0.005)/0.47,2)
                        return implicit>1.005 && implicit<1.14
                    }
                }
                part.node.opacity=CGFloat(1-pose.expression)
            }
        }
        SCNTransaction.commit()
        let image=renderer.snapshot(atTime:0,with:NSSize(width:size,height:size),antialiasingMode:.multisampling4X)
        // Check actual deformed mesh vertices. Rotating a local bounding box
        // creates empty corners outside the viewport even when the mesh fits.
        if verifyGeometry {
        let viewProjection=simd_float4x4(camera.camera!.projectionTransform)*simd_inverse(camera.simdWorldTransform)
        geometryInsideFrustum=parts.filter { !$0.node.isHidden }.allSatisfy { part in
            guard let source=part.node.geometry?.sources(for:.vertex).first else { return false }
            let transform=viewProjection*part.node.simdWorldTransform
            return source.data.withUnsafeBytes { bytes in
                (0..<source.vectorCount).allSatisfy { i in
                    let offset=source.dataOffset+i*source.dataStride
                    let x=bytes.loadUnaligned(fromByteOffset:offset,as:Float.self)
                    let y=bytes.loadUnaligned(fromByteOffset:offset+4,as:Float.self)
                    let z=bytes.loadUnaligned(fromByteOffset:offset+8,as:Float.self)
                    let p=transform*SIMD4(x,y,z,1)
                    return p.w>0 && abs(p.x)<p.w && abs(p.y)<p.w && abs(p.z)<p.w
                }
            }
        }
        }
        guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return nil }
        lastPose=pose;lastActivity=activity
        guard let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,
            samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
            let context=NSGraphicsContext(bitmapImageRep:rep) else { return nil }
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        let c=context.cgContext
        c.clear(CGRect(x:0,y:0,width:size,height:size));c.setAlpha(pose.opacity)
        let feedback=activity == .waiting || activity == .completed
        c.translateBy(x:CGFloat(size)/2,y:CGFloat(size)*0.48)
        c.rotate(by: -pose.rotation * .pi/180)
        if feedback { c.translateBy(x:0,y:pose.lift*Double(size)/85) }
        // The centred sweep retains a small transparent interaction margin.
        c.scaleBy(x:0.96,y:0.96)
        c.draw(cg,in:CGRect(x:-CGFloat(size)/2,y:-CGFloat(size)/2,width:CGFloat(size),height:CGFloat(size)))
        NSGraphicsContext.restoreGraphicsState();return rep
    }
}

private func SCNMatrix4MakePerspective(_ fov:Double,_ aspect:Double,_ near:Double,_ far:Double)->SCNMatrix4 {
    let f=1/tan(fov/2)
    return SCNMatrix4(m11:CGFloat(f/aspect),m12:0,m13:0,m14:0,m21:0,m22:CGFloat(f),m23:0,m24:0,
        m31:0,m32:0,m33:CGFloat((far+near)/(near-far)),m34:-1,m41:0,m42:0,m43:CGFloat(2*far*near/(near-far)),m44:0)
}
