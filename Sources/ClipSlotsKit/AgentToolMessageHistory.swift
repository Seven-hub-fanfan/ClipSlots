import Foundation

/// An immutable host association. Never inferred from tool arguments or a
/// globally unique provider call ID: IDs may repeat in another run or reply.
public struct AgentToolMessageOrigin: Equatable, Codable, Sendable {
    public let assistantID: UUID
    public let runID: String?
    public let scope: AgentExecutionScope?
    public let executionID: String?

    public init(assistantID: UUID, runID: String? = nil, scope: AgentExecutionScope? = nil,
                executionID: String? = nil) {
        self.assistantID = assistantID; self.runID = runID
        self.scope = scope; self.executionID = executionID
    }

    public func matches(_ other: Self) -> Bool {
        assistantID == other.assistantID && runID == other.runID && scope == other.scope
            && (executionID == nil || other.executionID == nil || executionID == other.executionID)
    }
}

public enum AgentToolMessageHistory {
    /// Tool rows keyed by their assistant, then the unchanged provider call ID.
    /// Legacy rows use chronological adjacency; an early row can only be
    /// associated when there is exactly one matching assistant in the history.
    /// Lost legacy results are never reconstructed from another run's result.
    public static func resultIndices(_ messages: [AgentMessage]) -> [UUID: [String: Int]] {
        var assistants: [UUID: AgentMessage] = [:]
        var unique: [String: UUID] = [:], ambiguous: Set<String> = []
        for message in messages where message.role == .assistant {
            assistants[message.id] = message
            for call in message.toolCalls {
                if unique[call.id] != nil { ambiguous.insert(call.id) }
                else { unique[call.id] = message.id }
            }
        }
        var latest: [String: UUID] = [:]
        var result: [UUID: [String: Int]] = [:]
        for (index, message) in messages.enumerated() {
            if message.role == .user { latest.removeAll() }
            if message.role == .assistant {
                for call in message.toolCalls { latest[call.id] = message.id }
            }
            guard message.role == .tool, let callID = message.toolCallId else { continue }
            let assistantID: UUID?
            if let origin = message.toolOrigin {
                guard let assistant = assistants[origin.assistantID],
                      assistant.runID == origin.runID, assistant.executionScope == origin.scope else { continue }
                assistantID = origin.assistantID
            } else {
                assistantID = latest[callID] ?? (ambiguous.contains(callID) ? nil : unique[callID])
            }
            guard let id = assistantID, let assistant = assistants[id],
                  assistant.toolCalls.contains(where: {
                      $0.id == callID && (message.toolName == nil || $0.name == message.toolName)
                  }) else { continue }
            if let old = result[id]?[callID] {
                // Two executions with conflicting durable identities are not
                // interchangeable, even inside the same assistant.
                if let a = messages[old].toolOrigin, let b = message.toolOrigin, !a.matches(b) { continue }
                if !isInterrupted(messages[old]) && isInterrupted(message) { continue }
            }
            result[id, default: [:]][callID] = index
        }
        return result
    }

    public static func matchingIndex(_ source: AgentMessage, in messages: [AgentMessage]) -> Int? {
        if let exact = messages.firstIndex(where: { $0.id == source.id }) { return exact }
        guard source.role == .tool, let callID = source.toolCallId, let origin = source.toolOrigin else { return nil }
        let associated = messages.indices.filter {
            let message = messages[$0]
            guard message.role == .tool, message.toolCallId == callID, let old = message.toolOrigin,
                  message.toolName == nil || source.toolName == nil || message.toolName == source.toolName else { return false }
            return old.assistantID == origin.assistantID && old.runID == origin.runID && old.scope == origin.scope
        }
        if associated.contains(where: {
            !isInterrupted(messages[$0]) && messages[$0].toolOrigin?.matches(origin) == false
        }) { return nil }
        if let exact = associated.first(where: { !isInterrupted(messages[$0]) })
            ?? associated.first(where: { messages[$0].toolOrigin?.matches(origin) == true }) { return exact }
        // Adopt an old untagged row only through its actual assistant position.
        // A global call-ID lookup would erase another reply's history.
        if let old = resultIndices(messages)[origin.assistantID]?[callID],
           messages[old].toolOrigin == nil,
           messages[old].content == source.content || isInterrupted(messages[old]) { return old }
        return nil
    }

    public static func isInterrupted(_ message: AgentMessage) -> Bool {
        message.isFailure && (try? JSONValue.decode(jsonText: message.content))?["error_code"] == "interrupted"
    }

    public static func merging(_ source: AgentMessage, preserving current: AgentMessage) -> AgentMessage {
        if !isInterrupted(current) && isInterrupted(source) { return current }
        var replacement = source
        replacement.id = current.id
        replacement.createdAt = current.createdAt
        return replacement
    }
}
