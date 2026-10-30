#if DEBUG
import AppKit
import WebKit
import SwiftUI
import ClipSlotsKit

private actor AppReplyPageTransport: AgentGatewayTransport {
    let network = URLSessionAgentGatewayTransport()
    var mode = ""
    var posts = 0
    var held = false
    var manifestHeld = false
    var waiter: CheckedContinuation<Void, Never>?
    var requests: [URLRequest] = []
    func setMode(_ value: String) { mode = value }
    func release() { waiter?.resume(); waiter = nil }
    func send(request: URLRequest) async throws -> AgentGatewayHTTPResponse {
        requests.append(request)
        if request.httpMethod == "POST", request.url?.path.hasSuffix("/tool-results") == true,
           mode == "tools-prepare" {
            _ = try await network.send(request: request)
            throw URLError(.networkConnectionLost)
        }
        if request.url?.path.hasSuffix("/app-reply-manifest") == true,
           mode == "permission" || mode == "lifecycle-pending" && !manifestHeld {
            let result = try await network.send(request: request)
            manifestHeld = true
            held = true
            await withCheckedContinuation { waiter = $0 }
            held = false
            return result
        }
        if request.httpMethod == "POST", request.url?.path.hasSuffix("/app-replies") == true {
            posts += 1
            if mode == "before" { throw URLError(.networkConnectionLost) }
            let result = try await network.send(request: request)
            if ["after", "prepare"].contains(mode) { throw URLError(.networkConnectionLost) }
            if mode == "session" {
                held = true
                await withCheckedContinuation { waiter = $0 }
            }
            return result
        }
        return try await network.send(request: request)
    }
    func stream(request: URLRequest) async throws -> AgentHTTPStream {
        requests.append(request)
        let stream = try await network.stream(request: request)
        if mode.hasPrefix("lifecycle-"), mode != "lifecycle-pending", posts > 0 {
            held = true
            await withCheckedContinuation { waiter = $0 }
            if mode == "lifecycle-unknown" {
                // Fault-injected frame after a real HTTP connection; it must not count as activity.
                let frame = Data("""
                    id: alien
                    event: content
                    data: {"schemaVersion":1,"eventID":"alien","binding":{"sessionID":"alien"},"runID":"alien","payload":{}}


                    """.utf8)
                return .init(statusCode: 200, chunks: AsyncThrowingStream { continuation in
                    continuation.yield(frame); continuation.finish()
                })
            }
        }
        return stream
    }
    func save(_ file: URL) throws {
        try JSONEncoder().encode(requests.map {
            ["method": $0.httpMethod ?? "", "url": $0.url?.absoluteString ?? "",
             "key": $0.value(forHTTPHeaderField: "Idempotency-Key") ?? "",
             "body": $0.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""]
        }).write(to: file, options: .atomic)
    }
}

/// Actual WKWebView -> AgentChatModel -> URLSession -> separate gateway process and SQLite.
@MainActor
func runAppReplyPageRegression(directory: URL) async -> [String: Any] {
    var checks: [String] = [], failures: [String] = []
    func check(_ value: Bool, _ name: String) {
        print("\(value ? "PASS" : "FAIL"): \(name)")
        (value ? checks.append(name) : failures.append(name))
    }
    func wait(_ predicate: () async -> Bool, count: Int = 1000) async throws {
        for _ in 0..<count {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentGatewayError.interrupted
    }
    let mode = ProcessInfo.processInfo.environment["APP_REPLY_PAGE_MODE"] ?? ""
    let transport = AppReplyPageTransport()
    let coordinator = AgentArtifactHTMLPreview.Coordinator()
    let web = AgentArtifactHTMLPreview.makeWebView(coordinator: coordinator)
    web.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = web
    defer {
        coordinator.detach(); web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        window.close()
    }
    var responses: [String: JSONValue] = [:]
    func evaluate(_ code: String) async -> JSONValue? {
        await withCheckedContinuation { continuation in
            web.evaluateJavaScript(code) { value, error in
                guard error == nil, let value,
                      let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                      let result = try? JSONDecoder().decode(JSONValue.self, from: bytes) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: result)
            }
        }
    }
    func promise(_ code: String) async throws -> JSONValue {
        let key = "r" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        _ = await evaluate("Promise.resolve(\(code)).then(x=>window['\(key)']=x).catch(x=>window['\(key)']={caught:String(x)}); null")
        try await wait { await evaluate("window['\(key)']") != nil }
        let result = await evaluate("window['\(key)']") ?? .null
        responses[code] = result
        return result
    }
    do {
        guard let text = ProcessInfo.processInfo.environment["APP_REPLY_PAGE_GATEWAY"],
              let endpoint = URL(string: text), endpoint.host == "127.0.0.1" else {
            throw AgentGatewayError.invalidConfiguration
        }
        let store = SlotStoreObservable()
        let canvas = CanvasStore(storage: CanvasStorage(rootOverride: directory.appendingPathComponent("canvas")),
            projectStorage: CanvasProjectStorage(rootOverride: directory.appendingPathComponent("canvas")))
        let file = directory.appendingPathComponent("agent-sessions/reply.json")
        let model = AgentChatModel(displayName: "App reply page", persistenceURL: file,
                                   canvasProjectID: canvas.activeProjectId)
        let project = canvas.activeProjectId
        model.canvasContext = CanvasAgentContext(canvas: canvas, store: store, projectID: project)
        let runtime = directory.appendingPathComponent("agent-runtime").appendingPathComponent(
            model.snapshot.runBindingID?.uuidString ?? "")
        let gatewayRoot = model.snapshot.run?.appReplyID.map {
            runtime.appendingPathComponent("app-reply-runs").appendingPathComponent($0)
        } ?? runtime
        let original = AgentGatewayBackend(baseURL: endpoint,
            binding: .init(sessionID: model.selectedConversationID.uuidString, projectID: project, canvasID: project),
            journalRoot: gatewayRoot, apiKeyProvider: { "app-reply-page-auth" }, transport: transport,
            timing: .init(sleep: { _ in }, controlTimeout: 2))
        model.setBackend(original, kind: .gateway)
        var config = AgentConfig(model: "synthetic", systemPrompt: "Synthetic only")
        config.supportsImageInput = false
        let restarting = ["restore", "tools-restore", "tools-restore-second",
                          "tools-restore-denied", "tools-restore-completed"].contains(mode)
        let toolMode = mode.hasPrefix("tools-")
        let secondReply = mode.contains("second") || mode.contains("denied")
        let deniedSecond = mode.contains("denied")
        let sideEffect = directory.appendingPathComponent("actual-side-effect.txt")
        if !restarting {
            if toolMode {
                model.selectAccessMode(.fullAccess)
                model.selectAutomaticApproval(true)
            }
            var app: JSONValue = ["artifactID": "app/汉字+opaque", "path": "apps/board.html", "revision": 1,
                "content": """
                <script>window.hostNotifications=[];window.addEventListener('message',e=>{
                  if(e.source===window&&e.data.clipslots_host&&e.data.method)window.hostNotifications.push(e.data)
                });</script><p>Native App reply test</p>
                """, "mimeType": "text/html",
                "pageProjection": ["schemaVersion": 1,
                    "revision": ["message_sequence": 2, "part_index": 1],
                    "toolInput": ["text": "原运行工具输入🙂e\u{301}", "media_ref": "private-reference"],
                    "toolResult": ["summary": "原运行工具结果🙂", "items": [1, .null, false]]],
                "appReplyManifest": ["schemaVersion": 1, "manifestRevision": .string(String(repeating: "a", count: 64)),
                                     "actions": ["previs_reply"]]]
            if toolMode && mode != "tools-changed" {
                var object = app.objectValue ?? [:]
                object["testFile"] = ["path": .string(sideEffect.path), "content": "original-file",
                                      "expected_sha256": ""]
                app = .object(object)
            }
            check(model.send(text: "test:app-artifact:" + (try app.encodedText()), config: config, enabledSkills: []),
                  "actual App starts original synthetic artifact run")
            await model.debugWaitForRunCompletion()
            check(model.runPhase == .applied && !model.isRunning, "original run completes before App reply")
        }
        try await wait { model.artifacts.first?.appReplyOrigin != nil }
        guard let record = model.artifacts.first, let origin = record.appReplyOrigin else {
            throw AgentAppReplyError.preflight
        }
        check(origin.authority.binding.sessionID == model.selectedConversationID.uuidString
              && origin.authority.path == record.key.path, "page authority comes from original native gateway event")
        check(record.pageProjection?.revision == (try AgentArtifactPageRevision(messageSequence: 2, partIndex: 1))
              && record.pageProjectionConversationID == model.selectedConversationID
              && record.pageProjectionRunID == origin.authority.originRunID,
              "real HTTP artifact event persists source projection under original native conversation and run")
        if toolMode {
            check(record.appReplyToolContext?.authority == origin.authority,
                  "actual artifact persists native original declarations for exact App revision")
            if mode == "tools-changed" { model.selectAutomaticApproval(false) }
        }
        if mode == "readonly" { model.selectAccessMode(.allDirectoriesReadOnly) }
        var identity = model.artifactPageIdentity(key: record.key, revision: record.revision)
        var ready = false
        func updatePage() async throws {
            let previousInstance = await evaluate("window.__clipslotsNativeInstance")
            identity = model.artifactPageIdentity(key: record.key, revision: record.revision)
            let page = identity
            ready = false
            coordinator.update(source: record.text ?? "", onState: { if $0 == .ready { ready = true } },
                onLink: { _ in }, onRequest: { operation, name, args in
                    try await model.artifactRequest(identity: page, operation: operation, name: name, arguments: args)
                }, identity: page, pageProjection: record.pageProjection, onReplyEvents: { replyID, runID in
                    try model.artifactReplyObservation(identity: page, replyID: replyID, runID: runID)
                }, conversationRunActive: model.artifactConversationRunActive)
            try await wait {
                let instance = await evaluate("window.__clipslotsNativeInstance")
                let initialize = await evaluate("typeof window.clipslots.initialize")
                return instance?.stringValue != nil && instance != previousInstance && initialize == "function"
            }
            let initResult = try await promise("clipslots.initialize()")
            check(initResult["result"]?["protocolVersion"] == "2026-01-26", "actual App reply page initializes")
            try await wait { ready }
            try await wait {
                await evaluate("window.hostNotifications.some(x=>x.method==='ui/notifications/tool-result')") == true
            }
            let input = await evaluate("window.hostNotifications.find(x=>x.method==='ui/notifications/tool-input').params")
            let result = await evaluate("window.hostNotifications.find(x=>x.method==='ui/notifications/tool-result').params")
            check(input == record.pageProjection?.inputParams && result == record.pageProjection?.resultParams(),
                  "actual WKWebView receives exact source projection restored through native model, HTTP and SQLite")
        }
        try await updatePage()
        let id: String
        if restarting {
            id = try String(contentsOf: directory.appendingPathComponent("reply-id.txt"), encoding: .utf8)
        } else {
            id = UUID().uuidString.lowercased()
            try id.write(to: directory.appendingPathComponent("reply-id.txt"), atomically: true, encoding: .utf8)
        }
        var details: JSONValue = ["type": "app_reply", "reply_id": .string(id), "action": "previs_reply",
            "payload": ["selection": "原始🙂e\u{301}", "slow": .bool(mode == "prepare"), "fail": .bool(mode == "failed")],
            "expected_manifest_revision": .string(origin.authority.manifestRevision)]
        if toolMode {
            var object = details.objectValue ?? [:]
            object["payload"] = ["write_file": ["path": .string(sideEffect.path), "content": "reply-file🙂",
                "expected_sha256": .string(mode == "tools-changed" ? "" : AgentDirectoryAccess.digest(Data("original-file".utf8)))],
                "call_id": "same-call-id"]
            details = .object(object)
        }
        let args = try details.encodedText()
        func pressRecovery(_ actionID: String) async throws {
            try await wait { model.appReplySnapshots.contains { $0.submission.replyID == id } }
            let page = identity
            var dispatched = false, finished = false, recoveryError = false
            let panel = AgentArtifactPanel(record: record, pageIdentity: page, onAction: { _ in }, onClose: {},
                replies: model.appReplies(for: record), onRecoverReply: { replyID, action in
                    dispatched = true
                    do {
                        _ = try await model.recoverArtifactAppReply(identity: page, replyID: replyID, action: action)
                    } catch { recoveryError = true }
                    finished = true
                })
            let host = NSHostingView(rootView: panel)
            let nativeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
                styleMask: [.titled], backing: .buffered, defer: false)
            nativeWindow.isReleasedWhenClosed = false
            nativeWindow.contentView = host
            defer { nativeWindow.close() }
            nativeWindow.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
                guard depth < 30 else { return [] }
                let children = node.accessibilityChildren?() ?? []
                let fallback = (node as? NSView)?.subviews ?? []
                return [node] + (children.isEmpty ? fallback : children).flatMap {
                    elements($0 as AnyObject, depth: depth + 1)
                }
            }
            func controls(_ view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(controls)
            }
            var button: NSButton?
            do {
                try await wait {
                    button = controls(host).first { $0.identifier?.rawValue == actionID }
                    return button != nil
                }
            } catch {
                let diagnostics = elements(host).map {
                    ["class": String(describing: type(of: $0)),
                     "identifier": $0.accessibilityIdentifier?() ?? "",
                     "label": $0.accessibilityLabel?() ?? ""]
                }
                try JSONEncoder().encode(diagnostics).write(to: directory.appendingPathComponent("recovery-button-diagnostic.json"))
                throw error
            }
            button?.performClick(nil)
            try await wait { finished }
            check(button != nil && dispatched, "actual native recovery button executes target/action press: \(actionID)")
            check(dispatched && !recoveryError, "actual native recovery button reaches bound model operation: \(actionID)")
        }
        if toolMode {
            if restarting {
                let posts = await transport.posts
                if mode == "tools-restore" {
                    try await wait { model.canResumeGateway }
                    model.resumeGateway()
                    await model.debugWaitForRunCompletion()
                } else { await model.debugHydrateContextUsage(from: original) }
                let restoredPosts = await transport.posts
                check(model.runPhase == .applied && restoredPosts == posts,
                      "independent actual App restores accepted tool result without resubmitting reply")
                if mode != "tools-restore" {
                    let saved = try JSONDecoder().decode([AgentMessage].self,
                        from: Data(contentsOf: directory.appendingPathComponent("tool-messages.json")))
                    check(model.messages == saved,
                          "independent App process retains exact message IDs, results and assistant associations")
                }
            } else {
                await transport.setMode(mode)
                let response = try await promise("clipslots.rpc('ui/message',{details:\(args)},'reply')")
                await model.debugWaitForRunCompletion()
                check(model.snapshot.run?.appReplyID == id
                      && response["result"]?["run_id"]?.stringValue == model.snapshot.run?.gatewayRunID,
                      "actual native session persists distinct reply tool owner from source receipt")
                check(model.runPhase == (mode == "tools-prepare" ? .unknown : .applied),
                      "reply tool run follows accepted or lost result HTTP outcome")
                if secondReply {
                    if deniedSecond {
                        model.selectAutomaticApproval(false)
                    }
                    let nextID = UUID().uuidString.lowercased()
                    let second: JSONValue = ["type": "app_reply", "reply_id": .string(nextID),
                        "action": "previs_reply", "payload": ["call_id": "same-call-id",
                            "write_file": ["path": .string(sideEffect.path), "content": "second-reply",
                                "expected_sha256": .string(AgentDirectoryAccess.digest(Data("reply-file🙂".utf8)))]]]
                    let another = try await promise("clipslots.rpc('ui/message',{details:\(try second.encodedText())},'second')")
                    await model.debugWaitForRunCompletion()
                    check(model.snapshot.run?.appReplyID == nextID
                          && another["result"]?["run_id"]?.stringValue == model.snapshot.run?.gatewayRunID
                          && model.runPhase == .applied,
                          "second actual reply has independent tool owner and same call ID remains usable")
                }
            }
            let lastReply = model.snapshot.run?.appReplyID ?? id
            let control = AgentGatewayBackend(baseURL: endpoint, binding: origin.authority.binding,
                journalRoot: runtime.appendingPathComponent("app-reply-runs").appendingPathComponent(lastReply),
                apiKeyProvider: { "app-reply-page-auth" }, transport: transport)
            await model.debugHydrateContextUsage(from: control)
            let content = try? String(contentsOf: sideEffect, encoding: .utf8)
            check(content == (mode == "tools-changed" ? nil : secondReply && !deniedSecond ? "second-reply" : "reply-file🙂"),
                  "real temporary file bytes match authorized original and reply side effects")
            if mode == "tools-changed" {
                check(model.messages.contains { $0.role == .tool && $0.content.contains("NOT_AUTHORIZED") },
                      "changed automatic-write declaration is rejected before execution")
            } else {
                let user = model.messages.first { $0.role == .user }?.id.uuidString ?? ""
                let executionJournal = AgentExecutionJournal(root: runtime)
                let originalReceipts = try executionJournal.records(scope: .init(
                    sessionID: model.selectedConversationID.uuidString, projectID: project, turnID: user))
                let replyReceipts = try executionJournal.records(scope: AgentAppReplyToolContext.executionScope(
                    binding: origin.authority.binding, replyID: id))
                check(originalReceipts.count == 1 && replyReceipts.count == 1
                      && originalReceipts.first?.callID == replyReceipts.first?.callID,
                      "same original and reply call ID has separate immutable execution receipts")
                let expected = secondReply && !deniedSecond
                    ? ["original-file", "reply-file🙂", "second-reply"] : ["original-file", "reply-file🙂"]
                let expectedCount = expected.count + (deniedSecond ? 1 : 0)
                let results = model.messages.filter { $0.role == .tool && $0.toolCallId == "same-call-id" }
                check(results.count == expectedCount,
                      "same call ID retains one native result for each original and reply execution")
                for content in expected {
                    let hash = AgentDirectoryAccess.digest(Data(content.utf8))
                    check(results.filter { $0.content.contains(hash) }.count == 1,
                          "native history retains exact independent file result: \(content)")
                }
                let assistants = model.messages.filter { $0.toolCalls.contains { $0.id == "same-call-id" } }
                check(assistants.count == expectedCount,
                      "all original and reply assistant tool calls remain in native history")
                let groups = model.transcript.compactMap { item -> [AgentToolActivity]? in
                    if case .tools(let rows) = item.kind { return rows }
                    return nil
                }
                check(groups.count == expectedCount && groups.allSatisfy { $0.count == 1 }
                      && groups.filter { $0.first?.state == .success }.count == expected.count
                      && groups.filter { $0.first?.state == .failure }.count == (deniedSecond ? 1 : 0),
                      "each original and reply assistant has an independently completed transcript row")
                for assistant in assistants {
                    let matched = results.filter { $0.toolOrigin?.assistantID == assistant.id }
                    check(matched.count == 1 && matched.first?.toolOrigin?.runID == assistant.runID
                          && matched.first?.toolOrigin?.scope == assistant.executionScope,
                          "native result retains exact run/scope and triggering assistant identity")
                    if let result = matched.first {
                        let call = assistant.toolCalls.first!
                        let requested = try call.arguments()["content"]?.stringValue ?? ""
                        check(result.isFailure ? deniedSecond && requested == "second-reply"
                              && result.content.contains("NOT_AUTHORIZED")
                              : result.content.contains(AgentDirectoryAccess.digest(Data(requested.utf8))),
                              "each transcript assistant is paired to its own success or denial result")
                    }
                }
                let wire = AgentService.requestBody(history: model.messages, config: config, tools: [], stream: false)
                let wireMessages = wire["messages"]?.arrayValue ?? []
                let calls = wireMessages.filter { $0["tool_calls"]?.arrayValue?.isEmpty == false }
                let toolResults = wireMessages.filter { $0["role"] == "tool" }
                check(calls.count == expectedCount && toolResults.count == expectedCount
                      && toolResults.allSatisfy { $0["tool_call_id"] == "same-call-id" },
                      "next provider history retains every assistant and unchanged original tool call ID")
                var pending: [String] = []
                var paired = true
                for message in wireMessages {
                    if let calls = message["tool_calls"]?.arrayValue {
                        if !pending.isEmpty { paired = false }
                        pending = calls.compactMap { $0["id"]?.stringValue }
                    }
                    if message["role"] == "tool", let call = message["tool_call_id"]?.stringValue {
                        if let index = pending.firstIndex(of: call) { pending.remove(at: index) }
                        else { paired = false }
                    }
                }
                check(paired && pending.isEmpty, "provider wire places every tool result after its original assistant call")
                try JSONEncoder().encode(model.messages).write(to: directory.appendingPathComponent("tool-messages.json"))
            }
        } else if restarting {
            try await wait { model.appReplySnapshots.contains { $0.submission.replyID == id } }
            let before = await transport.posts
            check(model.appReplySnapshots.first?.state == .unknown && before == 0,
                  "independent App restart discovers original unknown reply without POST")
            _ = try await model.recoverArtifactAppReply(identity: identity, replyID: id, action: .reconcile)
            check(await transport.posts == before && !model.isRunning, "restart readback only confirms original acceptance")
            _ = try await model.recoverArtifactAppReply(identity: identity, replyID: id, action: .attach)
            await model.debugWaitForRunCompletion()
            check(model.canResumeGateway && !model.isControllingRun, "accepted suspended run is attached without reapplying action")
            model.resumeGateway()
            await model.debugWaitForRunCompletion()
            check(model.runPhase == .applied && model.messages.contains { $0.content == "synthetic-app-reply-continuation" },
                  "explicit native resume uses dedicated continuation and finishes original run")
            check(await transport.posts == 0, "restart and continuation never POST the first reply again")
        } else if mode == "permission" {
            await transport.setMode(mode)
            let pending = Task { try await promise("clipslots.rpc('ui/message',{details:\(args)},'reply')") }
            try await wait { await transport.held }
            model.selectAccessMode(.allDirectoriesReadOnly)
            model.selectAccessMode(.fullAccess)
            await transport.release()
            let response = try await pending.value
            check(await transport.posts == 0 && response["error"]?["code"] == -32010,
                  "permission ABA during real manifest request rejects before health and POST")
            try await updatePage()
            await transport.setMode("")
            _ = try await model.recoverArtifactAppReply(identity: identity, replyID: id,
                action: .retry(expectedAttempt: 0))
            _ = try await model.recoverArtifactAppReply(identity: identity, replyID: id, action: .attach)
            await model.debugWaitForRunCompletion()
            check(await transport.posts == 1 && model.runPhase == .applied,
                  "explicit saved reply sends once under fresh native authority")
        } else if mode == "session" {
            await transport.setMode(mode)
            let pending = Task { try await promise("clipslots.rpc('ui/message',{details:\(args)},'reply')") }
            try await wait { await transport.held }
            let conversation = model.selectedConversationID
            model.clearHistory()
            await transport.release()
            let response = try await pending.value
            check(response["error"]?["code"] == -32012 && model.messages.isEmpty,
                  "accepted response from old session cannot adopt or write into new conversation")
            model.openConversation(id: conversation)
            try await wait { model.artifacts.first?.appReplyOrigin == origin }
            try await updatePage()
            await transport.setMode("")
            _ = try await model.recoverArtifactAppReply(identity: identity, replyID: id, action: .reconcile)
            _ = try await model.recoverArtifactAppReply(identity: identity, replyID: id, action: .attach)
            await model.debugWaitForRunCompletion()
            check(await transport.posts == 1 && model.runPhase == .applied,
                  "returning session explicitly reads and adopts original acceptance without second POST")
        } else if mode == "lifecycle-pending" {
            await transport.setMode(mode)
            let first = Task { try await promise("clipslots.rpc('ui/message',{details:\(args)},'first-pending')") }
            try await wait { await transport.held }
            let second = Task { try await promise("clipslots.rpc('ui/message',{details:\(args)},'second-pending')") }
            check(await transport.posts == 0, "concurrent source reply callers wait behind original manifest preflight")
            await transport.release()
            let result = try await first.value, repeated = try await second.value
            check(result["result"] == repeated["result"] && result["result"]?["run_id"] != nil,
                  "concurrent RPC IDs await one reply submission promise")
            await model.debugWaitForRunCompletion()
            check(await transport.posts == 1 && model.runPhase == .applied,
                  "concurrent pending reply performs exactly one actual HTTP POST and one native run")
            try await wait {
                await evaluate("window.hostNotifications.some(x=>x.method==='tapnow/appReplyStatus')") == true
            }
            let completions = await evaluate("window.hostNotifications.filter(x=>x.method==='tapnow/appReplyStatus').length")
            check(completions == 1, "concurrent RPC callers install exactly one completion observation")
            responses["lifecycle-notifications"] = await evaluate("window.hostNotifications") ?? .null
        } else if mode.hasPrefix("lifecycle-") {
            await transport.setMode(mode)
            let response = try await promise("clipslots.rpc('ui/message',{details:\(args)},'reply')")
            try await wait { await transport.held }
            check(Set(response["result"]?.objectValue?.keys.map { $0 } ?? []) == ["reply_id", "run_id", "deduped"],
                  "accepted receipt contains source identity only while real HTTP stream is held")
            let before = await evaluate("window.hostNotifications")?.arrayValue ?? []
            responses["lifecycle-held"] = .array(before)
            check(!before.contains { $0["params"]?["reply_run_status"] != nil || $0["method"] == "tapnow/appReplyStatus" },
                  "HTTP receipt and local streaming phase do not resolve activity or completion promises")
            let duplicate = try await promise("clipslots.rpc('ui/message',{details:\(args)},'reply')")
            check(await transport.posts == 1 && duplicate == response,
                  "same RPC result is cached without a second POST or a second lifecycle subscription")
            let repeatedReply = try await promise("clipslots.rpc('ui/message',{details:\(args)},'same-reply-new-rpc')")
            check(await transport.posts == 1 && repeatedReply["result"] == response["result"],
                  "new RPC ID reuses original reply promise while its accepted run is active")
            var conflicting = details.objectValue ?? [:]
            conflicting["payload"] = ["selection": "different"]
            let conflict = try await promise("clipslots.rpc('ui/message',{details:\(try JSONValue.object(conflicting).encodedText())},'conflicting-reply')")
            check(await transport.posts == 1 && conflict["error"]?["code"] == -32010,
                  "same reply ID with changed bytes cannot borrow cached acceptance or repeat POST")
            let run = response["result"]?["run_id"]?.stringValue ?? ""
            let readback = try await promise("clipslots.rpc('tapnow/getAppReplyRunStatus',{run_id:\(try JSONValue.string(run).encodedText())})")
            check(readback["result"]?["status"] == "inactive",
                  "independent run readback can report terminal without inventing stream activity")
            check(await evaluate("window.hostNotifications.some(x=>x.params?.reply_run_status)") == false,
                  "status readback does not resolve the running promise")
            if mode == "lifecycle-close" {
                coordinator.detach()
            } else if mode == "lifecycle-reload" {
                let prior = await evaluate("window.__clipslotsNativeInstance")
                ready = false
                web.reload()
                try await wait {
                    let instance = await evaluate("window.__clipslotsNativeInstance")
                    let initialize = await evaluate("typeof window.clipslots.initialize")
                    return instance?.stringValue != nil && instance != prior
                        && initialize == "function"
                }
                _ = try await promise("clipslots.initialize()")
                try await wait { ready }
            } else if mode == "lifecycle-session" {
                model.clearHistory()
            }
            await transport.release()
            await model.debugWaitForRunCompletion()
            if ["lifecycle-close", "lifecycle-reload", "lifecycle-session"].contains(mode) {
                let notifications = await evaluate("window.hostNotifications")?.arrayValue ?? []
                responses["lifecycle-notifications"] = .array(notifications)
                check(!notifications.contains { $0["params"]?["reply_id"] == .string(id) },
                      "closed replaced or cross-session document receives no old reply lifecycle notification")
                if mode == "lifecycle-session" {
                    check(model.messages.isEmpty, "late accepted stream cannot write another conversation")
                } else {
                    check(model.runPhase == .applied, "page disposal cancels observation while native run finishes")
                }
            } else {
                try await wait {
                    await evaluate("window.hostNotifications.some(x=>x.method==='tapnow/appReplyStatus')") == true
                }
                let notifications = await evaluate("window.hostNotifications")?.arrayValue ?? []
                let runStates = notifications.filter { $0["params"]?["reply_id"] == .string(id)
                    && $0["params"]?["reply_run_status"] != nil }.compactMap { $0["params"]?["reply_run_status"]?.stringValue }
                let outcomes = notifications.filter { $0["method"] == "tapnow/appReplyStatus"
                    && $0["params"]?["reply_id"] == .string(id) }.compactMap { $0["params"]?["status"]?.stringValue }
                check(runStates == (mode == "lifecycle-unknown" ? ["unknown"] : ["running", "completed"]),
                      "validated real stream resolves activity once while foreign frame preserves unknown")
                check(outcomes == [mode == "lifecycle-unknown" ? "unknown" : "applied"],
                      "completion outcome is delivered once and never guesses success after invalid SSE")
                let active = notifications.compactMap { $0["params"]?["conversation_run_active"]?.boolValue }
                check(active == [false, true, false], "page receives source conversation activity before and after run")
                responses["lifecycle-notifications"] = .array(notifications)
            }
            check(await transport.posts == 1, "lifecycle and readback never repeat structured reply submission")
        } else {
            let validation = try await promise("clipslots.rpc('tapnow/validateAppReply',\(args))")
            check(validation["error"]?["code"] == (mode == "readonly" ? -32010 : nil)
                  && (mode == "readonly" || validation["result"]?["manifest_revision"] == .string(origin.authority.manifestRevision)),
                  "native projection validates actual manifest or enforces read-only permission")
            await transport.setMode(mode)
            let response = try await promise("clipslots.rpc('ui/message',{details:\(args)},'reply')")
            if mode == "readonly" {
                check(await transport.posts == 0 && response["error"]?["code"] == -32010,
                      "read-only actual page cannot submit App reply")
            } else if ["before", "after", "prepare"].contains(mode) {
                check(response["error"]?["code"] == -32012, "actual page classifies lost reply outcome as unknown")
                let repeated = try await promise("clipslots.rpc('ui/message',{details:\(args)},'another-rpc-id')")
                check(await transport.posts == 1 && repeated["error"]?["code"] == -32012,
                      "new RPC id cannot automatically resend attempted original reply")
                if mode != "prepare" {
                    await transport.setMode("")
                    if mode == "before" {
                        do {
                            _ = try await model.recoverArtifactAppReply(identity: identity, replyID: id, action: .reconcile)
                            check(false, "404 remains unknown")
                        } catch { check(await transport.posts == 1, "404 remains unknown and never resubmits") }
                        _ = try await model.recoverArtifactAppReply(identity: identity, replyID: id,
                            action: .retry(expectedAttempt: 1))
                    } else {
                        try await pressRecovery("agent-app-reply-reconcile")
                    }
                    if mode == "after" {
                        try await wait { model.appReplySnapshots.first(where: { $0.submission.replyID == id })?.state == .accepted }
                        try await pressRecovery("agent-app-reply-attach")
                    } else {
                        _ = try await model.recoverArtifactAppReply(identity: identity, replyID: id, action: .attach)
                    }
                    await model.debugWaitForRunCompletion()
                    check(await transport.posts == (mode == "before" ? 2 : 1) && model.runPhase == .applied,
                          "native explicit recovery adopts exact accepted run and renders SSE output")
                }
            } else {
                check(Set(response["result"]?.objectValue?.keys.map { $0 } ?? []) == ["reply_id", "run_id", "deduped"]
                      && response["result"]?["reply_id"] == .string(id),
                      "actual page receives only source acceptance identity envelope")
                await model.debugWaitForRunCompletion()
                try await wait {
                    await evaluate("window.hostNotifications.some(x=>x.method==='tapnow/appReplyStatus')") == true
                }
                check(model.runPhase == (mode == "failed" ? .failed : .applied),
                      "App reply execution phase follows real terminal event")
                let lifecycle = await evaluate("window.hostNotifications") ?? .null
                responses["lifecycle-notifications"] = lifecycle
                let notifications = lifecycle.arrayValue ?? []
                check(notifications.contains { $0["method"] == "tapnow/updateData"
                    && $0["params"]?["reply_id"] == .string(id)
                    && $0["params"]?["reply_run_status"] == "running" },
                    "real SSE activity notifies page that exact reply run is running")
                check(notifications.contains { $0["method"] == "tapnow/updateData"
                    && $0["params"]?["reply_id"] == .string(id)
                    && $0["params"]?["reply_run_status"] == .string(mode == "failed" ? "failed" : "completed") },
                    "real SSE terminal notifies exact page reply run status")
                check(notifications.contains { $0["method"] == "tapnow/appReplyStatus"
                    && $0["params"]?["reply_id"] == .string(id)
                    && $0["params"]?["status"] == .string(mode == "failed" ? "failed" : "applied") },
                    "page receives source completion outcome independently of acceptance")
                if mode == "failed" {
                    check(!model.canResumeGateway, "confirmed terminal business failure has no resumable-run control")
                }
                if mode != "failed" {
                    check(model.messages.filter { $0.content == "synthetic-structured-app-reply" }.count == 1,
                          "actual reply SSE persists one assistant message")
                }
                if let run = response["result"]?["run_id"]?.stringValue {
                    let status = try await promise("clipslots.rpc('tapnow/getAppReplyRunStatus',{run_id:\(try JSONValue.string(run).encodedText())})")
                    check(status["result"]?["status"] == "inactive",
                          "actual page recovery returns source inactive status for known terminal run")
                }
                let alien = try await promise("clipslots.rpc('tapnow/getAppReplyRunStatus',{run_id:'another-run'})")
                check(alien["error"]?["code"] == -32010, "page cannot select an unrelated recovery run")
            }
        }
        check(model.messages.filter { $0.role == .user }.count <= 1,
              "structured reply never becomes a replacement chat user message")
        check(model.flushSession() && canvas.flushSave(), "native conversation and canvas persist in private fixture")
        try await transport.save(directory.appendingPathComponent("wire.json"))
    } catch { failures.append("actual App reply fixture: \(error)") }
    try? JSONEncoder().encode(responses).write(to: directory.appendingPathComponent("rpc-responses.json"))
    return ["mode": mode, "passed": checks.count, "checks": checks, "failures": failures,
            "actualWebKit": true, "actualNativeModel": true, "actualHTTP": true,
            "remoteProviderRequests": 0, "foregroundAccepted": false, "M06Accepted": false, "goalComplete": false]
}
#endif
