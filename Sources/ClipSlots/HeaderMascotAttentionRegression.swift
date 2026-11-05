#if DEBUG
import AppKit
import ClipSlotsKit
import SceneKit

/// Actual native raster timing; no model calls, live slot data or pointer injection.
@MainActor
enum HeaderMascotAttentionRegression {
    static func runScheduled(root: URL, check: (Bool, String) -> Void) async throws {
        // Exercise the actual asynchronous queue and newest-frame scheduler.
        // This measures callback delivery, not physical display scanout.
        let renderer = HeaderMascotRenderer()
        _ = renderer.renderSynchronously(.init(pose: MascotPose(), size: 248, activity: .idle))
        let motion = MascotMotion()
        motion.random = { 1 }
        var received: [[String: Double]] = []
        let origin = ProcessInfo.processInfo.systemUptime * 1000
        let scheduler = MascotFrameScheduler(render: { request, completion in
            renderer.render(request, completion: completion)
        }, present: { request, frame in
            guard frame.bitmap != nil else { return }
            let now = ProcessInfo.processInfo.systemUptime * 1000
            received.append(["time_ms":now-origin, "age_ms":now-request.issuedAtMS,
                             "yaw":request.pose.yaw])
        })
        motion.setPointer(x:220, y:70, at:0)
        for i in 0..<90 {
            let time = ProcessInfo.processInfo.systemUptime * 1000 - origin
            if i == 20 { motion.setPointer(x:-220,y:70,at:time) }
            if i == 50 { motion.setPointer(x:220,y:-70,at:time) }
            scheduler.submit(.init(pose:motion.sample(at:time),size:248,activity:.idle))
            try await Task.sleep(for:.milliseconds(1000.0/60))
        }
        for _ in 0..<50 where scheduler.inFlight {
            try await Task.sleep(for:.milliseconds(10))
        }
        let intervals = zip(received, received.dropFirst()).map { $1["time_ms"]!-$0["time_ms"]! }.sorted()
        let ages = received.map { $0["age_ms"]! }.sorted()
        let firstResponse = received.first { abs($0["yaw"]!)>0.25 }?["time_ms"] ?? .infinity
        func p95(_ values:[Double])->Double {
            values.isEmpty ? .infinity : values[Int(Double(values.count-1)*0.95)]
        }
        check(received.count>=75 && p95(intervals)<34,
              "机器人异步帧交付连续：90 次请求至少呈现 75 帧，P95 间隔小于 34ms")
        check(firstResponse<140 && p95(ages)<34,
              "机器人异步首个转头小于 140ms，P95 帧龄小于 34ms")
        try JSONSerialization.data(withJSONObject:[
            "scope":"Warm native renderer + actual frame scheduler callbacks; excludes OS compositor and physical scanout.",
            "frames":received, "frame_count":received.count, "first_response_ms":firstResponse,
            "p95_interval_ms":p95(intervals), "p95_age_ms":p95(ages),
            "passed":received.count>=75 && p95(intervals)<34 && firstResponse<140 && p95(ages)<34
        ],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("mascot-scheduled.json"))
    }
    static func run(root: URL, check: (Bool, String) -> Void) throws {
        func source(_ x:Float,_ padding:Float)->SCNGeometrySource {
            let values:[Float]=[x,2,3,padding]
            return SCNGeometrySource(data:values.withUnsafeBytes { Data($0) },semantic:.vertex,
                vectorCount:1,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,
                dataOffset:0,dataStride:16)
        }
        let a=source(1,0),b=source(1,99),c=source(1.001,0)
        check(a.data != b.data && HeaderMascotScene.geometrySourceBytes(a)
            == HeaderMascotScene.geometrySourceBytes(b), "几何审计忽略 SIMD3 未使用的填充字节")
        check(HeaderMascotScene.geometrySourceBytes(a) != HeaderMascotScene.geometrySourceBytes(c),
              "几何审计仍检测实际顶点分量差异")
        func pixels(_ edits:[(Int,Int,UInt8)]) -> MascotLampPixels {
            var bytes=[UInt8](repeating:100,count:8*8*4)
            for i in stride(from:3,to:bytes.count,by:4) { bytes[i]=255 }
            for (pixel,channel,value) in edits { bytes[pixel*4+channel]=value }
            let provider=CGDataProvider(data:Data(bytes) as CFData)!
            let image=CGImage(width:8,height:8,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:32,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue),provider:provider,decode:nil,
                shouldInterpolate:false,intent:.defaultIntent)!
            return MascotLampPixels(image)!
        }
        let base=pixels([]),roi=CGRect(x:3,y:3,width:2,height:2)
        check(pixels([(0,0,101)]).matchesOutsideAndOpaque(base,rect:roi),
              "灯效缓存允许单个区域外像素的 1/255 舍入")
        check(!pixels([(0,0,103)]).matchesOutsideAndOpaque(base,rect:roi),
              "灯效缓存拒绝区域外明显色差")
        check(!pixels((0..<8).map { ($0,0,101) }).matchesOutsideAndOpaque(base,rect:roi),
              "灯效缓存拒绝大面积 1/255 变化")
        check(!pixels([(27,3,254)]).matchesOutsideAndOpaque(base,rect:roi),
              "灯效缓存仍严格拒绝补丁内透明像素")
        check(base.differenceRect(pixels([(0,0,101),(27,0,150)]),tolerance:1)
                == CGRect(x:3,y:3,width:1,height:1),
              "区域外的单字节舍入不会扩大灯效补丁")
        let renderer = HeaderMascotRenderer()
        let auditedRenderer = HeaderMascotRenderer(verifyGeometry: true)
        let motion = MascotMotion()
        motion.random = { 1 }
        motion.pointerProjection = { renderer.pointer(x: $0, y: $1) }
        var timings: [Double] = []
        var valid = true
        var rows: [[String: Any]] = []
        var auditedTimes: [Double] = []
        var matchingPixels = true
        var maximumPixelDifference = 0
        var alphaIdentical = true
        var maximumAlphaDifference = 0
        var maximumContactLiftDifference:Float = 0
        var maximumMeanPixelDifference = 0.0
        var geometryIdentical = true
        for i in 0...180 {
            let time = Double(i) * 1000 / 60
            if i == 0 { motion.setPointer(x: 220, y: 70, at: time) }
            if i == 50 { motion.setPointer(x: -220, y: -70, at: time) }
            if i == 110 { motion.setPointer(x: nil, y: nil, at: time) }
            let pose = motion.sample(at: time)
            let start = ProcessInfo.processInfo.systemUptime
            let frame = renderer.renderSynchronously(.init(pose: pose, size: 248, activity: .idle))
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            if i > 5 { timings.append(ms) } // report cold setup separately
            valid = valid && frame.geometryInsideFrustum && frame.facialSurfaceValid && frame.bitmap != nil
            rows.append(["time_ms": time, "yaw": pose.yaw, "pitch": pose.pitch, "raster_ms": ms,
                         "phases": renderer.performancePhases])
            if [0, 20, 50, 80, 110, 140, 180].contains(i) {
                let auditStart = ProcessInfo.processInfo.systemUptime
                let audited = auditedRenderer.renderSynchronously(.init(pose: pose, size: 248, activity: .idle))
                auditedTimes.append((ProcessInfo.processInfo.systemUptime - auditStart) * 1000)
                try audited.bitmap?.representation(using: .png, properties: [:])?
                    .write(to: root.appendingPathComponent("mascot-audited-\(i).png"))
                valid = valid && audited.geometryInsideFrustum && audited.facialSurfaceValid
                maximumContactLiftDifference=max(maximumContactLiftDifference,
                    abs(renderer.contactLift-auditedRenderer.contactLift))
                geometryIdentical = geometryIdentical &&
                    renderer.geometryFingerprint == auditedRenderer.geometryFingerprint
                if let a = frame.bitmap, let b = audited.bitmap,
                   let bytesA = a.bitmapData, let bytesB = b.bitmapData, a.bytesPerRow == b.bytesPerRow {
                    // Exact geometry inputs, <=1/255 alpha rounding, mean error
                    // <=0.01 per 8-bit channel. Independent GPU snapshots may
                    // round an edge pixel differently; retain the actual delta.
                    var sum=0
                    for y in 0..<a.pixelsHigh {
                        for x in 0..<(a.pixelsWide * 4) {
                            let delta=abs(Int(bytesA[y*a.bytesPerRow+x])-Int(bytesB[y*b.bytesPerRow+x]))
                            maximumPixelDifference=max(maximumPixelDifference,delta);sum+=delta
                            if x%4==3 {
                                maximumAlphaDifference=max(maximumAlphaDifference,delta)
                                if delta != 0 { alphaIdentical=false }
                            }
                        }
                    }
                    maximumMeanPixelDifference=max(maximumMeanPixelDifference,
                        Double(sum)/Double(a.pixelsWide*a.pixelsHigh*4))
                    matchingPixels = matchingPixels &&
                        maximumMeanPixelDifference <= 0.01 && maximumAlphaDifference<=1
                } else { matchingPixels = false }
                try frame.bitmap?.representation(using: .png, properties: [:])?
                    .write(to: root.appendingPathComponent("mascot-\(i).png"))
            }
        }
        let sorted = timings.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        check(valid, "机器人观察、转头、急转、离开轨迹均可原生绘制且几何有效")
        check(matchingPixels, "机器人实时与完整审计渲染轮廓一致，颜色仅有稀疏舍入误差")
        check(geometryIdentical, "机器人实时与完整审计的顶点、法线、索引和变换哈希一致")
        check(maximumContactLiftDifference<0.000001, "空间筛选与逐顶点碰撞的抬升结果一致")
        check(p95 < 16.7, "机器人 248px 原生渲染 P95 小于 60fps 单帧预算")
        let report: [String: Any] = [
            "scope": "181 actual native rasters at 248px; excludes display scanout and OS compositor scheduling.",
            "p95_raster_ms": p95, "median_raster_ms": sorted[sorted.count / 2],
            "cold_raster_ms": rows[0]["raster_ms"]!, "rows": rows,
            "audited_raster_ms": auditedTimes, "audited_pixels_equivalent": matchingPixels,
            "maximum_pixel_channel_difference":maximumPixelDifference,
            "alpha_identical":alphaIdentical,"maximum_mean_pixel_channel_difference":maximumMeanPixelDifference,
            "maximum_alpha_difference":maximumAlphaDifference,
            "maximum_contact_lift_difference":maximumContactLiftDifference,
            "geometry_identical":geometryIdentical,
            "passed": valid && matchingPixels && geometryIdentical && maximumContactLiftDifference<0.000001 && p95 < 16.7
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("mascot-raster.json"))
    }
}
#endif
