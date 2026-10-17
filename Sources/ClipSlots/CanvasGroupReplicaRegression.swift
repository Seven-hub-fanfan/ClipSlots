#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor func runGroupReplicaProbe(directory: URL) async {
        var live: CanvasWorkspaceView { CanvasAgentGroupsProbeBridge.current ?? self }
        var passed = 0, failures: [String] = []
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failures.append(name) }
            NSLog("[GroupReplica] %@ %@", value ? "PASS" : "FAIL", name)
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(220)) }
        func capture(_ name: String) {
            guard let root = live.inputRouter.anchorView?.window?.contentView,
                  let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
        func elements(_ object: AnyObject, depth: Int = 0) -> [AnyObject] {
            guard depth < 40 else { return [] }
            let children = object.accessibilityChildren?() ?? []
            return [object] + (children.isEmpty ? (object as? NSView)?.subviews ?? [] : children)
                .flatMap { elements($0 as AnyObject, depth: depth + 1) }
        }
        func press(_ root: NSView, id: String) -> Bool {
            elements(root).first { ($0.accessibilityIdentifier?() ?? "") == id }?
                .accessibilityPerformPress?() == true
        }
        guard let anchor = live.inputRouter.anchorView, let window = anchor.window else { return }
        _ = await AgentProcessRunner.run(executable: "/usr/bin/swift", arguments: ["-e", """
            import ApplicationServices
            let app = AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!)
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            var windows: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
            """, String(ProcessInfo.processInfo.processIdentifier)], timeout: 15)
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) -> Bool {
            let event = NSEvent.mouseEvent(with: type, location: anchor.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: clicks, pressure: 1)!
            return live.inputRouter.routeForRegression(event)
        }
        func drag(_ start: CGPoint, _ end: CGPoint) async {
            let owned = mouse(.leftMouseDown, start)
            NSLog("[GroupReplica] pointer %@ owned=%@ target=%@ controls=%@", NSStringFromPoint(start),
                  String(owned), String(describing: live.pointerSession?.target),
                  live.activeControlRegions.filter { $0.value.contains(start) }.description)
            for step in 1...8 {
                let fraction = CGFloat(step) / 8
                _ = mouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * fraction,
                                                     y: start.y + (end.y - start.y) * fraction))
                try? await Task.sleep(for: .milliseconds(8))
            }
            _ = mouse(.leftMouseUp, end)
            await settle()
        }
        window.setContentSize(CGSize(width: 1440, height: 900))
        canvas.isLibraryExpanded = false
        live.pan = CGSize(width: 200, height: 140); live.zoom = 0.65
        await settle()
        let a = live.createNode(kind: .text, at: CGPoint(x: 180, y: 350), parentNodeId: nil,
                                beginEditing: false, quiet: true)!
        let b = live.createNode(kind: .image, at: CGPoint(x: 750, y: 350), parentNodeId: a.id,
                                beginEditing: false, quiet: true)!
        let c = live.createNode(kind: .video, at: CGPoint(x: 1650, y: 350), parentNodeId: nil,
                                beginEditing: false, quiet: true)!
        let d = live.createNode(kind: .text, at: CGPoint(x: 2200, y: 350), parentNodeId: nil,
                                beginEditing: false, quiet: true)!
        live.commitEdit(a, text: "森林中的光线与角色参考")
        live.commitEdit(b, text: "保持构图与光影关系")
        canvas.updateNodeGeneration(id: b.id, model: "seedream45", ratio: "16:9", count: 4, resolution: "2K")
        canvas.updateNodeGeneration(id: c.id, model: "seedance20", ratio: "9:16", count: 1, resolution: "720p")
        let originals = canvas.nodes, originalEdges = canvas.edges
        let beforeHistory = canvas.history.entries.count
        let group = canvas.groupNodes([a.id, b.id])!
        check(canvas.history.entries.count == beforeHistory + 1, "creation records exactly one undo transaction")
        check(canvas.nodes == originals && canvas.edges == originalEdges, "group creation preserves all node fields and edges")
        check(group.containerFrame == CanvasGroupGeometry.enclosing([canvas.node(id: a.id)!, canvas.node(id: b.id)!]),
              "container uses exact union plus 20 world units")
        check(group.name == "新建组" && group.layoutType == .horizontal, "creation uses reference defaults")
        check(canvas.selectedGroupID == group.id && live.selectionScreenBounds == nil && live.composerFrame == nil,
              "group selection suppresses node multiselect overlay and composer")
        await settle()
        check(live.activeControlRegions["group-toolbar-\(group.id)"] != nil, "selected group has capsule toolbar")
        if let root = window.contentView {
            check(press(root, id: "canvas-group-layout"), "captioned layout button opens choices")
            await settle()
            let panel = NSApp.windows.filter(\.isVisible).compactMap(\.contentView)
                .first { elements($0).contains { ($0.accessibilityIdentifier?() ?? "") == "canvas-group-layout-grid" } }
            check(panel != nil, "layout choices expose descriptions in native panel")
            if let panel {
                check(press(panel, id: "canvas-group-layout-horizontal"), "native layout choice applies and closes")
                _ = canvas.undo()
                check(canvas.nodes == originals, "native layout choice undo restores interaction fixture")
            }
            await settle()
        }
        canvas.clearSelection(); await settle()
        check(live.activeControlRegions["group-toolbar-\(group.id)"] == nil, "deselection immediately releases toolbar region")
        let header = live.groupHeaderFrame(group)!
        let titlePoint = CGPoint(x: header.minX + 40, y: header.midY)
        check(mouse(.leftMouseDown, titlePoint), "native title press belongs to group")
        _ = mouse(.leftMouseUp, titlePoint)
        check(canvas.selectedGroupID == group.id, "title selects container independently")
        for scale in [CGFloat(0.4), 0.65, 1] {
            live.zoom = scale; await settle()
            let before = canvas.nodes
            let oldFrame = CanvasGroupGeometry.frame(canvas.groups.first!, nodes: canvas.nodes)!
            let title = live.groupHeaderFrame(canvas.groups.first!)!
            let start = CGPoint(x: title.minX + 36, y: title.midY)
            let delta = CGSize(width: 45, height: 22)
            await drag(start, CGPoint(x: start.x + delta.width * scale, y: start.y + delta.height * scale))
            let moved = canvas.groups.first!.containerFrame!
            check(abs(moved.minX - oldFrame.minX - delta.width) < 0.001 &&
                  abs(moved.minY - oldFrame.minY - delta.height) < 0.001, "group drag follows pointer at zoom \(scale)")
            check(before.allSatisfy { old in
                let now = canvas.node(id: old.id)!
                let inside = group.nodeIDs.contains(old.id)
                return abs(now.x - old.x - (inside ? delta.width : 0)) < 0.001 &&
                    abs(now.y - old.y - (inside ? delta.height : 0)) < 0.001 &&
                    now.width == old.width && now.height == old.height
            }, "group drag moves only its members together at zoom \(scale)")
            _ = canvas.undo(); check(canvas.nodes == before, "group drag undo restores exact geometry at zoom \(scale)")
        }
        live.zoom = 0.65; await settle()
        for handle in CanvasGroupResizeHandle.allCases {
            canvas.selectGroup(group.id); await settle()
            guard !canvas.groups.isEmpty else {
                check(false, "group disappeared before handle \(handle)")
                NSLog("[GroupReplica] history cursor=%ld entries=%@", canvas.history.cursor,
                      canvas.history.entries.map { "\($0.kind):\($0.detail)" }.description)
                break
            }
            let before = canvas.nodes
            let oldFrame = canvas.groups.first!.containerFrame!
            let bounds = live.groupScreenBounds(canvas.groups.first!)!
            let start = handle.point(in: bounds)
            await drag(start, CGPoint(x: start.x + 18, y: start.y + 12))
            check(canvas.groups.first!.containerFrame != oldFrame, "\(handle) native handle changes container")
            check(canvas.nodes == before && canvas.edges == originalEdges, "\(handle) resize never scales media or moves nodes")
            if canvas.groups.first!.containerFrame != oldFrame { _ = canvas.undo() }
            check(canvas.groups.first!.containerFrame == oldFrame, "\(handle) resize undo restores container")
        }
        let nowB = canvas.node(id: b.id)!
        canvas.selectGroup(group.id); await settle()
        let frameB = live.screenFrame(of: nowB)
        await drag(CGPoint(x: frameB.midX, y: frameB.midY),
                   CGPoint(x: frameB.midX + 26, y: frameB.midY + 8))
        check(canvas.selectedGroupID == nil && canvas.selectedNodeIds == [b.id], "dragging child selects only that child")
        check(canvas.node(id: a.id)?.frame == originals.first(where: { $0.id == a.id })?.frame,
              "child drag leaves siblings still")
        check(canvas.groups.first!.containerFrame == group.containerFrame, "child drag does not recompute container bounds")
        _ = canvas.undo()
        let beforeLeave = canvas.history.cursor
        canvas.select(id: b.id, additive: false)
        canvas.moveNodes(ids: [b.id], by: CGSize(width: 1600, height: 0))
        check(canvas.groups.first?.nodeIDs == [a.id], "fully outside node leaves group")
        check(canvas.history.cursor == beforeLeave + 1, "move and membership change share undo")
        _ = canvas.undo()
        check(canvas.groups.first == group && canvas.edges == originalEdges, "undo restores membership with nodes and links")
        let originalB = canvas.node(id: b.id)!
        canvas.select(id: b.id, additive: false)
        canvas.moveNodes(ids: [b.id], by: CGSize(width: group.containerFrame!.maxX - originalB.x - 10, height: 0))
        check(canvas.groups.first!.nodeIDs.contains(b.id), "partial overlap retains membership")
        _ = canvas.undo()
        let enlarged = group.containerFrame!.union(canvas.node(id: c.id)!.frame).insetBy(dx: -40, dy: -40)
        canvas.resizeGroup(group.id, frame: enlarged)
        canvas.select(id: c.id, additive: false)
        canvas.moveNodes(ids: [c.id], by: CGSize(width: 10, height: 0))
        check(canvas.groups.first!.nodeIDs.contains(c.id), "fully contained ungrouped node joins group")
        _ = canvas.undo(); _ = canvas.undo()
        let extended = canvas.groupNodes([a.id, c.id])!
        check(extended.id == group.id && Set(extended.nodeIDs) == [a.id, b.id, c.id], "one group plus extra extends original identity")
        _ = canvas.undo()
        let second = canvas.groupNodes([c.id, d.id])!
        let extracted = canvas.groupNodes([b.id, c.id])!
        check(extracted.id != group.id && extracted.id != second.id, "members from multiple groups form a fresh group")
        check(canvas.groups.first(where: { $0.id == group.id })?.nodeIDs == [a.id] &&
              canvas.groups.first(where: { $0.id == second.id })?.nodeIDs == [d.id],
              "multiple group extraction preserves unselected originals")
        _ = canvas.undo(); _ = canvas.undo()
        canvas.selectGroup(group.id)
        for color in CanvasGroupColor.allCases {
            canvas.setGroupColor(group.id, color: color)
            check(canvas.groups.first?.color == color, "background \(color) applies")
            _ = canvas.undo()
            check(canvas.groups.first?.color == nil, "background \(color) undo")
            _ = canvas.redo()
            check(canvas.groups.first?.color == color, "background \(color) redo")
            _ = canvas.undo()
        }
        for layout in CanvasGroupLayoutType.allCases {
            let before = canvas.nodes
            canvas.arrangeGroup(group.id, layout: layout)
            check(canvas.groups.first?.layoutType == layout, "\(layout) applies to container")
            check(canvas.nodes.allSatisfy { node in
                let old = before.first { $0.id == node.id }!
                var geometryOnly = node
                geometryOnly.x = old.x; geometryOnly.y = old.y
                geometryOnly.updatedAt = old.updatedAt
                return geometryOnly == old
            }, "\(layout) preserves model ratio resolution count dimensions and identity")
            _ = live.handleKeyAction(.fitSelection)
            await settle()
            capture("group-layout-\(layout)")
            _ = canvas.undo(); check(canvas.nodes == before, "\(layout) undo restores original coordinates")
        }
        canvas.selectGroup(group.id); await settle()
        let title = live.groupHeaderFrame(canvas.groups.first!)!
        _ = mouse(.leftMouseDown, CGPoint(x: title.minX + 30, y: title.midY), clicks: 2)
        _ = mouse(.leftMouseUp, CGPoint(x: title.minX + 30, y: title.midY), clicks: 2)
        await settle()
        check(live.editingGroupID == group.id && window.sheets.isEmpty, "double-click mounts inline title without alert sheet")
        live.groupTitleDraft = "镜头组 · 森林"
        live.finishGroupTitle(); await settle()
        check(canvas.groups.first?.name == "镜头组 · 森林", "inline title saves nonempty text")
        canvas.renameGroup(group.id, name: "  ")
        check(canvas.groups.first?.name == "  ", "group title preserves target-observed whitespace")
        let titleHistory = canvas.history.cursor
        canvas.renameGroup(group.id, name: "")
        check(canvas.groups.first?.name == "  " && canvas.history.cursor == titleHistory,
              "empty title preserves the previous title and undo history")
        _ = canvas.undo()
        check(canvas.groups.first?.name == "镜头组 · 森林", "whitespace title undo restores the exact prior value")
        _ = canvas.redo()
        check(canvas.groups.first?.name == "  ", "whitespace title redo restores the exact whitespace")
        canvas.renameGroup(group.id, name: " REA Group ")
        check(canvas.groups.first?.name == " REA Group ", "group title retains leading and trailing spaces")
        canvas.renameGroup(group.id, name: "镜头组 · 森林")
        do {
            let draft = try live.groupWorkflow(canvas.groups.first!)
            check(draft.graph.nodes.count == 2 && draft.graph.edges.count == 1,
                  "workflow captures exactly group nodes and internal connections")
            check(Set(draft.provenance.sources.map(\.nodeID)) == [a.id, b.id],
                  "workflow excludes outside nodes and preserves provenance")
            let path = directory.appendingPathComponent("workflow.json")
            try JSONEncoder().encode(draft).write(to: path)
            check(try JSONDecoder().decode(WorkflowSkill.self, from: Data(contentsOf: path)) == draft,
                  "workflow remains reusable after serialization")
        } catch { check(false, "workflow \(error)") }
        let currentGroup = canvas.groups.first!
        live.saveGroupWorkflow(currentGroup); await settle()
        if let sheet = window.sheets.first?.contentView {
            check(press(sheet, id: "workflow-skill-save"), "workflow sheet saves through actual native control")
            for _ in 0..<50 where !window.sheets.isEmpty { await settle() }
            let linked = canvas.groups.first?.workflowSkillID
            check(linked != nil && WorkflowSkillStore().list(projectID: canvas.activeProjectId).contains { $0.id == linked },
                  "saved workflow links back to group")
            live.saveGroupWorkflow(canvas.groups.first!); await settle()
            if let updateSheet = window.sheets.first?.contentView {
                check(press(updateSheet, id: "workflow-skill-save"), "existing group opens versioned workflow update")
                for _ in 0..<50 where !window.sheets.isEmpty { await settle() }
                check(WorkflowSkillStore().list(projectID: canvas.activeProjectId).first { $0.id == linked }?.version == 2,
                      "update preserves workflow identity and creates version two")
            } else { check(false, "workflow update sheet opens") }
        } else { check(false, "workflow save sheet opens") }
        live.requestGroupRun(canvas.groups.first!); await settle()
        check(live.groupRunAlert != nil && window.sheets.count == 1 && canvas.selectionGenerationTask == nil,
              "run all opens confirmation before any submission")
        if let alert = live.groupRunAlert {
            alert.buttons[1].performClick(nil)
            for _ in 0..<30 where !window.sheets.isEmpty { await settle() }
        }
        check(window.sheets.isEmpty && canvas.selectionGenerationTask == nil, "cancel run closes sheet without starting generation")
        let project = canvas.activeProjectId
        let saved = canvas.groups
        _ = canvas.createProject(name: "编组持久化回归"); _ = canvas.switchProject(to: project)
        check(canvas.groups == saved, "project reload preserves title frame color layout and membership")
        for skin in ["minimal", "colorful"] {
            for appearance in ["light", "dark"] {
                AppSkinCenter.apply(AppSkin(rawValue: skin)!)
                NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                canvas.selectGroup(group.id)
                canvas.setGroupColor(group.id, color: .blue)
                _ = live.handleKeyAction(.fitSelection)
                await settle()
                let toolbar = live.controlRegions["group-toolbar-\(group.id)"]
                check(toolbar?.height == 64, "\(skin)/\(appearance) capsule provides room for visible captions")
                check(toolbar.map { live.canvasContentViewport.contains($0) } == true, "\(skin)/\(appearance) toolbar stays in canvas")
                check(live.controlRegions["selection-actions"] == nil, "\(skin)/\(appearance) does not duplicate node toolbar")
                capture("group-\(skin)-\(appearance)")
            }
        }
        window.setContentSize(CGSize(width: 780, height: 720)); await settle()
        check(live.controlRegions["group-toolbar-\(group.id)"].map { live.canvasContentViewport.contains($0) } == true,
              "narrow window keeps whole toolbar reachable")
        capture("group-narrow")
        let ungroupBefore = canvas.nodes, ungroupEdges = canvas.edges
        canvas.ungroupNodes(Set(group.nodeIDs))
        check(canvas.groups.isEmpty && canvas.nodes == ungroupBefore && canvas.edges == ungroupEdges,
              "ungroup preserves world coordinates contents and all edges")
        _ = canvas.undo()
        check(canvas.groups.count == 1 && canvas.nodes == ungroupBefore, "ungroup undo restores exact group")
        let single = canvas.groupNodes([a.id])
        check(single == nil, "user grouping rejects one node")
        check(live.pointerSession == nil && live.groupDragID == nil && live.groupResizePreview == nil,
              "all pointer sessions and transient geometry are released")
        check(canvas.flushSave(), "final document flush succeeds")
        func flowClock(in layer: CALayer) -> CAAnimation? {
            layer.animation(forKey: "flow") ?? (layer.sublayers ?? []).compactMap { flowClock(in: $0) }.first
        }
        func flowClock(in view: NSView) -> CAAnimation? {
            view.layer.flatMap { flowClock(in: $0) } ?? view.subviews.compactMap { flowClock(in: $0) }.first
        }
        if let edge = canvas.edges.first, let root = window.contentView {
            window.setContentSize(CGSize(width: 1440, height: 900))
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await settle()
            canvas.selectGroup(group.id)
            _ = live.handleKeyAction(.fitSelection)
            canvas.setEdgeAnimated(edgeId: edge.id, animated: true)
            await settle()
            let clock = flowClock(in: root)
            check(clock?.duration == 2 && clock?.repeatCount == .infinity,
                  "selected animated endpoints install a native two-second flow clock")
            capture("group-edge-flow")
            canvas.clearSelection(); await settle()
            check(flowClock(in: root) == nil, "deselecting endpoints releases every edge animation clock")
            canvas.selectGroup(group.id); await settle()
            check(flowClock(in: root) != nil, "reselecting endpoints resumes flow without changing the graph")
            window.miniaturize(nil); await settle()
            check(flowClock(in: root) == nil, "minimizing the window stops offscreen edge clocks")
            window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
            canvas.setEdgeAnimated(edgeId: edge.id, animated: false); await settle()
            check(flowClock(in: root) == nil, "disabling edge animation removes its native overlay")
        } else { check(false, "flow fixture has a real edge and host") }
        await runTapNowAgentReplicaProbe(directory: directory, check: check)
        let result: [String: Any] = ["passed": passed, "failures": failures, "complete": true,
            "expectedCrateSubmissions": 0,
            "scope": "native Group interaction plus Agent queue, fork, persistence and late event isolation; fixture backends only"]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}
#endif
