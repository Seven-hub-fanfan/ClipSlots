#if DEBUG
import AppKit
import ClipSlotsKit

private actor TaskSubagentProbeBackend: AgentBackend {
    private var callback: (@Sendable (AgentRunEvent) async -> Void)?
    private var readyWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    func ready() async {
        if callback != nil { return }
        await withCheckedContinuation { readyWaiter = $0 }
    }
    func emit(_ event: AgentRunEvent) async { await callback?(event) }
    func finish() { completion?.resume(); completion = nil }
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        callback = onEvent
        await withCheckedContinuation { continuation in
            completion = continuation
            readyWaiter?.resume(); readyWaiter = nil
        }
        return history
    }
}

@MainActor
func runTaskSubagentRegression(directory: URL) async -> [String: Any] {
    _ = NSApplication.shared
    var checks: [String] = [], failures: [String] = []
    func check(_ value: Bool, _ name: String) {
        print("\(value ? "PASS" : "FAIL"): \(name)")
        if value { checks.append(name) } else { failures.append(name) }
    }
    func children(_ model: AgentChatModel) -> [AgentSubagentState] {
        model.taskSubagents.entries.compactMap { entry in
            if case .subagent(let state) = entry.content { return state }; return nil
        }
    }
    let file = directory.appendingPathComponent("task-session.json")
    do {
        if ProcessInfo.processInfo.environment["CLIPSLOTS_SUBAGENT_VERIFY_RESTART"] == "1" {
            let saved = try JSONDecoder().decode(AgentChatModel.SavedSessions.self, from: Data(contentsOf: file))
            let model = AgentChatModel(displayName: "Task restart", backend: TaskSubagentProbeBackend(), persistenceURL: file)
            check(model.taskSubagents == saved.current.taskSubagents, "native separate process restores complete task projection")
            check(children(model).map(\.status) == [.stopped, .endedUnknown],
                  "native separate process preserves stopped and unknown child outcomes")
            check(model.transcript.filter { if case .taskSubagent = $0.kind { return true }; return false }.count == 3,
                  "native separate process restores task and both child transcript cards")
            check(model.messages.contains { $0.content == "前🙂中e\u{301}后" },
                  "native separate process restores original parent body bytes")
        } else {
            let backend = TaskSubagentProbeBackend()
            let model = AgentChatModel(displayName: "Task regression", backend: backend, persistenceURL: file)
            let config = AgentConfig(model: "fixture")
            check(model.send(text: "synthetic task projection", config: config, enabledSkills: []),
                  "native task starts actual AgentChatModel session")
            await backend.ready()
            await backend.emit(.runState(phase: "streaming", runID: "task-run", cursor: "initial"))
            await backend.emit(.contentDelta("前🙂"))
            let plan = try AgentTaskPlanSnapshot(validating: ["schema_version": "agent_task_snapshot.v1",
                "plan_ready": false, "tasks": [["task_id": "one", "subject": "分析画布", "status": "pending"]]])
            await backend.emit(.taskSnapshot(plan, eventID: "plan|1"))
            check(model.streamingContent == "前🙂", "native task snapshot flushes buffered parent text")
            await backend.emit(.contentDelta("中e\u{301}"))
            let ready = try AgentTaskPlanSnapshot(validating: ["schema_version": "agent_task_snapshot.v1",
                "plan_ready": true, "tasks": [["task_id": "one", "subject": "分析画布", "status": "in_progress"]]])
            await backend.emit(.taskSnapshot(ready, eventID: "plan|2"))
            check(model.taskSubagents.entries.count == 1, "native task replaces snapshot in place")
            check(model.taskSubagents.entries.first?.anchor?.contentBytes == "前🙂".utf8.count,
                  "native plan update retains first display anchor")
            func child(_ phase: String, parent: String = "parent-one", text: String? = nil,
                       tool: JSONValue? = nil) -> JSONValue {
                var value: [String: JSONValue] = ["schema_version": "subagent_event.v1", "subagent_id": "child",
                    "phase": .string(phase), "parent_tool_call_id": .string(parent),
                    "agent_type": "分析子任务", "task_description": "检查引用与连线"]
                if let text { value["text"] = .string(text) }
                if let tool { value["tool_event"] = tool }
                return .object(value)
            }
            await backend.emit(.subagentEvent(child("started"), eventID: "child|1"))
            let start: JSONValue = ["schema_version": "tool_event.v1", "type": "tool_event", "tool": "Read",
                "tool_call_id": "read", "status": "started", "request": ["path": "synthetic"], "response": .null]
            let done: JSONValue = ["schema_version": "tool_event.v1", "type": "tool_event", "tool": "Read",
                "tool_call_id": "read", "status": "completed", "request": .object([:]), "response": "已读取"]
            await backend.emit(.subagentEvent(child("content", text: "分析🙂"), eventID: "child|2"))
            await backend.emit(.subagentEvent(child("tool_started", tool: start), eventID: "child|3"))
            await backend.emit(.subagentEvent(child("tool_completed", tool: done), eventID: "child|4"))
            await backend.emit(.subagentEvent(child("tool_completed", tool: done), eventID: "child|4"))
            await backend.emit(.subagentEvent(child("tool_started", tool: start), eventID: "late-tool|5"))
            await backend.emit(.subagentEvent(child("content", text: "重复"), eventID: "repeat|2"))
            check(children(model).first?.text == "分析🙂", "native child repeated content not appended")
            check(children(model).first?.tools.count == 1
                  && children(model).first?.tools[0]["request"] == ["path": "synthetic"]
                  && children(model).first?.tools[0]["status"] == "completed",
                  "native child tools preserve original request and terminal result")
            check(children(model).first?.timeline == [.text("分析🙂"), .tool("read")],
                  "native child text and tool timeline has no repeated entries")
            await backend.emit(.subagentEvent(child("stopped"), eventID: "child|6"))
            await backend.emit(.subagentEvent(child("progress"), eventID: "child|7"))
            check(children(model).first?.status == .stopped, "native progress cannot reopen stopped child")
            await backend.emit(.subagentEvent(child("started", parent: "parent-two"), eventID: "child|8"))
            await backend.emit(.subagentEvent(child("started"), eventID: "old-start|9"))
            await backend.emit(.subagentEvent(child("content", text: "旧实例"), eventID: "old-content|10"))
            check(children(model).count == 2 && children(model).last?.parentToolCallID == "parent-two"
                  && children(model).last?.text == "", "native parent successor rejects old parent start and content")
            await backend.emit(.contentDelta("后"))
            let message = AgentMessage(role: .assistant, content: "前🙂中e\u{301}后")
            await backend.emit(.assistantCompleted(message))
            let transcript = model.transcript
            check(transcript.filter { if case .taskSubagent = $0.kind { return true }; return false }.count == 3,
                  "native completed assistant contains plan and both child cards")
            check(model.taskSubagents.entries.allSatisfy { $0.anchor?.messageID == message.id },
                  "native task cards bind to actual completed assistant identity")
            let body = transcript.compactMap { item -> String? in
                if case .assistant(let text, _, _) = item.kind { return text }; return nil
            }.joined()
            check(Data(body.utf8) == Data(message.content.utf8), "native task segmentation keeps complete original parent bytes")
            let labels = transcript.compactMap { item -> String? in
                switch item.kind {
                case .assistant(let text, _, _): return text
                case .taskSubagent(let entry):
                    if case .tasks = entry.content { return "plan" }; return "child"
                default: return nil
                }
            }
            check(labels == ["前🙂", "plan", "中e\u{301}", "child", "child", "后"],
                  "native mixed text and task cards retain receipt order")
            await backend.finish()
            let deadline = Date().addingTimeInterval(2)
            while model.isRunning && Date() < deadline { await Task.yield() }
            check(!model.isRunning && children(model).last?.status == .endedUnknown,
                  "native parent completion leaves unfinished child outcome unknown")
            check(model.flushSession(), "native full task session saved atomically")
            let saved = try JSONDecoder().decode(AgentChatModel.SavedSessions.self, from: Data(contentsOf: file))
            check(saved.current.taskSubagents == model.taskSubagents, "native persisted task projection matches live state")
            let forkFile = directory.appendingPathComponent("fork-session.json")
            try Data(contentsOf: file).write(to: forkFile)
            let forked = AgentChatModel(displayName: "Task fork", backend: TaskSubagentProbeBackend(), persistenceURL: forkFile)
            forked.forkConversation(through: forked.messages.first?.id)
            check(forked.taskSubagents.entries.isEmpty, "native fork before assistant drops future task cards")
            let restoredFile = directory.appendingPathComponent("task-reopen-session.json")
            try Data(contentsOf: file).write(to: restoredFile)
            let restored = AgentChatModel(displayName: "Task restored", backend: TaskSubagentProbeBackend(), persistenceURL: restoredFile)
            check(restored.taskSubagents == model.taskSubagents, "native reopened session preserves exact task and tool metadata")
            restored.clearHistory()
            await backend.emit(.subagentEvent(child("completed", parent: "parent-two"), eventID: "late|100"))
            check(restored.taskSubagents.entries.isEmpty, "native cleared conversation has no old task projection")
            let interruptedBackend = TaskSubagentProbeBackend()
            let interruptedFile = directory.appendingPathComponent("interrupted-task-session.json")
            let interrupted = AgentChatModel(displayName: "Task interruption", backend: interruptedBackend, persistenceURL: interruptedFile)
            _ = interrupted.send(text: "synthetic interrupted task", config: config, enabledSkills: [])
            await interruptedBackend.ready()
            await interruptedBackend.emit(.contentDelta("中断正文"))
            await interruptedBackend.emit(.subagentEvent(child("started"), eventID: "child|1"))
            check(interrupted.flushSession(), "native in-flight task is saved before recovery")
            let recovered = AgentChatModel(displayName: "Task recovered", backend: TaskSubagentProbeBackend(), persistenceURL: interruptedFile)
            check(children(recovered).first?.status == .endedUnknown && recovered.runPhase == .unknown,
                  "native interrupted recovery never reports child success")
            check(recovered.taskSubagents.entries.first?.anchor?.messageID == recovered.messages.last?.id,
                  "native interrupted local task attaches to recovered partial body")
            interrupted.clearHistory()
            await interruptedBackend.emit(.subagentEvent(child("completed"), eventID: "late|99"))
            check(interrupted.taskSubagents.entries.isEmpty, "native old callback cannot enter new conversation")
            await interruptedBackend.finish()
        }
    } catch { check(false, "native task unexpected error \(error)") }
    check(NSApplication.shared.windows.isEmpty, "headless task regression opened no AppKit windows")
    return ["passed": checks.count, "checks": checks, "failures": failures,
            "gui": false, "remote": false, "providerRequests": 0]
}
#endif
