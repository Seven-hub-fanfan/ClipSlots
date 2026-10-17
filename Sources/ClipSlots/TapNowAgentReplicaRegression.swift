#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runTapNowAgentReplicaProbe(directory: URL, check: (Bool, String) -> Void) async {
    func wait(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    let historyURL = directory.appendingPathComponent("replica-agent-session.json")
    let backend = ReplicaReplyBackend()
    let model = AgentChatModel(displayName: "REA fixture", backend: backend, persistenceURL: historyURL)
    var firstConfig = AgentConfig(model: "first-model")
    firstConfig.thinkingMode = .disabled
    check(model.send(text: "第一条", config: firstConfig, enabledSkills: []), "Agent starts the first submission")
    let originalID = model.selectedConversationID
    model.draftSkillReferences = [.init(name: "固定引用", path: "/fixture/SKILL.md", markdown: "快照原文")]
    check(model.send(text: "第二条", config: AgentConfig(model: "second-model"), enabledSkills: []),
          "busy Agent accepts a queued submission")
    check(model.send(text: "第三条", config: AgentConfig(model: "third-model"), enabledSkills: []),
          "multiple queued submissions retain separate snapshots")
    check(model.queuedSubmissions.count == 2 && model.queuedSubmissions.first?.skillReferences.first?.markdown == "快照原文"
          && model.messages.filter { $0.role == .user }.count == 1,
          "queue snapshots never appear as sent messages before dispatch")
    if let last = model.queuedSubmissions.last {
        model.moveQueuedSubmission(last.id, by: -1)
        model.editQueuedSubmission(last.id, text: "第三条已编辑")
    }
    await wait { backend.calls.count == 3 && !model.isRunning }
    check(backend.calls.map { $0.text } == ["第一条", "第三条已编辑", "第二条"],
          "queue edit and reorder determine actual backend invocation order")
    check(backend.calls.map { $0.model } == ["first-model", "third-model", "second-model"],
          "queued model preferences stay frozen across later changes")
    check(model.queuedSubmissions.isEmpty && model.runPhase == .applied,
          "normal completion drains the queue exactly once")
    check(model.messages.filter { $0.role == .assistant && !$0.isFailure }.count == 3,
          "repeated assistant completion events merge by message identity")
    model.renameConversation(originalID, title: "镜头设计会话")
    check(model.currentConversationTitle == "镜头设计会话" && model.flushSession(),
          "session rename persists without altering messages")
    let saved = try? JSONDecoder().decode(AgentChatModel.SavedSessions.self, from: Data(contentsOf: historyURL))
    check(saved?.current.customTitle == "镜头设计会话" && saved?.current.run?.phase == .applied,
          "saved history includes title and terminal run phase")
    let assistantID = model.messages.first { $0.role == .assistant && !$0.isFailure }?.id
    model.forkConversation(through: assistantID)
    check(model.selectedConversationID != originalID && model.snapshot.forkSourceID == originalID
          && model.messages.count == 2 && model.recentConversations.contains { $0.id == originalID },
          "fork preserves original history and copies only the requested prefix")
    model.deleteConversation(model.selectedConversationID)
    check(model.selectedConversationID == originalID && model.messages.count == 6 && model.recentConversations.isEmpty,
          "deleting current conversation restores its predecessor without resurrecting deleted history")
    model.deleteConversation(originalID)
    check(model.recentConversations.isEmpty && model.selectedConversationID == originalID
          && model.messages.isEmpty && model.snapshot.run == nil && model.gatewayRunID == nil && model.gatewayCursor == nil,
          "deleting the final conversation resets all state while retaining client identity")
    model.clearHistory()
    check(model.selectedConversationID == originalID, "new conversation reuses pristine session identity")
    model.draft = "保留草稿"
    model.clearHistory()
    let nextID = model.selectedConversationID
    check(nextID != originalID && model.recentConversations.contains { $0.id == originalID && $0.draft == "保留草稿" },
          "new conversation archives nonempty draft")
    model.draft = "第二份草稿"; model.clearHistory()
    let newestID = model.selectedConversationID
    model.openConversation(id: originalID)
    model.deleteConversation(originalID)
    check(model.selectedConversationID == nextID && model.draft == "第二份草稿",
          "deleting oldest active session selects next in persistent creation order")
    model.openConversation(id: newestID)
    model.deleteConversation(nextID)
    check(model.selectedConversationID == newestID && model.messages.isEmpty, "background deletion preserves active state")
    model.deleteConversation(newestID)
    let restoredFinal = AgentChatModel(displayName: "reloaded final", backend: ReplicaReplyBackend(), persistenceURL: historyURL)
    check(restoredFinal.selectedConversationID == newestID && restoredFinal.snapshot.run == nil,
          "same identity reset survives persistence and restart")

    let interruptedBackend = ReplicaReplyBackend(interrupted: true)
    let interrupted = AgentChatModel(displayName: "interrupted", backend: interruptedBackend,
        persistenceURL: directory.appendingPathComponent("replica-interrupted.json"))
    interrupted.send(text: "未确认运行", config: AgentConfig(), enabledSkills: [])
    interrupted.send(text: "保留下一条", config: AgentConfig(), enabledSkills: [])
    await wait { !interrupted.isRunning }
    check(interrupted.runPhase == .unknown && interrupted.queuedSubmissions.count == 1
          && interrupted.queuePauseReason != nil && interruptedBackend.calls.count == 1,
          "interrupted runs retain the queue and never auto-resubmit")
    check(interrupted.messages.contains { $0.content == "部分文字🙂" && $0.isFailure },
          "incomplete output remains visible and excluded from completed answers")
    interrupted.retryLast(config: AgentConfig(), enabledSkills: [])
    check(!interrupted.isRunning && interruptedBackend.calls.count == 1,
          "unknown outcomes cannot silently replay the previous request")
    let reopened = AgentChatModel(displayName: "restored", backend: ReplicaReplyBackend(),
        persistenceURL: directory.appendingPathComponent("replica-interrupted.json"))
    check(reopened.runPhase == .unknown && reopened.queuedSubmissions.count == 1 && reopened.queuePauseReason != nil,
          "restart restores unknown outcome and pauses queued submissions")

    let lateBackend = ReplicaReplyBackend()
    let late = AgentChatModel(displayName: "late events", backend: lateBackend)
    late.send(text: "旧会话", config: AgentConfig(), enabledSkills: [])
    late.clearHistory()
    let newID = late.selectedConversationID
    try? await Task.sleep(for: .milliseconds(250))
    check(late.selectedConversationID == newID && late.messages.isEmpty && !late.isRunning,
          "late completion from a cancelled epoch cannot contaminate a new conversation")
    let lateReset = AgentChatModel(displayName: "same identity reset", backend: ReplicaReplyBackend())
    let resetID = lateReset.selectedConversationID
    lateReset.send(text: "同 ID 重置", config: AgentConfig(), enabledSkills: [])
    lateReset.deleteConversation(resetID)
    try? await Task.sleep(for: .milliseconds(250))
    check(lateReset.selectedConversationID == resetID && lateReset.messages.isEmpty
          && !lateReset.isRunning && lateReset.gatewayRunID == nil && lateReset.snapshot.run == nil,
          "late completion cannot revive a deleted active session")

    let fixture = AgentChatModel(displayName: "面板验收", backend: ReplicaReplyBackend())
    fixture.draft = "保持画布布局，继续完善下一组镜头。"
    let host = NSHostingView(rootView: HStack(spacing: 0) {
        Color.black.frame(maxWidth: .infinity)
        AgentSidebarView(model: fixture, isVisible: .constant(true))
    })
    let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 1440, height: 800),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    try? await Task.sleep(for: .milliseconds(300))
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = bitmap.representation(using: .png, properties: [:])
        try? data?.write(to: directory.appendingPathComponent("agent-replica-panel.png"))
        check(data != nil, "resizable Agent panel renders in the real native host")
    } else { check(false, "native Agent panel screenshot") }
    window.close()
}

private final class ReplicaReplyBackend: AgentBackend, @unchecked Sendable {
    struct Call { let text: String; let model: String }
    private let lock = NSLock()
    private var records: [Call] = []
    private let interrupted: Bool
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return records }
    init(interrupted: Bool = false) { self.interrupted = interrupted }
    private func record(_ history: [AgentMessage], _ config: AgentConfig) {
        lock.lock(); defer { lock.unlock() }
        records.append(Call(text: history.last { $0.role == .user }?.content ?? "", model: config.model))
    }
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        record(history, config)
        await onEvent(.contentDelta("部分文字🙂"))
        try? await Task.sleep(for: .milliseconds(150))
        if interrupted { throw AgentError.interrupted("fixture disconnect") }
        let reply = AgentMessage(role: .assistant, content: "已完成🙂")
        await onEvent(.assistantCompleted(reply))
        await onEvent(.assistantCompleted(reply))
        return [reply]
    }
}
#endif
