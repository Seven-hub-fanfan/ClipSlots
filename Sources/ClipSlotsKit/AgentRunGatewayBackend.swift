import Foundation

/// Adapter for a self-owned service implementing the gateway v1 contract.
/// It never infers routes or credentials from AgentConfig.endpoint.
public actor AgentGatewayBackend: AgentGatewaySteering {
    private let baseURL: URL
    public nonisolated var artifactEndpoint: URL { baseURL }
    private let binding: AgentRunBinding
    private let transport: any AgentGatewayTransport
    private let timing: AgentGatewayTiming
    private let apiKeyProvider: (@Sendable () -> String?)?
    private let store: AgentGatewayJournalStore
    private var journal: AgentGatewayJournal
    private var diagnostics: AgentRunDiagnostics
    private var loadFailed = false
    private var operation: Task<[AgentMessage], Error>?
    private var busy = false
    private var controlling = false
    private var hotControl = false
    private var sharedJournalLock: Int32?
    private var journalLockUsers = 0
    private var decisionClocks: [String: (serverTime: Double, uptime: Double)] = [:]
    private struct ToolOwner {
        let id: UUID
        let executor: AgentToolExecuting
    }
    private var toolOwners: [String: ToolOwner] = [:]

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
        diagnostics = .init(binding: binding)
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

    #if DEBUG
    /// Linked isolated-process fault tests only; no environment switch.
    func debugSetDecisionJournalQuota(_ bytes: Int64?) { store.testQuotaBytes = bytes }
    #endif

    public var snapshot: AgentGatewayRunSnapshot {
        .init(binding: binding, runID: journal.runID, phase: journal.phase, cursor: journal.cursor,
              messages: journal.messages, clientInstanceID: journal.clientInstanceID,
              currentAssistantID: journal.currentAssistantID,
              completedAssistantIDs: journal.completedAssistantIDs,
              artifactUpdates: journal.artifactUpdates ?? [],
              artifactToolContexts: journal.artifactToolContexts ?? [:],
              canvasMutations: journal.canvasMutations ?? [],
              canvasReadbacks: journal.canvasReadbacks ?? [],
              subagentCanvasScopes: journal.subagentCanvasProjection?.scopes ?? [:],
              contextUsage: journal.contextUsage ?? .init(), compactions: journal.compactions ?? .init(),
              taskSubagents: journal.taskSubagents ?? .init(),
              steerCapability: journal.steerCapability, steers: steerSnapshots(),
              interactions: decisionInteractions())
    }

    private func retainJournalLock() throws {
        if sharedJournalLock == nil { sharedJournalLock = try store.acquire() }
        journalLockUsers += 1
    }

    private func releaseJournalLock() {
        journalLockUsers -= 1
        if journalLockUsers == 0, let lock = sharedJournalLock {
            store.release(lock); sharedJournalLock = nil
        }
    }

    private func steerSnapshots() -> [AgentGatewaySteerSnapshot] {
        (journal.steerSubmissions ?? [:]).keys.sorted().compactMap { try? steerSnapshot($0) }
    }

    private func steerSnapshot(_ id: String) throws -> AgentGatewaySteerSnapshot {
        guard let submission = journal.steerSubmissions?[id],
              let state = journal.steerStates?[id] else { throw AgentGatewayError.malformedPayload }
        return try .init(message: submission.message, receipt: state.receipt,
                         attempted: state.attempted, eventApplied: state.eventApplied)
    }

    /// Fresh read-only invocations must not consume the conversation journal.
    /// The host owns the supplied temporary directory's lifecycle.
    public func isolatedBackend(journalRoot: URL) -> AgentGatewayBackend {
        .init(baseURL: baseURL, binding: .init(sessionID: "isolated-\(UUID().uuidString)"),
              journalRoot: journalRoot, apiKeyProvider: apiKeyProvider, transport: transport, timing: timing)
    }

    public nonisolated func appReplyClient(directory: URL) throws -> AgentAppReplyClient {
        try .init(directory: directory, transport: transport, credential: { url in
            guard url.absoluteString.utf8.elementsEqual(self.baseURL.absoluteString.utf8) else { return nil }
            return self.apiKeyProvider?()
        })
    }

    public nonisolated func appReplyBackend(journalRoot: URL) -> AgentGatewayBackend {
        .init(baseURL: baseURL, binding: binding, journalRoot: journalRoot,
              apiKeyProvider: apiKeyProvider, transport: transport, timing: timing)
    }

    /// Attach an already accepted run. This performs GET only and preserves a separate run journal.
    public func attachAppReply(_ record: AgentAppReplySnapshot,
                               toolContext: AgentAppReplyToolContext? = nil) async throws {
        try record.submission.validate()
        if let toolContext {
            try toolContext.validate()
            guard toolContext.authority == record.submission.origin.authority else {
                throw AgentGatewayError.originMismatch
            }
        }
        guard let receipt = record.receipt, record.state == .accepted,
              record.submission.origin.endpoint.absoluteString.utf8.elementsEqual(baseURL.absoluteString.utf8),
              AgentGatewayDecisionIdentity.bindingBytes(receipt.binding, binding),
              !busy, !controlling, !hotControl else { throw AgentGatewayError.originMismatch }
        try receipt.validate(for: record.submission, readback: receipt.state != nil)
        try validateConfiguration()
        try retainJournalLock()
        defer { releaseJournalLock() }
        if FileManager.default.fileExists(atPath: store.storageFile.path) { journal = try store.load() }
        if let prior = journal.appReply {
            guard prior.submission == record.submission,
                  prior.receipt?.sameAcceptance(as: receipt) == true,
                  journal.runID == receipt.runID,
                  toolContext == nil || journal.appReplyToolContext == toolContext else {
                throw AgentGatewayError.originMismatch
            }
            return
        }
        guard journal.runID == nil, journal.command == nil else { throw AgentGatewayError.resumableRunExists }
        let response = try await send(makeRequest(path: ["runs", receipt.runID], method: "GET"), stage: .control)
        try checkHTTP(response.statusCode)
        let descriptor = try decode(AgentGatewayDescriptor.self, response.body)
        try validate(descriptor)
        guard descriptor.runID == receipt.runID,
              let owner = descriptor.clientInstanceID, AgentGatewayDecisionIdentity.opaque(owner),
              toolContext.map({ $0.clientInstanceID == owner }) ?? true else {
            throw AgentGatewayError.originMismatch
        }
        try Task.checkCancellation()
        var next = AgentGatewayJournal(origin: store.origin, binding: binding, clientInstanceID: owner)
        next.runID = receipt.runID
        next.phase = "recovering"
        next.appReply = record
        next.appReplyToolContext = toolContext
        try store.save(next); journal = next
    }

    /// First adoption explicitly authorizes a new executor for this reply only.
    /// Resume and later adoption never rebind a persisted owner or pending call.
    @discardableResult
    public func activateAppReplyTools(_ tools: AgentToolExecuting?, config: AgentConfig) throws -> Bool {
        guard !busy, !controlling, !hotControl else { throw AgentGatewayError.busy }
        try retainJournalLock()
        defer { releaseJournalLock() }
        journal = try store.load()
        guard let reply = journal.appReply, let context = journal.appReplyToolContext,
              let tools, !config.isolatedReadOnly, journal.toolSubmissionKey == nil,
              journal.cursor == nil, journal.ordinal == 0, journal.tools.isEmpty else { return false }
        try context.validate()
        let scope = AgentAppReplyToolContext.executionScope(binding: binding, replyID: reply.submission.replyID)
        guard context.authority == reply.submission.origin.authority,
              context.clientInstanceID == journal.clientInstanceID,
              (tools as? any AgentToolExecutionScoped)?.executionScope == scope else {
            throw AgentGatewayError.originMismatch
        }
        let key = scope.turnID, instance = UUID()
        var next = journal
        next.toolSubmissionKey = key
        next.toolSnapshots = [key: .init(instanceID: instance, scope: scope, declarations: context.declarations)]
        next.toolNames = Set(context.declarations.map(\.name))
        next.toolLimit = min(context.toolLimit, config.maxToolRounds)
        next.allowsTools = true
        try store.save(next); journal = next
        toolOwners[key] = .init(id: instance, executor: tools)
        return true
    }

    /// Distinct user action; no new chat history, UUID, or first business action is submitted.
    public func prepareAppReplyContinuation() async throws {
        guard !busy, !controlling, !hotControl else { throw AgentGatewayError.busy }
        try retainJournalLock()
        defer { releaseJournalLock() }
        journal = try store.load()
        guard let reply = journal.appReply, let receipt = reply.receipt,
              journal.runID == receipt.runID else { throw AgentGatewayError.originMismatch }
        if journal.command != nil { return } // Recover the original command key, never replace it.
        let descriptor = try await query(receipt.runID)
        guard descriptor.phase == "waiting_suspended" else { return }
        let key = UUID().uuidString.lowercased()
        var next = journal
        next.command = .init(key: key, path: ["runs", receipt.runID, "app-reply-continue"], body: [
            "schemaVersion": 1, "requestKey": .string(key), "binding": try value(binding),
            "clientInstanceID": .string(journal.clientInstanceID)], attempted: false)
        try store.save(next); journal = next
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

    public var diagnosticSnapshot: AgentRunDiagnostics { diagnostics }
    public func exportDiagnostics() throws -> Data { try diagnostics.export() }

    private func diagnose(_ stage: AgentRunDiagnostics.Stage, _ outcome: AgentRunDiagnostics.Outcome,
                          request: String? = nil, event: String? = nil, call: String? = nil,
                          elapsed: TimeInterval? = nil, bytes: Int? = nil, status: Int? = nil,
                          retry: Int? = nil, error: Error? = nil) {
        diagnostics.append(stage: stage, outcome: outcome, run: journal.runID,
            request: request, event: event, call: call, elapsed: elapsed, bytes: bytes,
            status: status, retry: retry, failure: error.map(AgentRunDiagnostics.Failure.classify))
    }

    private func send(_ request: URLRequest, stage: AgentRunDiagnostics.Stage) async throws -> AgentGatewayHTTPResponse {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let response = try await transport.send(request: request)
            diagnose(stage, (200..<300).contains(response.statusCode) ? .completed : .rejected,
                request: request.value(forHTTPHeaderField: "Idempotency-Key"),
                elapsed: ProcessInfo.processInfo.systemUptime - start,
                bytes: request.httpBody?.count, status: response.statusCode)
            return response
        } catch {
            diagnose(stage, error is CancellationError ? .cancelled : .unknown,
                request: request.value(forHTTPHeaderField: "Idempotency-Key"),
                elapsed: ProcessInfo.processInfo.systemUptime - start,
                bytes: request.httpBody?.count, error: error)
            throw error
        }
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
        guard !busy, !controlling, !hotControl else { throw AgentGatewayError.busy }
        try validateConfiguration()
        try retainJournalLock()
        defer { releaseJournalLock() }
        if FileManager.default.fileExists(atPath: store.storageFile.path) { journal = try store.load() }
        loadFailed = false
        try restoreLegacyDecision()
        guard resuming || journal.appReply == nil else { throw AgentGatewayError.originMismatch }
        if resuming {
            guard journal.resumable else { throw AgentGatewayError.noResumableRun }
            var usage = journal.contextUsage ?? .init()
            usage.invalidate()
            journal.contextUsage = usage
            try store.save(journal)
        } else {
            let specs = config.isolatedReadOnly ? [] : tools?.specs() ?? []
            guard specs.count <= 128, Set(specs.map(\.name)).count == specs.count,
                  specs.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 256
                      && $0.parameters.objectValue != nil }) else {
                throw AgentGatewayError.malformedPayload
            }
            if journal.resumable {
                guard !(journal.decisionRecords ?? [:]).values.contains(where: { $0.state == .syncing || $0.state == .saved }) else {
                    throw AgentGatewayError.decisionOutcomeUnknown
                }
                guard journal.phase.hasPrefix("waiting"), journal.command == nil,
                      let runID = journal.runID else { throw AgentGatewayError.resumableRunExists }
                journal.command = try command(path: ["runs", runID, "continue"],
                                              history: history, config: config, specs: specs)
                journal.phase = "starting"
            } else {
                let usage = journal.contextUsage
                journal = .init(origin: store.origin, binding: binding,
                                clientInstanceID: journal.clientInstanceID)
                journal.contextUsage = usage
                decisionClocks.removeAll()
                toolOwners.removeAll()
                journal.command = try command(path: ["runs"], history: history, config: config, specs: specs)
                journal.phase = "starting"
            }
            var usage = journal.contextUsage ?? .init()
            usage.invalidate()
            journal.contextUsage = usage
            journal.allowsTools = !config.isolatedReadOnly
            journal.toolNames = Set(specs.map(\.name))
            journal.toolLimit = config.maxToolRounds
            guard let key = journal.command?.key else { throw AgentGatewayError.malformedPayload }
            let instanceID = UUID()
            journal.toolSubmissionKey = key
            var snapshots = journal.toolSnapshots ?? [:]
            snapshots[key] = .init(instanceID: instanceID,
                scope: (tools as? any AgentToolExecutionScoped)?.executionScope,
                declarations: specs.map(AgentGatewayToolSnapshot.Declaration.init))
            journal.toolSnapshots = snapshots
            if let tools { toolOwners[key] = .init(id: instanceID, executor: tools) }
            try store.save(journal)
            diagnose(.submission, .committed, request: key)
        }
        busy = true
        defer {
            busy = false; operation = nil
            if !journal.resumable { toolOwners.removeAll() }
        }
        let task = Task { try await self.perform(config: config, tools: tools, onEvent: onEvent) }
        operation = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func command(path: [String], history: [AgentMessage], config: AgentConfig,
                         specs: [AgentToolSpec]) throws -> AgentGatewayCommand {
        let messages: [JSONValue] = try history.filter(\.isWireVisible).map { message in
            let content: JSONValue
            if let submission = journal.steerSubmissions?[message.id.uuidString],
               journal.steerStates?[message.id.uuidString]?.receipt?.state == .placed {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                guard try encoder.encode(message) == submission.messageData,
                      let saved = try decode(JSONValue.self, submission.requestBody)["message"]?["content"] else {
                    throw AgentGatewayError.originMismatch
                }
                // Re-encoding reference JSON can change its embedded text
                // bytes. Continue must carry the exact content already placed.
                content = saved
            } else { content = message.wirePayload(supportsImages: config.supportsImageInput == true) }
            // Local attachment paths and endpoint credentials do not belong in
            // this contract. Authorized textual references use wireContent.
            var fields: [String: JSONValue] = [
                "id": .string(message.id.uuidString), "role": .string(message.role.rawValue),
                "content": content,
                "toolCallID": message.toolCallId.map(JSONValue.string) ?? .null
            ]
            if message.role == .assistant, let reasoning = message.reasoning {
                fields["reasoning"] = .string(reasoning)
            }
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
        journal.wireMessageOffset = messages.count + 1 - journal.messages.count
        journal.steerSupportsImages = config.supportsImageInput == true
        let bindingValue = try value(binding)
        let body: JSONValue = .object([
            "schemaVersion": 1, "messageSchemaVersion": 1,
            "requestKey": .string(key), "binding": bindingValue,
            "clientInstanceID": .string(journal.clientInstanceID),
            "history": .array(messages),
            "config": .object(["model": .string(config.model), "systemPrompt": .string(config.systemPrompt),
                               "thinkingMode": .string(config.thinkingMode.rawValue),
                               "supportsImageInput": .bool(config.supportsImageInput == true),
                               "taskPolicy": .string(config.taskPolicy.rawValue),
                               "maxToolRounds": .number(Double(config.maxToolRounds))]),
            "tools": .array(specs.map(\.wireValue))
        ])
        // Reject before persisting a command/unknown run: this is the HTTP
        // budget for the complete history including base64 and JSON overhead.
        _ = try Self.encodedRequestBody(body)
        return .init(key: key, path: path, body: body, attempted: false)
    }

    private func perform(config: AgentConfig, tools: AgentToolExecuting?,
                         onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        var retries = 0
        let operationStart = ProcessInfo.processInfo.systemUptime
        defer {
            diagnose(.terminal, journal.phase == "completed" ? .completed :
                journal.phase == "cancelled" ? .cancelled :
                journal.phase == "failed" ? .failed : .unknown,
                elapsed: ProcessInfo.processInfo.systemUptime - operationStart)
        }
        do {
            while true {
                try Task.checkCancellation()
                do {
                    try await resolveCommand()
                    try await refreshDecisions()
                    await publishDecisions(onEvent)
                    guard let runID = journal.runID else { throw AgentGatewayError.malformedPayload }
                    let descriptor = try await query(runID)
                    let needsSteerReplay = (journal.steerStates ?? [:]).values.contains {
                        $0.receipt?.state == .accepted || $0.receipt == nil || !$0.eventApplied
                    }
                    let needsReplyReplay = journal.appReply != nil
                        && !["completed", "failed", "cancelled"].contains(journal.phase)
                    if descriptor.phase == "cancelled", !needsSteerReplay, !needsReplyReplay {
                        try setPhase("cancelled")
                        await publishState(onEvent)
                        return journal.messages
                    }
                    if descriptor.phase == "failed", !needsSteerReplay, !needsReplyReplay {
                        try setPhase("failed")
                        await publishState(onEvent)
                        throw AgentGatewayError.remoteFailed
                    }
                    if !journal.tools.isEmpty { try await deliverTools(config: config, executor: tools, onEvent: onEvent) }
                    if descriptor.phase.hasPrefix("waiting"), !needsSteerReplay,
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
                    let streamStart = ProcessInfo.processInfo.systemUptime
                    let stream: AgentHTTPStream
                    do {
                        stream = try await transport.stream(request: request)
                    } catch {
                        diagnose(.stream, .unknown, elapsed: ProcessInfo.processInfo.systemUptime - streamStart,
                                 error: error)
                        throw error
                    }
                    diagnose(.stream, (200..<300).contains(stream.statusCode) ? .started : .rejected,
                        elapsed: ProcessInfo.processInfo.systemUptime - streamStart, status: stream.statusCode)
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
                            if journal.phase.hasPrefix("waiting"),
                               !(journal.steerStates ?? [:]).values.contains(where: {
                                   $0.receipt == nil || $0.receipt?.state == .accepted
                               }) { return journal.messages }
                        }
                    }
                    _ = try framer.finish()
                    try await flushSubagentReadback(onEvent: onEvent)
                    // EOF, including an incomplete final frame, is not terminal.
                    throw AgentGatewayError.interrupted
                } catch {
                    try Task.checkCancellation()
                    if !isRetriable(error) { throw error }
                    guard retries < 8 else { throw AgentGatewayError.interrupted }
                    retries += 1
                    diagnose(.retry, .started, retry: retries, error: error)
                    try setPhase("recovering")
                    await publishState(onEvent)
                    try await timing.sleep(Double(retries) * 5)
                }
            }
        } catch {
            let decisionUnknown = (error as? AgentGatewayError) == .decisionOutcomeUnknown
            diagnose(.terminal, error is CancellationError ? .cancelled : decisionUnknown ? .unknown : .failed, error: error)
            if journal.resumable, journal.phase != "cancelling" {
                try setPhase(isRetriable(error) || error is CancellationError || decisionUnknown ? "unknown" : "blocked")
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
            let receipt = try await send(makeRequest(path: ["requests", pending.key], method: "GET"),
                                         stage: .receipt)
            try Task.checkCancellation()
            if receipt.statusCode != 404 { try checkHTTP(receipt.statusCode); response = receipt }
            else if pending.body["interactionID"] != nil {
                // An unknown legacy answer must not be resent just because a
                // receipt lookup has no record.
                throw AgentGatewayError.decisionOutcomeUnknown
            }
        }
        if response == nil {
            pending.attempted = true
            journal.command = pending
            try store.save(journal)
            response = try await send(makeRequest(path: pending.path, method: "POST",
                                                   body: pending.body, key: pending.key), stage: .submission)
            try Task.checkCancellation()
        }
        guard let response else { throw AgentGatewayError.malformedPayload }
        try checkHTTP(response.statusCode)
        let descriptor = try decode(AgentGatewayDescriptor.self, response.body)
        try validate(descriptor)
        guard descriptor.requestKey == pending.key else { throw AgentGatewayError.originMismatch }
        if let existing = journal.runID, existing != descriptor.runID { throw AgentGatewayError.originMismatch }
        journal.runID = descriptor.runID
        journal.steerCapability = descriptor.steerCapability
        if let id = pending.body["interactionID"]?.stringValue,
           journal.legacyDecisionRecords?[id]?.submissionKey == pending.key {
            journal.legacyDecisionRecords?[id]?.acceptedKey = pending.key
        }
        journal.command = nil
        journal.pendingInteraction = nil
        // Receipt/status cursors cannot advance the committed event cursor.
        try store.save(journal)
        diagnose(.receipt, .committed, request: pending.key)
    }

    private func query(_ runID: String, deadline: Date? = nil) async throws -> AgentGatewayDescriptor {
        let request = try makeRequest(path: ["runs", runID], method: "GET")
        let response: AgentGatewayHTTPResponse
        if let deadline { response = try await controlSend(request, deadline: deadline) }
        else { response = try await send(request, stage: .status) }
        try Task.checkCancellation()
        try checkHTTP(response.statusCode)
        let descriptor = try decode(AgentGatewayDescriptor.self, response.body)
        try validate(descriptor)
        guard descriptor.runID == runID else { throw AgentGatewayError.originMismatch }
        if journal.steerCapability != descriptor.steerCapability {
            var next = journal
            next.steerCapability = descriptor.steerCapability
            try store.save(next); journal = next
        }
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
        if descriptor.steerCapability?.accepting == true, descriptor.phase != "streaming" {
            throw AgentGatewayError.malformedPayload
        }
        if let capability = descriptor.decisionCapability,
           capability.schemaVersion != 1 || !capability.readback {
            throw AgentGatewayError.malformedPayload
        }
    }

    private func appendReadback(_ request: AgentCanvasReadbackRequest, to next: inout AgentGatewayJournal) throws {
        if let previous = (next.canvasReadbacks ?? []).first(where: { $0.coordinationKey == request.coordinationKey }) {
            guard previous == request else { throw AgentGatewayError.malformedPayload }
            return
        }
        guard (next.canvasReadbacks?.count ?? 0) < 256 else { throw AgentGatewayError.journalUnavailable }
        next.canvasReadbacks = (next.canvasReadbacks ?? []) + [request]
    }

    private func flushSubagentReadback(onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws {
        var next = journal
        let requests = next.subagentCanvasProjection?.finishAll() ?? []
        guard !requests.isEmpty else { return }
        for request in requests { try appendReadback(request, to: &next) }
        try store.save(next)
        journal = next
        for request in requests { await onEvent(.canvasReadbackRequested(request)) }
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
            await onEvent(.runStreamActivity(runID: envelope.runID))
            return
        }
        var next = journal
        var events: [AgentRunEvent] = []
        let payload = envelope.payload
        switch frame.event {
        case "app_reply_accepted":
            let receipt = try decode(AgentAppReplyReceipt.self, JSONEncoder().encode(payload))
            guard let record = next.appReply else { throw AgentGatewayError.originMismatch }
            try receipt.validate(for: record.submission, readback: false)
            guard record.receipt?.sameAcceptance(as: receipt) == true else {
                throw AgentGatewayError.originMismatch
            }
        case "steer_state":
            let receipt = try decode(AgentGatewaySteerReceipt.self, JSONEncoder().encode(payload))
            try receiveSteer(receipt, event: true, into: &next)
            guard let submission = next.steerSubmissions?[receipt.submissionID],
                  let state = next.steerStates?[receipt.submissionID] else {
                throw AgentGatewayError.malformedPayload
            }
            events.append(try .steerState(.init(message: submission.message, receipt: state.receipt,
                attempted: state.attempted, eventApplied: state.eventApplied)))
        case "initial":
            guard let messageID = UUID(uuidString: try requiredString(payload, "messageID")) else {
                throw AgentGatewayError.malformedPayload
            }
            if next.currentAssistantID == nil {
                guard !next.messages.contains(where: { $0.id == messageID }) else {
                    throw AgentGatewayError.malformedPayload
                }
                next.messages.append(.init(id: messageID, role: .assistant, content: "",
                    runID: envelope.runID,
                    executionScope: next.toolSubmissionKey.flatMap { next.toolSnapshots?[$0]?.scope }))
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
            if payload["decisionSchemaVersion"] != nil {
                guard payload["decisionSchemaVersion"] == 1, let runID = next.runID else {
                    throw AgentGatewayError.malformedPayload
                }
                let identity = try AgentGatewayDecisionIdentity(binding: binding, runID: runID,
                    clientInstanceID: next.clientInstanceID, kind: frame.event, payload: payload)
                if let old = next.decisionRecords?[identity.interactionID] {
                    guard old.identity == identity, old.params == payload["params"],
                          old.receipt?.state != "resolved" else { throw AgentGatewayError.originMismatch }
                } else {
                    guard (next.decisionRecords?.count ?? 0) < 128, let params = payload["params"] else {
                        throw AgentGatewayError.malformedPayload
                    }
                    if next.decisionRecords == nil { next.decisionRecords = [:] }
                    next.decisionRecords?[identity.interactionID] = .init(localID: UUID(), identity: identity, params: params)
                }
            } else if let runID = next.runID, let id = payload["interactionID"]?.stringValue,
                      let params = payload["params"], case .number(let expiry)? = payload["expiresAt"] {
                if next.legacyDecisionRecords == nil { next.legacyDecisionRecords = [:] }
                if let old = next.legacyDecisionRecords?[id] {
                    guard old.runID == runID, old.params == params, old.expiresAt == expiry else {
                        throw AgentGatewayError.originMismatch
                    }
                } else {
                    guard (next.legacyDecisionRecords?.count ?? 0) < 128 else { throw AgentGatewayError.malformedPayload }
                    next.legacyDecisionRecords?[id] = .init(localID: UUID(), runID: runID,
                        interactionID: id, kind: frame.event, params: params, expiresAt: expiry)
                }
            }
        case "decision_resolved":
            let receipt = try decode(AgentGatewayDecisionReceipt.self, JSONEncoder().encode(payload))
            guard var record = next.decisionRecords?[receipt.interactionID], receipt.state == "resolved" else {
                throw AgentGatewayError.malformedPayload
            }
            try receipt.validate(for: record.identity)
            if let old = record.receipt, old.state == "resolved", old.decision != receipt.decision {
                throw AgentGatewayError.originMismatch
            }
            record.receipt = receipt
            next.decisionRecords?[receipt.interactionID] = record
            if next.pendingInteraction?["payload"]?["interactionID"] == .string(receipt.interactionID) {
                next.pendingInteraction = nil
            }
        case "waiting_suspended":
            next.phase = frame.event
        case "client_tool_request":
            let request = try decode(AgentGatewayToolRequest.self, JSONEncoder().encode(payload))
            guard !request.executionID.isEmpty, !request.callID.isEmpty, !request.name.isEmpty,
                  !request.targetClientInstanceID.isEmpty, request.expiresAt.isFinite,
                  request.executionID.utf8.count <= 1024, request.callID.utf8.count <= 1024,
                  request.name.utf8.count <= 256, request.targetClientInstanceID.utf8.count <= 1024,
                  request.argumentsJSON.utf8.count <= 1_048_576,
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
                guard let assistantID = next.currentAssistantID,
                      let index = next.messages.firstIndex(where: { $0.id == assistantID }),
                      !next.completedAssistantIDs.contains(assistantID) else {
                    throw AgentGatewayError.malformedPayload
                }
                let scope = next.toolSubmissionKey.flatMap { next.toolSnapshots?[$0]?.scope }
                next.messages[index].runID = envelope.runID
                next.messages[index].executionScope = scope
                next.messages[index].toolCalls.append(request.call)
                let origin = AgentToolMessageOrigin(assistantID: assistantID, runID: envelope.runID,
                    scope: scope, executionID: request.executionID)
                next.tools[request.executionID] = .init(request: request, phase: "reserved",
                    submissionKey: next.toolSubmissionKey, messageOrigin: origin, resultMessageID: UUID())
                events.append(.assistantUpdated(next.messages[index]))
            }
        case "artifact_updated":
            _ = try requiredString(payload, "artifactID")
            try validateRevision(payload)
            guard (next.artifactUpdates?.count ?? 0) < 256 else { throw AgentGatewayError.journalUnavailable }
            var context: AgentAppReplyToolContext?
            if let authorityJSON = payload["appReplyAuthority"], next.allowsTools,
               let key = next.toolSubmissionKey, let source = next.toolSnapshots?[key] {
                let authority = try decode(AgentAppReplyAuthority.self, JSONEncoder().encode(authorityJSON))
                guard authority.binding == binding, authority.originRunID == next.runID,
                      authority.artifactID == payload["artifactID"]?.stringValue,
                      authority.path == payload["path"]?.stringValue,
                      payload["revision"] == .number(Double(authority.artifactRevision)) else {
                    throw AgentGatewayError.originMismatch
                }
                let captured = AgentAppReplyToolContext(authority: authority,
                    clientInstanceID: next.clientInstanceID, submissionKey: key,
                    sourceScope: source.scope, declarations: source.declarations, toolLimit: next.toolLimit)
                try captured.validate()
                if let prior = next.artifactToolContexts?[captured.key], prior != captured {
                    throw AgentGatewayError.originMismatch
                }
                if next.artifactToolContexts == nil { next.artifactToolContexts = [:] }
                next.artifactToolContexts?[captured.key] = captured
                context = captured
            }
            next.artifactUpdates = (next.artifactUpdates ?? []) + [payload]
            events.append(.artifactUpdated(payload, toolContext: context))
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
        case "canvas_tool_event":
            guard let project = binding.projectID else { throw AgentGatewayError.originMismatch }
            if let request = try AgentCanvasChangeNotice.request(event: payload, projectID: project,
                conversationID: binding.sessionID, runID: envelope.runID) {
                if let previous = (next.canvasReadbacks ?? []).first(where: { $0.coordinationKey == request.coordinationKey }) {
                    guard previous == request else { throw AgentGatewayError.malformedPayload }
                } else {
                    guard (next.canvasReadbacks?.count ?? 0) < 256 else { throw AgentGatewayError.journalUnavailable }
                    next.canvasReadbacks = (next.canvasReadbacks ?? []) + [request]
                }
                events.append(.canvasReadbackRequested(request))
            }
        case "task_snapshot":
            if let snapshot = try? AgentTaskPlanSnapshot(validating: payload) {
                var display = next.taskSubagents ?? .init()
                let assistant = next.messages.first { $0.id == next.currentAssistantID }
                let anchor = AgentContextCompactionAnchor(messageID: next.currentAssistantID,
                    afterMessageID: next.messages.last?.id, content: assistant?.content ?? "",
                    reasoning: assistant?.reasoning ?? "", awaitingAssistant: false, displayOrder: next.ordinal)
                if try display.receiveTasks(snapshot, eventID: envelope.eventID, runID: envelope.runID,
                                            anchor: anchor, now: timing.now()) {
                    next.taskSubagents = display
                    events.append(.taskSnapshot(snapshot, eventID: envelope.eventID, anchor: anchor))
                }
            } else { next.diagnosticCount += 1 }
        case "subagent_event":
            var display = next.taskSubagents ?? .init()
            let assistant = next.messages.first { $0.id == next.currentAssistantID }
            let anchor = AgentContextCompactionAnchor(messageID: next.currentAssistantID,
                afterMessageID: next.messages.last?.id, content: assistant?.content ?? "",
                reasoning: assistant?.reasoning ?? "", awaitingAssistant: false, displayOrder: next.ordinal)
            if try display.receiveSubagent(payload, eventID: envelope.eventID, runID: envelope.runID,
                                           anchor: anchor, now: timing.now()) {
                next.taskSubagents = display
                events.append(.subagentEvent(payload, eventID: envelope.eventID, anchor: anchor))
            }
            // A conversation without a canvas still receives the child display.
            guard let project = binding.projectID else { break }
            var projection = next.subagentCanvasProjection ?? .init()
            let update = try projection.receive(payload, eventID: envelope.eventID, projectID: project,
                conversationID: binding.sessionID, runID: envelope.runID)
            next.subagentCanvasProjection = projection
            if update != nil { events.append(.subagentCanvasScopes(projection.scopes)) }
            // A nested tool response is still an index, with the explicitly
            // supplied child/parent provenance attached by this adapter.
            if update != nil, var tool = payload["tool_event"]?.objectValue,
               let child = payload["subagent_id"]?.stringValue,
               let accepted = projection.scopes[child],
               accepted == AgentGatewayJournalStore.digest(Data(
                   "\(child)\u{0}\(payload["parent_tool_call_id"]?.stringValue ?? "")".utf8)) {
                tool["subagent_id"] = .string(child)
                if let parent = payload["parent_tool_call_id"] { tool["parent_tool_call_id"] = parent }
                if let nested = try AgentCanvasChangeNotice.request(event: .object(tool), projectID: project,
                    conversationID: binding.sessionID, runID: envelope.runID) {
                    try appendReadback(nested, to: &next)
                    events.append(.canvasReadbackRequested(nested))
                }
            }
            if let request = update?.request {
                try appendReadback(request, to: &next)
                events.append(.canvasReadbackRequested(request))
            }
        case "usage":
            let prompt = try requiredInteger(payload, "promptTokens")
            let completion = try requiredInteger(payload, "completionTokens")
            let total = try requiredInteger(payload, "totalTokens")
            events.append(.usage(.init(promptTokens: prompt, completionTokens: completion,
                                       totalTokens: total, cachedTokens: nil)))
        case "context_usage":
            // Stream adapters unwrap the optional context_usage envelope.
            if let incoming = try? AgentContextUsageSnapshot(validating: payload["context_usage"] ?? payload) {
                var usage = next.contextUsage ?? .init()
                if usage.receive(incoming, conversationID: binding.sessionID, runID: next.runID) {
                    next.contextUsage = usage
                    events.append(.contextUsage(incoming))
                }
            } else { next.diagnosticCount += 1 }
        case "compact":
            if let raw = payload["phase"]?.stringValue, let phase = AgentContextCompactionPhase(rawValue: raw),
               phase != .idle {
                var usage = next.contextUsage ?? .init()
                usage.setCompaction(phase)
                next.contextUsage = usage
                var lifecycle = next.compactions ?? .init()
                let assistant = next.messages.first { $0.id == next.currentAssistantID }
                let anchor = AgentContextCompactionAnchor(messageID: next.currentAssistantID,
                    afterMessageID: next.messages.last?.id,
                    content: assistant?.content ?? "", reasoning: assistant?.reasoning ?? "",
                    awaitingAssistant: false, displayOrder: next.ordinal)
                lifecycle.receive(phase, eventID: envelope.eventID, runID: next.runID, anchor: anchor)
                next.compactions = lifecycle
                events.append(.contextCompaction(phase: phase, eventID: envelope.eventID, anchor: anchor))
            } else { next.diagnosticCount += 1 }
        case "note":
            // Remote diagnostic strings are not surfaced; they may echo secrets.
            next.diagnosticCount += 1
            events.append(.note("Gateway reported a diagnostic event."))
        default:
            next.diagnosticCount += 1
            events.append(.note("Gateway ignored an unknown event type."))
        }
        if ["run_completed", "run_failed", "run_cancelled"].contains(frame.event) {
            for request in next.subagentCanvasProjection?.finishAll() ?? [] {
                try appendReadback(request, to: &next)
                events.append(.canvasReadbackRequested(request))
            }
        }
        if ["run_completed", "run_failed", "run_cancelled"].contains(frame.event) {
            next.contextUsage?.finishLoading()
            next.compactions?.interrupt()
            next.taskSubagents?.finish(runID: envelope.runID, now: timing.now())
        }
        next.ordinal += 1
        next.eventDigests[envelope.eventID] = digest
        next.cursor = envelope.eventID
        let delta: (messageID: UUID, kind: String, text: String)?
        if frame.event == "content" || frame.event == "thinking",
           let id = UUID(uuidString: try requiredString(payload, "messageID")) {
            delta = (id, frame.event == "content" ? "content" : "reasoning",
                     try requiredString(payload, "delta", allowEmpty: true))
        } else { delta = nil }
        try store.saveEvent(next, eventID: envelope.eventID, digest: digest, delta: delta)
        journal = next
        diagnose(.event, .committed, event: envelope.eventID, bytes: frame.data.utf8.count)
        await onEvent(.runStreamActivity(runID: envelope.runID))
        for event in events { await onEvent(event); try Task.checkCancellation() }
        await publishState(onEvent)
        try Task.checkCancellation()
        if frame.event == "client_tool_request" {
            try await deliverTools(config: config, executor: tools, onEvent: onEvent)
        }
        if frame.event == "waiting_question" || frame.event == "waiting_confirmation" {
            try await publishInteraction(onEvent)
        }
        if frame.event == "decision_resolved" { await publishDecisions(onEvent) }
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
                let result: AgentToolResult?
                if let scope = record.submissionKey.flatMap({ journal.toolSnapshots?[$0]?.scope }),
                   let recovery = executor as? any AgentGatewayScopedToolRecovering {
                    result = try await recovery.recoveredResult(call: record.request.call, scope: scope)
                } else if let recovery = executor as? any AgentGatewayToolRecovering {
                    result = try await recovery.recoveredResult(call: record.request.call)
                } else { result = nil }
                guard let result else {
                    throw AgentGatewayError.toolOutcomeUnknown
                }
                try cacheToolResult(result, executionID: executionID, record: &record)
                await onEvent(.toolCompleted(callId: record.request.callID, name: record.request.name,
                    result: result, origin: record.messageOrigin))
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
                    record.expiryRejection = true
                } else if config.isolatedReadOnly || !journal.allowsTools ||
                            !journal.toolNames.contains(request.name) || executor == nil ||
                            !isAuthorized(record: record, executor: executor) {
                    result = .failure("Gateway tool is not authorized.", code: "NOT_AUTHORIZED")
                } else if journal.tools.values.filter({ $0.phase != "reserved" && $0.phase != "not_target" }).count >= min(config.maxToolRounds, journal.toolLimit) {
                    result = .failure("Gateway tool limit reached.", code: "TOOL_LIMIT")
                } else if let executor {
                    guard let key = record.submissionKey,
                          let schema = journal.toolSnapshots?[key]?.declarations
                            .first(where: { $0.name == request.name })?.wireValue["function"]?["parameters"] else {
                        throw AgentGatewayError.malformedPayload
                    }
                    let valid = (try? GenerationSchema.validate(try request.call.arguments(), schema: schema)) != nil
                    if !valid {
                        result = .failure("Gateway tool arguments do not match the submitted schema.",
                                          code: "INVALID_TOOL_ARGUMENTS")
                    } else {
                        record.phase = "executing"
                        journal.tools[executionID] = record
                        try store.save(journal)
                        diagnose(.tool, .started, call: request.callID)
                        await onEvent(.toolStarted(request.call, origin: record.messageOrigin))
                        try Task.checkCancellation()
                        if isAuthorized(record: record, executor: executor) {
                            result = await executor.execute(call: request.call)
                        } else {
                            result = .failure("Gateway tool declaration changed before execution.",
                                              code: "NOT_AUTHORIZED")
                        }
                        // Cache the result even if stop arrived during execution.
                        // The parent owns its durable side effect journal.
                    }
                } else { throw AgentGatewayError.malformedPayload }
                try cacheToolResult(result, executionID: executionID, record: &record)
                diagnose(.tool, .committed, call: request.callID, bytes: result.content.utf8.count)
                await onEvent(.toolCompleted(callId: request.callID, name: request.name,
                    result: result, origin: record.messageOrigin))
            }
            try Task.checkCancellation()
            if record.phase == "not_target" { continue }
            try await reportTool(record, executionID: executionID)
        }
    }

    private func isAuthorized(record: AgentGatewayToolRecord, executor: AgentToolExecuting?) -> Bool {
        guard let executor, let key = record.submissionKey,
              let snapshot = journal.toolSnapshots?[key], let owner = toolOwners[key],
              owner.id == snapshot.instanceID,
              ObjectIdentifier(owner.executor) == ObjectIdentifier(executor),
              snapshot.scope == (executor as? any AgentToolExecutionScoped)?.executionScope,
              let declared = snapshot.declarations.first(where: { $0.name == record.request.name }),
              let live = executor.specs().first(where: { $0.name == record.request.name }) else { return false }
        return declared.matches(live)
    }

    private func reportTool(_ saved: AgentGatewayToolRecord, executionID: String) async throws {
        try Task.checkCancellation()
        guard saved.phase == "completed", let content = saved.content,
              let failed = saved.isFailure, let runID = journal.runID else {
            throw AgentGatewayError.malformedPayload
        }
        guard saved.expiryRejection == true || timing.now().timeIntervalSince1970 < saved.request.expiresAt else {
            throw AgentGatewayError.toolRequestExpired
        }
        let key = "tool-" + executionID
        let body: JSONValue = .object(["schemaVersion": 1, "binding": try value(binding),
            "runID": .string(runID), "executionID": .string(executionID),
            "callID": .string(saved.request.callID), "content": .string(content),
            "isFailure": .bool(failed), "requestKey": .string(key)])
        let response = try await send(makeRequest(path: ["runs", runID, "tool-results"],
                                                   method: "POST", body: body, key: key), stage: .tool)
        try Task.checkCancellation()
        try checkHTTP(response.statusCode)
        var record = saved
        record.phase = "reported"
        journal.tools[executionID] = record
        try store.save(journal)
    }

    private func cacheToolResult(_ result: AgentToolResult, executionID: String,
                                 record: inout AgentGatewayToolRecord) throws {
        record.phase = "completed"
        record.content = result.content
        record.isFailure = result.isFailure
        record.summary = result.summary
        let request = record.request
        if record.messageOrigin == nil {
            // Compatibility with pre-provenance reservations: recover a host
            // association only when this journal has one matching assistant.
            let candidates = journal.messages.indices.filter {
                journal.messages[$0].toolCalls.contains { $0 == request.call }
            }
            let index = candidates.count == 1 ? candidates.first : journal.messages.firstIndex {
                $0.id == journal.currentAssistantID && $0.toolCalls.isEmpty
            }
            if let index {
                let scope = record.submissionKey.flatMap { journal.toolSnapshots?[$0]?.scope }
                journal.messages[index].runID = journal.runID
                journal.messages[index].executionScope = scope
                if journal.messages[index].toolCalls.isEmpty { journal.messages[index].toolCalls.append(request.call) }
                record.messageOrigin = .init(assistantID: journal.messages[index].id,
                    runID: journal.runID, scope: scope, executionID: request.executionID)
            }
        }
        if record.resultMessageID == nil { record.resultMessageID = UUID() }
        journal.tools[executionID] = record
        journal.contextUsage?.invalidate()
        let message = AgentMessage(id: record.resultMessageID ?? UUID(), role: .tool,
            content: result.content, toolCallId: request.callID, toolName: request.name,
            isFailure: result.isFailure, runID: record.messageOrigin?.runID,
            executionScope: record.messageOrigin?.scope, toolOrigin: record.messageOrigin)
        if let index = AgentToolMessageHistory.matchingIndex(message, in: journal.messages) {
            var replacement = message
            replacement.id = journal.messages[index].id
            record.resultMessageID = replacement.id
            journal.tools[executionID] = record
            journal.messages[index] = replacement
        } else { journal.messages.append(message) }
        try store.save(journal)
    }

    private func publishInteraction(_ onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws {
        guard let pending = journal.pendingInteraction, let payload = pending["payload"],
              let params = payload["params"], let runID = journal.runID else { return }
        let id = try requiredString(payload, "interactionID")
        if journal.decisionRecords?[id] != nil {
            // Replayed serverTime is not a current clock observation.
            try await refreshDecision(id)
            await publishDecisions(onEvent)
            return
        }
        guard case .number(let expiry)? = payload["expiresAt"] else { throw AgentGatewayError.malformedPayload }
        let kind: AgentInteraction.Kind = pending["kind"] == .string("waiting_question") ? .questions : .commandApproval
        let interaction = AgentInteraction(id: journal.legacyDecisionRecords?[id]?.localID ?? UUID(),
            kind: kind, params: params, identity: nil,
            timeout: max(0, expiry - timing.now().timeIntervalSince1970), state: .pending,
            reply: { [weak self] result in
                guard let self else { throw AgentGatewayError.noResumableRun }
                try await self.reply(runID: runID, interactionID: id, result: result)
                return .syncing
            }, readback: { [weak self] in
                guard let self else { throw AgentGatewayError.noResumableRun }
                return try await self.reconcileLegacyDecision(runID: runID, interactionID: id)
            })
        await onEvent(.interactionRequested(interaction))
    }

    private func decisionInteractions() -> [AgentInteraction] {
        let decisions = (journal.decisionRecords ?? [:]).values.sorted {
            $0.identity.createdAt == $1.identity.createdAt
                ? $0.identity.interactionID < $1.identity.interactionID : $0.identity.createdAt < $1.identity.createdAt
        }.map { record in
            let identity = record.identity
            // Pending forms need a fresh server observation before enabling
            // submit. All transport entry points recheck on the server.
            let remaining = decisionClocks[identity.interactionID].map {
                max(0, identity.expiresAt - $0.serverTime - (ProcessInfo.processInfo.systemUptime - $0.uptime))
            } ?? 0
            let state: AgentInteraction.State = record.state == .resolved && journal.phase == "streaming"
                ? .executing : record.state
            return AgentInteraction(id: record.localID,
                kind: identity.kind == "waiting_question" ? .questions : .commandApproval,
                params: record.params, identity: identity, timeout: remaining, state: state,
                reply: { [weak self] answer in
                    guard let self else { throw AgentGatewayError.noResumableRun }
                    return try await self.submitDecision(identity: identity, answer: answer)
                }, readback: { [weak self] in
                    guard let self else { throw AgentGatewayError.noResumableRun }
                    return try await self.reconcileDecision(identity: identity)
                }, refreshTimeout: { [weak self] in
                    await self?.decisionTimeRemaining(identity.interactionID) ?? 0
                }, sendSaved: { [weak self] in
                    guard let self else { throw AgentGatewayError.noResumableRun }
                    return try await self.sendSavedDecision(identity: identity)
                })
        }
        let legacy = (journal.legacyDecisionRecords ?? [:]).values.sorted { $0.interactionID < $1.interactionID }.map { record in
            AgentInteraction(id: record.localID,
                kind: record.kind == "waiting_question" ? .questions : .commandApproval,
                params: record.params, identity: nil,
                timeout: max(0, record.expiresAt - timing.now().timeIntervalSince1970),
                state: record.state(phase: journal.phase),
                reply: { [weak self] answer in
                    guard let self else { throw AgentGatewayError.noResumableRun }
                    try await self.reply(runID: record.runID, interactionID: record.interactionID, result: answer)
                    return .syncing
                }, readback: { [weak self] in
                    guard let self else { throw AgentGatewayError.noResumableRun }
                    return try await self.reconcileLegacyDecision(runID: record.runID, interactionID: record.interactionID)
                })
        }
        return decisions + legacy
    }

    private func decisionTimeRemaining(_ id: String) -> TimeInterval {
        guard let record = journal.decisionRecords?[id], let clock = decisionClocks[id] else { return 0 }
        return max(0, record.identity.expiresAt - clock.serverTime
                   - (ProcessInfo.processInfo.systemUptime - clock.uptime))
    }

    private func publishDecisions(_ onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async {
        for interaction in decisionInteractions() { await onEvent(.interactionRequested(interaction)) }
    }

    private func refreshDecisions() async throws {
        for id in (journal.decisionRecords ?? [:]).keys.sorted() {
            guard let record = journal.decisionRecords?[id],
                  record.state == .syncing || record.state == .saved else { continue }
            try await refreshDecision(id)
        }
    }

    private func refreshDecision(_ id: String) async throws {
        guard let record = journal.decisionRecords?[id] else { throw AgentGatewayError.noResumableRun }
        let response = try await controlSend(makeRequest(
            path: ["runs", record.identity.runID, "interactions", id], method: "GET"),
            deadline: timing.now().addingTimeInterval(timing.controlTimeout))
        if response.statusCode == 404 { throw AgentGatewayError.decisionOutcomeUnknown }
        try checkHTTP(response.statusCode)
        let receipt = try decode(AgentGatewayDecisionReceipt.self, response.body)
        try commitDecisionReceipt(receipt)
        decisionClocks[id] = (receipt.serverTime, ProcessInfo.processInfo.systemUptime)
    }

    private func commitDecisionReceipt(_ receipt: AgentGatewayDecisionReceipt) throws {
        guard var record = journal.decisionRecords?[receipt.interactionID] else {
            throw AgentGatewayError.originMismatch
        }
        try receipt.validate(for: record.identity)
        if let old = record.receipt {
            if old.state == "resolved" {
                guard receipt.state == "resolved", old.decision == receipt.decision else {
                    throw AgentGatewayError.originMismatch
                }
            } else if receipt.serverTime < old.serverTime { throw AgentGatewayError.originMismatch }
        }
        record.receipt = receipt
        var next = journal
        next.decisionRecords?[receipt.interactionID] = record
        if receipt.state != "pending",
           next.pendingInteraction?["payload"]?["interactionID"] == .string(receipt.interactionID) {
            next.pendingInteraction = nil
        }
        try store.save(next); journal = next
    }

    private func submitDecision(identity: AgentGatewayDecisionIdentity, answer: JSONValue) async throws -> AgentInteraction.State {
        try beginHotControl()
        defer { endHotControl() }
        guard let original = journal.decisionRecords?[identity.interactionID], original.identity == identity,
              journal.runID == identity.runID, original.submission == nil else {
            throw AgentGatewayError.decisionOutcomeUnknown
        }
        let submission = AgentGatewayDecisionSubmission(requestKey: UUID().uuidString,
            answerJSON: try answer.encodedText())
        _ = try Self.encodedRequestBody(decisionBody(identity, submission))
        // Claim durably before any network request. Even preflight failure
        // leaves the exact answer recoverable, never an editable replacement.
        var next = journal
        next.decisionRecords?[identity.interactionID]?.submission = submission
        do { try store.save(next); journal = next }
        catch {
            // No network has been invoked. A successful authoritative reload
            // distinguishes rollback from an uncertain storage outcome.
            let restored: AgentGatewayJournal
            do { restored = try store.load() }
            catch { throw AgentGatewayError.decisionStorageUnknown }
            journal = restored
            guard let record = restored.decisionRecords?[identity.interactionID],
                  record.identity == identity else { throw AgentGatewayError.decisionStorageUnknown }
            if record.submission == nil { throw AgentGatewayError.decisionNotSaved }
            guard record.submission == submission else { throw AgentGatewayError.decisionStorageUnknown }
            return record.state
        }
        return await dispatchSavedDecision(identity: identity)
    }

    private func decisionBody(_ identity: AgentGatewayDecisionIdentity,
                              _ submission: AgentGatewayDecisionSubmission) throws -> JSONValue {
        let body: JSONValue = .object([
            "schemaVersion": 1, "decisionSchemaVersion": 1,
            "binding": try value(identity.binding), "runID": .string(identity.runID),
            "clientInstanceID": .string(identity.clientInstanceID), "interactionID": .string(identity.interactionID),
            "requestRevision": .number(Double(identity.requestRevision)),
            "requestFingerprint": .string(identity.requestFingerprint),
            "requestKey": .string(submission.requestKey), "answerJSON": .string(submission.answerJSON)
        ])
        return body
    }

    private func sendSavedDecision(identity: AgentGatewayDecisionIdentity) async throws -> AgentInteraction.State {
        try beginHotControl()
        defer { endHotControl() }
        guard let record = journal.decisionRecords?[identity.interactionID], record.identity == identity,
              journal.runID == identity.runID else { throw AgentGatewayError.originMismatch }
        // The attempted flag is the authority even for a stale UI object.
        guard record.state == .saved, !record.attempted else { return record.state }
        return await dispatchSavedDecision(identity: identity)
    }

    private func dispatchSavedDecision(identity: AgentGatewayDecisionIdentity) async -> AgentInteraction.State {
        do {
            guard let record = journal.decisionRecords?[identity.interactionID], !record.attempted,
                  let submission = record.submission else { throw AgentGatewayError.decisionOutcomeUnknown }
            let body = try decisionBody(identity, submission)
            _ = try Self.encodedRequestBody(body)
            try await refreshDecision(identity.interactionID)
            guard journal.decisionRecords?[identity.interactionID]?.receipt?.state == "pending" else {
                return journal.decisionRecords?[identity.interactionID]?.state ?? .syncing
            }
            try Task.checkCancellation()
            var next = journal
            next.decisionRecords?[identity.interactionID]?.attempted = true
            try store.save(next); journal = next
            let response = try await controlSend(makeRequest(path: ["runs", identity.runID, "continue"],
                method: "POST", body: body, key: submission.requestKey),
                deadline: timing.now().addingTimeInterval(timing.controlTimeout))
            try checkHTTP(response.statusCode)
            let descriptor = try decode(AgentGatewayDescriptor.self, response.body)
            try validate(descriptor)
            guard descriptor.runID == identity.runID, descriptor.requestKey == submission.requestKey,
                  let receipt = descriptor.decisionReceipt, receipt.state == "resolved" else {
                throw AgentGatewayError.originMismatch
            }
            try commitDecisionReceipt(receipt)
            decisionClocks[identity.interactionID] = (receipt.serverTime, ProcessInfo.processInfo.systemUptime)
        } catch {
            // Readback only, including 409/410, timeout and dropped response.
            // Do not interpret 404 or pending as proof POST was not accepted.
            do { try await refreshDecision(identity.interactionID) } catch { }
        }
        return journal.decisionRecords?[identity.interactionID]?.state ?? .syncing
    }

    private func reconcileDecision(identity: AgentGatewayDecisionIdentity) async throws -> AgentInteraction.State {
        try beginHotControl()
        defer { endHotControl() }
        guard journal.decisionRecords?[identity.interactionID]?.identity == identity else {
            throw AgentGatewayError.originMismatch
        }
        try await refreshDecision(identity.interactionID)
        return journal.decisionRecords?[identity.interactionID]?.state ?? .syncing
    }

    private func reconcileLegacyDecision(runID: String, interactionID: String) async throws -> AgentInteraction.State {
        try beginHotControl()
        defer { endHotControl() }
        guard journal.runID == runID else { throw AgentGatewayError.originMismatch }
        if let command = journal.command {
            guard command.body["interactionID"] == .string(interactionID) else { throw AgentGatewayError.originMismatch }
            let response = try await controlSend(makeRequest(path: ["requests", command.key], method: "GET"),
                deadline: timing.now().addingTimeInterval(timing.controlTimeout))
            if response.statusCode == 404 { return .syncing }
            try checkHTTP(response.statusCode)
            let descriptor = try decode(AgentGatewayDescriptor.self, response.body)
            try validate(descriptor)
            guard descriptor.runID == runID, descriptor.requestKey == command.key else { throw AgentGatewayError.originMismatch }
            var next = journal
            next.command = nil; next.pendingInteraction = nil
            next.legacyDecisionRecords?[interactionID]?.acceptedKey = command.key
            try store.save(next); journal = next
            return .resolved
        }
        return journal.legacyDecisionRecords?[interactionID]?.state(phase: journal.phase) ?? .superseded
    }

    private func beginHotControl() throws {
        guard !controlling, !hotControl, !loadFailed else { throw AgentGatewayError.busy }
        try validateConfiguration()
        try retainJournalLock()
        do {
            if !busy { journal = try store.load() }
            try restoreLegacyDecision()
            hotControl = true
        } catch {
            releaseJournalLock(); throw error
        }
    }

    private func endHotControl() {
        hotControl = false
        releaseJournalLock()
    }

    /// Retains the active run's lock across actor reentrancy; never cancels its
    /// model or tools. Exact input and key are committed before the first POST.
    public func submitSteer(message: AgentMessage, runID: String) async throws -> AgentGatewaySteerSnapshot {
        try beginHotControl()
        defer { endHotControl() }
        guard journal.runID == runID else { throw AgentGatewayError.originMismatch }
        let id = message.id.uuidString
        if let existing = journal.steerSubmissions?[id] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard try encoder.encode(message) == existing.messageData else {
                throw AgentGatewayError.originMismatch
            }
            return try await reconcileSteerLocked(id, runID: runID)
        }
        let deadline = timing.now().addingTimeInterval(timing.controlTimeout)
        let descriptor = try await query(runID, deadline: deadline)
        guard !controlling, descriptor.steerCapability?.accepting == true,
              journal.wireMessageOffset != nil,
              let capability = descriptor.steerCapability else { throw AgentGatewayError.steerNotReady }
        let states = journal.steerStates ?? [:]
        guard states.count < capability.maxPerRun,
              states.values.filter({ $0.receipt == nil || $0.receipt?.state == .accepted }).count
                < capability.maxPending else { throw AgentGatewayError.requestTooLarge }
        guard !journal.messages.contains(where: { $0.id == message.id }) else {
            throw AgentGatewayError.originMismatch
        }
        let submission = try AgentGatewaySteerSubmission(message: message, binding: binding, runID: runID,
            clientInstanceID: journal.clientInstanceID, supportsImages: journal.steerSupportsImages == true)
        var next = journal
        var submissions = next.steerSubmissions ?? [:]; submissions[id] = submission
        var local = next.steerStates ?? [:]; local[id] = .init(attempted: true)
        next.steerSubmissions = submissions; next.steerStates = local
        try store.save(next); journal = next
        var request = try makeRequest(path: ["runs", runID, "steer"], method: "POST", key: submission.requestKey)
        request.httpBody = submission.requestBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await controlSend(request, deadline: deadline)
        try Task.checkCancellation()
        try checkHTTP(response.statusCode)
        let receipt = try decode(AgentGatewaySteerReceipt.self, response.body)
        guard receipt.state == .accepted else { throw AgentGatewayError.malformedPayload }
        try commitSteerReceipt(receipt)
        return try steerSnapshot(id)
    }

    /// Unknown outcomes only query the original identity. A 404 cannot create
    /// a second submission, change bytes, or start another model request.
    public func hasSteerSubmission(submissionID: UUID, runID: String) throws -> Bool {
        guard journal.runID == runID else { throw AgentGatewayError.originMismatch }
        return journal.steerSubmissions?[submissionID.uuidString] != nil
    }

    public func reconcileSteer(submissionID: UUID, runID: String) async throws -> AgentGatewaySteerSnapshot {
        try beginHotControl()
        defer { endHotControl() }
        guard journal.runID == runID else { throw AgentGatewayError.originMismatch }
        return try await reconcileSteerLocked(submissionID.uuidString, runID: runID)
    }

    private func reconcileSteerLocked(_ id: String, runID: String) async throws -> AgentGatewaySteerSnapshot {
        guard let submission = journal.steerSubmissions?[id] else { throw AgentGatewayError.malformedPayload }
        let deadline = timing.now().addingTimeInterval(timing.controlTimeout)
        let original = try await controlSend(makeRequest(path: ["requests", submission.requestKey],
            method: "GET"), deadline: deadline)
        try Task.checkCancellation()
        if original.statusCode != 404 {
            try checkHTTP(original.statusCode)
            let accepted = try decode(AgentGatewaySteerReceipt.self, original.body)
            guard accepted.state == .accepted else { throw AgentGatewayError.malformedPayload }
            try commitSteerReceipt(accepted)
        }
        let latest = try await controlSend(makeRequest(path: ["runs", runID, "steers", id],
            method: "GET"), deadline: deadline)
        try Task.checkCancellation()
        if latest.statusCode == 404 { throw AgentGatewayError.interrupted }
        try checkHTTP(latest.statusCode)
        try commitSteerReceipt(decode(AgentGatewaySteerReceipt.self, latest.body))
        return try steerSnapshot(id)
    }

    private func commitSteerReceipt(_ receipt: AgentGatewaySteerReceipt) throws {
        var next = journal
        try receiveSteer(receipt, event: false, into: &next)
        try store.save(next); journal = next
    }

    private func receiveSteer(_ receipt: AgentGatewaySteerReceipt, event: Bool,
                              into next: inout AgentGatewayJournal) throws {
        guard let submission = next.steerSubmissions?[receipt.submissionID],
              var state = next.steerStates?[receipt.submissionID] else {
            throw AgentGatewayError.originMismatch
        }
        try submission.validate(receipt)
        guard !(next.steerStates ?? [:]).contains(where: {
            $0.key != receipt.submissionID && $0.value.receipt?.sequence == receipt.sequence
        }) else { throw AgentGatewayError.malformedPayload }
        state.receipt = try AgentGatewaySteerReceipt.reduce(state.receipt, incoming: receipt)
        if event, receipt.state != .accepted {
            if receipt.state == .placed, !state.eventApplied {
                guard let placement = receipt.placement, let offset = next.wireMessageOffset,
                      offset + next.messages.count == placement.messageIndex,
                      next.currentAssistantID == nil,
                      !next.messages.contains(where: { $0.id.uuidString == receipt.messageID }) else {
                    throw AgentGatewayError.malformedPayload
                }
                next.messages.append(try submission.message)
                next.contextUsage?.invalidate()
            }
            state.eventApplied = true
        }
        next.steerStates?[receipt.submissionID] = state
    }

    private func reply(runID: String, interactionID: String, result: JSONValue) async throws {
        guard !busy, !controlling else { throw AgentGatewayError.busy }
        let lock = try store.acquire()
        defer { store.release(lock) }
        journal = try store.load()
        try restoreLegacyDecision()
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
        journal.legacyDecisionRecords?[interactionID]?.submissionKey = key
        try store.save(journal)
        // Dispatch/reconciliation happens on resume. A reply is durably queued
        // here, not falsely acknowledged as delivered to the service.
    }

    private func restoreLegacyDecision() throws {
        guard let pending = journal.pendingInteraction, let payload = pending["payload"],
              payload["decisionSchemaVersion"] == nil, let runID = journal.runID,
              let id = payload["interactionID"]?.stringValue,
              let kind = pending["kind"]?.stringValue,
              let params = payload["params"], case .number(let expiry)? = payload["expiresAt"],
              journal.legacyDecisionRecords?[id] == nil else { return }
        let key = journal.command.flatMap {
            $0.body["interactionID"] == .string(id) ? $0.key : nil
        }
        var next = journal
        if next.legacyDecisionRecords == nil { next.legacyDecisionRecords = [:] }
        next.legacyDecisionRecords?[id] = .init(localID: UUID(), runID: runID, interactionID: id,
            kind: kind, params: params, expiresAt: expiry, submissionKey: key, acceptedKey: nil)
        try store.save(next); journal = next
    }

    public func cancelRun() async {
        await cancelRun(deadline: timing.now().addingTimeInterval(timing.controlTimeout))
    }

    private func cancelRun(deadline: Date) async {
        guard !controlling else { return }
        controlling = true
        defer { controlling = false }
        operation?.cancel()
        while hotControl {
            if timing.now() >= deadline { return }
            await Task.yield()
        }
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
                if let id = command.body["interactionID"]?.stringValue,
                   journal.legacyDecisionRecords?[id]?.submissionKey == command.key {
                    journal.legacyDecisionRecords?[id]?.acceptedKey = command.key
                }
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
        let start = ProcessInfo.processInfo.systemUptime
        let remaining = deadline.timeIntervalSince(timing.now())
        guard remaining > 0 else { throw AgentGatewayError.steerNotReady }
        var bounded = request
        bounded.timeoutInterval = remaining
        let boundedRequest = bounded
        let transport = self.transport
        do {
        let response = try await withThrowingTaskGroup(of: AgentGatewayHTTPResponse.self) { group in
            group.addTask { try await transport.send(request: boundedRequest) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                throw AgentGatewayError.steerNotReady
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AgentGatewayError.steerNotReady }
            return first
        }
        diagnose(.control, (200..<300).contains(response.statusCode) ? .completed : .rejected,
                 elapsed: ProcessInfo.processInfo.systemUptime - start, status: response.statusCode)
        return response
        } catch {
            diagnose(.control, error is CancellationError ? .cancelled : .unknown,
                     elapsed: ProcessInfo.processInfo.systemUptime - start, error: error)
            throw error
        }
    }

    private static func encodedRequestBody(_ body: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(body)
        guard data.count <= 8 * 1024 * 1024 else { throw AgentGatewayError.requestTooLarge }
        return data
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
            request.httpBody = try Self.encodedRequestBody(body)
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
        if ["recovering", "unknown", "blocked", "failed", "cancelled"].contains(phase) {
            next.contextUsage?.interrupt()
            next.compactions?.interrupt()
        } else if phase == "completed" {
            next.contextUsage?.finishLoading()
            next.compactions?.interrupt()
        }
        try store.save(next)
        journal = next
    }

    private func publishState(_ onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async {
        await onEvent(.steerCapability(journal.steerCapability))
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
