import Foundation
import Security
@testable import ClipSlotsKit

private let gatewayRoot = URL(string: "https://gateway.fixture.invalid/v1")!
private let gatewayBinding = AgentRunBinding(sessionID: "session", projectID: "project", canvasID: "canvas")
private let gatewayMessageID = "F2CADB49-AD93-4BAC-914F-7A4CCFA16A71"
private let gatewayRunID = "opaque/run+one"
private enum GatewayFixtureError: Error { case unexpectedRequest }

private func gatewayData(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func gatewayDescriptor(_ request: URLRequest, phase: String = "streaming",
                               binding: AgentRunBinding = gatewayBinding) throws -> AgentGatewayHTTPResponse {
    let bindingValue = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(binding))
    let key = request.value(forHTTPHeaderField: "Idempotency-Key") ??
        (request.url?.path.contains("/requests/") == true ? request.url?.lastPathComponent : nil)
    return try .init(statusCode: 200, body: gatewayData(.object([
        "schemaVersion": 1, "binding": bindingValue, "runID": .string(gatewayRunID),
        "phase": .string(phase), "requestKey": key.map(JSONValue.string) ?? .null
    ])))
}

private func gatewayFrame(_ event: String, _ id: String, _ payload: JSONValue,
                          binding: AgentRunBinding = gatewayBinding, runID: String = gatewayRunID,
                          envelopeID: String? = nil, version: Int = 1) throws -> Data {
    let bindingValue = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(binding))
    let data = try gatewayData(.object([
        "schemaVersion": .number(Double(version)), "binding": bindingValue,
        "runID": .string(runID), "eventID": .string(envelopeID ?? id), "payload": payload
    ]))
    return Data("event: \(event)\r\nid: \(id)\r\ndata: ".utf8) + data + Data("\r\n\r\n".utf8)
}

private func gatewayInitial(_ id: String = "start") throws -> Data {
    try gatewayFrame("initial", id, ["messageID": .string(gatewayMessageID)])
}
private func gatewayContent(_ text: String, id: String = "text") throws -> Data {
    try gatewayFrame("content", id, ["messageID": .string(gatewayMessageID), "delta": .string(text)])
}
private func gatewayDone(_ id: String = "done") throws -> Data {
    try gatewayFrame("run_completed", id, ["messageID": .string(gatewayMessageID)])
}
private func gatewayTool(_ target: String, expiry: Double = 4_000_000_000,
                         name: String = "fixture_tool", id: String = "tool-event") throws -> Data {
    try gatewayFrame("client_tool_request", id, [
        "executionID": "execution-one", "callID": "call-one", "name": .string(name),
        "argumentsJSON": #"{"text":"test"}"#, "targetClientInstanceID": .string(target),
        "expiresAt": .number(expiry)
    ])
}

private actor GatewayScript: AgentGatewayTransport {
    struct HTTP: Sendable {
        let method: String
        let suffix: String
        let action: @Sendable (URLRequest) async throws -> AgentGatewayHTTPResponse
    }
    struct SSE: Sendable {
        var status = 200
        let chunks: [Data]
        var failure: URLError.Code?
    }
    private var http: [HTTP]
    private var sse: [SSE]
    private(set) var requests: [URLRequest] = []
    private(set) var streams: [URLRequest] = []

    init(_ http: [HTTP], _ sse: [SSE] = []) { self.http = http; self.sse = sse }
    func enqueue(_ http: [HTTP], _ sse: [SSE]) { self.http += http; self.sse += sse }
    func send(request: URLRequest) async throws -> AgentGatewayHTTPResponse {
        requests.append(request)
        guard !http.isEmpty else { throw GatewayFixtureError.unexpectedRequest }
        let step = http.removeFirst()
        guard request.httpMethod == step.method,
              request.url?.absoluteString.hasSuffix(step.suffix) == true else {
            throw GatewayFixtureError.unexpectedRequest
        }
        return try await step.action(request)
    }
    func stream(request: URLRequest) async throws -> AgentHTTPStream {
        streams.append(request)
        guard !sse.isEmpty else { throw GatewayFixtureError.unexpectedRequest }
        let step = sse.removeFirst()
        return .init(statusCode: step.status, chunks: AsyncThrowingStream { continuation in
            for chunk in step.chunks { continuation.yield(chunk) }
            if let failure = step.failure { continuation.finish(throwing: URLError(failure)) }
            else { continuation.finish() }
        })
    }
    var remaining: Int { http.count + sse.count }
}

private func gatewayHTTP(_ method: String, _ suffix: String, phase: String = "streaming") -> GatewayScript.HTTP {
    .init(method: method, suffix: suffix, action: { try gatewayDescriptor($0, phase: phase) })
}
private func gatewayStatus(_ method: String, _ suffix: String, _ status: Int) -> GatewayScript.HTTP {
    .init(method: method, suffix: suffix, action: { _ in .init(statusCode: status) })
}
private let gatewayRunPath = "/runs/opaque%2Frun%2Bone"
private func gatewayQuery(_ phase: String = "streaming") -> GatewayScript.HTTP {
    gatewayHTTP("GET", gatewayRunPath, phase: phase)
}

private final class GatewayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 2_000_000_000)
    private var delays: [Double] = []
    let cancelSleep: Bool
    init(cancelSleep: Bool = false) { self.cancelSleep = cancelSleep }
    var now: Date { lock.withLock { date } }
    var sleeps: [Double] { lock.withLock { delays } }
    var timing: AgentGatewayTiming {
        .init(sleep: { [self] delay in
            try Task.checkCancellation()
            lock.withLock { delays.append(delay); date.addTimeInterval(delay) }
            if cancelSleep { throw CancellationError() }
        }, now: { [self] in now })
    }
}

private actor GatewayEvents {
    private(set) var content = ""
    private(set) var reasoning = ""
    private(set) var completed = 0
    private(set) var tools = 0
    private(set) var artifacts = 0
    private(set) var canvas = 0
    private(set) var notes: [String] = []
    private(set) var phases: [String] = []
    private(set) var interaction: AgentInteraction?
    func receive(_ event: AgentRunEvent) {
        switch event {
        case .contentDelta(let delta): content += delta
        case .reasoningDelta(let delta): reasoning += delta
        case .assistantCompleted: completed += 1
        case .toolStarted: tools += 1
        case .artifactUpdated: artifacts += 1
        case .canvasChanged: canvas += 1
        case .note(let note): notes.append(note)
        case .runState(let phase, _, _): phases.append(phase)
        case .interactionRequested(let value): interaction = value
        default: break
        }
    }
}

private final class GatewayTools: AgentToolExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var executions = 0
    var count: Int { lock.withLock { executions } }
    func specs() -> [AgentToolSpec] {
        [.init(name: "fixture_tool", description: "test",
               parameters: ["type": "object", "properties": [:]], originLabel: "test")]
    }
    func execute(call: AgentToolCall) async -> AgentToolResult {
        lock.withLock { executions += 1 }
        return .init(content: #"{"ok":true}"#, summary: "fixture completed")
    }
}

private final class GatewayAssertions: @unchecked Sendable {
    var values: [(Bool, String)] = []
    func check(_ result: Bool, _ name: String) { values.append((result, name)) }
    func error(_ expected: AgentGatewayError,
               _ body: () async throws -> Void, _ name: String) async {
        do { try await body(); check(false, name) }
        catch { check(error as? AgentGatewayError == expected, name) }
    }
}

private func gatewayCase(_ t: TestRunner, _ name: String,
                         _ body: @escaping @Sendable (GatewayAssertions, URL) async throws -> Void) {
    let values: [(Bool, String)] = smokeAwait {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gateway-test-\(UUID())")
        let checks = GatewayAssertions()
        defer { try? FileManager.default.removeItem(at: root) }
        do { try await body(checks, root) }
        catch { checks.check(false, "fixture failed: \(type(of: error))") }
        return checks.values
    }
    values.forEach { t.check($0.0, "GATEWAY \(name): \($0.1)") }
}

private func gatewayBackend(_ root: URL, _ transport: GatewayScript,
                            clock: GatewayClock = GatewayClock()) -> AgentGatewayBackend {
    .init(baseURL: gatewayRoot, binding: gatewayBinding, journalRoot: root,
          transport: transport, timing: clock.timing)
}

func runAgentRunGatewayTests(_ t: TestRunner) {
    gatewayCase(t, "UTF8 and metadata") { c, root in
        let mutation: JSONValue = [
            "project_id": "project", "conversation_id": "session", "run_id": .string(gatewayRunID),
            "mutation_id": "mutation", "changes": [], "added_edges": [], "removed_edges": []
        ]
        let bytes = try gatewayInitial() + gatewayContent("中文🙂") +
            gatewayFrame("thinking", "thought", ["messageID": .string(gatewayMessageID), "delta": "推理🧪"]) +
            gatewayFrame("artifact_updated", "artifact", ["artifactID": "artifact", "revision": 1]) +
            gatewayFrame("canvas_changed", "canvas", mutation) +
            gatewayFrame("note", "note", ["message": "fixture-secret"]) +
            gatewayFrame("future_type", "future", ["text": "fixture-secret"]) + gatewayDone()
        let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery()],
                                   [.init(chunks: bytes.map { Data([$0]) })])
        let backend = AgentGatewayBackend(baseURL: gatewayRoot, binding: gatewayBinding, journalRoot: root,
            apiKeyProvider: { "fixture-secret" }, transport: script, timing: GatewayClock().timing)
        var config = AgentConfig()
        config.endpoint = URL(string: "https://never-use.fixture.invalid/private?key=config-secret")!
        let events = GatewayEvents()
        let result = try await backend.run(history: [.init(role: .user, content: "hello")],
            config: config, tools: nil, onEvent: { await events.receive($0) })
        c.check(result.first?.content == "中文🙂", "bytewise UTF8 reconstructs Chinese and emoji")
        c.check(result.first?.reasoning == "推理🧪", "reasoning survives split scalar boundaries")
        c.check(await events.content == "中文🙂", "emitted deltas equal persisted content")
        c.check(await events.completed == 1, "completion emitted once")
        let canvasCount = await events.canvas
        c.check(await events.artifacts == 1 && canvasCount == 1, "metadata forwarded as proposal events")
        c.check(await events.notes.count == 2, "unknown event diagnostic only")
        c.check(await !events.notes.joined().contains("fixture-secret"), "remote diagnostics sanitized")
        c.check(await !backend.hasResumableRun, "explicit completion is terminal")
        let requests = await script.requests
        c.check(requests.allSatisfy { $0.url?.host == gatewayRoot.host }, "configured origin only")
        c.check(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret" },
                "credential provider used only for bound request headers")
        let body = String(data: requests[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        c.check(!body.contains("config-secret") && !body.contains("never-use"), "config endpoint and API key excluded")
        let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: root)
        let disk = try String(contentsOf: store.file, encoding: .utf8)
        c.check(!disk.contains("fixture-secret") && !disk.contains("config-secret"), "journal stores no transport secrets")
        c.check(try store.load().cursor == "done", "committed cursor is terminal event ID")
        let mode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
        c.check(mode?.intValue == 0o600, "journal has private file mode")
        let reopened = gatewayBackend(root, script)
        let snapshot = await reopened.snapshot
        c.check(snapshot.artifactUpdates.count == 1 && snapshot.canvasMutations == [mutation],
                "metadata survives restart without relying on callbacks")
        c.check(snapshot.currentAssistantID == nil && snapshot.completedAssistantIDs == [UUID(uuidString: gatewayMessageID)!],
                "snapshot distinguishes completed from partial assistants")
        c.check(await script.remaining == 0, "all scripted steps consumed")
    }

    gatewayCase(t, "lost start receipt") { c, root in
        let clock = GatewayClock()
        let lost = GatewayScript.HTTP(method: "POST", suffix: "/runs", action: { _ in
            throw URLError(.networkConnectionLost)
        })
        let receipt = GatewayScript.HTTP(method: "GET", suffix: "", action: { request in
            guard request.url?.path.contains("/requests/") == true else { throw GatewayFixtureError.unexpectedRequest }
            return try gatewayDescriptor(request)
        })
        let script = GatewayScript([lost, receipt, gatewayQuery()], [.init(chunks: [try gatewayInitial() + gatewayDone()])])
        let backend = gatewayBackend(root, script, clock: clock)
        _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
        let requests = await script.requests
        c.check(requests.filter { $0.httpMethod == "POST" }.count == 1, "receipt reconciliation never creates a second run")
        c.check(requests[1].url?.lastPathComponent == requests[0].value(forHTTPHeaderField: "Idempotency-Key"),
                "reconciles exact durable creation key")
        c.check(clock.sleeps == [5], "retry uses injected five-second first delay")
        c.check(await !backend.hasResumableRun, "reconciled run completes")
    }

    gatewayCase(t, "404 reconciliation repost") { c, root in
        let lost = GatewayScript.HTTP(method: "POST", suffix: "/runs", action: { _ in throw URLError(.timedOut) })
        let script = GatewayScript([lost, gatewayStatus("GET", "", 404), gatewayHTTP("POST", "/runs"), gatewayQuery()],
                                  [.init(chunks: [try gatewayInitial() + gatewayDone()])])
        _ = try await gatewayBackend(root, script).run(history: [], config: .init(), tools: nil, onEvent: { _ in })
        let posts = await script.requests.filter { $0.httpMethod == "POST" }
        c.check(posts.count == 2 && posts[0].httpBody == posts[1].httpBody, "repost uses identical durable command body")
        c.check(posts[0].value(forHTTPHeaderField: "Idempotency-Key") == posts[1].value(forHTTPHeaderField: "Idempotency-Key"),
                "404 is safe only with server-side idempotency")
    }

    gatewayCase(t, "restart before receipt") { c, root in
        let lost = GatewayScript.HTTP(method: "POST", suffix: "/runs", action: { _ in throw URLError(.networkConnectionLost) })
        let initialScript = GatewayScript([lost])
        let initial = gatewayBackend(root, initialScript, clock: GatewayClock(cancelSleep: true))
        do {
            _ = try await initial.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
            c.check(false, "cancelled retry must throw")
        } catch { c.check(error is CancellationError, "cancelled retry interrupts immediately") }
        c.check(await initial.hasResumableRun, "unknown creation remains durable")
        let oldKey = await initialScript.requests[0].value(forHTTPHeaderField: "Idempotency-Key")
        let script = GatewayScript([gatewayHTTP("GET", ""), gatewayQuery()],
                                  [.init(chunks: [try gatewayInitial() + gatewayContent("recovered") + gatewayDone()])])
        let restarted = gatewayBackend(root, script)
        c.check(await restarted.clientInstanceID == initial.clientInstanceID, "client targeting identity stable after restart")
        let messages = try await restarted.resume(history: [.init(role: .user, content: "must not resubmit")],
            config: .init(), tools: nil, onEvent: { _ in })
        let requests = await script.requests
        c.check(requests[0].url?.lastPathComponent == oldKey, "restart loads original request key")
        c.check(requests.allSatisfy { $0.httpMethod == "GET" }, "resume never posts new history")
        c.check(messages.first?.content == "recovered", "restart reconstructs accepted run")
    }

    gatewayCase(t, "replay text and cached tool result") { c, root in
        let tools = GatewayTools(), events = GatewayEvents()
        let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: root)
        let seed = try store.load()
        try store.save(seed)
        let start = try gatewayInitial(), text = try gatewayContent("once"), tool = try gatewayTool(seed.clientInstanceID)
        let lost = GatewayScript.HTTP(method: "POST", suffix: gatewayRunPath + "/tool-results", action: { _ in
            throw URLError(.networkConnectionLost)
        })
        let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery(), lost, gatewayQuery(),
            gatewayStatus("POST", gatewayRunPath + "/tool-results", 204)],
            [.init(chunks: [start + text + tool]),
             .init(chunks: [start + text + tool + (try gatewayContent(" twice", id: "next")) + (try gatewayDone())])])
        let messages = try await gatewayBackend(root, script).run(history: [], config: .init(), tools: tools,
            onEvent: { await events.receive($0) })
        let emittedTools = await events.tools, emittedContent = await events.content
        c.check(tools.count == 1 && emittedTools == 1, "replayed tool never repeats local work")
        c.check(messages.first?.content == "once twice" && emittedContent == "once twice",
                "replayed deltas never duplicate text")
        c.check(messages.filter { $0.role == .tool }.count == 1, "tool message cached once")
        let posts = await script.requests.filter { $0.url?.absoluteString.hasSuffix("/tool-results") == true }
        c.check(posts.count == 2 && posts[0].httpBody == posts[1].httpBody, "lost tool receipt resends same cached result")
        c.check(posts[0].value(forHTTPHeaderField: "Idempotency-Key") == posts[1].value(forHTTPHeaderField: "Idempotency-Key"),
                "tool result delivery has stable idempotency key")
        let streams = await script.streams
        c.check(streams[1].value(forHTTPHeaderField: "Last-Event-ID") == "tool-event", "cursor committed before side effects")
        c.check(streams[1].url?.query == "cursor=tool-event", "opaque cursor sent on reconnect")
        c.check(await script.remaining == 0, "script reconciled without extra calls")
    }

    gatewayCase(t, "EOF retry budget and restart") { c, root in
        let clock = GatewayClock(), events = GatewayEvents()
        let partial = try gatewayInitial() + gatewayContent("partial")
        let script = GatewayScript([gatewayHTTP("POST", "/runs")] + Array(repeating: gatewayQuery(), count: 9),
                                  Array(repeating: .init(chunks: [partial, Data("data: unfinished".utf8)]), count: 9))
        let backend = gatewayBackend(root, script, clock: clock)
        await c.error(.interrupted, {
            _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { await events.receive($0) })
        }, "EOF is never treated as done")
        c.check(clock.sleeps == (1...8).map { Double($0) * 5 }, "exactly eight cancellable linear retries")
        let completed = await events.completed, snapshot = await backend.snapshot
        c.check(await events.content == "partial" && completed == 0, "partial text preserved without fake completion")
        c.check(await backend.hasResumableRun && snapshot.phase == "unknown", "retry exhaustion stays resumable")
        c.check(snapshot.currentAssistantID == UUID(uuidString: gatewayMessageID) && snapshot.completedAssistantIDs.isEmpty,
                "snapshot marks partial assistant for host rehydration")
        await c.error(.resumableRunExists, {
            _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
        }, "new run cannot overwrite unknown outcome")
        let recovery = GatewayScript([gatewayQuery("completed")],
            [.init(chunks: [partial + (try gatewayContent(" recovered", id: "tail")) + (try gatewayDone())])])
        let restarted = gatewayBackend(root, recovery)
        let result = try await restarted.resume(history: [], config: .init(), tools: nil, onEvent: { _ in })
        c.check(result.first?.content == "partial recovered", "restart uses committed reconstructed text")
        c.check(result.first?.id.uuidString == gatewayMessageID, "restored assistant retains stable UUID")
        let streams = await recovery.streams
        c.check(streams[0].value(forHTTPHeaderField: "Last-Event-ID") == "text", "status completion cannot skip missing events")
        c.check(await !restarted.hasResumableRun, "terminal replay commits completion")
    }

    gatewayCase(t, "waiting question and durable continue") { c, root in
        let waiting = try gatewayFrame("waiting_question", "question", [
            "interactionID": "question-one", "expiresAt": 4_000_000_000,
            "params": ["questions": [["id": "q", "question": "Choose", "options": [["label": "yes"]]]]]
        ])
        let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery(), gatewayQuery("waiting_question"),
            gatewayHTTP("POST", gatewayRunPath + "/continue"), gatewayQuery()],
            [.init(chunks: [try gatewayInitial() + gatewayContent("choose") + waiting]),
             .init(chunks: [try gatewayContent(" chosen", id: "answer") + gatewayDone()])])
        let backend = gatewayBackend(root, script), events = GatewayEvents()
        _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { await events.receive($0) })
        let resumable = await backend.hasResumableRun
        c.check(await backend.snapshot.phase == "waiting_question" && resumable, "waiting is not completion")
        c.check(await events.completed == 0, "waiting does not finalize partial assistant")
        _ = try await backend.resume(history: [], config: .init(), tools: nil, onEvent: { await events.receive($0) })
        c.check(await script.streams.count == 1, "waiting resume returns pending interaction without opening duplicate stream")
        guard let interaction = await events.interaction else { throw GatewayFixtureError.unexpectedRequest }
        let answer: JSONValue = ["answers": ["q": ["answers": ["yes"]]]]
        let accepted = try await interaction.respond(answer)
        c.check(accepted, "valid user answer is durably queued")
        c.check(await script.requests.count == 3, "answer callback does not pretend remote delivery")
        c.check(!(try await interaction.respond(answer)), "double reply does not queue a second command")
        let restarted = gatewayBackend(root, script)
        let result = try await restarted.resume(history: [], config: .init(), tools: nil, onEvent: { _ in })
        c.check(result.first?.content == "choose chosen", "continue preserves prior partial text")
        let request = await script.requests[3]
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
        c.check(body["interactionID"] == "question-one" && body["answer"] == answer, "continue is distinct from creation")
        c.check(await !restarted.hasResumableRun, "continued run completes")
    }

    gatewayCase(t, "suspended waiting") { c, root in
        let suspended = try gatewayFrame("waiting_suspended", "suspend", [:])
        let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery(), gatewayQuery("waiting_suspended")],
                                  [.init(chunks: [try gatewayInitial() + suspended])])
        let backend = gatewayBackend(root, script)
        _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
        _ = try await backend.resume(history: [], config: .init(), tools: nil, onEvent: { _ in })
        c.check(await backend.snapshot.phase == "waiting_suspended", "suspended state survives status-only resume")
        c.check(await script.streams.count == 1, "suspended resume does not retry EOF")
    }

    gatewayCase(t, "suspended status is not replay acknowledgment") { c, root in
        let suspended = try gatewayFrame("waiting_suspended", "suspend", [:])
        let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery("waiting_suspended")],
                                  [.init(chunks: [try gatewayInitial() + gatewayContent("durable unseen text") + suspended])])
        let backend = gatewayBackend(root, script)
        let messages = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
        c.check(messages.first?.content == "durable unseen text", "replay text before suspended return")
        c.check(await backend.snapshot.cursor == "suspend", "only SSE commits suspended cursor")
    }

    gatewayCase(t, "opaque cursor plus is query encoded") { c, root in
        let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery(), gatewayQuery()],
            [.init(chunks: [try gatewayInitial() + gatewayContent("partial", id: "cursor/+opaque")]),
             .init(chunks: [try gatewayDone()])])
        let backend = gatewayBackend(root, script)
        _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
        let requests = await script.streams
        c.check(requests[1].value(forHTTPHeaderField: "Last-Event-ID") == "cursor/+opaque",
                "header preserves literal plus")
        c.check(requests[1].url?.absoluteString.contains("%2Bopaque") == true,
                "query prevents plus from becoming a space")
    }

    gatewayCase(t, "tool target expiry and authorization") { c, root in
        for mode in ["target", "expired", "unauthorized", "readonly", "limit"] {
            let localRoot = root.appendingPathComponent(mode)
            let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: localRoot)
            let seed = try store.load()
            try store.save(seed)
            let tools = GatewayTools()
            let frame = try gatewayTool(mode == "target" ? "another-client" : seed.clientInstanceID,
                expiry: mode == "expired" ? 1 : 4_000_000_000, name: mode == "unauthorized" ? "arbitrary_write" : "fixture_tool")
            var steps = [gatewayHTTP("POST", "/runs"), gatewayQuery()]
            if mode != "target" { steps.append(gatewayStatus("POST", gatewayRunPath + "/tool-results", 204)) }
            let script = GatewayScript(steps, [.init(chunks: [try gatewayInitial() + frame + gatewayDone()])])
            var config = AgentConfig()
            if mode == "readonly" { config.taskPolicy = .textPolish }
            if mode == "limit" { config.maxToolRounds = 0 }
            let messages = try await gatewayBackend(localRoot, script).run(
                history: [], config: config, tools: tools, onEvent: { _ in })
            c.check(tools.count == 0, "\(mode) never executes a local tool")
            if mode == "target" {
                c.check(messages.filter { $0.role == .tool }.isEmpty, "other client target never claims or delivers result")
            } else {
                c.check(messages.first(where: { $0.role == .tool })?.isFailure == true, "\(mode) delivers a typed rejection")
            }
            c.check(await script.remaining == 0, "\(mode) uses expected request sequence")
        }
    }

    gatewayCase(t, "tool crash window recovery") { c, root in
        for confirmed in [false, true] {
            let localRoot = root.appendingPathComponent(confirmed ? "confirmed" : "unknown")
            let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: localRoot)
            var seed = try store.load()
            let call = AgentToolCall(id: "call-one", name: "fixture_tool", argumentsJSON: #"{"text":"test"}"#)
            let scope = AgentExecutionScope(sessionID: gatewayBinding.sessionID, projectID: gatewayBinding.projectID, turnID: "original-turn")
            let hostJournal = AgentExecutionJournal(root: localRoot)
            guard case .execute(let reservation) = try hostJournal.reserve(scope: scope, call: call) else {
                throw GatewayFixtureError.unexpectedRequest
            }
            if confirmed { try hostJournal.complete(reservation, result: .init(content: "cached", summary: "cached")) }
            seed.runID = gatewayRunID; seed.phase = "unknown"
            seed.tools["execution-one"] = .init(request: .init(executionID: "execution-one", callID: call.id,
                name: call.name, argumentsJSON: call.argumentsJSON, targetClientInstanceID: seed.clientInstanceID,
                expiresAt: 4_000_000_000), phase: "executing")
            try store.save(seed)
            let base = GatewayTools()
            let wrapper = AgentGatewayRecoverableTools(base: base, journal: hostJournal, scope: scope)
            let script = GatewayScript(confirmed ? [gatewayQuery(), gatewayStatus("POST", gatewayRunPath + "/tool-results", 204)] : [gatewayQuery()],
                confirmed ? [.init(chunks: [try gatewayInitial() + gatewayDone()])] : [])
            let backend = gatewayBackend(localRoot, script)
            if confirmed {
                let messages = try await backend.resume(history: [], config: .init(), tools: wrapper, onEvent: { _ in })
                c.check(messages.first(where: { $0.role == .tool })?.content == "cached", "confirmed host result recovered")
                c.check(await !backend.hasResumableRun, "recovered result delivered and run completed")
            } else {
                await c.error(.toolOutcomeUnknown, {
                    _ = try await backend.resume(history: [], config: .init(), tools: wrapper, onEvent: { _ in })
                }, "unconfirmed host side effect remains blocked")
                c.check(await backend.hasResumableRun, "unknown tool preserves resumable run")
            }
            c.check(base.count == 0, "recovery never invokes base executor")
        }
    }

    gatewayCase(t, "cancel confirmation and steer readiness") { c, root in
        let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery(),
            gatewayStatus("POST", gatewayRunPath + "/cancel", 202), gatewayQuery(),
            gatewayStatus("POST", gatewayRunPath + "/cancel", 202), gatewayQuery(),
            gatewayQuery(), gatewayQuery("cancelled")], [.init(chunks: [try gatewayInitial()])])
        let backend = gatewayBackend(root, script, clock: GatewayClock(cancelSleep: true))
        do { _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { _ in }) }
        catch {}
        await backend.cancelRun()
        let resumable = await backend.hasResumableRun
        c.check(await backend.snapshot.phase == "unknown" && resumable, "cancel receipt cannot falsely confirm cancellation")
        // Use a restarted controller with a non-cancelling fixture clock.
        let clock = GatewayClock(), restarted = gatewayBackend(root, script, clock: clock)
        c.check(try await restarted.waitUntilReadyToSteer(), "steer waits for explicit remote cancellation")
        c.check(clock.sleeps == [0.5], "readiness polls at 500 ms")
        c.check(await !restarted.hasResumableRun, "confirmed cancellation releases run")
    }

    gatewayCase(t, "steer deadline and permanent failure") { c, root in
        for unauthorized in [false, true] {
            let localRoot = root.appendingPathComponent(unauthorized ? "unauthorized" : "deadline")
            let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: localRoot)
            var seed = try store.load(); seed.runID = gatewayRunID; seed.phase = "unknown"; try store.save(seed)
            let clock = GatewayClock()
            let polls = unauthorized ? [gatewayStatus("GET", gatewayRunPath, 401)] : Array(repeating: gatewayQuery(), count: 60)
            let script = GatewayScript([gatewayStatus("POST", gatewayRunPath + "/cancel", 202), gatewayQuery()] + polls)
            let backend = gatewayBackend(localRoot, script, clock: clock)
            await c.error(.steerNotReady, { _ = try await backend.waitUntilReadyToSteer() }, "unconfirmed readiness keeps queued submission")
            let snapshot = await backend.snapshot
            c.check(await backend.hasResumableRun && snapshot.phase == "unknown", "steer failure preserves unknown run")
            c.check(unauthorized ? clock.sleeps.isEmpty : clock.sleeps == Array(repeating: 0.5, count: 60),
                    unauthorized ? "permanent failure stops polling" : "polling stops at exactly 30 seconds")
            c.check(await script.remaining == 0, "bounded polling consumes exact scripted calls")
        }
    }

    gatewayCase(t, "slow cancel request deadline") { c, root in
        let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: root)
        var seed = try store.load(); seed.runID = gatewayRunID; seed.phase = "unknown"; try store.save(seed)
        let slow = GatewayScript.HTTP(method: "POST", suffix: gatewayRunPath + "/cancel", action: { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .init(statusCode: 202)
        })
        let script = GatewayScript([slow])
        let backend = AgentGatewayBackend(baseURL: gatewayRoot, binding: gatewayBinding, journalRoot: root,
            transport: script, timing: .init(controlTimeout: 0.03))
        let start = Date()
        await c.error(.steerNotReady, { _ = try await backend.waitUntilReadyToSteer() }, "deadline cancels cooperative hanging transport")
        c.check(Date().timeIntervalSince(start) < 1, "deadline covers cancel HTTP request, not only polling sleeps")
        c.check(await backend.hasResumableRun, "timeout does not report remote cancelled")
    }

    gatewayCase(t, "completed status must replay before steer") { c, root in
        let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: root)
        var seed = try store.load(); seed.runID = gatewayRunID; seed.phase = "unknown"; try store.save(seed)
        let script = GatewayScript([gatewayStatus("POST", gatewayRunPath + "/cancel", 202), gatewayQuery("completed"), gatewayQuery("completed")])
        let backend = gatewayBackend(root, script)
        await c.error(.steerNotReady, { _ = try await backend.waitUntilReadyToSteer() }, "status alone cannot discard missing final text")
        c.check(await backend.hasResumableRun, "caller must resume terminal events before replacing run")
    }

    gatewayCase(t, "permanent HTTP and schema validation") { c, root in
        for status in [400, 401, 403, 404, 409, 410, 422] {
            let script = GatewayScript([gatewayStatus("POST", "/runs", status)])
            let clock = GatewayClock(), backend = gatewayBackend(root.appendingPathComponent("http-\(status)"), script, clock: clock)
            await c.error(.http(status), {
                _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
            }, "HTTP \(status) is permanent")
            let resumable = await backend.hasResumableRun
            c.check(clock.sleeps.isEmpty && resumable, "permanent creation failure does not retry or discard command")
        }
        let malformed: [(String, Data, AgentGatewayError)] = [
            ("version", try gatewayFrame("initial", "bad", ["messageID": .string(gatewayMessageID)], version: 2), .malformedPayload),
            ("event-id", try gatewayFrame("initial", "bad", ["messageID": .string(gatewayMessageID)], envelopeID: "other"), .malformedPayload),
            ("binding", try gatewayFrame("initial", "bad", ["messageID": .string(gatewayMessageID)],
                binding: .init(sessionID: "other")), .originMismatch),
            ("run", try gatewayFrame("initial", "bad", ["messageID": .string(gatewayMessageID)], runID: "other"), .originMismatch),
            ("message", try gatewayFrame("initial", "bad", ["messageID": "not-uuid"]), .malformedPayload),
            ("delta", try gatewayInitial() + gatewayFrame("content", "bad", ["messageID": .string(gatewayMessageID), "delta": 7]), .malformedPayload),
            ("mutated-id", try gatewayInitial() + gatewayContent("first") + gatewayContent("changed"), .malformedPayload),
            ("canvas-origin", try gatewayInitial() + gatewayFrame("canvas_changed", "bad", [
                "project_id": "other", "conversation_id": "session", "run_id": .string(gatewayRunID),
                "mutation_id": "m", "changes": [], "added_edges": [], "removed_edges": []]), .originMismatch)
        ]
        for (name, bytes, expected) in malformed {
            let clock = GatewayClock()
            let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery()], [.init(chunks: [bytes])])
            let backend = gatewayBackend(root.appendingPathComponent(name), script, clock: clock)
            await c.error(expected, {
                _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
            }, "\(name) rejected")
            let resumable = await backend.hasResumableRun
            c.check(clock.sleeps.isEmpty && resumable, "\(name) stops without losing run")
        }
    }

    gatewayCase(t, "wrong request receipt") { c, root in
        let wrong = GatewayScript.HTTP(method: "POST", suffix: "/runs", action: { request in
            let response = try gatewayDescriptor(request)
            var value = try JSONDecoder().decode(JSONValue.self, from: response.body).objectValue ?? [:]
            value["requestKey"] = "another-command"
            return try .init(statusCode: 200, body: gatewayData(.object(value)))
        })
        let script = GatewayScript([wrong]), backend = gatewayBackend(root, script)
        await c.error(.originMismatch, {
            _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
        }, "create receipt must echo exact request key")
        let snapshot = await backend.snapshot
        c.check(await backend.hasResumableRun && snapshot.runID == nil, "wrong receipt never binds run")
    }

    gatewayCase(t, "corrupt journal locking and configuration") { c, root in
        let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: root)
        try store.save(store.load())
        let lock = try store.acquire()
        let script = GatewayScript([]), backend = gatewayBackend(root, script)
        await c.error(.busy, {
            _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
        }, "independent controller lock blocks stale creation")
        store.release(lock)
        try Data("corrupt".utf8).write(to: store.file)
        let restarted = gatewayBackend(root, script)
        c.check(await restarted.hasResumableRun, "corrupt journal conservatively blocks replacement")
        await c.error(.journalUnavailable, {
            _ = try await restarted.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
        }, "corrupt journal is never reset silently")
        c.check(try String(contentsOf: store.file, encoding: .utf8) == "corrupt", "corrupt evidence preserved")
        let other = AgentGatewayJournalStore(baseURL: URL(string: "https://other.fixture.invalid/v1")!,
            binding: gatewayBinding, root: root)
        c.check(other.file != store.file, "service origin participates in journal identity")
        for url in ["http://remote.fixture.invalid/v1", "https://user:pass@gateway.fixture.invalid", "https://gateway.fixture.invalid/?key=value"] {
            let invalid = AgentGatewayBackend(baseURL: URL(string: url)!, binding: gatewayBinding,
                journalRoot: root.appendingPathComponent(UUID().uuidString), transport: script)
            await c.error(.invalidConfiguration, {
                _ = try await invalid.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
            }, "unsafe gateway configuration rejected before transport")
        }
        c.check(await script.requests.isEmpty, "storage/config failures make no network calls")
    }

    gatewayCase(t, "metadata commit before interrupted callback") { c, root in
        let payloads: [(String, JSONValue)] = [
            ("artifact_updated", ["artifactID": "a", "revision": 1]),
            ("canvas_changed", ["project_id": "project", "conversation_id": "session",
                "run_id": .string(gatewayRunID), "mutation_id": "m", "changes": [], "added_edges": [], "removed_edges": []])
        ]
        for (name, payload) in payloads {
            let localRoot = root.appendingPathComponent(name)
            let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery()],
                [.init(chunks: [try gatewayInitial() + gatewayFrame(name, "metadata", payload)])])
            let backend = gatewayBackend(localRoot, script)
            do {
                _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { event in
                    switch event {
                    case .artifactUpdated, .canvasChanged: withUnsafeCurrentTask { $0?.cancel() }
                    default: break
                    }
                })
            } catch { c.check(error is CancellationError, "interrupted host callback stops local run") }
            let reopened = gatewayBackend(localRoot, script)
            let snapshot = await reopened.snapshot
            c.check(snapshot.cursor == "metadata", "metadata cursor durably committed")
            c.check(name == "artifact_updated" ? snapshot.artifactUpdates == [payload] : snapshot.canvasMutations == [payload],
                    "payload recovered even if host callback never acknowledged delivery")
        }
        let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: root)
        let old = try store.load()
        var object = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(old)).objectValue ?? [:]
        object.removeValue(forKey: "artifactUpdates"); object.removeValue(forKey: "canvasMutations")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try gatewayData(.object(object)).write(to: store.file)
        let legacy = gatewayBackend(root, GatewayScript([]))
        let snapshot = await legacy.snapshot
        c.check(snapshot.artifactUpdates.isEmpty && snapshot.canvasMutations.isEmpty, "old v1 journal defaults metadata to empty")
    }

    gatewayCase(t, "bounded metadata fails closed") { c, root in
        let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: root)
        var seed = try store.load()
        seed.runID = gatewayRunID; seed.phase = "unknown"
        seed.artifactUpdates = Array(repeating: ["artifactID": "old", "revision": 0], count: 256)
        try store.save(seed)
        let script = GatewayScript([gatewayQuery()], [.init(chunks: [
            try gatewayFrame("artifact_updated", "overflow", ["artifactID": "new", "revision": 1])
        ])])
        let backend = gatewayBackend(root, script)
        await c.error(.journalUnavailable, {
            _ = try await backend.resume(history: [], config: .init(), tools: nil, onEvent: { _ in })
        }, "metadata capacity never silently evicts a proposal")
        let snapshot = await backend.snapshot
        c.check(snapshot.artifactUpdates.count == 256 && snapshot.cursor == nil, "overflow event cursor is not committed")
    }

    gatewayCase(t, "optional backend and credential isolation") { c, root in
        c.check(AgentBackendKind.allCases == [.deepseek, .tika, .gateway], "gateway is additive and opt-in")
        c.check(AgentBackendKind(rawValue: "deepseek") == .deepseek && AgentBackendKind(rawValue: "tika") == .tika,
                "retained serialized provider identifiers unchanged")
        let a = URL(string: "https://GATEWAY.fixture.invalid/v1")!
        let b = URL(string: "https://gateway.fixture.invalid:443/other")!
        let other = URL(string: "https://gateway.fixture.invalid:8443/v1")!
        c.check(AgentGatewayPreferences.keychainService != AgentKeychain.service, "gateway credential service is not DeepSeek")
        c.check(AgentGatewayPreferences.credentialAccount(url: a) == AgentGatewayPreferences.credentialAccount(url: b),
                "same origin and default port share only their gateway credential")
        c.check(AgentGatewayPreferences.credentialAccount(url: a) != AgentGatewayPreferences.credentialAccount(url: other),
                "different port has separate credential account")
        c.check(AgentGatewayPreferences.keychain(url: a) === AgentGatewayPreferences.keychain(url: b),
                "same-origin keychain cache reused without repeated probes")
        c.check(AgentGatewayPreferences.keychain(url: a) !== AgentKeychain.shared,
                "factory never returns DeepSeek shared store")
        let expectedAccount = AgentGatewayPreferences.credentialAccount(url: a)
        let operations = AgentKeychain.Operations(read: { query in
            let values = query as! [String: Any]
            let correct = values[kSecAttrService as String] as? String == AgentGatewayPreferences.keychainService &&
                values[kSecAttrAccount as String] as? String == expectedAccount
            return (correct ? errSecSuccess : errSecItemNotFound, correct ? Data("fixture-token".utf8) : nil)
        }, update: { _, _ in errSecSuccess }, add: { _ in errSecSuccess }, delete: { _ in errSecSuccess })
        let fixtureStore = AgentKeychain(service: AgentGatewayPreferences.keychainService,
                                        account: expectedAccount, operations: operations)
        c.check(fixtureStore.readAPIKey() == "fixture-token", "credential lookup uses isolated service/account coordinates")
        let defaults = UserDefaults(suiteName: "gateway-fixture-\(UUID())")!
        let registration = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defer { defaults.setVolatileDomain(registration, forName: UserDefaults.registrationDomain) }
        defaults.register(defaults: ["agent.endpoint": "https://private.fixture.invalid/deepseek"])
        c.check(AgentGatewayPreferences.endpoint(defaults: defaults) == AgentGatewayPreferences.defaultEndpoint,
                "gateway defaults never inherit DeepSeek endpoint")
        defaults.register(defaults: [AgentGatewayPreferences.endpointKey: "https://user:secret@invalid.fixture.invalid"])
        c.check(AgentGatewayPreferences.endpoint(defaults: defaults) == nil, "credential-bearing URL never becomes a gateway endpoint")
        let missing = AgentGatewayUnavailableBackend()
        await c.error(.invalidConfiguration, {
            _ = try await missing.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
        }, "missing binding does not silently fall back to another provider")
        c.check(!FileManager.default.fileExists(atPath: root.path), "configuration tests use no system keychain or journal writes")
    }

    gatewayCase(t, "fresh polish journal isolation") { c, root in
        let conversationRoot = root.appendingPathComponent("conversation")
        let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: conversationRoot)
        var seed = try store.load()
        seed.runID = gatewayRunID; seed.phase = "unknown"
        seed.messages = [.init(id: UUID(uuidString: gatewayMessageID)!, role: .assistant, content: "existing partial")]
        seed.currentAssistantID = seed.messages[0].id
        try store.save(seed)
        let before = try Data(contentsOf: store.file)
        let script = GatewayScript([])
        let conversation = gatewayBackend(conversationRoot, script)
        let fresh = await conversation.isolatedBackend(journalRoot: root.appendingPathComponent("polish"))
        let freshBinding = await fresh.snapshot.binding
        c.check(freshBinding.sessionID != gatewayBinding.sessionID && freshBinding.projectID == nil && freshBinding.canvasID == nil,
                "draft polish gets a fresh session without conversation or canvas authority")
        c.check(await fresh.clientInstanceID != conversation.clientInstanceID, "draft targeting identity is independent")
        c.check(await !fresh.hasResumableRun, "fresh polish cannot attach to conversation run")
        c.check(await conversation.hasResumableRun, "conversation remains resumable during polish")
        let actions = [
            GatewayScript.HTTP(method: "POST", suffix: "/runs", action: { try gatewayDescriptor($0, binding: freshBinding) }),
            GatewayScript.HTTP(method: "GET", suffix: gatewayRunPath, action: { try gatewayDescriptor($0, binding: freshBinding) })
        ]
        let frames = try gatewayFrame("initial", "start", ["messageID": .string(gatewayMessageID)], binding: freshBinding) +
            gatewayFrame("content", "text", ["messageID": .string(gatewayMessageID), "delta": "polished"], binding: freshBinding) +
            gatewayFrame("run_completed", "done", ["messageID": .string(gatewayMessageID)], binding: freshBinding)
        await script.enqueue(actions, [.init(chunks: [frames])])
        var config = AgentConfig(); config.taskPolicy = .textPolish
        let result = try await fresh.run(history: [.init(role: .user, content: "draft")], config: config,
                                        tools: GatewayTools(), onEvent: { _ in })
        c.check(result.first?.content == "polished", "fresh read-only run completes separately")
        let request = await script.requests[0]
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
        c.check(body["tools"] == .array([]) && body["config"]?["taskPolicy"] == "textPolish",
                "isolated polish advertises no tools and explicit read-only task policy")
        c.check(try Data(contentsOf: store.file) == before, "isolated backend creation never edits original journal")
    }
}
