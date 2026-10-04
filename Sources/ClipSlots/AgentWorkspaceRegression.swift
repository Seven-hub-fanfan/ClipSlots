#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor func runAgentWorkspaceProbe(directory: URL) async {
        var passed = 0
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("[AgentWorkspace] \(ok ? "PASS" : "FAIL") \(name)")
        }
        func settle(_ duration: Double = 0.25) async {
            try? await Task.sleep(for: .seconds(duration))
        }
        func editors(_ view: NSView) -> [AgentDraftEditor.Editor] {
            (view as? AgentDraftEditor.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
            guard depth < 30 else { return [] }
            let children = node.accessibilityChildren?() ?? []
            let fallback = (node as? NSView)?.subviews ?? []
            return [node] + (children.isEmpty ? fallback : children).flatMap { elements($0 as AnyObject, depth: depth + 1) }
        }
        func views(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(views)
        }
        guard let mainWindow = inputRouter.anchorView?.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)
        // SwiftUI builds virtual AX children lazily, only after an external client
        // requests accessibility. Calling AX synchronously on our own PID deadlocks.
        let axBootstrap = await AgentProcessRunner.run(executable: "/usr/bin/swift", arguments: [
            "-e", """
            import ApplicationServices
            let app = AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!)
            print(AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue)
            var windows: CFTypeRef?
            print(AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows).rawValue)
            """, String(ProcessInfo.processInfo.processIdentifier)
        ], timeout: 15)
        NSLog("[AgentWorkspace] AX bootstrap %@", axBootstrap.stdout)
        await settle()
        // Window activation is asynchronous and another app can briefly take focus
        // while the external AX bootstrap starts. Require real focus before input.
        for _ in 0..<10 {
            if mainWindow.isKeyWindow && NSApp.isActive { break }
            NSApp.activate(ignoringOtherApps: true)
            mainWindow.makeKeyAndOrderFront(nil)
            await settle(0.15)
        }
        check(mainWindow.isKeyWindow && NSApp.isActive, "native desktop focus")
        check(WorkspaceMode.allCases.map(\.rawValue) == ["edit", "canvas", "agent"], "three workspace routes")
        let sessions = AgentSessionStore()
        check(sessions.session(for: .agent) === sessions.agent && sessions.agent !== sessions.edit
              && sessions.agent !== sessions.canvas, "three isolated sessions")
        let oldBackend = UserDefaults.standard.string(forKey: TikaBackendPreferences.backendKindKey)
        UserDefaults.standard.set("codex", forKey: CodexPreferences.workspaceBackendKey)
        check(UserDefaults.standard.string(forKey: TikaBackendPreferences.backendKindKey) == oldBackend,
              "workspace backend does not change sidebars")
        for mode in WorkspaceMode.allCases {
            NotificationCenter.default.post(name: .setWorkspaceMode, object: nil, userInfo: ["mode": mode.rawValue])
            await settle(0.5)
            let nodes = mainWindow.contentView.map { elements($0) } ?? []
            let debugRows = nodes.map { node in
                ["type": String(describing: type(of: node)), "label": node.accessibilityLabel?() ?? "",
                 "title": node.accessibilityTitle?() ?? "", "id": node.accessibilityIdentifier?() ?? ""]
            }
            try? JSONSerialization.data(withJSONObject: debugRows, options: [.prettyPrinted])
                .write(to: directory.appendingPathComponent("ax-\(mode.rawValue).json"))
            check(nodes.contains { ($0.accessibilityLabel?() ?? "") == mode.title
                || ($0.accessibilityTitle?() ?? "") == mode.title
                || ($0.accessibilityHelp?() ?? "") == mode.title }, "\(mode.rawValue) switch remains accessible")
            if mode == .agent {
                check(mainWindow.contentView.map { !editors($0).isEmpty } ?? false, "full workspace mounts native composer")
                PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-agent-workspace-route.png").path)
            }
        }

        let path = directory.appendingPathComponent("agent-sessions/workspace.json")
        let model = AgentChatModel(displayName: "Agent", backend: AgentWorkspaceFixtureBackend(), persistenceURL: path)
        model.send(text: "帮我把海边日落的想法整理成分镜", config: AgentConfig(), enabledSkills: [])
        await settle(0.5)
        check(model.messages.last?.content.contains("镜头") == true, "workspace streaming completes")
        check(model.transcript.count == 3, "workspace includes tool result in transcript")
        check(model.flushSession(), "workspace persists history")
        let codex = CodexAgentService(configuration: .init(executable: "/missing", workingDirectory: directory.path))
        let restored = AgentChatModel(displayName: "恢复", backend: codex, persistenceURL: path)
        check(restored.messages == model.messages && codex.sessionID == "workspace-fixture-thread", "restart restores history and Codex thread")
        restored.setBackend(AgentService(transport: AgentScriptedTransport(steps: [
            .sse("data: {\"choices\":[{\"delta\":{\"content\":\"来自另一后端的回答\"}}]}\n\ndata: [DONE]\n\n")
        ]), secretStore: AgentInMemorySecretStore(key: "local-fixture")))
        restored.send(text: "切到另一后端补充上下文", config: AgentConfig(), enabledSkills: [])
        await settle()
        restored.setBackend(codex)
        check(codex.sessionID == nil && restored.messages.last?.content == "来自另一后端的回答",
              "provider switch rebuilds Codex context from full local history")

        model.clearHistory()
        let savedID = model.recentConversations.first?.id
        check(model.isEmpty && savedID != nil, "new chat archives old conversation")
        model.draft = "下一段创作的草稿"
        let file = directory.appendingPathComponent("notes.md")
        try? "附件内容".write(to: file, atomically: true, encoding: .utf8)
        model.addAttachments([file])
        for _ in 0..<50 {
            if !model.isAddingAttachments { break }
            await settle(0.02)
        }
        check(model.draftAttachments.count == 1, "attachment imports into draft")
        check(model.draftAttachments.first?.path != file.path, "attachment has durable private copy")
        model.clearHistory()
        let draftID = model.recentConversations.first?.id
        if let savedID { model.openConversation(id: savedID) }
        check(model.messages.first?.content.contains("日落") == true && model.draftAttachments.isEmpty,
              "opening conversation restores its own text and attachments")
        if let draftID { model.openConversation(id: draftID) }
        check(model.draft == "下一段创作的草稿" && model.draftAttachments.count == 1, "draft attachments restore after switching")
        let imported = AgentChatModel(displayName: "桌面联动", backend: codex,
            persistenceURL: directory.appendingPathComponent("agent-sessions/imported.json"))
        imported.draft = "保留本地未发送草稿"
        let desktopThread = CodexThreadSummary([
            "id": "desktop-import", "name": "桌面历史", "cwd": .string(directory.path),
            "modelProvider": "custom", "model": "custom-model", "reasoningEffort": "high",
            "status": ["type": "idle"]
        ])!
        let importedMessages = [AgentMessage(role: .user, content: "桌面消息"), AgentMessage(role: .assistant, content: "桌面答复")]
        imported.openCodexThread(desktopThread, messages: importedMessages)
        check(imported.recentConversations.first?.draft == "保留本地未发送草稿", "desktop import archives local draft")
        check(imported.codexContext?.provider == "custom" && imported.codexContext?.model == "custom-model",
              "desktop import preserves provider and model")
        imported.draft = "桌面续聊草稿"
        imported.openCodexThread(desktopThread, messages: importedMessages + [AgentMessage(role: .assistant, content: "另一客户端更新")])
        check(imported.draft == "桌面续聊草稿" && imported.messages.last?.content == "另一客户端更新",
              "desktop refresh updates history while preserving draft")
        imported.flushSession()
        let reloaded = AgentChatModel(displayName: "桌面恢复", backend: codex,
            persistenceURL: directory.appendingPathComponent("agent-sessions/imported.json"))
        check(reloaded.codexContext?.cwd == directory.path && reloaded.transcript.count == 3,
              "desktop metadata and transcript survive restart")
        let busyThread = CodexThreadSummary(["id": "desktop-import", "cwd": .string(directory.path), "status": ["type": "active"]])!
        imported.openCodexThread(busyThread, messages: importedMessages)
        check(!imported.send(text: "不能重入", config: AgentConfig(), enabledSkills: []) && imported.draft == "桌面续聊草稿",
              "active desktop thread refuses send without losing draft")
        imported.selectProject(.init(id: directory.path, name: "项目", path: directory.path, isOfficial: false))
        check(imported.codexThreadID == nil && imported.isEmpty && imported.codexContext?.cwd == directory.path,
              "project switch creates independent conversation")
        imported.openCodexThread(desktopThread, messages: importedMessages)
        check(imported.draft == "桌面续聊草稿", "reopening desktop history restores its local draft")
        check(!model.send(text: model.draft, config: AgentConfig(), enabledSkills: []) && model.draftAttachments.count == 1,
              "unsupported backend does not silently send attachments")
        model.draftAttachments = []
        model.errorText = nil
        if let savedID { model.openConversation(id: savedID) }

        let host = NSHostingView(rootView: AgentWorkspaceView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1180, height: 800),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Agent Workspace Test"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        await settle()
        check(editors(host).count == 1, "full page has one native composer")
        if let editor = editors(host).first {
            check(editor.bounds.width > AgentSidebarView.width, "full composer expands beyond sidebar width")
            model.draft = ""
            await settle()
            editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            check(editor.hasMarkedText() && !editor.isPlaceholderVisible, "full page IME hides placeholder")
            editor.insertText("你好", replacementRange: editor.markedRange())
            check(model.draft == "你好", "full page native input updates draft")
            editor.selectAll(nil)
            editor.deleteBackward(nil)
            check(model.draft.isEmpty && editor.isPlaceholderVisible, "full page clear restores placeholder")
        }
        let nodes = elements(host)
        if let search = nodes.first(where: { ($0.accessibilityIdentifier?() ?? "") == "agent-history-search" }) {
            check(true, "history search is accessible")
            if let frame = search.accessibilityFrame?() {
                let point = window.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                    await settle(0.08)
                }
            }
            var fieldEditor = window.firstResponder as? NSTextView
            if fieldEditor == nil,
               let field = views(host).compactMap({ $0 as? NSTextField }).first(where: {
                   $0.accessibilityIdentifier() == "agent-history-search"
                   || $0.placeholderString == "搜索对话"
               }) {
                window.makeFirstResponder(field)
                fieldEditor = window.fieldEditor(true, for: field) as? NSTextView
            }
            fieldEditor?.selectAll(nil)
            fieldEditor?.insertText("不存在的会话", replacementRange: fieldEditor?.selectedRange() ?? NSRange(location: 0, length: 0))
            await settle()
            let filtered = elements(host)
            if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: image)
                try? image.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("canvas-agent-search-filtered.png"))
            }
            let visibleText = filtered.flatMap { node in
                [node.accessibilityLabel?(), node.accessibilityTitle?(),
                 (node as? NSAccessibilityProtocol)?.accessibilityValue() as? String].compactMap { $0 }
            }
            check(fieldEditor?.string == "不存在的会话"
                  && !visibleText.contains("下一段创作的草稿"),
                  "native search filters history")
            fieldEditor?.selectAll(nil)
            fieldEditor?.deleteBackward(nil)
            await settle()
        } else { check(false, "history search is accessible") }
        check(nodes.contains { ($0.accessibilityLabel?() ?? "") == "添加附件" },
              "attachment control is accessible")
        if let button = nodes.first(where: { ($0.accessibilityIdentifier?() ?? "") == "agent-new-conversation" }) {
            let previous = model.selectedConversationID
            check(button.accessibilityPerformPress?() == true, "native new conversation button responds")
            await settle()
            check(model.isEmpty && model.selectedConversationID != previous, "native new conversation switches session")
            model.openConversation(id: previous)
        } else { check(false, "new conversation button is accessible") }
        let preservedDraft = "页面切换后保留草稿"
        model.draft = preservedDraft
        for (identifier, expected) in [
            ("codex-nav-定时任务", "定时任务"),
            ("codex-page-link-projects", "项目"),
            ("codex-page-link-review", "代码审查"),
            ("codex-page-link-tools", "Skills 与 MCP")
        ] {
            let control = elements(host).first { ($0.accessibilityIdentifier?() ?? "") == identifier }
            check(control?.accessibilityPerformPress?() == true, "\(expected) navigation responds")
            await settle(0.4)
            let pageNodes = elements(host)
            let text = pageNodes.flatMap { node in
                [node.accessibilityLabel?(), node.accessibilityTitle?(),
                 (node as? NSAccessibilityProtocol)?.accessibilityValue() as? String].compactMap { $0 }
            }
            check(text.contains(expected), "\(expected) real page mounts")
            check(model.draft == preservedDraft, "\(expected) preserves chat draft")
            if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: image)
                try? image.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("canvas-codex-page-\(expected).png"))
            }
            if expected == "定时任务" {
                let create = pageNodes.first { ($0.accessibilityIdentifier?() ?? "") == "codex-automation-create" }
                check(create?.accessibilityPerformPress?() == true, "automation create responds")
                await settle()
                check(!window.sheets.isEmpty, "automation editor opens natively")
                if let sheet = window.sheets.first, let content = sheet.contentView {
                    let cancel = elements(content).first {
                        ($0.accessibilityLabel?() ?? $0.accessibilityTitle?() ?? "") == "取消"
                    }
                    _ = cancel?.accessibilityPerformPress?()
                    await settle()
                    if !window.sheets.isEmpty { window.endSheet(sheet) }
                }
            }
        }
        let back = elements(host).first { ($0.accessibilityIdentifier?() ?? "") == "codex-page-link-chat" }
        check(back?.accessibilityPerformPress?() == true, "return to Codex responds")
        await settle()
        check(editors(host).count == 1 && model.draft == preservedDraft, "return restores native composer and draft")
        for skin in [AppSkin.minimal, .colorful] {
            AppSkinCenter.apply(skin)
            for appearance in ["light", "dark"] {
                UserDefaults.standard.set(appearance, forKey: AppearanceDefaults.key)
                window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
                host.rootView = AgentWorkspaceView(model: model)
                await settle()
                host.layoutSubtreeIfNeeded()
                if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: image)
                    try? image.representation(using: .png, properties: [:])?
                        .write(to: directory.appendingPathComponent("canvas-agent-workspace-\(skin.rawValue)-\(appearance).png"))
                }
                check(editors(host).count == 1, "\(skin.rawValue) \(appearance) keeps composer")
            }
        }
        window.close()
        do {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Tests/CodexProtocolRegression/fixture.py")
            let taskStore = try CodexAutomationStore(url: directory.appendingPathComponent("schedule-regression/tasks.json"))
            let config = CodexServerConfiguration(executable: "/usr/bin/python3", workingDirectory: directory.path,
                codexHome: directory.appendingPathComponent("schedule-empty-home").path,
                arguments: [fixture.path, "task", directory.appendingPathComponent("schedule-rpc.jsonl").path])
            let scheduler = CodexAutomationModel(store: taskStore, configuration: config)
            var job = CodexAutomation()
            job.name = "原生定时验收"; job.prompt = "本地模拟"; job.cwd = directory.path
            job.frequency = .once; job.nextRun = Date().addingTimeInterval(-1)
            check(scheduler.save(job), "native schedule save")
            scheduler.tick()
            scheduler.tick()
            for _ in 0..<100 {
                if scheduler.activeID == nil { break }
                await settle(0.05)
            }
            check(scheduler.runs.count == 1 && scheduler.runs.first?.status == .completed,
                  "native scheduler due tick executes exactly once")
            check(scheduler.runs.first?.output.contains("完成") == true
                  && scheduler.runs.first?.threadID == "fixture-thread", "scheduled result and thread persist")
            scheduler.toggle(scheduler.tasks[0])
            scheduler.toggle(scheduler.tasks[0])
            scheduler.tick(now: Date().addingTimeInterval(3600))
            check(scheduler.runs.count == 1, "paused schedule never executes")
            scheduler.delete(job.id)
            check(scheduler.tasks.isEmpty && scheduler.runs.count == 1, "native delete retains run results")
        } catch { check(false, "native scheduler: \(error.localizedDescription)") }
        await runAgentReadabilityProbe(directory: directory, check: check)
        await runAgentModelProbe(directory: directory, check: check)
        await runAgentComposerProbe(directory: directory, check: check)
        await runAgentInteractionProbe(directory: directory, check: check)
        await runCanvasAgentProbe(store: store, directory: directory, check: check)
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let report: [String: Any] = ["passed": passed, "failures": failures, "sessionLocked": locked]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}

private final class AgentWorkspaceFixtureBackend: AgentBackend, @unchecked Sendable {
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        await onEvent(.sessionStarted("workspace-fixture-thread"))
        let call = AgentToolCall(id: UUID().uuidString, name: "list_slots", argumentsJSON: "{}")
        await onEvent(.assistantCompleted(AgentMessage(role: .assistant, content: "", toolCalls: [call])))
        await onEvent(.toolStarted(call))
        await onEvent(.toolCompleted(callId: call.id, name: call.name,
                                    result: AgentToolResult(content: "{\"ok\":true,\"slots\":[]}", summary: "完成")))
        let text = "可以把这段日落拆成三个镜头：\n\n1. 远景建立海岸与夕阳的关系。\n2. 中景跟随人物沿水边行走。\n3. 特写捕捉海风与金色的水面。"
        await onEvent(.contentDelta(String(text.prefix(20))))
        try await Task.sleep(for: .milliseconds(120))
        await onEvent(.contentDelta(String(text.dropFirst(20))))
        await onEvent(.assistantCompleted(AgentMessage(role: .assistant, content: text)))
        return []
    }
}
#endif
