import Foundation
import ClipSlotsKit

private struct CheckFailure: Error { let message: String }

private final class LiveChecks {
    var cases = 0
    var assertions = 0
    var failures = 0

    func check(_ value: Bool, _ message: String) throws {
        assertions += 1
        if !value { throw CheckFailure(message: message) }
    }

    func test(_ name: String, _ body: () async throws -> Void) async {
        cases += 1
        do { try await body(); print("PASS: \(name)") }
        catch {
            failures += 1
            print("FAIL: \(name): \((error as? CheckFailure)?.message ?? String(describing: type(of: error)))")
        }
    }

    func expected(_ expected: AgentGatewayError, _ body: () async throws -> Void) async throws {
        do { try await body() }
        catch {
            try check(error as? AgentGatewayError == expected, "expected \(expected)")
            return
        }
        try check(false, "expected error, got success")
    }
}

private actor LiveEvents {
    var content = ""
    var reasoning = ""
    var completions = 0
    var artifacts = 0
    var usage = 0
    var toolCompleted = 0
    var canvasProposals = 0
    var notes: [String] = []
    var interaction: AgentInteraction?

    func receive(_ event: AgentRunEvent) {
        switch event {
        case .contentDelta(let delta): content += delta
        case .reasoningDelta(let delta): reasoning += delta
        case .assistantCompleted: completions += 1
        case .artifactUpdated: artifacts += 1
        case .usage: usage += 1
        case .toolCompleted: toolCompleted += 1
        case .canvasChanged: canvasProposals += 1
        case .note(let note): notes.append(note)
        case .interactionRequested(let value): interaction = value
        default: break
        }
    }
}

private final class LiveTools: AgentToolExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var executions = 0
    private let marker: URL?
    var count: Int { lock.withLock { executions } }

    init(marker: URL? = nil) {
        self.marker = marker
        if let marker, let data = try? Data(contentsOf: marker),
           let value = try? JSONDecoder().decode([String: Int].self, from: data) {
            executions = value["count"] ?? 0
        }
    }

    func specs() -> [AgentToolSpec] {
        [.init(name: "live_test_tool", description: "Synthetic test only",
               parameters: ["type": "object", "properties": [:]], originLabel: "TEST ONLY")]
    }

    func execute(call: AgentToolCall) async -> AgentToolResult {
        do {
            try lock.withLock {
                executions += 1
                if let marker {
                    try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try JSONEncoder().encode(["count": executions]).write(to: marker, options: .atomic)
                }
            }
        } catch { return .failure("Synthetic test marker unavailable.", code: "TEST_MARKER") }
        return .init(content: #"{"synthetic":true}"#, summary: "Synthetic test tool")
    }
}

private func until(_ condition: () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw CheckFailure(message: "bounded wait timed out")
}

private struct Environment {
    let root: URL
    let fault: URL
    let journal: URL
    let token: String
    let phase: String
    var config: AgentConfig {
        // Proves the gateway never derives its route from AgentConfig.endpoint.
        .init(endpoint: URL(string: "https://unused.invalid/never-call")!,
              model: "test", systemPrompt: "", maxToolRounds: 8)
    }

    func backend(_ name: String, authenticated: Bool = true, endpoint: URL? = nil) -> AgentGatewayBackend {
        let keyProvider: (@Sendable () -> String?)? = authenticated ? { @Sendable [token] in token } : nil
        return .init(baseURL: endpoint ?? root,
              binding: .init(sessionID: name, projectID: "p", canvasID: "c"),
              journalRoot: journal.appendingPathComponent(name),
              apiKeyProvider: keyProvider,
              transport: URLSessionAgentGatewayTransport(),
              timing: .init(sleep: { _ in try Task.checkCancellation() }))
    }
}

private func suite(_ env: Environment, _ checks: LiveChecks) async {
    await checks.test("real URLSession content, reasoning, metadata and durable snapshot") {
        let backend = env.backend("swift-metadata")
        let events = LiveEvents()
        let result = try await backend.run(history: [.init(role: .user, content: "test:metadata")],
            config: env.config, tools: nil) { await events.receive($0) }
        try checks.check(result.last?.content == "synthetic-local-http:test:metadata", "complete content")
        try checks.check(await events.completions == 1, "one assistant completion")
        try checks.check(await events.reasoning == "synthetic-reasoning", "reasoning deltas")
        let artifacts = await events.artifacts
        let usage = await events.usage
        try checks.check(artifacts == 1 && usage == 1, "metadata before terminal")
        let snapshot = await backend.snapshot
        try checks.check(snapshot.phase == "completed" && snapshot.cursor != nil, "committed completion cursor")
        let reload = env.backend("swift-metadata")
        let restored = await reload.snapshot
        try checks.check(restored.artifactUpdates.count == 1 && restored.messages == snapshot.messages,
                         "journal restored without a UI callback")
        try checks.check(!(await reload.hasResumableRun), "no false resumable after completion")
    }

    await checks.test("real SSE nested GROUP and typed edge proposal, duplicate receipt and local CAS") {
        var source = CanvasNode(pageId: "page", groupId: "storage", slot: 1, kind: .video, x: 40, y: 60)
        source.state = .succeeded(assetPath: "/fixture/draft.mp4")
        source.draftVideoID = "http-draft"
        source.duration = 6; source.ratio = "16:9"; source.generateAudio = false
        var target = CanvasNode(pageId: "page", groupId: "storage", slot: 2, kind: .video, x: 50, y: 70)
        target.draftReference = CanvasDraftReference(sourceNodeID: source.id, videoID: source.draftVideoID)
        target.duration = source.duration; target.ratio = source.ratio; target.generateAudio = source.generateAudio
        let parent = CanvasNodeGroup(id: "http-parent", nodeIDs: [source.id],
            containerFrame: CGRect(x: 100, y: 80, width: 2000, height: 1600), createdBy: .server)
        let child = CanvasNodeGroup(id: "http-child", nodeIDs: [target.id],
            containerFrame: CGRect(x: 400, y: 250, width: 800, height: 900),
            parentGroupID: parent.id, createdBy: .server)
        let prompt = CanvasEdge(id: "http-prompt", fromNodeId: source.id, toNodeId: target.id, role: .prompt)
        let reference = CanvasEdge(id: "http-reference", fromNodeId: source.id, toNodeId: target.id,
                                   purpose: .draftReference)
        let proposal = AgentCanvasMutation(projectID: "fixture", conversationID: "fixture",
            runID: "fixture", mutationID: "http-group-and-purpose",
            changes: [.init(before: nil, after: source), .init(before: nil, after: target)],
            addedEdges: [prompt, reference],
            groupChanges: [.init(before: nil, after: child), .init(before: nil, after: parent)],
            coordinateSpace: .parentLocal)
        let json = String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self)
        let backend = env.backend("swift-canvas-groups")
        let events = LiveEvents()
        _ = try await backend.run(history: [.init(role: .user, content: "test:canvas:" + json)],
                                  config: env.config, tools: nil) { await events.receive($0) }
        let run = await backend.snapshot
        let proposalEvents = await events.canvasProposals
        try checks.check(run.canvasMutations.count == 2 && proposalEvents == 2,
                         "duplicate SSE notifications delivered as proposals")
        guard let runID = run.runID else { throw CheckFailure(message: "real run identity missing") }
        let mutations = try run.canvasMutations.map {
            try JSONDecoder().decode(AgentCanvasMutation.self, from: JSONEncoder().encode($0))
        }
        try checks.check(mutations.allSatisfy {
            $0.runID == runID && $0.projectID == "p" && $0.conversationID == "swift-canvas-groups"
        }, "proposals bind to real persisted run and session")
        let empty = CanvasDocument()
        let plan = try AgentCanvasSync.plan(mutations[0], current: empty, expectedProject: "p",
            expectedConversation: "swift-canvas-groups", expectedRun: runID)
        try checks.check(plan.document.groups.first(where: { $0.id == child.id })?.containerFrame?.origin
                         == CGPoint(x: 500, y: 330), "parent-first GROUP world conversion after network decode")
        try checks.check(plan.document.nodes.first(where: { $0.id == source.id })?.frame.origin
                         == CGPoint(x: 140, y: 140) &&
                         plan.document.nodes.first(where: { $0.id == target.id })?.frame.origin
                         == CGPoint(x: 550, y: 400), "node local coordinates converted once")
        try checks.check(plan.document.edges == [prompt, reference] &&
                         plan.document.nodes.last?.draftReference == target.draftReference,
                         "both typed purposes and explicit draft params survive SSE")
        let storageRoot = env.journal.appendingPathComponent("canvas-cas")
        let storage = CanvasStorage(rootOverride: storageRoot)
        try checks.check(storage.save(empty, projectId: "p"), "empty graph stored before confirmation")
        try storage.saveComparingGraph(plan.document, expectedRevision: AgentCanvasSync.revision(empty), projectId: "p")
        let saved = CanvasStorage(rootOverride: storageRoot).load(projectId: "p")
        let replay = try AgentCanvasSync.plan(mutations[1], current: saved, expectedProject: "p",
            expectedConversation: "swift-canvas-groups", expectedRun: runID)
        try checks.check(replay.alreadyApplied && replay.document == saved, "duplicate notification cannot apply twice")
        let restored = await env.backend("swift-canvas-groups").snapshot
        try checks.check(restored.canvasMutations == run.canvasMutations, "restart restores complete GROUP proposal journal")
        var cyclic = saved.groups.first(where: { $0.id == parent.id })!
        let before = cyclic
        cyclic.parentGroupID = child.id
        let invalid = AgentCanvasMutation(projectID: "p", conversationID: "swift-canvas-groups",
            runID: runID, mutationID: "invalid-after-http", changes: [],
            groupChanges: [.init(before: before, after: cyclic)])
        do {
            _ = try AgentCanvasSync.plan(invalid, current: saved, expectedProject: "p",
                                        expectedConversation: "swift-canvas-groups", expectedRun: runID)
            throw CheckFailure(message: "invalid hierarchy accepted")
        } catch is AgentOperationError {
            try checks.check(CanvasStorage(rootOverride: storageRoot).load(projectId: "p") == saved,
                             "invalid hierarchy leaves confirmed disk graph intact")
        }
    }

    await checks.test("real SSE empty and oversized GROUP changes rejected before graph callbacks") {
        let oversized = (0...CanvasGroupHierarchy.maximumGroups).map { index in
            AgentCanvasMutation.GroupChange(before: nil,
                after: CanvasNodeGroup(id: "limit-\(index)", nodeIDs: [],
                    containerFrame: CGRect(x: 0, y: 0, width: 100, height: 100), createdBy: .server))
        }
        for (name, groups) in [("empty", [AgentCanvasMutation.GroupChange(before: nil, after: nil)]),
                               ("oversized", oversized)] {
            let mutation = AgentCanvasMutation(projectID: "fixture", conversationID: "fixture",
                runID: "fixture", mutationID: "invalid-\(name)", changes: [], groupChanges: groups)
            let json = String(decoding: try JSONEncoder().encode(mutation), as: UTF8.self)
            let backend = env.backend("swift-invalid-group-" + name)
            let events = LiveEvents()
            try await checks.expected(.malformedPayload) {
                _ = try await backend.run(history: [.init(role: .user, content: "test:canvas:" + json)],
                    config: env.config, tools: nil) { await events.receive($0) }
            }
            let callbacks = await events.canvasProposals
            let snapshot = await backend.snapshot
            try checks.check(callbacks == 0 && snapshot.canvasMutations.isEmpty,
                             "invalid GROUP never reaches confirmation or journal")
        }
    }

    await checks.test("real URLSession raw SSE replay with opaque percent-encoded cursor") {
        let backend = env.backend("swift-replay")
        _ = try await backend.run(history: [.init(role: .user, content: "test:plain")],
            config: env.config, tools: nil) { _ in }
        let snapshot = await backend.snapshot
        guard let run = snapshot.runID else { throw CheckFailure(message: "run missing") }
        let encoded = run.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let endpoint = URL(string: env.root.absoluteString + "/runs/" + encoded + "/events")!
        let transport = URLSessionAgentGatewayTransport()
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer " + env.token, forHTTPHeaderField: "Authorization")
        var framer = AgentSSEFramer()
        var frames: [AgentSSEFrame] = []
        let stream = try await transport.stream(request: request)
        for try await chunk in stream.chunks { frames += try framer.feed(chunk) }
        try checks.check(frames.first?.event == "initial" && frames.last?.event == "run_completed",
                         "real URLSession SSE frames")
        guard let cursor = frames[1].id else { throw CheckFailure(message: "cursor missing") }
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "cursor", value: cursor)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        request.url = parts.url
        request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID")
        framer = AgentSSEFramer()
        var replay: [AgentSSEFrame] = []
        let second = try await transport.stream(request: request)
        for try await chunk in second.chunks { replay += try framer.feed(chunk) }
        try checks.check(replay == Array(frames.dropFirst(2)), "byte-stable opaque replay")
    }

    await checks.test("real URLSession unauthenticated create rejected") {
        let backend = env.backend("swift-auth", authenticated: false)
        try await checks.expected(.http(401)) {
            _ = try await backend.run(history: [], config: env.config, tools: nil) { _ in }
        }
    }

    await checks.test("waiting continuation keeps immutable run binding") {
        let backend = env.backend("swift-continue")
        _ = try await backend.run(history: [.init(role: .user, content: "test:question")],
                                  config: env.config, tools: nil) { _ in }
        let before = await backend.snapshot
        try checks.check(before.phase == "waiting_question", "waiting state from SSE")
        _ = try await backend.run(history: [.init(role: .user, content: "continue")],
                                  config: env.config, tools: nil) { _ in }
        let after = await backend.snapshot
        try checks.check(after.runID == before.runID && after.phase == "completed", "continue not create")
        try checks.check(after.messages.last?.content == "synthetic-local-http:continue", "continued text")
    }

    await checks.test("interaction answer durably queues then sends on resume") {
        let backend = env.backend("swift-answer")
        let events = LiveEvents()
        _ = try await backend.run(history: [.init(role: .user, content: "test:confirmation")],
                                  config: env.config, tools: nil) { await events.receive($0) }
        guard let interaction = await events.interaction else { throw CheckFailure(message: "missing interaction") }
        let accepted = try await interaction.respond(["decision": "accept"])
        try checks.check(accepted, "valid approval response accepted")
        try checks.check(await backend.hasResumableRun, "answer remains durably queued")
        _ = try await backend.resume(history: [], config: env.config, tools: nil) { _ in }
        try checks.check(await backend.snapshot.phase == "completed", "answer completed over HTTP")
    }

    await checks.test("tool executes once across task termination and journal reconstruction") {
        let backend = env.backend("swift-tool-cache")
        let events = LiveEvents()
        let tools = LiveTools()
        let task = Task {
            try await backend.run(history: [.init(role: .user, content: "test:tool")],
                config: env.config, tools: tools) { event in
                    await events.receive(event)
                    if case .toolCompleted = event {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                }
        }
        try await until { await events.toolCompleted == 1 }
        task.cancel()
        do { _ = try await task.value; throw CheckFailure(message: "expected cancellation") }
        catch is CancellationError {}
        try checks.check(tools.count == 1, "exactly one execution before reconstruction")
        let client = await backend.snapshot.clientInstanceID
        let restored = env.backend("swift-tool-cache")
        let result = try await restored.resume(history: [], config: env.config, tools: tools) { _ in }
        try checks.check(tools.count == 1, "cached tool never re-executed")
        try checks.check(result.filter { $0.role == .tool }.count == 1, "one tool message")
        try checks.check(await restored.snapshot.clientInstanceID == client, "same durable target client")
        try checks.check(await restored.snapshot.phase == "completed", "tool result delivered and final text committed")
    }

    await checks.test("active cancellation confirms remote phase and steer readiness") {
        let backend = env.backend("swift-cancel")
        let events = LiveEvents()
        let task = Task {
            try await backend.run(history: [.init(role: .user, content: "test:slow")],
                config: env.config, tools: nil) { event in
                    await events.receive(event)
                    if case .contentDelta = event {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                }
        }
        try await until { !(await events.content.isEmpty) }
        await backend.cancelRun()
        _ = try? await task.value
        try checks.check(await backend.snapshot.phase == "cancelled", "queried remote cancellation")
        try checks.check(try await backend.waitUntilReadyToSteer(), "ready only after remote termination")
    }

    await checks.test("remote explicit failure is not synthetic completion") {
        let backend = env.backend("swift-failed")
        try await checks.expected(.remoteFailed) {
            _ = try await backend.run(history: [.init(role: .user, content: "test:fail")],
                                      config: env.config, tools: nil) { _ in }
        }
        try checks.check(await backend.snapshot.phase == "failed", "explicit failed phase")
    }

    let errors: [(String, AgentGatewayError)] = [
        ("bad-receipt", .malformedPayload), ("wrong-binding", .originMismatch),
        ("event-id-mismatch", .malformedPayload), ("bad-metadata", .malformedPayload),
        ("bad-usage", .malformedPayload), ("eof", .interrupted),
        ("incomplete", .interrupted), ("redirect", .http(307))
    ]
    for (name, expected) in errors {
        await checks.test("TEST-ONLY malformed HTTP service: \(name)") {
            let backend = env.backend("fault-" + name, endpoint: env.fault.appendingPathComponent(name))
            let events = LiveEvents()
            try await checks.expected(expected) {
                _ = try await backend.run(history: [], config: env.config, tools: nil) { await events.receive($0) }
            }
            try checks.check(await events.completions == 0, "no fabricated completion")
            try checks.check(await backend.hasResumableRun, "unknown or blocked run preserved")
        }
    }

    await checks.test("unknown event type commits only sanitized diagnostic") {
        let backend = env.backend("fault-unknown", endpoint: env.fault.appendingPathComponent("unknown"))
        let events = LiveEvents()
        _ = try await backend.run(history: [], config: env.config, tools: nil) { await events.receive($0) }
        let notes = await events.notes
        try checks.check(notes == ["Gateway ignored an unknown event type."], "no arbitrary diagnostic content")
        try checks.check(await backend.snapshot.phase == "completed", "unknown event does not execute an action")
    }
}

private func toolProcess(_ env: Environment, _ checks: LiveChecks, record: Bool) async {
    await checks.test(record ? "real Swift process records tool before HTTP result"
                            : "new Swift process delivers cached tool without re-execution") {
        let backend = env.backend("swift-process-tool")
        let tools = LiveTools(marker: env.journal.appendingPathComponent("tool-execution-count.json"))
        if record {
            let events = LiveEvents()
            let task = Task {
                try await backend.run(history: [.init(role: .user, content: "test:tool")],
                    config: env.config, tools: tools) { event in
                        await events.receive(event)
                        if case .toolCompleted = event {
                            try? await Task.sleep(nanoseconds: 60_000_000_000)
                        }
                    }
            }
            try await until { await events.toolCompleted == 1 }
            task.cancel()
            do { _ = try await task.value; throw CheckFailure(message: "expected cancellation") }
            catch is CancellationError {}
            try checks.check(tools.count == 1, "one durable test side effect")
            try checks.check(await backend.hasResumableRun, "cached result remains pending")
        } else {
            try checks.check(tools.count == 1, "side effect marker restored from earlier process")
            _ = try await backend.resume(history: [], config: env.config, tools: tools) { _ in }
            try checks.check(tools.count == 1, "new process did not invoke tool")
            try checks.check(await backend.snapshot.phase == "completed", "cached result acknowledged over HTTP")
        }
    }
}

private func crashRecord(_ env: Environment, _ checks: LiveChecks) async {
    await checks.test("cross-process crash record: cancel local reader only") {
        let backend = env.backend("swift-crash")
        let events = LiveEvents()
        let task = Task {
            try await backend.run(history: [.init(role: .user, content: "test:slow")],
                config: env.config, tools: nil) { event in
                    await events.receive(event)
                    if case .contentDelta = event {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                }
        }
        try await until { !(await events.content.isEmpty) }
        task.cancel()
        do { _ = try await task.value; throw CheckFailure(message: "expected cancellation") }
        catch is CancellationError {}
        let snapshot = await backend.snapshot
        try checks.check(snapshot.phase == "unknown", "no remote cancel was sent")
        try checks.check(snapshot.messages.last?.content == "before-crash", "reader stopped at committed cursor")
    }
}

private func crashReplay(_ env: Environment, _ checks: LiveChecks) async {
    await checks.test("real SQLite SIGKILL recovery replays unseen content before waiting") {
        let backend = env.backend("swift-crash")
        let result = try await backend.resume(history: [], config: env.config, tools: nil) { _ in }
        let snapshot = await backend.snapshot
        try checks.check(result.last?.content == "before-crashafter-disconnect", "unseen committed content replayed")
        try checks.check(snapshot.phase == "waiting_suspended", "explicit suspended event committed")
        try checks.check(snapshot.completedAssistantIDs.isEmpty, "crash is not assistant completion")
        _ = try await backend.resume(history: [], config: env.config, tools: nil) { _ in }
        try checks.check(await backend.snapshot.cursor == snapshot.cursor, "already committed suspended state is stable")
        _ = try await backend.run(history: result + [.init(role: .user, content: "explicit recovery")],
                                  config: env.config, tools: nil) { _ in }
        try checks.check(await backend.snapshot.phase == "completed", "explicit continue completes after crash")
        try checks.check(await backend.snapshot.runID == snapshot.runID, "continue retains original run")
    }
}

@main
private enum GatewayLiveMain {
    static func main() async {
        let values = ProcessInfo.processInfo.environment
        guard let text = values["CLIPSLOTS_LIVE_TEST_URL"], let root = URL(string: text),
              let faultText = values["CLIPSLOTS_LIVE_FAULT_URL"], let fault = URL(string: faultText),
              let path = values["CLIPSLOTS_LIVE_TEST_JOURNAL"],
              let token = values["CLIPSLOTS_LIVE_TEST_TOKEN"] else {
            print("Run via gateway/test_live.py --swift-bin, never against a production provider.")
            exit(2)
        }
        let env = Environment(root: root, fault: fault, journal: URL(fileURLWithPath: path),
                              token: token, phase: values["CLIPSLOTS_LIVE_TEST_PHASE"] ?? "suite")
        let checks = LiveChecks()
        switch env.phase {
        case "suite": await suite(env, checks)
        case "tool-record": await toolProcess(env, checks, record: true)
        case "tool-replay": await toolProcess(env, checks, record: false)
        case "crash-record": await crashRecord(env, checks)
        case "crash-replay": await crashReplay(env, checks)
        default: exit(2)
        }
        print("{\"swiftCases\":\(checks.cases),\"assertions\":\(checks.assertions),\"failures\":\(checks.failures)}")
        exit(checks.failures == 0 ? 0 : 1)
    }
}
