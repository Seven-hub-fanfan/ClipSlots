#if DEBUG
import AppKit
import AVFoundation
import ClipSlotsKit

@MainActor
enum LargeMediaRegression {
    struct Result {
        var checks: [String: Bool] = [:]
        var measurements: [[String: Any]] = []
    }
    static func run(manifest: URL, directory: URL, store: SlotStoreObservable,
                    canvas: CanvasStore, window: NSWindow,
                    request: @escaping (WorkspaceMode) -> Void,
                    ready: @escaping () -> Bool) async -> Result {
        var result = Result()
        func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func until(_ condition: () -> Bool) async -> Bool {
            let start = ProcessInfo.processInfo.systemUptime
            while !condition(), ProcessInfo.processInfo.systemUptime - start < 15 { await pause(20) }
            return condition()
        }
        func rss() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return status == KERN_SUCCESS ? info.resident_size : 0
        }
        func capture(_ name: String) {
            guard let root = window.contentView,
                  let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
        guard let data = try? Data(contentsOf: manifest),
              let files = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              files.count == 36, store.specialSlots.count >= 4 else {
            result.checks["real media fixture available"] = false
            return result
        }
        // This function is invoked only in the isolated workload process.
        canvas.removeNodes(ids: Set(canvas.nodes.map(\.id)))
        canvas.isLibraryExpanded = false
        let groups = Array(store.specialSlots.suffix(4))
        var media: [(CanvasNode, SlotContent.SlotAttachment)] = []
        let initialRSS = rss()
        for (index, file) in files.enumerated() {
            guard let path = file["path"] as? String else { continue }
            let kind: CanvasNodeKind = file["kind"] as? String == "video" ? .video : .image
            let group = groups[index / 10]
            let slot = index % 10 + 1
            let attachment = SlotContent.SlotAttachment(name: URL(fileURLWithPath: path).lastPathComponent,
                type: kind == .image ? .image : .file, path: path)
            guard let saved = store.appendCanvasGeneratedAttachment(attachment, groupId: group.id, slot: slot)
                else { continue }
            _ = canvas.placeSlot(pageId: group.pageId, groupId: group.id, slot: slot,
                name: attachment.name, at: CGPoint(x: 170 + index % 4 * 310, y: 150 + index / 4 * 215),
                kind: kind)
            if let node = canvas.nodes.first(where: { $0.groupId == group.id && $0.slot == slot }) {
                media.append((node, saved))
            }
            await pause(10)
        }
        canvas.clearSelection()
        await pause(800)
        for (index, entry) in media.enumerated() {
            canvas.moveNode(id: entry.0.id, to: CGPoint(x: 40 + index % 4 * 620,
                                                       y: 60 + index / 4 * 390))
        }
        canvas.updateViewport(pan: CGSize(width: 30, height: 30), zoom: 0.32)
        request(.edit)
        _ = await until(ready)
        request(.canvas)
        _ = await until(ready)
        await pause(1800)
        result.checks["36 real media nodes stored and mounted"] = media.count == 36 && canvas.nodes.count == 36
        var dimensions = 0
        var aspectMatches = 0
        var thumbnails = 0
        for (node, attachment) in media {
            let facts = await CanvasMediaProbe.load(for: attachment).facts
            if let image = await CanvasAttachmentThumbnails.load(attachment, maxPixel: 900),
               image.size.width > 0, image.size.height > 0 {
                thumbnails += 1
            }
            if let pixels = facts.pixelSize, pixels.width > 0, pixels.height > 0 {
                dimensions += 1
                if let live = canvas.node(id: node.id),
                   abs(live.width / live.height - pixels.width / pixels.height) < 0.03 { aspectMatches += 1 }
            }
        }
        result.checks["all real image and video dimensions readable"] = dimensions == 36
        result.checks["all media nodes preserve original aspect"] = aspectMatches == 36
        result.checks["all 36 real image and video thumbnails decode"] = thumbnails == 36
        capture("real-media-overview")
        var peakRSS = rss()
        var costs: [Double] = []
        var deadlines: [Double] = []
        var compositor: OwnWindowCompositorProbe?
        if #available(macOS 14.4, *) { compositor = try? await OwnWindowCompositorProbe.start(window: window) }
        compositor?.begin(region: CGRect(x: 80, y: 160, width: 660, height: 430), retainImages: false)
        await pause(30)
        let pixelStart = compositor?.now ?? 0
        let initialPan = CanvasAgentGroupsProbeBridge.current?.pan
        let clock = ProcessInfo.processInfo.systemUptime
        for step in 0..<90 {
            let deadline = clock + Double(step) / 60
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            let start = ProcessInfo.processInfo.systemUptime
            deadlines.append(max(0, start - deadline) * 1000)
            CanvasAgentGroupsProbeBridge.current?.inputRouter.onScroll?(
                0, -10, true, false, CGPoint(x: 400, y: 300))
            costs.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            peakRSS = max(peakRSS, rss())
        }
        costs.sort(); deadlines.sort()
        await pause(150)
        if let compositor {
            let pixels = await compositor.report(since: pixelStart, until: compositor.now,
                expectedText: nil, directory: directory, name: "real-media-pan")
            result.measurements.append(["scenario": "real-media-pan-compositor", "compositor": pixels])
            result.checks["media pan changes actual compositor pixels"] =
                (pixels["changedPixelSamples"] as? Int ?? 0) > 20
            await compositor.stop()
        }
        result.checks["media pan moves visible viewport"] =
            initialPan != CanvasAgentGroupsProbeBridge.current?.pan
        result.measurements.append(["scenario": "real-media-pan", "images": 24, "videos": 12,
            "p95HandlerMS": costs[Int(Double(costs.count - 1) * 0.95)],
            "p95DeadlineLatenessMS": deadlines[Int(Double(deadlines.count - 1) * 0.95)],
            "initialResidentBytes": initialRSS, "sampledPeakResidentBytes": peakRSS,
            "metric": "actual canvas viewport updates; not hardware gesture or presented FPS"])
        CanvasAgentGroupsProbeBridge.current?.inputRouter.onScroll?(
            0, 150, true, false, CGPoint(x: 400, y: 300))
        result.checks["media pan uses mounted native input route"] =
            CanvasAgentGroupsProbeBridge.current?.inputRouter.onScroll != nil
        await pause(600)
        capture("real-media-video-nodes")
        var played = 0
        var released = 0
        var playTimes: [Double] = []
        if let playback = CanvasInlinePlayback.regressionInstance {
            for (node, attachment) in media.filter({ $0.0.kind == .video }) {
                let previous = playback.player
                let started = ProcessInfo.processInfo.systemUptime
                playback.toggle(nodeID: node.id, attachment: attachment)
                let valid = await until { playback.nodeID == node.id && playback.phase == .playing }
                playTimes.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
                await pause(180)
                if valid, let current = playback.player, current.currentTime().seconds > 0 { played += 1 }
                if previous == nil || (previous?.rate == 0 && previous?.currentItem == nil) { released += 1 }
                peakRSS = max(peakRSS, rss())
            }
            capture("real-media-playing")
            playback.stop()
            result.checks["video stop releases current player"] = playback.player == nil && playback.phase == .idle
        }
        result.checks["all 12 real videos advance playback time"] = played == 12
        result.checks["switching videos releases every prior decoder item"] = released == 12
        playTimes.sort()
        result.measurements.append(["scenario": "real-video-switch", "played": played,
            "medianStartMS": playTimes.isEmpty ? 0 : playTimes[playTimes.count / 2],
            "maxStartMS": playTimes.max() ?? 0, "sampledPeakResidentBytes": peakRSS,
            "metric": "single shared player; time to ready-to-play, not first presented video frame"])
        for target: WorkspaceMode in [.edit, .canvas, .edit, .canvas] {
            let start = ProcessInfo.processInfo.systemUptime
            request(target)
            let settled = await until(ready)
            result.checks["media workspace \(target.rawValue) returns ready"] = settled
            result.measurements.append(["scenario": "real-media-workspace-\(target.rawValue)",
                "readyMS": (ProcessInfo.processInfo.systemUptime - start) * 1000, "residentBytes": rss()])
            await pause(300)
        }
        result.checks["media nodes survive workspace switching"] = canvas.nodes.count == 36
        return result
    }
}
#endif
