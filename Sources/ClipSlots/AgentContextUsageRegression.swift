#if DEBUG
import AppKit
import ClipSlotsKit

private actor ContextUsageProbeBackend: AgentBackend {
    private var callback: (@Sendable (AgentRunEvent) async -> Void)?
    private var started: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    func ready() async {
        if callback != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func emit(_ event: AgentRunEvent) async { await callback?(event) }
    func finish() { completion?.resume(); completion = nil }
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        callback = onEvent
        await withCheckedContinuation { continuation in
            completion = continuation
            started?.resume(); started = nil
        }
        return history
    }
}

private struct ContextMetadataTransport: AgentGatewayTransport {
    let binding: AgentRunBinding
    let usage: AgentContextUsageSnapshot
    var taskPayload: JSONValue? = nil
    func send(request: URLRequest) async throws -> AgentGatewayHTTPResponse {
        let object: JSONValue = ["schemaVersion": 1,
            "binding": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(binding)),
            "runID": "context-run", "phase": "completed",
            "requestKey": request.value(forHTTPHeaderField: "Idempotency-Key").map(JSONValue.string) ?? .null]
        return .init(statusCode: 200, body: try JSONEncoder().encode(object))
    }
    func stream(request: URLRequest) async throws -> AgentHTTPStream {
        let bindingValue = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(binding))
        let message = UUID().uuidString
        var frames = Data()
        var events: [(String, String, JSONValue)] = [
            ("initial", "first", ["messageID": .string(message)]),
            ("context_usage", "usage", usage.wireValue)
        ]
        if let taskPayload { events.append(("subagent_event", "metadata-child|1", taskPayload)) }
        events.append(("run_completed", "done", ["messageID": .string(message)]))
        for (event, id, payload) in events {
            let value: JSONValue = ["schemaVersion": 1, "binding": bindingValue, "runID": "context-run",
                                   "eventID": .string(id), "payload": payload]
            frames += Data("event: \(event)\nid: \(id)\ndata: ".utf8)
            frames += try JSONEncoder().encode(value)
            frames += Data("\n\n".utf8)
        }
        return .init(statusCode: 200, chunks: AsyncThrowingStream {
            $0.yield(frames); $0.finish()
        })
    }
}

private actor ContextMetadataBackend: AgentGatewayResuming {
    let state: AgentGatewayRunSnapshot
    let hold: Bool
    private var snapshotWaiter: CheckedContinuation<AgentGatewayRunSnapshot, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var requested = false
    init(state: AgentGatewayRunSnapshot, hold: Bool = false) { self.state = state; self.hold = hold }
    var hasResumableRun: Bool { false }
    var snapshot: AgentGatewayRunSnapshot {
        get async {
            guard hold else { return state }
            return await withCheckedContinuation { continuation in
                snapshotWaiter = continuation; requested = true
                requestWaiter?.resume(); requestWaiter = nil
            }
        }
    }
    func waitForSnapshot() async {
        if requested { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }
    func release() { snapshotWaiter?.resume(returning: state); snapshotWaiter = nil }
    func cancelRun() async {}
    func waitUntilReadyToSteer() async throws -> Bool { false }
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        throw AgentGatewayError.invalidConfiguration
    }
    func resume(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
                onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        throw AgentGatewayError.invalidConfiguration
    }
}

/// Actual AgentChatModel reducer, saved sessions, restored display and stale
/// callback guards. No windows, keychain or model request.
@MainActor
func runContextUsageRegression(directory: URL) async -> [String: Any] {
    _ = NSApplication.shared
    var checks: [String] = [], failures: [String] = []
    func check(_ value: Bool, _ name: String) {
        (value ? print("PASS: \(name)") : print("FAIL: \(name)"))
        if value { checks.append(name) } else { failures.append(name) }
    }
    func observation(_ conversation: UUID, revision: Double, run: String = "context-run",
                     source: String = "sdk", percent: JSONValue = 200) throws -> AgentContextUsageSnapshot {
        try .init(validating: [
            "conversation_id": .string(conversation.uuidString), "run_id": .string(run),
            "runtime_session_id": .null, "revision": .number(revision), "used_tokens": 200, "max_tokens": 100,
            "percentage": percent, "model": "fixture", "source": .string(source), "status": "ready",
            "observed_at": "2026-10-29T02:00:00Z"
        ])
    }
    do {
        let backend = ContextUsageProbeBackend()
        let file = directory.appendingPathComponent("context-session.json")
        let model = AgentChatModel(displayName: "Context regression", backend: backend, persistenceURL: file)
        let conversation = model.selectedConversationID
        let config = AgentConfig(model: "fixture")
        check(model.send(text: "synthetic context test", config: config, enabledSkills: []),
              "native context starts injected run")
        await backend.ready()
        await backend.emit(.runState(phase: "streaming", runID: "context-run", cursor: nil))
        await backend.emit(.contextUsage(try observation(conversation, revision: 1)))
        let display = model.contextDisplay(model: "fixture", endpoint: config.endpoint)
        check(display?.percentage == 200 && display?.fraction == 1 && display?.statusLabel == "当前上下文",
              "native display preserves 200 percent with bounded ring")
        await backend.emit(.usage(.init(promptTokens: 20, completionTokens: 10, totalTokens: 30, cachedTokens: nil)))
        check(model.contextDisplay(model: "fixture", endpoint: config.endpoint)?.usedTokens == 200
              && model.reportedPromptTokens == 20, "native request billing never overwrites authoritative observation")
        await backend.emit(.contextUsage(try observation(conversation, revision: 0)))
        await backend.emit(.contextUsage(try observation(UUID(), revision: 90)))
        await backend.emit(.contextUsage(try observation(conversation, revision: 90, run: "old-run")))
        check(model.contextObservation.snapshot?.revision == 1, "native old revision conversation and run ignored")
        await backend.emit(.contextCompaction(phase: .started, eventID: "first"))
        await backend.emit(.contextCompaction(phase: .started, eventID: "duplicate"))
        check(model.contextCompactions.entries.count == 1 && model.contextObservation.stale,
              "native compact duplicate has one lifecycle and stale display")
        await backend.emit(.contextCompaction(phase: .finished, eventID: "finished"))
        check(model.contextDisplay(model: "fixture", endpoint: config.endpoint)?.statusLabel == "等待压缩后用量",
              "native finish waits for new authority")
        await backend.emit(.contextUsage(try observation(conversation, revision: 2)))
        check(!model.contextObservation.stale && model.contextObservation.compaction == .idle,
              "native post-compact ready makes display current")
        model.contextConfigurationChanged(model: "fixture", endpoint: config.endpoint)
        await backend.emit(.contextUsage(try observation(conversation, revision: 3)))
        model.contextConfigurationChanged(model: "another", endpoint: config.endpoint)
        check(model.contextObservation.stale && model.contextDisplay(model: "another", endpoint: config.endpoint) == nil,
              "native model change invalidates and hides mismatched observation")
        model.contextConfigurationChanged(model: "fixture", endpoint: config.endpoint)
        await backend.emit(.contextUsage(try observation(conversation, revision: 4)))
        await backend.emit(.toolCompleted(callId: "fixture", name: "fixture", result: .init(content: "synthetic", summary: "fixture")))
        check(model.contextObservation.stale, "native tool completion invalidates pending context")
        await backend.emit(.contextUsage(try observation(conversation, revision: 5, source: "last_request_usage", percent: .null)))
        check(model.contextObservation.snapshot?.revision == 5 && model.contextObservation.displaySnapshot?.revision == 4
              && model.contextDisplay(model: "fixture", endpoint: config.endpoint)?.statusLabel == "上次可靠观测",
              "native retains complete SDK display without calling it current")
        check(model.flushSession(), "native context saves projection to real temporary file")
        let saved = try JSONDecoder().decode(AgentChatModel.SavedSessions.self, from: Data(contentsOf: file))
        check(saved.current.contextObservation == model.contextObservation && saved.current.compactions == model.contextCompactions,
              "native saved observation and lifecycle preserve exact identities")
        let restored = AgentChatModel(displayName: "Restored context", backend: ContextUsageProbeBackend(), persistenceURL: file)
        check(restored.contextObservation.snapshot?.revision == 5 && restored.contextObservation.displaySnapshot?.revision == 4
              && restored.contextObservation.stale, "native interrupted restore keeps last reliable display stale")
        check(restored.contextDisplay(model: "fixture", endpoint: config.endpoint)?.percentage == 200,
              "native restore exposes original display percentage")
        func metadata(revision: Double, taskPayload: JSONValue? = nil) async throws -> AgentGatewayRunSnapshot {
            let gateway = AgentGatewayBackend(baseURL: URL(string: "https://context.fixture.invalid/v1")!,
                binding: .init(sessionID: conversation.uuidString),
                journalRoot: directory.appendingPathComponent("metadata-\(Int(revision))"),
                transport: ContextMetadataTransport(binding: .init(sessionID: conversation.uuidString),
                    usage: try observation(conversation, revision: revision), taskPayload: taskPayload))
            _ = try await gateway.run(history: [], config: config, tools: nil) { _ in }
            return await gateway.snapshot
        }
        let equal = ContextMetadataBackend(state: try await metadata(revision: 5))
        await backend.emit(.contextCompaction(phase: .started, eventID: "local-start"))
        await model.debugHydrateContextUsage(from: equal)
        check(model.contextObservation.compaction == .started && model.contextCompactions.entries.last?.phase == .started,
              "native equal-revision completed metadata cannot erase current compact state")
        let late = ContextMetadataBackend(state: try await metadata(revision: 20), hold: true)
        let hydration = Task { await model.debugHydrateContextUsage(from: late) }
        await late.waitForSnapshot()
        model.contextConfigurationChanged(model: "new-model", endpoint: config.endpoint)
        await late.release()
        await hydration.value
        check(model.contextObservation.snapshot?.revision == 5 && model.contextObservation.compaction == .started,
              "native higher-revision metadata requested before local invalidation is ignored")
        let child: JSONValue = ["schema_version": "subagent_event.v1", "subagent_id": "metadata-child",
            "parent_tool_call_id": "parent", "phase": "started"]
        await backend.emit(.subagentEvent(child, eventID: "metadata-child|1"))
        let taskMetadata = ContextMetadataBackend(state: try await metadata(revision: 40, taskPayload: child), hold: true)
        let taskHydration = Task { await model.debugHydrateContextUsage(from: taskMetadata) }
        await taskMetadata.waitForSnapshot()
        var stopped = child.objectValue!; stopped["phase"] = "stopped"
        await backend.emit(.subagentEvent(.object(stopped), eventID: "metadata-child|2"))
        await taskMetadata.release()
        await taskHydration.value
        if case .subagent(let state)? = model.taskSubagents.entries.first?.content {
            check(state.status == .stopped, "native late task metadata cannot overwrite newer local child terminal")
        } else { check(false, "native late task metadata cannot overwrite newer local child terminal") }
        let oldRunMetadata = ContextMetadataBackend(state: try await metadata(revision: 41, taskPayload: child), hold: true)
        let oldRunHydration = Task { await model.debugHydrateContextUsage(from: oldRunMetadata) }
        await oldRunMetadata.waitForSnapshot()
        await backend.emit(.runState(phase: "streaming", runID: "context-successor", cursor: "successor"))
        await oldRunMetadata.release()
        await oldRunHydration.value
        check(model.gatewayRunID == "context-successor" && model.gatewayCursor == "successor",
              "native metadata requested before remote run change cannot restore previous run")
        model.clearHistory()
        await backend.emit(.contextUsage(try observation(conversation, revision: 99)))
        await backend.emit(.contextCompaction(phase: .finished, eventID: "late"))
        check(model.contextObservation.snapshot == nil && model.contextCompactions.entries.isEmpty,
              "native old callback cannot cross cleared conversation")
        await backend.finish()
        restored.clearHistory()
        check(restored.contextObservation.snapshot == nil && restored.contextDisplay(model: "fixture", endpoint: config.endpoint) == nil,
              "native new conversation clears restored authority")

        let timelineBackend = ContextUsageProbeBackend()
        let timelineFile = directory.appendingPathComponent("compact-timeline.json")
        let timeline = AgentChatModel(displayName: "Compact timeline", backend: timelineBackend, persistenceURL: timelineFile)
        check(timeline.send(text: "synthetic compact lifecycle", config: config, enabledSkills: []),
              "native timeline starts actual session")
        await timelineBackend.ready()
        let initialUser = timeline.messages.first!.id
        func cards(_ items: [AgentChatModel.TranscriptItem]) -> [AgentContextCompactionLifecycle.Entry] {
            items.compactMap { item in if case .compaction(let entry) = item.kind { return entry }; return nil }
        }
        func bytes(_ items: [AgentChatModel.TranscriptItem], reasoning: Bool) -> Data {
            Data(items.compactMap { item -> String? in
                if case .assistant(let text, let thought, _) = item.kind { return reasoning ? (thought ?? "") : text }
                return nil
            }.joined().utf8)
        }
        await timelineBackend.emit(.reasoningDelta("思考🙂"))
        await timelineBackend.emit(.contentDelta("中e"))
        await timelineBackend.emit(.contextCompaction(phase: .started, eventID: "first"))
        check(!timeline.showsThinking && timeline.streamingContent == "中e" && timeline.streamingReasoning == "思考🙂",
              "native compact start flushes buffered deltas and ends live thinking")
        check(cards(timeline.streamingTranscript).count == 1 && cards(timeline.transcript).isEmpty,
              "native pending compact appears once inside stream")
        let cardIdentity = cards(timeline.streamingTranscript).first?.displayID
        await timelineBackend.emit(.contextCompaction(phase: .started, eventID: "same-lifecycle"))
        await timelineBackend.emit(.contextCompaction(phase: .finished, eventID: "finished"))
        check(timeline.showsThinking && cards(timeline.streamingTranscript).first?.displayID == cardIdentity
              && cards(timeline.streamingTranscript).first?.phase == .finished,
              "native compact finish resumes thinking and keeps card identity")
        await timelineBackend.emit(.contextCompaction(phase: .finished, eventID: "finished"))
        check(cards(timeline.streamingTranscript).count == 1, "native duplicate finish does not append or reopen")
        await timelineBackend.emit(.contentDelta("\u{301}后"))
        await timelineBackend.emit(.reasoningDelta("下一步"))
        await timelineBackend.emit(.contextCompaction(phase: .started, eventID: "second"))
        await timelineBackend.emit(.contextCompaction(phase: .finished, eventID: "second-finished"))
        check(bytes(timeline.streamingTranscript, reasoning: false) == Data("中e\u{301}后".utf8)
              && bytes(timeline.streamingTranscript, reasoning: true) == Data("思考🙂下一步".utf8),
              "native two compactions preserve content and reasoning bytes")
        let firstMessage = AgentMessage(role: .assistant, content: "中e\u{301}后", reasoning: "思考🙂下一步")
        await timelineBackend.emit(.assistantCompleted(firstMessage))
        check(cards(timeline.transcript).count == 2 && cards(timeline.streamingTranscript).isEmpty
              && timeline.contextCompactions.entries.allSatisfy { $0.anchor?.messageID == firstMessage.id },
              "native completion anchors both cards to exact assistant without duplicate stream")
        check(bytes(timeline.transcript, reasoning: false) == Data(firstMessage.content.utf8)
              && bytes(timeline.transcript, reasoning: true) == Data(firstMessage.reasoning!.utf8),
              "native completed transcript retains all original body bytes")
        check(timeline.transcript.compactMap(\.copyText) == [firstMessage.content],
              "native segmented reply offers one complete original answer for copy")
        await timelineBackend.emit(.toolStarted(.init(id: "synthetic-tool", name: "fixture", argumentsJSON: "{}")))
        await timelineBackend.emit(.toolCompleted(callId: "synthetic-tool", name: "fixture",
            result: .init(content: "synthetic tool result", summary: "fixture")))
        await timelineBackend.emit(.contextCompaction(phase: .started, eventID: "unfinished"))
        check(cards(timeline.streamingTranscript).count == 1 && !timeline.showsThinking,
              "native next assistant has independent pending compact")
        await timelineBackend.finish()
        await timeline.debugWaitForRunCompletion()
        check(!timeline.isRunning && !timeline.showsThinking && timeline.contextCompactions.entries.count == 2
              && cards(timeline.transcript).allSatisfy { $0.phase == .finished },
              "native terminal removes unfinished card and retains completed history")
        check(timeline.messages.first(where: { $0.id == firstMessage.id })?.content == firstMessage.content
              && timeline.messages.first(where: { $0.id == firstMessage.id })?.reasoning == firstMessage.reasoning,
              "native compact projection does not change request history")
        let restartedBackend = ContextUsageProbeBackend()
        let restarted = AgentChatModel(displayName: "Timeline restored", backend: restartedBackend, persistenceURL: timelineFile)
        check(cards(restarted.transcript).map(\.displayID) == cards(timeline.transcript).map(\.displayID),
              "native completed card identities and positions survive session file reopen")
        check(restarted.send(text: "synthetic second run", config: config, enabledSkills: []),
              "native reopened session starts next run")
        await restartedBackend.ready()
        await restartedBackend.emit(.contextCompaction(phase: .started, eventID: "first"))
        await restartedBackend.emit(.contextCompaction(phase: .finished, eventID: "finished"))
        let secondMessage = AgentMessage(role: .assistant, content: "第二轮")
        await restartedBackend.emit(.assistantCompleted(secondMessage))
        await restartedBackend.finish()
        await restarted.debugWaitForRunCompletion()
        check(cards(restarted.transcript).count == 3
              && Set(cards(restarted.transcript).map(\.displayID)).count == 3,
              "native new run retains old history and namespaces repeated receipts")
        restarted.forkConversation(through: firstMessage.id)
        check(cards(restarted.transcript).count == 2 && !restarted.messages.contains { $0.id == secondMessage.id },
              "native fork trims future cards and keeps prefix anchors")
        restarted.forkConversation(through: initialUser)
        check(cards(restarted.transcript).isEmpty, "native fork before reply does not copy later compact cards")

        let interruptedBackend = ContextUsageProbeBackend()
        let interruptedFile = directory.appendingPathComponent("compact-interrupted.json")
        let interrupted = AgentChatModel(displayName: "Interrupted compact", backend: interruptedBackend,
                                         persistenceURL: interruptedFile)
        _ = interrupted.send(text: "synthetic crash snapshot", config: config, enabledSkills: [])
        await interruptedBackend.ready()
        await interruptedBackend.emit(.reasoningDelta("保留的思考"))
        await interruptedBackend.emit(.contextCompaction(phase: .started, eventID: "start"))
        await interruptedBackend.emit(.contextCompaction(phase: .finished, eventID: "finish"))
        check(interrupted.flushSession(), "native partial compact session writes crash recovery snapshot")
        let recoveredPartial = AgentChatModel(displayName: "Partial restored", backend: ContextUsageProbeBackend(),
                                              persistenceURL: interruptedFile)
        check(cards(recoveredPartial.transcript).count == 1
              && bytes(recoveredPartial.transcript, reasoning: true) == Data("保留的思考".utf8)
              && !recoveredPartial.showsThinking,
              "native crash restore anchors finished card to recovered partial without running spinner")
        interrupted.stop()
        await interruptedBackend.emit(.contextCompaction(phase: .finished, eventID: "late"))
        check(interrupted.contextCompactions.entries.count == 1 && !interrupted.showsThinking,
              "native stopped callback cannot add compact card or restart thinking")
        await interruptedBackend.finish()
    } catch { check(false, "native context regression \(type(of: error))") }
    check(NSApp.windows.isEmpty, "headless context regression opened no AppKit windows")
    return ["passed": checks.count, "checks": checks, "failures": failures, "gui": false, "remote": false,
            "providerRequests": 0, "scope": "Actual AgentChatModel with injected events and file persistence"]
}
#endif
