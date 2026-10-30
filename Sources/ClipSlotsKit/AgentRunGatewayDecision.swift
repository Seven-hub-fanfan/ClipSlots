import Foundation
import CryptoKit

public struct AgentGatewayDecisionCapability: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let readback: Bool
}

/// Server-issued identity. The fingerprint is opaque; never reconstruct it
/// from a re-encoded request or from the currently selected conversation.
public struct AgentGatewayDecisionIdentity: Codable, Equatable, Sendable {
    public let binding: AgentRunBinding
    public let runID: String
    public let clientInstanceID: String
    public let interactionID: String
    public let kind: String
    public let requestRevision: Int
    public let requestFingerprint: String
    public let createdAt: Double
    public let expiresAt: Double

    init(binding: AgentRunBinding, runID: String, clientInstanceID: String,
         kind: String, payload: JSONValue) throws {
        self.binding = binding; self.runID = runID; self.clientInstanceID = clientInstanceID
        self.kind = kind
        guard let id = payload["interactionID"]?.stringValue,
              case .number(let revision)? = payload["requestRevision"],
              revision.isFinite, revision >= 1, revision.rounded() == revision, revision < Double(Int.max),
              let fingerprint = payload["requestFingerprint"]?.stringValue,
              case .number(let created)? = payload["createdAt"],
              case .number(let expiry)? = payload["expiresAt"],
              case .number(let time)? = payload["serverTime"], time.isFinite else {
            throw AgentGatewayError.malformedPayload
        }
        interactionID = id; requestRevision = Int(revision)
        requestFingerprint = fingerprint; createdAt = created; expiresAt = expiry
        try validate()
    }

    func validate() throws {
        guard [runID, clientInstanceID, interactionID].allSatisfy(Self.opaque),
              !binding.sessionID.isEmpty, requestRevision > 0,
              ["waiting_question", "waiting_confirmation"].contains(kind),
              Self.digest(requestFingerprint), createdAt.isFinite, expiresAt.isFinite else {
            throw AgentGatewayError.malformedPayload
        }
    }

    static func opaque(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 1024 && ![".", ".."].contains(text)
            && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    static func digest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func bytes(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    public static func == (a: Self, b: Self) -> Bool {
        bytes(a.binding.sessionID, b.binding.sessionID)
            && optionalBytes(a.binding.projectID, b.binding.projectID)
            && optionalBytes(a.binding.canvasID, b.binding.canvasID)
            && bytes(a.runID, b.runID) && bytes(a.clientInstanceID, b.clientInstanceID)
            && bytes(a.interactionID, b.interactionID) && a.kind == b.kind
            && a.requestRevision == b.requestRevision && a.requestFingerprint == b.requestFingerprint
            && a.createdAt == b.createdAt && a.expiresAt == b.expiresAt
    }
    private static func optionalBytes(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return bytes(a, b)
        default: return false
        }
    }
    static func bindingBytes(_ a: AgentRunBinding, _ b: AgentRunBinding) -> Bool {
        bytes(a.sessionID, b.sessionID) && optionalBytes(a.projectID, b.projectID)
            && optionalBytes(a.canvasID, b.canvasID)
    }
}

public struct AgentGatewayDecisionReceipt: Codable, Equatable, Sendable {
    public struct Decision: Codable, Equatable, Sendable {
        public let requestKey: String
        public let answerSHA256: String
        public let acceptedAt: Double
        public let generation: Int
        public let messageIndex: Int
    }
    public let schemaVersion: Int
    public let decisionSchemaVersion: Int
    public let binding: AgentRunBinding
    public let runID: String
    public let clientInstanceID: String
    public let interactionID: String
    public let kind: String
    public let requestRevision: Int
    public let requestFingerprint: String
    public let createdAt: Double
    public let expiresAt: Double
    public let serverTime: Double
    public let state: String
    public let decision: Decision?

    func validate(for identity: AgentGatewayDecisionIdentity) throws {
        try identity.validate()
        guard schemaVersion == 1, decisionSchemaVersion == 1,
              AgentGatewayDecisionIdentity.bindingBytes(binding, identity.binding), runID == identity.runID,
              AgentGatewayDecisionIdentity.bytes(runID, identity.runID),
              AgentGatewayDecisionIdentity.bytes(clientInstanceID, identity.clientInstanceID),
              AgentGatewayDecisionIdentity.bytes(interactionID, identity.interactionID), kind == identity.kind,
              requestRevision == identity.requestRevision,
              requestFingerprint == identity.requestFingerprint,
              createdAt == identity.createdAt, expiresAt == identity.expiresAt else {
            throw AgentGatewayError.originMismatch
        }
        guard serverTime.isFinite, serverTime >= createdAt,
              ["pending", "expired", "superseded", "resolved"].contains(state),
              (state == "resolved") == (decision != nil),
              state != "pending" || serverTime < expiresAt,
              state != "expired" || serverTime >= expiresAt else {
            throw AgentGatewayError.malformedPayload
        }
        if let decision {
            guard AgentGatewayDecisionIdentity.opaque(decision.requestKey),
                  AgentGatewayDecisionIdentity.digest(decision.answerSHA256),
                  decision.acceptedAt.isFinite, decision.acceptedAt >= createdAt,
                  decision.acceptedAt < expiresAt, decision.generation >= 1,
                  decision.messageIndex >= 0 else { throw AgentGatewayError.malformedPayload }
        }
    }
}

/// Exact immutable UTF-8 answer, retained outside chat/diagnostic exports.
struct AgentGatewayDecisionSubmission: Codable, Equatable, Sendable {
    let requestKey: String
    let answerJSON: String
    var answerSHA256: String {
        SHA256.hash(data: Data(answerJSON.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func == (a: Self, b: Self) -> Bool {
        AgentGatewayDecisionIdentity.bytes(a.requestKey, b.requestKey)
            && AgentGatewayDecisionIdentity.bytes(a.answerJSON, b.answerJSON)
    }
}

struct AgentGatewayDecisionRecord: Codable, Equatable, Sendable {
    let localID: UUID
    let identity: AgentGatewayDecisionIdentity
    let params: JSONValue
    var submission: AgentGatewayDecisionSubmission?
    var attempted = false
    var receipt: AgentGatewayDecisionReceipt?

    var state: AgentInteraction.State {
        if let receipt {
            if receipt.state == "resolved" {
                guard let submission, receipt.decision?.requestKey == submission.requestKey,
                      receipt.decision?.answerSHA256 == submission.answerSHA256 else { return .conflict }
                return .resolved
            }
            if receipt.state == "expired" { return .expired }
            if receipt.state == "superseded" { return .superseded }
        }
        return submission == nil ? .pending : attempted ? .syncing : .saved
    }

    func validate() throws {
        try identity.validate()
        guard params.objectValue != nil, !attempted || submission != nil else {
            throw AgentGatewayError.journalUnavailable
        }
        if let submission {
            guard AgentGatewayDecisionIdentity.opaque(submission.requestKey),
                  submission.answerJSON.utf8.count <= 8_388_608,
                  let bytes = submission.answerJSON.data(using: .utf8),
                  let answer = try? JSONDecoder().decode(JSONValue.self, from: bytes),
                  AgentInteraction(kind: identity.kind == "waiting_question" ? .questions : .commandApproval,
                      params: params, reply: { _ in }).accepts(answer) else {
                throw AgentGatewayError.journalUnavailable
            }
        }
        if let receipt { try receipt.validate(for: identity) }
    }
}

/// Old services have no revision/readback contract. Only a matching generic
/// receipt proves acceptance; absence of a waiting request never does.
struct AgentGatewayLegacyDecisionRecord: Codable, Equatable, Sendable {
    let localID: UUID
    let runID: String
    let interactionID: String
    let kind: String
    let params: JSONValue
    let expiresAt: Double
    var submissionKey: String?
    var acceptedKey: String?

    func state(phase: String) -> AgentInteraction.State {
        if acceptedKey != nil { return phase == "streaming" ? .executing : .resolved }
        if submissionKey != nil { return .syncing }
        if ["cancelled", "failed", "completed"].contains(phase) { return .superseded }
        return Date().timeIntervalSince1970 >= expiresAt ? .expired : .pending
    }
}
