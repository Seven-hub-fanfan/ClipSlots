#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runAgentSessionSyncProbe(canvas: CanvasStore, store: SlotStoreObservable,
                             directory: URL, check: (Bool, String) -> Void) async {
    func settle() async { try? await Task.sleep(for: .milliseconds(160)) }
    func wait(_ condition: () -> Bool) async {
        for _ in 0..<40 {
            if condition() { return }
            await settle()
        }
    }
    func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 30 else { return [] }
        let children = node.accessibilityChildren?() ?? []
        let fallback = (node as? NSView)?.subviews ?? []
        return [node] + (children.isEmpty ? fallback : children).flatMap {
            elements($0 as AnyObject, depth: depth + 1)
        }
    }
    func saved(_ title: String, id: UUID = UUID(), time: Double = 1_700_000_000) -> AgentChatModel.SavedConversation {
        .init(id: id, messages: [.init(role: .user, content: title),
                                .init(role: .assistant, content: "完整回答🙂")],
              draft: "保留草稿", updatedAt: Date(timeIntervalSince1970: time),
              codexThreadID: "legacy-fixture", draftAttachments: nil,
              codexContext: .init(cwd: "/legacy", title: title),
              draftReferences: nil,
              draftSkillReferences: [.init(name: "fixture", path: "/fixture/SKILL.md", markdown: "完整原文")])
    }
    let root = directory.appendingPathComponent("sync-fixtures")
    func write(_ source: AgentConversationSource, current: AgentChatModel.SavedConversation,
               recent: [AgentChatModel.SavedConversation] = []) throws {
        let url = source.url(dataRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(AgentChatModel.SavedSessions(current: current, recent: recent))
            .write(to: url, options: .atomic)
    }
    do {
        let originalProject = canvas.activeProjectId
        let projectA = canvas.createProject(name: "同步项目 A")
        let projectB = canvas.createProject(name: "未打开的同步项目 B")
        canvas.switchProject(to: projectA.id)
        let duplicateID = UUID()
        let workspace = saved("顶部历史")
        let edit = saved("编辑历史")
        let unopened = saved("项目 B 的历史")
        let orphan = saved("已删除项目的记录")
        let legacy = saved("旧版画布记录")
        let bArchived = saved("项目 B 归档历史", time: 1_600_000_000)
        try write(.workspace, current: workspace,
                  recent: [saved("重复旧记录", id: duplicateID)])
        try write(.edit, current: edit,
                  recent: [saved("重复记录的最新副本", id: duplicateID, time: 1_800_000_000)])
        try write(.legacyCanvas, current: legacy)
        try write(.project(projectB.id), current: unopened, recent: [bArchived])
        try write(.project("deleted-project"), current: orphan)
        let malformedURL = AgentConversationSource.project("broken-project").url(dataRoot: root)
        try Data("invalid json".utf8).write(to: malformedURL)
        let protected = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".json") }.reduce(into: [String: Data]()) {
                $0[$1] = try? Data(contentsOf: root.appendingPathComponent($1))
            }

        let sessions = AgentSessionStore(dataRoot: root)
        let index = sessions.directory
        index.bind(canvas: canvas)
        index.refresh()
        await wait { !index.isScanning }
        check(index.entries.count == 7, "unified directory includes current, archived, sidebar and unopened project records")
        check(index.entries.filter { $0.id == duplicateID }.count == 1
              && index.entries.first { $0.id == duplicateID }?.title == "重复记录的最新副本",
              "UUID duplicates are indexed once with the newest live copy")
        check(index.entries.contains { $0.id == bArchived.id }
              && !sessions.liveSessions.contains { $0.0 == .project(projectB.id) },
              "unopened projects are indexed without creating another writer")
        check(index.error != nil && (try? Data(contentsOf: malformedURL)) == Data("invalid json".utf8),
              "unreadable history is reported and never rewritten")
        check(protected.allSatisfy {
            (try? Data(contentsOf: root.appendingPathComponent($0.key))) == $0.value
        }, "directory scanning and initial display preserve all legacy history bytes")
        check(AgentConversationSource.projectSource(filename: "not-hex") == nil
              && AgentConversationSource.projectSource(filename: "e4b8ad") == .project("中"),
              "project filenames validate hex and Unicode identifiers")

        guard let editEntry = index.entries.first(where: { $0.id == edit.id }) else {
            check(false, "edit entry is indexed"); return
        }
        check(index.open(editEntry, canvas: canvas, store: store)
              && index.selectedModel === sessions.edit && !index.selectedModel.usesWorkspaceBackend,
              "opening sidebar history reuses its exact model and backend scope")
        index.selectedModel.draft = "顶部修改，侧栏同步🙂"
        check(sessions.edit.draft == "顶部修改，侧栏同步🙂", "workspace edits immediately update the sidebar draft")
        sessions.edit.draft = "侧栏修改，顶部同步🙂"
        sessions.edit.draftSkillReferences.append(.init(name: "第二个技能", path: "/fixture/two", markdown: "snapshot"))
        await settle()
        check(index.selectedModel.draft == sessions.edit.draft
              && index.selectedModel.draftSkillReferences == sessions.edit.draftSkillReferences
              && index.entries.first(where: { $0.id == edit.id })?.searchableText.contains("侧栏修改") == true,
              "sidebar draft, references and searchable directory refresh together")
        let originalBytes = try Data(contentsOf: AgentConversationSource.workspace.url(dataRoot: root))
        let backend = SessionSyncFixtureBackend()
        sessions.edit.setBackend(backend, kind: .deepseek)
        check(sessions.edit.send(text: "生成同步验证", config: AgentConfig(), enabledSkills: []),
              "shared session accepts one generation")
        await wait { backend.calls == 1 && !sessions.edit.streamingContent.isEmpty }
        let active = AgentConversationEntry(sessions.edit.snapshot, source: .edit, current: true, running: true)
        check(index.open(active, canvas: canvas, store: store) && sessions.edit.isRunning,
              "reopening the running current UUID does not stop generation")
        let workspaceEntry = AgentConversationEntry(sessions.agent.snapshot, source: .workspace, current: true)
        check(index.open(workspaceEntry, canvas: canvas, store: store) && sessions.edit.isRunning,
              "switching displayed sources preserves the other running generation")
        check(index.open(active, canvas: canvas, store: store)
              && index.selectedModel.streamingContent == sessions.edit.streamingContent,
              "returning to a running source shows the same streamed content")
        index.selectedModel.stop()
        await settle()
        check(!sessions.edit.isRunning && backend.calls == 1 && backend.cancelled,
              "stop from workspace reaches the same request without duplicate backend calls")
        check((try? Data(contentsOf: AgentConversationSource.workspace.url(dataRoot: root))) == originalBytes,
              "sidebar generation never writes workspace transcript")

        let projectModel = sessions.canvasSession(canvas: canvas, store: store)
        check(sessions.sidebarSession(canvas: canvas, store: store) === projectModel,
              "edit and canvas sidebars resolve the same active project writer")
        projectModel.draft = "项目 A 草稿"
        let projectEntry = AgentConversationEntry(projectModel.snapshot, source: .project(projectA.id), current: true)
        check(index.open(projectEntry, canvas: canvas, store: store)
              && index.selectedModel === projectModel && index.readOnlyReason == nil,
              "active canvas history shares its project model")
        let projectBackend = SessionSyncFixtureBackend()
        projectModel.setBackend(projectBackend, kind: .deepseek)
        projectModel.send(text: "项目 A 快照", config: AgentConfig(), enabledSkills: [])
        await wait { projectModel.isRunning && !projectModel.streamingContent.isEmpty }
        check(sessions.sidebarSession(canvas: canvas, store: store).isRunning
            && sessions.sidebarSession(canvas: canvas, store: store).streamingContent == projectModel.streamingContent
            && projectBackend.calls == 1,
            "cross-mode session resolution preserves one streaming request")
        check(projectBackend.toolNames.contains("canvas_current")
            && projectBackend.toolNames.contains("write_slot") && projectBackend.toolNames.contains("read_slot"),
            "shared project run declares both live canvas and existing library tools")
        let runScope = projectModel.snapshot
        check(runScope.run?.libraryPageID == store.currentPageId
            && runScope.run?.libraryGroupID == store.currentSpecialSlotId,
            "submitted library target is saved with the active run")
        let resumeURL = root.appendingPathComponent("resume-library-target.json")
        try JSONEncoder().encode(AgentChatModel.SavedSessions(current: runScope, recent: []))
            .write(to: resumeURL)
        let restoredRun = AgentChatModel(displayName: "恢复目标",
            backend: SessionSyncFixtureBackend(), persistenceURL: resumeURL,
            canvasProjectID: projectA.id)
        check(restoredRun.snapshot.run?.libraryPageID == runScope.run?.libraryPageID
            && restoredRun.snapshot.run?.libraryGroupID == runScope.run?.libraryGroupID,
            "restart preserves the library target for run recovery")
        let turn = projectModel.messages.last(where: { $0.role == .user })?.canvasTurn
        canvas.switchProject(to: projectB.id)
        await settle()
        check(index.readOnlyReason != nil && !projectModel.isRunning
              && !projectModel.send(text: "禁止串项目", config: AgentConfig(), enabledSkills: []),
              "leaving a project disables its shared input and rejects cross-project calls")
        let inactiveReader = turn.flatMap { captured in
            projectModel.canvasContext.flatMap { try? $0.reader(for: captured) }
        }
        check(turn?.projectID == projectA.id && inactiveReader == nil,
              "project snapshot identity remains frozen and inactive readers fail")
        check(projectBackend.cancelled, "project switch cancels the request shared by both sidebars")
        guard let bEntry = index.entries.first(where: { $0.id == unopened.id }) else {
            check(false, "unopened project entry survives live refresh"); return
        }
        check(index.open(bEntry, canvas: canvas, store: store)
              && canvas.activeProjectId == projectB.id
              && index.selectedModel === sessions.canvasSession(canvas: canvas, store: store)
              && index.selectedModel !== projectModel,
              "opening previously unopened history routes to its own project and writer")
        let bModel = index.selectedModel
        check(bModel.selectedConversationID == unopened.id
              && bModel.draftSkillReferences.first?.markdown == "完整原文",
              "legacy project history retains UUID and frozen Skill content")
        check(index.open(projectEntry, canvas: canvas, store: store)
              && canvas.activeProjectId == projectA.id && index.selectedModel === projectModel
              && index.readOnlyReason == nil, "opening another project switches to the matching context")
        canvas.renameProject(id: projectA.id, name: "同步项目 A 已改名")
        await settle()
        check(index.sourceLabel(.project(projectA.id)).contains("已改名"),
              "source labels follow project renames without changing conversation identity")

        guard let orphanEntry = index.entries.first(where: { $0.id == orphan.id }),
              let legacyEntry = index.entries.first(where: { $0.id == legacy.id }) else {
            check(false, "read-only histories are indexed"); return
        }
        check(index.open(orphanEntry, canvas: canvas, store: store)
              && index.readOnlyReason != nil && canvas.activeProjectId == projectA.id,
              "deleted project remains visible read-only without adopting another canvas")
        check(!index.selectedModel.send(text: "禁止无项目调用", config: AgentConfig(), enabledSkills: []),
              "missing-project model rejects backend calls even outside the UI")
        check(index.open(legacyEntry, canvas: canvas, store: store) && index.readOnlyReason != nil,
              "legacy canvas records remain readable in the unified directory")
        index.newConversation(source: .project(projectB.id), canvas: canvas, store: store)
        let newID = index.selectedModel.selectedConversationID
        check(index.selectedModel === bModel && bModel.recentConversations.contains { $0.id == unopened.id }
              && canvas.activeProjectId == projectB.id && newID != unopened.id,
              "new conversation explicitly archives within the selected project")
        bModel.draft = "项目 B 新草稿"
        guard let archivedEntry = index.entries.first(where: { $0.id == bArchived.id }) else {
            check(false, "archived entry remains indexed"); return
        }
        check(index.open(archivedEntry, canvas: canvas, store: store)
              && bModel.selectedConversationID == bArchived.id
              && bModel.draftSkillReferences.first?.markdown == "完整原文",
              "opening an archived UUID swaps the original project session without cloning history")
        bModel.openConversation(id: newID)
        bModel.draft = "项目 B 新草稿"
        check(bModel.flushSession() && sessions.edit.flushSession() && projectModel.flushSession(),
              "all source writers flush their own histories")
        let reopened = AgentSessionStore(dataRoot: root)
        let reopenedIndex = reopened.directory
        reopenedIndex.bind(canvas: canvas)
        reopenedIndex.refresh()
        await wait { !reopenedIndex.isScanning }
        let reopenedB = reopened.canvasSession(canvas: canvas, store: store)
        check(reopened.sidebarSession(canvas: canvas, store: store) === reopenedB,
              "restart retains one project writer for both sidebars")
        check(reopenedB.selectedConversationID == newID && reopenedB.draft == "项目 B 新草稿"
              && reopenedB.recentConversations.contains { $0.id == unopened.id },
              "restart restores each current UUID, draft and archived history")
        check(reopenedIndex.entries.contains { $0.id == bArchived.id }
              && reopenedIndex.entries.filter { $0.id == duplicateID }.count == 1,
              "restart rebuilds archived disk index without duplicate UUIDs")

        // Actual shared views: no fixture data from the real user's directory.
        index.open(AgentConversationEntry(sessions.edit.snapshot, source: .edit, current: true),
                   canvas: canvas, store: store)
        let host = NSHostingView(rootView: AgentWorkspaceView(sessions: sessions, canvas: canvas, store: store))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 60, width: 1180, height: 780),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        await settle()
        let buttons = elements(host)
        let orphanButton = buttons.first {
            ($0.accessibilityIdentifier?() ?? "") == "agent-conversation-\(orphan.id.uuidString)"
        }
        check(orphanButton?.accessibilityPerformPress?() == true, "unified history row opens through native action")
        await settle()
        check(index.selectedModel.selectedConversationID == orphan.id && index.readOnlyReason != nil,
              "native history selection preserves read-only source routing")
        func editors(_ view: NSView) -> [AgentDraftEditor.Editor] {
            (view as? AgentDraftEditor.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        check(editors(host).first?.isEditable == false, "read-only history disables the native text editor")
        if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(
                to: directory.appendingPathComponent("session-sync-readonly.png"))
        }
        index.open(AgentConversationEntry(sessions.edit.snapshot, source: .edit, current: true),
                   canvas: canvas, store: store)
        await settle()
        let sidebarHost = NSHostingView(rootView: AgentSidebarView(
            model: sessions.edit, isVisible: .constant(true), workspaceMode: .edit))
        let sidebarWindow = NSWindow(contentRect: NSRect(x: 80, y: 60, width: 480, height: 720),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        sidebarWindow.isReleasedWhenClosed = false
        sidebarWindow.contentView = sidebarHost
        sidebarWindow.makeKeyAndOrderFront(nil)
        await settle()
        if let topEditor = editors(host).first, let sidebarEditor = editors(sidebarHost).first {
            topEditor.selectAll(nil)
            topEditor.insertText("顶部原生编辑同步到侧栏🙂", replacementRange: topEditor.selectedRange())
            await settle()
            check(sidebarEditor.string == "顶部原生编辑同步到侧栏🙂",
                  "two mounted editors synchronize workspace input to sidebar")
            sidebarEditor.selectAll(nil)
            sidebarEditor.insertText("侧栏原生编辑同步到顶部🙂", replacementRange: sidebarEditor.selectedRange())
            await settle()
            check(topEditor.string == "侧栏原生编辑同步到顶部🙂",
                  "two mounted editors synchronize sidebar input to workspace")
        } else {
            check(false, "both shared views mount their own native editor")
        }
        sidebarWindow.close()
        window.makeKeyAndOrderFront(nil)
        sessions.edit.send(text: "验证完成后完整同步", config: AgentConfig(), enabledSkills: [])
        await wait { !sessions.edit.isRunning }
        check(sessions.edit.messages.last?.content == "共享的完整回答🙂"
              && index.selectedModel.messages == sessions.edit.messages && backend.calls == 2,
              "completed response reaches shared transcript once")
        if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(
                to: directory.appendingPathComponent("session-sync-unified.png"))
        }
        window.close()
        let currentSidebar = sessions.sidebarSession(canvas: canvas, store: store)
        let pair = NSHostingView(rootView: HStack(spacing: 0) {
            AgentSidebarView(model: currentSidebar, isVisible: .constant(true), workspaceMode: .edit)
            AgentSidebarView(model: sessions.sidebarSession(canvas: canvas, store: store),
                             isVisible: .constant(true), workspaceMode: .canvas)
        })
        let pairWindow = NSWindow(contentRect: NSRect(x: 80, y: 60, width: 1000, height: 720),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        pairWindow.isReleasedWhenClosed = false
        pairWindow.contentView = pair
        pairWindow.makeKeyAndOrderFront(nil)
        await settle()
        let pairEditors = editors(pair)
        if pairEditors.count == 2 {
            pairEditors[0].selectAll(nil)
            pairEditors[0].insertText("编辑侧栏同步到画布🙂", replacementRange: pairEditors[0].selectedRange())
            await settle()
            check(pairEditors[1].string == "编辑侧栏同步到画布🙂",
                  "native edit sidebar input synchronizes into canvas sidebar")
            pairEditors[1].selectAll(nil)
            pairEditors[1].insertText("画布侧栏同步到编辑🙂", replacementRange: pairEditors[1].selectedRange())
            await settle()
            check(pairEditors[0].string == "画布侧栏同步到编辑🙂" && currentSidebar.draft == pairEditors[0].string,
                  "native canvas sidebar input synchronizes into edit sidebar")
        } else { check(false, "both project sidebars mount native editors") }
        pairWindow.close()
        await runSharedSidebarToolProbe(check: check)
        canvas.switchProject(to: originalProject)
    } catch {
        check(false, "session sync probe exception: \(error.localizedDescription)")
    }
}

private final class SessionSyncFixtureBackend: AgentBackend, @unchecked Sendable {
    private(set) var calls = 0
    private(set) var cancelled = false
    private(set) var toolNames: Set<String> = []
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        calls += 1
        toolNames = Set(tools?.specs().map(\.name) ?? [])
        await onEvent(.contentDelta("共享的流式回答🙂"))
        do {
            try await Task.sleep(for: .seconds(3))
            let reply = AgentMessage(role: .assistant, content: "共享的完整回答🙂")
            await onEvent(.assistantCompleted(reply))
            return [reply]
        } catch {
            cancelled = true
            throw error
        }
    }
}

@MainActor
private func runSharedSidebarToolProbe(check: (Bool, String) -> Void) async {
    let library = SharedSidebarLibraryFixture()
    var active = true
    var approvals = 0
    let tools = AgentSharedSidebarTools(canvas: AgentPreviewTools(), library: library,
        pageID: "page-A", groupID: "group-A", automaticApproval: false,
        isCurrent: { active }, onInteraction: { interaction in
            await MainActor.run { approvals += 1 }
            _ = try? await interaction.respond(["decision": "accept"])
        })
    let read = await tools.execute(call: .init(id: "read-shared", name: "read_slot", argumentsJSON: #"{"slot":3}"#))
    check(!read.isFailure && library.lastInput?["group"] == .string("group-A")
        && library.lastInput?["page"] == .string("page-A") && approvals == 0,
        "library reads use submitted group defaults without approval")
    let write = await tools.execute(call: .init(id: "write-shared", name: "write_slot",
        argumentsJSON: #"{"slot":3,"text":"同步正文"}"#))
    check(!write.isFailure && library.writes == 1 && approvals == 1,
          "shared library write passes the existing approval policy once")
    let pageList = await tools.execute(call: .init(id: "list-page", name: "list_slots",
        argumentsJSON: #"{"page":"explicit-page"}"#))
    check(!pageList.isFailure && library.lastInput?["page"] == .string("explicit-page")
        && library.lastInput?["group"] == nil, "explicit page listing retains all-group semantics")
    _ = await tools.execute(call: .init(id: "read-explicit-page", name: "read_slot",
        argumentsJSON: #"{"page":"explicit-page","slot":3}"#))
    check(library.lastInput?["page"] == .string("explicit-page") && library.lastInput?["group"] == nil,
          "explicit page reads cannot inherit the other page's default group")
    _ = await tools.execute(call: .init(id: "read-explicit-group", name: "read_slot",
        argumentsJSON: #"{"group":"explicit-group","slot":3}"#))
    check(library.lastInput?["group"] == .string("explicit-group") && library.lastInput?["page"] == nil,
          "explicit group reads retain their own page resolution")
    active = false
    let stale = await tools.execute(call: .init(id: "stale-shared", name: "write_slot",
        argumentsJSON: #"{"slot":3,"text":"不得写入"}"#))
    check(stale.isFailure && library.writes == 1 && approvals == 1,
          "leaving shared project prevents library writes and approvals")
    active = true
    let declinedTools = AgentSharedSidebarTools(canvas: AgentPreviewTools(), library: library,
        pageID: "page-A", groupID: "group-A", automaticApproval: false,
        isCurrent: { active }, onInteraction: { interaction in
            _ = try? await interaction.respond(["decision": "decline"])
        })
    let decline = await declinedTools.execute(call: .init(id: "decline-shared", name: "write_slot",
        argumentsJSON: #"{"slot":3,"text":"拒绝后不写入"}"#))
    check(decline.isFailure && library.writes == 1, "declining in shared sidebar leaves library unchanged")
    let switchedTools = AgentSharedSidebarTools(canvas: AgentPreviewTools(), library: library,
        pageID: "page-A", groupID: "group-A", automaticApproval: false,
        isCurrent: { active }, onInteraction: { interaction in
            await MainActor.run { active = false }
            _ = try? await interaction.respond(["decision": "accept"])
        })
    let switched = await switchedTools.execute(call: .init(id: "switch-shared", name: "write_slot",
        argumentsJSON: #"{"slot":3,"text":"批准期间切项目"}"#))
    check(switched.isFailure && library.writes == 1, "approval cannot retarget a call after project switch")
    active = true
    let readonly = AgentSharedSidebarTools(canvas: AgentPreviewTools(),
        library: AgentAccessTools(base: library, mode: .allDirectoriesReadOnly),
        pageID: "page-A", groupID: "group-A", automaticApproval: true,
        isCurrent: { active }, onInteraction: { _ in })
    let denied = await readonly.execute(call: .init(id: "readonly-shared", name: "write_slot",
        argumentsJSON: #"{"slot":3,"text":"只读"}"#))
    check(denied.isFailure && !readonly.specs().contains { $0.name == "write_slot" }
        && library.writes == 1, "shared schema and executor both enforce read-only library access")
    check(!tools.permitsCLI("write") && !tools.permitsCLI("clear")
        && tools.permitsCLI("version"), "local CLI cannot bypass shared approval and target binding")
    let suite = UserDefaults(suiteName: "round24-visibility-\(UUID())")!
    suite.set(true, forKey: AgentPreferences.editSidebarVisibleKey)
    AgentPreferences.migrateSidebarVisibility(defaults: suite)
    suite.set(false, forKey: AgentPreferences.sharedSidebarVisibleKey)
    AgentPreferences.migrateSidebarVisibility(defaults: suite)
    check(!suite.bool(forKey: AgentPreferences.sharedSidebarVisibleKey),
          "shared visibility migration runs once and preserves later close choices")
}

private final class SharedSidebarLibraryFixture: AgentToolExecuting {
    var writes = 0
    var lastInput: JSONValue?
    func specs() -> [AgentToolSpec] {
        AgentBuiltinTools().specs().filter { ["read_slot", "list_slots", "write_slot"].contains($0.name) }
    }
    func execute(call: AgentToolCall) async -> AgentToolResult {
        lastInput = try? JSONValue.decode(jsonText: call.argumentsJSON)
        if call.name == "write_slot" { writes += 1 }
        return .init(content: #"{"ok":true}"#, summary: "共享工具测试")
    }
}
#endif
