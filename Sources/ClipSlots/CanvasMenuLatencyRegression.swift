#if DEBUG
import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreImage
import ClipSlotsKit

/// Presented pixels are collected off the main thread; no forced layout/display
/// is used to make a latency assertion pass.
final class MenuFrameCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "clipslots.menu.frames")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var frames: [(Double, CGImage)] = []
    private var recording = false

    func start(windowID: CGWindowID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 5
        config.showsCursor = false
        let next = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                            configuration: config, delegate: nil)
        try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = next
        try await next.startCapture()
    }

    func begin() { queue.sync { frames.removeAll(); recording = true } }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard recording, type == .screen, buffer.isValid, frames.count < 100,
              let info = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = info.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixels = buffer.imageBuffer else { return }
        let input = CIImage(cvPixelBuffer: pixels)
        guard let image = context.createCGImage(input, from: input.extent) else { return }
        frames.append((CMTimeGetSeconds(buffer.presentationTimeStamp), image))
    }

    func save(to directory: URL, name: String, trigger: Double) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                self.recording = false
                var times: [[String: Any]] = []
                for (index, frame) in self.frames.enumerated() {
                    let filename = "\(name)-\(index).png"
                    let rep = NSBitmapImageRep(cgImage: frame.1)
                    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(filename))
                    times.append(["file": filename, "relative_ms": (frame.0 - trigger) * 1000])
                }
                try? JSONSerialization.data(withJSONObject: times, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent(name + "-frames.json"))
                self.frames.removeAll()
                continuation.resume(returning: times.count)
            }
        }
    }
    func stop() async { try? await stream?.stopCapture() }
}

extension CanvasWorkspaceView {
    @MainActor func runMenuLatencyProbe(directory: URL) async {
        let env = ProcessInfo.processInfo.environment
        var passed = 0, failures: [String] = [], results: [[String: Any]] = []
        func check(_ value: Bool, _ text: String) {
            if value { passed += 1 } else { failures.append(text) }
            NSLog("[MenuLatency] \(value ? "PASS" : "FAIL") \(text)")
        }
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func waitUntil(_ predicate: () -> Bool, deadline: Double) async -> Double? {
            while true {
                if predicate() { return ProcessInfo.processInfo.systemUptime }
                if ProcessInfo.processInfo.systemUptime >= deadline { return nil }
                await pause(0.001)
            }
        }
        guard let window = inputRouter.anchorView?.window else { return }
        let displayUsable = CGDisplayIsAsleep(CGMainDisplayID()) == 0
            && (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true
        check(displayUsable, "desktop is unlocked and display awake")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        agentVisible = false
        canvas.isLibraryExpanded = false
        canvas.activeTool = .select
        pan = .zero
        zoom = 0.65
        guard let source = createNode(kind: .image, at: CGPoint(x: 220, y: 220),
                                      parentNodeId: nil, beginEditing: false, quiet: true) else { return }
        await pause(0.5)
        let systemMouse = env["CANVAS_SYSTEM_MOUSE"] == "1"
        if systemMouse {
            let ready = directory.appendingPathComponent("mouse-ready")
            _ = await waitUntil({ FileManager.default.fileExists(atPath: ready.path) },
                                deadline: ProcessInfo.processInfo.systemUptime + 15)
            check((try? String(contentsOf: ready)) == "ready", "external system mouse driver ready")
        }
        @MainActor @discardableResult func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> Double {
            let now = ProcessInfo.processInfo.systemUptime
            guard let anchor = inputRouter.anchorView else { return now }
            let location = anchor.convert(point, to: nil)
            if systemMouse {
                let screen = window.convertPoint(toScreen: location)
                let quartz = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
                let cgType: CGEventType = type == .rightMouseDown ? .rightMouseDown
                    : type == .rightMouseUp ? .rightMouseUp
                    : type == .leftMouseDown ? .leftMouseDown
                    : (type == .leftMouseUp ? .leftMouseUp : (type == .mouseMoved ? .mouseMoved : .leftMouseDragged))
                let payload: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier),
                    "window": window.windowNumber, "type": cgType.rawValue, "x": quartz.x, "y": quartz.y,
                    "flags": 0, "clicks": 1]
                if var data = try? JSONSerialization.data(withJSONObject: payload) {
                    data.append(10)
                    let file = directory.appendingPathComponent("mouse-events.jsonl")
                    if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                    if let handle = try? FileHandle(forWritingTo: file) {
                        handle.seekToEndOfFile(); handle.write(data); try? handle.close()
                    }
                }
            } else if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                     timestamp: now, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 1, clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
            return now
        }
        let capture = MenuFrameCapture()
        var captureStarted = false
        if env["CLIPSLOTS_MENU_CAPTURE"] == "1" {
            do { try await capture.start(windowID: CGWindowID(window.windowNumber)); captureStarted = true }
            catch { check(false, "presented-frame capture: \(error)") }
        }
        let repeats = Int(env["CLIPSLOTS_MENU_REPEATS"] ?? "") ?? 6
        let nodeCount = Int(env["CLIPSLOTS_MENU_NODES"] ?? "") ?? (env["CLIPSLOTS_MENU_STRESS"] == "1" ? 100 : 1)
        let stress = nodeCount > 1
        if stress {
            zoom = 0.25
            // Keep the source's port below the toolbar at this smaller zoom.
            canvas.updateNode(id: source.id) { $0.x = 500; $0.y = 650 }
            for index in 1..<nodeCount {
                _ = canvas.placeSlot(pageId: source.pageId, groupId: "menu-stress-fixture", slot: index,
                                     name: "节点 \(index)",
                                     at: CGPoint(x: 160 + (index % 12) * 280, y: 1300 + (index / 12) * 220))
            }
        }
        await pause(0.4)
        try? String(ProcessInfo.processInfo.processIdentifier).write(to: directory.appendingPathComponent("menu-sample-ready"),
                                                                      atomically: true, encoding: .utf8)
        for index in 0..<repeats {
            for scenario in (env["CLIPSLOTS_MENU_SCENARIOS"]?.components(separatedBy: ",") ?? ["double", "drag", "right"]) {
                let reference = scenario == "drag", rightClick = scenario == "right"
                let name = "\(scenario)-\(index)"
                CanvasMenuLatencyObservation.events = []
                addMenu = nil
                lastBlankClick = nil
                if reference { canvas.select(id: source.id, additive: false) }
                else { canvas.clearSelection() }
                await pause(0.18)
                let point = CGPoint(x: min(viewSize.width - 290, 1010), y: 430)
                let captureThis = captureStarted && index == 0
                // The capture queue may finish a GPU transfer. Never synchronize
                // with it between the down/up events of a double click.
                if captureThis { capture.begin() }
                if reference {
                    guard let port = outputPortPoint else { check(false, "\(name) output port exists"); continue }
                    mouse(.mouseMoved, port)
                    mouse(.leftMouseDown, port)
                    await pause(0.04)
                    mouse(.leftMouseDragged, CGPoint(x: port.x + 45, y: port.y))
                    await pause(0.025)
                    mouse(.leftMouseDragged, point)
                    await pause(0.025)
                } else if !rightClick {
                    mouse(.mouseMoved, point)
                    mouse(.leftMouseDown, point)
                    await pause(0.025)
                    mouse(.leftMouseUp, point)
                    await pause(0.06)
                    mouse(.leftMouseDown, point)
                    await pause(0.025)
                }
                let beforeBodies = CanvasRenderDiagnostics.count
                CanvasMenuLatencyObservation.pickedAt = nil
                let trigger = mouse(rightClick ? .rightMouseDown : .leftMouseUp, point)
                let requestAt = await waitUntil({ addMenu != nil }, deadline: trigger + 1)
                if rightClick { mouse(.rightMouseUp, point) }
                let layoutAt = await waitUntil({
                    guard let rect = controlRegions["add-menu"], let row = controlRegions["add-menu-row-image"] else { return false }
                    return addMenu != nil && abs(rect.width - CanvasAddNodeMenu.width) < 0.1
                        && abs(row.width - CanvasAddNodeMenu.width) < 0.1
                        && abs(rect.minX - min(max(12, point.x - (reference ? CanvasAddNodeMenu.width / 2 : 0)),
                            max(12, viewSize.width - CanvasAddNodeMenu.width - 12))) < 0.5
                }, deadline: trigger + 1)
                let layoutEnd = layoutAt ?? ProcessInfo.processInfo.systemUptime
                let expectedParents = reference ? [source.id] : []
                check(addMenu?.allParentIds == expectedParents, "\(name) correct request parents")
                let bodyDelta = CanvasRenderDiagnostics.count - beforeBodies
                // Keep the first menu visible for pixel comparison; later cycles
                // click as soon as real final geometry is observed.
                if captureThis { await pause(max(0, 0.3 - (ProcessInfo.processInfo.systemUptime - trigger))) }
                let beforeCount = canvas.nodes.count
                var pickTime: Double?
                var pickTrigger: Double?
                if let row = controlRegions["add-menu-row-image"], layoutAt != nil {
                    let target = CGPoint(x: row.midX, y: row.midY)
                    mouse(.leftMouseDown, target)
                    await pause(systemMouse ? 0.015 : 0.001)
                    let pickedAt = mouse(.leftMouseUp, target)
                    pickTrigger = pickedAt
                    pickTime = await waitUntil({ canvas.nodes.count == beforeCount + 1 && addMenu == nil },
                                               deadline: pickedAt + 0.5)
                }
                let end = pickTime ?? ProcessInfo.processInfo.systemUptime
                let accepted = CanvasMenuLatencyObservation.pickedAt
                let latency = (layoutEnd - trigger) * 1000
                check(layoutAt != nil && latency <= 300, "\(name) final hit geometry <=300ms (\(Int(latency))ms)")
                check(pickTime != nil, "\(name) actual menu click creates node")
                // The interaction endpoint is the real menu action handler.
                // Record subsequent node creation/layout separately.
                if !captureThis { check(accepted.map { $0 - trigger <= 0.3 } == true, "\(name) trigger through accepted action <=300ms") }
                if let created = canvas.soleSelectedNode, created.id != source.id {
                    check(canvas.incomingEdges(of: created.id).map(\.fromNodeId).sorted() == expectedParents,
                          "\(name) selected action preserves references")
                }
                results.append(["scenario": scenario, "iteration": index,
                                "nodes": nodeCount, "request_ms": requestAt.map { ($0 - trigger) * 1000 } ?? -1,
                                "layout_ms": latency, "click_complete_ms": (end - trigger) * 1000,
                                "action_accepted_ms": accepted.map { ($0 - trigger) * 1000 } ?? -1,
                                "pick_event_ms": pickTrigger.map { ($0 - trigger) * 1000 } ?? -1,
                                "node_created_ms": pickTrigger.map { (end - $0) * 1000 } ?? -1,
                                "captured": captureThis, "node_body_evaluations": bodyDelta,
                                "events": CanvasMenuLatencyObservation.events,
                                "click_succeeded": pickTime != nil])
                if captureThis {
                    await pause(0.3)
                    let count = await capture.save(to: directory, name: name, trigger: trigger)
                    check(count > 1, "\(name) actual presented frames collected")
                }
                if pickTime != nil { _ = canvas.undo() }
                addMenu = nil
            }
        }
        await capture.stop()
        let report: [String: Any] = ["passed": passed, "failures": failures, "measurements": results,
                                    "input": systemMouse ? "system-CGEvent" : "AppKit-event-queue",
                                    "desktop_usable": displayUsable, "stress": stress,
                                    "theme": env["CLIPSLOTS_TEST_SKIN"] ?? "default",
                                    "appearance": env["CLIPSLOTS_TEST_APPEARANCE"] ?? "default"]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        await pause(0.2)
        NSApp.terminate(nil)
    }
}
#endif
