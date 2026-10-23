import Foundation

public enum AgentArtifactError: Error, LocalizedError, Equatable {
    case invalidScope, invalidPath, invalidMetadata, invalidFile
    case tooLarge, capacityExceeded, revisionConflict, missingArtifact, storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidScope: return "缺少有效的项目或画布标识。"
        case .invalidPath: return "产物相对路径无效。"
        case .invalidMetadata: return "产物信息无效或过大。"
        case .invalidFile: return "文件不可读取或不在授权目录内。"
        case .tooLarge: return "产物超过大小限制。"
        case .capacityExceeded: return "产物仓库容量已满。"
        case .revisionConflict: return "产物修订冲突，已保留原内容。"
        case .missingArtifact: return "产物不存在或已删除。"
        case .storageUnavailable: return "产物存储不可用。"
        }
    }
}

public struct AgentArtifactScope: Codable, Hashable, Sendable {
    public let projectID: String
    public let canvasID: String

    public init(projectID: String, canvasID: String) throws {
        func valid(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && value.utf8.count <= 256
                && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard valid(projectID), valid(canvasID) else { throw AgentArtifactError.invalidScope }
        self.projectID = projectID.precomposedStringWithCanonicalMapping
        self.canvasID = canvasID.precomposedStringWithCanonicalMapping
    }

    private enum CodingKeys: String, CodingKey { case projectID, canvasID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(projectID: c.decode(String.self, forKey: .projectID),
                      canvasID: c.decode(String.self, forKey: .canvasID))
    }
}

public struct AgentArtifactKey: Codable, Hashable, Sendable {
    public let scope: AgentArtifactScope
    public let path: String

    public init(scope: AgentArtifactScope, path: String) throws {
        self.scope = scope
        self.path = try Self.normalize(path)
    }

    public init(projectID: String, canvasID: String, path: String) throws {
        try self.init(scope: AgentArtifactScope(projectID: projectID, canvasID: canvasID), path: path)
    }

    public static func normalize(_ path: String) throws -> String {
        let value = path.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\\", with: "/")
        guard !value.isEmpty, value.utf8.count <= 1024, !value.hasPrefix("/"),
              !value.hasPrefix("~"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AgentArtifactError.invalidPath
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(".."), components.count <= 32 else { throw AgentArtifactError.invalidPath }
        let normalized = components.filter { $0 != "." }.joined(separator: "/")
        guard !normalized.isEmpty else { throw AgentArtifactError.invalidPath }
        return normalized
    }

    private enum CodingKeys: String, CodingKey { case scope, path }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(scope: c.decode(AgentArtifactScope.self, forKey: .scope),
                      path: c.decode(String.self, forKey: .path))
    }
}

public enum AgentArtifactResourceState: Codable, Equatable, Sendable {
    case missing, loading, ready
    case error(String)
}

public enum AgentArtifactKind: String, Codable, Sendable {
    case html, text, image, audio, video, binary

    public static func detect(mimeType: String, path: String) -> Self {
        let mime = mimeType.lowercased().split(separator: ";").first.map(String.init) ?? ""
        let ext = (path as NSString).pathExtension.lowercased()
        if mime == "text/html" || ["html", "htm"].contains(ext) { return .html }
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("text/") || ["application/json", "application/xml"].contains(mime) { return .text }
        if ["txt", "md", "json", "csv", "xml", "swift", "js", "css"].contains(ext) { return .text }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) { return .image }
        if ["mp4", "mov", "webm", "m4v"].contains(ext) { return .video }
        if ["mp3", "m4a", "wav", "aac"].contains(ext) { return .audio }
        return .binary
    }
}

public struct AgentArtifactRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: AgentArtifactKey { key }
    public let key: AgentArtifactKey
    public internal(set) var revision: UInt64
    public internal(set) var contentRevision: UInt64?
    public internal(set) var content: Data?
    public internal(set) var title: String
    public internal(set) var mimeType: String
    public internal(set) var resourceState: AgentArtifactResourceState
    public internal(set) var isDeleted: Bool
    public internal(set) var updatedAt: Date
    internal var mutationID: UUID

    public var kind: AgentArtifactKind { .detect(mimeType: mimeType, path: key.path) }
    public var text: String? { content.flatMap { String(data: $0, encoding: .utf8) } }
    public var hasCurrentContent: Bool { content != nil && contentRevision == revision && !isDeleted }
}

public struct AgentArtifactUpdate: Sendable {
    public let key: AgentArtifactKey
    public let revision: UInt64
    public let content: Data?
    public let title: String?
    public let mimeType: String?

    public init(key: AgentArtifactKey, revision: UInt64, content: Data? = nil,
                title: String? = nil, mimeType: String? = nil) {
        self.key = key
        self.revision = revision
        self.content = content
        self.title = title
        self.mimeType = mimeType
    }
}

public struct AgentArtifactFetchToken: Equatable, Sendable {
    public let key: AgentArtifactKey
    public let revision: UInt64
    internal let mutationID: UUID
}

public struct AgentArtifactAppToolAction: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let toolName: String
    public let arguments: JSONValue

    public init(id: String, label: String, toolName: String, arguments: JSONValue = [:]) {
        self.id = id; self.label = label; self.toolName = toolName; self.arguments = arguments
    }
}

public struct AgentArtifactAppToolRequest: Equatable, Sendable {
    public let key: AgentArtifactKey
    public let revision: UInt64
    public let action: AgentArtifactAppToolAction
    public init(key: AgentArtifactKey, revision: UInt64, action: AgentArtifactAppToolAction) {
        self.key = key; self.revision = revision; self.action = action
    }
}

public enum AgentArtifactPanelAction: Equatable, Sendable {
    case retry(AgentArtifactKey)
    case delete(AgentArtifactKey, revision: UInt64)
    case openExternalURL(URL)
    case appTool(AgentArtifactAppToolRequest)
}

/// This policy is also applied by the native preview. Links are never auto-opened.
public enum AgentArtifactPreviewPolicy {
    public static func externalURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 8192 else { return nil }
        return url
    }

    public static func sandboxedHTML(_ source: String, allowsScripts: Bool = false) -> String {
        let policy = "default-src 'none'; script-src \(allowsScripts ? "'unsafe-inline'" : "'none'"); connect-src 'none'; "
            + "style-src 'unsafe-inline'; img-src data:; media-src data:; "
            + "font-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        return "<!doctype html><html><head><meta charset=\"utf-8\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
            + "</head><body>\(source)</body></html>"
    }
}
