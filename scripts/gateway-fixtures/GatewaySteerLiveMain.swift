import Foundation
@testable import ClipSlotsKit

private struct Failure: Error { let text: String }
private func check(_ condition: Bool, _ text: String) throws {
    guard condition else { throw Failure(text: text) }
    print("PASS: \(text)")
}
private func until(_ condition: () async -> Bool) async throws {
    for _ in 0..<800 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw Failure(text: "bounded wait")
}
private actor Gate {
    var opened = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { opened = true; for waiter in waiters { waiter.resume() }; waiters = [] }
}
private actor Events {
    var text = ""
    var completions = 0
    var entries: [AgentGatewaySteerSnapshot] = []
    func receive(_ event: AgentRunEvent) {
        switch event {
        case .contentDelta(let value): text += value
        case .assistantCompleted: completions += 1
        case .steerState(let value): entries.append(value)
        default: break
        }
    }
}
private actor TestTransport: AgentGatewayTransport {
    let network = URLSessionAgentGatewayTransport()
    let gate: Gate
    let mode: String
    var posts = 0
    var requests: [URLRequest] = []
    init(gate: Gate, mode: String) { self.gate = gate; self.mode = mode }
    func send(request: URLRequest) async throws -> AgentGatewayHTTPResponse {
        requests.append(request)
        if request.url?.path.hasSuffix("/steer") == true {
            posts += 1
            if mode == "missing" { throw URLError(.networkConnectionLost) }
            let result = try await network.send(request: request)
            if mode == "unknown" { throw URLError(.networkConnectionLost) }
            return result
        }
        return try await network.send(request: request)
    }
    func stream(request: URLRequest) async throws -> AgentHTTPStream {
        let result = try await network.stream(request: request)
        guard mode == "hold" || mode == "restart" else { return result }
        let gate = gate
        return .init(statusCode: result.statusCode, chunks: AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in result.chunks {
                        if String(decoding: chunk, as: UTF8.self).contains("event: assistant_completed") {
                            await gate.wait()
                        }
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel(); Task { await gate.open() } }
        })
    }
    func save(_ url: URL) throws {
        let values = requests.map {
            ["method": $0.httpMethod ?? "", "url": $0.url?.absoluteString ?? "",
             "key": $0.value(forHTTPHeaderField: "Idempotency-Key") ?? "",
             "body": $0.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""]
        }
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
    }
}
private final class Tools: AgentToolExecuting, @unchecked Sendable {
    let gate = Gate()
    let lock = NSLock()
    var count = 0
    var executions: Int { lock.withLock { count } }
    func specs() -> [AgentToolSpec] {
        [.init(name: "live_test_tool", description: "Local synthetic fixture",
               parameters: ["type": "object", "properties": [:]], originLabel: "TEST ONLY")]
    }
    func execute(call: AgentToolCall) async -> AgentToolResult {
        let number = lock.withLock { count += 1; return count }
        if number == 2 { await gate.wait() }
        return .init(content: "synthetic-tool-\(number)", summary: "Synthetic result")
    }
}

private func validators() throws {
    let id = UUID().uuidString
    let binding: JSONValue = ["sessionID": "session", "projectID": "project", "canvasID": "canvas"]
    var accepted: [String: JSONValue] = ["schemaVersion": 1, "steerSchemaVersion": 1,
        "binding": binding, "runID": "run/opaque+id", "clientInstanceID": "client",
        "requestKey": .string("steer-" + id), "submissionID": .string(id), "messageID": .string(id),
        "state": "accepted", "revision": 1, "sequence": 1, "acceptedAt": 100]
    let a = try AgentGatewaySteerReceipt(validating: .object(accepted))
    var placed = accepted
    placed["state"] = "placed"; placed["revision"] = 2
    placed["placement"] = ["point": "model_boundary", "generation": 1, "messageIndex": 3, "placedAt": 101]
    let p = try AgentGatewaySteerReceipt(validating: .object(placed))
    try check(a.placement == nil, "accepted has no placement")
    try check(try AgentGatewaySteerReceipt.reduce(p, incoming: a) == p, "late accepted cannot reverse placed")
    try check(try AgentGatewaySteerReceipt.reduce(nil, incoming: p) == p, "latest query may precede accepted")
    var malformed: [[String: JSONValue]] = []
    for (key, value) in [("schemaVersion", JSONValue.number(2)), ("revision", .number(2)),
                         ("sequence", .number(1.5)), ("placement", .null), ("injected", .bool(true))] {
        var candidate = accepted; candidate[key] = value; malformed.append(candidate)
    }
    var changed = placed
    changed["placement"] = ["point": "model_boundary", "generation": 1, "messageIndex": 4, "placedAt": 101]
    do {
        _ = try AgentGatewaySteerReceipt.reduce(p, incoming: .init(validating: .object(changed)))
        throw Failure(text: "conflicting revision accepted")
    } catch is AgentGatewayError { print("PASS: same revision placement conflict rejected") }
    accepted["clientInstanceID"] = "other"
    do {
        _ = try AgentGatewaySteerReceipt.reduce(p, incoming: .init(validating: .object(accepted)))
        throw Failure(text: "foreign stale receipt accepted")
    } catch is AgentGatewayError { print("PASS: foreign stale identity rejected") }
    for candidate in malformed {
        do {
            _ = try AgentGatewaySteerReceipt(validating: .object(candidate))
            throw Failure(text: "malformed receipt accepted")
        } catch is AgentGatewayError { print("PASS: malformed receipt rejected") }
    }
}

@main private enum Main {
    static func main() async {
        do {
            let env = ProcessInfo.processInfo.environment
            guard let rootText = env["STEER_GATEWAY_URL"], let root = URL(string: rootText),
                  let folder = env["STEER_TEST_DIR"], folder.hasPrefix("/tmp/clipslots-gateway-steer-"),
                  let control = env["STEER_CONTROL_URL"], let mode = env["STEER_TEST_MODE"] else {
                throw Failure(text: "private fixture required")
            }
            let directory = URL(fileURLWithPath: folder)
            let binding = AgentRunBinding(sessionID: "swift-" + (mode == "restore" ? "restart" : mode),
                                          projectID: "p", canvasID: "c")
            let journal = directory.appendingPathComponent("journal")
            let gate = Gate(), transport = TestTransport(gate: Gate(), mode: mode)
            let network = URLSessionAgentGatewayTransport()
            let config: AgentConfig = {
                var value = AgentConfig(model: "synthetic", systemPrompt: "synthetic only")
                value.supportsImageInput = true; return value
            }()
            let tools = Tools(), events = Events()
            let backend = AgentGatewayBackend(baseURL: root, binding: binding, journalRoot: journal,
                apiKeyProvider: { "live-auth" }, transport: transport)
            func controlRequest(_ path: String) async throws {
                let response = try await network.send(request: URLRequest(url: URL(string: control + path)!))
                try check(response.statusCode == 200, "fixture control \(path)")
            }
            func saveState() async throws {
                let state = await backend.snapshot
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let value: JSONValue = ["runID": state.runID.map(JSONValue.string) ?? .null,
                    "clientInstanceID": .string(state.clientInstanceID),
                    "cursor": state.cursor.map(JSONValue.string) ?? .null,
                    "messages": try JSONDecoder().decode(JSONValue.self, from: encoder.encode(state.messages)),
                    "steers": .array(try state.steers.map { entry in
                        ["message": try JSONDecoder().decode(JSONValue.self, from: encoder.encode(entry.message)),
                         "receipt": try entry.receipt.map { try JSONDecoder().decode(JSONValue.self,
                            from: encoder.encode($0)) } ?? .null,
                         "attempted": .bool(entry.attempted), "eventApplied": .bool(entry.eventApplied)]
                    })]
                try encoder.encode(value).write(to: directory.appendingPathComponent("client-state.json"))
                try await transport.save(directory.appendingPathComponent(
                    mode == "restore" ? "client-restore-requests.json" : "client-requests.json"))
            }
            if mode == "restore" {
                let state = await backend.snapshot
                try check(state.steers.count == 2 && state.steers.allSatisfy { $0.receipt?.state == .placed && !$0.eventApplied },
                          "separate process loads placement without prematurely inserting input")
                let output = try await backend.resume(history: [], config: config, tools: nil,
                    onEvent: { await events.receive($0) })
                try check(output.filter { $0.role == .user }.count == 2, "separate process replays both inputs once")
                try check(output.map(\.role) == [.assistant, .user, .user, .assistant],
                          "separate process restores exact chronological order")
                try await saveState()
                return
            }
            try validators()
            let initial = AgentMessage(role: .user, content: "synthetic first")
            let run = Task {
                try await backend.run(history: [initial],
                    config: config, tools: mode == "tools" ? tools : nil, onEvent: { await events.receive($0) })
            }
            try await until { await events.text == "kept-work" }
            let remote = await backend.snapshot.runID!
            let first = AgentMessage(role: .user, content: "补充🙂e\u{301}",
                skillReferences: mode == "continue"
                    ? [.init(name: "snapshot", path: "/synthetic/SKILL.md", markdown: "exact original 🙂")] : nil)
            if mode == "unknown" || mode == "missing" {
                do { _ = try await backend.submitSteer(message: first, runID: remote)
                    throw Failure(text: "transport loss did not fail")
                } catch is URLError { print("PASS: unknown POST response retained") }
                let state = await backend.snapshot
                try check(state.steers.count == 1 && state.steers[0].receipt == nil && state.steers[0].attempted,
                          "unknown exact input is durable")
                if mode == "missing" {
                    do { _ = try await backend.reconcileSteer(submissionID: first.id, runID: remote)
                        throw Failure(text: "404 resubmitted")
                    } catch let error as AgentGatewayError {
                        try check(error == .interrupted, "dual 404 remains recoverable unknown")
                    }
                    try check(await transport.posts == 1, "dual 404 never issues another POST")
                    try await controlRequest("/release")
                    _ = try await run.value
                    try await saveState(); return
                }
                let result = try await backend.reconcileSteer(submissionID: first.id, runID: remote)
                try check(result.receipt?.state == .accepted, "unknown reconciles original immutable request")
                try check(await transport.posts == 1, "unknown reconciliation has no repeated POST")
            } else {
                let result = try await backend.submitSteer(message: first, runID: remote)
                try check(result.receipt?.state == .accepted && !result.eventApplied, "live accepted remains unconsumed")
            }
            let independent = AgentGatewayBackend(baseURL: root, binding: binding, journalRoot: journal,
                apiKeyProvider: { "live-auth" })
            do { _ = try await independent.reconcileSteer(submissionID: first.id, runID: remote)
                throw Failure(text: "second process owner permitted")
            } catch let error as AgentGatewayError {
                try check(error == .busy, "independent owner rejected by journal lock")
            }
            if mode == "cancel" {
                await backend.cancelRun()
                _ = try? await run.value
                let result = try await backend.reconcileSteer(submissionID: first.id, runID: remote)
                try check(result.receipt?.state == .returned && result.receipt?.returnReason == "TERMINAL_CANCELLED",
                          "cancel returns exact pending input")
                try check(Data(result.message.content.utf8) == Data(first.content.utf8), "returned body preserves Unicode bytes")
                try await saveState(); return
            }
            if mode == "tools" {
                try await controlRequest("/release")
                try await until { tools.executions == 2 }
                let before = try await backend.reconcileSteer(submissionID: first.id, runID: remote)
                try check(before.receipt?.state == .accepted, "partial tools are not a safe placement")
                await tools.gate.open()
            } else {
                if mode == "hold" || mode == "restart" {
                    let second = AgentMessage(role: .user, content: "第二条输入")
                    _ = try await backend.submitSteer(message: second, runID: remote)
                }
                try await controlRequest("/release")
                if mode == "hold" || mode == "restart" {
                    try await until {
                        (try? await backend.reconcileSteer(submissionID: first.id, runID: remote))?.receipt?.state == .placed
                    }
                    let state = await backend.snapshot
                    try check(state.messages.allSatisfy { $0.role != .user },
                              "early placed query does not insert into partial assistant")
                    try check(state.cursor != nil && state.steers[0].eventApplied == false,
                              "status query never acknowledges SSE cursor")
                    if mode == "restart" {
                        for entry in state.steers {
                            _ = try await backend.reconcileSteer(submissionID: entry.message.id, runID: remote)
                        }
                        try await saveState()
                        print("PASS: durable checkpoint ready for independent restart")
                        fflush(stdout)
                        exit(0)
                    }
                    await transport.gate.open()
                }
            }
            if mode == "continue" {
                try await until { await events.text == "kept-workfollow-up" }
                try await controlRequest("/restart")
                let interrupted = try await run.value
                try check(await backend.snapshot.phase == "waiting_suspended", "server SIGKILL leaves explicit suspended run")
                let original = await transport.requests.first {
                    $0.url?.path.hasSuffix("/steer") == true
                }?.httpBody
                let result = try await backend.run(history: [initial] + interrupted
                    + [.init(role: .user, content: "explicit continuation")], config: config, tools: nil,
                    onEvent: { await events.receive($0) })
                let continuation = await transport.requests.last {
                    $0.url?.path.hasSuffix("/continue") == true
                }?.httpBody
                let before = try JSONDecoder().decode(JSONValue.self, from: original!)
                let after = try JSONDecoder().decode(JSONValue.self, from: continuation!)
                let restoredContent = after["history"]?.arrayValue?.first {
                    $0["id"]?.stringValue == first.id.uuidString
                }?["content"]
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try check(try encoder.encode(restoredContent) == encoder.encode(before["message"]?["content"]),
                          "explicit continue preserves original embedded reference bytes")
                try check(result.filter { $0.id == first.id }.count == 1, "explicit continue retains placed identity once")
                try await saveState(); return
            }
            let output = try await run.value
            let users = output.filter { $0.role == .user }
            try check(users.first?.id == first.id && Data(users.first?.content.utf8 ?? "".utf8) == Data(first.content.utf8),
                      "ordered SSE materializes exact original input")
            try check(output.first?.content == "kept-work" && output.last?.content == "follow-up",
                      "same run keeps prior output and performs real follow-up")
            let state = await backend.snapshot
            try check(state.steers.allSatisfy { $0.receipt?.state == .placed && $0.eventApplied },
                      "all placed inputs and cursor committed together")
            try check(await events.completions == 2, "no cancellation interrupts either assistant")
            if mode == "tools" { try check(output.map(\.role) == [.assistant, .tool, .tool, .user, .assistant],
                                          "input follows both real tool results") }
            if mode == "hold" { try check(output.map(\.role) == [.assistant, .user, .user, .assistant],
                                         "two submissions follow wire receipt order") }
            await gate.open()
            try await saveState()
        } catch {
            print("FAIL: \((error as? Failure)?.text ?? String(describing: error))")
            exit(1)
        }
    }
}
