import Foundation
import JavaScriptCore

/// The server observation and the display cache are separate from local token
/// estimates. Preserve absent last_good versus explicit null on disk and wire.
public struct AgentContextUsageSnapshot: Codable, Equatable, Sendable {
    private let wire: JSONValue
    public var conversationID: String { wire["conversation_id"]!.stringValue! }
    public var runID: String { wire["run_id"]!.stringValue! }
    public var revision: UInt64 {
        if case .number(let value) = wire["revision"]! { return UInt64(value) }
        preconditionFailure("Validated revision")
    }
    public var usedTokens: Double? { Self.number(wire["used_tokens"]) }
    public var maxTokens: Double? { Self.number(wire["max_tokens"]) }
    public var percentage: Double? { Self.number(wire["percentage"]) }
    public var model: String? { wire["model"]?.stringValue }
    public var source: String { wire["source"]!.stringValue! }
    public var status: String { wire["status"]!.stringValue! }
    public var observedAt: String { wire["observed_at"]!.stringValue! }
    public var hasLastGood: Bool { wire.objectValue!["last_good"] != nil }
    public var lastGood: AgentContextUsageSnapshot? {
        guard let value = wire["last_good"], value != .null else { return nil }
        return try? .init(validating: value)
    }
    public var wireValue: JSONValue { wire }

    public init(validating value: JSONValue) throws {
        guard Self.valid(value, nested: false) else { throw AgentGatewayError.malformedPayload }
        wire = value
    }

    public init(from decoder: Decoder) throws {
        try self.init(validating: JSONValue(from: decoder))
    }
    public func encode(to encoder: Encoder) throws { try wire.encode(to: encoder) }

    private static func number(_ value: JSONValue?) -> Double? {
        if case .number(let number)? = value { return number }
        return nil
    }
    private static func nullableString(_ value: JSONValue?) -> Bool {
        if value == .null { return true }
        return value?.stringValue != nil
    }
    private static func count(_ value: JSONValue?) -> Bool {
        if value == .null { return true }
        guard let number = number(value) else { return false }
        return number.isFinite && number >= 0
    }
    private static func valid(_ value: JSONValue, nested: Bool) -> Bool {
        guard let fields = value.objectValue,
              let conversation = fields["conversation_id"]?.stringValue, !conversation.isEmpty,
              let run = fields["run_id"]?.stringValue, !run.isEmpty,
              nullableString(fields["runtime_session_id"]),
              let revision = number(fields["revision"]), revision.isFinite,
              revision >= 0, revision <= 9_007_199_254_740_991, revision.rounded() == revision,
              count(fields["used_tokens"]), count(fields["max_tokens"]), number(fields["max_tokens"]) != 0,
              count(fields["percentage"]),
              fields["percentage"] == .null || (fields["used_tokens"] != .null && fields["max_tokens"] != .null),
              nullableString(fields["model"]),
              let source = fields["source"]?.stringValue,
              ["sdk", "last_request_usage", "unavailable"].contains(source),
              let status = fields["status"]?.stringValue, ["ready", "stale", "unavailable"].contains(status),
              status != "ready" || (fields["used_tokens"] != .null && source != "unavailable"),
              status != "unavailable" || (fields["used_tokens"] == .null && fields["max_tokens"] == .null
                  && fields["percentage"] == .null),
              let observed = fields["observed_at"]?.stringValue,
              AgentUsageDateParser.shared.isValid(observed) else { return false }
        if nested { return fields["last_good"] == nil }
        guard let good = fields["last_good"], good != .null else { return true }
        return valid(good, nested: true) && good["status"] == .string("ready")
            && good["conversation_id"] == .string(conversation)
            && (number(good["revision"]) ?? .infinity) <= revision
    }
}

/// Source Qn uses Date.parse rather than an ISO-only format. Use the system JS
/// date parser with a constant function and a string argument, never source code
/// assembled from an event. The private VM has no application callbacks.
private final class AgentUsageDateParser: @unchecked Sendable {
    static let shared = AgentUsageDateParser()
    private let lock = NSLock()
    private let context: JSContext?
    private let parse: JSValue?
    private init() {
        context = JSContext()
        parse = context?.evaluateScript("Date.parse")
    }
    func isValid(_ string: String) -> Bool {
        lock.withLock {
            guard let value = parse?.call(withArguments: [string]), value.isNumber else { return false }
            return value.toDouble().isFinite
        }
    }
}

public enum AgentContextCompactionPhase: String, Codable, Sendable {
    case idle, started, finished
}

/// Versioned client projection of jx/un. This is observation, not an execution
/// budget, and compact events do not implement server-side summarization.
public struct AgentContextUsageState: Codable, Equatable, Sendable {
    public private(set) var snapshot: AgentContextUsageSnapshot?
    public private(set) var displaySnapshot: AgentContextUsageSnapshot?
    public private(set) var localVersion: UInt64 = 0
    public private(set) var stale = false
    public private(set) var compaction: AgentContextCompactionPhase = .idle

    public init() {}
    public mutating func invalidate() {
        stale = true
        localVersion &+= 1
    }
    public mutating func setCompaction(_ phase: AgentContextCompactionPhase) {
        invalidate()
        compaction = phase
    }
    public mutating func interrupt() {
        invalidate()
        compaction = .idle
    }
    public mutating func finishLoading() {
        if compaction == .started { interrupt() }
    }
    public mutating func resetConversation() {
        let version = localVersion
        self = .init()
        localVersion = version
    }

    @discardableResult
    public mutating func receive(_ incoming: AgentContextUsageSnapshot, conversationID: String,
                                 runID: String?, requestedAtVersion: UInt64? = nil) -> Bool {
        guard requestedAtVersion.map({ $0 == localVersion }) ?? true,
              incoming.conversationID == conversationID,
              requestedAtVersion != nil || runID == nil || incoming.runID == runID,
              snapshot.map({ incoming.revision > $0.revision }) ?? true else { return false }
        let oldCompleteSDK = displaySnapshot.map {
            $0.source == "sdk" && $0.percentage != nil && $0.maxTokens != nil
        } ?? false
        let newCompleteSDK = incoming.source == "sdk" && incoming.percentage != nil && incoming.maxTokens != nil
        if (incoming.status == "ready" || (displaySnapshot == nil && incoming.status == "stale")),
           incoming.source != "unavailable", incoming.usedTokens != nil, !(oldCompleteSDK && !newCompleteSDK) {
            displaySnapshot = incoming
        }
        snapshot = incoming
        stale = incoming.status != "ready" || compaction == .started
        if compaction == .finished && incoming.status == "ready" { compaction = .idle }
        if incoming.hasLastGood {
            displaySnapshot = incoming.lastGood ?? (incoming.status == "ready" ? incoming : nil)
        }
        return true
    }

    /// Durable hydration carries the display preference and compact lifecycle.
    /// An existing equal revision cannot replace local state. A request begun
    /// before invalidation is discarded even if it returns a higher revision.
    @discardableResult
    public mutating func hydrate(_ saved: Self, conversationID: String, requestedAtVersion: UInt64) -> Bool {
        guard localVersion == requestedAtVersion else { return false }
        if let incoming = saved.snapshot {
            let empty = snapshot == nil
            let previousCompaction = compaction
            guard receive(incoming, conversationID: conversationID, runID: nil,
                          requestedAtVersion: requestedAtVersion) else { return false }
            if empty { displaySnapshot = saved.displaySnapshot }
            if previousCompaction == .idle { compaction = saved.compaction }
            stale = stale || saved.stale || compaction == .started
        } else {
            guard snapshot == nil, compaction == .idle else { return false }
            let version = localVersion
            self = saved
            localVersion = version
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, snapshot, displaySnapshot, localVersion, stale, compaction
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw AgentGatewayError.malformedPayload
        }
        snapshot = try c.decodeIfPresent(AgentContextUsageSnapshot.self, forKey: .snapshot)
        displaySnapshot = try c.decodeIfPresent(AgentContextUsageSnapshot.self, forKey: .displaySnapshot)
        localVersion = try c.decode(UInt64.self, forKey: .localVersion)
        stale = try c.decode(Bool.self, forKey: .stale)
        compaction = try c.decode(AgentContextCompactionPhase.self, forKey: .compaction)
        if let display = displaySnapshot {
            guard let snapshot, display.conversationID == snapshot.conversationID,
                  display.revision <= snapshot.revision, display.source != "unavailable",
                  display.usedTokens != nil, display.status != "unavailable" else {
                throw AgentGatewayError.malformedPayload
            }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .schemaVersion)
        try c.encodeIfPresent(snapshot, forKey: .snapshot)
        try c.encodeIfPresent(displaySnapshot, forKey: .displaySnapshot)
        try c.encode(localVersion, forKey: .localVersion)
        try c.encode(stale, forKey: .stale)
        try c.encode(compaction, forKey: .compaction)
    }
}

/// Conversation display history, separate from the model request history.
/// Events are scoped to a run; finished updates the active card in place.
public struct AgentContextCompactionLifecycle: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public var phase: AgentContextCompactionPhase
        public var runID: String?
        public var anchor: AgentContextCompactionAnchor?
        public var finishedEventID: String?
        public var displayID: String {
            let scope = runID ?? ""
            return "\(scope.utf8.count):" + scope + id
        }
    }
    public private(set) var entries: [Entry] = []
    public init() {}
    @discardableResult
    public mutating func receive(_ phase: AgentContextCompactionPhase, eventID: String,
                                 runID: String? = nil, anchor: AgentContextCompactionAnchor? = nil) -> Bool {
        guard phase != .idle, !eventID.isEmpty,
              !entries.contains(where: { $0.runID == runID && ($0.id == eventID || $0.finishedEventID == eventID) })
        else { return false }
        if let index = entries.lastIndex(where: { $0.runID == runID && $0.phase == .started }) {
            guard phase == .finished else { return false }
            entries[index].phase = .finished
            entries[index].finishedEventID = eventID
        } else {
            entries.append(.init(id: eventID, phase: phase, runID: runID, anchor: anchor))
        }
        return true
    }
    public mutating func interrupt() { entries.removeAll { $0.phase == .started } }

    /// Direct streaming backends do not expose the assistant ID until complete.
    /// Bind only the unresolved cards of that run, without modifying body bytes.
    public mutating func attachPending(to messageID: UUID, runID: String) {
        for index in entries.indices where entries[index].runID == runID
                && entries[index].anchor?.awaitingAssistant == true && entries[index].anchor?.messageID == nil {
            entries[index].anchor?.messageID = messageID
        }
    }

    /// A journal can restore additional cards, but cannot downgrade a finished
    /// lifecycle or relocate an already anchored card.
    public mutating func merge(_ incoming: Self, runID: String) {
        for source in incoming.entries {
            guard source.runID == nil || source.runID == runID else { continue }
            var source = source
            source.runID = runID
            if let index = entries.firstIndex(where: { $0.runID == runID && $0.id == source.id }) {
                guard entries[index].phase != .finished,
                      entries[index].anchor == nil || entries[index].anchor == source.anchor else { continue }
                entries[index] = source
            } else { entries.append(source) }
        }
    }

    public mutating func retain(through messageIDs: Set<UUID>) {
        entries.removeAll {
            guard let anchor = $0.anchor else { return true }
            return !((anchor.messageID ?? anchor.afterMessageID).map(messageIDs.contains) ?? false)
        }
    }
}

public struct AgentContextUsageDisplay: Equatable, Sendable {
    public let usedTokens: Double?
    public let maxTokens: Double?
    /// Text retains the server value, including >100%; only the ring is clamped.
    public let percentage: Double?
    public var fraction: Double? { percentage.map { min(1, max(0, $0 / 100)) } }
    public let statusLabel: String
    public let sourceLabel: String
    public init(state: AgentContextUsageState) {
        usedTokens = state.displaySnapshot?.usedTokens
        maxTokens = state.displaySnapshot?.maxTokens
        percentage = state.displaySnapshot?.percentage
        switch state.compaction {
        case .started: statusLabel = "正在压缩"
        case .finished: statusLabel = "等待压缩后用量"
        case .idle:
            statusLabel = state.displaySnapshot == nil ? "用量未知"
                : state.stale || state.snapshot != state.displaySnapshot ? "上次可靠观测" : "当前上下文"
        }
        switch state.displaySnapshot?.source {
        case "sdk": sourceLabel = "运行时 SDK"
        case "last_request_usage": sourceLabel = "最近请求"
        default: sourceLabel = "暂无权威观测"
        }
    }
}
