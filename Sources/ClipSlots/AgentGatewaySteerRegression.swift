#if DEBUG
import AppKit
import ClipSlotsKit

private actor AppSteerTransport: AgentGatewayTransport {
    let network = URLSessionAgentGatewayTransport()
    var holdReceipt = false
    var posted = false
    var waiter: CheckedContinuation<Void, Never>?
    var requests: [URLRequest] = []
    func hold() { holdReceipt = true }
    func release() { holdReceipt = false; waiter?.resume(); waiter = nil }
    func send(request: URLRequest) async throws -> AgentGatewayHTTPResponse {
        requests.append(request)
        let response = try await network.send(request: request)
        if request.url?.path.hasSuffix("/steer") == true {
            posted = true
            if holdReceipt { await withCheckedContinuation { waiter = $0 } }
        }
        return response
    }
    func stream(request: URLRequest) async throws -> AgentHTTPStream { try await network.stream(request: request) }
    func save(_ file: URL) throws {
        try JSONEncoder().encode(requests.map {
            ["method": $0.httpMethod ?? "", "url": $0.url?.absoluteString ?? "",
             "key": $0.value(forHTTPHeaderField: "Idempotency-Key") ?? "",
             "body": $0.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""]
        }).write(to: file)
    }
}

@MainActor
func runGatewaySteerRegression(directory: URL) async -> [String: Any] {
    _ = NSApplication.shared
    var checks: [String] = [], failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL"): \(name)")
        if condition { checks.append(name) } else { failures.append(name) }
    }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AgentGatewayError.interrupted
    }
    let env = ProcessInfo.processInfo.environment
    do {
        guard let urlText = env["STEER_GATEWAY_URL"], let url = URL(string: urlText),
              url.host == "127.0.0.1", let controlText = env["STEER_CONTROL_URL"],
              let mode = env["STEER_APP_MODE"] else { throw AgentGatewayError.invalidConfiguration }
        let file = directory.appendingPathComponent("steer-session.json")
        let runtime = directory.appendingPathComponent("steer-journal")
        let transport = AppSteerTransport()
        let model: AgentChatModel
        let gateway: AgentGatewayBackend
        if mode == "restore" {
            let saved = try JSONDecoder().decode(AgentChatModel.SavedSessions.self, from: Data(contentsOf: file))
            gateway = AgentGatewayBackend(baseURL: url, binding: .init(sessionID: saved.current.id.uuidString),
                journalRoot: runtime, apiKeyProvider: { "live-auth" }, transport: transport)
            model = AgentChatModel(displayName: "Steer restore", backend: gateway, persistenceURL: file)
        } else {
            model = AgentChatModel(displayName: "Steer regression", persistenceURL: file)
            gateway = AgentGatewayBackend(baseURL: url, binding: .init(sessionID: model.selectedConversationID.uuidString),
                journalRoot: runtime, apiKeyProvider: { "live-auth" }, transport: transport)
            model.setBackend(gateway, kind: .gateway)
        }
        var config = AgentConfig(model: "synthetic", systemPrompt: "synthetic only")
        config.supportsImageInput = true
        let text = "追加要求🙂e\u{301}"
        let image = try AgentAttachmentImport.captureImage(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+afo0AAAAASUVORK5CYII=")!,
            name: "captured.png", path: directory.appendingPathComponent("deleted.png").path)
        let skill = AgentSkillReference(name: "资料", path: "/synthetic/SKILL.md", markdown: "保留原始输入🙂")
        let reference = AgentCanvasReference(projectID: "synthetic-reference", nodeID: "node",
            nodeCreatedAt: Date(timeIntervalSince1970: 100), groupID: "group", slot: 1,
            title: "明确引用", text: "捕获的正文", attachmentNames: [])
        let id: UUID
        if mode == "restore" {
            try await wait { model.canResumeGateway }
            guard let input = model.queuedSubmissions.first else { throw AgentGatewayError.malformedPayload }
            id = input.id
            check(input.text == text && input.hotReceipt?.state == .accepted, "App independent restart retains accepted queue")
            check(input.attachments?.first?.imageSnapshot == image.imageSnapshot && input.skillReferences == [skill]
                  && input.references == [reference], "App independent restart retains captured images and references")
            model.steerQueuedSubmission(id)
            try await wait { !model.isControllingRun }
            check(model.queuedSubmissions.count == 1 && model.messages.filter { $0.id == id }.isEmpty,
                  "App restored accepted input is still unconsumed")
            model.resumeGateway()
            try await wait { model.isRunning }
        } else {
            check(model.send(text: "synthetic initial", config: config, enabledSkills: []), "App starts actual gateway run")
            try await wait { model.streamingContent == "kept-work" && model.canHotSteer }
            model.draftAttachments = [image]; model.draftSkillReferences = [skill]; model.draftReferences = [reference]
            let queuedText = mode == "preflight" ? String(repeating: "界", count: 90_000) : text
            check(model.send(text: queuedText, config: config, enabledSkills: []), "App captures queued input during active run")
            guard let input = model.queuedSubmissions.first else { throw AgentGatewayError.malformedPayload }
            id = input.id
            if mode == "savefailure" {
                check(model.flushSession(), "App queue is persisted before save failure injection")
                let original = try Data(contentsOf: file)
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
                model.steerQueuedSubmission(id)
                check(!model.isControllingRun && model.queuedSubmissions.first?.hotRunID == nil,
                      "App session save failure leaves unsubmitted queue editable")
                check(model.queuePauseReason == "追加未提交，会话尚未保存；输入已保留。",
                      "App session save failure explains that no submission occurred")
                let requests = await transport.requests
                check(!requests.contains { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/steer") == true },
                      "App session save failure sends no steer POST")
                check(model.isRunning && model.streamingContent == "kept-work",
                      "App session save failure preserves running provider")
                try FileManager.default.removeItem(at: file)
                try original.write(to: file)
            }
            if mode == "preflight" {
                model.steerQueuedSubmission(id)
                try await wait { !model.isControllingRun }
                check(model.queuedSubmissions.first?.hotRunID == nil
                      && model.queuedSteerStatus(model.queuedSubmissions[0]) == nil,
                      "App oversized preflight input stays editable without unknown status")
                check(model.queuePauseReason == "追加未提交，输入已保留；请修改后再试。",
                      "App preflight failure says not submitted")
                check(model.isRunning && model.streamingContent == "kept-work",
                      "App preflight failure keeps current provider running")
                let requests = await transport.requests
                check(!requests.contains { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/steer") == true },
                      "App oversized preflight sends no steer POST")
                guard let remoteRun = model.gatewayRunID else { throw AgentGatewayError.malformedPayload }
                check(try await !gateway.hasSteerSubmission(submissionID: id, runID: remoteRun),
                      "App oversized preflight has no committed identity")
                model.editQueuedSubmission(id, text: text)
                check(model.queuedSubmissions.first?.id == id && model.queuedSubmissions.first?.text == text,
                      "App preflight input can be corrected with its original queue identity")
            }
            if mode == "switch" { await transport.hold() }
            model.steerQueuedSubmission(id)
            if mode == "switch" {
                for _ in 0..<400 {
                    if await transport.posted { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                check(await transport.posted, "App control request is durably accepted before session switch")
                let original = model.selectedConversationID
                model.clearHistory()
                await transport.release()
                try await Task.sleep(nanoseconds: 100_000_000)
                check(model.selectedConversationID != original && model.messages.isEmpty && model.queuedSubmissions.isEmpty,
                      "App old receipt writes nothing after session epoch changes")
                check(!model.isRunning && !model.isControllingRun, "App new session has no inherited control lifecycle")
                check(model.recentConversations.first?.queue?.first?.id == id,
                      "App archived conversation preserves unresolved exact submission")
            } else {
                try await wait { !model.isControllingRun && model.queuedSubmissions.first?.hotReceipt?.state == .accepted }
                check(model.isRunning && model.runPhase == .streaming, "App hot submission keeps existing task alive")
                check(model.messages.filter { $0.id == id }.isEmpty, "App accepted receipt is not shown as consumed")
                model.editQueuedSubmission(id, text: "不得覆盖"); model.moveQueuedSubmission(id, by: -1)
                model.removeQueuedSubmission(id)
                check(model.queuedSubmissions.first?.text == text && model.queuedSubmissions.first?.id == id,
                      "App accepted input cannot be edited, moved or removed")
                var other = config; other.model = "different"
                check(model.send(text: "changed config", config: other, enabledSkills: []), "App retains queue with different configuration")
                if let incompatible = model.queuedSubmissions.last, incompatible.id != id {
                    model.steerQueuedSubmission(incompatible.id)
                    check(model.queuedSubmissions.last?.hotRunID == nil && model.isRunning,
                          "App frozen model configuration prevents hot expansion")
                    model.removeQueuedSubmission(incompatible.id)
                }
                if mode == "prepare" {
                    check(model.flushSession(), "App accepted queue persisted before independent process exit")
                    try await transport.save(directory.appendingPathComponent("app-requests.json"))
                    return ["passed": checks.count, "checks": checks, "failures": failures, "gui": false,
                            "remoteProviderRequests": 0, "mode": mode]
                }
                if mode == "cancel" {
                    model.stop()
                    try await wait { !model.isControllingRun }
                    model.steerQueuedSubmission(id)
                    try await wait { !model.isControllingRun && model.queuedSubmissions.first?.hotReceipt?.state == .returned }
                    check(model.queuedSubmissions.first?.attachments?.first?.imageSnapshot == image.imageSnapshot,
                          "App cancel preserves original captured attachment")
                    model.restoreReturnedSteerDraft(id)
                    check(model.draft == text && model.draftAttachments == [image]
                          && model.draftReferences == [reference] && model.draftSkillReferences == [skill],
                          "App returned input restores complete draft and references")
                    check(model.queuedSubmissions.isEmpty && !model.isRunning, "App returned draft never automatically resubmits")
                }
            }
        }
        if ["session", "restore", "preflight", "savefailure"].contains(mode) {
            let network = URLSessionAgentGatewayTransport()
            let response = try await network.send(request: .init(url: URL(string: controlText + "/release")!))
            check(response.statusCode == 200, "App releases local synthetic provider")
            try await wait { !model.isRunning }
            check(model.queuedSubmissions.isEmpty && model.messages.filter { $0.id == id }.count == 1,
                  "App placement consumes queue exactly once")
            check(model.messages.map(\.role) == [.user, .assistant, .user, .assistant],
                  "App preserves actual assistant and user order")
            check(model.messages.first { $0.id == id }?.attachments?.first?.imageSnapshot == image.imageSnapshot,
                  "App placed message retains captured image after source removal")
            check(model.messages.contains { $0.content == "kept-work" }
                  && model.messages.last?.content == "follow-up", "App keeps prior work and actual follow-up result")
        }
        check(model.flushSession(), "App final session state is durable")
        try await transport.save(directory.appendingPathComponent(mode == "restore" ? "app-restore-requests.json" : "app-requests.json"))
    } catch { check(false, "App steer fixture: \(error.localizedDescription)") }
    return ["passed": checks.count, "checks": checks, "failures": failures, "gui": false,
            "remoteProviderRequests": 0, "mode": env["STEER_APP_MODE"] ?? ""]
}
#endif
