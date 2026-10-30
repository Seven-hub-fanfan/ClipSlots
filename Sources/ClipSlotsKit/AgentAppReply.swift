import Foundation
import CryptoKit

public enum AgentAppReplyError: Error, Equatable, Sendable {
    case preflight, rejected(Int), unknown

    public var rpcError: AgentArtifactRPCError {
        switch self {
        case .preflight: return .init(-32010, "app reply not submitted: preflight failed")
        case .rejected: return .init(-32011, "app reply rejected")
        case .unknown: return .init(-32012, "app reply acceptance unknown: reconcile original identity")
        }
    }
}

/// Issued by the gateway's artifact event. A page cannot construct native authority.
public struct AgentAppReplyAuthority: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let binding: AgentRunBinding
    public let originRunID: String
    public let artifactID: String
    public let path: String
    public let artifactRevision: UInt64
    public let manifestRevision: String
    public let actions: [String]

    func validate() throws {
        guard schemaVersion == 1, AgentGatewayDecisionIdentity.opaque(originRunID),
              !artifactID.isEmpty, artifactID.utf8.count <= 256,
              artifactRevision < 9_007_199_254_740_992,
              AgentGatewayDecisionIdentity.digest(manifestRevision), actions == ["previs_reply"],
              AgentGatewayDecisionIdentity.opaque(binding.sessionID),
              let project = binding.projectID, let canvas = binding.canvasID,
              try AgentArtifactKey(projectID: project, canvasID: canvas, path: path).path.utf8.elementsEqual(path.utf8),
              !path.contains("\\"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(""),
              !path.split(separator: "/").contains(".") else { throw AgentAppReplyError.preflight }
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.schemaVersion == b.schemaVersion && AgentGatewayDecisionIdentity.bindingBytes(a.binding, b.binding)
            && AgentGatewayDecisionIdentity.bytes(a.originRunID, b.originRunID)
            && AgentGatewayDecisionIdentity.bytes(a.artifactID, b.artifactID)
            && AgentGatewayDecisionIdentity.bytes(a.path, b.path)
            && a.artifactRevision == b.artifactRevision && a.manifestRevision == b.manifestRevision
            && a.actions == b.actions
    }
}

/// Captured from a verified gateway event and its actual transport, never current preferences.
public struct AgentAppReplyOrigin: Codable, Equatable, Sendable {
    public let endpoint: URL
    public let authority: AgentAppReplyAuthority

    public init(endpoint: URL, authority: AgentAppReplyAuthority) throws {
        self.endpoint = endpoint; self.authority = authority
        try validate()
    }

    func validate() throws {
        guard AgentGatewayPreferences.credentialOrigin(url: endpoint) != nil,
              endpoint.absoluteString.utf8.count <= 8192,
              let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              !components.percentEncodedPath.contains("//"),
              !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw AgentAppReplyError.preflight
        }
        try authority.validate()
    }

    public static func == (a: Self, b: Self) -> Bool {
        AgentGatewayDecisionIdentity.bytes(a.endpoint.absoluteString, b.endpoint.absoluteString)
            && a.authority == b.authority
    }
}

public struct AgentAppReplyReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let appReplySchemaVersion: Int
    public let binding: AgentRunBinding
    public let originRunID: String
    public let artifactID: String
    public let artifactRevision: UInt64
    public let manifestRevision: String
    public let replyID: String
    public let replySHA256: String
    public let requestKey: String
    public let runID: String
    public let acceptedAt: Double
    public let deduped: Bool
    public let phase: String?
    public let state: String?

    func validate(for submission: AgentAppReplySubmission, readback: Bool) throws {
        let authority = submission.origin.authority
        guard schemaVersion == 1, appReplySchemaVersion == 1,
              AgentGatewayDecisionIdentity.bindingBytes(binding, authority.binding),
              AgentGatewayDecisionIdentity.bytes(originRunID, authority.originRunID),
              AgentGatewayDecisionIdentity.bytes(artifactID, authority.artifactID),
              artifactRevision == authority.artifactRevision, manifestRevision == authority.manifestRevision,
              replyID == submission.replyID, requestKey == submission.replyID,
              replySHA256 == submission.replySHA256, AgentGatewayDecisionIdentity.opaque(runID),
              !AgentGatewayDecisionIdentity.bytes(runID, originRunID),
              acceptedAt.isFinite, acceptedAt > 0 else { throw AgentAppReplyError.unknown }
        if readback {
            guard let phase, let state,
                  ["streaming", "recovering", "waiting_question", "waiting_confirmation", "waiting_suspended",
                   "completed", "failed", "cancelled"].contains(phase),
                  state == (phase == "waiting_suspended" ? "unknown"
                      : ["completed", "failed", "cancelled"].contains(phase) ? "terminal" : "running") else {
                throw AgentAppReplyError.unknown
            }
        } else if phase != nil || state != nil { throw AgentAppReplyError.unknown }
    }

    func sameAcceptance(as other: Self) -> Bool {
        // Deduplication and live execution state may change; acceptance identity cannot.
        schemaVersion == other.schemaVersion && appReplySchemaVersion == other.appReplySchemaVersion
            && AgentGatewayDecisionIdentity.bindingBytes(binding, other.binding)
            && AgentGatewayDecisionIdentity.bytes(originRunID, other.originRunID)
            && AgentGatewayDecisionIdentity.bytes(artifactID, other.artifactID)
            && artifactRevision == other.artifactRevision && manifestRevision == other.manifestRevision
            && replyID == other.replyID && replySHA256 == other.replySHA256 && requestKey == other.requestKey
            && AgentGatewayDecisionIdentity.bytes(runID, other.runID) && acceptedAt == other.acceptedAt
    }
}

/// Original reply UTF-8 and original HTTP body are immutable, private durable data.
public struct AgentAppReplySubmission: Codable, Equatable, Sendable {
    public let origin: AgentAppReplyOrigin
    public let replyID: String
    public let replyJSON: String
    public let requestBody: Data
    public var replySHA256: String { AgentGatewayJournalStore.digest(Data(replyJSON.utf8)) }

    public init(origin: AgentAppReplyOrigin, replyJSON: String) throws {
        try origin.validate()
        let reply = try AgentAppReplyJSON.parse(replyJSON)
        guard let fields = reply.objectValue,
              Set(fields.keys).isSubset(of: ["reply_id", "action", "payload", "expected_manifest_revision"]),
              let id = fields["reply_id"]?.stringValue, id.utf8.count == 36,
              let uuid = UUID(uuidString: id),
              id.lowercased() == uuid.uuidString.lowercased(),
              fields["action"] == "previs_reply", fields["payload"]?.objectValue != nil,
              fields["expected_manifest_revision"].map({ $0 == .string(origin.authority.manifestRevision) }) ?? true else {
            throw AgentAppReplyError.preflight
        }
        self.origin = origin; self.replyJSON = replyJSON; replyID = uuid.uuidString.lowercased()
        let authority = origin.authority
        let binding = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(authority.binding))
        let body: JSONValue = ["schemaVersion": 1, "appReplySchemaVersion": 1,
            "requestKey": .string(replyID), "binding": binding, "originRunID": .string(authority.originRunID),
            "artifactID": .string(authority.artifactID), "artifactRevision": .number(Double(authority.artifactRevision)),
            "manifestRevision": .string(authority.manifestRevision), "replyJSON": .string(replyJSON)]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        requestBody = try encoder.encode(body)
    }

    func validate() throws {
        let original = try Self(origin: origin, replyJSON: replyJSON)
        guard original == self else { throw AgentAppReplyError.preflight }
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.origin == b.origin && a.replyID == b.replyID
            && AgentGatewayDecisionIdentity.bytes(a.replyJSON, b.replyJSON) && a.requestBody == b.requestBody
    }
}

public struct AgentAppReplySnapshot: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case saved, unknown, rejected, accepted }
    public let submission: AgentAppReplySubmission
    public internal(set) var attempt: UInt64 = 0
    public internal(set) var state: State = .saved
    public internal(set) var rejectionStatus: Int?
    public internal(set) var receipt: AgentAppReplyReceipt?
}

public enum AgentAppReplyRecoveryAction: Sendable {
    case reconcile
    case retry(expectedAttempt: UInt64)
    case attach
}

/// Bounded structural scan rejects duplicate keys before Foundation loses them.
/// Only reply JSON is scanned here; original bytes are retained without normalization.
enum AgentAppReplyJSON {
    static func parse(_ text: String) throws -> JSONValue {
        guard text.utf8.count <= 32768 else { throw AgentAppReplyError.preflight }
        var scan = Scanner(bytes: Array(text.utf8))
        try scan.value(depth: 0); scan.space()
        guard scan.index == scan.bytes.count else { throw AgentAppReplyError.preflight }
        do { return try JSONValue.decode(jsonText: text) }
        catch { throw AgentAppReplyError.preflight }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        mutating func space() {
            while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func take(_ byte: UInt8) throws {
            space()
            guard index < bytes.count, bytes[index] == byte else { throw AgentAppReplyError.preflight }
            index += 1
        }
        mutating func string() throws -> String {
            space(); let start = index; try take(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 {
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    catch { throw AgentAppReplyError.preflight }
                }
                if byte == 92 {
                    guard index < bytes.count else { throw AgentAppReplyError.preflight }
                    index += 1
                } else if byte < 32 { throw AgentAppReplyError.preflight }
            }
            throw AgentAppReplyError.preflight
        }
        mutating func value(depth: Int) throws {
            space()
            guard depth < 64, index < bytes.count else { throw AgentAppReplyError.preflight }
            if bytes[index] == 34 { _ = try string(); return }
            if bytes[index] == 123 {
                index += 1; space()
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                var keys: Set<String> = []
                while true {
                    guard keys.insert(try string()).inserted else { throw AgentAppReplyError.preflight }
                    try take(58); try value(depth: depth + 1); space()
                    guard index < bytes.count else { throw AgentAppReplyError.preflight }
                    if bytes[index] == 125 { index += 1; return }
                    try take(44)
                }
            }
            if bytes[index] == 91 {
                index += 1; space()
                if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); space()
                    guard index < bytes.count else { throw AgentAppReplyError.preflight }
                    if bytes[index] == 93 { index += 1; return }
                    try take(44)
                }
            }
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw AgentAppReplyError.preflight }
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            if ["true", "false", "null"].contains(token) { return }
            guard let number = Double(token), number.isFinite else { throw AgentAppReplyError.preflight }
            // Full JSON decoding below rejects invalid numeric grammar.
        }
    }
}
