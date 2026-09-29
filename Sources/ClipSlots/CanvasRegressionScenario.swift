#if DEBUG
import SwiftUI
import AppKit
import AVFoundation
import ClipSlotsKit

private enum CanvasRegression {
    static var started = false
}

extension CanvasWorkspaceView {
    /// 本进程场景走实际画布/存储/CLI 路径，只允许独立测试 bundle 与临时数据目录。
    func runCanvasRegressionIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["CLIPSLOTS_CANVAS_REGRESSION"] == "1", !CanvasRegression.started,
              Bundle.main.bundleIdentifier == "com.clipslots.app.canvas-v2174-test",
              env["CLIPSLOTS_DATA_DIR"]?.hasPrefix("/tmp/clipslots-v2174-") == true,
              let folder = env["CLIPSLOTS_FIXTURE_DIR"] else { return }
        CanvasRegression.started = true
        Task { @MainActor in
            var failures: [String] = []
            var passed = 0
            func check(_ condition: Bool, _ message: String) {
                if condition { passed += 1 } else { failures.append(message) }
                NSLog("[CanvasRegression] \(condition ? "PASS" : "FAIL") \(message)")
            }
            func settle(_ seconds: Double = 0.6) async {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            await settle(1)
            inputRouter.anchorView?.window?.setContentSize(CGSize(width: 1440, height: 900))
            let directory = URL(fileURLWithPath: folder, isDirectory: true)
            if env["CLIPSLOTS_NATIVE_CONTROLS"] == "1" {
                try? await Self.makeRegressionMedia(in: directory)
                await runNativeControlsProbe(directory: directory)
                return
            }
            if env["CLIPSLOTS_SLOT_AGENT_PROBE"] == "1" {
                await runSlotAgentProbe(directory: directory)
                return
            }
            if env["CLIPSLOTS_MEDIA_THEME_PROBE"] == "1" {
                try? await Self.makeRegressionMedia(in: directory)
                await runMediaThemeProbe(directory: directory)
                return
            }
            if env["CLIPSLOTS_PROMPT_PROBE"] == "1" {
                await runPromptSizingProbe(directory: directory)
                return
            }
            let metadataRoot = directory.appendingPathComponent("identity-check")
            let identities = CanvasStore(storage: CanvasStorage(rootOverride: metadataRoot),
                                         projectStorage: CanvasProjectStorage(rootOverride: metadataRoot))
            let a = identities.placeSlot(pageId: "p", groupId: "g", slot: 1, name: "a", at: .zero).node
            let b = identities.placeSlot(pageId: "p", groupId: "g", slot: 2, name: "b", at: .zero).node
            identities.updateNode(id: b.id) { $0.createdAt = a.createdAt }
            let ta = identities.beginGeneration(a)!
            let tb = identities.beginGeneration(identities.node(id: b.id)!)!
            identities.updateGeneration(ta.token) { $0.taskId = "task-a" }
            identities.updateGeneration(tb.token) { $0.taskId = "task-b" }
            identities.moveNodes(ids: [a.id, b.id], by: CGSize(width: 80, height: 0))
            _ = identities.undo()
            check(identities.generationNode(ta.token)?.taskId == "task-a", "same timestamp preserves first task identity")
            check(identities.generationNode(tb.token)?.taskId == "task-b", "same timestamp preserves second task identity")
            do { try await Self.makeRegressionMedia(in: directory) }
            catch { check(false, "fixture media: \(error)") }
            canvas.isLibraryExpanded = false
            pan = CGSize(width: 80, height: 65)
            zoom = 0.85
            guard let text = createNode(kind: .text, at: CGPoint(x: 180, y: 170),
                                        parentNodeId: nil, beginEditing: false, quiet: true),
                  // Imported/generated 16:9 media now widens both cards. Keep their
                  // exposed ports clear of neighbouring cards in the click fixture.
                  let image = createNode(kind: .image, at: CGPoint(x: 720, y: 170),
                                         parentNodeId: text.id, beginEditing: false, quiet: true),
                  let video = createNode(kind: .video, at: CGPoint(x: 1430, y: 170),
                                         parentNodeId: image.id, beginEditing: false, quiet: true)
            else { check(false, "create nodes"); return }
            commitEdit(text, text: "海边日落，柔和的橙色天空，远处的山脉。\n保持构图简洁，缓慢推进镜头。")
            commitEdit(image, text: "生成一张电影感分镜，16:9。")
            commitEdit(video, text: "以首帧为基础，镜头缓慢向前移动。")
            if let edge = canvas.incomingEdges(of: image.id).first {
                _ = canvas.disconnect(edgeId: edge.id)
                canvas.flushSave()
                let reload = CanvasStorage(rootOverride: URL(fileURLWithPath: env["CLIPSLOTS_DATA_DIR"]!))
                    .load(projectId: canvas.activeProjectId)
                check(!reload.edges.contains { $0.fromNodeId == text.id && $0.toNodeId == image.id },
                      "disconnect survives reload")
                _ = canvas.undo()
                check(canvas.incomingEdges(of: image.id).count == 1, "undo restores edge")
            }
            canvas.select(id: image.id, additive: false)
            check(canvas.selectedEdgeId == nil, "node and edge selection exclusive")
            let project = canvas.activeProjectId
            if let ticket = canvas.beginGeneration(image) {
                check(canvas.beginGeneration(image) == nil, "duplicate execution blocked")
                _ = canvas.createProject(name: "任务归属测试")
                canvas.updateGeneration(ticket.token) { $0.taskId = "retained-task" }
                check(canvas.generationNode(ticket.token)?.taskId == "retained-task", "inactive project receives metadata")
                _ = canvas.switchProject(to: project)
                check(canvas.node(id: image.id)?.taskId == "retained-task", "switch back retains task")
                canvas.endGeneration(ticket.token)
                canvas.updateNode(id: image.id) { $0.state = .idle; $0.taskId = nil }
            }
            if let disposable = createNode(kind: .image, at: CGPoint(x: 1500, y: 100),
                                             parentNodeId: nil, beginEditing: false, quiet: true),
               let ticket = canvas.beginGeneration(disposable) {
                canvas.removeNodes(ids: [disposable.id])
                check(canvas.generationNode(ticket.token) == nil, "deleted node invalidates task")
                _ = canvas.undo()
                check(canvas.generationNode(ticket.token) == nil, "undo cannot resurrect cancelled ownership")
                canvas.removeNodes(ids: [disposable.id])
            }
            // 暂存区与历史面板必须走同一恢复钩子。
            canvas.removeNodes(ids: [text.id])
            canvas.onRestoreDocument?()
            _ = canvas.undo()
            check(liveText(for: text).contains("海边"), "history restores private slot text")
            startGeneration(canvas.node(id: image.id)!)
            // 同一次 runloop 内再次点，不能发出第二个 submit。
            startGeneration(canvas.node(id: image.id)!)
            for _ in 0..<100 {
                if case .succeeded = canvas.node(id: image.id)?.state { break }
                await settle(0.2)
            }
            if case .succeeded(let path) = canvas.node(id: image.id)?.state {
                check(FileManager.default.fileExists(atPath: path), "image submit poll download persist")
            } else { check(false, "image generation: \(String(describing: canvas.node(id: image.id)?.state))") }
            startGeneration(canvas.node(id: video.id)!)
            // 运行中归到正式槽位，任务应跟随新身份，且当前组异步写不再吞掉临时文件。
            archiveNodeToLibrary(canvas.node(id: video.id)!)
            let videoNow = canvas.nodes.first { $0.createdAt == video.createdAt }!
            for _ in 0..<100 {
                if case .succeeded = canvas.node(id: videoNow.id)?.state { break }
                await settle(0.2)
            }
            if case .succeeded(let path) = canvas.node(id: videoNow.id)?.state {
                check(FileManager.default.fileExists(atPath: path), "video result follows archive to current group")
            } else { check(false, "video generation: \(String(describing: canvas.node(id: videoNow.id)?.state))") }
            if let media = previewableMedia(of: canvas.node(id: videoNow.id)!) {
                let facts = CanvasMediaProbe.facts(for: media)
                check(facts.duration.map { abs($0 - 2) < 0.2 } == true, "stored bin video duration readable")
                check(facts.pixelSize == CGSize(width: 320, height: 180), "stored bin video dimensions readable")
                check(VideoThumbnailProvider.thumbnail(forFile: media.canvasLocalURL!.path, fileName: media.name) != nil,
                      "stored bin video frame decodes")
                check(media.canvasPlaybackURL.map { AVURLAsset(url: $0).isPlayable } == true,
                      "stored bin video playable")
            }
            let beforeCount = store.canvasSlotAttachments(groupId: image.groupId, slot: image.slot).count
            recoverGeneration(canvas.node(id: image.id)!)
            for _ in 0..<60 {
                if case .succeeded = canvas.node(id: image.id)?.state { break }
                await settle(0.2)
            }
            check(store.canvasSlotAttachments(groupId: image.groupId, slot: image.slot).count == beforeCount,
                  "recovery does not duplicate output")
            canvas.select(id: image.id, additive: false)
            pan = CGSize(width: 80, height: 65)
            zoom = 0.85
            await settle()
            let renderBefore = CanvasRenderDiagnostics.count
            for step in 1...30 {
                pan.width = 80 + CGFloat(step)
                await settle(0.025)
            }
            let panBodyEvaluations = CanvasRenderDiagnostics.count - renderBefore
            check(panBodyEvaluations == 0, "30 pan steps do not reevaluate node content")
            check(linkTarget(at: CanvasEdgeGeometry.inputHandle(of: screenFrame(of: videoNow)),
                             from: text.id) == videoNow.id, "input port hit testing")
            _ = handleKeyAction(.selectAll)
            check(canvas.selectedNodeIds.count == canvas.nodes.count, "select all routes to canvas")
            await settle()
            if let window = inputRouter.anchorView?.window {
                window.makeFirstResponder(nil)
                func key(_ code: UInt16, type: NSEvent.EventType = .keyDown) -> NSEvent {
                    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil,
                                     characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
                }
                check(inputRouter.routeForRegression(key(4)) && canvas.activeTool == .hand, "H via AppKit router")
                check(inputRouter.routeForRegression(key(9)) && canvas.activeTool == .select, "V via AppKit router")
                check(inputRouter.routeForRegression(key(49)), "space enables temporary hand")
                let before = pan
                for (type, point) in [(NSEvent.EventType.leftMouseDown, CGPoint(x: 700, y: 400)),
                                      (.leftMouseDragged, CGPoint(x: 728, y: 416)),
                                      (.leftMouseUp, CGPoint(x: 728, y: 416))] {
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 1)!
                    _ = inputRouter.routeForRegression(event)
                }
                check(abs(pan.width - before.width - 28) < 0.1 && abs(abs(pan.height - before.height) - 16) < 0.1,
                      "space drag pans without moving nodes")
                check(inputRouter.routeForRegression(key(49, type: .keyUp)), "space release restores input")
                if let media = previewableMedia(of: canvas.node(id: image.id)!) {
                    openFullscreen(image, attachment: media)
                    let count = canvas.nodes.count
                    _ = handleKeyAction(.delete)
                    check(canvas.nodes.count == count, "preview blocks node deletion")
                    _ = handleKeyAction(.cancel)
                }
            }
            _ = handleKeyAction(.fitContent)
            await settle()
            // 验证实际 AppKit -> SwiftUI 的命中与手势，而非直接调用选择函数。
            if let anchor = inputRouter.anchorView, let window = anchor.window {
                @MainActor func mouse(_ type: NSEvent.EventType, _ point: CGPoint,
                           flags: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
                    // SwiftUI may replace the geometry anchor during this long scenario.
                    // Resolve it per event, just as the live input router does.
                    let location = (inputRouter.anchorView ?? anchor).convert(point, to: nil)
                    if env["CANVAS_SYSTEM_MOUSE"] == "1" {
                        let screen = window.convertPoint(toScreen: location)
                        let quartz = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
                        let eventType: CGEventType = type == .leftMouseDown ? .leftMouseDown
                            : (type == .leftMouseUp ? .leftMouseUp : (type == .mouseMoved ? .mouseMoved : .leftMouseDragged))
                        let payload: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier),
                            "window": window.windowNumber, "type": eventType.rawValue, "x": quartz.x, "y": quartz.y,
                            "flags": flags.rawValue, "clicks": clickCount]
                        if var bytes = try? JSONSerialization.data(withJSONObject: payload) {
                            bytes.append(10)
                            let file = directory.appendingPathComponent("mouse-events.jsonl")
                            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                            if let handle = try? FileHandle(forWritingTo: file) {
                                handle.seekToEndOfFile()
                                handle.write(bytes)
                                try? handle.close()
                            }
                        }
                        return
                    }
                    // #region debug-point B:dispatch
                    if type == .leftMouseDown { var r = URLRequest(url: URL(string: "http://127.0.0.1:7777/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-pointer-routing", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "B", "msg": "[DEBUG] dispatch", "data": ["point": NSStringFromPoint(point), "window": NSStringFromPoint(location), "bounds": NSStringFromRect(anchor.bounds), "hit": String(describing: window.contentView?.hitTest(location)), "key": window.isKeyWindow]]); URLSession.shared.dataTask(with: r).resume() }
                    // #endregion
                    let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags,
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 1, clickCount: clickCount, pressure: 1)!
                    if env["CLIPSLOTS_DIRECT_EVENTS"] == "1" {
                        // Direct mode covers the production router; forwarding to an
                        // inactive NSTextView would enter its blocking mouse-tracking loop.
                        _ = inputRouter.routeForRegression(event)
                    } else {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                @MainActor func click(_ point: CGPoint, flags: NSEvent.ModifierFlags = []) async {
                    mouse(.mouseMoved, point, flags: flags)
                    await settle(0.1)
                    mouse(.leftMouseDown, point, flags: flags)
                    await settle(0.08)
                    mouse(.leftMouseUp, point, flags: flags)
                    await settle(0.3)
                }
                if env["CANVAS_SYSTEM_MOUSE"] == "1" {
                    let ready = directory.appendingPathComponent("mouse-ready")
                    for _ in 0..<50 {
                        if FileManager.default.fileExists(atPath: ready.path) { break }
                        await settle(0.1)
                    }
                    guard (try? String(contentsOf: ready, encoding: .utf8)) == "ready" else {
                        NSLog("[CanvasRegression] External mouse driver unavailable")
                        exit(2)
                    }
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    await settle()
                }
                @MainActor func drag(_ start: CGPoint, _ end: CGPoint) async {
                    mouse(.leftMouseDown, start)
                    await settle(0.08)
                    for step in 1...16 {
                        let fraction = CGFloat(step) / 16
                        mouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * fraction,
                                                         y: start.y + (end.y - start.y) * fraction))
                        await settle(0.025)
                    }
                    mouse(.leftMouseUp, end)
                    await settle()
                }
                let blank = CGPoint(x: viewSize.width - 70, y: viewSize.height - 180)
                await click(blank)
                check(canvas.selectedNodeIds.isEmpty && canvas.selectedEdgeId == nil,
                      "native blank click deselects even with edges")
                let textRect = screenFrame(of: canvas.node(id: text.id)!)
                await click(CGPoint(x: textRect.midX, y: textRect.midY))
                check(canvas.selectedNodeIds == [text.id], "native text card single click selects immediately")
                beginEdit(canvas.node(id: text.id)!)
                await settle()
                await click(blank)
                check(editingNodeId == nil && canvas.selectedNodeIds.isEmpty,
                      "native blank click commits editing and deselects in one click")
                canvas.select(id: text.id, additive: false)
                hoverHoldNodeId = text.id
                await settle()
                if let panel = composerFrame {
                    let covered = CGPoint(x: panel.midX, y: panel.midY)
                    let before = canvas.edges.count
                    check(linkTarget(at: covered, from: text.id) == nil, "composer blocks drag target hit testing")
                    finishLinkDrag(from: text, at: covered, target: videoNow.id)
                    check(canvas.edges.count == before && addMenu == nil, "dropping a wire on composer does not connect behind it")
                }
                let videoRect = screenFrame(of: canvas.node(id: videoNow.id)!)
                await drag(CGPoint(x: textRect.maxX + TapSkin.portOffset, y: textRect.midY),
                           CGPoint(x: videoRect.minX - TapSkin.portOffset, y: videoRect.midY))
                check(canvas.edges.contains { $0.fromNodeId == text.id && $0.toNodeId == videoNow.id },
                      "native port drag connects at displayed input circle")
                check(canvas.node(id: text.id)?.frame == text.frame, "port drag does not move source node")
                let edgeCount = canvas.edges.count
                await drag(CGPoint(x: textRect.maxX + TapSkin.portOffset, y: textRect.midY),
                           CGPoint(x: videoRect.minX - TapSkin.portOffset, y: videoRect.midY))
                check(canvas.edges.count == edgeCount && addMenu == nil, "duplicate native link does not create another edge or menu")
                addMenu = nil
                linkDrag = nil
                await click(CGPoint(x: textRect.midX, y: textRect.midY))
                let imageRect = screenFrame(of: canvas.node(id: image.id)!)
                await click(CGPoint(x: imageRect.midX, y: imageRect.midY), flags: .shift)
                check(canvas.selectedNodeIds == [text.id, image.id], "native Shift click selects both nodes")
                let originalImage = canvas.node(id: image.id)!.frame
                await drag(CGPoint(x: imageRect.midX, y: imageRect.midY),
                           CGPoint(x: imageRect.midX + 40, y: imageRect.midY + 24))
                check(abs(canvas.node(id: text.id)!.x - text.x - 40 / zoom) < 0.6
                      && abs(canvas.node(id: image.id)!.x - originalImage.minX - 40 / zoom) < 0.6,
                      "native multi-selection drag moves every selected node")
                _ = canvas.undo()
                check(canvas.node(id: text.id)!.frame == text.frame && canvas.node(id: image.id)!.frame == originalImage,
                      "one undo restores group drag")
                canvas.clearSelection()
                await settle()
                await drag(CGPoint(x: textRect.minX - 8, y: textRect.minY - 8),
                           CGPoint(x: imageRect.maxX + 8, y: imageRect.maxY + 8))
                check(canvas.selectedNodeIds == [text.id, image.id], "native marquee selects intersecting cards")
                await click(blank)
                lastBlankClick = nil
                mouse(.leftMouseDown, blank)
                mouse(.leftMouseUp, blank)
                await settle(0.08)
                mouse(.leftMouseDown, blank, clickCount: 2)
                mouse(.leftMouseUp, blank, clickCount: 2)
                await settle()
                check(addMenu != nil && addMenu?.allParentIds.isEmpty == true, "native double click blank opens add menu")
                check(CanvasAddNodeMenu.Choice.image.title(referencing: false) == "图片"
                      && CanvasAddNodeMenu.Choice.text.title(referencing: false) == "文本",
                      "blank menu uses add labels without generation")
                PerfAutoTest.snapshotWindow(to: "\(folder)/canvas-add-menu.png")
                if let row = controlRegions["add-menu-row-image"] {
                    await click(CGPoint(x: row.midX, y: row.midY))
                    let added = canvas.soleSelectedNode
                    check(added?.kind == .image && added.map { canvas.incomingEdges(of: $0.id).isEmpty } == true,
                          "native blank menu row creates an unreferenced image")
                    _ = canvas.undo()
                } else { check(false, "blank menu image row reports visible geometry") }
                _ = handleKeyAction(.cancel)
                canvas.select(id: text.id, additive: false)
                await settle()
                mouse(.leftMouseDown, CGPoint(x: textRect.midX, y: textRect.midY), clickCount: 2)
                mouse(.leftMouseUp, CGPoint(x: textRect.midX, y: textRect.midY), clickCount: 2)
                await settle()
                check(editingNodeId == text.id, "native double click text enters editor")
                await click(blank)
                canvas.select(id: image.id, additive: false)
                await settle()
                if let panel = controlRegions["composer"] {
                    // #region debug-point C:editor-frame
                    @MainActor func editorFrames(_ view: NSView) -> [[String: Any]] { (view is NSTextView ? [["type": String(describing: type(of: view)), "rect": NSStringFromRect(anchor.convert(view.bounds, from: view)), "hidden": view.isHiddenOrHasHiddenAncestor]] : []) + view.subviews.flatMap { editorFrames($0) } }
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:7777/event")!); request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-pointer-routing", "runId": "editor-frame", "hypothesisId": "C", "msg": "[DEBUG] editors", "data": ["panel": NSStringFromRect(panel), "fields": window.contentView.map { editorFrames($0) } ?? []]]); URLSession.shared.dataTask(with: request).resume()
                    // #endregion
                    await click(CGPoint(x: panel.minX + 80, y: panel.minY + 78))
                    check(editingNodeId == image.id && canvas.selectedNodeIds == [image.id],
                          "composer controls receive click without canvas deselection")
                    await settle()
                    if let editor = window.firstResponder as? NSTextView {
                        editor.string = "新的生成指令，保留原来的图片。"
                        editor.didChangeText()
                    }
                    await click(blank)
                    check(liveText(for: image) == "新的生成指令，保留原来的图片。",
                          "native outside click saves composer draft")
                    check(previewableMedia(of: canvas.node(id: image.id)!) != nil, "editing retains generated media")
                } else { check(false, "composer reports control geometry") }
                // 用户录屏：36% 缩放，纵向三个空节点；先选一张再框选，连续点击汇聚 +。
                zoom = 0.36
                pan = CGSize(width: 160, height: 110)
                canvas.moveNode(id: image.id, to: CGPoint(x: 100, y: 380))
                canvas.moveNode(id: text.id, to: CGPoint(x: 100, y: 720))
                canvas.moveNode(id: videoNow.id, to: CGPoint(x: 100, y: 1060))
                canvas.select(id: image.id, additive: false)
                await settle()
                let top = screenFrame(of: canvas.node(id: image.id)!)
                let bottom = screenFrame(of: canvas.node(id: videoNow.id)!)
                await click(CGPoint(x: viewSize.width - 60, y: 130))
                await drag(CGPoint(x: top.minX - 14, y: top.minY - 32),
                           CGPoint(x: bottom.maxX + 14, y: bottom.maxY + 32))
                check(canvas.selectedNodeIds.count == 3, "recording 36 percent marquee selects three nodes")
                for attempt in 1...2 {
                    if let junction = selectionJunction {
                        await click(junction)
                        check(addMenu?.allParentIds.count == 3, "recording 36 percent plus opens menu attempt \(attempt)")
                        await click(CGPoint(x: viewSize.width - 60, y: 130))
                        check(addMenu == nil, "native outside click dismisses reference menu")
                    } else { check(false, "recording selection junction exists") }
                }
                if let junction = selectionJunction {
                    await drag(junction, CGPoint(x: junction.x + 7, y: junction.y + 5))
                    check(addMenu?.allParentIds.count == 3, "collective plus tolerates pointer movement during click")
                    _ = handleKeyAction(.cancel)
                    mouse(.leftMouseDown, junction)
                    await settle(0.1)
                    let unrelated = NSWindow()
                    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: unrelated)
                    mouse(.leftMouseUp, junction)
                    await settle()
                    check(addMenu?.allParentIds.count == 3, "unrelated window notification does not cancel plus click")
                    _ = handleKeyAction(.cancel)
                }
                // 单选面板盖住下面节点时，鼠标不能命中背后的节点端口。
                canvas.select(id: image.id, additive: false)
                await settle()
                if let panel = controlRegions["composer"] {
                    let coveredRect = screenFrame(of: canvas.node(id: videoNow.id)!)
                    let covered = CGPoint(x: coveredRect.midX, y: coveredRect.midY)
                    // 先处于下方卡片的 hover，再让面板遮住它（与录屏里平移后的状态一致）。
                    hoverHoldNodeId = videoNow.id
                    inputRouter.cursorPoint = covered
                    mouse(.mouseMoved, covered)
                    await settle()
                    check(interactionNode?.id != videoNow.id, "composer occludes hover of the card behind it")
                    check(!portIsExposed(CGPoint(x: coveredRect.maxX + TapSkin.portOffset, y: coveredRect.midY),
                                         nodeId: videoNow.id), "covered output port is not drawn or hittable")
                    PerfAutoTest.snapshotWindow(to: "\(folder)/canvas-covered-ports.png")
                    // #region debug-point C:covered-port
                    var r = URLRequest(url: URL(string: "http://127.0.0.1:7780/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-overlay-hit", "runId": env["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "C", "msg": "[DEBUG] covered port", "data": ["covered": panel.contains(covered), "point": NSStringFromPoint(covered), "panel": NSStringFromRect(panel), "hover": hoverHoldNodeId ?? "", "interaction": interactionNode?.id ?? "", "selected": Array(canvas.selectedNodeIds)]]); URLSession.shared.dataTask(with: r).resume()
                    // #endregion
                    await click(covered)
                    check(canvas.selectedNodeIds == [image.id] && addMenu == nil,
                          "covered port click stays in composer")
                }
                endInlineEditing()
                // 复刻参考中的纵向多选布局，给汇聚菜单留下可见空间。
                zoom = 0.65
                pan = CGSize(width: 190, height: 150)
                canvas.moveNode(id: image.id, to: CGPoint(x: 80, y: 80))
                canvas.moveNode(id: text.id, to: CGPoint(x: 360, y: 340))
                canvas.moveNode(id: videoNow.id, to: CGPoint(x: 80, y: 570))
                canvas.selectedNodeIds = Set([text.id, image.id, videoNow.id])
                await settle()
                PerfAutoTest.snapshotWindow(to: "\(folder)/canvas-selection.png")
                if let junction = selectionJunction {
                    await click(junction)
                    check(Set(addMenu?.allParentIds ?? []) == canvas.selectedNodeIds,
                          "native collective plus captures all selected parents")
                    PerfAutoTest.snapshotWindow(to: "\(folder)/canvas-selection-menu.png")
                }
                if let request = addMenu {
                    let before = canvas.nodes.count
                    _ = handleKeyAction(.delete)
                    check(canvas.nodes.count == before && addMenu?.id == request.id,
                          "menu blocks Delete from reaching selected nodes")
                    if let row = controlRegions["add-menu-row-audio"] {
                        await click(CGPoint(x: row.midX, y: row.midY))
                        check(addMenu?.id == request.id && canvas.nodes.count == before,
                              "unavailable menu item neither creates nor dismisses")
                    }
                    check(CanvasAddNodeMenu.Choice.image.title(referencing: true) == "图片生成",
                          "downstream menu uses generation labels")
                    if let row = controlRegions["add-menu-row-image"] {
                        await click(CGPoint(x: row.midX, y: row.midY))
                    } else { check(false, "reference menu image row reports visible geometry") }
                    if let child = canvas.soleSelectedNode {
                        check(Set(canvas.incomingEdges(of: child.id).map(\.fromNodeId)) == Set([text.id, image.id, videoNow.id]),
                              "collective creation wires all parents")
                        _ = canvas.undo()
                        check(canvas.nodes.count == before && canvas.node(id: child.id) == nil
                              && canvas.edges.allSatisfy { $0.toNodeId != child.id },
                              "one undo removes collective child and every new edge")
                        _ = canvas.redo()
                        check(canvas.incomingEdges(of: child.id).count == 3, "redo restores collective references")
                        _ = canvas.undo()
                    }
                }
                // 单节点菜单也必须经过真实点击、选择菜单行、创建，不能仅检测 addMenu 状态。
                canvas.select(id: text.id, additive: false)
                hoverHoldNodeId = text.id
                await settle()
                if let port = outputPortPoint {
                    await click(port)
                    check(addMenu?.allParentIds == [text.id], "single node output click opens reference menu")
                    if let row = controlRegions["add-menu-row-video"] {
                        await click(CGPoint(x: row.midX, y: row.midY))
                        if let child = canvas.soleSelectedNode {
                            check(child.kind == .video && canvas.incomingEdges(of: child.id).map(\.fromNodeId) == [text.id],
                                  "native single reference menu creates connected video")
                            _ = canvas.undo()
                        }
                    }
                } else { check(false, "single output control is visible") }
                canvas.select(id: text.id, additive: false)
                zoom = 0.65
                pan = CGSize(width: 450, height: -20)
                await settle()
                PerfAutoTest.snapshotWindow(to: "\(folder)/canvas-text.png")
                let instruction = "将上游内容整理成三句话"
                canvas.setTextGenerationPrompt(id: text.id, text: instruction)
                let originalText = liveText(for: text)
                let transport = AgentScriptedTransport(steps: [.sse(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"这是生成的文本正文。\"},\"finish_reason\":null}]}\n\n"
                    + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")])
                startTextGeneration(canvas.node(id: text.id)!,
                                    service: AgentService(transport: transport, secretStore: AgentInMemorySecretStore(key: "fixture")))
                await settle()
                check(liveText(for: text) == "这是生成的文本正文。", "text generation writes actual response into node")
                check(canvas.node(id: text.id)?.textGenerationPrompt == instruction,
                      "text generation preserves separate instruction")
                _ = canvas.undo()
                check(liveText(for: text) == originalText, "text generation result undo restores previous content")
                importCanvasResource(directory.appendingPathComponent("fixture.png"), at: CGPoint(x: 1500, y: 900))
                if let imported = canvas.soleSelectedNode {
                    let media = previewableMedia(of: imported)
                    check(imported.kind == .image && media?.canvasLocalURL.map {
                        $0.path != directory.appendingPathComponent("fixture.png").path &&
                            FileManager.default.fileExists(atPath: $0.path)
                    } == true, "upload imports image into managed storage and previews it")
                    _ = canvas.undo()
                    check(canvas.node(id: imported.id) == nil, "undo removes uploaded node")
                    _ = canvas.redo()
                    check(canvas.node(id: imported.id).flatMap { previewableMedia(of: $0) }?.canvasLocalURL.map {
                        FileManager.default.fileExists(atPath: $0.path)
                    } == true, "redo restores uploaded image bytes")
                    _ = canvas.undo()
                }
                let textFile = directory.appendingPathComponent("upload.txt")
                try? "导入的文字\n保持完整".write(to: textFile, atomically: true, encoding: .utf8)
                importCanvasResource(textFile, at: CGPoint(x: 1500, y: 900))
                if let imported = canvas.soleSelectedNode {
                    check(imported.kind == .text && liveText(for: imported) == "导入的文字\n保持完整",
                          "upload imports text without modifying another node")
                    _ = canvas.undo()
                    check(canvas.node(id: imported.id) == nil, "one undo removes uploaded text node")
                    _ = canvas.redo()
                    check(liveText(for: imported) == "导入的文字\n保持完整", "redo restores uploaded text content")
                    _ = canvas.undo()
                }
            }
            if env["CLIPSLOTS_OPTIMIZATION_PROBE"] == "1" {
                let child = createNode(kind: .image, at: CGPoint(x: 2000, y: 1000), parentNodeId: nil,
                                       beginEditing: false, quiet: true)!
                let parent = createNode(kind: .image, at: CGPoint(x: 2000, y: 1500), parentNodeId: nil,
                                        beginEditing: false, quiet: true)!
                commitEdit(child, text: "根据上游图片调整光线")
                commitEdit(parent, text: "测试上游图片")
                _ = canvas.connect(from: parent.id, to: child.id)
                canvas.selectedNodeIds = [child.id, parent.id]
                runGenerationForSelection()
                await canvas.selectionGenerationTask?.value
                if case .succeeded = canvas.node(id: child.id)?.state,
                   case .succeeded = canvas.node(id: parent.id)?.state {
                    check(true, "reverse document order batch waits for upstream asset")
                } else { check(false, "reverse document order batch waits for upstream asset") }
                let retainedTask = canvas.node(id: child.id)?.taskId
                canvas.updateNode(id: child.id) { $0.state = .idle }
                await startGeneration(canvas.node(id: child.id)!)?.value
                check(canvas.node(id: child.id)?.taskId == retainedTask,
                      "ordinary primary action recovers existing task without resubmit")
                canvas.updateNode(id: parent.id) { $0.state = .idle; $0.taskId = nil }
                commitEdit(parent, text: "")
                let childTaskBefore = canvas.node(id: child.id)?.taskId
                canvas.selectedNodeIds = [child.id, parent.id]
                runGenerationForSelection()
                await canvas.selectionGenerationTask?.value
                check(canvas.node(id: parent.id)?.taskId == nil && canvas.node(id: child.id)?.taskId == childTaskBefore,
                      "invalid upstream batch does not rerun dependent node")
                canvas.removeNodes(ids: [parent.id, child.id])
            }
            canvas.select(id: image.id, additive: false)
            _ = handleKeyAction(.fitContent)
            UserDefaults.standard.set(ThemeMode.dark.rawValue, forKey: "appearanceMode")
            await settle()
            PerfAutoTest.snapshotWindow(to: "\(folder)/canvas-dark.png")
            beginEdit(canvas.node(id: image.id)!)
            await settle()
            PerfAutoTest.snapshotWindow(to: "\(folder)/canvas-edit.png")
            NSApp.keyWindow?.makeFirstResponder(nil)
            editingNodeId = nil
            UserDefaults.standard.set(ThemeMode.light.rawValue, forKey: "appearanceMode")
            await settle()
            PerfAutoTest.snapshotWindow(to: "\(folder)/canvas-light.png")
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                var frame = window.frame
                frame.size = CGSize(width: 760, height: 680)
                window.setFrame(frame, display: true)
            }
            await settle()
            _ = handleKeyAction(.fitSelection)
            await settle()
            PerfAutoTest.snapshotWindow(to: "\(folder)/canvas-narrow.png")
            let report: [String: Any] = ["passed": passed, "failures": failures,
                                         "expectedCrateSubmissions": env["CLIPSLOTS_OPTIMIZATION_PROBE"] == "1" ? 4 : 2,
                                         "eventDelivery": env["CLIPSLOTS_DIRECT_EVENTS"] == "1"
                                            ? "direct canvas router (no desktop focus)" :
                                            (env["CANVAS_SYSTEM_MOUSE"] == "1" ? "system CGEvent mouse" : "native event queue"),
                                         "nodeBodyEvaluationsDuringPan": panBodyEvaluations]
            if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: directory.appendingPathComponent("report.json"))
            }
            canvas.flushSave()
            NSLog("[CanvasRegression] COMPLETE passed=\(passed) failed=\(failures.count)")
            NSApp.terminate(nil)
        }
    }

    private static func makeRegressionMedia(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = NSImage(size: CGSize(width: 640, height: 360))
        image.lockFocus()
        NSGradient(colors: [NSColor.systemOrange, NSColor.systemPurple])?.draw(
            in: CGRect(x: 0, y: 0, width: 640, height: 360), angle: 90)
        NSColor.systemYellow.setFill()
        NSBezierPath(ovalIn: CGRect(x: 390, y: 185, width: 100, height: 100)).fill()
        NSColor(calibratedRed: 0.1, green: 0.2, blue: 0.3, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 640, height: 140)).fill()
        image.unlockFocus()
        if let tiff = image.tiffRepresentation,
           let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try data.write(to: directory.appendingPathComponent("fixture.png"))
        }
        let movieURL = directory.appendingPathComponent("fixture.mp4")
        try? FileManager.default.removeItem(at: movieURL)
        let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB, nil, &pixel)
            guard let pixel else { continue }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) {
                memset(base, Int32(70 + frame * 8), CVPixelBufferGetDataSize(pixel))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 6))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
#endif
