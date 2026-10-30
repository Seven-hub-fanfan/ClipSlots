import Foundation

/// Content is supplied by the configured gateway. Remote paths are identifiers,
/// never permission to read a local file or fetch an arbitrary URL.
public enum AgentArtifactGatewayPayload {
    public static func update(_ payload: JSONValue, scope: AgentArtifactScope,
                              binding: AgentRunBinding? = nil, originRunID: String? = nil,
                              gatewayURL: URL? = nil,
                              toolContext: AgentAppReplyToolContext? = nil,
                              conversationID: UUID? = nil) throws -> AgentArtifactUpdate {
        guard let id = payload["artifactID"]?.stringValue, !id.isEmpty,
              id.utf8.count <= 256,
              let path = payload["path"]?.stringValue,
              case .number(let revision)? = payload["revision"],
              revision.isFinite, revision >= 0, revision.rounded() == revision,
              revision <= 9_007_199_254_740_991 else {
            throw AgentArtifactError.invalidMetadata
        }
        if let project = payload["projectID"], project != .string(scope.projectID) {
            throw AgentArtifactError.invalidScope
        }
        if let canvas = payload["canvasID"], canvas != .string(scope.canvasID) {
            throw AgentArtifactError.invalidScope
        }
        if let content = payload["content"], content.stringValue == nil {
            throw AgentArtifactError.invalidMetadata
        }
        let content: Data?
        if let encoded = payload["contentBase64"]?.stringValue {
            guard encoded.utf8.count <= 44 * 1024 * 1024,
                  let bytes = Data(base64Encoded: encoded), payload["content"] == nil else {
                throw AgentArtifactError.invalidMetadata
            }
            content = bytes
        } else { content = payload["content"]?.stringValue.map { Data($0.utf8) } }
        guard (content?.count ?? 0) <= 32 * 1024 * 1024 else { throw AgentArtifactError.tooLarge }
        let origin: AgentAppReplyOrigin?
        if let value = payload["appReplyAuthority"] {
            guard let binding, let originRunID, let gatewayURL else { throw AgentArtifactError.invalidMetadata }
            let authority = try JSONDecoder().decode(AgentAppReplyAuthority.self, from: JSONEncoder().encode(value))
            guard AgentGatewayDecisionIdentity.bindingBytes(authority.binding, binding),
                  AgentGatewayDecisionIdentity.bytes(authority.originRunID, originRunID),
                  AgentGatewayDecisionIdentity.bytes(authority.artifactID, id),
                  AgentGatewayDecisionIdentity.bytes(authority.path, path),
                  authority.artifactRevision == UInt64(revision),
                  AgentGatewayDecisionIdentity.bytes(authority.binding.projectID ?? "", scope.projectID),
                  AgentGatewayDecisionIdentity.bytes(authority.binding.canvasID ?? "", scope.canvasID) else {
                throw AgentArtifactError.invalidScope
            }
            origin = try .init(endpoint: gatewayURL, authority: authority)
        } else { origin = nil }
        if let toolContext {
            try toolContext.validate()
            guard toolContext.authority == origin?.authority else { throw AgentArtifactError.invalidScope }
        }
        let projection = try payload["pageProjection"].map {
            let data = try JSONDecoder().decode(AgentArtifactPageData.self, from: JSONEncoder().encode($0))
            try data.validate()
            return data
        }
        let resourceURI: String?
        if let value = payload["pageResourceURI"] {
            guard let uri = value.stringValue, AgentArtifactResourceIdentity(uri: uri) != nil,
                  projection != nil, conversationID != nil else { throw AgentArtifactError.invalidMetadata }
            resourceURI = uri
        } else { resourceURI = nil }
        return try .init(key: .init(scope: scope, path: path), revision: UInt64(revision),
            content: content, title: payload["title"]?.stringValue,
            mimeType: payload["mimeType"]?.stringValue, appReplyOrigin: origin,
            replacesAppReplyAuthority: binding != nil && originRunID != nil && gatewayURL != nil,
            appReplyToolContext: toolContext, pageProjection: projection,
            pageProjectionConversationID: projection == nil ? nil : conversationID,
            pageProjectionRunID: projection == nil ? nil : originRunID, pageResourceURI: resourceURI)
    }
}
