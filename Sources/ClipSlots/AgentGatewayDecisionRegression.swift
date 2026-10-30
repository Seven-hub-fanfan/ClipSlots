#if DEBUG
import AppKit
import ClipSlotsKit

private actor AppDecisionTransport: AgentGatewayTransport {
    let network = URLSessionAgentGatewayTransport()
    let mode: String
    var posts = 0
    var reads = 0
    var posted = false
    var waiter: CheckedContinuation<Void, Never>?
    var requests: [URLRequest] = []
    init(_ mode: String) { self.mode = mode }
    func release() { waiter?.resume(); waiter = nil }
    func send(request: URLRequest) async throws -> AgentGatewayHTTPResponse {
        requests.append(request)
        if request.httpMethod == "GET", request.url?.path.contains("/interactions/") == true {
            reads += 1
            if ["saved", "preparesaved"].contains(mode), (2...3).contains(reads) {
                throw URLError(.networkConnectionLost)
            }
            if posts > 0 && mode == "prepare" { return .init(statusCode: 404) }
        }
        if request.httpMethod == "POST", request.url?.path.hasSuffix("/continue") == true {
            posts += 1
            if mode == "unknown" { throw URLError(.networkConnectionLost) }
            let response = try await network.send(request: request)
            posted = true
            if mode == "switch" { await withCheckedContinuation { waiter = $0 } }
            if mode == "prepare" { throw URLError(.networkConnectionLost) }
            return response
        }
        return try await network.send(request: request)
    }
    func stream(request: URLRequest) async throws -> AgentHTTPStream {
        if posts > 0 && mode == "disconnect" { throw URLError(.networkConnectionLost) }
        return try await network.stream(request: request)
    }
    func save(_ file: URL) throws {
        try JSONEncoder().encode(requests.map {
            ["method": $0.httpMethod ?? "", "url": $0.url?.absoluteString ?? "",
             "key": $0.value(forHTTPHeaderField: "Idempotency-Key") ?? "",
             "body": $0.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""]
        }).write(to: file, options: .atomic)
    }
}

@MainActor
func runGatewayDecisionRegression(directory: URL) async -> [String: Any] {
    _ = NSApplication.shared
    var checks: [String] = [], failures: [String] = []
    func check(_ value: Bool, _ label: String) {
        print("\(value ? "PASS" : "FAIL"): \(label)")
        if value { checks.append(label) } else { failures.append(label) }
    }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AgentGatewayError.interrupted
    }
    let mode = ProcessInfo.processInfo.environment["DECISION_APP_MODE"] ?? ""
    do {
        guard let text = ProcessInfo.processInfo.environment["DECISION_GATEWAY_URL"],
              let service = URL(string: text), service.host == "127.0.0.1" else {
            throw AgentGatewayError.invalidConfiguration
        }
        let file = directory.appendingPathComponent("decision-session.json")
        let runtime = directory.appendingPathComponent("decision-journal")
        let transport = AppDecisionTransport(mode)
        let model: AgentChatModel
        let gateway: AgentGatewayBackend
        if mode.hasPrefix("restore") {
            let saved = try JSONDecoder().decode(AgentChatModel.SavedSessions.self, from: Data(contentsOf: file))
            gateway = AgentGatewayBackend(baseURL: service, binding: .init(sessionID: saved.current.id.uuidString),
                journalRoot: runtime, apiKeyProvider: { "decision-client-auth" }, transport: transport,
                timing: .init(sleep: { _ in }, controlTimeout: 2))
            model = AgentChatModel(displayName: "Decision restore", backend: gateway, persistenceURL: file)
        } else {
            model = AgentChatModel(displayName: "Decision regression", persistenceURL: file)
            gateway = AgentGatewayBackend(baseURL: service, binding: .init(sessionID: model.selectedConversationID.uuidString),
                journalRoot: runtime, apiKeyProvider: { "decision-client-auth" }, transport: transport,
                timing: .init(sleep: { _ in }, controlTimeout: 2))
            model.setBackend(gateway, kind: .gateway)
        }
        let answer: JSONValue
        let params: JSONValue
        if mode == "batch" {
            params = ["items": [["index": 19, "action": "write_file", "allowedModifications": ["text"]],
                                ["index": 4, "action": "organize"]], "cost": ["summary": "Synthetic cost"]]
            answer = ["items": [["index": 19, "action": "write_file", "decision": "accept",
                                  "modifications": ["text": "修改🙂e\u{301}"]],
                                 ["index": 4, "action": "organize", "decision": "decline", "modifications": [:]]],
                      "costDecision": "decline"]
        } else if mode == "secret" {
            params = ["questions": [["id": "secret", "question": "Synthetic secret", "isSecret": true]]]
            answer = ["answers": ["secret": ["answers": ["synthetic-sensitive-🙂"]]]]
        } else {
            params = ["title": "Synthetic decision", "availableDecisions": ["accept", "decline"]]
            answer = ["decision": "accept"]
        }
        var config = AgentConfig(model: "synthetic", systemPrompt: "Synthetic only")
        config.supportsImageInput = false
        if mode.hasPrefix("restore") {
            try await wait { model.canResumeGateway && !model.pendingInteractions.isEmpty }
            guard let request = model.pendingInteractions.first else { throw AgentGatewayError.malformedPayload }
            let pending = mode == "restorepending", saved = mode == "restoresaved"
            check(request.state == (pending ? .pending : saved ? .saved : .syncing),
                  "App independent process restores original persistence boundary")
            let original = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent("original.json")))
            check(request.id.uuidString == original["id"]?.stringValue, "App process restart retains original local request identity")
            check(request.gatewayIdentity?.runID == original["runID"]?.stringValue, "App process restart retains original server run")
            if pending { check(!request.isPending && !model.isRunning, "restored pending requires fresh server time") }
            await model.reconcile(request)
            if pending || saved {
                let posts = await transport.posts
                check(!model.isRunning && posts == 0, "restored readback does not submit an answer")
                if pending {
                    check(request.isPending, "fresh readback enables restored original form")
                    await model.respond(to: request, result: answer)
                } else {
                    check(request.canSendSaved, "restored saved reply exposes explicit first dispatch")
                    await model.sendSaved(request)
                    await model.sendSaved(request)
                }
            }
            try await wait { !model.isRunning && model.runPhase == .applied }
            check(model.pendingInteractions.first?.state.accepted == true, "App accepted record remains visible after completion")
            check(await transport.posts == (pending || saved ? 1 : 0), "App restoration only dispatches explicit original answer")
        } else {
            let fixture: JSONValue = ["id": "app-confirm/a+汉", "ttl": 300,
                "kind": .string(mode == "secret" ? "waiting_question" : "waiting_confirmation"), "params": params]
            check(model.send(text: "test:decision:" + (try fixture.encodedText()), config: config, enabledSkills: []),
                  "App starts real synthetic gateway run")
            await model.debugWaitForRunCompletion()
            guard let request = model.pendingInteractions.first else { throw AgentGatewayError.malformedPayload }
            check(model.isRunning && model.runPhase == .waiting && request.isPending, "App waits for original server request")
            check(request.accepts(answer), "App original answer structure is valid")
            try JSONValue.object(["id": .string(request.id.uuidString),
                                  "runID": .string(request.gatewayIdentity!.runID)])
                .encodedText().write(to: directory.appendingPathComponent("original.json"), atomically: true, encoding: .utf8)
            if mode == "preparepending" {
                check(model.flushSession(), "App pending request persisted before independent process restart")
            } else if mode == "switch" {
                let response = Task { await model.respond(to: request, result: answer) }
                for _ in 0..<800 {
                    if await transport.posted { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                check(await transport.posted && request.state == .saving, "App has no acceptance claim before held response arrives")
                check(!model.messages.contains { $0.content.contains("已提交") || $0.content.contains("已允许") },
                      "App local queue is never summarized as server acceptance")
                let original = model.selectedConversationID
                model.clearHistory()
                await transport.release()
                await response.value
                check(model.selectedConversationID != original && model.pendingInteractions.isEmpty && model.messages.isEmpty,
                      "late original decision writes nothing to another session")
                check(await gateway.snapshot.interactions.first?.state.accepted == true,
                      "original journal retains accepted answer after session switch")
            } else {
                await model.respond(to: request, result: answer)
                if mode == "saved" || mode == "preparesaved" {
                    check(request.state == .saved && request.canSendSaved && model.runPhase == .waiting,
                          "App distinguishes saved unsent answer from attempted unknown")
                    check(await transport.posts == 0, "App preflight outage never dispatched saved answer")
                    if mode == "saved" {
                        await model.reconcile(request)
                        let posts = await transport.posts
                        check(request.state == .saved && posts == 0, "App readback cannot automatically send saved answer")
                        await model.sendSaved(request)
                        await model.sendSaved(request)
                        await model.debugWaitForRunCompletion()
                        check(model.runPhase == .applied && model.pendingInteractions.first?.state.accepted == true,
                              "App explicit saved-answer dispatch replays downstream completion")
                        check(await transport.posts == 1, "App saved-answer action cannot submit twice")
                    }
                } else if mode == "unknown" || mode == "prepare" {
                    check(request.state == .syncing && model.runPhase == .unknown,
                          "App unresolved reply displays syncing without stopping original task")
                    check(model.isRunning && model.canResumeGateway, "App unknown answer leaves original run recoverable")
                    await model.reconcile(request)
                    check(await transport.posts == 1, "App manual readback never repeats unknown reply")
                    if mode == "unknown" {
                        model.resumeGateway()
                        await model.debugWaitForRunCompletion()
                        check(model.runPhase != .applied && model.canResumeGateway,
                              "App pending readback cannot finalize unresolved original answer")
                    }
                } else {
                    await model.debugWaitForRunCompletion()
                    check(model.pendingInteractions.first?.state.accepted == true,
                          "App keeps accepted decision after downstream task ends")
                    if mode == "disconnect" {
                        check(model.runPhase == .unknown && model.canResumeGateway,
                              "App disconnect changes execution state without reversing acceptance")
                    } else {
                        check(model.runPhase == .applied && !model.isRunning, "App replays actual downstream completion")
                    }
                    check(await transport.posts == 1, "App acceptance sends exactly one answer")
                }
                check(!model.messages.contains { $0.isFailure && $0.content.contains("synthetic-sensitive") },
                      "App confirmation summaries never contain secret answers")
            }
            check(model.flushSession(), "App final session is persisted")
        }
        try await transport.save(directory.appendingPathComponent(mode + "-requests.json"))
    } catch { check(false, "App decision fixture: \(error.localizedDescription)") }
    return ["passed": checks.count, "checks": checks, "failures": failures,
            "gui": false, "remoteProviderRequests": 0, "mode": mode]
}
#endif
