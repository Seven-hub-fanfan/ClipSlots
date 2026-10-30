import Foundation

/// Answers are protocol data, never persisted as chat confirmation summaries.
/// Gateway requests retain original identity in their private durable journal.
public final class AgentInteraction: Identifiable, @unchecked Sendable {
    public enum Kind: Equatable, Sendable { case commandApproval, fileApproval, questions }
    public enum State: String, Codable, Equatable, Sendable {
        case pending, saving, saved, syncing, storageUnknown, resolved, executing, expired, superseded, conflict, invalidated
        public var accepted: Bool { self == .resolved || self == .executing }
        public var summary: String {
            switch self {
            case .pending: return "等待回答"
            case .saving: return "正在保存回答"
            case .saved: return "回答已保存，尚未尝试发送"
            case .syncing: return "回答已保留，接受结果待核对"
            case .storageUnknown: return "暂时无法确认回答是否已保存，请核对原请求"
            case .resolved: return "回答已接受，后续执行尚未确认"
            case .executing: return "回答已接受，后续任务进行中"
            case .expired: return "原请求已过期"
            case .superseded: return "原请求已结束"
            case .conflict: return "原请求已由另一份回复解决"
            case .invalidated: return "请求已失效"
            }
        }
    }
    public struct Question: Identifiable, Sendable {
        public let id: String
        public let header: String
        public let text: String
        public let options: [String]
        public let descriptions: [String]
        public let allowsOther: Bool
        public let secret: Bool
    }

    public let id: UUID
    public let kind: Kind
    public let params: JSONValue
    public let expiresAt: Date
    public let questions: [Question]
    public let gatewayIdentity: AgentGatewayDecisionIdentity?
    public let isGateway: Bool
    private let lock = NSLock()
    private var currentState: State
    private var expiryUptime: TimeInterval
    private let reply: @Sendable (JSONValue) async throws -> State
    private let readback: (@Sendable () async throws -> State)?
    private let refreshTimeout: (@Sendable () async -> TimeInterval)?
    private let sendSaved: (@Sendable () async throws -> State)?

    public init(kind: Kind, params: JSONValue, timeout: TimeInterval = 300,
                reply: @escaping @Sendable (JSONValue) async throws -> Void) {
        self.id = UUID(); self.gatewayIdentity = nil; self.isGateway = false
        self.kind = kind
        self.params = params
        self.expiresAt = Date().addingTimeInterval(timeout)
        self.expiryUptime = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        self.currentState = .pending; self.readback = nil
        self.refreshTimeout = nil
        self.sendSaved = nil
        self.reply = { result in try await reply(result); return .resolved }
        self.questions = Self.parseQuestions(params)
    }

    init(id: UUID, kind: Kind, params: JSONValue, identity: AgentGatewayDecisionIdentity?,
         timeout: TimeInterval, state: State,
         reply: @escaping @Sendable (JSONValue) async throws -> State,
         readback: @escaping @Sendable () async throws -> State,
         refreshTimeout: (@Sendable () async -> TimeInterval)? = nil,
         sendSaved: (@Sendable () async throws -> State)? = nil) {
        self.id = id; self.kind = kind; self.params = params; self.gatewayIdentity = identity
        self.isGateway = true; self.currentState = state
        self.expiresAt = Date().addingTimeInterval(max(0, timeout))
        self.expiryUptime = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        self.reply = reply; self.readback = readback; self.questions = Self.parseQuestions(params)
        self.refreshTimeout = refreshTimeout
        self.sendSaved = sendSaved
    }

    private static func parseQuestions(_ params: JSONValue) -> [Question] {
        (params["questions"]?.arrayValue ?? []).compactMap { value in
            guard let id = value["id"]?.stringValue, !id.isEmpty,
                  let text = value["question"]?.stringValue else { return nil }
            let options = value["options"]?.arrayValue ?? []
            return Question(id: id, header: value["header"]?.stringValue ?? "",
                text: text, options: options.compactMap { $0["label"]?.stringValue },
                descriptions: options.map { $0["description"]?.stringValue ?? "" },
                allowsOther: options.isEmpty || value["isOther"]?.boolValue == true,
                secret: value["isSecret"]?.boolValue ?? false)
        }
    }

    public var state: State { lock.withLock { currentState } }
    public var isPending: Bool {
        lock.withLock { currentState == .pending && ProcessInfo.processInfo.systemUptime < expiryUptime }
    }
    public var remainingTime: TimeInterval {
        lock.withLock { max(0, expiryUptime - ProcessInfo.processInfo.systemUptime) }
    }
    public var canReconcile: Bool { readback != nil && state != .invalidated }
    public var canSendSaved: Bool { sendSaved != nil && state == .saved }
    public func invalidate() {
        lock.withLock { if !currentState.accepted { currentState = .invalidated } }
    }
    public func expire() -> Bool {
        lock.withLock {
            guard currentState == .pending, ProcessInfo.processInfo.systemUptime >= expiryUptime else { return false }
            currentState = .expired
            return true
        }
    }
    public var canAccept: Bool {
        params["availableDecisions"]?.arrayValue.map { $0.contains(.string("accept")) } ?? true
    }
    public var canDecline: Bool { Self.decisions(params).contains("decline") }
    public var batchItems: [JSONValue] { params["items"]?.arrayValue ?? [] }
    public var requiresCostDecision: Bool { params["cost"] != nil }
    public static func decisions(_ params: JSONValue) -> [String] {
        params["availableDecisions"]?.arrayValue?.compactMap(\.stringValue) ?? ["accept", "decline"]
    }

    public func accepts(_ result: JSONValue) -> Bool {
        guard let fields = result.objectValue else { return false }
        var expected: Set<String> = []
        if requiresCostDecision {
            expected.insert("costDecision")
            guard let cost = params["cost"], let decision = result["costDecision"]?.stringValue,
                  Self.decisions(cost).contains(decision) else { return false }
        }
        switch kind {
        case .commandApproval, .fileApproval:
            if params["items"] != nil {
                expected.insert("items")
                guard Set(fields.keys) == expected, !batchItems.isEmpty,
                      let items = result["items"]?.arrayValue, items.count == batchItems.count else { return false }
                var indices: Set<Double> = []
                return zip(batchItems, items).allSatisfy { original, item in
                    guard case .number(let index)? = original["index"], index.isFinite, index >= 0,
                          index.rounded() == index, indices.insert(index).inserted,
                          let action = original["action"]?.stringValue, !action.isEmpty,
                          item["index"] == original["index"], item["action"] == original["action"],
                          Set(item.objectValue?.keys.map { $0 } ?? []) == ["index", "action", "decision", "modifications"],
                          let decision = item["decision"]?.stringValue, Self.decisions(original).contains(decision),
                          let modifications = item["modifications"]?.objectValue,
                          Set(modifications.keys).isSubset(of: Set(original["allowedModifications"]?.arrayValue?.compactMap(\.stringValue) ?? [])),
                          decision != "decline" || modifications.isEmpty else { return false }
                    return true
                }
            }
            expected.insert("decision")
            guard Set(fields.keys) == expected else { return false }
            guard let decision = result["decision"]?.stringValue else { return false }
            return Self.decisions(params).contains(decision) && ["accept", "decline"].contains(decision)
        case .questions:
            expected.insert("answers")
            guard Set(fields.keys) == expected else { return false }
            guard !questions.isEmpty, Set(questions.map(\.id)).count == questions.count,
                  let answers = result["answers"]?.objectValue,
                  Set(answers.keys) == Set(questions.map(\.id)) else { return false }
            return questions.allSatisfy { question in
                guard Set(answers[question.id]?.objectValue?.keys.map { $0 } ?? []) == ["answers"],
                      let values = answers[question.id]?["answers"]?.arrayValue, values.count == 1,
                      let answer = values[0].stringValue,
                      !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                return question.allowsOther || question.options.contains(answer)
            }
        }
    }

    /// Claim before awaiting transport, so double-clicks cannot send two replies.
    @discardableResult
    public func respond(_ result: JSONValue) async throws -> Bool {
        guard accepts(result) else { return false }
        try Task.checkCancellation()
        let claimed = lock.withLock {
            guard currentState == .pending, ProcessInfo.processInfo.systemUptime < expiryUptime else { return false }
            currentState = isGateway ? .saving : .syncing
            return true
        }
        guard claimed else { return false }
        do {
            let state = try await reply(result)
            update(state)
        } catch {
            // A gateway failure may follow durable acceptance. Only readback
            // can resolve it; never reopen the form or assume non-delivery.
            if !isGateway { update(.invalidated) }
            else if (error as? AgentGatewayError) == .decisionNotSaved { update(.pending) }
            else { update(.storageUnknown) }
            throw error
        }
        return true
    }

    /// Explicit first dispatch of immutable bytes. The backend reloads the
    /// journal and checks attempted before preflight; this never retries POST.
    @discardableResult
    public func sendSavedResponse() async throws -> Bool {
        guard let sendSaved else { return false }
        try Task.checkCancellation()
        let claimed = lock.withLock {
            guard currentState == .saved else { return false }
            currentState = .syncing
            return true
        }
        guard claimed else { return false }
        do { update(try await sendSaved()) }
        catch { update(.storageUnknown); throw error }
        return true
    }

    @discardableResult
    public func reconcile() async throws -> State {
        guard let readback else { return state }
        let value = try await readback()
        update(value)
        if value == .pending, let refreshTimeout {
            let timeout = await refreshTimeout()
            lock.withLock {
                if currentState == .pending {
                    expiryUptime = ProcessInfo.processInfo.systemUptime + max(0, timeout)
                }
            }
        }
        return state
    }

    private func update(_ state: State) {
        lock.withLock {
            guard currentState != .invalidated else { return }
            if currentState.accepted && !state.accepted { return }
            currentState = state
        }
    }
}
