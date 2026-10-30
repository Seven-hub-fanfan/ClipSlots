import Foundation

/// Client-side readback triggers only. This does not start, schedule or claim
/// completion of a remote child. State is journaled with the source event.
public struct AgentSubagentCanvasProjection: Codable, Sendable {
    private struct Instance: Codable, Sendable {
        let identity: String
        var terminal: Bool
        var parentToolCallID: String?
    }
    private var instances: [String: Instance] = [:]
    private var pending: AgentCanvasReadbackRequest?
    private var pendingChildren: [String: AgentCanvasReadbackRequest]?
    private var retiredInstances: [String: Set<String>]?
    public init() {}
    public var scopes: [String: String] { instances.mapValues(\.identity) }
    public struct Update: Sendable {
        public let request: AgentCanvasReadbackRequest?
    }

    public mutating func receive(_ payload: JSONValue, eventID: String, projectID: String,
                                 conversationID: String, runID: String) throws -> Update? {
        if let schema = payload["schema_version"], schema != "subagent_event.v1" { return nil }
        guard let phase = payload["phase"]?.stringValue,
              ["started", "tool_started", "tool_completed", "tool_failed", "completed", "failed", "stopped"].contains(phase)
        else { return nil }
        guard let child = payload["subagent_id"]?.stringValue else { throw AgentGatewayError.malformedPayload }
        let parent: String?
        if let raw = payload["parent_tool_call_id"] {
            guard let text = raw.stringValue else { throw AgentGatewayError.malformedPayload }
            parent = text
        } else { parent = nil }
        let request = try AgentCanvasReadbackRequest(projectID: projectID, conversationID: conversationID,
            runID: runID, key: eventID, nodeIDs: [], edgeIDs: [],
            source: .init(tool: "subagent_event", subagentID: child, parentToolCallID: parent),
            scope: .subagentCanvas)
        guard let identity = request.subagentInstanceKey else { throw AgentGatewayError.malformedPayload }
        if let current = instances[child] {
            // A late event from an earlier parent cannot replace its successor.
            if current.identity != identity {
                guard phase == "started", let parent, !parent.isEmpty,
                      let previous = current.parentToolCallID, !previous.isEmpty,
                      retiredInstances?[child]?.contains(identity) != true else { return nil }
                var retired = retiredInstances ?? [:]
                guard (retired[child]?.count ?? 0) < 256 else { throw AgentGatewayError.journalUnavailable }
                retired[child, default: []].insert(current.identity)
                retiredInstances = retired
            }
            if current.identity == identity && current.terminal { return nil }
        } else if instances.count >= 256 { throw AgentGatewayError.journalUnavailable }
        let terminal = ["completed", "failed", "stopped"].contains(phase)
        instances[child] = .init(identity: identity, terminal: terminal, parentToolCallID: parent)
        var dirty = pendingChildren ?? pending.map { [$0.source?.subagentID ?? "": $0] } ?? [:]
        pending = nil
        if terminal { dirty.removeValue(forKey: child) }
        else { dirty[child] = request }
        pendingChildren = dirty
        return .init(request: terminal ? request : nil)
    }

    /// A stream can end without a child terminal event. Its dirty intent is
    /// retained until explicitly flushed, including across process recovery.
    public mutating func finish() -> AgentCanvasReadbackRequest? {
        if let child = pendingChildren?.keys.sorted().first {
            return pendingChildren?.removeValue(forKey: child)
        }
        defer { pending = nil }
        return pending
    }
    public mutating func finishAll() -> [AgentCanvasReadbackRequest] {
        var requests: [AgentCanvasReadbackRequest] = []
        while let request = finish() { requests.append(request) }
        return requests
    }
}
