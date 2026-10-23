import Foundation

/// Adapter for a self-owned service implementing the gateway v1 contract.
/// It never infers routes or credentials from AgentConfig.endpoint.
public actor AgentGatewayBackend: AgentGatewayResuming {
    private let baseURL: URL
    private let binding: AgentRunBinding
    private let transport: any AgentGatewayTransport
    private let timing: AgentGatewayTiming
    private let apiKeyProvider: (@Sendable () -> String?)?
    private let store: AgentGatewayJournalStore
    private var journal: AgentGatewayJournal
    private var loadFailed = false
    private var operation: Task<[AgentMessage], Error>?
    private var busy = false
    private var controlling = false

    public init(baseURL: URL, binding: AgentRunBinding, journalRoot: URL,
                apiKeyProvider: (@Sendable () -> String?)? = nil) {
        self.init(baseURL: baseURL, binding: binding, journalRoot: journalRoot,
                  apiKeyProvider: apiKeyProvider, transport: URLSessionAgentGatewayTransport())
    }

    public init(baseURL: URL, binding: AgentRunBinding, journalRoot: URL,
                apiKeyProvider: (@Sendable () -> String?)? = nil,
                transport: any AgentGatewayTransport, timing: AgentGatewayTiming = .init()) {
        self.baseURL = baseURL
        self.binding = binding
        self.apiKeyProvider = apiKeyProvider
        self.transport = transport
        self.timing = timing
        let store = AgentGatewayJournalStore(baseURL: baseURL, binding: binding, root: journalRoot)
        self.store = store
        do { journal = try store.load() }
        catch {
            journal = .init(origin: store.origin, binding: binding, clientInstanceID: UUID().uuidString)
            loadFailed = true
        }
    }

    public var hasResumableRun: Bool {
        // Corruption must not make the host overwrite an unresolved run.
        if loadFailed { return true }
        do { return try store.load().resumable }
        catch { return true }
    }

    public var clientInstanceID: String { journal.clientInstanceID }

    public var snapshot: AgentGatewayRunSnapshot {
        .init(binding: binding, runID: journal.runID, phase: journal.phase, cursor: journal.cursor,
              messages: journal.messages, clientInstanceID: journal.clientInstanceID,
              currentAssistantID: journal.currentAssistantID,
              completedAssistantIDs: journal.completedAssistantIDs,
              artifactUpdates: journal.artifactUpdates ?? [], canvasMutations: journal.canvasMutations ?? [])
    }

    /// Fresh read-only invocations must not consume the conversation journal.
    /// The host owns the supplied temporary directory's lifecycle.
    public func isolatedBackend(journalRoot: URL) -> AgentGatewayBackend {
        .init(baseURL: baseURL, binding: .init(sessionID: "isolated-\(UUID().uuidString)"),
              journalRoot: journalRoot, apiKeyProvider: apiKeyProvider, transport: transport, timing: timing)
    }

    @discardableResult
    public func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
                    onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        try await invoke(resuming: false, history: history, config: config, tools: tools, onEvent: onEvent)
    }

    @discardableResult
    public func resume(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
                       onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        try await invoke(resuming: true, history: history, config: config, tools: tools, onEvent: onEvent)
    }

    private func validateConfiguration() throws {
        guard AgentGatewayPreferences.credentialOrigin(url: baseURL) != nil,
              !binding.sessionID.isEmpty,
              binding.projectID.map({ !$0.isEmpty }) ?? true,
              binding.canvasID.map({ !$0.isEmpty }) ?? true else {
            throw AgentGatewayError.invalidConfiguration
        }
    }

    private func invoke(resuming: Bool, history: [AgentMessage], config: AgentConfig,
                        tools: AgentToolExecuting?,
                        onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        try AgentAttachmentImport.validateImageSupport(history: history, supported: config.supportsImageInput == true)
        guard !busy, !controlling else { throw AgentGatewayError.busy }
        try validateConfiguration()
        let lock = try store.acquire()
        defer { store.release(lock) }
        if FileManager.default.fileExists(atPath: store.file.path) { journal = try store.load() }
        loadFailed = false
        if resuming {
            guard journal.resumable else { throw AgentGatewayError.noResumableRun }
        } else {
            if journal.resumable {
                guard journal.phase.hasPrefix("waiting"), journal.command == nil,
                      let runID = journal.runID else { throw AgentGatewayError.resumableRunExists }
                journal.command = try command(path: ["runs", runID, "continue"],
                                              history: history, config: config, tools: tools)
                journal.phase = "starting"
            } else {
                journal = .init(origin: store.origin, binding: binding,
                                clientInstanceID: journal.clientInstanceID)
                journal.command = try command(path: ["runs"], history: history, config: config, tools: tools)
                journal.phase = "starting"
            }
            journal.allowsTools = !config.isolatedReadOnly
            journal.toolNames = Set((config.isolatedReadOnly ? [] : tools?.specs() ?? []).map(\.name))
            journal.toolLimit = config.maxToolRounds
            try store.save(journal)
        }
        busy = true
        defer { busy = false; operation = nil }
        let task = Task { try await self.perform(config: config, tools: tools, onEvent: onEvent) }
        operation = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func command(path: [String], history: [AgentMessage], config: AgentConfig,
                         tools: AgentToolExecuting?) throws -> AgentGatewayCommand {
        let messages: [JSONValue] = try history.filter(\.isWireVisible).map { message in
            // Local attachment paths and endpoint credentials do not belong in
            // this contract. Authorized textual references use wireContent.
            var fields: [String: JSONValue] = [
                "id": .string(message.id.uuidString), "role": .string(message.role.rawValue),
                "content": message.wirePayload(supportsImages: config.supportsImageInput == true),
                "toolCallID": message.toolCallId.map(JSONValue.string) ?? .null
            ]
            if !config.isolatedReadOnly {
                guard message.toolCalls.count <= 20 else { throw AgentGatewayError.malformedPayload }
                fields["toolCalls"] = .array(try message.toolCalls.map { call in
                    guard !call.id.isEmpty, call.id.utf8.count <= 1024,
                          !call.name.isEmpty, call.name.utf8.count <= 256,
                          call.argumentsJSON.utf8.count <= 1_048_576,
                          try call.arguments().objectValue != nil else { throw AgentGatewayError.malformedPayload }
                    return .object(["id": .string(call.id), "name": .string(call.name),
                                    "argumentsJSON": .string(call.argumentsJSON)])
                })
            }
            return .object(fields)
        }
        let key = UUID().uuidString
        let bindingValue = try value(binding)
        let body: JSONValue = .object([
            "schemaVersion": 1, "requestKey": .string(key), "binding": bindingValue,
            "clientInstanceID": .string(journal.clientInstanceID),
            "history": .array(messages),
            "config": .object(["model": .string(config.model), "systemPrompt": .string(config.systemPrompt),
                               "thinkingMode": .string(config.thinkingMode.rawValue),
                               "taskPolicy": .string(config.taskPolicy.rawValue),
                               "maxToolRounds": .number(Double(config.maxToolRounds))]),
            "tools": .array(config.isolatedReadOnly ? [] : (tools?.specs() ?? []).map(\.wireValue))
        ])
        return .init(key: key, path: path, body: body, attempted: false)
    }

    private func perform(config: AgentConfig, tools: AgentToolExecuting?,
                         onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        var retries = 0
        do {
            while true {
                try Task.checkCancellation()
                do {
                    try await resolveCommand()
                    guard let runID = journal.runID else { throw AgentGatewayError.malformedPayload }
                    let descriptor = try await query(runID)
                    if descriptor.phase == "cancelled" {
                        try setPhase("cancelled")
                        await publishState(onEvent)
                        return journal.messages
                    }
                    if descriptor.phase == "failed" {
                        try setPhase("failed")
                        await publishState(onEvent)
                        throw AgentGatewayError.remoteFailed
                    }
                    if !journal.tools.isEmpty { try await deliverTools(config: config, executor: tools, onEvent: onEvent) }
                    if descriptor.phase.hasPrefix("waiting"),
                       journal.pendingInteraction != nil ||
                       (descriptor.phase == "waiting_suspended" && journal.phase == "waiting_suspended") {
                        // Status is not a replay acknowledgment. A restarted
                        // service may have committed text beyond our cursor.
                        try setPhase(descriptor.phase)
                        await publishState(onEvent)
                        try await publishInteraction(onEvent)
                        return journal.messages
                    }
                    try setPhase("streaming")
                    await onEvent(.sessionStarted(binding.sessionID))
                    await publishState(onEvent)
                    var request = try makeRequest(path: ["runs", runID, "events"], method: "GET")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let cursor = journal.cursor {
                        request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID")
                        var parts = URLComponents(url: request.url ?? baseURL, resolvingAgainstBaseURL: false)
                        parts?.queryItems = [.init(name: "cursor", value: cursor)]
                        // URLComponents leaves '+' literal; form-style query
                        // parsers otherwise turn this opaque ID byte into space.
                        let encodedQuery = parts?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
                        parts?.percentEncodedQuery = encodedQuery
                        request.url = parts?.url
                    }
                    let stream = try await transport.stream(request: request)
                    try Task.checkCancellation()
                    try checkHTTP(stream.statusCode)
                    var framer = AgentSSEFramer()
                    for try await chunk in stream.chunks {
                        try Task.checkCancellation()
                        let frames: [AgentSSEFrame]
                        do { frames = try framer.feed(chunk) }
                        catch { throw AgentGatewayError.malformedPayload }
                        for frame in frames {
                            try Task.checkCancellation()
                            try await apply(frame, config: config, tools: tools, onEvent: onEvent)
                            if ["completed", "cancelled"].contains(journal.phase) { return journal.messages }
                            if journal.phase == "failed" { throw AgentGatewayError.remoteFailed }
                            if journal.phase.hasPrefix("waiting") { return journal.messages }
                        }
                    }
                    _ = try framer.finish()
                    // EOF, including an incomplete final frame, is not terminal.
                    throw AgentGatewayError.interrupted
                } catch {
                    try Task.checkCancellation()
                    if !isRetriable(error) { throw error }
                    guard retries < 8 else { throw AgentGatewayError.interrupted }
                    retries += 1
                    try setPhase("recovering")
                    await publishState(onEvent)
                    try await timing.sleep(Double(retries) * 5)
                }
            }
        } catch {
            if journal.resumable, journal.phase != "cancelling" {
                try setPhase(isRetriable(error) || error is CancellationError ? "unknown" : "blocked")
            }
            await publishState(onEvent)
            if error is CancellationError { throw CancellationError() }
            if let known = error as? AgentGatewayError { throw known }
            // Never expose URLSession descriptions, response bodies, or secrets.
            throw AgentGatewayError.interrupted
        }
    }

    private func resolveCommand() async throws {
        guard var pending = journal.command else { return }
        var response: AgentGatewayHTTPResponse?
        if pending.attempted {
            let receipt = try await transport.send(request: makeRequest(path: ["requests", pending.key], method: "GET"))
            try Task.checkCancellation()
            if receipt.statusCode != 404 { try checkHTTP(receipt.statusCode); response = receipt }
        }
        if response == nil {
            pending.attempted = true
            journal.command = pending
            try store.save(journal)
            response = try await transport.send(request: makeRequest(path: pending.path, method: "POST",
                                                                     body: pending.body, key: pending.key))
            try Task.checkCancellation()
        }
        guard let response else { throw AgentGatewayError.malformedPayload }
        try checkHTTP(response.statusCode)
        let descriptor = try decode(AgentGatewayDescriptor.self, response.body)
        try validate(descriptor)
        guard descriptor.requestKey == pending.key else { throw AgentGatewayError.originMismatch }
        if let existing = journal.runID, existing != descriptor.runID { throw AgentGatewayError.originMismatch }
        journal.runID = descriptor.runID
        journal.command = nil
        journal.pendingInteraction = nil
        // Receipt/status cursors cannot advance the committed event cursor.
        try store.save(journal)
    }

    private func query(_ runID: String, deadline: Date? = nil) async throws -> AgentGatewayDescriptor {
        let request = try makeRequest(path: ["runs", runID], method: "GET")
        let response: AgentGatewayHTTPResponse
        if let deadline { response = try await controlSend(request, deadline: deadline) }
        else { response = try await transport.send(request: request) }
        try Task.checkCancellation()
        try checkHTTP(response.statusCode)
        let descriptor = try decode(AgentGatewayDescriptor.self, response.body)
        try validate(descriptor)
        guard descriptor.runID == runID else { throw AgentGatewayError.originMismatch }
        return descriptor
    }

    private func validate(_ descriptor: AgentGatewayDescriptor) throws {
        guard descriptor.schemaVersion == 1, !descriptor.runID.isEmpty,
              ![".", ".."].contains(descriptor.runID), descriptor.runID.utf8.count <= 1024,
              !descriptor.runID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ["starting", "streaming", "recovering", "waiting_question", "waiting_confirmation",
               "waiting_suspended", "completed", "failed", "cancelled", "cancelling"].contains(descriptor.phase)
        else { throw AgentGatewayError.malformedPayload }
        guard descriptor.binding == binding else { throw AgentGatewayError.originMismatch }
    }

    private func apply(_ frame: AgentSSEFrame, config: AgentConfig, tools: AgentToolExecuting?,
                       onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws {
        let envelope = try decode(AgentGatewayEnvelope.self, Data(frame.data.utf8))
        guard envelope.schemaVersion == 1, !envelope.eventID.isEmpty,
              envelope.eventID == frame.id, envelope.eventID.utf8.count <= 1024,
              !envelope.eventID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              envelope.payload.objectValue != nil else { throw AgentGatewayError.malformedPayload }
        guard envelope.binding == binding, envelope.runID == journal.runID else {
            throw AgentGatewayError.originMismatch
        }
        let digest = AgentGatewayJournalStore.digest(Data((frame.event + "\n" + frame.data).utf8))
        if let prior = journal.eventDigests[envelope.eventID] {
            guard prior == digest else { throw AgentGatewayError.malformedPayload }
            return
        }
        var next = journal
        var events: [AgentRunEvent] = []
        let payload = envelope.payload
        switch frame.event {
        case "initial":
            guard let messageID = UUID(uuidString: try requiredString(payload, "messageID")) else {
                throw AgentGatewayError.malformedPayload
            }
            if next.currentAssistantID == nil {
                guard !next.messages.contains(where: { $0.id == messageID }) else {
                    throw AgentGatewayError.malformedPayload
                }
                next.messages.append(.init(id: messageID, role: .assistant, content: ""))
                next.currentAssistantID = messageID
            } else if next.currentAssistantID != messageID { throw AgentGatewayError.malformedPayload }
        case "content", "thinking":
            let messageID = try requiredString(payload, "messageID")
            let text = try requiredString(payload, "delta", allowEmpty: true)
            guard let id = next.currentAssistantID, id == UUID(uuidString: messageID),
                  !next.completedAssistantIDs.contains(id),
                  let index = next.messages.firstIndex(where: { $0.id == id }) else {
                throw AgentGatewayError.malformedPayload
            }
            if frame.event == "content" {
                next.messages[index].content += text
                events.append(.contentDelta(text))
            } else {
                next.messages[index].reasoning = (next.messages[index].reasoning ?? "") + text
                events.append(.reasoningDelta(text))
            }
        case "assistant_completed":
            try completeAssistant(&next, payload: payload, events: &events)
        case "run_completed":
            if next.currentAssistantID != nil { try completeAssistant(&next, payload: payload, events: &events) }
            next.phase = "completed"
        case "run_failed":
            _ = try requiredString(payload, "code")
            next.phase = "failed"
        case "run_cancelled":
            next.phase = "cancelled"
        case "waiting_question", "waiting_confirmation":
            _ = try requiredString(payload, "interactionID")
            guard case .number(let expiry)? = payload["expiresAt"], expiry.isFinite,
                  payload["params"]?.objectValue != nil else { throw AgentGatewayError.malformedPayload }
            next.phase = frame.event
            next.pendingInteraction = .object(["kind": .string(frame.event), "payload": payload])
        case "waiting_suspended":
            next.phase = frame.event
        case "client_tool_request":
            let request = try decode(AgentGatewayToolRequest.self, JSONEncoder().encode(payload))
            guard !request.executionID.isEmpty, !request.callID.isEmpty, !request.name.isEmpty,
                  !request.targetClientInstanceID.isEmpty, request.expiresAt.isFinite,
                  let arguments = request.argumentsJSON.data(using: .utf8),
                  (try? JSONDecoder().decode(JSONValue.self, from: arguments))?.objectValue != nil else {
                throw AgentGatewayError.malformedPayload
            }
            if let previous = next.tools[request.executionID] {
                guard previous.request == request else { throw AgentGatewayError.malformedPayload }
            } else {
                guard !next.tools.values.contains(where: { $0.request.callID == request.callID }) else {
                    throw AgentGatewayError.malformedPayload
                }
                next.tools[request.executionID] = .init(request: request, phase: "reserved")
            }
        case "artifact_updated":
            _ = try requiredString(payload, "artifactID")
            try validateRevision(payload)
            guard (next.artifactUpdates?.count ?? 0) < 256 else { throw AgentGatewayError.journalUnavailable }
            next.artifactUpdates = (next.artifactUpdates ?? []) + [payload]
            events.append(.artifactUpdated(payload))
        case "canvas_changed":
            let mutation = try decode(AgentCanvasMutation.self, JSONEncoder().encode(payload))
            guard mutation.projectID == binding.projectID,
                  mutation.conversationID == binding.sessionID,
                  mutation.runID == next.runID else {
                throw AgentGatewayError.originMismatch
            }
            guard !mutation.mutationID.isEmpty, mutation.mutationID.utf8.count <= 256,
                  mutation.changes.count <= 1000, mutation.addedEdges.count <= 2000,
                  mutation.removedEdges.count <= 2000,
                  mutation.groupChanges.count <= CanvasGroupHierarchy.maximumGroups,
                  mutation.changes.allSatisfy({ $0.before != nil || $0.after != nil }),
                  mutation.groupChanges.allSatisfy({ $0.before != nil || $0.after != nil }) else {
                throw AgentGatewayError.malformedPayload
            }
            // The host decodes CanvasNode/CanvasEdge and asks for confirmation.
            // This event is a proposal, never authority to mutate local storage.
            guard (next.canvasMutations?.count ?? 0) < 256 else { throw AgentGatewayError.journalUnavailable }
            next.canvasMutations = (next.canvasMutations ?? []) + [payload]
            events.append(.canvasChanged(payload))
        case "usage":
            let prompt = try requiredInteger(payload, "promptTokens")
            let completion = try requiredInteger(payload, "completionTokens")
            let total = try requiredInteger(payload, "totalTokens")
            events.append(.usage(.init(promptTokens: prompt, completionTokens: completion,
                                       totalTokens: total, cachedTokens: nil)))
        case "note":
            // Remote diagnostic strings are not surfaced; they may echo secrets.
            next.diagnosticCount += 1
            events.append(.note("Gateway reported a diagnostic event."))
        default:
            next.diagnosticCount += 1
            events.append(.note("Gateway ignored an unknown event type."))
        }
        next.ordinal += 1
        next.eventDigests[envelope.eventID] = digest
        next.cursor = envelope.eventID
        try store.save(next)
        journal = next
        for event in events { await onEvent(event); try Task.checkCancellation() }
        await publishState(onEvent)
        try Task.checkCancellation()
        if frame.event == "client_tool_request" {
            try await deliverTools(config: config, executor: tools, onEvent: onEvent)
        }
        if frame.event == "waiting_question" || frame.event == "waiting_confirmation" {
            try await publishInteraction(onEvent)
        }
    }

    private func completeAssistant(_ next: inout AgentGatewayJournal, payload: JSONValue,
                                   events: inout [AgentRunEvent]) throws {
        guard let id = next.currentAssistantID,
              id == UUID(uuidString: try requiredString(payload, "messageID")),
              let index = next.messages.firstIndex(where: { $0.id == id }) else {
            throw AgentGatewayError.malformedPayload
        }
        if next.completedAssistantIDs.insert(id).inserted { events.append(.assistantCompleted(next.messages[index])) }
        next.currentAssistantID = nil
    }

    private func deliverTools(config: AgentConfig, executor: AgentToolExecuting?,
                              onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws {
        for executionID in journal.tools.keys.sorted() {
            try Task.checkCancellation()
            guard var record = journal.tools[executionID], record.phase != "reported" else { continue }
            if record.phase == "executing" {
                guard let recovery = executor as? any AgentGatewayToolRecovering,
                      let result = try await recovery.recoveredResult(call: record.request.call) else {
                    throw AgentGatewayError.toolOutcomeUnknown
                }
                try cacheToolResult(result, executionID: executionID, record: &record)
                await onEvent(.toolCompleted(callId: record.request.callID, name: record.request.name, result: result))
            }
            if record.phase == "reserved" {
                let request = record.request
                let result: AgentToolResult
                if request.targetClientInstanceID != journal.clientInstanceID {
                    // Targeted work belongs to another client, including result delivery.
                    record.phase = "not_target"
                    journal.tools[executionID] = record
                    try store.save(journal)
                    continue
                } else if timing.now().timeIntervalSince1970 >= request.expiresAt {
                    result = .failure("Gateway tool request expired.", code: "EXPIRED")
                } else if config.isolatedReadOnly || !journal.allowsTools ||
                            !journal.toolNames.contains(request.name) || executor == nil ||
                            !(executor?.specs().contains(where: { $0.name == request.name }) ?? false) {
                    result = .failure("Gateway tool is not authorized.", code: "NOT_AUTHORIZED")
                } else if journal.tools.values.filter({ $0.phase != "reserved" && $0.phase != "not_target" }).count >= min(config.maxToolRounds, journal.toolLimit) {
                    result = .failure("Gateway tool limit reached.", code: "TOOL_LIMIT")
                } else if let executor {
                    record.phase = "executing"
                    journal.tools[executionID] = record
                    try store.save(journal)
                    await onEvent(.toolStarted(request.call))
                    try Task.checkCancellation()
                    result = await executor.execute(call: request.call)
                    // Cache the result even if stop arrived during execution.
                    // The parent executor is responsible for its durable side effect journal.
                } else { throw AgentGatewayError.malformedPayload }
                try cacheToolResult(result, executionID: executionID, record: &record)
                await onEvent(.toolCompleted(callId: request.callID, name: request.name, result: result))
            }
            try Task.checkCancellation()
            if record.phase == "not_target" { continue }
            guard record.phase == "completed", let content = record.content,
                  let failed = record.isFailure, let runID = journal.runID else {
                throw AgentGatewayError.malformedPayload
            }
            let key = "tool-" + executionID
            let body: JSONValue = .object(["schemaVersion": 1, "binding": try value(binding),
                "runID": .string(runID), "executionID": .string(executionID),
                "callID": .string(record.request.callID), "content": .string(content),
                "isFailure": .bool(failed), "requestKey": .string(key)])
            let response = try await transport.send(request: makeRequest(path: ["runs", runID, "tool-results"],
                                                                         method: "POST", body: body, key: key))
            try Task.checkCancellation()
            try checkHTTP(response.statusCode)
            record.phase = "reported"
            journal.tools[executionID] = record
            try store.save(journal)
        }
    }

    private func cacheToolResult(_ result: AgentToolResult, executionID: String,
                                 record: inout AgentGatewayToolRecord) throws {
        record.phase = "completed"
        record.content = result.content
        record.isFailure = result.isFailure
        record.summary = result.summary
        let request = record.request
        journal.tools[executionID] = record
        if !journal.messages.contains(where: { $0.toolCallId == request.callID }) {
            journal.messages.append(.init(role: .tool, content: result.content, toolCallId: request.callID,
                                          toolName: request.name, isFailure: result.isFailure))
            if let id = journal.currentAssistantID,
               let index = journal.messages.firstIndex(where: { $0.id == id }) {
                journal.messages[index].toolCalls.append(request.call)
            }
        }
        try store.save(journal)
    }

    private func publishInteraction(_ onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws {
        guard let pending = journal.pendingInteraction, let payload = pending["payload"],
              let params = payload["params"], let runID = journal.runID else { return }
        let id = try requiredString(payload, "interactionID")
        guard case .number(let expiry)? = payload["expiresAt"] else { throw AgentGatewayError.malformedPayload }
        let kind: AgentInteraction.Kind = pending["kind"] == .string("waiting_question") ? .questions : .commandApproval
        let interaction = AgentInteraction(kind: kind, params: params,
            timeout: max(0, expiry - timing.now().timeIntervalSince1970)) { [weak self] result in
                guard let self else { throw AgentGatewayError.noResumableRun }
                try await self.reply(runID: runID, interactionID: id, result: result)
            }
        await onEvent(.interactionRequested(interaction))
    }

    private func reply(runID: String, interactionID: String, result: JSONValue) async throws {
        guard !busy, !controlling else { throw AgentGatewayError.busy }
        let lock = try store.acquire()
        defer { store.release(lock) }
        journal = try store.load()
        guard journal.runID == runID, journal.phase.hasPrefix("waiting"),
              journal.pendingInteraction?["payload"]?["interactionID"] == .string(interactionID),
              journal.command == nil else { throw AgentGatewayError.noResumableRun }
        guard case .number(let expiry)? = journal.pendingInteraction?["payload"]?["expiresAt"],
              expiry > timing.now().timeIntervalSince1970 else { throw AgentGatewayError.http(410) }
        let key = UUID().uuidString
        journal.command = .init(key: key, path: ["runs", runID, "continue"], body: .object([
            "schemaVersion": 1, "requestKey": .string(key), "binding": try value(binding),
            "clientInstanceID": .string(journal.clientInstanceID),
            "interactionID": .string(interactionID), "answer": result
        ]), attempted: false)
        try store.save(journal)
        // Dispatch/reconciliation happens on resume. A reply is durably queued
        // here, not falsely acknowledged as delivered to the service.
    }

    public func cancelRun() async {
        await cancelRun(deadline: timing.now().addingTimeInterval(timing.controlTimeout))
    }

    private func cancelRun(deadline: Date) async {
        guard !controlling else { return }
        controlling = true
        defer { controlling = false }
        operation?.cancel()
        let task = operation
        _ = try? await task?.value
        // Let invoke unwind and release its lock before acquiring control.
        while busy { await Task.yield() }
        guard let lock = try? store.acquire() else { return }
        defer { store.release(lock) }
        guard let loaded = try? store.load() else { return }
        journal = loaded
        guard journal.resumable else { return }
        do {
            try validateConfiguration()
            // Reconcile an unknown create/continue receipt before addressing cancel.
            // Do not dispatch a never-received create merely to cancel it.
            if let command = journal.command {
                let receipt = try await controlSend(makeRequest(path: ["requests", command.key], method: "GET"),
                                                    deadline: deadline)
                if receipt.statusCode == 404 { try setPhase("unknown"); return }
                try checkHTTP(receipt.statusCode)
                let descriptor = try decode(AgentGatewayDescriptor.self, receipt.body)
                try validate(descriptor)
                guard descriptor.requestKey == command.key else { throw AgentGatewayError.originMismatch }
                if let id = journal.runID, id != descriptor.runID { throw AgentGatewayError.originMismatch }
                journal.runID = descriptor.runID
                journal.command = nil
                try store.save(journal)
            }
            guard let runID = journal.runID else { try setPhase("unknown"); return }
            try setPhase("cancelling")
            let key = UUID().uuidString
            // A successful cancel receipt only acknowledges the request.
            _ = try? await controlSend(makeRequest(path: ["runs", runID, "cancel"],
                method: "POST", body: .object(["schemaVersion": 1, "binding": try value(binding),
                                               "requestKey": .string(key)]), key: key), deadline: deadline)
            let status = try await query(runID, deadline: deadline)
            try setPhase(status.phase == "cancelled" ? "cancelled" : status.phase == "failed" ? "failed" : "unknown")
        } catch { try? setPhase("unknown") }
    }

    /// Does not consume/drop queued input. The caller sends it only after true.
    public func waitUntilReadyToSteer() async throws -> Bool {
        try Task.checkCancellation()
        let deadline = timing.now().addingTimeInterval(timing.controlTimeout)
        await cancelRun(deadline: deadline)
        try Task.checkCancellation()
        guard !busy, !controlling else { throw AgentGatewayError.busy }
        controlling = true
        defer { controlling = false }
        let lock = try store.acquire()
        defer { store.release(lock) }
        journal = try store.load()
        guard let runID = journal.runID else {
            if journal.command != nil { throw AgentGatewayError.steerNotReady }
            return true
        }
        if ["cancelled", "failed", "completed"].contains(journal.phase) { return true }
        // Count bound also enforces the deadline with an injected/static clock.
        for index in 0...60 {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSince(timing.now())
            if remaining <= 0 { break }
            if index > 0 {
                try await timing.sleep(min(0.5, remaining))
                if timing.now() >= deadline { break }
            }
            do {
                let descriptor = try await query(runID, deadline: deadline)
                if ["cancelled", "failed", "completed"].contains(descriptor.phase) {
                    // Completed status alone cannot commit missing text/events.
                    // Keep queued input until resume has reconstructed completion.
                    if descriptor.phase == "completed" { throw AgentGatewayError.steerNotReady }
                    try setPhase(descriptor.phase)
                    return true
                }
            } catch {
                try Task.checkCancellation()
                if !isRetriable(error) { try setPhase("unknown"); throw AgentGatewayError.steerNotReady }
            }
        }
        try setPhase("unknown")
        throw AgentGatewayError.steerNotReady
    }

    private func controlSend(_ request: URLRequest, deadline: Date) async throws -> AgentGatewayHTTPResponse {
        let remaining = deadline.timeIntervalSince(timing.now())
        guard remaining > 0 else { throw AgentGatewayError.steerNotReady }
        var bounded = request
        bounded.timeoutInterval = remaining
        let boundedRequest = bounded
        let transport = self.transport
        return try await withThrowingTaskGroup(of: AgentGatewayHTTPResponse.self) { group in
            group.addTask { try await transport.send(request: boundedRequest) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                throw AgentGatewayError.steerNotReady
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AgentGatewayError.steerNotReady }
            return first
        }
    }

    private func makeRequest(path: [String], method: String, body: JSONValue? = nil,
                             key: String? = nil) throws -> URLRequest {
        guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AgentGatewayError.invalidConfiguration
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let suffix = try path.map { segment -> String in
            guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed),
                  !encoded.isEmpty else { throw AgentGatewayError.malformedPayload }
            return encoded
        }.joined(separator: "/")
        parts.percentEncodedPath = parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + suffix
        if !parts.percentEncodedPath.hasPrefix("/") { parts.percentEncodedPath = "/" + parts.percentEncodedPath }
        guard let url = parts.url else { throw AgentGatewayError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        if let secret = apiKeyProvider?(), !secret.isEmpty {
            guard !secret.contains("\r"), !secret.contains("\n") else { throw AgentGatewayError.invalidConfiguration }
            request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func checkHTTP(_ status: Int) throws {
        guard (200..<300).contains(status) else { throw AgentGatewayError.http(status) }
    }

    private func isRetriable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? AgentGatewayError {
            switch error {
            case .http(let status): return status == 408 || status == 425 || status == 429 || (500...599).contains(status)
            case .interrupted: return true
            default: return false
            }
        }
        if let error = error as? URLError { return error.code != .cancelled && error.code != .badURL && error.code != .unsupportedURL }
        return false
    }

    private func setPhase(_ phase: String) throws {
        var next = journal
        next.phase = phase
        try store.save(next)
        journal = next
    }

    private func publishState(_ onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async {
        if let id = journal.runID { await onEvent(.runState(phase: journal.phase, runID: id, cursor: journal.cursor)) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw AgentGatewayError.malformedPayload }
    }

    private func value<T: Encodable>(_ value: T) throws -> JSONValue {
        try decode(JSONValue.self, JSONEncoder().encode(value))
    }

    private func requiredString(_ value: JSONValue, _ key: String, allowEmpty: Bool = false) throws -> String {
        guard case .string(let text)? = value[key], allowEmpty || !text.isEmpty else {
            throw AgentGatewayError.malformedPayload
        }
        return text
    }

    private func requiredInteger(_ value: JSONValue, _ key: String) throws -> Int {
        guard case .number(let number)? = value[key], number.isFinite, number >= 0,
              number.rounded() == number, number < Double(Int.max) else { throw AgentGatewayError.malformedPayload }
        return Int(number)
    }

    private func validateRevision(_ payload: JSONValue) throws {
        _ = try requiredInteger(payload, "revision")
    }
}
