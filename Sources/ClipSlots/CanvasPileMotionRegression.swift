#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit

@MainActor enum CanvasPileNativeButtonProbe {
    /// SwiftUI's in-process NSView children do not expose its complete AX tree.
    /// Ask the public accessibility API from an independent process instead.
    static func press(_ identifier: String, directory: URL) async -> Bool {
        let token = UUID().uuidString
        let request: [String: Any] = ["identifier": identifier, "token": token,
                                     "pid": Int(ProcessInfo.processInfo.processIdentifier)]
        let file = directory.appendingPathComponent("ax-button-requests.jsonl")
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            handle.seekToEndOfFile()
            handle.write(try JSONSerialization.data(withJSONObject: request))
            handle.write(Data([10])); try handle.close()
            let response = directory.appendingPathComponent("ax-button-\(token).json")
            for _ in 0..<300 {
                if let data = try? Data(contentsOf: response),
                   let record = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let log = directory.appendingPathComponent("native-button-actions.jsonl")
                    if !FileManager.default.fileExists(atPath: log.path) {
                        FileManager.default.createFile(atPath: log.path, contents: nil)
                    }
                    let stream = try FileHandle(forWritingTo: log)
                    stream.seekToEndOfFile(); stream.write(data); stream.write(Data([10])); try stream.close()
                    return record["token"] as? String == token && record["result"] as? Int == 0
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch { return false }
        return false
    }
}

extension CanvasWorkspaceView {
    /// Runtime evidence from the real gallery, not a synthetic session runner.
    /// Pose records are destinations; timestamped PNGs document rendered motion.
    @MainActor func runPileGalleryMotionProbe(
        directory: URL, pileID: String, memberID: String,
        mouse: (NSEvent.EventType, CGPoint) async -> Bool,
        check: (Bool, String) -> Void
    ) async -> [[String: Any]] {
        var live: CanvasWorkspaceView { CanvasAgentGroupsProbeBridge.current ?? self }
        var observations: [[String: Any]] = []
        let started = ProcessInfo.processInfo.systemUptime
        let originalNodes = canvas.nodes, originalEdges = canvas.edges, originalPiles = canvas.piles
        let initialHistory = canvas.history.cursor
        let camera = live.effectivePan, zoom = live.zoom
        func pause(_ seconds: Double) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        func poseRecord(_ pose: CanvasPileMemberPose) -> [String: Any] {
            ["x": pose.frame.minX, "y": pose.frame.minY,
             "width": pose.frame.width, "height": pose.frame.height,
             "rotation": pose.rotation, "shade": pose.shade]
        }
        func sample(_ name: String) {
            let bridge = CanvasPileGalleryProbeBridge.self
            var row: [String: Any] = [
                "name": name, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "phase": bridge.sessions[pileID]?.phase.rawValue ?? "removed",
                "modal": live.pileGalleryID == pileID,
                "blocksCanvasInput": live.inputRouter.blocksCanvasInput?() == true,
                "returnTarget": bridge.returnTargets[pileID] ?? false,
                "expansion": bridge.expansions[pileID] ?? 1,
                "reducedMotion": bridge.reducedMotion[pileID] ?? CanvasPileMotionAccessibility.shouldReduceMotion(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),
                "poseSemantics": "destination, not sampled presentation transform"
            ]
            if let source = bridge.sources[pileID]?[memberID] { row["source"] = poseRecord(source) }
            if let grid = bridge.grids[pileID]?[memberID] { row["grid"] = poseRecord(grid) }
            if let carried = bridge.carried[pileID] { row["carried"] = poseRecord(carried) }
            // Capturing an entire SwiftUI tree on MainActor stalls animation and
            // its completion task. The independent driver records actual pixels
            // and capture times without blocking these lifecycle observations.
            if let window = live.inputRouter.anchorView?.window {
                let request: [String: Any] = ["name": name, "window": window.windowNumber,
                    "pid": Int(ProcessInfo.processInfo.processIdentifier),
                    "requestedUnixSeconds": Date().timeIntervalSince1970]
                do {
                    let path = directory.appendingPathComponent("capture-requests.jsonl")
                    if !FileManager.default.fileExists(atPath: path.path) {
                        FileManager.default.createFile(atPath: path.path, contents: nil)
                    }
                    let handle = try FileHandle(forWritingTo: path)
                    handle.seekToEndOfFile()
                    handle.write(try JSONSerialization.data(withJSONObject: request))
                    handle.write(Data([10])); try handle.close()
                    row["captureRequest"] = name
                } catch { check(false, "Motion capture request writes: \(error)") }
            } else { check(false, "Motion observation has an attached window") }
            observations.append(row)
        }
        func open(_ prefix: String) async -> Bool {
            canvas.select(id: pileID, additive: false)
            live.pileGalleryID = pileID
            await pause(0.035)
            let reduced = CanvasPileGalleryProbeBridge.reducedMotion[pileID] ?? false
            check(CanvasPileGalleryProbeBridge.sessions[pileID]?.phase == (reduced ? .open : .opening),
                  "\(prefix) opening lifetime honors effective reduced motion")
            sample(prefix + "-035ms")
            await pause(0.165)
            sample(prefix + "-200ms")
            await pause(0.45)
            let ready = CanvasPileGalleryProbeBridge.sessions[pileID]?.phase == .open
            check(ready && canvas.selectedNodeIds == [pileID] && live.inputRouter.blocksCanvasInput?() == true,
                  "\(prefix) opens into a modal gallery without changing Pile selection")
            sample(prefix + "-650ms")
            return ready
        }
        func restore(_ label: String) async -> Bool {
            if canvas.history.cursor == initialHistory + 1 {
                check(canvas.undo() != nil, "\(label) undo is available")
            }
            await pause(0.65)
            let restored = canvas.nodes == originalNodes && canvas.edges == originalEdges && canvas.piles == originalPiles
            check(restored, "\(label) restores every node, wire and Pile field")
            canvas.select(id: pileID, additive: false)
            return restored
        }

        guard await open("gallery-motion-open") else { return observations }
        let reduced = CanvasPileGalleryProbeBridge.reducedMotion[pileID] ?? false
        check(await CanvasPileNativeButtonProbe.press("gallery-close", directory: directory),
              "Motion probe presses the actual native Gallery close button")
        await pause(0.035)
        check(reduced ? live.pileGalleryID == nil
            : live.pileGalleryID == pileID && CanvasPileGalleryProbeBridge.sessions[pileID]?.phase == .closing,
              "Reverse close waits for motion, or completes immediately under reduced motion")
        sample("gallery-motion-close-035ms")
        await pause(0.165); sample("gallery-motion-close-200ms")
        await pause(0.45); sample("gallery-motion-close-650ms")
        check(live.pileGalleryID == nil && canvas.nodes == originalNodes && canvas.edges == originalEdges
              && canvas.piles == originalPiles && canvas.history.cursor == initialHistory,
              "Reverse close only changes presentation state")

        live.pileGalleryID = pileID
        await pause(0.02)
        NotificationCenter.default.post(name: .canvasPileGalleryCloseRequested, object: pileID)
        await pause(0.035); sample("gallery-motion-opening-cancel")
        await pause(0.65)
        check(live.pileGalleryID == nil && CanvasPileGalleryProbeBridge.sessions[pileID] == nil,
              "Close during opening cancels the old completion and does not reopen")

        guard await open("gallery-motion-pickup"),
              let viewport = CanvasPileGalleryProbeBridge.viewports[pileID],
              let grid = CanvasPileGalleryProbeBridge.grids[pileID]?[memberID],
              let pile = canvas.piles.first(where: { $0.id == pileID }) else { return observations }
        let start = CGPoint(x: grid.frame.midX + viewport.minX, y: grid.frame.midY + viewport.minY)
        check(await mouse(.leftMouseDown, start), "Gallery pickup delivers native mouse-down")
        await pause(0.06)
        check(await mouse(.leftMouseDragged, CGPoint(x: start.x + 20, y: start.y)), "Gallery pickup delivers sub-threshold move")
        await pause(0.06)
        check(CanvasPileGalleryProbeBridge.sessions[pileID]?.phase == .dragging,
              "Native 20px pickup stays in the Gallery")
        sample("gallery-motion-pickup-20px")
        check(await mouse(.leftMouseDragged, CGPoint(x: start.x + 100, y: start.y)), "Gallery pickup delivers collapse move")
        await pause(0.06)
        check(CanvasPileGalleryProbeBridge.sessions[pileID]?.phase == .collapsed,
              "Native move beyond 72px collapses the other Gallery cards")
        sample("gallery-motion-collapse")
        let members = CanvasPileGeometry.members(pile, nodes: canvas.nodes).filter { $0.id != memberID }
        let sourceFrame = live.pileScreenFrame(pile).offsetBy(dx: -viewport.minX, dy: -viewport.minY)
        let bounds = CanvasPileGalleryMotion.returnBounds(members, screenFrame: sourceFrame, zoom: live.zoom)
        let target = CGPoint(x: bounds.midX + viewport.minX, y: bounds.midY + viewport.minY)
        check(await mouse(.leftMouseDragged, target), "Gallery drag delivers return-target entry")
        await pause(0.06)
        check(CanvasPileGalleryProbeBridge.returnTargets[pileID] == true
              && CanvasPileGalleryProbeBridge.expansions[pileID] == 2.35,
              "Native return-target entry selects recovered 2.35 expansion")
        sample("gallery-motion-return-target")
        NotificationCenter.default.post(name: .canvasPileGalleryCloseRequested, object: pileID)
        _ = await mouse(.leftMouseUp, target)
        await pause(0.035); sample("gallery-motion-cancel-handoff")
        await pause(0.65)
        check(live.pileGalleryID == nil && canvas.nodes == originalNodes && canvas.edges == originalEdges
              && canvas.piles.first(where: { $0.id == pileID })?.memberIDs.last == memberID,
              "Cancelled collapsed pickup returns to Pile top without extracting content")
        guard await restore("Cancelled pickup") else { return observations }

        guard await open("gallery-motion-extract"),
              let extractionGrid = CanvasPileGalleryProbeBridge.grids[pileID]?[memberID],
              let extractionViewport = CanvasPileGalleryProbeBridge.viewports[pileID] else { return observations }
        let grab = CGPoint(x: extractionGrid.frame.minX + extractionGrid.frame.width * 0.25 + extractionViewport.minX,
                           y: extractionGrid.frame.minY + extractionGrid.frame.height * 0.75 + extractionViewport.minY)
        let release = CGPoint(x: extractionViewport.maxX - 140, y: extractionViewport.minY + 170)
        _ = await mouse(.leftMouseDown, grab); await pause(0.06)
        if ProcessInfo.processInfo.environment["CANVAS_SYSTEM_MOUSE"] != "1" {
            // NSEvent.mouseEvent has no hardware mouse state. SwiftUI needs the
            // pickup move while still over the card before a queued distant move.
            // The system CGEvent run separately validates a single large jump.
            _ = await mouse(.leftMouseDragged, CGPoint(x: grab.x + 20, y: grab.y)); await pause(0.06)
            check(CanvasPileGalleryProbeBridge.sessions[pileID]?.phase == .dragging,
                  "Native fractional pickup begins with a continuous sub-threshold move")
        }
        _ = await mouse(.leftMouseDragged, release); await pause(0.06)
        let carried = CanvasPileGalleryProbeBridge.carried[pileID]
        check(CanvasPileGalleryProbeBridge.sessions[pileID]?.phase == .collapsed
              && CanvasPileGalleryProbeBridge.returnTargets[pileID] == false && carried != nil,
              "Native extraction pickup owns a carried card outside the return target")
        sample("gallery-motion-extract-carried")
        _ = await mouse(.leftMouseUp, release)
        await pause(0.035); sample("gallery-motion-extract-landing")
        if !reduced {
            check(live.pileGalleryID == pileID && canvas.history.cursor == initialHistory
                  && CanvasPileGalleryProbeBridge.sessions[pileID]?.phase == .landingOnCanvas,
                  "Extraction defers data mutation until the visual landing finishes")
        }
        await pause(0.65)
        if let carried, let node = canvas.node(id: memberID) {
            let center = CanvasGeometry.canvasPoint(
                screen: CGPoint(x: carried.frame.midX + extractionViewport.minX,
                                y: carried.frame.midY + extractionViewport.minY), pan: camera, zoom: zoom)
            check(abs(node.frame.midX - center.x) < 0.01 && abs(node.frame.midY - center.y) < 0.01,
                  "Native fractional pickup lands by card center, not release pointer")
            var restoredNode = node
            if let before = originalNodes.first(where: { $0.id == memberID }) {
                restoredNode.x = before.x; restoredNode.y = before.y
                restoredNode.updatedAt = before.updatedAt
                check(restoredNode == before, "Native extraction preserves identity and payload, allowing the movement timestamp")
            }
        } else { check(false, "Native extraction produces a landing node and carried geometry") }
        check(live.pileGalleryID == nil && canvas.selectedNodeIds == [memberID]
              && live.nodesInPaintOrder.contains(where: { $0.id == memberID }) && canvas.edges == originalEdges
              && canvas.history.cursor == initialHistory + 1,
              "Native extraction reveals and selects the original node in one transaction")
        sample("gallery-motion-extracted")
        guard await restore("Extraction") else { return observations }

        guard await open("gallery-motion-button-extract") else { return observations }
        check(await CanvasPileNativeButtonProbe.press("pile-extract-\(memberID)", directory: directory),
              "Motion probe presses the actual native extraction button")
        await pause(0.035); sample("gallery-motion-button-landing")
        await pause(0.65)
        check(live.pileGalleryID == nil && canvas.selectedNodeIds == [memberID]
              && canvas.history.cursor == initialHistory + 1,
              "Native extraction button uses the same deferred landing transaction")
        _ = await restore("Button extraction")
        check(live.effectivePan == camera && live.zoom == zoom, "Gallery motion never changes the canvas camera")
        return observations
    }
}
#endif
