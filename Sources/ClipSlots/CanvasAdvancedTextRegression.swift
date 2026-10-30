#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

private actor PolishProbeBackend: AgentBackend {
    var calls = 0
    var history: [[AgentMessage]] = []
    var policies: [AgentTaskPolicy] = []
    var delay: Double = 0.3
    var failure = false
    var response = "暖色夕阳照亮海边的橘猫，柔和侧光勾勒毛发，画面安静自然。"
    func configure(delay: Double = 0.3, failure: Bool = false) {
        self.delay = delay
        self.failure = failure
    }
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        calls += 1
        self.history.append(history)
        policies.append(config.taskPolicy)
        guard tools == nil else { throw AgentError.invalidResponse("Unexpected tools") }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        if failure { throw AgentError.network("模拟网络连接中断；原文已保留") }
        return [.init(role: .assistant, content: response)]
    }
}

extension CanvasWorkspaceView {
    @MainActor func runAdvancedTextProbe(directory: URL) async {
        var live: CanvasWorkspaceView { CanvasAgentGroupsProbeBridge.current ?? self }
        var passed = 0, failures: [String] = []
        var timings: [Double] = []
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failures.append(name) }
            NSLog("[AdvancedText] %@ %@", value ? "PASS" : "FAIL", name)
        }
        func settle(_ seconds: Double = 0.15) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        guard let anchor = inputRouter.anchorView, let window = anchor.window else { return }
        func editors(_ view: NSView) -> [NSTextView] {
            ([view as? NSTextView].compactMap { $0 }) + view.subviews.flatMap(editors)
        }
        func click(_ key: String) async {
            guard let rect = controlRegions[key] else { check(false, "Control exists: \(key)"); return }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let point = anchor.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1) { NSApp.sendEvent(event) }
            }
            await settle(0.03)
        }
        func key(_ code: UInt16, _ chars: String, modifiers: NSEvent.ModifierFlags = []) {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code) { NSApp.sendEvent(event) }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(CGSize(width: 1250, height: 850))
        canvas.isLibraryExpanded = false
        pan = CGSize(width: 50, height: 35)
        zoom = 0.8
        guard let node = createNode(kind: .text, at: CGPoint(x: 540, y: 220),
                                    parentNodeId: nil, beginEditing: false, quiet: true) else { return }
        canvas.select(id: node.id, additive: false)
        composingNodeId = node.id
        await settle(0.4)
        let document = store.canvasTextDocument(groupID: node.groupId, slot: node.slot)
        let backend = PolishProbeBackend()
        CanvasTextGeneration.regressionBackend = backend
        defer { CanvasTextGeneration.regressionBackend = nil }
        guard let editor = window.contentView.flatMap({ editors($0).first(where: { $0.isEditable }) }) else { return }
        window.makeFirstResponder(editor)
        let samples = [
            "中文🙂 café e\u{301} \"引号\" '单引号' & <tag> \\路径 $变量\n",
            "  # 标题\n\n| 镜头 | 描述 |\n|---|---|\n| 1 | 海边 |\n\t缩进  \n",
            String(repeating: "镜头缓慢推进🙂，保留中文和换行。\n", count: 1500)
        ]
        for (index, sample) in samples.enumerated() {
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            let start = ProcessInfo.processInfo.systemUptime
            editor.insertText(sample, replacementRange: editor.selectedRange())
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            timings.append(elapsed)
            check(document.text == sample && liveText(for: node) == sample, "Sample \(index) synchronizes in input callback")
            check(elapsed < 100, "Sample \(index) synchronous edit under 100ms")
            let captured = CanvasWorkflowCapture.facts(nodes: [node], store: store, includeMediaMetadata: false)
            check(captured.first?.body == sample, "Sample \(index) workflow sees current unsaved text")
            for _ in 0..<30 {
                await settle(0.05)
                if !document.isDirty { break }
            }
            check(store.canvasReadFullContent(groupId: node.groupId, slot: node.slot)?.plainText == sample,
                  "Sample \(index) disk round trip exact")
        }
        check(await backend.calls == 0, "Typing and pasting never invoke AI")
        check(editor.enclosingScrollView?.hasVerticalScroller == true, "Long text has native vertical scrolling")
        check(editor.enclosingScrollView.map { $0.bounds.height <= 280.5 && $0.bounds.height >= 112 } == true,
              "Adaptive editor height stays within bounds")
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText("输入快捷键测试", replacementRange: editor.selectedRange())
        await settle()
        let beforeEnter = await backend.calls
        key(36, "\r")
        await settle()
        check(document.text.contains("\n"), "Enter inserts a newline")
        check(await backend.calls == beforeEnter, "Enter does not submit AI")
        editor.breakUndoCoalescing()
        editor.undoManager?.removeAllActions()
        let beforeUndo = document.text
        editor.insertText("UNDO_MARK", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        await settle()
        editor.undoManager?.undo()
        check(document.text == beforeUndo, "Native undo synchronizes shared document")
        editor.undoManager?.redo()
        check(document.text.contains("UNDO_MARK"), "Native redo synchronizes shared document")
        key(36, "\r", modifiers: .command)
        await settle()
        check(await backend.calls == beforeEnter, "Cmd Enter saves without invoking AI")

        document.edit("一只橘猫在海边观看夕阳，保持自然光线和安静构图。")
        _ = document.flush()
        await settle()
        await backend.configure(delay: 0.6)
        await click("composer-polish")
        await click("composer-polish")
        check(await backend.calls == 1, "Actual AI button sends one request during loading")
        check(canvas.node(id: node.id).map { if case .running = $0.state { return true }; return false } == true,
              "AI button sets running state")
        PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("polish-loading.png").path)
        await settle(0.8)
        check(document.text == (await backend.response), "Successful polish updates the shared input")
        check(await backend.policies.allSatisfy { $0 == .textPolish }, "Polish uses strict backend task policy")
        _ = canvas.undo()
        await settle()
        check(document.text.contains("观看夕阳"), "Canvas undo restores pre-polish body")

        let old = document.text
        await backend.configure(delay: 0.45)
        await click("composer-polish")
        document.edit(old + "\n用户在润色期间追加的细节")
        await settle(0.65)
        check(document.text.hasSuffix("用户在润色期间追加的细节"), "Late result cannot overwrite a newer edit")
        check(canvas.node(id: node.id).map { if case .failed = $0.state { return true }; return false } == true,
              "Edit conflict has visible failure state")
        let edited = document.text
        await backend.configure(delay: 0.1, failure: true)
        await click("composer-polish")
        await settle(0.3)
        check(document.text == edited, "Network failure preserves complete input")
        await backend.configure(delay: 1)
        await click("composer-polish")
        await click("composer-polish-cancel")
        await settle(0.2)
        check(document.text == edited, "Cancel preserves complete input")
        check(canvas.node(id: node.id)?.state == .idle, "Cancel immediately clears loading state")

        // Test the document against an independent storage/queue with actual checked writes.
        let root = directory.appendingPathComponent("document-store")
        let storage = SpecialSlotStorage(baseDirectory: root, role: .main)
        let group = storage.loadIndex().specialSlots[0].id
        var original = SlotContent()
        original.items = [[PasteboardItem(type: "public.utf8-plain-text", data: Data("初始".utf8))]]
        original.attachments = [.init(name: "保留.png", type: .image)]
        _ = storage.set(1, content: original, in: group)
        let queue = DispatchQueue(label: "advanced.document-fixture")
        let doc = CanvasTextDocument(content: storage.get(1, in: group), storage: storage,
                                     groupID: group, slot: 1, queue: queue)
        var saves = 0
        doc.didPersist = { _, _, _, _ in saves += 1 }
        for index in 0..<100 { doc.edit("连续输入\(index)") }
        check(saves == 0, "100 input events do not synchronously save")
        await settle(0.45)
        check(saves == 1 && storage.get(1, in: group).plainText == "连续输入99", "One debounced save persists final burst")
        check(storage.get(1, in: group).attachments == original.attachments, "Typing preserves attachments exactly")
        let durable = doc.text
        doc.edit("排队中的写入")
        doc.saveSoon()
        doc.edit(durable)
        check(doc.flush(), "Flush handles queued edit then revert")
        await settle(0.2)
        check(doc.text == durable && storage.get(1, in: group).plainText == durable && !doc.isDirty,
              "Late callbacks cannot resurrect reverted content")
        var external = storage.get(1, in: group)
        external.items = [[PasteboardItem(type: "public.utf8-plain-text", data: Data("外部修改".utf8))]]
        external.contentId = UUID().uuidString
        external.updatedAt = Date().timeIntervalSince1970
        _ = storage.set(1, content: external, in: group)
        doc.edit("未保存的用户草稿")
        check(!doc.flush() && doc.saveError != nil, "Concurrent external write causes checked save failure")
        check(doc.text == "未保存的用户草稿" && storage.get(1, in: group).plainText == "外部修改",
              "Save failure retains both draft and external content")

        // Configuration routing is tested without consulting or sending user credentials.
        let defaults = UserDefaults(suiteName: "advanced-text-\(UUID())")!
        defaults.set("deepseek-flash", forKey: AgentPreferences.modelKey)
        for kind in AgentBackendKind.allCases {
            defaults.set(kind.rawValue, forKey: TikaBackendPreferences.backendKindKey)
            let config = CanvasTextGeneration.configuration(defaults: defaults)
            check(config.model == (kind == .deepseek ? "deepseek-flash" : ""),
                  "\(kind.rawValue) model routing matches sidebar preferences")
        }
        func sse(_ text: String) -> String {
            let json: JSONValue = ["choices": [["delta": ["content": .string(text)], "finish_reason": "stop"]]]
            return "data: \(try! json.encodedText())\n\ndata: [DONE]\n\n"
        }
        let repair = AgentScriptedTransport(steps: [.sse(sse("<svg>bad</svg>")), .sse(sse("海边的橘猫沐浴在金色夕阳中，画面安静。"))])
        do {
            _ = try await CanvasTextGeneration.optimizedPrompt("橘猫",
                config: AgentConfig(), service: AgentService(transport: repair, secretStore: AgentInMemorySecretStore(key: "fixture")))
            let history = repair.requestJSON(at: 1)?["messages"]?.arrayValue ?? []
            check(history.contains { $0["role"] == "assistant" && $0["content"] == "<svg>bad</svg>" },
                  "Format correction includes the rejected assistant answer")
            check(repair.capturedRequests.count == 2, "Format correction has one retry")
        } catch { check(false, "Format correction succeeds: \(error)") }
        for suffix in ["", #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"# + "\n\n"] {
            let partial = AgentScriptedTransport(steps: [.sse(#"data: {"choices":[{"delta":{"content":"这段文字表面完整但服务端尚未完成"},"finish_reason":null}]}"# + "\n\n" + suffix)])
            do {
                _ = try await CanvasTextGeneration.optimizedPrompt("测试", config: AgentConfig(),
                    service: AgentService(transport: partial, secretStore: AgentInMemorySecretStore(key: "fixture")))
                check(false, "Incomplete stream must fail")
            } catch { check(true, "Incomplete stream rejected") }
        }

        document.edit("电影感分镜\n\n雨后的城市街角，一只橘猫坐在窗边。暖色灯光映在湿润石板上，镜头缓慢向前推进。\n\n保留自然色彩与细腻的毛发质感。")
        _ = document.flush()
        canvas.updateNode(id: node.id) { $0.state = .idle }
        window.makeFirstResponder(nil)
        for skin in AppSkin.allCases.map(\.rawValue) {
            for appearance in ["light", "dark"] {
                AppSkinCenter.apply(AppSkin(rawValue: skin) ?? .minimal)
                UserDefaults.standard.set(appearance, forKey: "appearanceMode")
                NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                await settle(0.3)
                live.composingNodeId = node.id
                await settle()
                PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("\(skin)-\(appearance).png").path)
                check(live.controlRegions["composer-polish"].map { $0.width > 0 && $0.minX >= 0 && $0.maxX <= live.viewSize.width } == true,
                      "\(skin)/\(appearance) polish control remains visible")
            }
        }
        window.setContentSize(CGSize(width: 960, height: 700))
        await settle(0.4)
        PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("narrow.png").path)
        check(live.controlRegions["composer-polish"].map { $0.minX >= 0 && $0.maxX <= live.viewSize.width } == true,
              "Narrow window retains polish control")
        if let disposable = live.createNode(kind: .text, at: CGPoint(x: 1000, y: 800),
                                        parentNodeId: nil, beginEditing: false, quiet: true) {
            check(canvas.onRestoreDocument != nil, "Restore bridge survives theme changes")
            let draft = store.canvasTextDocument(groupID: disposable.groupId, slot: disposable.slot)
            draft.edit("删除前尚在防抖窗口中的正文🙂")
            canvas.select(id: disposable.id, additive: false)
            window.makeFirstResponder(nil)
            _ = live.handleKeyAction(.delete)
            check(canvas.node(id: disposable.id) == nil, "Delete flushes pending draft before removing node")
            let undone = canvas.undo()
            check(undone?.kind == .removeNode, "Undo targets deletion after the flushed text edit")
            await settle()
            check(liveText(for: disposable) == "删除前尚在防抖窗口中的正文🙂", "Undo delete restores the entire pending draft")
            draft.edit("入库前尚未落盘的正文🙂")
            live.archiveNodeToLibrary(disposable)
            await settle()
            check(live.archiveRequest?.nodes.first?.id == disposable.id, "Archive opens page/group/slot picker")
            live.archiveRequest = nil
            if let slot = (1...10).first(where: {
                store.canvasSlotIsFree(groupId: store.currentSpecialSlotId, slot: $0)
                    && canvas.node(forGroupId: store.currentSpecialSlotId, slot: $0) == nil
            }) {
                do { try archiveNode(disposable, pageID: store.currentPageId, groupID: store.currentSpecialSlotId, slot: slot) }
                catch { check(false, "Selected archive target succeeds: \(error)") }
            }
            if let rebound = canvas.nodes.first(where: { $0.createdAt == disposable.createdAt }) {
                check(rebound.groupId == store.currentSpecialSlotId && liveText(for: rebound) == "入库前尚未落盘的正文🙂",
                      "Archive rebind preserves pending text")
                let newDocument = store.canvasTextDocument(groupID: rebound.groupId, slot: rebound.slot)
                check(newDocument !== draft && newDocument.text == liveText(for: rebound), "Rebound editor starts with the correct shared document")
                newDocument.edit("切项目前的最新编辑")
                let project = canvas.activeProjectId
                _ = canvas.createProject(name: "文档切换测试")
                _ = canvas.switchProject(to: project)
                check(liveText(for: rebound) == "切项目前的最新编辑", "Project switch flushes pending edits")
            } else { check(false, "Archived node exists") }
        }
        let report: [String: Any] = ["passed": passed, "failures": failures,
            "synchronousEditMilliseconds": timings, "modelCalls": await backend.calls,
            "systemInputValidated": false, "device": ProcessInfo.processInfo.operatingSystemVersionString]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}
#endif
