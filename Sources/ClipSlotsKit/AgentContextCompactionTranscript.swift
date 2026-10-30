import Foundation

/// Local display coordinates captured at event receipt. UTF-8 offsets preserve
/// combining characters even when a later delta changes grapheme boundaries.
/// This metadata is never a model message or a compression instruction.
public struct AgentContextCompactionAnchor: Codable, Equatable, Sendable {
    public var messageID: UUID?
    public let afterMessageID: UUID?
    public let contentBytes: Int
    public let reasoningBytes: Int
    public let awaitingAssistant: Bool?
    public let displayOrder: Int?

    public init(messageID: UUID?, afterMessageID: UUID?, content: String, reasoning: String,
                awaitingAssistant: Bool = true, displayOrder: Int? = nil) {
        self.messageID = messageID
        self.afterMessageID = afterMessageID
        contentBytes = content.utf8.count
        reasoningBytes = reasoning.utf8.count
        self.awaitingAssistant = awaitingAssistant
        self.displayOrder = displayOrder
    }

    private enum CodingKeys: String, CodingKey {
        case messageID, afterMessageID, contentBytes, reasoningBytes, awaitingAssistant, displayOrder
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try c.decodeIfPresent(UUID.self, forKey: .messageID)
        afterMessageID = try c.decodeIfPresent(UUID.self, forKey: .afterMessageID)
        contentBytes = try c.decode(Int.self, forKey: .contentBytes)
        reasoningBytes = try c.decode(Int.self, forKey: .reasoningBytes)
        awaitingAssistant = try c.decodeIfPresent(Bool.self, forKey: .awaitingAssistant)
        displayOrder = try c.decodeIfPresent(Int.self, forKey: .displayOrder)
        guard contentBytes >= 0, reasoningBytes >= 0 else { throw AgentGatewayError.malformedPayload }
    }
}

public struct AgentCompactionTranscriptPart: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case assistant(text: String, reasoning: String)
        case compact(AgentContextCompactionLifecycle.Entry)
        case taskSubagent(AgentTaskSubagentProjection.Entry)
    }
    public let id: String
    public let kind: Kind
    public let isTail: Bool
}

public extension AgentContextCompactionLifecycle {
    /// Callers select only cards belonging to this assistant or the unresolved
    /// stream. Projection retains every text byte; it never rewrites history.
    static func project(content: String, reasoning: String, cards: [Entry],
                        identity: String,
                        taskSubagents: [AgentTaskSubagentProjection.Entry] = []) -> [AgentCompactionTranscriptPart] {
        if cards.isEmpty && taskSubagents.isEmpty {
            return [.init(id: identity, kind: .assistant(text: content, reasoning: reasoning), isTail: true)]
        }
        let body = Array(content.utf8), thoughts = Array(reasoning.utf8)
        var contentOffset = 0, reasoningOffset = 0
        var parts: [AgentCompactionTranscriptPart] = []
        func boundary(_ requested: Int, in bytes: [UInt8], after previous: Int) -> Int {
            var offset = max(previous, min(bytes.count, requested))
            // A stale or malformed display coordinate cannot create replacement
            // characters or consume bytes from a newer message.
            while offset < bytes.count && offset > previous && bytes[offset] & 0xc0 == 0x80 { offset -= 1 }
            return offset
        }
        var markers: [(String, AgentContextCompactionAnchor, AgentCompactionTranscriptPart.Kind)] = []
        markers += cards.compactMap { card in card.anchor.map { (card.displayID, $0, .compact(card)) } }
        markers += taskSubagents.compactMap { entry in entry.anchor.map { (entry.id, $0, .taskSubagent(entry)) } }
        markers = markers.enumerated().sorted { a, b in
            if let x = a.element.1.displayOrder, let y = b.element.1.displayOrder, x != y { return x < y }
            if a.element.1.contentBytes != b.element.1.contentBytes {
                return a.element.1.contentBytes < b.element.1.contentBytes
            }
            if a.element.1.reasoningBytes != b.element.1.reasoningBytes {
                return a.element.1.reasoningBytes < b.element.1.reasoningBytes
            }
            return a.offset < b.offset
        }.map(\.element)
        for (markerID, anchor, kind) in markers {
            let nextContent = boundary(anchor.contentBytes, in: body, after: contentOffset)
            let nextReasoning = boundary(anchor.reasoningBytes, in: thoughts, after: reasoningOffset)
            let text = String(decoding: body[contentOffset..<nextContent], as: UTF8.self)
            let thought = String(decoding: thoughts[reasoningOffset..<nextReasoning], as: UTF8.self)
            if !text.isEmpty || !thought.isEmpty {
                parts.append(.init(id: identity + ":before:" + markerID,
                                   kind: .assistant(text: text, reasoning: thought), isTail: false))
            }
            let prefix: String
            if case .compact = kind { prefix = ":compact:" } else { prefix = ":task:" }
            parts.append(.init(id: identity + prefix + markerID, kind: kind, isTail: false))
            contentOffset = nextContent; reasoningOffset = nextReasoning
        }
        parts.append(.init(id: identity, kind: .assistant(
            text: String(decoding: body[contentOffset...], as: UTF8.self),
            reasoning: String(decoding: thoughts[reasoningOffset...], as: UTF8.self)), isTail: true))
        return parts
    }
}
