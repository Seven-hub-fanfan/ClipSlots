import Foundation

public struct AgentRunBinding: Codable, Equatable, Sendable {
    public let sessionID: String
    public let projectID: String?
    public let canvasID: String?

    public init(sessionID: String, projectID: String? = nil, canvasID: String? = nil) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.canvasID = canvasID
    }
}

public protocol AgentGatewayResuming: AgentBackend {
    var hasResumableRun: Bool { get async }
    var snapshot: AgentGatewayRunSnapshot { get async }
    @discardableResult
    func resume(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
                onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage]
    func cancelRun() async
    func waitUntilReadyToSteer() async throws -> Bool
}

public struct AgentGatewayHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data = Data()) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// Both paths are injectable; fixtures never need a listener or a real API key.
public protocol AgentGatewayTransport: Sendable {
    func send(request: URLRequest) async throws -> AgentGatewayHTTPResponse
    func stream(request: URLRequest) async throws -> AgentHTTPStream
}

/// Recovery must only inspect a durable result, never invoke the tool again.
public protocol AgentGatewayToolRecovering: AgentToolExecuting {
    func recoveredResult(call: AgentToolCall) async throws -> AgentToolResult?
}

public protocol AgentGatewayScopedToolRecovering: AgentGatewayToolRecovering, AgentToolExecutionScoped {
    func recoveredResult(call: AgentToolCall, scope: AgentExecutionScope) async throws -> AgentToolResult?
}

public struct AgentGatewayTiming: Sendable {
    public let sleep: @Sendable (TimeInterval) async throws -> Void
    public let now: @Sendable () -> Date
    public let controlTimeout: TimeInterval

    public init(
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
        },
        now: @escaping @Sendable () -> Date = { Date() },
        controlTimeout: TimeInterval = 30
    ) {
        self.sleep = sleep
        self.now = now
        self.controlTimeout = controlTimeout.isFinite ? min(30, max(0.001, controlTimeout)) : 30
    }
}

public enum AgentGatewayError: Error, LocalizedError, Equatable {
    case invalidConfiguration
    case busy
    case resumableRunExists
    case noResumableRun
    case http(Int)
    case malformedPayload
    case requestTooLarge
    case originMismatch
    case journalUnavailable
    case interrupted
    case toolOutcomeUnknown
    case toolRequestExpired
    case remoteFailed
    case steerNotReady
    case decisionOutcomeUnknown
    case decisionNotSaved
    case decisionStorageUnknown

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Invalid gateway URL or session binding."
        case .busy: return "This gateway binding is already running."
        case .resumableRunExists: return "Resume or cancel the existing run before creating another."
        case .noResumableRun: return "There is no resumable gateway run."
        case .http(let status): return "Gateway HTTP \(status)."
        case .malformedPayload: return "Gateway payload does not satisfy the v1 contract."
        case .requestTooLarge: return "本轮完整消息超过网关 8 MiB 限制，请减少附件或开启新会话；内容已保留。"
        case .originMismatch: return "Gateway event belongs to a different origin or run."
        case .journalUnavailable: return "Gateway journal cannot be read or committed."
        case .interrupted: return "Gateway outcome is unknown; the run remains resumable."
        case .toolOutcomeUnknown: return "Interrupted tool execution needs reconciliation; it was not repeated."
        case .toolRequestExpired: return "Tool result was saved locally after its delivery deadline; it was not submitted."
        case .remoteFailed: return "The gateway explicitly reported run failure."
        case .steerNotReady: return "Remote termination was not confirmed; keep the queued submission."
        case .decisionOutcomeUnknown: return "回答已保留，服务端接受结果待核对；没有自动重发。"
        case .decisionNotSaved: return "回答未能保存，尚未发送；请重试保存原回答。"
        case .decisionStorageUnknown: return "无法核实回答的保存状态，尚未发起发送；请恢复本地存储后核对原请求。"
        }
    }
}

public struct AgentGatewayRunSnapshot: Sendable {
    public let binding: AgentRunBinding
    public let runID: String?
    public let phase: String
    public let cursor: String?
    public let messages: [AgentMessage]
    public let clientInstanceID: String
    public let currentAssistantID: UUID?
    public let completedAssistantIDs: Set<UUID>
    public let artifactUpdates: [JSONValue]
    public var artifactToolContexts: [String: AgentAppReplyToolContext] = [:]
    public let canvasMutations: [JSONValue]
    public let canvasReadbacks: [AgentCanvasReadbackRequest]
    public let subagentCanvasScopes: [String: String]
    public let contextUsage: AgentContextUsageState
    public let compactions: AgentContextCompactionLifecycle
    public var taskSubagents: AgentTaskSubagentProjection = .init()
    public var steerCapability: AgentGatewaySteerCapability?
    public var steers: [AgentGatewaySteerSnapshot] = []
    public var interactions: [AgentInteraction] = []

    public func appReplyToolContext(for payload: JSONValue) -> AgentAppReplyToolContext? {
        guard let value = payload["appReplyAuthority"],
              let bytes = try? JSONEncoder().encode(value),
              let authority = try? JSONDecoder().decode(AgentAppReplyAuthority.self, from: bytes) else { return nil }
        return artifactToolContexts[AgentAppReplyToolContext.key(for: authority)]
    }
}

/// Redirects are denied on both paths, so credentials cannot escape the
/// configured origin. Transport errors/bodies are never interpolated into logs.
public final class URLSessionAgentGatewayTransport: NSObject, AgentGatewayTransport,
    URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        super.init()
    }

    private func makeSession() -> URLSession {
        let config = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 1_200
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func send(request: URLRequest) async throws -> AgentGatewayHTTPResponse {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return .init(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
    }

    public func stream(request: URLRequest) async throws -> AgentHTTPStream {
        let session = makeSession()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let chunks = AsyncThrowingStream<Data, Error> { continuation in
                let reader = Task {
                    defer { session.invalidateAndCancel() }
                    do {
                        var data = Data()
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            data.append(byte)
                            if byte == 10 || byte == 13 || data.count >= 8192 {
                                continuation.yield(data)
                                data.removeAll(keepingCapacity: true)
                            }
                        }
                        if !data.isEmpty { continuation.yield(data) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in
                    reader.cancel()
                    session.invalidateAndCancel()
                }
            }
            return .init(statusCode: status, chunks: chunks)
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }
}

struct AgentGatewayDescriptor: Codable {
    let schemaVersion: Int
    let binding: AgentRunBinding
    let runID: String
    let phase: String
    let requestKey: String?
    let steerCapability: AgentGatewaySteerCapability?
    let decisionCapability: AgentGatewayDecisionCapability?
    let decisionReceipt: AgentGatewayDecisionReceipt?
    var clientInstanceID: String? = nil
}

struct AgentGatewayEnvelope: Codable {
    let schemaVersion: Int
    let binding: AgentRunBinding
    let runID: String
    let eventID: String
    let payload: JSONValue
}

struct AgentGatewayToolRequest: Codable, Equatable {
    let executionID: String
    let callID: String
    let name: String
    let argumentsJSON: String
    let targetClientInstanceID: String
    /// Unix seconds, not a client-relative timeout.
    let expiresAt: Double

    var call: AgentToolCall { .init(id: callID, name: name, argumentsJSON: argumentsJSON) }
}

struct AgentGatewayCommand: Codable {
    let key: String
    let path: [String]
    let body: JSONValue
    var attempted: Bool
}

struct AgentGatewayToolRecord: Codable {
    let request: AgentGatewayToolRequest
    var phase: String
    var content: String?
    var isFailure: Bool?
    var summary: String?
    var submissionKey: String?
    var expiryRejection: Bool?
    var messageOrigin: AgentToolMessageOrigin?
    var resultMessageID: UUID?
}

/// Exact local declaration and ownership at submission. A fresh executor may
/// reconcile a durable result, but never inherits an old instance's authority
/// to begin side effects after resume or process restart.
struct AgentGatewayToolSnapshot: Codable {
    typealias Declaration = AgentAppReplyToolContext.Declaration
    let instanceID: UUID
    let scope: AgentExecutionScope?
    let declarations: [Declaration]
}

struct AgentGatewayJournal: Codable {
    var schemaVersion = 1
    let origin: String
    let binding: AgentRunBinding
    let clientInstanceID: String
    var runID: String?
    var phase = "idle"
    var cursor: String?
    var ordinal = 0
    var eventDigests: [String: String] = [:]
    var messages: [AgentMessage] = []
    var currentAssistantID: UUID?
    var completedAssistantIDs: Set<UUID> = []
    var command: AgentGatewayCommand?
    var tools: [String: AgentGatewayToolRecord] = [:]
    var allowsTools = false
    var toolNames: Set<String> = []
    var toolLimit = 0
    var toolSubmissionKey: String?
    var toolSnapshots: [String: AgentGatewayToolSnapshot]?
    var pendingInteraction: JSONValue?
    var diagnosticCount = 0
    // Optional storage fields keep existing v1 journals decodable. Snapshots
    // normalize missing values to empty arrays; callbacks are not acknowledgments.
    var artifactUpdates: [JSONValue]?
    var canvasMutations: [JSONValue]?
    var canvasReadbacks: [AgentCanvasReadbackRequest]?
    var subagentCanvasProjection: AgentSubagentCanvasProjection?
    var contextUsage: AgentContextUsageState?
    var compactions: AgentContextCompactionLifecycle?
    var taskSubagents: AgentTaskSubagentProjection?
    var steerCapability: AgentGatewaySteerCapability?
    var steerSupportsImages: Bool?
    var wireMessageOffset: Int?
    var steerSubmissions: [String: AgentGatewaySteerSubmission]?
    var steerStates: [String: AgentGatewaySteerLocalState]?
    var decisionRecords: [String: AgentGatewayDecisionRecord]?
    var legacyDecisionRecords: [String: AgentGatewayLegacyDecisionRecord]?
    var appReply: AgentAppReplySnapshot?
    var artifactToolContexts: [String: AgentAppReplyToolContext]?
    var appReplyToolContext: AgentAppReplyToolContext?
    var nativeToolContextRows: Set<String>?
    var nativeToolMessagePresence: String?

    var resumable: Bool {
        command != nil || (runID != nil && !["completed", "failed", "cancelled"].contains(phase))
            || (decisionRecords ?? [:]).values.contains { $0.state == .syncing || $0.state == .saved }
            || (legacyDecisionRecords ?? [:]).values.contains { $0.submissionKey != nil && $0.acceptedKey == nil }
            || (steerStates ?? [:]).values.contains {
                $0.receipt == nil || $0.receipt?.state == .accepted
                    || ($0.receipt?.state == .placed && !$0.eventApplied)
            }
    }
}
