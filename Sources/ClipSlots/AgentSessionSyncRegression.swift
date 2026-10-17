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
        projectModel.draft = "项目 A 草稿"
        let projectEntry = AgentConversationEntry(projectModel.snapshot, source: .project(projectA.id), current: true)
        check(index.open(projectEntry, canvas: canvas, store: store)
              && index.selectedModel === projectModel && index.readOnlyReason == nil,
              "active canvas history shares its project model")
        projectModel.setBackend(SessionSyncFixtureBackend(), kind: .deepseek)
        projectModel.send(text: "项目 A 快照", config: AgentConfig(), enabledSkills: [])
        await wait { projectModel.isRunning }
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
        canvas.switchProject(to: originalProject)
    } catch {
        check(false, "session sync probe exception: \(error.localizedDescription)")
    }
}

private final class SessionSyncFixtureBackend: AgentBackend, @unchecked Sendable {
    private(set) var calls = 0
    private(set) var cancelled = false
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        calls += 1
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
#endif
