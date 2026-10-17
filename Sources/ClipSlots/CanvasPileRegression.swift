#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor func runPileProbe(directory: URL) async {
        var live: CanvasWorkspaceView { CanvasAgentGroupsProbeBridge.current ?? self }
        var passed = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1 } else { failures.append(label) }
            NSLog("[PileProbe] %@ %@", value ? "PASS" : "FAIL", label)
        }
        let systemInput = ProcessInfo.processInfo.environment["CANVAS_SYSTEM_MOUSE"] == "1"
        let presentationOnly = ProcessInfo.processInfo.environment["CLIPSLOTS_PILE_PRESENTATION_ONLY"] == "1"
        let accessibilityOnly = ProcessInfo.processInfo.environment["CLIPSLOTS_PILE_ACCESSIBILITY_ONLY"] == "1"
        var galleryMotion: [[String: Any]] = []
        var galleryReducedMotion = false
        var complete = false
        var pointerEvidence: [[String: Any]] = []
        defer {
            let report: [String: Any] = ["passed": passed, "failures": failures, "complete": complete,
                "expectedCrateSubmissions": 0, "systemInputValidated": systemInput,
                "isolatedAppKitHost": CanvasPileProbeWindow.usedFallback,
                "productSceneLaunchValidated": false,
                "galleryMotion": galleryMotion, "reducedMotion": galleryReducedMotion,
                "pointerEvidence": pointerEvidence,
                "galleryEventDelivery": accessibilityOnly ? "public AX button actions; mouse excluded"
                    : presentationOnly ? "none: lifecycle and presentation only"
                    : systemInput ? "system CGEvent" : "native AppKit event queue",
                "presentationOnly": presentationOnly, "accessibilityOnly": accessibilityOnly,
                "nativeButtonsValidated": complete && !presentationOnly && failures.isEmpty,
                "mouseAndNativeButtonsValidated": complete && !presentationOnly && !accessibilityOnly && failures.isEmpty,
                "scope": accessibilityOnly ? "native Pile presentation and public AX buttons; mouse excluded"
                    : presentationOnly ? "native Pile presentation and transactions; mouse and buttons excluded"
                    : "native Pile transactions, pointer routing, gallery lifecycle, pickup, return and extraction",
                "evidenceLimit": "Native probe is not a TapNow runtime or screenshot-equivalence claim. Pose records are destinations; external captures have their own timestamps."]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
            NSApp.terminate(nil)
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(650)) }
        func capture(_ name: String) {
            guard let root = live.inputRouter.anchorView?.window?.contentView,
                  let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
        guard live.inputRouter.anchorView?.window != nil else {
            check(false, "Pile probe has an attached input anchor"); return
        }
        if !presentationOnly {
        _ = await AgentProcessRunner.run(executable: "/usr/bin/swift", arguments: ["-e", """
            import ApplicationServices
            let app = AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!)
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            var windows: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
            """, String(ProcessInfo.processInfo.processIdentifier)], timeout: 15)
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, gallery: Bool = false) async -> Bool {
            // SwiftUI may replace the anchor when the sidebar or gallery changes.
            // Resolve it per event, just as the actual input router does.
            guard let anchor = live.inputRouter.anchorView, let window = anchor.window else {
                check(false, "Pointer delivery has an attached current anchor"); return false
            }
            let location = anchor.convert(point, to: nil)
            var evidence: [String: Any] = ["type": type.rawValue, "gallery": gallery,
                "point": NSStringFromPoint(point), "windowPoint": NSStringFromPoint(location),
                "window": window.windowNumber, "anchor": String(describing: ObjectIdentifier(anchor)),
                "anchorBounds": NSStringFromRect(anchor.bounds),
                "contentHit": String(describing: window.contentView?.hitTest(location))]
            if systemInput {
                let token = UUID().uuidString
                let screen = window.convertPoint(toScreen: location)
                let kind: CGEventType = type == .leftMouseDown ? .leftMouseDown
                    : type == .leftMouseUp ? .leftMouseUp : .leftMouseDragged
                let row: [String: Any] = ["token": token, "pid": Int(ProcessInfo.processInfo.processIdentifier),
                    "window": window.windowNumber, "type": kind.rawValue, "x": screen.x,
                    "y": (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y, "flags": 0, "clicks": 1]
                var data = try! JSONSerialization.data(withJSONObject: row); data.append(10)
                let url = directory.appendingPathComponent("mouse-events.jsonl")
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                guard let file = try? FileHandle(forWritingTo: url) else { return false }
                file.seekToEndOfFile(); file.write(data); try? file.close()
                evidence["delivery"] = "system driver request"
                pointerEvidence.append(evidence)
                let receipt = directory.appendingPathComponent("mouse-ack-\(token).json")
                for _ in 0..<300 {
                    if FileManager.default.fileExists(atPath: receipt.path) { return true }
                    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("mouse-driver-result.json").path) {
                        return false
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                check(false, "System pointer producer acknowledges event posting")
                return false
            }
            guard let event = NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
            if gallery {
                NSApp.postEvent(event, atStart: false)
                evidence["delivery"] = "AppKit event queue"
                pointerEvidence.append(evidence)
                return true
            }
            let consumed = live.inputRouter.routeForRegression(event)
            evidence["consumed"] = consumed
            pointerEvidence.append(evidence)
            return consumed
        }
        canvas.isLibraryExpanded = false
        live.agentVisible = false
        live.pan = CGSize(width: 160, height: 120); live.zoom = 0.65
        await settle()
        let kinds: [CanvasNodeKind] = [.text, .image, .video, .text, .image, .image]
        var created: [CanvasNode] = []
        for (index, kind) in kinds.enumerated() {
            if let node = live.createNode(kind: kind, at: CGPoint(x: 180 + index * 420, y: 350),
                parentNodeId: index == 1 || index == 2 ? created.last?.id : nil, beginEditing: false, quiet: true) {
                canvas.updateNode(id: node.id) { $0.width = 320; $0.height = 240 }
                created.append(canvas.node(id: node.id) ?? node)
            }
        }
        guard created.count == 6 else { check(false, "Pile fixture creates six nodes"); return }
        let a = created[0], b = created[1], c = created[2], d = created[3], e = created[4], f = created[5]
        for node in created where node.kind.isMediaNode {
            let key = node.kind == .video ? "CLIPSLOTS_PILE_VIDEO_FIXTURE" : "CLIPSLOTS_PILE_IMAGE_FIXTURE"
            if let path = ProcessInfo.processInfo.environment[key] {
                var attachment = SlotContent.SlotAttachment(name: URL(fileURLWithPath: path).lastPathComponent,
                    type: node.kind == .video ? .file : .image)
                attachment.storagePath = path
                if let saved = store.appendCanvasGeneratedAttachment(attachment, groupId: node.groupId, slot: node.slot) {
                    canvas.updateNode(id: node.id) { $0.outputAttachmentIds = [saved.id.uuidString] }
                }
            }
        }
        _ = store.writeCanvasSlotText(groupId: a.groupId, slot: a.slot, text: "完整正文🙂\nPile identity sentinel")
        live.synchronizeMediaLayouts()
        await settle()
        for node in [b, c] {
            if let current = canvas.node(id: node.id), let media = live.previewableMedia(of: current) {
                let image: NSImage? = await withCheckedContinuation { continuation in
                    CanvasAttachmentThumbnails.load(media, maxPixel: 640) { continuation.resume(returning: $0) }
                }
                check(image != nil, "\(node.kind.displayName) externalized media decodes for Gallery at bounded size")
            } else { check(false, "\(node.kind.displayName) externalized media is available to Gallery") }
        }
        await settle()
        let originals = canvas.nodes, originalEdges = canvas.edges
        let count = canvas.history.count
        canvas.selectedNodeIds = [a.id, b.id]
        check(live.handleKeyAction(.pile), "native CmdG action is consumed")
        await settle()
        guard let first = canvas.piles.first else { check(false, "Pile creation produces an entity"); return }
        check(first.memberIDs == [a.id, b.id] && canvas.selectedPile?.id == first.id, "CmdG creates and selects independent Pile")
        check(canvas.groups.isEmpty && canvas.nodes == originals && canvas.edges == originalEdges, "Pile preserves node fields and graph")
        check(canvas.history.count == count + 1, "Pile creation records one history transaction")
        check(live.nodesInPaintOrder.allSatisfy { !first.memberIDs.contains($0.id) }, "members lose independent canvas hit targets")
        check(live.nodeScreenFrames[a.id] == live.pileScreenFrame(first)
            && live.nodeScreenFrames[b.id] == live.pileScreenFrame(first), "hidden member endpoints project to the Pile")
        check(live.renderedCanvasEdges.count == 1 && canvas.edges.count == 2, "internal wire hides while external wire remains")
        check(live.staticPortNodes.isEmpty && canvas.soleSelectedNode == nil, "Pile does not expose member ports or generation composer")
        capture("pile-stack")
        if presentationOnly || accessibilityOnly {
            galleryMotion = await live.runPilePresentationProbe(directory: directory, pileID: first.id, check: check)
            galleryReducedMotion = CanvasPileMotionAccessibility.shouldReduceMotion(
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            if accessibilityOnly {
                await live.runPileAccessibilityProbe(directory: directory, pileID: first.id, check: check)
            }
        } else {
        let start = live.pileScreenFrame(first)
        let center = CGPoint(x: start.midX, y: start.midY)
        _ = await mouse(.leftMouseDown, center); await settle()
        let ownsPointer: Bool
        if case .pile(let id) = live.pointerSession?.target { ownsPointer = id == first.id }
        else { ownsPointer = false }
        check(ownsPointer, "native Pile press owns the pointer")
        // A missing physical input must not undo fixture creation and cascade
        // into unrelated data failures. The deferred report remains incomplete.
        guard ownsPointer else { return }
        let end = CGPoint(x: center.x + 85, y: center.y + 31)
        _ = await mouse(.leftMouseDragged, end); await settle()
        _ = await mouse(.leftMouseUp, end)
        await settle()
        let moved = canvas.piles.first!
        check(abs(moved.x - first.x - 85 / live.zoom) < 0.001, "Pile drag converts screen displacement into canvas displacement")
        check(canvas.nodes == originals && canvas.edges == originalEdges, "Pile movement does not rewrite hidden node identity or wires")
        check(canvas.undo() != nil && canvas.piles.first == first, "undo restores Pile position")
        check(canvas.redo() != nil && canvas.piles.first == moved, "redo restores Pile movement")
        canvas.selectedNodeIds = [first.id, c.id]
        let mixedHistory = canvas.history.count, mixedNode = canvas.node(id: c.id)!
        let mixedStart = live.pileScreenFrame(moved)
        let press = CGPoint(x: mixedStart.midX, y: mixedStart.midY)
        let release = CGPoint(x: press.x + 52, y: press.y + 26)
        _ = await mouse(.leftMouseDown, press); await settle()
        check(canvas.selectedNodeIds == [first.id, c.id], "pressing a selected Pile retains mixed selection")
        _ = await mouse(.leftMouseDragged, release); await settle()
        check(live.draggingIds == [first.id, c.id]
              && abs(live.screenFrame(of: mixedNode).minX - (mixedNode.x * live.zoom + live.effectivePan.width) - 52) < 0.01,
              "mixed drag previews ordinary node and Pile together")
        _ = await mouse(.leftMouseUp, release); await settle()
        let mixedDelta = canvas.piles.first!.x - moved.x
        check(abs(canvas.node(id: c.id)!.x - mixedNode.x - mixedDelta) < 0.001
              && canvas.history.count == mixedHistory + 1, "mixed movement preserves relative geometry in one transaction")
        check(canvas.undo() != nil && canvas.piles.first == moved && canvas.node(id: c.id) == mixedNode,
              "mixed drag undo restores every entity")
        let clicked = live.pileScreenFrame(moved)
        _ = await mouse(.leftMouseDown, CGPoint(x: clicked.midX, y: clicked.midY)); await settle()
        _ = await mouse(.leftMouseUp, CGPoint(x: clicked.midX, y: clicked.midY))
        await settle()
        check(live.pileGalleryID == first.id && live.inputRouter.blocksCanvasInput?() == true, "native click opens modal Pile gallery")
        if let source = CanvasPileGalleryProbeBridge.sources[first.id]?[b.id],
           let grid = CanvasPileGalleryProbeBridge.grids[first.id]?[b.id] {
            let size = CanvasPileGeometry.displaySize(canvas.node(id: b.id) ?? b)
            check(source.frame.size == CGSize(width: size.width * live.zoom, height: size.height * live.zoom)
                  && source.rotation == 0 && source.shade == 0,
                  "Gallery source snapshot preserves actual top-member size, rotation and shade")
            check(grid.frame.size == CGSize(width: size.width * CanvasPileGeometry.galleryInitialZoom,
                                             height: size.height * CanvasPileGeometry.galleryInitialZoom)
                  && grid.rotation == 0 && grid.shade == 0,
                  "Gallery destination centers the card independently of name and action bands")
        } else { check(false, "Gallery publishes native source and grid geometry") }
        capture("pile-gallery")
        let galleryNodes = canvas.nodes, galleryEdges = canvas.edges, galleryHistory = canvas.history.count
        galleryReducedMotion = CanvasPileGalleryProbeBridge.reducedMotion[first.id] ?? false
        let closePressed = await CanvasPileNativeButtonProbe.press("gallery-close", directory: directory)
        check(closePressed, "Gallery reverse transition uses actual native close button")
        if closePressed {
            try? await Task.sleep(for: .milliseconds(100))
            check(galleryReducedMotion ? live.pileGalleryID == nil
                  : live.pileGalleryID == first.id && live.inputRouter.blocksCanvasInput?() == true
                    && CanvasPileGalleryProbeBridge.sessions[first.id]?.phase == .closing,
                  "Gallery close honors motion lifetime and reduced-motion dismissal")
            capture("pile-gallery-closing")
            await settle()
            check(live.pileGalleryID == nil && canvas.nodes == galleryNodes && canvas.edges == galleryEdges
                  && canvas.history.count == galleryHistory, "Animated Gallery close preserves all data and history")
            live.pileGalleryID = first.id
            await settle()
        }
        let previewPressed = await CanvasPileNativeButtonProbe.press("pile-preview-\(b.id)", directory: directory)
        check(previewPressed, "Gallery preview invokes the actual native button")
        if previewPressed {
            await settle()
            check(canvas.selectedPile?.id == first.id && live.handleKeyAction(.cancel)
                  && live.pileGalleryID == first.id, "closing media preview retains Gallery and Pile selection")
        } else {
            check(false, "closing media preview retains Gallery and Pile selection")
        }
        check(live.handleKeyAction(.cancel)
              && (galleryReducedMotion ? live.pileGalleryID == nil : live.pileGalleryID == first.id),
              "Escape honors animated reverse close or immediate reduced-motion close (workspace integration)")
        await settle()
        check(live.pileGalleryID == nil && canvas.nodes == galleryNodes && canvas.history.count == galleryHistory,
              "Escape completes reverse Gallery close without mutating the canvas")
        galleryMotion = await live.runPileGalleryMotionProbe(directory: directory, pileID: first.id,
            memberID: a.id, mouse: { await mouse($0, $1, gallery: true) }, check: check)
        }
        check(canvas.createPile([a.id, c.id]) == nil, "hidden members cannot be individually restacked")
        guard let second = canvas.createPile([d.id, e.id]) else { check(false, "Second Pile creates"); return }
        canvas.movePileMemberToTop(second.id, memberID: d.id)
        check(canvas.piles.first(where: { $0.id == second.id })?.memberIDs == [e.id, d.id], "move-to-top retains exact bottom-to-top order")
        check(canvas.addToPile(first.id, entityIDs: [second.id]), "Pile merge succeeds")
        let merged = canvas.piles.first!
        check(merged.memberIDs == [a.id, b.id, e.id, d.id] && canvas.piles.count == 1, "merge appends source Pile in its current order")
        check(canvas.undo() != nil && canvas.piles.count == 2, "undo merge restores both independent Piles")
        check(canvas.redo() != nil && canvas.piles == [merged], "redo merge restores exact membership")
        canvas.removeNodes(ids: [b.id])
        check(canvas.piles.first?.memberIDs == [a.id, e.id, d.id], "member deletion prunes the Pile")
        check(canvas.undo() != nil && canvas.piles == [merged] && canvas.edges == originalEdges, "delete undo restores membership and wire roles")
        let position = CGPoint(x: 3300, y: 900)
        canvas.extractPileMember(first.id, memberID: a.id, at: position)
        check(canvas.node(id: a.id)?.frame.origin == position && canvas.piles.first?.memberIDs == [b.id, e.id, d.id],
              "extract keeps node identity and honors requested world position")
        check(canvas.undo() != nil && canvas.piles == [merged], "extract undo restores original Pile")
        let project = canvas.activeProjectId
        check(canvas.flushSave(), "Pile document flush succeeds")
        _ = canvas.createProject(name: "Pile reload isolation")
        _ = canvas.switchProject(to: project)
        check(canvas.piles == [merged] && canvas.edges == originalEdges, "project switching restores Pile and full graph")
        guard let group = canvas.groupNodes([merged.id, f.id]) else { check(false, "Parent Group creates"); return }
        check(canvas.piles.first?.groupID == group.id, "ordinary Group retains the independent child Pile")
        let groupGeometry = canvas.layoutNodes(Set(group.nodeIDs))
        check(groupGeometry.count == 2 && group.containerFrame == CanvasGroupGeometry.enclosing(groupGeometry),
              "Group boundary encloses the visible Pile and ordinary node")
        let hiddenBefore = canvas.nodes.filter { merged.memberIDs.contains($0.id) }
        let parentedPile = canvas.piles.first!
        canvas.arrangeGroup(group.id, layout: .grid)
        check(canvas.nodes.filter { merged.memberIDs.contains($0.id) } == hiddenBefore
              && canvas.layoutNodes(Set(group.nodeIDs)).count == 2,
              "Group grid arranges presentation entities without rewriting hidden originals")
        check(canvas.undo() != nil && canvas.piles == [parentedPile], "Group layout undo restores child Pile geometry")
        canvas.selectedGroupID = nil; canvas.selectedNodeIds = [merged.id, f.id]
        canvas.autoArrange([merged.id, f.id])
        check(canvas.nodes.filter { merged.memberIDs.contains($0.id) } == hiddenBefore,
              "mixed automatic layout preserves hidden node fields")
        _ = canvas.undo()
        let oldPile = canvas.piles.first!
        canvas.moveGroup(group.id, by: CGSize(width: 80, height: 40))
        check(canvas.piles.first?.x == oldPile.x + 80 && canvas.piles.first?.y == oldPile.y + 40,
              "Group movement moves child Pile once")
        _ = canvas.undo()
        canvas.ungroupNodes(Set(group.nodeIDs))
        check(canvas.groups.isEmpty && canvas.piles.count == 1 && canvas.piles.first?.groupID == nil,
              "ungroup retains Pile and only removes its parent")
        for skin in ["minimal", "colorful"] {
            for appearance in ["light", "dark"] {
                AppSkinCenter.apply(AppSkin(rawValue: skin)!)
                NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                canvas.selectedNodeIds = [merged.id]
                _ = live.handleKeyAction(.fitSelection); await settle()
                check(live.pileScreenFrame(canvas.piles.first!).intersects(live.canvasContentViewport),
                      "\(skin)/\(appearance) Pile remains visible after Fit")
                capture("pile-\(skin)-\(appearance)")
                live.pileGalleryID = merged.id; await settle()
                capture("gallery-\(skin)-\(appearance)")
                live.pileGalleryID = nil; await settle()
            }
        }
        let beforeUnstack = canvas.piles.first!
        let expectedOrigins = CanvasPileGeometry.unstackOrigins(beforeUnstack, nodes: canvas.nodes)
        live.unstackPile(beforeUnstack)
        await settle()
        check(canvas.piles.isEmpty && expectedOrigins.allSatisfy { canvas.node(id: $0.key)?.frame.origin == $0.value },
              "unstack applies recovered size-aware layout")
        check(canvas.edges == originalEdges && live.renderedCanvasEdges.count == 2, "unstack reveals every original edge")
        check(store.canvasSlotText(groupId: a.groupId, slot: a.slot) == "完整正文🙂\nPile identity sentinel",
              "Pile operations preserve exact slot text")
        capture("pile-unstack")
        check(canvas.undo() != nil && canvas.piles == [beforeUnstack], "unstack undo restores independent Pile")
        check(canvas.redo() != nil && canvas.piles.isEmpty, "unstack redo restores layout")
        guard let pair = canvas.createPile([d.id, e.id]) else { check(false, "Dissolution fixture creates"); return }
        let pairFrame = CanvasPileGeometry.frame(pair, nodes: canvas.nodes)
        canvas.extractPileMember(pair.id, memberID: d.id, at: CGPoint(x: 3600, y: 1000))
        check(canvas.piles.isEmpty && canvas.node(id: e.id)?.frame.midX == pairFrame.midX
              && canvas.node(id: e.id)?.frame.midY == pairFrame.midY, "two-member extraction dissolves and centers the remaining node")
        check(canvas.undo() != nil && canvas.piles == [pair], "dissolve undo restores the pair")
        canvas.selectedNodeIds = [pair.id]
        check(canvas.removeSelected() == 2 && canvas.piles.isEmpty, "Delete on Pile removes all members in one operation")
        check(canvas.undo() != nil && canvas.piles == [pair], "Pile Delete undo restores members and entity together")
        let motion = CanvasPortMotion(ticksAutomatically: false)
        motion.setVisible(true, now: 10)
        check(motion.opacity(at: 10) == 0 && motion.presentationOffset(output: true, at: 10).x == -24,
              "port reveal begins invisible with recovered inward offset")
        check(motion.opacity(at: 10.3) == 1 && motion.presentationOffset(output: false, at: 10.3) == .zero,
              "port reveal finishes independently after 300ms")
        motion.update(cursor: CGPoint(x: 520, y: 410), home: CGPoint(x: 500, y: 400), output: true, zoom: 1, now: 11)
        check(motion.opacity(at: 11) == 1 && motion.offset(at: 11) == .zero, "magnet entry does not restart completed reveal")
        motion.setVisible(false, now: 12)
        check(motion.opacity(at: 12.3) == 0, "hidden port finishes fading and cannot remain visible")
        complete = true
    }
}
#endif
