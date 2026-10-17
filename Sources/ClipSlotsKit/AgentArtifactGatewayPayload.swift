import Foundation

/// Content is supplied by the configured gateway. Remote paths are identifiers,
/// never permission to read a local file or fetch an arbitrary URL.
public enum AgentArtifactGatewayPayload {
    public static func update(_ payload: JSONValue, scope: AgentArtifactScope) throws -> AgentArtifactUpdate {
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
        return try .init(key: .init(scope: scope, path: path), revision: UInt64(revision),
            content: content, title: payload["title"]?.stringValue,
            mimeType: payload["mimeType"]?.stringValue)
    }
}
