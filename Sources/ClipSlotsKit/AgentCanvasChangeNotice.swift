import Foundation

public struct AgentCanvasReadbackRequest: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable { case subagentCanvas }
    /// Optional v1 provenance for the self-owned gateway. Absent fields stay
    /// absent; a child identity is never inferred from tool names or output.
    public struct Source: Codable, Equatable, Sendable {
        public let tool: String
        public let toolCallID: String?
        public let toolUseID: String?
        public let subagentID: String?
        public let parentToolCallID: String?
        public init(tool: String, toolCallID: String? = nil, toolUseID: String? = nil,
                    subagentID: String? = nil, parentToolCallID: String? = nil) {
            self.tool = tool; self.toolCallID = toolCallID; self.toolUseID = toolUseID
            self.subagentID = subagentID; self.parentToolCallID = parentToolCallID
        }
    }
    public let projectID: String
    public let conversationID: String
    public let runID: String
    public let key: String
    public let nodeIDs: [String]
    public let edgeIDs: [String]
    public let allowsFallback: Bool
    public let source: Source?
    /// Nil is the original expected-ID contract. Full readback is a separate,
    /// explicit scope and cannot be obtained by sending an empty ID list.
    public let scope: Scope?
    public var isFullSnapshot: Bool { scope == .subagentCanvas }

    public init(projectID: String, conversationID: String, runID: String, key: String,
                nodeIDs: [String], edgeIDs: [String], allowsFallback: Bool = false,
                source: Source? = nil, scope: Scope? = nil) throws {
        self.projectID = projectID; self.conversationID = conversationID; self.runID = runID
        self.key = key; self.nodeIDs = Array(Set(nodeIDs)).sorted()
        self.edgeIDs = Array(Set(edgeIDs)).sorted(); self.allowsFallback = allowsFallback
        self.source = source
        self.scope = scope
        try validate()
    }

    public var coordinationKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let provenance = source.flatMap { try? encoder.encode($0) } ?? Data()
        return AgentGatewayJournalStore.digest(Data(
            "\(projectID)\u{0}\(conversationID)\u{0}\(runID)\u{0}\(key)\u{0}".utf8) + provenance
            + (scope.map { Data("\u{0}\($0.rawValue)".utf8) } ?? Data()))
    }
    public var subagentInstanceKey: String? {
        guard let source, let child = source.subagentID else { return nil }
        return AgentGatewayJournalStore.digest(Data("\(child)\u{0}\(source.parentToolCallID ?? "")".utf8))
    }
    public var mutationID: String {
        // Retain legacy receipt identity when representable by the mutation
        // contract. New provenance includes parent/child scope in the receipt.
        source == nil && scope == nil && key.utf8.count <= 247 ? "readback-\(key)" : "readback-\(coordinationKey)"
    }

    public func validate() throws {
        var identities = [projectID, conversationID, runID, key] + nodeIDs + edgeIDs
        if let source {
            identities += [source.tool, source.toolCallID, source.toolUseID,
                           source.subagentID, source.parentToolCallID].compactMap { $0 }
        }
        guard nodeIDs.count <= 1000, edgeIDs.count <= 2000,
              isFullSnapshot
                ? (nodeIDs.isEmpty && edgeIDs.isEmpty && !allowsFallback
                   && source?.tool == "subagent_event" && source?.subagentID != nil)
                : (!nodeIDs.isEmpty || !edgeIDs.isEmpty),
              Set(nodeIDs).count == nodeIDs.count, Set(edgeIDs).count == edgeIDs.count,
              identities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024
                  && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw AgentGatewayError.malformedPayload
        }
    }
}

/// Source tool events are readback indices, never graph mutation authority.
public enum AgentCanvasChangeNotice {
    public static let snapshotTools: Set<String> = [
        "gen_image", "gen_video", "create_text_node", "create_media_node", "update_canvas_node",
        "group_canvas_nodes", "layout_canvas_nodes", "connect_canvas_nodes", "color_adjust_apply",
        "ecommerce_photoset_generate", "layer_composer_apply", "animatic_variants_submit",
        "previs_variants_submit", "animatic_redraw_submit", "animatic_storyboards_generate",
        "animatic_crop_cells", "actor_emotion_save_expression_guide", "prepare_canvas_generation",
        "generate_canvas_media", "submit_prepared_generation", "canvas_operator_regenerate",
        "generate_on_canvas_nodes", "canvas_operator_update_nodes", "canvas_operator_connect",
        "canvas_operator_edit", "import_web_media"
    ]
    private struct IDs {
        var nodes = Set<String>(), edges = Set<String>(), canvases = Set<String>()
        mutating func collect(_ value: JSONValue) {
            for key in ["node_id", "nodeId", "group_node_id", "groupNodeId", "node_ref", "sheet_node_ref"] {
                add(value[key], to: &nodes)
            }
            for key in ["node_ids", "nodeIds", "affected_node_ids"] {
                value[key]?.arrayValue?.forEach { add($0, to: &nodes) }
            }
            for key in ["connection_id", "connectionId", "edge_id", "edgeId"] { add(value[key], to: &edges) }
            for key in ["connection_ids", "connectionIds", "edge_ids", "edgeIds"] {
                value[key]?.arrayValue?.forEach { add($0, to: &edges) }
            }
            for key in ["canvas_id", "canvasId"] { add(value[key], to: &canvases) }
            for key in ["canvas_ref", "canvasRef"] {
                if let raw = value[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   raw.hasPrefix("canvas/") { add(.string(String(raw.dropFirst(7))), to: &canvases) }
            }
        }
        private func add(_ value: JSONValue?, to set: inout Set<String>) {
            if let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                set.insert(text)
            }
        }
    }

    public static func request(event: JSONValue, projectID: String, conversationID: String, runID: String,
                               cliTools: Set<String> = ["Bash", "tapnow_cli"]) throws -> AgentCanvasReadbackRequest? {
        guard let tool = event["tool"]?.stringValue, let status = event["status"]?.stringValue,
              let response = event["response"], response.objectValue != nil else { return nil }
        let cli = cliTools.contains(tool)
        guard cli ? ["completed", "failed"].contains(status) :
              (snapshotTools.contains(tool) && status == "completed") else { return nil }
        // A delete/disconnect notice cannot prove a complete deletion transaction.
        guard response["action"] != "delete", response["action"] != "disconnect" else { return nil }
        var ids = IDs()
        if cli {
            if let direct = response["canvas_changed"], direct.objectValue != nil {
                ids.collect(direct)
            }
            if ids.nodes.isEmpty && ids.edges.isEmpty, let text = response["text"]?.stringValue {
                for notice in try notices(in: text) { ids.collect(notice) }
            }
        } else {
            if let notice = response["canvas_changed"], notice.objectValue != nil { ids.collect(notice) }
            ids.collect(response)
            for key in ["items", "sheets", "created"] {
                for item in response[key]?.arrayValue ?? [] where item.objectValue != nil { ids.collect(item) }
            }
        }
        guard ids.canvases.count <= 1 else { throw AgentGatewayError.originMismatch }
        if let declared = ids.canvases.first, declared != projectID { throw AgentGatewayError.originMismatch }
        guard tool != "ecommerce_photoset_generate" || !ids.canvases.isEmpty else {
            throw AgentGatewayError.originMismatch
        }
        guard !ids.nodes.isEmpty || !ids.edges.isEmpty else { return nil }
        func identity(_ name: String) throws -> String? {
            guard let value = event[name] else { return nil }
            guard let text = value.stringValue else { throw AgentGatewayError.malformedPayload }
            return text
        }
        let source = try AgentCanvasReadbackRequest.Source(tool: tool,
            toolCallID: identity("tool_call_id"), toolUseID: identity("tool_use_id"),
            subagentID: identity("subagent_id"), parentToolCallID: identity("parent_tool_call_id"))
        let call = event["tool_call_id"]?.stringValue ?? event["tool_use_id"]?.stringValue ?? tool
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = AgentGatewayJournalStore.digest(try encoder.encode(response))
        let key = AgentGatewayJournalStore.digest(Data(
            "\(conversationID)\u{0}\(runID)\u{0}\(projectID)\u{0}\(call)\u{0}\(fingerprint)".utf8))
        return try .init(projectID: projectID, conversationID: conversationID, runID: runID,
                         key: key, nodeIDs: Array(ids.nodes), edgeIDs: Array(ids.edges),
                         allowsFallback: cli, source: source)
    }

    /// Balanced JSON objects only; marker, object and total-input budgets are
    /// independent. A brace inside an escaped string cannot end an object.
    static func notices(in text: String) throws -> [JSONValue] {
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw AgentGatewayError.requestTooLarge }
        let bytes = Array(text.utf8), marker = Array("\"_notice\"".utf8)
        var position = 0, markers = 0, output: [JSONValue] = []
        while position + marker.count <= bytes.count && markers < 256 && output.count < 32 {
            guard bytes[position..<(position + marker.count)].elementsEqual(marker) else { position += 1; continue }
            markers += 1; position += marker.count
            func skipWhitespace(_ index: Int) -> Int {
                var i = index
                while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 }
                return i
            }
            var start = skipWhitespace(position)
            guard start < bytes.count, bytes[start] == 58 else { continue }
            start = skipWhitespace(start + 1)
            guard start < bytes.count, bytes[start] == 123 else { continue }
            var stack: [UInt8] = [], quoted = false, escaped = false, end: Int?
            for i in start..<min(bytes.count, start + 64_000) {
                let byte = bytes[i]
                if quoted {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { quoted = false }
                } else if byte == 34 { quoted = true }
                else if byte == 123 || byte == 91 { stack.append(byte == 123 ? 125 : 93) }
                else if byte == 125 || byte == 93 {
                    guard stack.popLast() == byte else { break }
                    if stack.isEmpty { end = i + 1; break }
                }
            }
            guard let end else { continue }
            position = end
            if let object = try? JSONDecoder().decode(JSONValue.self, from: Data(bytes[start..<end])),
               let notice = object["canvas_changed"], notice.objectValue != nil {
                output.append(notice)
            }
        }
        return output
    }
}
