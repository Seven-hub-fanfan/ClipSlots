import Foundation

/// Source projection order is separate from the HTML resource revision.
public struct AgentArtifactPageRevision: Codable, Equatable, Comparable, Sendable {
    public let messageSequence: UInt64
    public let partIndex: UInt64

    public init(messageSequence: UInt64, partIndex: UInt64) throws {
        guard messageSequence <= 9_007_199_254_740_991, partIndex <= 9_007_199_254_740_991 else {
            throw AgentArtifactError.invalidMetadata
        }
        self.messageSequence = messageSequence; self.partIndex = partIndex
    }

    private enum CodingKeys: String, CodingKey {
        case messageSequence = "message_sequence", partIndex = "part_index"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(messageSequence: c.decode(UInt64.self, forKey: .messageSequence),
                      partIndex: c.decode(UInt64.self, forKey: .partIndex))
    }
    public static func < (a: Self, b: Self) -> Bool {
        a.messageSequence == b.messageSequence ? a.partIndex < b.partIndex : a.messageSequence < b.messageSequence
    }
    public var value: JSONValue {
        ["message_sequence": .number(Double(messageSequence)), "part_index": .number(Double(partIndex))]
    }
}

/// Local artifact event adapter. Page requests cannot supply this envelope or
/// select its conversation, resource, native tool owner or execution authority.
public struct AgentArtifactPageData: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: AgentArtifactPageRevision
    public let toolInput: JSONValue
    public let toolResult: JSONValue?

    public init(revision: AgentArtifactPageRevision, toolInput: JSONValue, toolResult: JSONValue?) throws {
        schemaVersion = 1; self.revision = revision
        self.toolInput = toolInput; self.toolResult = toolResult == .null ? nil : toolResult
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw AgentArtifactError.invalidMetadata
        }
        try self.init(revision: c.decode(AgentArtifactPageRevision.self, forKey: .revision),
                      toolInput: c.decode(JSONValue.self, forKey: .toolInput),
                      toolResult: c.decodeIfPresent(JSONValue.self, forKey: .toolResult))
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, toolInput, toolResult }

    public func validate() throws {
        var pending: [(JSONValue, Int)] = [(toolInput, 0), (toolResult ?? .null, 0)]
        var count = 0
        while let (value, depth) = pending.popLast() {
            count += 1
            guard count <= 8192, depth <= 32 else { throw AgentArtifactError.invalidMetadata }
            switch value {
            case .array(let values): pending.append(contentsOf: values.map { ($0, depth + 1) })
            case .object(let fields): pending.append(contentsOf: fields.values.map { ($0, depth + 1) })
            case .number(let number):
                guard number.isFinite else { throw AgentArtifactError.invalidMetadata }
            default: break
            }
        }
        guard schemaVersion == 1, try JSONEncoder().encode(self).count <= 32 * 1024 else {
            throw AgentArtifactError.invalidMetadata
        }
    }

    /// The source host omits media transport references recursively. Preserve
    /// user text, arrays, nulls, booleans and all other public tool data.
    public static func publicValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let values): return .array(values.map(publicValue))
        case .object(let fields):
            return .object(fields.filter { !["media_ref", "poster_ref"].contains($0.key) }
                .mapValues(publicValue))
        default: return value
        }
    }

    public var updateParams: JSONValue {
        ["toolInput": Self.publicValue(toolInput), "toolResult": Self.publicValue(toolResult ?? .null),
         "revision": revision.value]
    }
    public var inputParams: JSONValue { ["arguments": Self.publicValue(toolInput)] }
    public func resultParams(widgetState: JSONValue? = nil) -> JSONValue? {
        guard let toolResult else { return nil }
        var value: [String: JSONValue] = [
            "content": [["type": "text", "text": toolResult["summary"] ?? ""]],
            "structuredContent": Self.publicValue(toolResult)]
        if let widgetState, widgetState.objectValue != nil {
            value["_meta"] = ["tapnow/widgetState": widgetState]
        }
        // Source summaries are text only.
        if toolResult["summary"]?.stringValue == nil { value["content"] = [["type": "text", "text": ""]] }
        return .object(value)
    }
}
