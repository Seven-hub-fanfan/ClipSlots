import Foundation
import SceneKit
import AppKit
import simd
import ObjectiveC

private var glbDataKey: UInt8 = 0
extension SCNNode {
    var clipslotsGLBData: NSMutableDictionary {
        if let value=objc_getAssociatedObject(self,&glbDataKey) as? NSMutableDictionary { return value }
        let value=NSMutableDictionary()
        objc_setAssociatedObject(self,&glbDataKey,value,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }
}

/// GLB 2.0 decoding from the actual embedded buffers, rather than a thumbnail.
/// Embedded textures, sparse accessors, skinning and animation are decoded
/// locally. Unsupported compression fails explicitly.
public enum CanvasGLBScene {
    public static func sample(node:SCNNode,time:Double,animationIndex:Int=0) throws {
        if let playback=node.clipslotsGLBData["clipslots-glb-animation"] as? Playback {
            try playback.sample(time:time,index:animationIndex)
        }
    }
    public static func animationCount(_ node:SCNNode) -> Int {
        (node.clipslotsGLBData["clipslots-glb-animation"] as? Playback)?.clips.count ?? 0
    }
    public static func animationDuration(_ node:SCNNode,index:Int=0) -> Double {
        guard let playback=node.clipslotsGLBData["clipslots-glb-animation"] as? Playback,
              playback.clips.indices.contains(index) else { return 0 }
        return Double(playback.clips[index].map {$0.times.last ?? 0}.max() ?? 0)
    }
    private final class Playback: NSObject {
        struct Channel {
            let node:SCNNode,path:String,times:[Float],values:[Float],components:Int,interpolation:String
        }
        let clips:[[Channel]]
        let baseline:[(SCNNode,simd_float4x4,[SCNNode:[NSNumber]])]
        init(clips:[[Channel]],nodes:[SCNNode]) {
            self.clips=clips
            baseline=nodes.map { node in
                var weights:[SCNNode:[NSNumber]]=[:]
                node.enumerateChildNodes { child,_ in if let morpher=child.morpher { weights[child]=morpher.weights } }
                return (node,node.simdTransform,weights)
            }
        }
        func sample(time:Double,index:Int) throws {
            guard time.isFinite else { throw failure("动画时间无效") }
            guard !clips.isEmpty else { return }
            guard clips.indices.contains(index) else { throw failure("模型不存在该动画编号") }
            for (node,transform,weights) in baseline {
                node.simdTransform=transform
                for (child,values) in weights { child.morpher?.weights=values }
            }
            let clip=clips[index],duration=clip.map {$0.times.last ?? 0}.max() ?? 0
            let t=duration>0 ? Float(max(0,time).truncatingRemainder(dividingBy:Double(duration))) : 0
            for channel in clip {
                guard !channel.times.isEmpty else { continue }
                let a=channel.times.lastIndex(where:{$0<=t}) ?? 0,b=min(a+1,channel.times.count-1)
                let delta=channel.times[b]-channel.times[a]
                let f=delta>0 ? max(0,min(1,(t-channel.times[a])/delta)) : 0
                let cubic=channel.interpolation=="CUBICSPLINE",n=channel.components
                func value(_ frame:Int,_ part:Int=1) -> [Float] {
                    let start=(frame * (cubic ? 3 : 1)+(cubic ? part : 0))*n
                    return Array(channel.values[start..<start+n])
                }
                let va=value(a),vb=value(b)
                var result=va
                if a != b && channel.interpolation != "STEP" {
                    if cubic {
                        let out=value(a,2),into=value(b,0),f2=f*f,f3=f*f*f
                        let h00=2*f3-3*f2+1,h10=f3-2*f2+f,h01 = -2*f3+3*f2,h11=f3-f2
                        result=(0..<n).map { i in
                            let p=h00*va[i]+h10*delta*out[i]
                            let q=h01*vb[i]+h11*delta*into[i]
                            return p+q
                        }
                    } else if channel.path=="rotation" {
                        let qa=simd_normalize(simd_quatf(vector:SIMD4(va[0],va[1],va[2],va[3])))
                        let qb=simd_normalize(simd_quatf(vector:SIMD4(vb[0],vb[1],vb[2],vb[3])))
                        let q=simd_slerp(qa,qb,f).vector;result=[q.x,q.y,q.z,q.w]
                    } else { result=(0..<n).map {va[$0]+(vb[$0]-va[$0])*f} }
                }
                switch channel.path {
                case "translation":channel.node.simdPosition=SIMD3(result[0],result[1],result[2])
                case "scale":channel.node.simdScale=SIMD3(result[0],result[1],result[2])
                case "rotation":
                    let q=SIMD4(result[0],result[1],result[2],result[3])
                    guard simd_length_squared(q)>1e-8 else { throw failure("动画四元数无效") }
                    channel.node.simdOrientation=simd_normalize(simd_quatf(vector:q))
                case "weights":
                    channel.node.enumerateChildNodes { child,_ in
                        if child.morpher?.targets.count==result.count { child.morpher?.weights=result.map {NSNumber(value:$0)} }
                    }
                default:break
                }
            }
        }
    }
    public static func load(_ url: URL, name: String) throws -> SCNScene {
        if (name as NSString).pathExtension.lowercased() != "glb" {
            if url.pathExtension.lowercased() == "bin" {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipslots-3d-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let staged = directory.appendingPathComponent((name as NSString).lastPathComponent)
                try FileManager.default.copyItem(at: url, to: staged)
                return try SCNScene(url: staged, options: [.checkConsistency: true])
            }
            return try SCNScene(url: url, options: [.checkConsistency: true])
        }
        return try decode(Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func decode(_ data: Data) throws -> SCNScene {
        let bytes = [UInt8](data)
        guard bytes.count >= 20, bytes.count <= 512 * 1024 * 1024,
              u32(bytes, 0) == 0x46546c67, u32(bytes, 4) == 2,
              Int(u32(bytes, 8)) == bytes.count else { throw failure("GLB 文件头无效") }
        var cursor = 12, json: [String: Any]?, binary = [UInt8]()
        while cursor + 8 <= bytes.count {
            let length = Int(u32(bytes, cursor)), type = u32(bytes, cursor + 4); cursor += 8
            guard length <= bytes.count - cursor, length % 4 == 0 else { throw failure("GLB 区块越界") }
            if type == 0x4e4f534a {
                guard json == nil, length <= 16 * 1024 * 1024 else { throw failure("GLB JSON 无效") }
                json = try JSONSerialization.jsonObject(with: Data(bytes[cursor..<cursor + length])) as? [String: Any]
            } else if type == 0x004e4942 {
                guard binary.isEmpty else { throw failure("GLB 包含重复缓冲区") }
                binary = Array(bytes[cursor..<cursor + length])
            }
            cursor += length
        }
        guard cursor == bytes.count, let root = json else { throw failure("GLB 内容不完整") }
        let decoder = Decoder(root: root, binary: binary)
        return try decoder.scene()
    }

    private static func failure(_ message: String) -> CanvasToolError { .invalid(message) }
    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private struct Decoder {
        let root: [String: Any]; let binary: [UInt8]
        func objects(_ key: String) -> [[String: Any]] { root[key] as? [[String: Any]] ?? [] }
        func integer(_ object: [String: Any], _ key: String, _ fallback: Int = 0) -> Int {
            (object[key] as? NSNumber)?.intValue ?? fallback
        }
        func floats(_ object: [String: Any], _ key: String, count: Int, fallback: [Float]) throws -> [Float] {
            guard let numbers = object[key] as? [NSNumber] else { return fallback }
            let values = numbers.map(\.floatValue)
            guard values.count == count, values.allSatisfy(\.isFinite) else { throw failure("GLB 变换或材质参数无效") }
            return values
        }
        func bufferView(_ index: Int) throws -> (offset: Int, length: Int, stride: Int) {
            let views = objects("bufferViews")
            guard views.indices.contains(index) else { throw failure("GLB bufferView 不存在") }
            let view = views[index], offset = integer(view, "byteOffset"), length = integer(view, "byteLength")
            let stride = integer(view, "byteStride")
            guard integer(view, "buffer") == 0, offset >= 0, length >= 0,
                  offset <= binary.count, length <= binary.count - offset,
                  stride == 0 || (4...252).contains(stride) else { throw failure("GLB 缓冲区越界") }
            return (offset, length, stride)
        }
        func accessor(_ index: Int, components expected: Int) throws -> (values: [Float], count: Int) {
            let accessors = objects("accessors")
            guard accessors.indices.contains(index) else { throw failure("GLB accessor 不存在") }
            let accessor = accessors[index], component = integer(accessor, "componentType")
            let counts = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4,"MAT4":16]
            let components = counts[accessor["type"] as? String ?? ""] ?? 0
            let count = integer(accessor, "count")
            let width = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][component] ?? 0
            guard count>0,count<=5_000_000,components==expected,width>0 else { throw failure("GLB accessor 类型无效") }
            let hasView=accessor["bufferView"] != nil
            let view = hasView ? try bufferView(integer(accessor, "bufferView", -1)) : (offset:0,length:0,stride:0)
            let offset = integer(accessor, "byteOffset"), element = width * components
            let stride = view.stride == 0 ? element : view.stride
            guard count > 0, count <= 5_000_000, components == expected, width > 0,
                  offset >= 0, offset <= view.length, stride >= element,
                  !hasView || (element <= view.length - offset &&
                  count - 1 <= (view.length - offset - element) / max(1, stride))
            else { throw failure("GLB 顶点数据越界或过大") }
            let normalized = accessor["normalized"] as? Bool ?? false
            var values = [Float](); values.reserveCapacity(count * components)
            for index in 0..<(hasView ? count : 0) {
                if index % 8192 == 0 { try Task.checkCancellation() }
                for axis in 0..<components {
                    let start = view.offset + offset + index * stride + axis * width
                    var value: Float
                    switch component {
                    case 5120: value = Float(Int8(bitPattern: binary[start])); if normalized { value = max(-1, value / 127) }
                    case 5121: value = Float(binary[start]); if normalized { value /= 255 }
                    case 5122:
                        value = Float(Int16(bitPattern: UInt16(binary[start]) | UInt16(binary[start + 1]) << 8))
                        if normalized { value = max(-1, value / 32767) }
                    case 5123:
                        value = Float(UInt16(binary[start]) | UInt16(binary[start + 1]) << 8)
                        if normalized { value /= 65535 }
                    case 5125: value = Float(u32(binary, start))
                    default: value = Float(bitPattern: u32(binary, start))
                    }
                    guard value.isFinite else { throw failure("GLB 顶点包含非有限值") }
                    values.append(value)
                }
            }
            if !hasView { values=[Float](repeating:0,count:count*components) }
            if let sparse=accessor["sparse"] as? [String:Any] {
                let sparseCount=integer(sparse,"count")
                guard sparseCount>0,sparseCount<=count,let indices=sparse["indices"] as? [String:Any],
                      let replacements=sparse["values"] as? [String:Any] else { throw failure("稀疏 accessor 无效") }
                let indexType=integer(indices,"componentType")
                guard let indexWidth=[5121:1,5123:2,5125:4][indexType] else { throw failure("稀疏索引类型无效") }
                let iv=try bufferView(integer(indices,"bufferView",-1)),vv=try bufferView(integer(replacements,"bufferView",-1))
                let io=integer(indices,"byteOffset"),vo=integer(replacements,"byteOffset")
                guard io>=0,vo>=0,io<=iv.length,vo<=vv.length,
                      sparseCount<=(iv.length-io)/indexWidth,sparseCount<=(vv.length-vo)/element else { throw failure("稀疏 accessor 越界") }
                var previous = -1
                for i in 0..<sparseCount {
                    let pos=iv.offset+io+i*indexWidth
                    let idx=indexWidth==1 ? Int(binary[pos]) : indexWidth==2 ? Int(UInt16(binary[pos]) | UInt16(binary[pos+1])<<8) : Int(u32(binary,pos))
                    guard idx>previous,idx<count else { throw failure("稀疏索引重复或越界") };previous=idx
                    for c in 0..<components {
                        let start=vv.offset+vo+i*element+c*width
                        var value:Float
                        switch component {
                        case 5120:value=Float(Int8(bitPattern:binary[start]));if normalized {value=max(-1,value/127)}
                        case 5121:value=Float(binary[start]);if normalized {value/=255}
                        case 5122:value=Float(Int16(bitPattern:UInt16(binary[start]) | UInt16(binary[start+1])<<8));if normalized {value=max(-1,value/32767)}
                        case 5123:value=Float(UInt16(binary[start]) | UInt16(binary[start+1])<<8);if normalized {value/=65535}
                        case 5125:value=Float(u32(binary,start))
                        default:value=Float(bitPattern:u32(binary,start))
                        }
                        guard value.isFinite else {throw failure("稀疏数据无效")};values[idx*components+c]=value
                    }
                }
            }
            return (values, count)
        }
        func source(_ values: [Float], count: Int, components: Int, semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            let data = values.withUnsafeBytes { Data($0) }
            return SCNGeometrySource(data: data, semantic: semantic, vectorCount: count,
                usesFloatComponents: true, componentsPerVector: components,
                bytesPerComponent: 4, dataOffset: 0, dataStride: components * 4)
        }
        func material(_ index: Int?) throws -> SCNMaterial {
            let material = SCNMaterial(); material.lightingModel = .physicallyBased
            let materials = objects("materials")
            guard let index, materials.indices.contains(index) else {
                material.diffuse.contents = NSColor(white: 0.7, alpha: 1); return material
            }
            let config = materials[index], pbr = config["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            let rgba = try floats(pbr, "baseColorFactor", count: 4, fallback: [1, 1, 1, 1])
            material.diffuse.contents = NSColor(red: CGFloat(rgba[0]), green: CGFloat(rgba[1]), blue: CGFloat(rgba[2]), alpha: CGFloat(rgba[3]))
            material.metalness.contents = (pbr["metallicFactor"] as? NSNumber)?.doubleValue ?? 1
            material.roughness.contents = (pbr["roughnessFactor"] as? NSNumber)?.doubleValue ?? 1
            if let texture=pbr["metallicRoughnessTexture"] as? [String:Any] {
                let image=try textureImage(integer(texture,"index",-1))
                material.roughness.contents=image;material.roughness.textureComponents = .green
                material.metalness.contents=image;material.metalness.textureComponents = .blue
            }
            if let texture=config["normalTexture"] as? [String:Any] {
                material.normal.contents=try textureImage(integer(texture,"index",-1))
                material.normal.intensity=CGFloat((texture["scale"] as? NSNumber)?.doubleValue ?? 1)
            }
            if let texture=config["occlusionTexture"] as? [String:Any] {
                material.ambientOcclusion.contents=try textureImage(integer(texture,"index",-1))
                material.ambientOcclusion.textureComponents = .red
                material.ambientOcclusion.intensity=CGFloat((texture["strength"] as? NSNumber)?.doubleValue ?? 1)
            }
            material.isDoubleSided = config["doubleSided"] as? Bool ?? false
            if config["alphaMode"] as? String == "BLEND" { material.transparency = CGFloat(rgba[3]); material.writesToDepthBuffer = false }
            if let texture = pbr["baseColorTexture"] as? [String: Any],
               let image = try textureImage(integer(texture, "index", -1)) {
                material.diffuse.contents = image
                material.multiply.contents = NSColor(red: CGFloat(rgba[0]), green: CGFloat(rgba[1]), blue: CGFloat(rgba[2]), alpha: CGFloat(rgba[3]))
            }
            let emissive = try floats(config, "emissiveFactor", count: 3, fallback: [0, 0, 0])
            material.emission.contents = NSColor(red: CGFloat(emissive[0]), green: CGFloat(emissive[1]), blue: CGFloat(emissive[2]), alpha: 1)
            if let texture=config["emissiveTexture"] as? [String:Any] {
                material.emission.contents=try textureImage(integer(texture,"index",-1))
                material.emission.intensity=CGFloat(emissive.max() ?? 1)
            }
            if (config["extensions"] as? [String:Any])?["KHR_materials_unlit"] != nil { material.lightingModel = .constant }
            return material
        }
        func textureImage(_ index: Int) throws -> NSImage? {
            let textures = objects("textures"), images = objects("images")
            guard textures.indices.contains(index) else { throw failure("GLB 纹理不存在") }
            let imageIndex = integer(textures[index], "source", -1)
            guard images.indices.contains(imageIndex) else { throw failure("GLB 图片不存在") }
            let image = images[imageIndex]
            if let uri = image["uri"] as? String, uri.hasPrefix("data:"), let separator = uri.firstIndex(of: ","),
               let data = Data(base64Encoded: String(uri[uri.index(after: separator)...])) {
                guard data.count <= 32 * 1024 * 1024 else { throw failure("GLB 图片过大") }
                return NSImage(data: data)
            }
            guard image["uri"] == nil else { throw failure("GLB 外部纹理需先嵌入模型") }
            let view = try bufferView(integer(image, "bufferView", -1))
            guard view.length <= 32 * 1024 * 1024 else { throw failure("GLB 图片过大") }
            return NSImage(data: Data(binary[view.offset..<view.offset + view.length]))
        }
        func mesh(_ index: Int) throws -> SCNNode {
            let meshes = objects("meshes")
            guard meshes.indices.contains(index), let primitives = meshes[index]["primitives"] as? [[String: Any]],
                  !primitives.isEmpty, primitives.count <= 1024 else { throw failure("GLB mesh 无效") }
            let parent = SCNNode()
            for primitive in primitives {
                guard integer(primitive, "mode", 4) == 4,
                      (primitive["extensions"] as? [String: Any])?["KHR_draco_mesh_compression"] == nil,
                      let attributes = primitive["attributes"] as? [String: Int],
                      let positionID = attributes["POSITION"] else {
                    throw failure("模型需转换为未压缩的三角形 GLB")
                }
                let positions = try accessor(positionID, components: 3)
                var sources = [source(positions.values, count: positions.count, components: 3, semantic: .vertex)]
                var indices: [UInt32]
                if let index = primitive["indices"] as? Int {
                    let accessors = objects("accessors")
                    guard accessors.indices.contains(index), [5121,5123,5125].contains(integer(accessors[index], "componentType")) else {
                        throw failure("GLB 索引类型无效")
                    }
                    // Float32 cannot exactly encode very large indices. The vertex
                    // bound above is below 2^24, so every legal index is exact.
                    let decoded = try accessor(index, components: 1).values
                    guard decoded.allSatisfy({ $0 >= 0 && $0 < Float(positions.count) && $0.rounded() == $0 }) else {
                        throw failure("GLB 三角形索引越界")
                    }
                    indices = decoded.map { UInt32($0) }
                } else { indices = (0..<positions.count).map(UInt32.init) }
                guard indices.count % 3 == 0 else { throw failure("GLB 三角形数量无效") }
                if let normalID = attributes["NORMAL"] {
                    let normals = try accessor(normalID, components: 3)
                    guard normals.count == positions.count else { throw failure("GLB 法线数量无效") }
                    sources.append(source(normals.values, count: normals.count, components: 3, semantic: .normal))
                } else {
                    var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
                    func point(_ index: Int) -> SIMD3<Float> {
                        SIMD3(positions.values[index * 3], positions.values[index * 3 + 1], positions.values[index * 3 + 2])
                    }
                    for start in stride(from: 0, to: indices.count, by: 3) {
                        let a = Int(indices[start]), b = Int(indices[start + 1]), c = Int(indices[start + 2])
                        let normal = simd_cross(point(b) - point(a), point(c) - point(a))
                        normals[a] += normal; normals[b] += normal; normals[c] += normal
                    }
                    let values = normals.flatMap { normal -> [Float] in
                        let unit = simd_length_squared(normal) > 1e-12 ? simd_normalize(normal) : SIMD3<Float>(0, 1, 0)
                        return [unit.x, unit.y, unit.z]
                    }
                    sources.append(source(values, count: positions.count, components: 3, semantic: .normal))
                }
                if let uvID = attributes["TEXCOORD_0"] {
                    var uv = try accessor(uvID, components: 2)
                    guard uv.count == positions.count else { throw failure("GLB UV 数量无效") }
                    for index in stride(from: 1, to: uv.values.count, by: 2) { uv.values[index] = 1 - uv.values[index] }
                    sources.append(source(uv.values, count: uv.count, components: 2, semantic: .texcoord))
                }
                if let colorID = attributes["COLOR_0"] {
                    let type = objects("accessors").indices.contains(colorID) ? objects("accessors")[colorID]["type"] as? String : nil
                    let color = try accessor(colorID, components: type == "VEC4" ? 4 : 3)
                    guard color.count == positions.count else { throw failure("GLB 颜色数量无效") }
                    sources.append(source(color.values, count: color.count, components: type == "VEC4" ? 4 : 3, semantic: .color))
                }
                let element = SCNGeometryElement(data: indices.withUnsafeBytes { Data($0) }, primitiveType: .triangles,
                    primitiveCount: indices.count / 3, bytesPerIndex: 4)
                let geometry = SCNGeometry(sources: sources, elements: [element])
                geometry.materials = [try material(primitive["material"] as? Int)]
                let output=SCNNode(geometry:geometry)
                if let targets=primitive["targets"] as? [[String:Int]] {
                    guard targets.count<=64 else { throw failure("形变目标过多") }
                    let morpher=SCNMorpher();morpher.calculationMode = .additive
                    morpher.targets=try targets.map { target in
                        var targetSources=sources
                        for (attribute,semantic,baseID) in [("POSITION",SCNGeometrySource.Semantic.vertex,positionID),("NORMAL",.normal,attributes["NORMAL"] ?? -1)] {
                            guard let id=target[attribute] else { continue }
                            let deltas=try accessor(id,components:3)
                            guard deltas.count==positions.count else { throw failure("形变顶点数不匹配") }
                            let base=baseID>=0 ? try accessor(baseID,components:3).values : [Float](repeating:0,count:deltas.values.count)
                            let absolute=zip(base,deltas.values).map(+)
                            targetSources.removeAll {$0.semantic==semantic}
                            targetSources.append(source(absolute,count:positions.count,components:3,semantic:semantic))
                        }
                        return SCNGeometry(sources:targetSources,elements:[element])
                    }
                    output.morpher=morpher
                    let weights=meshes[index]["weights"] as? [NSNumber] ?? Array(repeating:NSNumber(value:0),count:targets.count)
                    guard weights.count==targets.count,weights.allSatisfy({$0.doubleValue.isFinite}) else { throw failure("形变权重无效") }
                    morpher.weights=weights
                }
                if let jointsID=attributes["JOINTS_0"],let weightsID=attributes["WEIGHTS_0"] {
                    let joints=try accessor(jointsID,components:4),weights=try accessor(weightsID,components:4)
                    guard joints.count==positions.count,weights.count==positions.count,
                          joints.values.allSatisfy({$0>=0 && $0<=65535 && $0.rounded()==$0}),
                          weights.values.allSatisfy({$0>=0}) else { throw failure("骨骼权重或索引无效") }
                    output.clipslotsGLBData["glb-joints"]=joints.values.map {NSNumber(value:$0)}
                    output.clipslotsGLBData["glb-weights"]=weights.values.map {NSNumber(value:$0)}
                }
                parent.addChildNode(output)
            }
            return parent
        }
        func scene() throws -> SCNScene {
            let scene = SCNScene(), configs = objects("nodes")
            let supported=Set(["KHR_materials_unlit"])
            guard (root["extensionsRequired"] as? [String] ?? []).allSatisfy({supported.contains($0)}) else {
                throw failure("GLB 必需扩展暂不支持，请导出未压缩的标准 GLB")
            }
            guard configs.count <= 10000 else { throw failure("GLB 节点过多") }
            var visiting = Set<Int>(), used = Set<Int>(),built=[Int:SCNNode]()
            func node(_ index: Int, depth: Int) throws -> SCNNode {
                guard configs.indices.contains(index), depth < 128, !visiting.contains(index), !used.contains(index) else {
                    throw failure("GLB 节点图循环或重复引用")
                }
                visiting.insert(index); used.insert(index); defer { visiting.remove(index) }
                let config = configs[index], output = SCNNode(); output.name = config["name"] as? String
                built[index]=output
                if config["matrix"] != nil {
                    let m = try floats(config, "matrix", count: 16, fallback: [])
                    output.simdTransform = simd_float4x4(columns: (SIMD4(m[0],m[1],m[2],m[3]),
                        SIMD4(m[4],m[5],m[6],m[7]), SIMD4(m[8],m[9],m[10],m[11]), SIMD4(m[12],m[13],m[14],m[15])))
                } else {
                    let t = try floats(config, "translation", count: 3, fallback: [0,0,0])
                    let r = try floats(config, "rotation", count: 4, fallback: [0,0,0,1])
                    let s = try floats(config, "scale", count: 3, fallback: [1,1,1])
                    output.simdPosition = SIMD3(t[0],t[1],t[2]); output.simdScale = SIMD3(s[0],s[1],s[2])
                    let q = SIMD4<Float>(r[0],r[1],r[2],r[3])
                    guard simd_length_squared(q) > 1e-8 else { throw failure("GLB 四元数无效") }
                    output.simdOrientation = simd_normalize(simd_quatf(vector: q))
                }
                if let meshID = config["mesh"] as? Int { output.addChildNode(try mesh(meshID)) }
                if let weights=config["weights"] as? [NSNumber] {
                    output.enumerateChildNodes { child,_ in if child.morpher?.targets.count==weights.count { child.morpher?.weights=weights } }
                }
                for child in config["children"] as? [Int] ?? [] { output.addChildNode(try node(child, depth: depth + 1)) }
                return output
            }
            let scenes = objects("scenes"), selected = integer(root, "scene")
            let roots: [Int]
            if scenes.indices.contains(selected) { roots = scenes[selected]["nodes"] as? [Int] ?? [] }
            else {
                let children = Set(configs.flatMap { $0["children"] as? [Int] ?? [] })
                roots = configs.indices.filter { !children.contains($0) }
            }
            guard !roots.isEmpty else { throw failure("GLB 没有可显示场景") }
            for index in roots { scene.rootNode.addChildNode(try node(index, depth: 0)) }
            for (index,output) in built {
                guard let skinID=configs[index]["skin"] as? Int else { continue }
                let skins=objects("skins")
                guard skins.indices.contains(skinID),let joints=skins[skinID]["joints"] as? [Int],
                      !joints.isEmpty,joints.count<=512 else { throw failure("骨骼定义无效") }
                let bones=try joints.map { id -> SCNNode in guard let bone=built[id] else {throw failure("骨骼不在场景内")};return bone }
                var transforms=[SCNMatrix4](repeating:SCNMatrix4Identity,count:bones.count)
                if let id=skins[skinID]["inverseBindMatrices"] as? Int {
                    let values=try accessor(id,components:16)
                    guard values.count==bones.count else {throw failure("骨骼矩阵数量无效")}
                    transforms=(0..<bones.count).map { i in let m=Array(values.values[i*16..<i*16+16])
                        return SCNMatrix4(simd_float4x4(columns:(SIMD4(m[0],m[1],m[2],m[3]),SIMD4(m[4],m[5],m[6],m[7]),SIMD4(m[8],m[9],m[10],m[11]),SIMD4(m[12],m[13],m[14],m[15])))) }
                }
                var primitives=[SCNNode]()
                output.enumerateChildNodes { child,_ in if child.clipslotsGLBData["glb-joints"] != nil {primitives.append(child)} }
                for primitive in primitives {
                    guard let geometry=primitive.geometry,let numbers=primitive.clipslotsGLBData["glb-joints"] as? [NSNumber],
                          let weightNumbers=primitive.clipslotsGLBData["glb-weights"] as? [NSNumber] else {throw failure("骨骼属性缺失")}
                    let indices=numbers.map(\.int32Value);var weights=weightNumbers.map(\.floatValue)
                    guard indices.allSatisfy({$0>=0 && $0<Int32(bones.count)}) else {throw failure("骨骼索引越界")}
                    for start in stride(from:0,to:weights.count,by:4) {
                        let sum=weights[start..<start+4].reduce(0,+);guard sum>0 else {throw failure("骨骼权重为零")}
                        for axis in 0..<4 {weights[start+axis]/=sum}
                    }
                    let indexSource=SCNGeometrySource(data:indices.withUnsafeBytes {Data($0)},semantic:.boneIndices,
                        vectorCount:indices.count/4,usesFloatComponents:false,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16)
                    primitive.skinner=SCNSkinner(baseGeometry:geometry,bones:bones,
                        boneInverseBindTransforms:transforms.map {NSValue(scnMatrix4:$0)},
                        boneWeights:source(weights,count:weights.count/4,components:4,semantic:.boneWeights),boneIndices:indexSource)
                    if let skeleton=skins[skinID]["skeleton"] as? Int {primitive.skinner?.skeleton=built[skeleton]}
                    primitive.clipslotsGLBData.removeObject(forKey:"glb-joints")
                    primitive.clipslotsGLBData.removeObject(forKey:"glb-weights")
                }
            }
            var clips=[[Playback.Channel]]()
            for animation in objects("animations") {
                guard clips.count<100,let channels=animation["channels"] as? [[String:Any]],
                      let samplers=animation["samplers"] as? [[String:Any]],channels.count<=10000 else {throw failure("动画轨道过多或无效")}
                var clip=[Playback.Channel]()
                for channel in channels {
                    guard let target=channel["target"] as? [String:Any],let id=target["node"] as? Int,
                          let output=built[id],let path=target["path"] as? String,["translation","rotation","scale","weights"].contains(path)
                    else {throw failure("动画目标无效")}
                    let samplerID=integer(channel,"sampler",-1)
                    guard samplers.indices.contains(samplerID) else {throw failure("动画采样器不存在")}
                    let sampler=samplers[samplerID],times=try accessor(integer(sampler,"input",-1),components:1).values
                    guard times.count<=100000,times.first ?? -1 >= 0,
                          zip(times,times.dropFirst()).allSatisfy({$0<$1}) else {throw failure("动画时间无效")}
                    let interpolation=sampler["interpolation"] as? String ?? "LINEAR"
                    guard ["LINEAR","STEP","CUBICSPLINE"].contains(interpolation) else {throw failure("动画插值不支持")}
                    let n:Int
                    if path=="weights" {
                        var count=0;output.enumerateChildNodes {child,_ in if let morpher=child.morpher {count=morpher.targets.count} }
                        guard count>0 else {throw failure("动画缺少形变目标")};n=count
                    } else { n=path=="rotation" ? 4 : 3 }
                    let values=try accessor(integer(sampler,"output",-1),components:path=="weights" ? 1 : n).values
                    guard values.count==times.count*n*(interpolation=="CUBICSPLINE" ? 3 : 1) else {throw failure("动画采样数量无效")}
                    clip.append(.init(node:output,path:path,times:times,values:values,components:n,interpolation:interpolation))
                }
                clips.append(clip)
            }
            scene.rootNode.clipslotsGLBData["clipslots-glb-animation"]=Playback(clips:clips,nodes:Array(built.values))
            return scene
        }
    }
}
