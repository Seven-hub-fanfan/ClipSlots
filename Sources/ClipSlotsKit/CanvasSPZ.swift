import Foundation
import simd
import zlib

public struct CanvasGaussianSplat {
    public var center: SIMD4<Float>
    public var scale: SIMD4<Float>
    public var rotation: SIMD4<Float>
    public var color: SIMD4<Float>
}

public struct CanvasGaussianCloud {
    public let splats: [CanvasGaussianSplat]
    /// Interleaved RGB coefficients, in SPZ basis order, per splat.
    public let harmonics: [Float]
    public let degree: Int
    public let antialiased: Bool
    public let minimum: SIMD3<Float>
    public let maximum: SIMD3<Float>
}

/// Matches the SPZ v1–v3 layout verified in TapNow's shipped Spark reader.
/// Rendering retains anisotropic scales, rotation, opacity and all SH bands.
public enum CanvasSPZ {
    public static let maximumSplats = 1_000_000
    public static func load(_ url: URL) throws -> CanvasGaussianCloud {
        try decode(Data(contentsOf: url, options: .mappedIfSafe))
    }
    public static func transformed(_ cloud:CanvasGaussianCloud,metadata:CanvasCloudResourceMetadata?) -> CanvasGaussianCloud {
        guard let metadata,metadata.marbleCoordinates else { return cloud }
        let scale=Float(metadata.metricScale),ground=Float(metadata.groundOffset)
        let rotation=simd_quatf(angle:.pi,axis:SIMD3<Float>(1,0,0))
        var minimum=SIMD3<Float>(repeating:.infinity),maximum=SIMD3<Float>(repeating:-.infinity)
        let splats=cloud.splats.map { splat -> CanvasGaussianSplat in
            var result=splat
            var point=SIMD3(splat.center.x,splat.center.y,splat.center.z)*scale;point.y-=ground;point=rotation.act(point)
            result.center=SIMD4(point,1);result.scale=splat.scale*scale
            result.rotation=(rotation * simd_quatf(vector:splat.rotation)).vector
            minimum=simd_min(minimum,point);maximum=simd_max(maximum,point)
            return result
        }
        let coefficients=[0,3,8,15][cloud.degree]
        let signs:[Float]=[-1,-1,1,-1,1,1,-1,1,-1,1,-1,-1,1,-1,1]
        var harmonics=cloud.harmonics
        if coefficients>0 {
            for index in harmonics.indices {harmonics[index]*=signs[(index/3)%coefficients]}
        }
        return CanvasGaussianCloud(splats:splats,harmonics:harmonics,degree:cloud.degree,
            antialiased:cloud.antialiased,minimum:minimum,maximum:maximum)
    }
    public static func decode(_ compressed: Data) throws -> CanvasGaussianCloud {
        let bytes = [UInt8](try gunzip(compressed))
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        guard bytes.count >= 16, u32(0) == 1347635022 else { throw error("SPZ 文件头无效") }
        let version = Int(u32(4)), count = Int(u32(8)), degree = Int(bytes[12]), fractional = Int(bytes[13])
        guard (1...3).contains(version), (1...maximumSplats).contains(count), (0...3).contains(degree),
              fractional <= 24 else { throw error("SPZ 版本、点数或精度无效（最多 100 万点）") }
        guard bytes[14] & 128 == 0 else { throw error("层级 LoD SPZ 需导出为普通 SPZ") }
        let coefficients = [0,3,8,15][degree]
        let positionBytes = version == 1 ? 6 : 9, rotationBytes = version == 3 ? 4 : 3
        let expected = 16 + count * (positionBytes + 1 + 3 + 3 + rotationBytes + coefficients * 3)
        guard bytes.count == expected else { throw error("SPZ 数据长度不匹配") }
        let positions = 16, alpha = positions + count * positionBytes, colors = alpha + count
        let scales = colors + count * 3, rotations = scales + count * 3
        let sh = rotations + count * rotationBytes
        var splats = [CanvasGaussianSplat](); splats.reserveCapacity(count)
        var harmonics = [Float](); harmonics.reserveCapacity(count * coefficients * 3)
        var minimum = SIMD3<Float>(repeating: .infinity), maximum = SIMD3<Float>(repeating: -.infinity)
        func position(_ offset: Int) -> Float {
            if version == 1 {
                return Float(Float16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8))
            }
            let packed = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            let signed = Int32(bitPattern: packed << 8) >> 8
            return Float(signed) / Float(UInt32(1) << fractional)
        }
        for index in 0..<count {
            if index % 8192 == 0 { try Task.checkCancellation() }
            let p = positions + index * positionBytes, step = positionBytes / 3
            let center = SIMD3<Float>(position(p), position(p + step), position(p + step * 2))
            guard center.x.isFinite, center.y.isFinite, center.z.isFinite else { throw error("SPZ 坐标无效") }
            minimum = simd_min(minimum, center); maximum = simd_max(maximum, center)
            let s = scales + index * 3
            let scale = SIMD4<Float>(exp(Float(bytes[s]) / 16 - 10), exp(Float(bytes[s + 1]) / 16 - 10),
                                     exp(Float(bytes[s + 2]) / 16 - 10), 0)
            let c = colors + index * 3, factor: Float = 0.28209479177387814 / 0.15
            let color = SIMD4<Float>((Float(bytes[c]) / 255 - 0.5) * factor + 0.5,
                (Float(bytes[c + 1]) / 255 - 0.5) * factor + 0.5,
                (Float(bytes[c + 2]) / 255 - 0.5) * factor + 0.5, Float(bytes[alpha + index]) / 255)
            let r = rotations + index * rotationBytes
            var quaternion = SIMD4<Float>(repeating: 0)
            if version == 3 {
                let packed = u32(r), largest = Int(packed >> 30)
                var remaining = packed, square: Float = 0
                for axis in stride(from: 3, through: 0, by: -1) where axis != largest {
                    var value = Float(remaining & 511) / 511 / sqrt(2)
                    if (remaining >> 9) & 1 != 0 { value = -value }
                    remaining >>= 10; quaternion[axis] = value; square += value * value
                }
                quaternion[largest] = sqrt(max(0, 1 - square))
            } else {
                quaternion.x = Float(bytes[r]) / 127.5 - 1
                quaternion.y = Float(bytes[r + 1]) / 127.5 - 1
                quaternion.z = Float(bytes[r + 2]) / 127.5 - 1
                quaternion.w = sqrt(max(0, 1 - quaternion.x * quaternion.x - quaternion.y * quaternion.y - quaternion.z * quaternion.z))
            }
            quaternion = simd_normalize(quaternion)
            splats.append(CanvasGaussianSplat(center: SIMD4(center, 1), scale: scale, rotation: quaternion, color: color))
            for component in 0..<coefficients * 3 {
                harmonics.append((Float(bytes[sh + index * coefficients * 3 + component]) - 128) / 128)
            }
        }
        return CanvasGaussianCloud(splats: splats, harmonics: harmonics, degree: degree,
                                   antialiased: bytes[14] & 1 != 0, minimum: minimum, maximum: maximum)
    }
    private static func error(_ message: String) -> CanvasToolError { .invalid(message) }
    private static func gunzip(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 256 * 1024 * 1024 else { throw error("SPZ 压缩文件过大或为空") }
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw error("无法初始化 SPZ 解压")
        }
        defer { inflateEnd(&stream) }
        var output = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        try data.withUnsafeBytes { raw in
            guard let address = raw.bindMemory(to: Bytef.self).baseAddress else { throw error("SPZ 文件为空") }
            stream.next_in = UnsafeMutablePointer(mutating: address); stream.avail_in = uInt(data.count)
            while true {
                try Task.checkCancellation()
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress; stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw error("SPZ gzip 损坏或校验失败") }
                let written = chunk.count - Int(stream.avail_out)
                guard output.count + written <= 256 * 1024 * 1024 else { throw error("SPZ 解压后过大") }
                output.append(contentsOf: chunk.prefix(written))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw error("SPZ 包含多余压缩数据") }
                    break
                }
                guard written > 0 else { throw error("SPZ 压缩流不完整") }
            }
        }
        return output
    }
}
