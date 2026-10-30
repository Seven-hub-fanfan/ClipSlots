import Foundation
import Darwin
@testable import ClipSlotsKit

private struct Failure: Error { let label: String }
private var assertions = 0
private func check(_ condition: Bool, _ label: String) throws {
    guard condition else { throw Failure(label: label) }
    assertions += 1
    print("PASS: \(label)")
}
private actor Events {
    var requests: [UUID: AgentInteraction] = [:]
    func receive(_ event: AgentRunEvent) {
        if case .interactionRequested(let request) = event { requests[request.id] = request }
    }
    var pending: AgentInteraction? { requests.values.first { $0.state == .pending } }
}
private actor Transport: AgentGatewayTransport {
    let network = URLSessionAgentGatewayTransport()
    let mode: String
    var posts = 0
    var reads = 0
    var requests: [URLRequest] = []
    init(_ mode: String) { self.mode = mode }
    func send(request: URLRequest) async throws -> AgentGatewayHTTPResponse {
        requests.append(request)
        if request.httpMethod == "GET", request.url?.path.contains("/interactions/") == true {
            reads += 1
            if ["preflight", "savedcrash", "savedexpire"].contains(mode), (2...3).contains(reads) {
                throw URLError(.networkConnectionLost)
            }
            if posts > 0 && mode == "unknown" { return .init(statusCode: 404) }
            if reads == 2 && mode == "expire" { try await Task.sleep(nanoseconds: 450_000_000) }
            let response = try await network.send(request: request)
            if reads >= 2 && mode == "malformed" {
                var body = try JSONDecoder().decode(JSONValue.self, from: response.body).objectValue!
                body["requestFingerprint"] = .string(String(repeating: "0", count: 64))
                return .init(statusCode: response.statusCode, body: try JSONEncoder().encode(JSONValue.object(body)))
            }
            return response
        }
        if request.httpMethod == "POST", request.url?.path.hasSuffix("/continue") == true {
            posts += 1
            if mode == "absent" { throw URLError(.networkConnectionLost) }
            if mode == "conflict" {
                var body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!).objectValue!
                body["requestKey"] = "another-reply"
                body["answerJSON"] = "{\"decision\":\"decline\"}"
                var other = request
                other.httpBody = try JSONEncoder().encode(JSONValue.object(body))
                other.setValue("another-reply", forHTTPHeaderField: "Idempotency-Key")
                _ = try await network.send(request: other)
            }
            let response = try await network.send(request: request)
            if mode == "crash" { kill(getpid(), SIGKILL); exit(3) }
            if mode == "loss" || mode == "unknown" { throw URLError(.networkConnectionLost) }
            return response
        }
        return try await network.send(request: request)
    }
    func stream(request: URLRequest) async throws -> AgentHTTPStream { try await network.stream(request: request) }
    func save(_ file: URL) throws {
        try JSONEncoder().encode(requests.map {
            ["method": $0.httpMethod ?? "", "url": $0.url?.absoluteString ?? "",
             "key": $0.value(forHTTPHeaderField: "Idempotency-Key") ?? "",
             "body": $0.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""]
        }).write(to: file, options: .atomic)
    }
}

@main private enum Main {
    static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        let mode = args[1], service = URL(string: args[2])!, root = URL(fileURLWithPath: args[3])
        guard service.host == "127.0.0.1", root.path.contains("clipslots-decision-client-") else { exit(2) }
        let transport = Transport(mode), events = Events()
        let binding = AgentRunBinding(sessionID: "decision-client", projectID: "synthetic", canvasID: "synthetic")
        let shift: Double = mode == "clockfast" ? 9_000_000_000 : mode == "clockslow" ? -9_000_000_000 : 0
        var backend = AgentGatewayBackend(baseURL: service, binding: binding, journalRoot: root.appendingPathComponent("journal"),
            apiKeyProvider: { "decision-client-auth" }, transport: transport,
            timing: .init(sleep: { _ in }, now: { Date().addingTimeInterval(shift) }, controlTimeout: 2))
        var config = AgentConfig(model: "synthetic", systemPrompt: "local decision tests")
        config.supportsImageInput = false
        if mode == "restore" || mode == "restoresaved" {
            let snapshot = await backend.snapshot
            let expected = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("before.json")))
            guard let request = snapshot.interactions.first else { throw Failure(label: "restored interaction") }
            try check(request.id.uuidString == expected["localID"]?.stringValue, "independent process restores original local identity")
            try check(request.gatewayIdentity?.runID == expected["runID"]?.stringValue, "independent process restores original run")
            if mode == "restoresaved" {
                try check(request.state == .saved && request.canSendSaved, "crash retains saved answer without an attempted POST")
                try check(try await request.reconcile() == .saved, "readback never automatically dispatches saved answer")
                try check(await transport.posts == 0, "fresh readback sends no answer")
                let writer = AgentGatewayJournalStore(baseURL: service, binding: binding, root: root.appendingPathComponent("journal"))
                let record = try writer.load().decisionRecords!["confirm/a+汉字"]!
                async let first = request.sendSavedResponse()
                async let second = request.sendSavedResponse()
                let dispatched = try await [first, second]
                try check(dispatched.filter { $0 }.count == 1, "concurrent explicit first dispatch claims saved answer once")
                let accepted = try writer.load().decisionRecords!["confirm/a+汉字"]!
                try check(record.submission == accepted.submission, "restored explicit dispatch retains original key and exact bytes")
                let posts = await transport.posts
                try check(request.state == .resolved && posts == 1, "saved answer accepts exactly one explicit dispatch")
            } else {
                try check(request.state == .syncing && !request.canSendSaved, "crash preserves attempted unknown reply")
                try check(try await request.reconcile() == .resolved, "readback confirms pre-crash server acceptance")
            }
            try check(!(try await request.respond(["decision": "decline"])), "restored accepted reply cannot be changed")
            _ = try await backend.resume(history: [], config: config, tools: nil, onEvent: { await events.receive($0) })
            try check(await backend.snapshot.interactions.first?.state.accepted == true, "accepted record survives terminal event replay")
            try check(await !backend.hasResumableRun, "completion resolves original run")
            try check(await transport.posts == (mode == "restoresaved" ? 1 : 0), "restart only dispatches an explicitly requested saved answer")
        } else {
            let params: JSONValue
            let answer: JSONValue
            if mode == "batch" || mode == "batchdecline" {
                params = ["title": "Synthetic batch", "items": [
                    ["index": 9, "action": "write_file", "allowedModifications": ["text"]],
                    ["index": 2, "action": "organize", "allowedModifications": ["target"]]],
                    "cost": ["summary": "Synthetic fee", "availableDecisions": ["accept", "decline"]]]
                answer = ["items": [
                    ["index": 9, "action": "write_file", "decision": .string(mode == "batch" ? "accept" : "decline"),
                     "modifications": mode == "batch" ? ["text": "中文🙂e\u{301}"] : [:]],
                    ["index": 2, "action": "organize", "decision": "decline", "modifications": [:]]],
                    "costDecision": .string(mode == "batch" ? "decline" : "accept")]
            } else if mode == "secret" {
                params = ["questions": [["id": "secret-q", "question": "Synthetic secret", "isSecret": true, "options": []]]]
                answer = ["answers": ["secret-q": ["answers": ["synthetic-secret-🙂e\u{301}"]]]]
            } else {
                params = ["title": "Synthetic confirmation", "availableDecisions": ["accept", "decline"]]
                answer = ["decision": "accept"]
            }
            let fixture: JSONValue = ["kind": .string(mode == "secret" ? "waiting_question" : "waiting_confirmation"),
                "id": "confirm/a+汉字", "ttl": .number(mode == "expire" || mode == "savedexpire" ? 0.35 : 300), "params": params]
            _ = try await backend.run(history: [.init(role: .user, content: "test:decision:" + fixture.encodedText())],
                config: config, tools: nil, onEvent: { await events.receive($0) })
            guard var request = await events.pending else { throw Failure(label: "pending request") }
            if mode == "pendingrestart" {
                let id = request.id
                backend = AgentGatewayBackend(baseURL: service, binding: binding,
                    journalRoot: root.appendingPathComponent("journal"), apiKeyProvider: { "decision-client-auth" },
                    transport: transport, timing: .init(sleep: { _ in }, controlTimeout: 2))
                request = await backend.snapshot.interactions.first!
                try check(request.id == id && !request.isPending, "restored pending request requires fresh server time")
                try check(try await request.reconcile() == .pending && request.isPending,
                          "fresh readback restores pending deadline without changing identity")
            }
            try check(request.isPending, "fresh server time enables original request")
            try check(request.gatewayIdentity?.interactionID == "confirm/a+汉字", "opaque original identity survives percent encoding")
            try check(request.accepts(answer), "structured answer matches original request")
            if mode == "batch" {
                var changed = answer.objectValue!
                changed["costDecision"] = nil
                try check(!request.accepts(.object(changed)), "operation decision cannot infer independent cost authorization")
                let originals = answer["items"]!.arrayValue!
                changed = answer.objectValue!; changed["items"] = .array(originals.reversed())
                try check(!request.accepts(.object(changed)), "batch reorder cannot substitute original identities")
                changed["items"] = .array([originals[0], originals[0]])
                try check(!request.accepts(.object(changed)), "duplicate batch item is rejected")
                var forbidden = originals[0].objectValue!
                forbidden["modifications"] = ["undeclared": "value"]
                changed["items"] = [.object(forbidden), originals[1]]
                try check(!request.accepts(.object(changed)), "undeclared batch modifications are rejected")
                var decline = originals[1].objectValue!; decline["modifications"] = ["target": "forbidden"]
                changed["items"] = [originals[0], .object(decline)]
                try check(!request.accepts(.object(changed)), "declined item cannot carry modifications")
            }
            let before: JSONValue = ["localID": .string(request.id.uuidString),
                "runID": .string(request.gatewayIdentity!.runID)]
            try before.encodedText().write(to: root.appendingPathComponent("before.json"), atomically: true, encoding: .utf8)
            if mode == "initialsave" {
                let count = await transport.requests.count
                await backend.debugSetDecisionJournalQuota(0)
                do {
                    _ = try await request.respond(answer)
                    throw Failure(label: "initial persistence must fail")
                } catch let error as AgentGatewayError {
                    try check(error == .decisionNotSaved, "initial quota failure reports known unsaved answer")
                }
                try check(request.state == .pending, "verified rollback keeps original form editable")
                try check(await transport.requests.count == count, "failed initial save invokes no network request")
                let writer = AgentGatewayJournalStore(baseURL: service, binding: binding, root: root.appendingPathComponent("journal"))
                let record = try writer.load().decisionRecords!["confirm/a+汉字"]!
                try check(record.submission == nil && !record.attempted && record.localID == request.id,
                          "independent journal reload proves no saved answer and original identity intact")
                await backend.debugSetDecisionJournalQuota(nil)
            }
            try check(try await request.respond(answer), "answer claimed once")
            try check(!(try await request.respond(answer)), "double click cannot send again")
            if ["preflight", "savedcrash", "savedexpire"].contains(mode) {
                try check(request.state == .saved && request.canSendSaved, "preflight failure preserves explicit first-dispatch action")
                try check(await transport.posts == 0, "preflight failure has never attempted answer POST")
                let writer = AgentGatewayJournalStore(baseURL: service, binding: binding, root: root.appendingPathComponent("journal"))
                let original = try writer.load().decisionRecords!["confirm/a+汉字"]!
                try check(original.submission != nil && !original.attempted, "saved journal distinguishes unsent from attempted unknown")
                if mode == "savedcrash" { kill(getpid(), SIGKILL); exit(3) }
                if mode == "savedexpire" { try await Task.sleep(nanoseconds: 450_000_000) }
                else {
                    _ = try await request.reconcile()
                    _ = try await backend.resume(history: [], config: config, tools: nil, onEvent: { await events.receive($0) })
                    try check(await transport.posts == 0, "resume and readback never dispatch saved answer automatically")
                }
                try check(try await request.sendSavedResponse(), "user explicitly dispatches original saved answer")
                let after = try writer.load().decisionRecords!["confirm/a+汉字"]!
                try check(original.submission == after.submission, "first dispatch preserves saved request key and full UTF-8 answer")
                try check(!(try await request.sendSavedResponse()), "saved button cannot repeat dispatch")
            }
            if mode == "absent" || mode == "unknown" || mode == "malformed" {
                try check(request.state == (mode == "malformed" ? .saved : .syncing), "persisted attempt state matches actual transport boundary")
                if mode != "malformed" {
                    try check(!(try await request.sendSavedResponse()), "attempted unknown exposes no first-dispatch action")
                }
                do { _ = try await request.reconcile() } catch { }
                let previousPosts = await transport.posts
                do { _ = try await backend.resume(history: [], config: config, tools: nil, onEvent: { await events.receive($0) }) }
                catch let error as AgentGatewayError {
                    try check(error == .decisionOutcomeUnknown || error == .originMismatch, "resume reports explicit unresolved decision")
                }
                try check(await transport.posts == previousPosts, "pending or 404 readback never automatically reposts")
                try check(await backend.hasResumableRun, "unknown original answer remains recoverable")
                if mode == "unknown" {
                    try check(await backend.snapshot.phase == "unknown", "missing decision readback is recoverable unknown, not blocked")
                    let diagnostics = try JSONDecoder().decode(AgentRunDiagnostics.self, from: await backend.exportDiagnostics())
                    try check(diagnostics.records.contains { $0.failure == .decisionUnknown && $0.outcome == .unknown },
                              "diagnostics classify unresolved decision separately from terminal failure")
                }
            } else if mode == "expire" || mode == "savedexpire" {
                try check(request.state == .expired, "server expiry prevents answer submission")
                try check(await transport.posts == 0, "expired preflight sends no POST")
            } else if mode == "conflict" {
                try check(request.state == .conflict, "another reply identity yields conflict")
                _ = try await request.reconcile()
                try check(request.state == .conflict, "conflict readback does not claim our answer")
            } else {
                try check(request.state == .resolved, "matching key and UTF-8 digest prove acceptance")
                _ = try await backend.resume(history: [], config: config, tools: nil, onEvent: { await events.receive($0) })
                try check(await backend.snapshot.interactions.first?.state.accepted == true, "downstream completion cannot reverse acceptance")
                try check(await !backend.hasResumableRun, "completed replay has no unresolved run")
            }
            if mode == "malformed" { try check(await transport.posts == 0, "wrong original fingerprint never submits") }
            else if mode != "expire" && mode != "savedexpire" { try check(await transport.posts == 1, "exactly one answer attempt") }
            let writer = AgentGatewayJournalStore(baseURL: service, binding: binding, root: root.appendingPathComponent("journal"))
            let journal = try writer.load()
            let record = journal.decisionRecords!["confirm/a+汉字"]!
            try check(record.submission?.answerJSON.utf8.elementsEqual(try answer.encodedText().utf8) == true,
                      "durable answer preserves full original UTF-8 bytes")
            try check(record.localID == request.id, "journal retains stable original identity")
            let diagnostic = String(decoding: try await backend.exportDiagnostics(), as: UTF8.self)
            try check(!diagnostic.contains("synthetic-secret") && !diagnostic.contains("decision-client-auth"),
                      "diagnostic export contains neither answer nor credential")
        }
        try await transport.save(root.appendingPathComponent(mode + "-requests.json"))
        let report: JSONValue = ["mode": .string(mode), "assertions": .number(Double(assertions)),
            "failures": 0, "answerPosts": .number(Double(await transport.posts)), "remoteProviderRequests": 0]
        try report.encodedText().write(to: root.appendingPathComponent(mode + "-report.json"), atomically: true, encoding: .utf8)
        print(try report.encodedText())
    }
}
