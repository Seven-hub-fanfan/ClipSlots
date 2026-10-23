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
            NativeAccessibilityProbe.elements(node)
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
        NativeAccessibilityProbe.enable()
        await settle()
        // Window activation and the external AX client may need several turns
        // after a new candidate is registered. Keep the real focus requirement.
        for attempt in 0..<100 {
            if mainWindow.isKeyWindow && NSApp.isActive { break }
            if attempt % 10 == 0 {
                NSLog("[AgentWorkspace] focus wait attempt=%d active=%d key=%d canKey=%d visible=%d window=%d keyWindow=%d",
                      attempt, NSApp.isActive, mainWindow.isKeyWindow, mainWindow.canBecomeKey,
                      mainWindow.isVisible, mainWindow.windowNumber, NSApp.keyWindow?.windowNumber ?? -1)
            }
            NSApp.activate(ignoringOtherApps: true)
            mainWindow.makeKeyAndOrderFront(nil)
            await settle(0.15)
        }
        if ProcessInfo.processInfo.environment["CLIPSLOTS_BA_CANVAS_PROBE"] == "1" {
            await runByteArtistCanvasProbe(directory: directory, check: check)
            let report: [String: Any] = ["passed": passed, "failures": failures,
                                         "scope": "BA canvas routing, recovery, field selection, media saving and themed native UI"]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"))
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["CLIPSLOTS_DIRECTORY_PROBE"] == "1" {
            await runAgentDirectoryProbe(directory: directory, check: check)
            let report: [String: Any] = ["passed": passed, "failures": failures,
                                         "scope": "OS bookmarks, conversation routing, local file tools and native directory UI"]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"))
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["CLIPSLOTS_SESSION_SYNC_PROBE"] == "1" {
            await runAgentSessionSyncProbe(canvas: canvas, store: store, directory: directory, check: check)
            let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
            let report: [String: Any] = [
                "passed": passed, "failures": failures, "sessionLocked": locked,
                "desktopFocused": mainWindow.isKeyWindow && NSApp.isActive,
                "systemInputValidated": false,
                "scope": "Isolated session files, project routing, native view actions and local backend fixtures"]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"))
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["CLIPSLOTS_SKILL_LAYOUT_PROBE"] == "1" {
            let desktopFocused = mainWindow.isKeyWindow && NSApp.isActive
            await runAgentComposerLayoutProbe(directory: directory, check: check)
            let sessions = AgentSessionStore()
            check(sessions.session(for: .edit) === sessions.edit
                  && sessions.session(for: .agent) === sessions.agent
                  && sessions.edit !== sessions.agent && sessions.canvas !== sessions.agent,
                  "workspace and sidebars have independent session identities")
            sessions.edit.draft = "编辑侧栏独立草稿"
            sessions.agent.draft = "顶部 Agent 独立草稿"
            sessions.edit.clearHistory()
            check(sessions.edit.recentConversations.first?.draft == "编辑侧栏独立草稿"
                  && sessions.agent.draft == "顶部 Agent 独立草稿"
                  && sessions.agent.recentConversations.isEmpty,
                  "archiving a sidebar conversation does not copy it into workspace history")
            check(sessions.agent.flushSession(), "workspace draft persists to its own file")
            let reopened = AgentSessionStore()
            check(reopened.agent.draft == "顶部 Agent 独立草稿"
                  && reopened.edit.recentConversations.first?.draft == "编辑侧栏独立草稿",
                  "restart restores separate workspace and sidebar histories")
            let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
            let report: [String: Any] = [
                "passed": passed, "failures": failures, "sessionLocked": locked,
                "desktopFocused": desktopFocused, "systemInputValidated": false,
                "geometryCases": 72,
                "scope": "Offscreen native view geometry and process-local accessibility actions"]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"))
            NSApp.terminate(nil)
            return
        }
        check(mainWindow.isKeyWindow && NSApp.isActive, "native desktop focus")
        if ProcessInfo.processInfo.environment["CLIPSLOTS_WORKFLOW_SKILL_PROBE"] == "1" {
            await runWorkflowSkillProbe(store: store, canvas: canvas, directory: directory, check: check)
            let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
            let report: [String: Any] = ["passed": passed, "failures": failures, "sessionLocked": locked]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"))
            NSApp.terminate(nil)
            return
        }
        check(WorkspaceMode.allCases.map(\.rawValue) == ["edit", "canvas", "agent"], "three workspace routes")
        let defaults = UserDefaults.standard
        let oldSidebarBackend = defaults.string(forKey: TikaBackendPreferences.backendKindKey)
        let oldWorkspaceBackend = defaults.string(forKey: AgentPreferences.workspaceBackendKey)
        defaults.set(AgentBackendKind.deepseek.rawValue, forKey: TikaBackendPreferences.backendKindKey)
        defaults.set(AgentBackendKind.deepseek.rawValue, forKey: AgentPreferences.workspaceBackendKey)
        let sessions = AgentSessionStore()
        check(sessions.session(for: .agent) === sessions.agent && sessions.agent !== sessions.edit
              && sessions.agent !== sessions.canvas, "three isolated sessions")
        check(AgentBackendScope(workspaceMode: .edit) == .sidebar
              && AgentBackendScope(workspaceMode: .canvas) == .sidebar
              && AgentBackendScope(workspaceMode: .agent) == .workspace,
              "workspace routes share explicit backend scopes")

        defaults.set("codex", forKey: AgentPreferences.workspaceBackendKey)
        let legacySelection = AgentBackendCoordinator.selection(for: .workspace)
        check(legacySelection.kind == .deepseek && legacySelection.backend is AgentService,
              "legacy backend safely falls back as one selection")

        AgentBackendCoordinator.setKind(.tika, for: .workspace)
        await settle()
        check(sessions.agent.backendKind == .tika && sessions.edit.backendKind == .deepseek
              && sessions.canvas.backendKind == .deepseek,
              "workspace backend notification updates only workspace")
        var baseConfig = AgentConfig(model: "deepseek-reasoner",
                                     thinkingMode: .enabled,
                                     reasoningEffort: "high")
        let question = AgentMessage(role: .user, content: "保持上下文")
        let tikaSelection = AgentBackendCoordinator.selection(for: .workspace)
        let invocation = tikaSelection.invocation(
            history: [question], config: baseConfig, tools: nil)
        baseConfig.model = "changed-after-snapshot"
        check(tikaSelection.backend is TikaCLIService
              && invocation.history == [question]
              && invocation.config.model.isEmpty
              && invocation.config.reasoningEffort == nil
              && invocation.config.thinkingMode == .serverDefault,
              "selection atomically normalizes backend invocation context")

        AgentBackendCoordinator.setKind(.tika, for: .sidebar)
        await settle()
        check(sessions.edit.backendKind == .tika && sessions.canvas.backendKind == .tika
              && sessions.agent.backendKind == .tika,
              "sidebar backend notification preserves workspace selection")
        AgentBackendCoordinator.setKind(.deepseek, for: .workspace)
        await settle()
        check(sessions.agent.backendKind == .deepseek && sessions.edit.backendKind == .tika,
              "workspace change leaves sidebar context unchanged")

        if let oldSidebarBackend {
            defaults.set(oldSidebarBackend, forKey: TikaBackendPreferences.backendKindKey)
        } else {
            defaults.removeObject(forKey: TikaBackendPreferences.backendKindKey)
        }
        if let oldWorkspaceBackend {
            defaults.set(oldWorkspaceBackend, forKey: AgentPreferences.workspaceBackendKey)
        } else {
            defaults.removeObject(forKey: AgentPreferences.workspaceBackendKey)
        }
        AgentBackendCoordinator.broadcastChange()
        await settle()
        for mode in WorkspaceMode.allCases {
            NotificationCenter.default.post(name: .setWorkspaceMode, object: nil, userInfo: ["mode": mode.rawValue])
            await settle(0.5)
            let nodes = elements(mainWindow)
            let debugRows = nodes.map { node in
                ["type": String(describing: type(of: node)), "label": node.accessibilityLabel?() ?? "",
                 "title": node.accessibilityTitle?() ?? "", "id": node.accessibilityIdentifier?() ?? ""]
            }
            try? JSONSerialization.data(withJSONObject: debugRows, options: [.prettyPrinted])
                .write(to: directory.appendingPathComponent("ax-\(mode.rawValue).json"))
            let identifier = mode == .agent ? "workspace-beat" : "workspace-\(mode.rawValue)"
            check(nodes.contains { ($0.accessibilityIdentifier?() ?? "") == identifier
                || ($0.accessibilityLabel?() ?? "") == mode.title
                || ($0.accessibilityTitle?() ?? "") == mode.title
                || ($0.accessibilityHelp?() ?? "") == mode.title }, "\(mode.rawValue) switch remains accessible")
            if mode == .agent {
                check(!mode.isSelectable, "Beat placeholder never opens the removed full workspace")
            }
        }

        let path = directory.appendingPathComponent("agent-sessions/workspace.json")
        let model = AgentChatModel(displayName: "Agent", backend: AgentWorkspaceFixtureBackend(), persistenceURL: path)
        model.send(text: "帮我把海边日落的想法整理成分镜", config: AgentConfig(), enabledSkills: [])
        await settle(0.5)
        check(model.messages.last?.content.contains("镜头") == true, "workspace streaming completes")
        check(model.transcript.count == 3, "workspace includes tool result in transcript")
        check(model.flushSession(), "workspace persists history")
        let restored = AgentChatModel(displayName: "恢复", backend: AgentWorkspaceFixtureBackend(), persistenceURL: path)
        check(restored.messages == model.messages, "restart restores complete local history")
        let beforeRead = try? Data(contentsOf: path)
        check(restored.flushSession() && beforeRead == (try? Data(contentsOf: path)),
              "opening and flushing unchanged history preserves original bytes")
        restored.setBackend(AgentService(transport: AgentScriptedTransport(steps: [
            .sse("data: {\"choices\":[{\"delta\":{\"content\":\"来自另一后端的回答\"}}]}\n\ndata: [DONE]\n\n")
        ]), secretStore: AgentInMemorySecretStore(key: "local-fixture")))
        restored.send(text: "切到另一后端补充上下文", config: AgentConfig(), enabledSkills: [])
        await settle()
        check(restored.messages.last?.content == "来自另一后端的回答",
              "provider switch preserves history and completes through DeepSeek")

        model.clearHistory()
        let savedID = model.recentConversations.first?.id
        check(model.isEmpty && savedID != nil, "new chat archives old conversation")
        model.draft = "下一段创作的草稿"
        let file = directory.appendingPathComponent("notes.md")
        try? "附件内容".write(to: file, atomically: true, encoding: .utf8)
        model.draftAttachments = [.init(path: file.path, name: "notes.md")]
        check(model.draftAttachments.count == 1, "legacy draft attachment fixture loaded")
        model.clearHistory()
        let draftID = model.recentConversations.first?.id
        if let savedID { model.openConversation(id: savedID) }
        check(model.messages.first?.content.contains("日落") == true && model.draftAttachments.isEmpty,
              "opening conversation restores its own text and attachments")
        if let draftID { model.openConversation(id: draftID) }
        check(model.draft == "下一段创作的草稿" && model.draftAttachments.count == 1, "draft attachments restore after switching")
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
        check(!nodes.contains { ($0.accessibilityLabel?() ?? "") == "添加附件" },
              "unsupported file-upload control is removed")
        if let button = nodes.first(where: { ($0.accessibilityIdentifier?() ?? "") == "agent-new-conversation" }) {
            let previous = model.selectedConversationID
            check(button.accessibilityPerformPress?() == true, "native new conversation button responds")
            await settle()
            check(model.isEmpty && model.selectedConversationID != previous, "native new conversation switches session")
            model.openConversation(id: previous)
        } else { check(false, "new conversation button is accessible") }
        let preservedDraft = "页面切换后保留草稿"
        model.draft = preservedDraft
        let toggle = elements(host).first { ($0.accessibilityIdentifier?() ?? "") == "agent-nav-展开或收起会话栏" }
        check(toggle?.accessibilityPerformPress?() == true, "conversation rail toggles")
        await settle()
        check(model.draft == preservedDraft && editors(host).count == 1, "rail toggle preserves composer draft")
        let home = elements(host).first { ($0.accessibilityIdentifier?() ?? "") == "agent-nav-主页" }
        check(home?.accessibilityPerformPress?() == true, "home restores conversation rail")
        await settle()
        check(elements(host).contains { ($0.accessibilityIdentifier?() ?? "") == "agent-history-search" },
              "home restores history search")
        check(!elements(host).contains { ($0.accessibilityIdentifier?() ?? "").hasPrefix("codex-") },
              "workspace contains no Codex controls")
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
        await runAgentReadabilityProbe(directory: directory, check: check)
        await runAgentModelProbe(directory: directory, check: check)
        await runAgentComposerProbe(directory: directory, check: check)
        await runAgentInteractionProbe(directory: directory, check: check)
        await runCanvasAgentProbe(store: store, directory: directory, check: check)
        await runWorkflowSkillProbe(store: store, canvas: canvas, directory: directory, check: check)
        await runRetainedAgentProbe(directory: directory, check: check)
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
