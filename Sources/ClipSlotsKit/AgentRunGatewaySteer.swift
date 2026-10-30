import Foundation

public struct AgentGatewaySteerCapability: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let safePoints: [String]
    public let accepting: Bool
    public let maxPending: Int
    public let maxPerRun: Int

    public init(validating value: JSONValue) throws {
        guard let object = value.objectValue,
              Set(object.keys) == ["schemaVersion", "safePoints", "accepting", "maxPending", "maxPerRun"],
              value["schemaVersion"] == 1,
              case .array(let points)? = value["safePoints"],
              points.count == 2,
              Set(points.compactMap(\.stringValue)) == ["model_boundary", "tools_resolved"],
              case .bool(let accepting)? = value["accepting"],
              case .number(let pending)? = value["maxPending"],
              case .number(let total)? = value["maxPerRun"],
              pending >= 1, pending <= 32, pending.rounded() == pending,
              total >= pending, total <= 64, total.rounded() == total else {
            throw AgentGatewayError.malformedPayload
        }
        schemaVersion = 1; safePoints = points.compactMap(\.stringValue)
        self.accepting = accepting; maxPending = Int(pending); maxPerRun = Int(total)
    }

    public init(from decoder: Decoder) throws { try self.init(validating: JSONValue(from: decoder)) }
}

public struct AgentGatewaySteerReceipt: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case accepted, placed, returned }
    public struct Placement: Codable, Equatable, Sendable {
        public let point: String
        public let generation: Int
        /// Absolute provider wire index, including the system message.
        public let messageIndex: Int
        public let placedAt: Double
    }
    public let schemaVersion: Int
    public let steerSchemaVersion: Int
    public let binding: AgentRunBinding
    public let runID: String
    public let clientInstanceID: String
    public let requestKey: String
    public let submissionID: String
    public let messageID: String
    public let state: State
    public let revision: Int
    public let sequence: Int
    public let acceptedAt: Double
    public let placement: Placement?
    public let returnReason: String?

    public init(validating value: JSONValue) throws {
        let required: Set<String> = ["schemaVersion", "steerSchemaVersion", "binding", "runID",
            "clientInstanceID", "requestKey", "submissionID", "messageID", "state", "revision",
            "sequence", "acceptedAt"]
        guard let fields = value.objectValue, required.isSubset(of: Set(fields.keys)),
              Set(fields.keys).isSubset(of: required.union(["placement", "returnReason"])),
              value["schemaVersion"] == 1, value["steerSchemaVersion"] == 1,
              let scope = value["binding"]?.objectValue,
              scope["sessionID"]?.stringValue?.isEmpty == false,
              Set(scope.keys).isSubset(of: ["sessionID", "projectID", "canvasID"]),
              let run = value["runID"]?.stringValue, !run.isEmpty, run.utf8.count <= 1024,
              let client = value["clientInstanceID"]?.stringValue, !client.isEmpty,
              client.utf8.count <= 1024,
              let submission = value["submissionID"]?.stringValue, UUID(uuidString: submission) != nil,
              let message = value["messageID"]?.stringValue, Data(message.utf8) == Data(submission.utf8),
              let key = value["requestKey"]?.stringValue, Data(key.utf8) == Data(("steer-" + submission).utf8),
              let rawState = value["state"]?.stringValue, let state = State(rawValue: rawState),
              case .number(let revision)? = value["revision"], revision == (state == .accepted ? 1 : 2),
              case .number(let sequence)? = value["sequence"], sequence >= 1, sequence <= 64,
              sequence.rounded() == sequence,
              case .number(let accepted)? = value["acceptedAt"], accepted.isFinite, accepted >= 0 else {
            throw AgentGatewayError.malformedPayload
        }
        let encoder = JSONEncoder()
        binding = try JSONDecoder().decode(AgentRunBinding.self, from: encoder.encode(JSONValue.object(scope)))
        schemaVersion = 1; steerSchemaVersion = 1; runID = run; clientInstanceID = client
        requestKey = key; submissionID = submission; messageID = message
        self.state = state; self.revision = Int(revision); self.sequence = Int(sequence); acceptedAt = accepted
        if state == .placed {
            guard fields["returnReason"] == nil, let p = value["placement"]?.objectValue,
                  Set(p.keys) == ["point", "generation", "messageIndex", "placedAt"],
                  let point = p["point"]?.stringValue, ["model_boundary", "tools_resolved"].contains(point),
                  case .number(let generation)? = p["generation"], generation >= 1,
                  generation <= 1_000_000, generation.rounded() == generation,
                  case .number(let index)? = p["messageIndex"], index >= 1, index < 1000,
                  index.rounded() == index,
                  case .number(let time)? = p["placedAt"], time.isFinite, time >= accepted else {
                throw AgentGatewayError.malformedPayload
            }
            placement = .init(point: point, generation: Int(generation), messageIndex: Int(index), placedAt: time)
            returnReason = nil
        } else {
            guard fields["placement"] == nil else { throw AgentGatewayError.malformedPayload }
            placement = nil
            if state == .returned {
                guard let reason = value["returnReason"]?.stringValue,
                      ["TERMINAL_CANCELLED", "TERMINAL_FAILED", "RUN_WAITING", "PROCESS_RESTART",
                       "CONTEXT_LIMIT"].contains(reason) else { throw AgentGatewayError.malformedPayload }
                returnReason = reason
            } else {
                guard fields["returnReason"] == nil else { throw AgentGatewayError.malformedPayload }
                returnReason = nil
            }
        }
    }

    public init(from decoder: Decoder) throws { try self.init(validating: JSONValue(from: decoder)) }

    /// Even a stale receipt must match identity and immutable acceptance metadata.
    public static func reduce(_ previous: Self?, incoming: Self) throws -> Self {
        guard let previous else { return incoming }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(previous.binding) == encoder.encode(incoming.binding),
              Data(previous.runID.utf8) == Data(incoming.runID.utf8),
              Data(previous.clientInstanceID.utf8) == Data(incoming.clientInstanceID.utf8),
              previous.submissionID == incoming.submissionID, previous.requestKey == incoming.requestKey,
              previous.messageID == incoming.messageID,
              previous.sequence == incoming.sequence, previous.acceptedAt == incoming.acceptedAt else {
            throw AgentGatewayError.originMismatch
        }
        if previous.revision == incoming.revision {
            guard previous == incoming else { throw AgentGatewayError.malformedPayload }
        }
        return incoming.revision > previous.revision ? incoming : previous
    }
}

/// Large immutable bodies have their own journal rows, separate from event headers.
struct AgentGatewaySteerSubmission: Codable, Equatable, Sendable {
    let runID: String
    let binding: AgentRunBinding
    let clientInstanceID: String
    let submissionID: String
    let requestKey: String
    let requestBody: Data
    let messageData: Data

    var message: AgentMessage { get throws { try JSONDecoder().decode(AgentMessage.self, from: messageData) } }

    init(message: AgentMessage, binding: AgentRunBinding, runID: String,
         clientInstanceID: String, supportsImages: Bool) throws {
        guard message.role == .user, message.reasoning == nil, message.toolCalls.isEmpty,
              message.toolCallId == nil, !message.wireContent.isEmpty else {
            throw AgentGatewayError.malformedPayload
        }
        guard message.wireContent.utf8.count <= 262_144 else { throw AgentGatewayError.requestTooLarge }
        try AgentAttachmentImport.validate((message.attachments ?? [])
            + (message.canvasReferences ?? []).flatMap { $0.images ?? [] })
        try AgentAttachmentImport.validateImageSupport(history: [message], supported: supportsImages)
        self.runID = runID; self.binding = binding; self.clientInstanceID = clientInstanceID
        submissionID = message.id.uuidString; requestKey = "steer-" + submissionID
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        messageData = try encoder.encode(message)
        let scope = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(binding))
        let body: JSONValue = ["schemaVersion": 1, "steerSchemaVersion": 1,
            "binding": scope, "runID": .string(runID), "clientInstanceID": .string(clientInstanceID),
            "requestKey": .string(requestKey), "submissionID": .string(submissionID),
            "message": ["id": .string(submissionID), "role": "user",
                        "content": message.wirePayload(supportsImages: supportsImages)]]
        requestBody = try encoder.encode(body)
        guard requestBody.count <= 8 * 1024 * 1024 else { throw AgentGatewayError.requestTooLarge }
    }

    func validate(_ receipt: AgentGatewaySteerReceipt) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(receipt.binding) == encoder.encode(binding),
              Data(receipt.runID.utf8) == Data(runID.utf8),
              receipt.clientInstanceID == clientInstanceID, receipt.submissionID == submissionID,
              receipt.requestKey == requestKey, receipt.messageID == submissionID else {
            throw AgentGatewayError.originMismatch
        }
    }
}

struct AgentGatewaySteerLocalState: Codable, Sendable {
    var attempted = false
    var receipt: AgentGatewaySteerReceipt?
    var eventApplied = false
}

public struct AgentGatewaySteerSnapshot: Sendable {
    public let message: AgentMessage
    public let receipt: AgentGatewaySteerReceipt?
    public let attempted: Bool
    /// Only the ordered SSE commit can materialize a placed message.
    public let eventApplied: Bool
}

public protocol AgentGatewaySteering: AgentGatewayResuming {
    func submitSteer(message: AgentMessage, runID: String) async throws -> AgentGatewaySteerSnapshot
    func reconcileSteer(submissionID: UUID, runID: String) async throws -> AgentGatewaySteerSnapshot
    /// Checks the committed identity rather than a possibly undecodable projection.
    func hasSteerSubmission(submissionID: UUID, runID: String) async throws -> Bool
}
