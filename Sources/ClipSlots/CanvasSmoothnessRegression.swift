#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit

enum CanvasSmoothnessTiming {
    static var values: [[Double]] = []
}

extension CanvasWorkspaceView {
    @MainActor func runSmoothnessProbe(directory: URL) async {
        var passed = 0, failures: [String] = [], dragTimes: [Double] = []
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failures.append(label) }
            NSLog("[Smoothness] \(condition ? "PASS" : "FAIL") \(label)")
        }
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        guard let anchor = inputRouter.anchorView, let window = anchor.window else { return }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> Bool {
            guard let event = NSEvent.mouseEvent(with: type, location: anchor.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
            return inputRouter.routeForRegression(event)
        }
        canvas.isLibraryExpanded = false; agentVisible = false; pan = .zero; zoom = 0.65
        guard let source = createNode(kind: .image, at: CGPoint(x: 240, y: 240), parentNodeId: nil,
                beginEditing: false, quiet: true),
              let target = createNode(kind: .image, at: CGPoint(x: 820, y: 240), parentNodeId: nil,
                beginEditing: false, quiet: true) else { return }
        for node in [source, target] { canvas.updateNode(id: node.id) { $0.mediaRole = .generation } }
        canvas.select(id: source.id, additive: false)
        refreshCanvasContent()
        await pause(0.5)
        let capture = MenuFrameCapture()
        do {
            try await capture.start(windowID: CGWindowID(window.windowNumber))
            capture.begin()
            let trigger = ProcessInfo.processInfo.systemUptime
            canvas.clearSelection()
            await pause(0.3)
            check(composerFrame == nil && !activeControlRegions.keys.contains("selection-actions"),
                  "exiting controls immediately relinquish input")
            _ = await capture.save(to: directory, name: "floating-exit", trigger: trigger)
            canvas.select(id: source.id, additive: false)
            await pause(0.4)
            capture.begin()
            let restart = ProcessInfo.processInfo.systemUptime
            canvas.clearSelection()
            await pause(0.05)
            canvas.select(id: source.id, additive: false)
            await pause(0.3)
            check(composerFrame != nil, "reselection cancels stale exit removal")
            _ = await capture.save(to: directory, name: "floating-reenter", trigger: restart)
            await capture.stop()
        } catch { check(false, "floating presented frame capture \(error)") }

        let group = source.groupId
        let invalid = canvas.placeSlot(pageId: source.pageId, groupId: "smoothness-fixture", slot: 101,
            name: "不兼容目标", at: CGPoint(x: 820, y: 720), kind: .image).node
        let videoNode = canvas.placeSlot(pageId: source.pageId, groupId: "smoothness-fixture", slot: 102,
            name: "视频源", at: CGPoint(x: 200, y: 720), kind: .video).node
        linkDrag = .init(fromNodeId: videoNode.id, start: outputPortHome(of: videoNode),
            cursor: CGPoint(x: 1300, y: 300), targetNodeId: nil)
        check(connectionAppearance(for: invalid) == .idle, "unrelated incompatible card stays unmasked")
        linkDrag?.cursor = CGPoint(x: screenFrame(of: invalid).midX, y: screenFrame(of: invalid).midY)
        check(connectionAppearance(for: invalid) == .invalid, "aimed incompatible card explains rejection")
        cancelCanvasPointer()

        canvas.connectionPolicy = .init(readOnly: true)
        check(linkCandidates(from: source.id).isEmpty, "readonly policy excludes candidates")
        check(canvas.connect(from: source.id, to: target.id) == .disabled, "readonly commit is rejected")
        canvas.connectionPolicy = .init(lockedNodeIDs: [target.id])
        check(!linkCandidates(from: source.id).contains { $0.id == target.id }, "locked target excluded from preview")
        check(canvas.connect(from: source.id, to: target.id) == .disabled, "locked target commit rejected")
        canvas.connectionPolicy = .init(nodesConnectable: false)
        check(staticPortNodes.isEmpty, "global policy force hides plus")
        canvas.connectionPolicy = .init()
        check(linkCandidates(from: source.id).contains { $0.id == target.id }, "policy change invalidates candidates")

        let count = 100
        for index in 1...(count - canvas.nodes.count) {
            _ = canvas.placeSlot(pageId: source.pageId, groupId: "smoothness-fixture", slot: index,
                name: "负载 \(index)", at: CGPoint(x: 180 + (index % 10) * 280, y: 1400 + (index / 10) * 240))
        }
        canvas.select(id: source.id, additive: false)
        await pause(0.5)
        let port = outputPortHome(of: source)
        check(mouse(.leftMouseDown, port), "real pointer owner captures source")
        _ = mouse(.leftMouseDragged, CGPoint(x: port.x + 5, y: port.y))
        for index in 0..<180 {
            let point = CGPoint(x: 800 + CGFloat(index % 40), y: 330 + CGFloat(index % 30))
            let start = ProcessInfo.processInfo.systemUptime
            _ = mouse(.leftMouseDragged, point)
            dragTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            await pause(1 / 120)
        }
        cancelCanvasPointer()
        let sorted = dragTimes.sorted(), p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        check(p95 < 4, "100 node drag handler p95 below 4ms (\(p95))")

        let request = AddNodeRequest(screenPoint: CGPoint(x: 1000, y: 500),
            canvasPoint: CGPoint(x: 1600, y: 500), parentNodeId: nil)
        let before = canvas.nodes.count
        await createNodeFromMenu(kind: .text, request: request)
        guard let created = canvas.soleSelectedNode else { return }
        check(canvas.nodes.count == before + 1 && created.groupId == group, "async creation commits verified private slot")
        check(created.slot != source.slot && created.slot != target.slot, "async creation preserves occupied slots")
        _ = canvas.undo()
        check(!activeControlRegions.keys.contains("source-upload-\(created.id)"), "removed node cannot retain a hit region")
        _ = canvas.redo()
        check(canvas.node(id: created.id) != nil, "async creation remains undoable and redoable")
        let document = store.canvasTextDocument(groupID: created.groupId, slot: created.slot)
        document.edit("后台新建前的未落盘正文🙂")
        await createNodeFromMenu(kind: .image, request: request)
        check(store.canvasSlotText(groupId: created.groupId, slot: created.slot) == "后台新建前的未落盘正文🙂",
              "async creation flushes pending draft without losing text")
        check(canvas.history.entries.contains { $0.slotEdit?.after == "后台新建前的未落盘正文🙂" },
              "draft history precedes later node creation")
        let report: [String: Any] = ["passed": passed, "failures": failures, "complete": true,
            "expectedCrateSubmissions": 0, "drag_handler_ms": dragTimes, "drag_p95_ms": p95,
            "drag_hover_target_ms": CanvasSmoothnessTiming.values,
            "scope": "isolated local input, lifecycle, policies and async storage; remote locks and paid TapNow generation unverified"]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}
#endif
