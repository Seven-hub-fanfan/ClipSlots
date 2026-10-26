#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor enum CanvasAgentGroupsProbeBridge {
    static var current: CanvasWorkspaceView?
}

private actor DraftGroupFixture: AgentBackend {
    var calls: [(AgentConfig, [AgentMessage], Bool)] = []
    var delay = 0.15
    var outcome = "success"
    func configure(_ outcome: String = "success", delay: Double = 0.15) {
        self.outcome = outcome; self.delay = delay
    }
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        calls.append((config, history, tools == nil))
        let result = outcome
        // Intentionally ignore cancellation to test the caller's late-result gate.
        try? await Task.sleep(for: .seconds(delay))
        switch result {
        case "failure": throw AgentError.network("本地夹具：网络中断")
        case "empty": return [.init(role: .assistant, content: "  ")]
        case "tool": return [.init(role: .tool, content: "unexpected")]
        default: return [.init(role: .assistant, content: "润色后的完整草稿🙂\n保留代码 `--ratio 16:9` 与原有约束。")]
        }
    }
}

extension CanvasWorkspaceView {
    @MainActor func runAgentGroupsProbe(directory: URL) async {
        var live: CanvasWorkspaceView { CanvasAgentGroupsProbeBridge.current ?? self }
        var passed = 0, failures: [String] = []
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failures.append(name) }
            NSLog("[AgentGroups] %@ %@", value ? "PASS" : "FAIL", name)
        }
        func settle(_ seconds: Double = 0.2) async { try? await Task.sleep(for: .seconds(seconds)) }
        func wait(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<400 {
                if condition() { return true }
                await settle(0.025)
            }
            return condition()
        }
        func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
            NativeAccessibilityProbe.elements(node)
        }
        func find(_ root: NSView, _ id: String) -> AnyObject? {
            elements(root).first { ($0.accessibilityIdentifier?() ?? "") == id }
        }
        func press(_ root: NSView, _ id: String) -> Bool {
            find(root, id)?.accessibilityPerformPress?() == true
        }
        func pressPolish(_ root: NSView) async -> Bool {
            press(root, "agent-ai-polish")
        }
        func editors(_ root: NSView) -> [AgentDraftEditor.Editor] {
            (root as? AgentDraftEditor.Editor).map { [$0] } ?? root.subviews.flatMap(editors)
        }
        func capture(_ root: NSView, _ name: String) {
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
        func submissions() -> [[String]] {
            ((try? String(contentsOf: directory.appendingPathComponent("commands.jsonl"))) ?? "")
                .split(separator: "\n").compactMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
                .filter { $0.first == "generate" }
        }
        guard let anchor = inputRouter.anchorView, let window = anchor.window, let root = window.contentView else { return }
        NativeAccessibilityProbe.enable()
        _ = await AgentProcessRunner.run(executable: "/usr/bin/swift", arguments: ["-e", """
            import ApplicationServices
            let app = AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!)
            print(AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue)
            var windows: CFTypeRef?
            print(AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows).rawValue)
            """, String(ProcessInfo.processInfo.processIdentifier)], timeout: 15)
        await settle()
        do {
            // Exercise the same mounted composer in all three workspace modes.
            UserDefaults.standard.set("deepseek", forKey: TikaBackendPreferences.backendKindKey)
            UserDefaults.standard.set("deepseek", forKey: AgentPreferences.workspaceBackendKey)
            UserDefaults.standard.set("fixture-selected-model", forKey: AgentPreferences.modelKey)
            let backend = DraftGroupFixture()
            let model = AgentChatModel(displayName: "测试会话", backend: backend)
            let hostWindow = NSWindow(contentRect: NSRect(x: 160, y: 100, width: 420, height: 780),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            hostWindow.isReleasedWhenClosed = false
            for mode in WorkspaceMode.allCases {
                let host = NSHostingView(rootView: AgentSidebarView(model: model, isVisible: .constant(true), workspaceMode: mode))
                hostWindow.contentView = host
                hostWindow.setContentSize(CGSize(width: mode == .agent ? 900 : 420, height: 780))
                hostWindow.makeKeyAndOrderFront(nil)
                model.draft = "请整理这段创作说明🙂\n保留 `--ratio 16:9`"
                await settle(0.4)
                let before = await backend.calls.count
                check(find(host, "agent-ai-polish") != nil && find(host, "agent-model-picker") != nil,
                      "\(mode.rawValue) exposes separate polish and model controls")
                check(await backend.calls.count == before, "\(mode.rawValue) mounting and typing do not invoke model")
                await backend.configure(delay: 0.55)
                check(await pressPolish(host), "\(mode.rawValue) native sparkle button activates polish")
                model.polishDraft(config: AgentConfig(model: "fixture-selected-model"))
                await settle(0.1)
                let loadingCalls = await backend.calls.count
                check(model.isPolishing && loadingCalls == before + 1, "\(mode.rawValue) loading prevents duplicate requests")
                capture(host, "agent-\(mode.rawValue)-loading")
                check(await wait { !model.isPolishing }, "\(mode.rawValue) finishes")
                await settle()
                check(model.draft.hasPrefix("润色后的") && model.messages.isEmpty, "\(mode.rawValue) updates only draft")
                check(await backend.calls.last?.0.model == "fixture-selected-model", "\(mode.rawValue) uses selected model")
                if let editor = editors(host).first {
                    hostWindow.makeFirstResponder(editor)
                    editor.undoManager?.undo()
                    check(model.draft.hasPrefix("请整理"), "\(mode.rawValue) undo restores pre-polish input")
                    editor.undoManager?.redo()
                    check(model.draft.hasPrefix("润色后的"), "\(mode.rawValue) redo reapplies polished input")
                    model.clearHistory()
                    await settle()
                    check(editor.undoManager?.canUndo != true && editor.string.isEmpty, "\(mode.rawValue) conversation switch clears old undo")
                    editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                         replacementRange: NSRange(location: NSNotFound, length: 0))
                    check(editor.hasMarkedText() && !editor.isPlaceholderVisible, "\(mode.rawValue) IME preedit remains visible")
                    editor.insertText("你好", replacementRange: editor.markedRange())
                    check(model.draft == "你好", "\(mode.rawValue) IME commits to draft")
                } else { check(false, "\(mode.rawValue) native editor exists") }
                model.draft = "把海边日落的创意整理成三个分镜，保留自然光线和安静的构图。"
                for skin in ["minimal", "colorful"] {
                    for appearance in ["light", "dark"] {
                        AppSkinCenter.apply(AppSkin(rawValue: skin) ?? .minimal)
                        NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                        await settle()
                        capture(host, "agent-\(mode.rawValue)-\(skin)-\(appearance)")
                        let frame = find(host, "agent-model-picker")?.accessibilityFrame?() ?? .zero
                        check(frame.width >= 26 && hostWindow.frame.contains(frame), "\(mode.rawValue)/\(skin)/\(appearance) model button within window")
                    }
                }
            }
            hostWindow.close()
            let config = AgentConfig(model: "model-proof", thinkingMode: .serverDefault, reasoningEffort: "high")
            model.draftAttachments = [.init(path: "/fixture/readme.md", name: "readme.md")]
            model.draftSkillReferences = [.init(name: "fixture", path: "/fixture/SKILL.md", markdown: "untouched")]
            model.draftReferences = [.init(projectID: "p", nodeID: "n", nodeCreatedAt: Date(), groupID: "g",
                slot: 1, title: "参考", text: "引用原文", attachmentNames: [])]
            let attachments = model.draftAttachments, skills = model.draftSkillReferences, references = model.draftReferences
            for outcome in ["failure", "empty", "tool"] {
                model.draft = "原文🙂 \(outcome)"
                let before = model.draft
                await backend.configure(outcome)
                model.polishDraft(config: config)
                _ = await wait { !model.isPolishing }
                check(model.draft == before && model.polishError != nil, "\(outcome) retains draft and displays error")
                check(model.errorText == nil && model.messages.isEmpty, "\(outcome) does not create retry-send message")
            }
            for action in ["edit", "cancel", "clear", "backend"] {
                model.draft = "等待润色"
                await backend.configure(delay: 0.5)
                model.polishDraft(config: config)
                await settle(0.02)
                switch action {
                case "edit": model.draft = "用户继续编辑的最新内容"
                case "cancel": model.cancelPolish()
                case "clear": model.clearHistory()
                default: model.setBackend(DraftGroupFixture())
                }
                let expected = model.draft
                await settle(0.6)
                check(!model.isPolishing && model.draft == expected, "\(action) rejects late result")
                model.setBackend(backend)
            }
            // Check preservation before clearHistory intentionally resets draft inputs.
            model.draftAttachments = attachments; model.draftSkillReferences = skills; model.draftReferences = references
            model.draft = "保留所有引用"
            await backend.configure()
            model.polishDraft(config: config)
            _ = await wait { !model.isPolishing }
            check(model.draftAttachments == attachments && model.draftSkillReferences == skills && model.draftReferences == references,
                  "Polishing preserves attachments, skills and canvas references")
            let calls = await backend.calls
            check(calls.allSatisfy { $0.0.taskPolicy == .textPolish && $0.1.count == 1 && $0.1[0].role == .user && $0.2 },
                  "All calls use fresh draft-only history, strict policy and no tools")
            check(calls.last?.0.model == config.model && calls.last?.0.reasoningEffort == config.reasoningEffort,
                  "Model and reasoning parameters pass intact")

            window.makeKeyAndOrderFront(nil)
            window.setContentSize(CGSize(width: 1320, height: 900))
            canvas.isLibraryExpanded = false
            live.zoom = 0.75; live.pan = CGSize(width: 120, height: 190)
            canvas.updateViewport(pan: live.pan, zoom: live.zoom)
            await settle()
            guard let a = live.createNode(kind: .text, at: CGPoint(x: 80, y: 120), parentNodeId: nil, beginEditing: false, quiet: true),
                  let b = live.createNode(kind: .image, at: CGPoint(x: 600, y: 120), parentNodeId: a.id, beginEditing: false, quiet: true) else {
                throw CocoaError(.coderInvalidValue)
            }
            let doc = store.canvasTextDocument(groupID: a.groupId, slot: a.slot)
            doc.edit("夕阳落在海边，橘猫看向远处的帆船。"); _ = doc.flush()
            canvas.selectedNodeIds = [a.id, b.id]
            await settle()
            check(press(root, "canvas-action-编组"), "Native multi-select toolbar creates group")
            await settle()
            guard let group = canvas.groups.first else { throw CocoaError(.coderInvalidValue) }
            let initialEdges = canvas.edges
            check(Set(group.nodeIDs) == [a.id, b.id] && initialEdges.count == 1, "Grouping preserves nodes and connection")
            check(canvas.undo() != nil && canvas.groups.isEmpty, "Undo grouping")
            check(live.activeControlRegions["canvas-group-\(group.id)"] == nil, "Removed group immediately releases pointer region")
            check(canvas.redo() != nil && canvas.groups.first == group, "Redo grouping")
            canvas.clearSelection()
            check(live.activeControlRegions["selection-actions"] == nil, "Deselection immediately releases toolbar pointer region")
            canvas.selectedNodeIds = [a.id, b.id]
            canvas.removeNodes(ids: [b.id])
            check(canvas.groups.first?.nodeIDs == [a.id], "Delete prunes group membership")
            _ = canvas.undo()
            check(canvas.groups.first == group && canvas.edges == initialEdges, "Undo delete restores group and connection")
            let project = canvas.activeProjectId
            _ = canvas.createProject(name: "隔离分组持久化")
            _ = canvas.switchProject(to: project)
            await settle()
            check(canvas.groups.first == group && canvas.edges == initialEdges, "Project reload persists group and connection")
            canvas.selectGroup(group.id)
            for skin in ["minimal", "colorful"] {
                for appearance in ["light", "dark"] {
                    AppSkinCenter.apply(AppSkin(rawValue: skin) ?? .minimal)
                    NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                    await settle(0.3)
                    capture(root, "groups-\(skin)-\(appearance)")
                    let toolbar = live.controlRegions["group-toolbar-\(group.id)"] ?? .zero
                    let header = live.groupHeaderFrame(group) ?? .zero
                    NSLog("[AgentGroups] geometry %@ %@ viewport %@", NSStringFromRect(toolbar), NSStringFromRect(header), NSStringFromRect(live.canvasContentViewport))
                    check(toolbar.width > 0 && header.width > 0 && !toolbar.intersects(header), "\(skin)/\(appearance) toolbar clears group header")
                }
            }
            window.setContentSize(CGSize(width: 960, height: 720))
            await settle()
            _ = live.handleKeyAction(.fitSelection)
            await settle()
            capture(root, "groups-narrow")
            check(live.controlRegions["group-toolbar-\(group.id)"].map { live.canvasContentViewport.contains($0) } == true,
                  "Narrow toolbar fits visible canvas")

            let p = try store.specialStorage.createPage(name: "测试目标页面", defaultGroupName: "目标素材组")
            guard let target = p.defaultGroup else { throw CocoaError(.coderInvalidValue) }
            let oldPage = store.currentPageId, oldGroup = store.currentSpecialSlotId
            let index = store.specialStorage.loadIndex()
            store.pages = index.pages
            store.specialSlots = index.specialSlots.filter { !SpecialSlotStorage.isReservedGroupId($0.id) }
            _ = store.specialStorage.set(1, content: .init(text: "已占用，不能覆盖"), in: target.id)
            doc.edit("入库前未落盘🙂\n保留完整正文")
            live.archiveNodeToLibrary(a)
            await settle(0.4)
            guard let sheet = window.sheets.first?.contentView else { throw CocoaError(.coderInvalidValue) }
            check(find(sheet, "archive-group-\(target.id)") == nil && find(sheet, "archive-slot-2") == nil,
                  "Picker starts at page; lower levels await selection")
            check(press(sheet, "archive-page-\(p.page.id)"), "Click 1 selects target page")
            await settle()
            check(find(sheet, "archive-group-\(target.id)") != nil && find(sheet, "archive-slot-2") == nil,
                  "Page selection reveals only its groups")
            check(press(sheet, "archive-group-\(target.id)"), "Click 2 selects target group")
            await settle()
            capture(sheet, "archive-page-group-slot")
            _ = press(sheet, "archive-slot-1")
            await settle()
            check(canvas.node(id: a.id) != nil && store.specialStorage.get(1, in: target.id).plainText == "已占用，不能覆盖",
                  "Occupied target cannot be overwritten")
            check(press(sheet, "archive-slot-2"), "Click 3 archives without another confirmation")
            await settle(0.4)
            let reboundID = CanvasNode.makeId(groupId: target.id, slot: 2)
            guard let rebound = canvas.node(id: reboundID) else { throw CocoaError(.coderInvalidValue) }
            check(liveText(for: rebound) == "入库前未落盘🙂\n保留完整正文", "Archive flushes complete pending text")
            check(canvas.groups.first?.nodeIDs.contains(reboundID) == true && canvas.edges.first?.fromNodeId == reboundID,
                  "Archive remaps group and edge with node")
            check(store.currentPageId == oldPage && store.currentSpecialSlotId == oldGroup,
                  "Cross-page archive leaves active library page and group unchanged")
            let newDoc = store.canvasTextDocument(groupID: target.id, slot: 2)
            newDoc.edit("归档后编辑"); _ = newDoc.flush()
            _ = canvas.undo()
            check(liveText(for: rebound) == "入库前未落盘🙂\n保留完整正文", "Undo post-archive edit")
            _ = canvas.undo()
            check(canvas.node(id: a.id) != nil && liveText(for: a).contains("未落盘")
                  && store.specialStorage.get(2, in: target.id).isEmpty && canvas.groups.first == group,
                  "Archive undo restores content and identity after edit/undo")
            _ = canvas.redo()
            check(canvas.node(id: reboundID) != nil && liveText(for: rebound).contains("未落盘"), "Archive redo moves content again")
            _ = store.specialStorage.set(2, content: .init(text: "外部写入，必须保留"), in: target.id)
            check(canvas.undo() == nil && canvas.node(id: reboundID) != nil
                  && store.specialStorage.get(2, in: target.id).plainText == "外部写入，必须保留",
                  "Concurrent edit rejects archive undo without moving history or overwriting")
            canvas.select(id: b.id, additive: false)
            // Generated-image archive was intentionally removed in 2.17.21.
            // This legacy archive scenario exercises an imported source instead.
            canvas.updateNode(id: b.id) { $0.mediaRole = .source }
            let archiveSource = canvas.node(id: b.id)!
            let beforeDrag = canvas.node(id: b.id)?.frame
            live.updateNodeDrag(archiveSource, translation: CGSize(width: -180, height: 30), point: CGPoint(x: 80, y: 180))
            live.endNodeDrag(archiveSource, translation: CGSize(width: -180, height: 30), point: CGPoint(x: 80, y: 180))
            await settle()
            check(live.archiveRequest?.nodes.map(\.id) == [b.id] && window.sheets.count == 1,
                  "Dragging unfiled node into library opens the same target picker")
            check(canvas.node(id: b.id)?.frame == beforeDrag, "Archive drag does not move the node behind library")
            live.archiveRequest = nil
            _ = await wait { window.sheets.isEmpty }
            await settle(0.4)

            // Whole group drop preserves existing configuration; new slots use normal slot nodes.
            newDoc.refreshFromStorage(store.specialStorage.get(2, in: target.id))
            check(store.flushCanvasTextDocuments(), "Prior archive conflict leaves documents ready for independent drag test")
            let library = try store.specialStorage.createSpecialSlot(name: "整组拖入测试", pageId: p.page.id)
            store.specialSlots.append(library)
            for slot in [1, 3] { _ = store.specialStorage.set(slot, content: .init(text: "海边分镜 \(slot)"), in: library.id) }
            var imageOnly = SlotContent()
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a9sAAAAASUVORK5CYII=")!
            imageOnly.items = [[PasteboardItem(type: "public.png", data: png)]]
            _ = store.specialStorage.set(5, content: imageOnly, in: library.id)
            try png.write(to: directory.appendingPathComponent("fixture.png"))
            let original = canvas.placeSlot(pageId: p.page.id, groupId: library.id, slot: 1, name: "保留配置", at: .zero).node
            canvas.updateNode(id: original.id) { $0.ratio = "16:9"; $0.seed = 2048; $0.count = 1 }
            check(canvas.node(id: original.id)?.ratio == "16:9" && canvas.node(id: original.id)?.seed == 2048,
                  "Existing canvas slot has custom parameters before drag")
            let slotEdge = SlotConnectionEdge(fromSlot: 1, fromPort: .bottom, toSlot: 3, toPort: .top, colorId: 3)
            SlotConnectionStorage.shared.save(.init(edges: [slotEdge]), pageId: p.page.id, groupId: library.id)
            let payload = CanvasSlotDragPayload(pageId: p.page.id, groupId: library.id, slot: 1, name: library.name, slots: [1, 2, 3, 5])
            canvas.isLibraryExpanded = true
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(nil)
            await settle(0.5)
            capture(root, "slot-group-before-drag")
            for _ in 0..<20 {
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                window.makeKeyAndOrderFront(nil)
                await settle(0.05)
                if window.isKeyWindow && NSApp.isActive { break }
            }
            window.makeKey()
            if let frame = find(root, "slot-group-drag-\(library.id)")?.accessibilityFrame?(),
               let activeAnchor = live.inputRouter.anchorView {
                let start = window.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
                let end = activeAnchor.convert(CGPoint(x: live.canvasContentViewport.midX, y: live.canvasContentViewport.midY), to: nil)
                check(frame.width > 0 && window.sheets.isEmpty && window.isKeyWindow, "Library drag handle is laid out in key window after picker dismissal")
                NSLog("[AgentGroups] existing before drag %@ / %@", canvas.node(id: original.id)?.ratio ?? "missing", String(describing: canvas.node(id: original.id)?.seed))
                NSLog("[AgentGroups] native drag %@ to %@ handle %@ key=%d", NSStringFromPoint(start), NSStringFromPoint(end), NSStringFromRect(frame), window.isKeyWindow)
                for step in 0...12 {
                    let t = CGFloat(step) / 12
                    let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                    let type: NSEvent.EventType = step == 0 ? .leftMouseDown : step == 12 ? .leftMouseUp : .leftMouseDragged
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: step + 1, clickCount: 1, pressure: 1) { NSApp.sendEvent(event) }
                    await settle(0.025)
                }
            } else { check(false, "Library group drag handle exists") }
            await settle()
            check(canvas.groups.contains(where: { $0.name == library.name }), "Native library group drag creates canvas group")
            guard let dragged = canvas.groups.first(where: { $0.name == library.name }) else { throw CocoaError(.coderInvalidValue) }
            check(dragged.nodeIDs.count == 3 && canvas.node(forGroupId: library.id, slot: 2) == nil,
                  "Group drop includes image-only and text slots, excludes empty slots")
            check(canvas.node(id: original.id)?.ratio == "16:9" && canvas.node(id: original.id)?.seed == 2048,
                  "Group drop preserves existing node parameters")
            check(canvas.edges.contains { $0.id == "slot-\(library.id)-\(slotEdge.id)" && $0.sourceFromPort == "bottom"
                  && $0.sourceToPort == "top" && $0.sourceColorID == 3 }, "Group drop retains exact connection identity, ports and color")
            live.handleSlotDrop(payload, screenPoint: CGPoint(x: live.canvasContentViewport.midX, y: live.canvasContentViewport.midY))
            check(canvas.groups.filter { $0.id == dragged.id }.count == 1 && canvas.nodes.filter { $0.groupId == library.id }.count == 3,
                  "Repeated group drop deduplicates nodes and group")
            // Binary-only slot remains a reference source for this run.
            let sourceID = CanvasNode.makeId(groupId: library.id, slot: 5)
            canvas.updateNode(id: sourceID) { $0.kind = .image; $0.mediaRole = .source }
            let sharedBirth = canvas.node(forGroupId: library.id, slot: 3)!.createdAt
            canvas.updateNode(id: original.id) { $0.createdAt = sharedBirth }
            CrateModelCatalogStore.shared.loadIfNeeded()
            _ = await wait { !CrateModelCatalogStore.shared.imageModels.isEmpty }
            canvas.selectGroup(dragged.id)
            _ = live.handleKeyAction(.fitSelection)
            await settle()
            let before = submissions().count
            // Selected-only capsule replaces the old always-mounted header.
            check(press(root, "canvas-group-运行全部"), "Native group toolbar opens run confirmation")
            await settle()
            check(canvas.selectionGenerationTask == nil && live.groupRunAlert != nil,
                  "Group run waits for confirmation before submission")
            live.groupRunAlert?.buttons.first?.performClick(nil)
            await settle(0.05)
            check(canvas.runningGroupID == dragged.id, "Native group Generate starts selected group")
            check(await wait { canvas.selectionGenerationTask == nil }, "Group generation completes")
            let submitted = Array(submissions().dropFirst(before))
            check(submitted.count == 2, "Group runs only its two generation nodes")
            check(submitted.count == 2 && submitted[1].contains("--image"), "Second grouped slot receives upstream generated image")
            check([1, 3].allSatisfy {
                if case .succeeded = canvas.node(forGroupId: library.id, slot: $0)?.state { return true }; return false
            }, "Grouped outputs are durably written to both slots")
            live.runGeneration(nodeIDs: Set(dragged.nodeIDs), groupID: dragged.id)
            canvas.stopSelectionGeneration()
            await settle()
            check(canvas.selectionGenerationTask == nil && canvas.runningGroupID == nil, "Stop clears group run and blocks next node")
            capture(root, "slot-group-generated")
        } catch { check(false, "Probe completes: \(error.localizedDescription)") }
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let report: [String: Any] = ["passed": passed, "failures": failures, "sessionLocked": locked,
            "systemInputValidated": false, "inputMethod": "Native AppKit/AX within isolated process",
            "crateSubmissions": submissions().count]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}
#endif
