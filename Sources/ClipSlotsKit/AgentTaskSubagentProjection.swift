import Foundation
import CryptoKit

/// Value semantics without copying every accumulated receipt on each event.
/// Codable retains the existing flat dictionary representation.
private struct AgentTaskReceiptLedger: Codable, Equatable, Sendable {
    private var buckets = Array(repeating: [String: String](), count: 256)
    private(set) var count = 0
    private(set) var fingerprint = Data(repeating: 0, count: 32)
    static func toggling(_ fingerprint: Data, key: String, value: String) -> Data {
        let hash = SHA256.hash(data: Data((key + "\u{0}" + value).utf8))
        return Data(zip(fingerprint, hash).map { $0 ^ $1 })
    }
    var values: [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(count)
        for bucket in buckets { for (key, value) in bucket { result[key] = value } }
        return result
    }
    init() {}
    init(_ values: [String: String]) {
        for (key, value) in values { self[key] = value }
    }
    subscript(key: String) -> String? {
        get { buckets[key.hashValue & 255][key] }
        set {
            let bucket = key.hashValue & 255
            let previous = buckets[bucket][key]
            guard previous != newValue else { return }
            let existed = previous != nil
            if let previous { fingerprint = Self.toggling(fingerprint, key: key, value: previous) }
            if let newValue { fingerprint = Self.toggling(fingerprint, key: key, value: newValue) }
            buckets[bucket][key] = newValue
            if !existed && newValue != nil { count += 1 }
            if existed && newValue == nil { count -= 1 }
        }
    }
    init(from decoder: Decoder) throws {
        let values = try [String: String](from: decoder)
        guard values.count <= 50_000 else { throw AgentGatewayError.journalUnavailable }
        self.init(values)
    }
    func encode(to encoder: Encoder) throws { try values.encode(to: encoder) }
}

/// A received plan is display metadata. It neither creates tasks nor grants
/// authority to execute them. Preserve extra provider fields without inventing
/// defaults for fields required by agent_task_snapshot.v1.
public struct AgentTaskPlanSnapshot: Codable, Equatable, Sendable {
    public let wireValue: JSONValue
    public var planReady: Bool { wireValue["plan_ready"] == .bool(true) }
    public var tasks: [JSONValue] { wireValue["tasks"]?.arrayValue ?? [] }

    public init(validating value: JSONValue) throws {
        guard value.objectValue != nil, value["schema_version"] == "agent_task_snapshot.v1",
              case .bool? = value["plan_ready"], let tasks = value["tasks"]?.arrayValue,
              tasks.allSatisfy({ task in
                  task.objectValue != nil
                      && !(task["task_id"]?.stringValue ?? "").isEmpty
                      && !(task["subject"]?.stringValue ?? "").isEmpty
                      && ["pending", "in_progress", "completed"].contains(task["status"]?.stringValue ?? "")
              }) else { throw AgentGatewayError.malformedPayload }
        wireValue = value
    }
    public init(from decoder: Decoder) throws {
        try self.init(validating: JSONValue(from: decoder))
    }
    public func encode(to encoder: Encoder) throws { try wireValue.encode(to: encoder) }
}

public struct AgentSubagentState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running, completed, failed, stopped, endedUnknown = "ended_unknown"
        public var isTerminal: Bool { self != .running }
        public var label: String {
            switch self {
            case .running: return "进行中"
            case .completed: return "已完成"
            case .failed: return "失败"
            case .stopped: return "已停止"
            case .endedUnknown: return "结果未知"
            }
        }
    }
    public enum TimelineItem: Codable, Equatable, Sendable {
        case text(String)
        case tool(String)
    }
    public let subagentID: String
    public var parentToolCallID: String?
    public var agentType: String?
    public var taskDescription: String?
    public var status: Status = .running
    public var text = ""
    public var tools: [JSONValue] = []
    public var timeline: [TimelineItem] = []
    public var lastContentSequence: Double?

    public init(subagentID: String, parentToolCallID: String? = nil) {
        self.subagentID = subagentID
        self.parentToolCallID = parentToolCallID
    }
    public static func toolIdentity(_ value: JSONValue) -> String? {
        guard let id = value["tool_call_id"]?.stringValue, !id.isEmpty else { return nil }
        return id
    }
    private static let terminalTools: Set<String> = ["completed", "failed", "stopped", "ended_unknown"]

    fileprivate mutating func receive(_ value: JSONValue, phase: String, sequence: Double?) throws {
        if let type = value["agent_type"]?.stringValue, !type.isEmpty { agentType = type }
        if let description = value["task_description"]?.stringValue, !description.isEmpty {
            taskDescription = description
        }
        switch phase {
        case "started", "progress":
            if !status.isTerminal { status = .running }
        case "content":
            guard !status.isTerminal,
                  sequence == nil || lastContentSequence == nil || sequence! > lastContentSequence! else { return }
            let delta = value["text"]?.stringValue ?? ""
            guard text.utf8.count + delta.utf8.count <= 8_388_608 else { throw AgentGatewayError.journalUnavailable }
            text += delta
            if !delta.isEmpty {
                if case .text(let previous)? = timeline.last {
                    timeline[timeline.count - 1] = .text(previous + delta)
                } else {
                    guard timeline.count < 2048 else { throw AgentGatewayError.journalUnavailable }
                    timeline.append(.text(delta))
                }
            }
            if let sequence { lastContentSequence = sequence }
        case "tool_started", "tool_completed":
            let tool: JSONValue
            if let nested = value["tool_event"], nested.objectValue != nil { tool = nested }
            else if let id = value["tool_call_id"]?.stringValue, !id.isEmpty {
                tool = ["schema_version": "tool_event.v1", "type": "tool_event",
                    "tool": value["tool_name"] ?? "", "tool_call_id": .string(id),
                    "status": value["tool_status"] ?? .string(phase == "tool_completed" ? "completed" : "started"),
                    "request": .object([:]), "response": .null]
            } else { return }
            if let id = Self.toolIdentity(tool),
               let index = tools.firstIndex(where: { Self.toolIdentity($0) == id }) {
                let previous = tools[index]
                if Self.terminalTools.contains(previous["status"]?.stringValue ?? ""),
                   !Self.terminalTools.contains(tool["status"]?.stringValue ?? "") { return }
                var merged = tool.objectValue!
                if tool["request"]?.objectValue?.isEmpty != false, let request = previous["request"] {
                    merged["request"] = request
                }
                tools[index] = .object(merged)
            } else {
                guard tools.count < 1024 else { throw AgentGatewayError.journalUnavailable }
                tools.append(tool)
            }
            if let id = Self.toolIdentity(tool), !timeline.contains(.tool(id)) {
                guard timeline.count < 2048 else { throw AgentGatewayError.journalUnavailable }
                timeline.append(.tool(id))
            }
        case "completed", "failed", "stopped":
            if !status.isTerminal, let next = Status(rawValue: phase) { status = next }
        default: break
        }
    }

    /// Legacy projections with an unrecognized status remain unknown. No
    /// compatibility path can manufacture successful completion.
    public init(legacy value: JSONValue) throws {
        guard let id = value["subagent_id"]?.stringValue, !id.isEmpty else {
            throw AgentGatewayError.malformedPayload
        }
        self.init(subagentID: id, parentToolCallID: value["parent_tool_call_id"]?.stringValue)
        agentType = value["agent_type"]?.stringValue
        taskDescription = value["task_description"]?.stringValue
        status = Status(rawValue: value["status"]?.stringValue ?? "") ?? .endedUnknown
        text = value["text"]?.stringValue ?? ""
        tools = (value["tools"]?.arrayValue ?? []).filter { $0.objectValue != nil }.map { item in
            guard item["schema_version"] == nil else { return item }
            var object = item.objectValue!
            object["schema_version"] = "tool_event.v1"; object["type"] = item["type"] ?? "tool_event"
            object["request"] = item["request"] ?? .object([:])
            object["response"] = item["response"] ?? .null
            return .object(object)
        }
        for item in value["timeline"]?.arrayValue ?? [] {
            if item["kind"] == "text", let text = item["text"]?.stringValue { timeline.append(.text(text)) }
            else if item["kind"] == "tool", let id = item["tool_call_id"]?.stringValue { timeline.append(.tool(id)) }
        }
        if case .number(let sequence)? = value["last_content_seq"], sequence.isFinite {
            lastContentSequence = sequence
        }
    }
}

/// Durable, run-scoped display projection. Canvas readback remains an
/// independent consumer of child/tool events.
public struct AgentTaskSubagentProjection: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public enum Content: Codable, Equatable, Sendable {
            case tasks(AgentTaskPlanSnapshot)
            case subagent(AgentSubagentState)
        }
        public let id: String
        public let runID: String
        public var anchor: AgentContextCompactionAnchor?
        public var content: Content
        public let startedAt: Date
        public var endedAt: Date?
    }
    public private(set) var entries: [Entry] = []
    private var receipts = AgentTaskReceiptLedger()
    public init() {}

    // Journal-only access. Wire Codable remains unchanged for v1/v2 snapshots.
    var journalReceipts: [String: String] { receipts.values }
    var journalReceiptCount: Int { receipts.count }
    var journalReceiptFingerprint: Data { receipts.fingerprint }
    func journalPriorReceiptFingerprint(runID: String, eventID: String) -> Data? {
        let key = runID + "\u{0}" + eventID
        guard let value = receipts[key] else { return nil }
        return AgentTaskReceiptLedger.toggling(receipts.fingerprint, key: key, value: value)
    }
    func journalReceipt(runID: String, eventID: String) -> String? {
        receipts[runID + "\u{0}" + eventID]
    }
    init(journalEntries: [Entry], receipts: [String: String]) throws {
        guard journalEntries.count <= 1024, receipts.count <= 50_000,
              Set(journalEntries.map(\.id)).count == journalEntries.count,
              journalEntries.allSatisfy({ entry in
                  guard !entry.id.isEmpty, !entry.runID.isEmpty else { return false }
                  if case .subagent(let child) = entry.content {
                      return !child.subagentID.isEmpty && child.text.utf8.count <= 8_388_608
                          && child.tools.count <= 1024 && child.timeline.count <= 2048
                          && (child.lastContentSequence?.isFinite ?? true)
                  }
                  return true
              }) else {
            throw AgentGatewayError.journalUnavailable
        }
        entries = journalEntries; self.receipts = .init(receipts)
    }

    /// Ex uses Number.isFinite on the component after the first "|". This is
    /// intentionally independent of the safe-integer revision contract.
    public static func contentSequence(eventID: String) -> Double? {
        let parts = eventID.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count > 1, !parts[1].isEmpty else { return nil }
        let text = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 0 }
        let lower = text.lowercased()
        for (prefix, radix) in [("0x", 16), ("0b", 2), ("0o", 8)] where lower.hasPrefix(prefix) {
            let digits = lower.dropFirst(2)
            guard !digits.isEmpty else { return nil }
            var number = 0.0
            for digit in digits {
                guard let value = digit.hexDigitValue, value < radix else { return nil }
                number = number * Double(radix) + Double(value)
            }
            return number.isFinite ? number : nil
        }
        guard let number = Double(text), number.isFinite else { return nil }
        return number
    }
    private mutating func reserve(_ value: JSONValue, eventID: String, runID: String) throws -> Bool {
        guard !eventID.isEmpty, !runID.isEmpty else { throw AgentGatewayError.malformedPayload }
        let key = runID + "\u{0}" + eventID
        let digest = AgentGatewayJournalStore.digest(Data(try value.encodedText().utf8))
        if let prior = receipts[key] {
            guard prior == digest else { throw AgentGatewayError.malformedPayload }
            return false
        }
        guard receipts.count < 50_000 else { throw AgentGatewayError.journalUnavailable }
        receipts[key] = digest
        return true
    }
    public mutating func receiveTasks(_ snapshot: AgentTaskPlanSnapshot, eventID: String, runID: String,
                                     anchor: AgentContextCompactionAnchor?, now: Date = Date()) throws -> Bool {
        var next = self
        guard try next.reserve(snapshot.wireValue, eventID: eventID, runID: runID) else { return false }
        if let index = next.entries.firstIndex(where: {
            guard $0.runID == runID, $0.anchor?.messageID == anchor?.messageID,
                  $0.anchor?.afterMessageID == anchor?.afterMessageID else { return false }
            if case .tasks = $0.content { return true }; return false
        }) {
            // Replace in place, keeping the original transcript position.
            next.entries[index].content = .tasks(snapshot)
        } else {
            guard next.entries.count < 1024 else { throw AgentGatewayError.journalUnavailable }
            next.entries.append(.init(id: runID + ":tasks:" + eventID, runID: runID,
                anchor: anchor, content: .tasks(snapshot), startedAt: now))
        }
        self = next
        return true
    }
    public mutating func receiveSubagent(_ value: JSONValue, eventID: String, runID: String,
                                        anchor: AgentContextCompactionAnchor?, now: Date = Date()) throws -> Bool {
        if let schema = value["schema_version"], schema != "subagent_event.v1" { return false }
        guard value.objectValue != nil, let child = value["subagent_id"]?.stringValue, !child.isEmpty,
              let phase = value["phase"]?.stringValue,
              ["started", "progress", "content", "tool_started", "tool_completed", "completed", "failed", "stopped"]
                .contains(phase) else { return false }
        if let parent = value["parent_tool_call_id"], parent.stringValue == nil {
            throw AgentGatewayError.malformedPayload
        }
        var next = self
        guard try next.reserve(value, eventID: eventID, runID: runID) else { return false }
        let indices = next.entries.indices.filter {
            guard next.entries[$0].runID == runID else { return false }
            if case .subagent(let state) = next.entries[$0].content { return state.subagentID == child }
            return false
        }
        var index = indices.last
        let parent = value["parent_tool_call_id"]?.stringValue
        if let current = index, case .subagent(let state) = next.entries[current].content,
           let parent, !parent.isEmpty, parent != state.parentToolCallID {
            // Only an explicit start with two distinct parent calls proves a
            // successor. An archived parent can never replace that successor.
            guard phase == "started", let previous = state.parentToolCallID, !previous.isEmpty,
                  !indices.contains(where: {
                      if case .subagent(let old) = next.entries[$0].content { return old.parentToolCallID == parent }
                      return false
                  }) else { self = next; return false }
            if !state.status.isTerminal {
                var ended = state; ended.status = .endedUnknown
                next.entries[current].content = .subagent(ended); next.entries[current].endedAt = now
            }
            index = nil
        }
        if index == nil {
            guard next.entries.count < 1024, indices.count < 256 else { throw AgentGatewayError.journalUnavailable }
            next.entries.append(.init(id: runID + ":child:" + eventID, runID: runID, anchor: anchor,
                content: .subagent(.init(subagentID: child, parentToolCallID: parent)), startedAt: now))
            index = next.entries.count - 1
        }
        if let index, case .subagent(var state) = next.entries[index].content {
            try state.receive(value, phase: phase, sequence: Self.contentSequence(eventID: eventID))
            next.entries[index].content = .subagent(state)
            if state.status.isTerminal, next.entries[index].endedAt == nil { next.entries[index].endedAt = now }
        }
        self = next
        return true
    }
    public mutating func attachPending(to messageID: UUID, runID: String) {
        for index in entries.indices where entries[index].runID == runID
            && entries[index].anchor?.messageID == nil && entries[index].anchor?.awaitingAssistant != false {
            entries[index].anchor?.messageID = messageID
        }
    }
    /// Parent termination proves that local observation ended. It does not
    /// prove that remote children succeeded, failed or were killed.
    public mutating func finish(runID: String, now: Date = Date()) {
        for index in entries.indices where entries[index].runID == runID {
            if case .subagent(var state) = entries[index].content, !state.status.isTerminal {
                state.status = .endedUnknown
                entries[index].content = .subagent(state)
                entries[index].endedAt = now
            }
        }
    }
    public mutating func retain(through messageIDs: Set<UUID>) {
        entries.removeAll {
            guard let anchor = $0.anchor else { return true }
            return !(anchor.messageID.map(messageIDs.contains) ?? anchor.afterMessageID.map(messageIDs.contains) ?? false)
        }
    }
    public mutating func merge(_ incoming: Self, runID: String) {
        for entry in incoming.entries where entry.runID == runID {
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
            else { entries.append(entry) }
        }
        for (key, value) in incoming.receipts.values where key.hasPrefix(runID + "\u{0}") { receipts[key] = value }
    }
}
