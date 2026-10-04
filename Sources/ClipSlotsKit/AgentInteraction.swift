import Foundation

/// A request belongs to one live connection. It is never serialized into chat
/// history; only the user's non-secret decision is recorded by the UI.
public final class AgentInteraction: Identifiable, @unchecked Sendable {
    public enum Kind: Equatable, Sendable { case commandApproval, fileApproval, questions }
    public struct Question: Identifiable, Sendable {
        public let id: String
        public let header: String
        public let text: String
        public let options: [String]
        public let descriptions: [String]
        public let allowsOther: Bool
        public let secret: Bool
    }

    public let id = UUID()
    public let kind: Kind
    public let params: JSONValue
    public let expiresAt: Date
    public let questions: [Question]
    private let lock = NSLock()
    private var pending = true
    private let reply: @Sendable (JSONValue) async throws -> Void

    public init(kind: Kind, params: JSONValue, timeout: TimeInterval = 300,
                reply: @escaping @Sendable (JSONValue) async throws -> Void) {
        self.kind = kind
        self.params = params
        self.expiresAt = Date().addingTimeInterval(timeout)
        self.reply = reply
        self.questions = (params["questions"]?.arrayValue ?? []).compactMap { value in
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

    public var isPending: Bool { lock.withLock { pending && Date() < expiresAt } }
    public func invalidate() { lock.withLock { pending = false } }
    public func expire() -> Bool {
        lock.withLock {
            guard pending, Date() >= expiresAt else { return false }
            pending = false
            return true
        }
    }
    public var canAccept: Bool {
        params["availableDecisions"]?.arrayValue.map { $0.contains(.string("accept")) } ?? true
    }

    public func accepts(_ result: JSONValue) -> Bool {
        switch kind {
        case .commandApproval, .fileApproval:
            guard let decision = result["decision"]?.stringValue else { return false }
            return decision == "decline" || (decision == "accept" && canAccept)
        case .questions:
            guard !questions.isEmpty, Set(questions.map(\.id)).count == questions.count,
                  let answers = result["answers"]?.objectValue,
                  Set(answers.keys) == Set(questions.map(\.id)) else { return false }
            return questions.allSatisfy { question in
                guard let values = answers[question.id]?["answers"]?.arrayValue, values.count == 1,
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
        let claimed = lock.withLock {
            guard pending, Date() < expiresAt else { return false }
            pending = false
            return true
        }
        guard claimed else { return false }
        try Task.checkCancellation()
        try await reply(result)
        return true
    }
}
