#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
enum SelectionMediaRegression {
    static var current: CanvasWorkspaceView?
    static var started = false
}

extension CanvasWorkspaceView {
    @MainActor
    func runSelectionMediaProbe(directory: URL) async {
        var passes = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            if value { passes += 1 } else { failures.append(label) }
            print("\(value ? "PASS" : "FAIL") \(label)"); fflush(stdout)
        }
        func settle(_ seconds: Double = 0.2) async { try? await Task.sleep(for: .seconds(seconds)) }
        func wait(_ condition: () -> Bool) async {
            for _ in 0..<100 { if condition() { return }; await settle(0.025) }
        }
        guard let anchor = inputRouter.anchorView, let window = anchor.window else { exit(3) }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) async {
            if let event = NSEvent.mouseEvent(with: type, location: anchor.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
            await settle(0.025)
        }
        func click(_ point: CGPoint) async {
            await mouse(.mouseMoved, point)
            await mouse(.leftMouseDown, point)
            await mouse(.leftMouseUp, point)
        }
        func screenshot(_ name: String) {
            guard let host = window.contentView,
                  let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
        do {
            NativeAccessibilityProbe.enable()
            window.setContentSize(CGSize(width: 1180, height: 760))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            canvas.isLibraryExpanded = false
            agentVisible = false
            canvas.activeTool = .select
            pan = .zero; zoom = 0.7
            let group = try store.specialStorage.createSpecialSlot(name: "选择与图片 fixture-\(UUID().uuidString)")
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for x in 0..<16 { for y in 0..<16 { bitmap.setColor(.red, atX: x, y: y) } }
            let png = bitmap.representation(using: .png, properties: [:])!
            var content = SlotContent(text: "真实附件来源")
            content.attachments = (0..<2).map {
                .init(name: "image-\($0).png", type: .file,
                      path: directory.appendingPathComponent("removed-source-\($0).png").path, data: png)
            }
            for slot in 1...2 {
                check(store.specialStorage.set(slot, content: content, in: group.id), "fixture \(slot) persisted")
                _ = canvas.placeSlot(pageId: group.pageId, groupId: group.id, slot: slot, name: "图片 \(slot)",
                    at: CGPoint(x: 250 + (slot - 1) * 550, y: 220))
            }
            let nodes = canvas.nodes.filter { $0.groupId == group.id }.sorted { $0.slot < $1.slot }
            guard nodes.count == 2 else { throw AgentCanvasError.unavailable }
            for node in nodes { canvas.updateNode(id: node.id) { $0.kind = .image; $0.mediaRole = .source } }
            let model = AgentSessionStore().canvasSession(canvas: canvas, store: store)
            guard let context = model.canvasContext else { throw AgentCanvasError.unavailable }
            model.draftReferences = []
            await settle(0.5)
            func nodePoint(_ node: CanvasNode) -> CGPoint {
                let frame = screenFrame(of: canvas.node(id: node.id)!)
                return CGPoint(x: frame.midX, y: frame.midY)
            }
            func blankPoint() throws -> CGPoint {
                let candidates = [CGPoint(x: viewSize.width - 70, y: 250),
                    CGPoint(x: viewSize.width - 70, y: 500), CGPoint(x: 650, y: 570)]
                guard let point = candidates.first(where: { isCanvasSurface(at: $0) && nodeBody(at: $0) == nil
                    && pileBody(at: $0) == nil }) else { throw AgentCanvasError.unavailable }
                return point
            }
            for dark in [false, true] {
                UserDefaults.standard.set((dark ? ThemeMode.dark : .light).rawValue, forKey: AppearanceDefaults.key)
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                canvas.clearSelection(); await settle()
                await click(nodePoint(nodes[0]))
                await wait { !context.isLoadingReferences }
                check(canvas.selectedNodeIds == [nodes[0].id], "native pointer selects image \(dark)")
                check(model.draftReferences.count == 1 && model.draftReferences.first?.images?.count == 2,
                      "selection captures both original images \(dark)")
                check(model.draftReferences.first?.images?.allSatisfy { $0.imageSnapshot == png } == true,
                      "canvas API input uses original image bytes \(dark)")
                let frozen = model.draftReferences
                await click(try blankPoint())
                check(canvas.selectedNodeIds.isEmpty && canvas.selectedGroupID == nil && canvas.selectedEdgeId == nil,
                      "single blank pointer clears complete selection \(dark)")
                check(model.draftReferences.isEmpty && composerFrame == nil && addMenu == nil,
                      "same blank click removes automatic Agent reference and composer \(dark)")
                await settle(0.3)
                check(model.draftReferences.isEmpty && !context.isLoadingReferences,
                      "cancelled async capture never resurrects reference \(dark)")
                check(frozen.first?.images?.count == 2, "already captured turn remains immutable \(dark)")
                await click(nodePoint(nodes[0])); await settle()
                await click(nodePoint(nodes[1])); await wait { !context.isLoadingReferences }
                check(model.draftReferences.count == 1 && model.draftReferences.first?.id == nodes[1].id,
                      "switching selection replaces automatic references \(dark)")
                context.addSelection(to: model)
                await wait { !context.isLoadingReferences }
                await click(try blankPoint())
                check(model.draftReferences.count == 1 && model.draftReferences.first?.selectionDerived == false,
                      "explicit pinned reference survives deselection \(dark)")
                model.draftReferences = []
                await click(nodePoint(nodes[0]))
                await click(try blankPoint())
                await settle(0.3)
                check(model.draftReferences.isEmpty, "rapid selection cancellation cannot send stale image \(dark)")
                screenshot("空白取消选中-\(dark ? "深色" : "浅色")")
            }
            if let visualGroup = canvas.groupNodes(Set(nodes.map(\.id)), name: "空白测试") {
                await settle()
                canvas.selectGroup(visualGroup.id); await settle()
                let rect = groupScreenBounds(visualGroup)!
                let point = CGPoint(x: rect.midX, y: rect.midY)
                check(nodeBody(at: point) == nil && isCanvasSurface(at: point), "group interior blank is actual canvas surface")
                await click(point)
                check(canvas.selectedGroupID == nil && canvas.selectedNodeIds.isEmpty,
                      "group interior blank cancels selection instead of reselecting whole group")
            }
            model.draftReferences = []
            canvas.select(id: nodes[0].id, additive: false)
            await settle()
            let point = try blankPoint()
            await click(point)
            await click(point)
            check(addMenu != nil && canvas.selectedNodeIds.isEmpty, "blank double click retains add-node behavior")
            addMenu = nil
            check(store.canvasReadFullContent(groupId: group.id, slot: 1)?.attachments.map { $0.resolveData() } == [png, png],
                  "selection and deselection preserve all slot attachment bytes")
        } catch { check(false, error.localizedDescription) }
        let report: [String: Any] = ["passed": failures.isEmpty, "passes": passes, "failures": failures,
            "fixture_only": true, "input": "AppKit event queue", "live_provider_calls": false]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("selection-media-regression.json"))
        exit(failures.isEmpty ? 0 : 1)
    }
}
#endif
