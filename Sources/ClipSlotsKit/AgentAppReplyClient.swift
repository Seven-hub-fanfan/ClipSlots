import Foundation

/// No background POST, no preference lookup, and no legacy chat fallback.
public actor AgentAppReplyClient {
    static let rejections: Set<Int> = [400, 401, 403, 404, 405, 409, 413, 422, 429]
    private let store: AgentAppReplyStore
    private let transport: any AgentGatewayTransport
    private let credential: @Sendable (URL) -> String?
    private var posting: Set<String> = []
    private var reading: Set<String> = []

    public init(directory: URL, transport: any AgentGatewayTransport = URLSessionAgentGatewayTransport(),
                credential: @escaping @Sendable (URL) -> String? = { _ in nil }) throws {
        store = try AgentAppReplyStore(directory: directory)
        self.transport = transport; self.credential = credential
    }

    #if DEBUG
    init(store: AgentAppReplyStore, transport: any AgentGatewayTransport,
         credential: @escaping @Sendable (URL) -> String?) {
        self.store = store; self.transport = transport; self.credential = credential
    }
    #endif

    public func snapshot(replyID: String) throws -> AgentAppReplySnapshot? {
        try store.load(replyID)
    }

    public func snapshots(binding: AgentRunBinding) throws -> [AgentAppReplySnapshot] {
        try store.records(binding: binding)
    }

    /// Persist before capability queries or submission. Failed saving implies zero POST.
    public func submit(_ submission: AgentAppReplySubmission,
                       authorize: @Sendable () async throws -> Void = {}) async throws -> AgentAppReplySnapshot {
        do {
            try Task.checkCancellation(); try await authorize()
            let record = try store.prepare(submission)
            if record.receipt != nil { return record }
            guard record.state == .saved else { throw outcome(record) }
            return try await post(record, explicitRetry: false, authorize: authorize)
        } catch let error as AgentAppReplyError { throw error }
        catch { throw AgentAppReplyError.preflight }
    }

    /// The caller must expose this as a distinct explicit action after unknown.
    /// Retrying an accepted reply only returns the receipt; it never restarts execution.
    public func retry(replyID: String, expectedAttempt: UInt64,
                      authorize: @Sendable () async throws -> Void = {}) async throws -> AgentAppReplySnapshot {
        do { try await authorize(); try Task.checkCancellation() }
        catch { throw AgentAppReplyError.preflight }
        guard let record = try store.load(replyID) else { throw AgentAppReplyError.preflight }
        if record.receipt != nil { return record }
        guard record.attempt == expectedAttempt else { throw AgentAppReplyError.unknown }
        return try await post(record, explicitRetry: true, authorize: authorize)
    }

    /// 404 is absence of a receipt, never permission to automatically submit again.
    public func reconcile(replyID: String,
                          authorize: @Sendable () async throws -> Void = {}) async throws -> AgentAppReplySnapshot {
        guard !reading.contains(replyID), let record = try store.load(replyID), record.attempt > 0 else {
            throw AgentAppReplyError.preflight
        }
        reading.insert(replyID); defer { reading.remove(replyID) }
        do {
            try await authorize(); try Task.checkCancellation()
            let response = try await transport.send(request: request(record.submission.origin,
                path: ["runs", record.submission.origin.authority.originRunID, "app-replies", replyID]))
            guard response.statusCode == 200 else { throw AgentAppReplyError.unknown }
            let receipt = try decode(AgentAppReplyReceipt.self, response.body)
            // Durable acceptance survives a page closing during readback.
            let saved = try store.accept(replyID, receipt: receipt, readback: true)
            try await authorize(); try Task.checkCancellation()
            return saved
        } catch { throw AgentAppReplyError.unknown }
    }

    public func validateManifest(origin: AgentAppReplyOrigin,
                                 authorize: @Sendable () async throws -> Void = {}) async throws -> AgentAppReplyAuthority {
        do {
            try origin.validate(); try await authorize(); try Task.checkCancellation()
            let response = try await transport.send(request: request(origin,
                path: ["runs", origin.authority.originRunID, "artifacts", origin.authority.artifactID,
                       "app-reply-manifest"]))
            try await authorize(); try Task.checkCancellation()
            guard response.statusCode == 200 else { throw AgentAppReplyError.preflight }
            let authority = try decode(AgentAppReplyAuthority.self, response.body)
            try authority.validate()
            guard authority == origin.authority else { throw AgentAppReplyError.preflight }
            return authority
        } catch { throw AgentAppReplyError.preflight }
    }

    private func outcome(_ record: AgentAppReplySnapshot) -> AgentAppReplyError {
        record.rejectionStatus.map(AgentAppReplyError.rejected) ?? .unknown
    }

    private func post(_ record: AgentAppReplySnapshot, explicitRetry: Bool,
                      authorize: @Sendable () async throws -> Void) async throws -> AgentAppReplySnapshot {
        let submission = record.submission, id = submission.replyID
        guard !posting.contains(id) else { throw AgentAppReplyError.unknown }
        posting.insert(id); defer { posting.remove(id) }
        let command: URLRequest
        do {
            try await authorize(); try Task.checkCancellation()
            if !explicitRetry || record.attempt == 0 {
                _ = try await validateManifest(origin: submission.origin, authorize: authorize)
                try await authorize(); try Task.checkCancellation()
                let health = try await transport.send(request: request(submission.origin, path: ["health"]))
                guard health.statusCode == 200,
                      try decode(JSONValue.self, health.body)["appReplyExecution"] == true else {
                    throw AgentAppReplyError.preflight
                }
            }
            try await authorize(); try Task.checkCancellation()
            command = try request(submission.origin,
                path: ["runs", submission.origin.authority.originRunID, "app-replies"], submission: submission)
        } catch { throw AgentAppReplyError.preflight }
        // No await between the durable reservation and initiating this exact HTTP command.
        let attempted = try store.claim(id, expectedAttempt: record.attempt, explicitRetry: explicitRetry)
        do {
            let response = try await transport.send(request: command)
            if Self.rejections.contains(response.statusCode) {
                let latest = try store.reject(id, attempt: attempted.attempt, status: response.statusCode)
                if latest.receipt != nil { return latest }
                throw AgentAppReplyError.rejected(response.statusCode)
            }
            guard response.statusCode == 200 else { throw AgentAppReplyError.unknown }
            let receipt = try decode(AgentAppReplyReceipt.self, response.body)
            let saved = try store.accept(id, receipt: receipt, readback: false)
            try await authorize(); try Task.checkCancellation()
            return saved
        } catch AgentAppReplyError.rejected(let status) { throw AgentAppReplyError.rejected(status) }
        catch { throw AgentAppReplyError.unknown }
    }

    private func request(_ origin: AgentAppReplyOrigin, path: [String],
                         submission: AgentAppReplySubmission? = nil) throws -> URLRequest {
        try origin.validate()
        guard var parts = URLComponents(url: origin.endpoint, resolvingAgainstBaseURL: false) else {
            throw AgentAppReplyError.preflight
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let suffix = try path.map { segment -> String in
            guard AgentGatewayDecisionIdentity.opaque(segment),
                  let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw AgentAppReplyError.preflight
            }
            return encoded
        }.joined(separator: "/")
        parts.percentEncodedPath = parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/" + suffix
        if !parts.percentEncodedPath.hasPrefix("/") { parts.percentEncodedPath = "/" + parts.percentEncodedPath }
        guard let url = parts.url else { throw AgentAppReplyError.preflight }
        var request = URLRequest(url: url); request.httpMethod = submission == nil ? "GET" : "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let submission {
            request.httpBody = submission.requestBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(submission.replyID, forHTTPHeaderField: "Idempotency-Key")
        }
        if let secret = credential(origin.endpoint), !secret.isEmpty {
            guard !secret.contains("\r"), !secret.contains("\n") else { throw AgentAppReplyError.preflight }
            request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard data.count <= 64 * 1024 else { throw AgentAppReplyError.unknown }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw AgentAppReplyError.unknown }
    }
}
