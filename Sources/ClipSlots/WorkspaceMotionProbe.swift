#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
enum WorkspaceMotionProbe {
    private static var started = false
    static func schedule(store: SlotStoreObservable, canvas: CanvasStore,
                         transition: WorkspaceTransition, mode: @escaping () -> WorkspaceMode,
                         request: @escaping (WorkspaceMode) -> Void) {
        guard !started, let path = ProcessInfo.processInfo.environment["CLIPSLOTS_WORKSPACE_MOTION_PROBE"],
              ProcessInfo.processInfo.environment["CLIPSLOTS_DATA_DIR"]?.hasPrefix("/tmp/") == true else { return }
        started = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            await run(directory: URL(fileURLWithPath: path), store: store, canvas: canvas,
                      transition: transition, mode: mode, request: request)
        }
    }
    private static func run(directory: URL, store: SlotStoreObservable, canvas: CanvasStore,
                            transition: WorkspaceTransition, mode: @escaping () -> WorkspaceMode,
                            request: @escaping (WorkspaceMode) -> Void) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var passed = 0, failures = [String](), observations = [[String: Any]]()
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 } else { failures.append(message) }
            NSLog("[WorkspaceMotion] %@ %@", condition ? "PASS" : "FAIL", message)
        }
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func wait(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<400 {
                if condition() { return true }
                await pause(0.025)
            }
            return condition()
        }
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }),
              let root = window.contentView else { return }
        window.setContentSize(CGSize(width: 1280, height: 720))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        UserDefaults.standard.set(true, forKey: AgentPreferences.editSidebarVisibleKey)
        UserDefaults.standard.set(true, forKey: AgentPreferences.canvasSidebarVisibleKey)
        if let appearance = ProcessInfo.processInfo.environment["CLIPSLOTS_PROBE_APPEARANCE"],
           let mode = ThemeMode(rawValue: appearance) {
            AppearanceDefaults.currentRawValue = mode.rawValue
        }
        await pause(0.2)
        func capture(_ name: String) {
            guard ProcessInfo.processInfo.environment["CLIPSLOTS_PROBE_SKIP_STATIC_CAPTURES"] != "1" else { return }
            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
        func views<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, type) }
        }
        func viewTree(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(viewTree)
        }
        await runCanvasDisplayClockRegression(check: check)
        do {
            // Ten real persisted text slots, followed by the actual group drop path.
            let group = try store.specialStorage.createSpecialSlot(name: "窗口与切页夹具")
            for slot in 1...10 {
                let content = SlotContent(items: [[.init(type: "public.utf8-plain-text",
                    data: Data("真实落盘节点 \(slot)\n用于验证批量挂载与切页内容一致性".utf8))]])
                check(store.specialStorage.set(slot, content: content, in: group.id), "fixture slot \(slot) persisted")
            }
            store.loadSpecialSlots()
            store.switchSpecialSlot(id: group.id)
            check(await wait {
                store.currentSpecialSlotId == group.id && !store.isSwitchingGroup
                    && (1...10).allSatisfy { store.slots[$0]?.isEmpty == false }
            }, "editor fixture displays all ten persisted text contents")
            await pause(0.3)
            let frames = MenuFrameCapture()
            var captureStarted = false
            var captureError: String?
            if ProcessInfo.processInfo.environment["CLIPSLOTS_PROBE_CAPTURE"] == "1" {
                do { try await frames.start(windowID: CGWindowID(window.windowNumber)); captureStarted = true }
                catch { captureError = String(describing: error) }
            }
            for cycle in 0..<4 {
                for target: WorkspaceMode in [.canvas, .edit] {
                    let begin = ProcessInfo.processInfo.systemUptime
                    var gaps = [Double](), last = begin
                    var stalls = [[String: Any]]()
                    let timer = Timer(timeInterval: 0.001, repeats: true) { _ in
                        let now = ProcessInfo.processInfo.systemUptime
                        let gap = (now - last) * 1000
                        gaps.append(gap)
                        if gap > 8.333 {
                            stalls.append(["uptime": now, "gap_ms": gap, "phase": WorkspaceMountTrace.phase])
                        }
                        last = now
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    if captureStarted { frames.begin() }
                    request(target)
                    let completed = await wait { mode() == target && !transition.isSwitching }
                    let latency = (ProcessInfo.processInfo.systemUptime - begin) * 1000
                    await pause(0.24)
                    timer.invalidate()
                    check(completed, "\(cycle) \(target.rawValue) transition finishes")
                    check(!views(root, AgentDraftEditor.Editor.self).isEmpty,
                          "\(cycle) \(target.rawValue) sidebar editor is actually mounted")
                    if target == .edit {
                        check(CanvasCommandBridge.shared.slotCommandHandler == nil, "hidden canvas releases slot commands")
                        let scrollers = views(root, NSScrollView.self)
                        check(scrollers.contains { $0.scrollerStyle == .overlay }, "editor uses local overlay scroller")
                    } else {
                        check(CanvasCommandBridge.shared.slotCommandHandler != nil, "visible canvas owns slot commands")
                    }
                    let sorted = gaps.sorted()
                    let nativeViews = viewTree(root)
                    if cycle == 0 {
                        var descriptions = [String]()
                        func describe(_ view: NSView, depth: Int) {
                            descriptions.append(String(repeating: " ", count: depth * 2)
                                + "\(type(of: view)) frame=\(view.frame) layer=\(view.wantsLayer)"
                                + " tracks=\(view.trackingAreas.count)")
                            view.subviews.forEach { describe($0, depth: depth + 1) }
                        }
                        describe(root, depth: 0)
                        try? descriptions.joined(separator: "\n").write(
                            to: directory.appendingPathComponent("native-tree-\(target.rawValue).txt"),
                            atomically: true, encoding: .utf8)
                    }
                    observations.append(["cycle": cycle, "target": target.rawValue, "ready_ms": latency,
                        "native_view_count": nativeViews.count,
                        "native_control_count": nativeViews.filter { $0 is NSControl }.count,
                        "native_tracking_area_count": nativeViews.reduce(0) { $0 + $1.trackingAreas.count },
                        "main_max_gap_ms": sorted.last ?? 0,
                        "main_p95_gap_ms": sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)],
                        "main_over_8_33": gaps.filter { $0 > 8.333 }.count,
                        "stalls": stalls,
                        "scope": "main-thread availability; not presented FPS"])
                    if captureStarted { _ = await frames.save(to: directory, name: "switch-\(cycle)-\(target.rawValue)", trigger: begin) }
                    if target == .canvas {
                        check(!views(root, AgentDraftEditor.Editor.self).isEmpty, "canvas input remains after loading")
                    }
                    if cycle == 0 && target == .canvas,
                       let live = CanvasAgentGroupsProbeBridge.current {
                        canvas.isLibraryExpanded = false
                        let payload = CanvasSlotDragPayload(pageId: group.pageId, groupId: group.id,
                            slot: 1, name: group.name, slots: Array(1...10))
                        let count = canvas.nodes.count
                        if captureStarted { frames.begin() }
                        let dropped = ProcessInfo.processInfo.systemUptime
                        var dropGaps = [Double](), lastDropTick = dropped
                        var dropStalls = [[String: Any]]()
                        let dropTimer = Timer(timeInterval: 0.001, repeats: true) { _ in
                            let now = ProcessInfo.processInfo.systemUptime
                            let gap = (now - lastDropTick) * 1000
                            dropGaps.append(gap)
                            if gap > 8.333 { dropStalls.append(["gap_ms": gap, "phase": WorkspaceMountTrace.phase]) }
                            lastDropTick = now
                        }
                        RunLoop.main.add(dropTimer, forMode: .common)
                        live.handleSlotDrop(payload, screenPoint: CGPoint(x: 600, y: 350))
                        check(await wait { canvas.nodes.count == count + 10 }, "real group drop places ten nodes")
                        let fullyMounted = await wait {
                            guard let current = CanvasAgentGroupsProbeBridge.current else { return false }
                            return !transition.preparation.textSurfaces.isMounting
                                && current.groupMounts.pendingIDs.isEmpty
                                && canvas.nodes.filter { $0.groupId == group.id }.allSatisfy {
                                    current.localControlRegistry.nativeNodes[$0.id] != nil
                                        || current.localControlRegistry.nodes[$0.id] != nil
                                }
                        }
                        check(fullyMounted, "all ten dropped node surfaces expose actual hit regions")
                        let dropReady = (ProcessInfo.processInfo.systemUptime - dropped) * 1000
                        await pause(0.3)
                        dropTimer.invalidate()
                        observations.append(["target": "batch-drop", "full_surface_ready_ms": dropReady,
                            "main_max_gap_ms": dropGaps.max() ?? 0,
                            "main_over_8_33": dropGaps.filter { $0 > 8.333 }.count,
                            "stalls": dropStalls,
                            "scope": "real persisted group drop, mounted surfaces and main availability"])
                        await pause(1)
                        if captureStarted { _ = await frames.save(to: directory, name: "batch-drop", trigger: dropped) }
                        check(transition.preparation.snapshots.entries.count == 10, "ten persisted contents reach render cache")
                        canvas.clearSelection()
                        await pause(0.3)
                    }
                    capture("settled-\(cycle)-\(target.rawValue)")
                }
            }
            let legacyEditModel = AgentSessionStore.shared.edit
            let savedLegacyDraft = legacyEditModel.draft
            let editModel = AgentSessionStore.shared.sidebarSession(canvas: canvas, store: store)
            let canvasModel = AgentSessionStore.shared.canvasSession(canvas: canvas, store: store)
            let savedDraft = editModel.draft
            check(editModel === canvasModel, "both pages use the same project writer during IME input")
            if let editor = views(root, AgentDraftEditor.Editor.self).first {
                window.makeFirstResponder(editor)
                editor.insertText("编辑区草稿 · ", replacementRange:
                    NSRange(location: 0, length: (editor.string as NSString).length))
                editor.setMarkedText("输入法候选", selectedRange: NSRange(location: 5, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                check(editor.hasMarkedText(), "native IME buffer contains uncommitted text")
                // Deliberately leave the binding behind the native marked buffer.
                editModel.draft = "编辑区草稿 · "
                let expectedDraft = editor.string
                request(.canvas)
                check(await wait { mode() == .canvas && !transition.isSwitching }, "IME page change finishes")
                check(editModel.draft == expectedDraft, "page change commits outgoing native IME buffer")
                check(views(root, AgentDraftEditor.Editor.self).first?.string == expectedDraft,
                      "destination displays the complete shared draft including IME text")
                check(views(root, AgentDraftEditor.Editor.self).first === editor,
                      "visible sidebar reuses its native editor across pages")
                request(.edit)
                _ = await wait { mode() == .edit && !transition.isSwitching }
                check(views(root, AgentDraftEditor.Editor.self).first?.string == expectedDraft,
                      "returning page restores the complete outgoing draft")
            } else { check(false, "native editor found for IME page change") }
            check(legacyEditModel.draft == savedLegacyDraft, "shared IME editing preserves legacy edit history")
            editModel.draft = savedDraft
            let completion = AgentComposerCompletion()
            let completionItems = [AgentComposerItem(id: "model", title: "模型", detail: "选择模型", action: .model)]
            var draft = "/", replacementID: UUID?
            var conversationID = UUID()
            func composer() -> AgentDraftEditor {
                AgentDraftEditor(text: Binding(get: { draft }, set: { draft = $0 }),
                    focusRequest: 0, conversationID: conversationID, replacementID: replacementID,
                    completion: completion, completionItems: completionItems, onSend: {})
            }
            let editorHost = NSHostingView(rootView: composer())
            let editorWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            editorWindow.isReleasedWhenClosed = false
            editorWindow.contentView = editorHost
            editorWindow.makeKeyAndOrderFront(nil)
            await pause(0.15)
            if let editor = views(editorHost, AgentDraftEditor.Editor.self).first {
                editor.setSelectedRange(NSRange(location: 1, length: 0))
                editor.scheduleCompletionUpdate()
                editor.scheduleCompletionUpdate()
                await pause(0.05)
                check(completion.rows == completionItems, "coalesced completion uses latest native selection")
                completion.dismiss()
                editorHost.rootView = composer()
                editor.scheduleCompletionUpdate()
                await pause(0.05)
                check(!completion.isOpen, "unchanged reconciliation keeps completion dismissed")
                editor.appearance = NSAppearance(named: .aqua)
                editor.synchronizeAppearance()
                var lightInk: NSColor?
                editor.effectiveAppearance.performAsCurrentDrawingAppearance {
                    lightInk = editor.textColor?.usingColorSpace(.deviceRGB)
                }
                editor.appearance = NSAppearance(named: .darkAqua)
                editor.synchronizeAppearance()
                var darkInk: NSColor?
                editor.effectiveAppearance.performAsCurrentDrawingAppearance {
                    darkInk = editor.textColor?.usingColorSpace(.deviceRGB)
                }
                check(lightInk != darkInk && (darkInk?.redComponent ?? 0) > 0.8,
                      "native editor refreshes ink when effective appearance changes")
                draft = "原始草稿"
                conversationID = UUID()
                editorHost.rootView = composer()
                await pause(0.05)
                draft = "润色后的草稿"; replacementID = UUID()
                editorHost.rootView = composer()
                await pause(0.05)
                check(editor.string == draft && editor.undoManager?.canUndo == true,
                      "native reconciliation preserves undoable prompt replacement")
                editor.undoManager?.undo()
                check(editor.string == "原始草稿" && draft == "原始草稿",
                      "undo restores both native buffer and bound draft")
                draft = "另一个会话"; conversationID = UUID()
                editorHost.rootView = composer()
                await pause(0.05)
                check(editor.string == draft && editor.undoManager?.canUndo == false,
                      "conversation replacement clears outgoing undo history")
                editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
                let markedBuffer = editor.string
                draft = "绑定中的旧草稿"
                editorHost.rootView = composer()
                await pause(0.05)
                check(editor.hasMarkedText() && editor.string == markedBuffer,
                      "redundant reconciliation leaves IME composition untouched")
                editor.commitDraftBuffer()
                check(draft == markedBuffer && !editor.hasMarkedText(),
                      "coalesced editor commits IME buffer through current binding")
            } else { check(false, "reconciliation fixture exposes native editor") }
            editorWindow.close()
            window.makeKeyAndOrderFront(nil)
            for width: CGFloat in [1166, 1280, 1440] {
                window.setContentSize(CGSize(width: width, height: 560))
                await pause(0.3)
                check(root.bounds.width >= 1166, "window refuses obsolete narrow budget \(width)")
                capture("window-\(Int(width))")
            }
            if let editor = views(root, NSScrollView.self).first(where: { $0.hasVerticalScroller }) {
                editor.contentView.scroll(to: CGPoint(x: 0, y: 120))
                editor.reflectScrolledClipView(editor.contentView)
                await pause(0.1)
                check(editor.verticalScroller?.alphaValue == 1, "scroll reveals track")
                await pause(1.3)
                check(editor.verticalScroller?.alphaValue == 0, "idle track fades away")
                let maximum = max(0, (editor.documentView?.bounds.height ?? 0) - editor.contentView.bounds.height)
                check(maximum > 100, "editor document retains offscreen slot rows")
                store.flashHighlightSlot = FlashHighlightTarget(groupId: store.currentSpecialSlotId, slot: 10)
                await pause(0.4)
                check(editor.contentView.bounds.origin.y > maximum / 2,
                      "footer highlight scrolls the final slot into view")
                store.flashHighlightSlot = nil
            } else { check(false, "editor scroll host found") }
            request(.canvas)
            _ = await wait { mode() == .canvas && !transition.isSwitching }
            check(transition.preparation.snapshots.entries.count == 10, "cached content survives repeat entry")
            request(.edit)
            _ = await wait { mode() == .edit }
            request(.canvas)
            check(await wait { mode() == .canvas && !transition.isSwitching },
                  "rapid reversal reaches the latest workspace")
            check(transition.sections.pendingIDs.isEmpty && transition.editorMounts.pendingIDs.isEmpty,
                  "cancelled transition leaves no stranded admissions")
            if ProcessInfo.processInfo.environment["CLIPSLOTS_PROBE_ACTIVE_INPUT"] == "1",
               let live = CanvasAgentGroupsProbeBridge.current {
                await pause(0.25)
                var gaps = [Double](), last = ProcessInfo.processInfo.systemUptime
                var updates = 0
                let begin = last
                let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
                    let now = ProcessInfo.processInfo.systemUptime
                    gaps.append((now - last) * 1000); last = now
                    let direction: CGFloat = updates < 240 ? 1 : -1
                    live.inputRouter.onScroll?(direction * 1.5, direction * 0.4, true, false,
                                               CGPoint(x: 600, y: 300))
                    updates += 1
                }
                RunLoop.main.add(timer, forMode: .common)
                await pause(4)
                timer.invalidate()
                check(updates > 100, "continuous canvas pan applies real input callbacks")
                observations.append(["target": "continuous-canvas-pan", "begin_uptime": begin,
                    "end_uptime": ProcessInfo.processInfo.systemUptime, "applied_input_updates": updates,
                    "main_max_gap_ms": gaps.max() ?? 0,
                    "scope": "continuous 120Hz requested scroll input; callback count is not presented FPS"])
                request(.edit)
                _ = await wait { mode() == .edit && !transition.isSwitching }
                if let scroll = views(root, NSScrollView.self).first(where: { $0.hasVerticalScroller }) {
                    var scrollUpdates = 0, scrollGaps = [Double]()
                    let scrollBegin = ProcessInfo.processInfo.systemUptime
                    var scrollLast = scrollBegin
                    let nativeInput = ProcessInfo.processInfo.environment["CLIPSLOTS_PROBE_NATIVE_SCROLL_INPUT"] == "1"
                    var minimumOrigin = scroll.contentView.bounds.origin.y
                    var maximumOrigin = minimumOrigin
                    var previousTarget = minimumOrigin
                    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
                        let now = ProcessInfo.processInfo.systemUptime
                        scrollGaps.append((now - scrollLast) * 1000); scrollLast = now
                        let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                        let elapsed = now - scrollBegin
                        let offset = maximum * CGFloat((1 - cos(elapsed * 2 * .pi)) / 2)
                        if nativeInput {
                            let delta = Int32((previousTarget - offset).rounded())
                            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                                   wheelCount: 2, wheel1: delta, wheel2: 0, wheel3: 0) {
                                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollUpdates == 0 ? 1 : 2)
                                if let event = NSEvent(cgEvent: event) {
                                    scroll.scrollWheel(with: event)
                                }
                            }
                            previousTarget = offset
                        } else {
                            scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                        minimumOrigin = min(minimumOrigin, scroll.contentView.bounds.origin.y)
                        maximumOrigin = max(maximumOrigin, scroll.contentView.bounds.origin.y)
                        scrollUpdates += 1
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    await pause(3)
                    timer.invalidate()
                    check(scrollUpdates > 100, "continuous editor scroll applies native clip offsets")
                    if nativeInput {
                        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                               wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) {
                            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
                            if let event = NSEvent(cgEvent: event) { scroll.scrollWheel(with: event) }
                        }
                        check(maximumOrigin - minimumOrigin > 100,
                              "native scroll-wheel fixture actually changes the clip origin")
                    }
                    observations.append(["target": "continuous-editor-scroll", "begin_uptime": scrollBegin,
                        "end_uptime": ProcessInfo.processInfo.systemUptime, "applied_input_updates": scrollUpdates,
                        "native_scroll_wheel_fixture": nativeInput,
                        "minimum_clip_origin": minimumOrigin, "maximum_clip_origin": maximumOrigin,
                        "main_max_gap_ms": scrollGaps.max() ?? 0,
                        "scope": nativeInput ? "in-process native scroll-wheel fixture; not physical trackpad evidence"
                            : "native continuous scrolling; callback count is not presented FPS"])
                } else { check(false, "active editor scroller found") }
            }
            if ProcessInfo.processInfo.environment["CLIPSLOTS_PROBE_GRID_ACTIONS"] == "1" {
                request(.edit)
                _ = await wait { mode() == .edit && !transition.isSwitching }
                NativeAccessibilityProbe.enable()
                let grid = views(root, NSScrollView.self).first(where: { $0.hasVerticalScroller })!
                if let scroll = views(root, NSScrollView.self).first(where: { $0.hasVerticalScroller }) {
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                    await pause(0.2)
                }
                func button(_ label: String, in view: NSView) -> AnyObject? {
                    let gridRect = window.convertToScreen(grid.convert(grid.bounds, to: nil))
                    return NativeAccessibilityProbe.elements(view === grid ? root : view).first {
                        guard $0.accessibilityRole?() == .button,
                              $0.accessibilityLabel?() == label else { return false }
                        guard view === grid else { return true }
                        guard let frame = $0.accessibilityFrame?() else { return false }
                        return gridRect.contains(CGPoint(x: frame.midX, y: frame.midY))
                    }
                }
                func press(_ element: AnyObject?) -> Bool {
                    element?.accessibilityPerformPress?() ?? false
                }
                func hit(_ element: AnyObject?) -> Bool {
                    guard let frame = element?.accessibilityFrame?(), !frame.isEmpty else { return false }
                    let point = root.convert(window.convertPoint(fromScreen:
                        CGPoint(x: frame.midX, y: frame.midY)), from: nil)
                    guard root.bounds.contains(point), let target = root.hitTest(point) else { return false }
                    return !(target is WorkspaceLoadingView) && !(target is ScrollTrackAutoFade.Anchor)
                }
                let original = store.slots[1]?.plainText
                let editButton = button("编辑", in: grid)
                check(hit(editButton), "scrolled grid edit button retains a visible native hit region")
                check(press(editButton), "grid edit button performs its native action")
                check(await wait { window.attachedSheet != nil }, "grid edit action opens text sheet")
                if let sheet = window.attachedSheet, let contentView = sheet.contentView,
                   let text = views(contentView, NSTextView.self).first {
                    let initialMatches = await wait { text.string == original }
                    let diagnostic: [String: Any] = [
                        "expected": original ?? NSNull(),
                        "actual": text.string,
                        "current_group": store.currentSpecialSlotId,
                        "expected_group": group.id,
                        "text_views": views(contentView, NSTextView.self).map {
                            ["type": String(describing: type(of: $0)), "text": $0.string,
                             "frame": NSStringFromRect($0.frame), "hidden": $0.isHidden] as [String: Any]
                        }
                    ]
                    try? JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("grid-editor-initial.json"))
                    if let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) {
                        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?
                            .write(to: directory.appendingPathComponent("grid-editor-initial.png"))
                    }
                    check(initialMatches,
                          "text sheet opens the current persisted slot")
                    text.insertText("取消后的临时内容", replacementRange:
                        NSRange(location: 0, length: (text.string as NSString).length))
                    check(press(button("取消", in: contentView)), "text sheet cancel performs its native action")
                    check(await wait { window.attachedSheet == nil }, "text sheet cancel dismisses cleanly")
                    check(store.slots[1]?.plainText == original, "cancel preserves persisted slot content")
                } else { check(false, "grid edit sheet exposes its native text editor") }
                check(press(button("编辑", in: grid)), "grid edit button reopens after cancellation")
                _ = await wait { window.attachedSheet != nil }
                if let sheet = window.attachedSheet, let contentView = sheet.contentView,
                   let text = views(contentView, NSTextView.self).first {
                    check(await wait { text.string == original },
                          "cancelled draft does not replace the reopened editor initial text")
                    let replacement = "原生交互保存 · \(original ?? "")"
                    text.insertText(replacement, replacementRange:
                        NSRange(location: 0, length: (text.string as NSString).length))
                    check(press(button("保存", in: contentView)), "text sheet save performs its native action")
                    check(await wait {
                        window.attachedSheet == nil && store.slots[1]?.plainText == replacement
                    }, "native save updates the current grid slot and dismisses")
                    check(store.specialStorage.get(1, in: group.id).plainText == replacement,
                          "native grid edit is persisted to the matching group")
                } else { check(false, "reopened edit sheet exposes its native text editor") }
                check(press(button("编辑", in: grid)), "saved slot can open a fresh editor")
                _ = await wait { window.attachedSheet != nil }
                if let sheet = window.attachedSheet, let contentView = sheet.contentView,
                   let text = views(contentView, NSTextView.self).first {
                    check(await wait { text.string == store.slots[1]?.plainText },
                          "saved content becomes the next editor initial text")
                    check(press(button("取消", in: contentView)),
                          "fresh editor cancels after saved-content verification")
                    check(await wait { window.attachedSheet == nil },
                          "saved-content verification leaves no attached sheet")
                } else { check(false, "saved slot editor exposes its current native text") }
                let attachment = button("附件", in: grid)
                check(hit(attachment), "grid attachment button retains a visible native hit region")
                check(press(attachment), "grid attachment button performs its native action")
                check(await wait { AttachmentManagerPanelController.shared.isVisible(forSlot: 1) },
                      "grid attachment manager opens for the matching slot")
                AttachmentManagerPanelController.shared.close()
                check(await wait { !AttachmentManagerPanelController.shared.isVisible },
                      "grid attachment manager dismisses without a stale panel")
                let nodes = NativeAccessibilityProbe.elements(root)
                let menu = nodes.first { $0.accessibilityLabel?() == "槽位 1 更多操作" }
                check(hit(menu), "grid more-actions menu retains a visible native hit region")
                let dump = nodes.map {
                    "\($0.accessibilityRole?()?.rawValue ?? "-") | \($0.accessibilityLabel?() ?? "-")"
                }
                try? dump.joined(separator: "\n").write(
                    to: directory.appendingPathComponent("grid-actions-accessibility.txt"),
                    atomically: true, encoding: .utf8)
            }
            if captureStarted { await frames.stop() }
            observations.append(["presented_capture_started": captureStarted,
                                 "presented_capture_error": captureError ?? NSNull()])
            request(.canvas)
            _ = await wait { mode() == .canvas && !transition.isSwitching }
            // Exercise the real minimap spring, including its retirement path.
            let map = CanvasMiniMapView(frame: CGRect(origin: .zero, size: CanvasReplicaGeometry.mapSize))
            map.nodes = canvas.nodes
            map.viewport = CGRect(x: 0, y: 0, width: 720, height: 400)
            map.zoom = 1
            map.synchronize(pan: CGSize(width: 700, height: 300))
            var mapUpdates = 0, mapEnds = 0
            map.onPan = { _ in mapUpdates += 1 }
            map.onEnd = { mapEnds += 1 }
            let mapWindow = NSWindow(contentRect: map.frame, styleMask: [.borderless],
                                     backing: .buffered, defer: false)
            mapWindow.contentView = map
            let rect = map.viewportRect
            let point = CGPoint(x: rect.midX < map.bounds.midX ? map.bounds.maxX - 2 : 2,
                                y: map.bounds.midY)
            if let event = NSEvent.mouseEvent(with: .leftMouseDown,
                location: map.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: mapWindow.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
                map.mouseDown(with: event)
                await pause(0.5)
                check(mapUpdates > 1 && mapEnds == 1, "minimap display spring advances and finishes once")
                map.cancelMotion()
                let before = mapUpdates
                await pause(0.1)
                check(mapUpdates == before, "minimap cancellation retires display subscription")
            } else { check(false, "minimap native input event created") }
            mapWindow.contentView = nil
            if ProcessInfo.processInfo.environment["CLIPSLOTS_PROBE_EDITOR_MOUNT_AUDIT"] == "1" {
                request(.edit)
                check(await wait { mode() == .edit && !transition.isSwitching },
                      "native mount audit reaches the settled editor")
                await pause(0.3)
                let audit = await EditorNativeMountAudit.run(root: root, window: window, directory: directory)
                check(audit["complete"] as? Bool == true, "native mount audit completes six settled checkpoints")
                check(audit["checkpoint_offsets_verified"] as? Bool == true,
                      "native mount audit reaches each requested clip offset")
                check(audit["native_editor_identity_preserved"] as? Bool == true,
                      "native mount audit preserves sidebar input identity across all offsets")
                observations.append(audit)
            }
        } catch { check(false, "fixture \(error)") }
        let report: [String: Any] = ["complete": true, "passed": passed, "failures": failures,
            "observations": observations, "display_max_fps": NSScreen.main?.maximumFramesPerSecond ?? 0,
            "mount_trace": WorkspaceMountTrace.events,
            "window_min": NSStringFromSize(window.contentMinSize), "published": false]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}
#endif
