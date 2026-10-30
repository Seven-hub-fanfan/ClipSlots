import Foundation

/// Native provenance of the declarations used to create one App revision.
/// This is stored separately from page JSON and immutable reply HTTP bytes.
public struct AgentAppReplyToolContext: Codable, Equatable, Sendable {
    public struct Declaration: Codable, Equatable, Sendable {
        public let name: String
        public let wireValue: JSONValue
        public let originLabel: String
        init(_ spec: AgentToolSpec) {
            name = spec.name; wireValue = spec.wireValue; originLabel = spec.originLabel
        }
        func matches(_ spec: AgentToolSpec) -> Bool {
            name == spec.name && wireValue == spec.wireValue && originLabel == spec.originLabel
        }
    }

    public let authority: AgentAppReplyAuthority
    public let clientInstanceID: String
    public let submissionKey: String
    public let sourceScope: AgentExecutionScope?
    public let declarations: [Declaration]
    public let toolLimit: Int

    var key: String { Self.key(for: authority) }

    static func key(for authority: AgentAppReplyAuthority) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return AgentGatewayJournalStore.digest((try? encoder.encode(authority)) ?? Data())
    }

    func validate() throws {
        try authority.validate()
        guard AgentGatewayDecisionIdentity.opaque(clientInstanceID),
              AgentGatewayDecisionIdentity.opaque(submissionKey),
              declarations.count <= 128, Set(declarations.map(\.name)).count == declarations.count,
              (1...20).contains(toolLimit),
              sourceScope.map({ $0.sessionID == authority.binding.sessionID
                  && $0.projectID == authority.binding.projectID && !$0.turnID.isEmpty }) ?? true,
              declarations.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 256
                  && $0.wireValue["type"] == "function"
                  && $0.wireValue["function"]?["name"] == .string($0.name)
                  && $0.wireValue["function"]?["parameters"]?.objectValue != nil
                  && $0.originLabel.utf8.count <= 2048 }),
              try JSONEncoder().encode(self).count <= 2_097_152 else {
            throw AgentGatewayError.malformedPayload
        }
    }

    public static func executionScope(binding: AgentRunBinding, replyID: String) -> AgentExecutionScope {
        .init(sessionID: binding.sessionID, projectID: binding.projectID, turnID: "app-reply:" + replyID)
    }
}
