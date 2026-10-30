import Foundation
import Security
import AppKit
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
                         name: String = "fixture_tool", id: String = "tool-event",
                         arguments: String = #"{"text":"test"}"#) throws -> Data {
    try gatewayFrame("client_tool_request", id, [
        "executionID": "execution-one", "callID": "call-one", "name": .string(name),
        "argumentsJSON": .string(arguments), "targetClientInstanceID": .string(target),
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
    func advance(_ seconds: Double) { lock.withLock { date.addTimeInterval(seconds) } }
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
    private(set) var readbacks = 0
    private(set) var readbackScopes: [Bool] = []
    private(set) var notes: [String] = []
    private(set) var phases: [String] = []
    private(set) var streamActivities = 0
    private(set) var interaction: AgentInteraction?
    func receive(_ event: AgentRunEvent) {
        switch event {
        case .contentDelta(let delta): content += delta
        case .reasoningDelta(let delta): reasoning += delta
        case .assistantCompleted: completed += 1
        case .toolStarted: tools += 1
        case .artifactUpdated: artifacts += 1
        case .canvasChanged: canvas += 1
        case .canvasReadbackRequested(let request): readbacks += 1; readbackScopes.append(request.isFullSnapshot)
        case .note(let note): notes.append(note)
        case .runState(let phase, _, _): phases.append(phase)
        case .runStreamActivity: streamActivities += 1
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

private final class GatewayMutableTools: AgentToolExecutionScoped, @unchecked Sendable {
    private let lock = NSLock()
    private var executions = 0
    private var scope = AgentExecutionScope(sessionID: "session", projectID: "project", turnID: "turn")
    private var declarations = [AgentToolSpec(name: "fixture_tool", description: "test",
        parameters: ["type": "object", "properties": ["text": ["type": "string"]],
                     "required": ["text"], "additionalProperties": false], originLabel: "test")]
    var afterExecution: (@Sendable () -> Void)?
    var count: Int { lock.withLock { executions } }
    var executionScope: AgentExecutionScope { lock.withLock { scope } }
    func changeScope() {
        lock.withLock { scope = .init(sessionID: "another", projectID: "project", turnID: "turn") }
    }
    func changeSchema() {
        lock.withLock {
            declarations = [.init(name: "fixture_tool", description: "changed",
                parameters: ["type": "object", "properties": [:]], originLabel: "another owner")]
        }
    }
    func disable() { lock.withLock { declarations = [] } }
    func specs() -> [AgentToolSpec] { lock.withLock { declarations } }
    func execute(call: AgentToolCall) async -> AgentToolResult {
        lock.withLock { executions += 1 }
        afterExecution?()
        return .init(content: "side effect completed", summary: "completed")
    }
}

private actor GatewayExecutionGate {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func start() { started = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private final class GatewayCancellableTools: AgentToolExecuting, @unchecked Sendable {
    let gate = GatewayExecutionGate()
    let output: URL
    init(output: URL) { self.output = output }
    func specs() -> [AgentToolSpec] { GatewayTools().specs() }
    func execute(call: AgentToolCall) async -> AgentToolResult {
        await gate.start()
        do {
            try await Task.sleep(for: .seconds(60))
            try Task.checkCancellation()
            try Data("must not be written".utf8).write(to: output)
            return .init(content: "written", summary: "written")
        } catch { return .failure("handler cancelled", code: "CANCELLED") }
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
    runTaskSubagentGatewayTests(t)
    gatewayCase(t, "context journal binding") { c, root in
        let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: root)
        var journal = try store.load()
        var usage = AgentContextUsageState()
        usage.receive(try .init(validating: usageTestValue(conversation: "other")),
                      conversationID: "other", runID: gatewayRunID)
        journal.contextUsage = usage
        await c.error(.journalUnavailable, { try store.save(journal) },
                      "foreign context cannot be persisted under another binding")
    }
    gatewayCase(t, "authoritative usage compact durable") { c, root in
        var frames = try gatewayInitial()
        frames += try gatewayFrame("thinking", "before-thought", ["messageID": .string(gatewayMessageID), "delta": "思考🙂"])
        frames += try gatewayFrame("content", "before-body", ["messageID": .string(gatewayMessageID), "delta": "中e"])
        frames += try gatewayFrame("context_usage", "u1", usageTestValue())
        frames += try gatewayFrame("compact", "c1", ["phase": "started"])
        frames += try gatewayFrame("compact", "c2", ["phase": "started"])
        frames += try gatewayFrame("context_usage", "u2", usageTestValue(revision: 2))
        frames += try gatewayFrame("compact", "c3", ["phase": "finished"])
        frames += try gatewayFrame("content", "after-body", ["messageID": .string(gatewayMessageID), "delta": "\u{301}后"])
        frames += try gatewayFrame("context_usage", "old", usageTestValue(revision: 1))
        frames += try gatewayFrame("context_usage", "bad", ["revision": -1])
        frames += try gatewayFrame("context_usage", "other", usageTestValue(revision: 100, conversation: "other"))
        frames += try gatewayFrame("context_usage", "oldrun", usageTestValue(revision: 100, run: "old"))
        frames += try gatewayFrame("compact", "unknown-phase", ["phase": "summarized"])
        frames += try gatewayFrame("context_usage", "u3", ["context_usage": usageTestValue(revision: 3)])
        frames += try gatewayDone()
        let transport = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery()], [.init(chunks: [frames])])
        let backend = gatewayBackend(root, transport)
        let events = GatewayEvents()
        _ = try await backend.run(history: [], config: AgentConfig(), tools: nil) { await events.receive($0) }
        let snapshot = await backend.snapshot
        c.check(snapshot.contextUsage.snapshot?.revision == 3 && snapshot.contextUsage.displaySnapshot?.percentage == 200,
                "stream ignores stale invalid and wrong origins while preserving 200 percent")
        c.check(!snapshot.contextUsage.stale && snapshot.contextUsage.compaction == .idle,
                "ready observation after compact finish restores validity")
        c.check(snapshot.compactions.entries.count == 1 && snapshot.compactions.entries[0].phase == .finished,
                "duplicate starts update one durable lifecycle")
        c.check(snapshot.compactions.entries.first?.anchor?.messageID == UUID(uuidString: gatewayMessageID)
                && snapshot.compactions.entries.first?.anchor?.contentBytes == "中e".utf8.count
                && snapshot.compactions.entries.first?.anchor?.reasoningBytes == "思考🙂".utf8.count,
                "compact card freezes assistant identity and byte offsets in same cursor transaction")
        c.check(snapshot.messages.last?.content == "中e\u{301}后" && snapshot.messages.last?.reasoning == "思考🙂",
                "compact card metadata never rewrites upstream body or reasoning")
        let recovered = await gatewayBackend(root, transport).snapshot
        c.check(recovered.contextUsage == snapshot.contextUsage && recovered.compactions == snapshot.compactions,
                "actual SQLite process-style reopen retains full projection")
    }
    gatewayCase(t, "compact stop no false finish") { c, root in
        var frames = try gatewayInitial()
        frames += try gatewayFrame("context_usage", "ready", usageTestValue())
        frames += try gatewayFrame("compact", "started", ["phase": "started"])
        frames += try gatewayDone()
        let backend = gatewayBackend(root, GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery()],
            [.init(chunks: [frames])]))
        _ = try await backend.run(history: [], config: AgentConfig(), tools: nil) { _ in }
        let snapshot = await backend.snapshot
        c.check(snapshot.contextUsage.stale && snapshot.contextUsage.compaction == .idle && snapshot.compactions.entries.isEmpty,
                "terminal removes unfinished lifecycle without inventing compressed observation")
    }
    gatewayCase(t, "durable subagent full readback") { c, root in
        let nested: JSONValue = ["tool": "gen_image", "status": "completed", "tool_call_id": "nested",
            "response": ["canvas_id": "project", "node_id": "created-node"]]
        func child(_ phase: String, parent: String = "parent", schema: String = "subagent_event.v1",
                   tool: JSONValue? = nil) -> JSONValue {
            var value: [String: JSONValue] = ["schema_version": .string(schema), "subagent_id": "child",
                "parent_tool_call_id": .string(parent), "phase": .string(phase)]
            if let tool { value["tool_event"] = tool }
            return .object(value)
        }
        var frames = try gatewayInitial()
        frames += try gatewayFrame("subagent_event", "child-start", child("started"))
        frames += try gatewayFrame("subagent_event", "unsupported", child("tool_completed", schema: "future.v2", tool: nested))
        frames += try gatewayFrame("subagent_event", "child-tool", child("tool_completed", tool: nested))
        frames += try gatewayFrame("subagent_event", "child-stop", child("stopped"))
        frames += try gatewayFrame("subagent_event", "late-terminal", child("completed"))
        frames += try gatewayFrame("subagent_event", "next-parent", child("started", parent: "next-parent"))
        frames += try gatewayFrame("subagent_event", "late-old-parent", child("failed"))
        frames += try gatewayDone()
        let backend = gatewayBackend(root, GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery()],
                                                        [.init(chunks: [frames])]))
        let events = GatewayEvents()
        _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { await events.receive($0) })
        let snapshot = await backend.snapshot, scopes = await events.readbackScopes
        c.check(scopes == [false, true, true], "nested tool index precedes terminal full query and run finish flush")
        c.check(snapshot.canvasReadbacks.count == 3 && snapshot.canvasMutations.isEmpty,
                "child events produce durable indices and full intents without graph mutation authority")
        c.check(snapshot.canvasReadbacks.first?.source?.subagentID == "child"
                && snapshot.canvasReadbacks.first?.source?.parentToolCallID == "parent",
                "adapter attaches explicitly declared parent and child to nested tool response")
        c.check(snapshot.canvasReadbacks.last?.source?.parentToolCallID == "next-parent"
                && snapshot.canvasReadbacks.last?.key == "next-parent",
                "run finish flushes dirty successor without accepting late earlier-parent terminal")
        let restored = await gatewayBackend(root, GatewayScript([])).snapshot
        c.check(restored.canvasReadbacks == snapshot.canvasReadbacks
                && restored.subagentCanvasScopes == snapshot.subagentCanvasScopes,
                "journal recovery preserves full intents and current parent instance scope")
    }
    gatewayCase(t, "durable source tool readback") { c, root in
        let payload: JSONValue = ["tool": "Bash", "status": "failed", "tool_call_id": "readback-call",
            "response": ["canvas_changed": ["canvas_id": "project", "node_id": "local-node"]]]
        let frames = try gatewayInitial() + gatewayFrame("canvas_tool_event", "readback-event", payload) + gatewayDone()
        let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery()], [.init(chunks: [frames])])
        let backend = gatewayBackend(root, script), events = GatewayEvents()
        _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { await events.receive($0) })
        let snapshot = await backend.snapshot
        let count = await events.readbacks
        c.check(count == 1 && snapshot.canvasReadbacks.count == 1, "source indices are persisted and emitted")
        c.check(snapshot.canvasReadbacks[0].nodeIDs == ["local-node"]
            && snapshot.canvasReadbacks[0].allowsFallback, "CLI partial effects retain scoped readback semantics")
        c.check(snapshot.canvasMutations.isEmpty, "source indices are never treated as graph mutation authority")
        let restarted = gatewayBackend(root, GatewayScript([]))
        c.check(await restarted.snapshot.canvasReadbacks == snapshot.canvasReadbacks,
                "restart preserves unresolved readback without inventing a source")
    }
    gatewayCase(t, "durable child readback origins") { c, root in
        func payload(_ parent: String) -> JSONValue {
            ["tool": "gen_image", "status": "completed", "tool_call_id": "shared-call",
             "subagent_id": "child", "parent_tool_call_id": .string(parent),
             "response": ["canvas_changed": ["canvas_id": "project", "node_id": "local-node"]]]
        }
        let frames = try gatewayInitial()
            + gatewayFrame("canvas_tool_event", "child-one", payload("parent-one"))
            + gatewayFrame("canvas_tool_event", "child-two", payload("parent-two")) + gatewayDone()
        let backend = gatewayBackend(root, GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery()],
                                                        [.init(chunks: [frames])]))
        _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
        let snapshot = await backend.snapshot
        c.check(snapshot.canvasReadbacks.count == 2
            && Set(snapshot.canvasReadbacks.map(\.coordinationKey)).count == 2,
                "shared tool call under distinct parents retains both requests")
        c.check(Set(snapshot.canvasReadbacks.compactMap { $0.source?.parentToolCallID }) == ["parent-one", "parent-two"],
                "explicit parent identities are persisted")
        let restarted = gatewayBackend(root, GatewayScript([]))
        c.check(await restarted.snapshot.canvasReadbacks == snapshot.canvasReadbacks,
                "journal restart preserves full child provenance")
        c.check(snapshot.canvasMutations.isEmpty, "child origin never grants graph mutation authority")
    }

    gatewayCase(t, "bounded redacted diagnostics") { c, root in
        let secret = "private-user-body-and-api-key"
        let start = try gatewayInitial()
        let frames = (0..<160).map { index in
            try! gatewayFrame("note", "secret-event-\(secret)-\(index)", ["message": .string(secret)])
        }.reduce(start, +) + (try gatewayDone())
        let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery()], [.init(chunks: [frames])])
        let backend = AgentGatewayBackend(baseURL: gatewayRoot, binding: gatewayBinding, journalRoot: root,
            apiKeyProvider: { secret }, transport: script, timing: GatewayClock().timing)
        _ = try await backend.run(history: [.init(role: .user, content: secret, reasoning: secret)],
            config: .init(), tools: nil, onEvent: { _ in })
        let diagnostics = await backend.diagnosticSnapshot
        let bytes = try await backend.exportDiagnostics()
        let text = String(decoding: bytes, as: UTF8.self)
        c.check(diagnostics.records.count == AgentRunDiagnostics.maximumRecords && diagnostics.dropped > 0,
                "record ring remains bounded after long stream")
        c.check(bytes.count <= AgentRunDiagnostics.maximumExportBytes, "export has a byte ceiling")
        c.check(!text.contains(secret) && !text.contains(gatewayRoot.absoluteString)
            && !text.contains(gatewayRunID), "no credentials, endpoint, user body or opaque raw run ID")
        c.check(diagnostics.records.last?.stage == .terminal && diagnostics.records.last?.outcome == .completed,
                "completed operation reports its durable terminal state")
        c.check(diagnostics.records.allSatisfy {
            $0.durationMilliseconds.map { $0.isFinite && $0 >= 0 } ?? true
        }, "durations use finite nonnegative milliseconds")
        let committed = diagnostics.records.filter { $0.stage == .event && $0.outcome == .committed }
        c.check(committed.allSatisfy { $0.event?.count == 64 && $0.run?.count == 64 },
                "event and run correlation use digests")
        c.check(diagnostics.records.map(\.sequence) == diagnostics.records.map(\.sequence).sorted(),
                "eviction retains sequence order")
        var direct = AgentRunDiagnostics(binding: gatewayBinding)
        direct.append(stage: .tool, outcome: .committed, call: secret,
            elapsed: .infinity, bytes: -4, status: 100_000, retry: -2)
        c.check(direct.records[0].durationMilliseconds == nil && direct.records[0].byteCount == 0
            && direct.records[0].httpStatus == nil && direct.records[0].retry == 0,
            "invalid metrics cannot escape sanitization")
        c.check(try !String(decoding: direct.export(), as: UTF8.self).contains(secret),
                "tool correlation never includes raw call identity")
    }

    gatewayCase(t, "versioned image and reasoning history") { c, root in
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        bitmap.bitmapData?.initialize(repeating: 128, count: 16)
        let png = bitmap.representation(using: .png, properties: [:])!
        let image = try AgentAttachmentImport.captureImage(png, name: "fixture.png")
        let history: [AgentMessage] = [
            .init(role: .assistant, content: "earlier", reasoning: "思考\n\t🙂 "),
            .init(role: .assistant, content: "", reasoning: "", toolCalls: [
                .init(id: "history-call", name: "fixture_tool", argumentsJSON: "{}")]),
            .init(role: .tool, content: "saved result", toolCallId: "history-call"),
            .init(role: .user, content: "captured image", attachments: [image])
        ]
        let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery()],
                                   [.init(chunks: [try gatewayInitial() + gatewayDone()])])
        var config = AgentConfig()
        config.supportsImageInput = true
        _ = try await gatewayBackend(root, script).run(history: history, config: config, tools: nil, onEvent: { _ in })
        let requests = await script.requests
        let body = try JSONDecoder().decode(JSONValue.self, from: requests[0].httpBody!)
        c.check(body["messageSchemaVersion"] == 1 && body["schemaVersion"] == 1, "message v1 is additive to gateway v1")
        c.check(body["config"]?["supportsImageInput"] == true, "model image capability explicitly captured")
        let wire = body["history"]!.arrayValue!
        c.check(wire[0]["reasoning"] == "思考\n\t🙂 " && wire[1]["reasoning"] == "", "all assistant reasoning preserved without trimming")
        c.check(wire[3]["content"]?.arrayValue?.last?["image_url"]?["url"] ==
                .string("data:image/png;base64," + png.base64EncodedString()), "image bytes survive request encoding")
        let unsupported = gatewayBackend(root.appendingPathComponent("unsupported"), GatewayScript([]))
        do {
            _ = try await unsupported.run(history: history, config: .init(), tools: nil, onEvent: { _ in })
            c.check(false, "unclaimed image capability rejects")
        } catch {
            c.check(error is AgentAttachmentImport.ImportError, "unclaimed image rejected before HTTP")
        }
    }

    gatewayCase(t, "complete history HTTP budget") { c, root in
        let script = GatewayScript([])
        let backend = gatewayBackend(root, script)
        await c.error(.requestTooLarge, {
            _ = try await backend.run(history: [.init(role: .user, content: String(repeating: "x", count: 8 * 1024 * 1024))],
                                      config: .init(), tools: nil, onEvent: { _ in })
        }, "rejects JSON envelope overhead before reserving run")
        c.check(await script.requests.isEmpty, "oversized history sends no HTTP request")
        c.check(await !backend.hasResumableRun, "oversized history does not create unknown run")
        let journal = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: root)
        c.check(!FileManager.default.fileExists(atPath: journal.file.path), "oversized command not persisted")
    }

    gatewayCase(t, "UTF8 and metadata") { c, root in
        let mutation: JSONValue = [
            "project_id": "project", "conversation_id": "session", "run_id": .string(gatewayRunID),
            "mutation_id": "mutation", "changes": [], "added_edges": [], "removed_edges": []
        ]
        let frames: [Data] = try [
            gatewayInitial(), gatewayContent("中文🙂"),
            gatewayFrame("thinking", "thought", ["messageID": .string(gatewayMessageID), "delta": "推理🧪"]),
            gatewayFrame("artifact_updated", "artifact", ["artifactID": "artifact", "revision": 1]),
            gatewayFrame("canvas_changed", "canvas", mutation),
            gatewayFrame("note", "note", ["message": "fixture-secret"]),
            gatewayFrame("future_type", "future", ["text": "fixture-secret"]), gatewayDone()
        ]
        let bytes = frames.reduce(into: Data()) { $0.append($1) }
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
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let disk = try files.filter { !$0.path.hasSuffix(".lock") }.map {
            String(decoding: try Data(contentsOf: $0), as: UTF8.self)
        }.joined()
        c.check(!disk.contains("fixture-secret") && !disk.contains("config-secret"), "journal stores no transport secrets")
        c.check(try store.load().cursor == "done", "committed cursor is terminal event ID")
        let mode = try FileManager.default.attributesOfItem(atPath: store.storageFile.path)[.posixPermissions] as? NSNumber
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

    gatewayCase(t, "frozen declaration scope and arguments") { c, root in
        for mode in ["schema", "owner", "arguments", "after_notification"] {
            let local = root.appendingPathComponent(mode)
            let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: local)
            let seed = try store.load(); try store.save(seed)
            let tools = GatewayMutableTools()
            let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery(),
                gatewayStatus("POST", gatewayRunPath + "/tool-results", 204)],
                [.init(chunks: [try gatewayInitial() + gatewayTool(seed.clientInstanceID,
                    arguments: mode == "arguments" ? #"{"text":12}"# : #"{"text":"test"}"#) + gatewayDone()])])
            let messages = try await gatewayBackend(local, script).run(
                history: [], config: .init(), tools: tools, onEvent: { event in
                    if case .sessionStarted = event {
                        if mode == "schema" { tools.changeSchema() }
                        if mode == "owner" { tools.changeScope() }
                    }
                    if case .toolStarted = event, mode == "after_notification" { tools.changeSchema() }
                })
            c.check(tools.count == 0, "\(mode) cannot start side effects under an old declaration")
            c.check(messages.first(where: { $0.role == .tool })?.isFailure == true,
                    "\(mode) produces a durable typed rejection")
            let saved = try store.load()
            c.check(saved.toolSnapshots?[saved.toolSubmissionKey ?? ""]?.declarations.first?.wireValue["function"]?["description"] == "test",
                    "\(mode) preserves the exact submitted declaration")
            c.check(await script.remaining == 0, "\(mode) finishes the expected protocol")
        }
    }

    gatewayCase(t, "same live owner versus restart") { c, root in
        for replacement in [false, true] {
            let local = root.appendingPathComponent(replacement ? "replacement" : "same")
            let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: local)
            let seed = try store.load(); try store.save(seed)
            let tools = GatewayMutableTools()
            let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery()],
                [.init(chunks: [try gatewayInitial()])])
            let backend = gatewayBackend(local, script, clock: GatewayClock(cancelSleep: true))
            do {
                _ = try await backend.run(history: [], config: .init(), tools: tools, onEvent: { _ in })
            } catch { c.check(error is CancellationError, "reader interruption leaves resumable submission") }
            await script.enqueue([gatewayQuery(), gatewayStatus("POST", gatewayRunPath + "/tool-results", 204)],
                [.init(chunks: [try gatewayTool(seed.clientInstanceID) + gatewayDone()])])
            let controller = replacement ? gatewayBackend(local, script) : backend
            let executor = replacement ? GatewayMutableTools() : tools
            let messages = try await controller.resume(history: [], config: .init(), tools: executor, onEvent: { _ in })
            c.check(executor.count == (replacement ? 0 : 1),
                    replacement ? "new process instance cannot inherit old execution authority" : "same live instance resumes authorized tools")
            c.check(messages.first(where: { $0.role == .tool })?.isFailure == replacement,
                    "result accurately reflects ownership")
        }
    }

    gatewayCase(t, "result expires while executing") { c, root in
        let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: root)
        let seed = try store.load(); try store.save(seed)
        let clock = GatewayClock()
        let tools = GatewayMutableTools()
        tools.afterExecution = { clock.advance(20) }
        let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery()],
            [.init(chunks: [try gatewayInitial() + gatewayTool(seed.clientInstanceID,
                expiry: clock.now.timeIntervalSince1970 + 10)])])
        let backend = gatewayBackend(root, script, clock: clock)
        await c.error(.toolRequestExpired, {
            _ = try await backend.run(history: [], config: .init(), tools: tools, onEvent: { _ in })
        }, "expired completed result is not submitted")
        let saved = try store.load()
        c.check(tools.count == 1 && saved.tools["execution-one"]?.phase == "completed"
            && saved.tools["execution-one"]?.content == "side effect completed", "completion stays durable without re-execution")
        c.check(await script.requests.filter { $0.httpMethod == "POST" }.count == 1,
                "no stale result POST is sent")
    }

    gatewayCase(t, "cancel reaches running handler") { c, root in
        let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: root)
        let seed = try store.load(); try store.save(seed)
        let tools = GatewayCancellableTools(output: root.appendingPathComponent("side-effect.txt"))
        let script = GatewayScript([gatewayHTTP("POST", "/runs"), gatewayQuery()],
            [.init(chunks: [try gatewayInitial() + gatewayTool(seed.clientInstanceID)])])
        let backend = gatewayBackend(root, script)
        let task = Task { try await backend.run(history: [], config: .init(), tools: tools, onEvent: { _ in }) }
        await tools.gate.wait()
        let started = Date()
        task.cancel()
        do { _ = try await task.value; c.check(false, "cancel must interrupt run") }
        catch { c.check(error is CancellationError, "run reports cancellation") }
        c.check(Date().timeIntervalSince(started) < 1 && !FileManager.default.fileExists(atPath: tools.output.path),
                "cooperative handler stops before its file side effect")
        c.check(try store.load().tools["execution-one"]?.phase == "completed",
                "handler cancellation result is cached locally")
        c.check(await script.requests.filter { $0.httpMethod == "POST" }.count == 1,
                "cancelled run sends no tool result")
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
            let base = GatewayMutableTools()
            if confirmed { base.disable() }
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

    gatewayCase(t, "recovery uses original submission scope") { c, root in
        let store = AgentGatewayJournalStore(baseURL: gatewayRoot, binding: gatewayBinding, root: root)
        var seed = try store.load()
        let call = AgentToolCall(id: "call-one", name: "fixture_tool", argumentsJSON: #"{"text":"test"}"#)
        let original = AgentExecutionScope(sessionID: "session", projectID: "project", turnID: "original")
        let later = AgentExecutionScope(sessionID: "session", projectID: "project", turnID: "later")
        let host = AgentExecutionJournal(root: root)
        for (scope, content) in [(original, "original result"), (later, "different result")] {
            guard case .execute(let reservation) = try host.reserve(scope: scope, call: call) else {
                throw GatewayFixtureError.unexpectedRequest
            }
            try host.complete(reservation, result: .init(content: content, summary: "saved"))
        }
        seed.runID = gatewayRunID; seed.phase = "unknown"
        seed.toolSnapshots = ["original": .init(instanceID: UUID(), scope: original, declarations: [])]
        seed.tools["execution-one"] = .init(request: .init(executionID: "execution-one", callID: call.id,
            name: call.name, argumentsJSON: call.argumentsJSON, targetClientInstanceID: seed.clientInstanceID,
            expiresAt: 4_000_000_000), phase: "executing", submissionKey: "original")
        try store.save(seed)
        let base = GatewayMutableTools(); base.disable()
        let recovery = AgentGatewayRecoverableTools(base: base, journal: host, scope: later)
        let script = GatewayScript([gatewayQuery(), gatewayStatus("POST", gatewayRunPath + "/tool-results", 204)],
            [.init(chunks: [try gatewayInitial() + gatewayDone()])])
        let messages = try await gatewayBackend(root, script).resume(
            history: [], config: .init(), tools: recovery, onEvent: { _ in })
        c.check(messages.first(where: { $0.role == .tool })?.content == "original result",
                "recreated host never substitutes a later turn's matching call ID")
        c.check(base.count == 0 && recovery.specs().isEmpty,
                "removed executor still reconciles durable result without executing")
        do {
            _ = try await recovery.recoveredResult(call: call,
                scope: .init(sessionID: "wrong", projectID: "project", turnID: "original"))
            c.check(false, "cross-session receipt must reject")
        } catch { c.check(error as? AgentGatewayError == .originMismatch, "cross-session receipt is rejected") }
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
            let events = GatewayEvents()
            await c.error(expected, {
                _ = try await backend.run(history: [], config: .init(), tools: nil, onEvent: { await events.receive($0) })
            }, "\(name) rejected")
            let resumable = await backend.hasResumableRun
            c.check(clock.sleeps.isEmpty && resumable, "\(name) stops without losing run")
            let activities = await events.streamActivities
            c.check(activities == (name == "mutated-id" ? 2 : ["delta", "canvas-origin"].contains(name) ? 1 : 0),
                    "\(name) only committed valid prefix frames count as stream activity")
            let diagnostics = await backend.diagnosticSnapshot
            c.check(diagnostics.records.contains {
                $0.failure == (expected == .originMismatch ? .scopeMismatch : .malformed)
            }, "\(name) has a typed diagnostic cause")
            if ["binding", "run", "canvas-origin"].contains(name) {
                let canvasEvents = await events.canvas, artifactEvents = await events.artifacts
                let content = await events.content
                c.check(canvasEvents == 0 && artifactEvents == 0 && content.isEmpty,
                        "\(name) emits no foreign content or canvas write")
                let state = await backend.snapshot
                c.check(state.canvasMutations.isEmpty && state.artifactUpdates.isEmpty,
                        "\(name) stores no foreign graph or artifact")
            }
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
        try Data("corrupt".utf8).write(to: store.storageFile)
        let restarted = gatewayBackend(root, script)
        c.check(await restarted.hasResumableRun, "corrupt journal conservatively blocks replacement")
        await c.error(.journalUnavailable, {
            _ = try await restarted.run(history: [], config: .init(), tools: nil, onEvent: { _ in })
        }, "corrupt journal is never reset silently")
        c.check(try String(contentsOf: store.storageFile, encoding: .utf8) == "corrupt", "corrupt evidence preserved")
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
        let before = try Data(contentsOf: store.storageFile)
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
        c.check(try Data(contentsOf: store.storageFile) == before, "isolated backend creation never edits original journal")
    }
}
