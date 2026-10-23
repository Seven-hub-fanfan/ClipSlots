import Foundation

/// Local canvas tools are dispatched by the project host, never by a shell.
/// Permission is enforced both when publishing schemas and when executing.
public final class CanvasAgentActionTools: AgentToolExecuting, AgentCLICommandAuthorizing {
    public static let readers: Set<String> = ["canvas_current", "canvas_get_node", "canvas_list_models"]
    public static let writers: Set<String> = [
        "canvas_create_node", "canvas_edit_node", "canvas_configure_node",
        "canvas_move_node", "canvas_layout_nodes", "canvas_connect_nodes", "canvas_disconnect_edge",
        "canvas_group_nodes", "canvas_delete_nodes", "canvas_undo", "canvas_redo",
        "canvas_generate"
    ]
    private let base: AgentToolExecuting
    private let mode: AgentAccessMode
    private let automaticApproval: Bool
    private let perform: @Sendable (AgentToolCall, JSONValue) async throws -> JSONValue
    private let onInteraction: @Sendable (AgentInteraction) async -> Void

    public init(base: AgentToolExecuting, mode: AgentAccessMode, automaticApproval: Bool? = nil,
                onInteraction: @escaping @Sendable (AgentInteraction) async -> Void,
                perform: @escaping @Sendable (AgentToolCall, JSONValue) async throws -> JSONValue) {
        self.base = base; self.mode = mode
        self.automaticApproval = automaticApproval ?? (mode == .fullAccess)
        self.perform = perform; self.onInteraction = onInteraction
    }

    public func permitsCLI(_ command: String) -> Bool { false }

    public func specs() -> [AgentToolSpec] {
        let string: JSONValue = ["type": "string"]
        let number: JSONValue = ["type": "number", "minimum": -100000, "maximum": 100000]
        let ids: JSONValue = ["type": "array", "items": string, "minItems": 1, "maxItems": 50]
        func spec(_ name: String, _ description: String, _ fields: [String: JSONValue],
                  _ required: [String]) -> AgentToolSpec {
            .init(name: name, description: description, parameters: [
                "type": "object", "additionalProperties": false,
                "properties": .object(fields), "required": .array(required.map(JSONValue.string))
            ], originLabel: "当前画布")
        }
        let live = [
            spec("canvas_current", "读取当前项目的实时节点、编组、连线与 graph_revision；offset 分页，正文限4000字符。新建或修改后用此工具读取真实结果。",
                 ["offset": ["type": "integer", "minimum": 0]], []),
            spec("canvas_get_node", "读取实时节点全部正文和配置，返回 node_revision。修改该节点前必须读取此版本；历史 canvas_read_* 仍是固定快照。",
                 ["node_id": string], ["node_id"]),
            spec("canvas_list_models", "读取当前Crate实际可用的图片/视频模型ID、名称、比例和分辨率。配置模型前先查询，必须使用返回的精确ID，不能猜测gpt2等别名。不会提交生成。",
                 [:], [])
        ]
        guard mode != .allDirectoriesReadOnly else { return base.specs() + live }
        let permission = automaticApproval ? "按本轮授权直接执行，" : "由用户确认后执行，"
        return base.specs() + live + [
            spec("canvas_create_node", permission + "在当前画布新建真实文本/图片/视频节点，保存正文并记录撤销。x/y是中心世界坐标；parent_ids可连接上游。不会提交生成。",
                 ["kind": ["type": "string", "enum": ["text", "image", "video"]],
                  "text": ["type": "string", "maxLength": 96000], "x": number, "y": number,
                  "parent_ids": ["type": "array", "items": string, "maxItems": 20]],
                 ["kind", "text", "x", "y"]),
            spec("canvas_edit_node", permission + "替换节点正文，保留附件与富文本撤销。版本过期时拒绝修改，请重新读取。",
                 ["node_id": string, "expected_revision": string,
                  "text": ["type": "string", "maxLength": 96000]],
                 ["node_id", "expected_revision", "text"]),
            spec("canvas_configure_node", permission + "修改生成参数，使用节点原生保存和撤销；ratio同时更新媒体卡片尺寸。model必须是canvas_list_models返回的精确ID。",
                 ["node_id": string, "expected_revision": string, "model": string, "ratio": string,
                  "count": ["type": "integer", "minimum": 1, "maximum": 4], "resolution": string,
                  "duration": ["type": ["integer", "null"], "minimum": 1, "maximum": 120],
                  "generate_audio": ["type": ["boolean", "null"]]],
                 ["node_id", "expected_revision"]),
            spec("canvas_move_node", permission + "移动节点到x/y世界坐标（左上角），支持撤销。",
                 ["node_id": string, "expected_revision": string, "x": number, "y": number],
                 ["node_id", "expected_revision", "x", "y"]),
            spec("canvas_layout_nodes", permission + "一次排布指定节点，horizontal按连线从左到右，grid按方格。使用真实卡片尺寸，保留正文、比例、连线和编组；完整子编组作为整体移动，堆叠必须选择全部成员。保存并合成一次撤销，失败不回写。先读取当前graph_revision。",
                 ["node_ids": ["type": "array", "items": string, "minItems": 2, "maxItems": 50],
                  "layout": ["type": "string", "enum": ["horizontal", "grid"]],
                  "expected_graph_revision": string], ["node_ids", "layout", "expected_graph_revision"]),
            spec("canvas_connect_nodes", permission + "连接两个现有节点作为生成输入，验证重复、循环与端口权限。先读取当前graph_revision。",
                 ["from_node_id": string, "to_node_id": string, "expected_graph_revision": string,
                  "role": ["type": "string", "enum": .array(CanvasEdgeRole.allCases.map { .string($0.rawValue) })]],
                 ["from_node_id", "to_node_id", "expected_graph_revision"]),
            spec("canvas_disconnect_edge", permission + "移除指定连线并记录撤销。",
                 ["edge_id": string, "expected_graph_revision": string], ["edge_id", "expected_graph_revision"]),
            spec("canvas_group_nodes", permission + "将指定节点编组，保留节点内容和连线，支持撤销。",
                 ["node_ids": ids, "name": ["type": "string", "minLength": 1, "maxLength": 120],
                  "expected_graph_revision": string], ["node_ids", "name", "expected_graph_revision"]),
            spec("canvas_delete_nodes", permission + "删除明确指定的节点和相关连线，可从画布历史撤销；不删除槽位库源文件。",
                 ["node_ids": ids, "expected_graph_revision": string], ["node_ids", "expected_graph_revision"]),
            spec("canvas_undo", permission + "撤销指定的最近一次Agent画布操作；有后续操作时拒绝跳过。",
                 ["history_id": string], ["history_id"]),
            spec("canvas_redo", permission + "重做指定Agent画布操作；版本冲突时拒绝。",
                 ["history_id": string], ["history_id"]),
            spec("canvas_generate", permission + "通过画布现有Crate/ByteArtist生成链提交当前提示词和参数，无依赖节点并发，有依赖节点等待本轮上游。按节点count生成，可能消耗额度，必须是用户明确要求生成的任务。返回真实状态，失败不能声称产物已生成。",
                 ["node_ids": ids, "expected_graph_revision": string], ["node_ids", "expected_graph_revision"])
        ]
    }

    public func execute(call: AgentToolCall) async -> AgentToolResult {
        guard Self.readers.contains(call.name) || Self.writers.contains(call.name) else {
            return await base.execute(call: call)
        }
        guard let spec = specs().first(where: { $0.name == call.name }) else {
            return .failure("当前为只读模式，画布没有修改。", code: "ACCESS_MODE_DENIED")
        }
        do {
            try Task.checkCancellation()
            let input = try JSONValue.decode(jsonText: call.argumentsJSON)
            try GenerationSchema.validate(input, schema: spec.parameters)
            if call.name == "canvas_layout_nodes", let ids = input["node_ids"]?.arrayValue?.compactMap(\.stringValue),
               Set(ids).count != ids.count {
                throw AgentOperationError("节点列表包含重复项，未排布。")
            }
            if Self.writers.contains(call.name), !automaticApproval {
                let decision = CanvasActionDecision()
                let request = AgentInteraction(kind: .commandApproval, params: [
                    "command": .string(call.name), "reason": "修改当前画布",
                    "title": .string(Self.approvalTitle(call.name, input: input)),
                    "preview": .string(String(input["text"]?.stringValue?.prefix(240) ?? "")),
                    "item": ["command": .string(call.name), "arguments": input],
                    "availableDecisions": ["accept", "decline"]
                ]) { value in decision.set(value["decision"] == .string("accept")) }
                await onInteraction(request)
                defer { request.invalidate() }
                while decision.value == nil && Date() < request.expiresAt {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(80))
                }
                guard decision.value == true else {
                    return .failure("未允许本次操作，画布没有修改。", code: "DECLINED")
                }
            }
            try Task.checkCancellation()
            let value = try await perform(call, input)
            return .init(content: try value.encodedText(), isFailure: value["ok"] == .bool(false),
                         summary: value["summary"]?.stringValue ?? "画布操作已完成")
        } catch {
            return .failure(error is CancellationError ? "本轮已停止。" : error.localizedDescription,
                            code: error is CancellationError ? "CANCELLED" : "CANVAS_ACTION_FAILED")
        }
    }

    private static func approvalTitle(_ name: String, input: JSONValue) -> String {
        if name == "canvas_create_node" {
            let kind = ["text": "文本", "image": "图片", "video": "视频"][input["kind"]?.stringValue ?? ""] ?? ""
            return "新建\(kind)节点"
        }
        return [
            "canvas_edit_node": "修改节点正文", "canvas_configure_node": "调整生成参数",
            "canvas_move_node": "移动节点", "canvas_layout_nodes": "整理节点布局",
            "canvas_connect_nodes": "连接节点",
            "canvas_disconnect_edge": "断开连线", "canvas_group_nodes": "创建编组",
            "canvas_delete_nodes": "删除所选节点", "canvas_undo": "撤销画布操作",
            "canvas_redo": "重做画布操作", "canvas_generate": "生成图片或视频，可能消耗生成额度"
        ][name] ?? "修改当前画布"
    }
}

private final class CanvasActionDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Bool?
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return answer }
    func set(_ value: Bool) { lock.lock(); defer { lock.unlock() }; answer = value }
}
