import Foundation

/// Declarative, path-free workflow. Instructions never grant executable tools.
public struct WorkflowSkill: Codable, Equatable {
    public enum Scope: String, Codable, CaseIterable { case personal, project }
    public enum Value: Codable, Equatable {
        case text(String), integer(Int), boolean(Bool), resources([String])
        public var displayText: String {
            switch self {
            case .text(let value): return value
            case .integer(let value): return String(value)
            case .boolean(let value): return value ? "true" : "false"
            case .resources(let values): return values.joined(separator: "\n")
            }
        }
    }
    public enum Field: String, Codable, CaseIterable {
        case title, body, instruction, model, ratio, resolution, duration, audio, images, video
        public var label: String {
            switch self {
            case .title: return "标题"
            case .body: return "正文 / Prompt"
            case .instruction: return "文本优化指令"
            case .model: return "模型"
            case .ratio: return "比例"
            case .resolution: return "分辨率"
            case .duration: return "时长（秒）"
            case .audio: return "生成音频"
            case .images: return "参考图片"
            case .video: return "视频素材"
            }
        }
        public var type: Variable.Kind {
            switch self {
            case .duration: return .integer
            case .audio: return .boolean
            case .images: return .images
            case .video: return .video
            default: return .text
            }
        }
    }
    public struct Binding: Codable, Equatable {
        public var nodeID: String
        public var field: Field
        /// nil replaces the entire field. A literal match only applies within this field.
        public var match: String?
        public init(nodeID: String, field: Field, match: String? = nil) {
            self.nodeID = nodeID; self.field = field; self.match = match
        }
    }
    public struct Variable: Codable, Equatable, Identifiable {
        public enum Kind: String, Codable, CaseIterable { case text, integer, boolean, images, video }
        public var id: String
        public var name: String
        public var kind: Kind
        public var required: Bool
        public var defaultValue: Value?
        public var minimum: Int?
        public var maximum: Int?
        public var bindings: [Binding]
        public init(id: String = UUID().uuidString, name: String, kind: Kind,
                    required: Bool = true, defaultValue: Value? = nil,
                    minimum: Int? = nil, maximum: Int? = nil, bindings: [Binding]) {
            self.id = id; self.name = name; self.kind = kind; self.required = required
            self.defaultValue = defaultValue; self.minimum = minimum; self.maximum = maximum
            self.bindings = bindings
        }
        public func parse(_ text: String) throws -> Value? {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            switch kind {
            case .text: return .text(text)
            case .integer:
                guard let value = Int(text) else { throw AgentOperationError("\(name)需要填写整数。") }
                return .integer(value)
            case .boolean:
                guard text == "true" || text == "false" else { throw AgentOperationError("\(name)需要选择是或否。") }
                return .boolean(text == "true")
            case .images, .video:
                throw AgentOperationError("请通过文件选择器绑定\(name)。")
            }
        }
        public func validate(_ value: Value) throws {
            let valid: Bool
            switch (kind, value) {
            case (.text, .text(let v)): valid = (!required || !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && v.utf8.count <= 96_000
            case (.integer, .integer(let v)): valid = (minimum.map { v >= $0 } ?? true) && (maximum.map { v <= $0 } ?? true)
            case (.boolean, .boolean): valid = true
            case (.images, .resources(let v)): valid = (!required || !v.isEmpty) && v.count <= 20 && v.allSatisfy { !$0.isEmpty }
            case (.video, .resources(let v)): valid = (!required || !v.isEmpty) && v.count <= 1 && v.allSatisfy { !$0.isEmpty }
            default: valid = false
            }
            guard valid else { throw AgentOperationError("变量「\(name)」类型、必填项或范围不正确。") }
        }
    }
    public struct Node: Codable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var body: String
        /// Contains only local identities and idle state; validated before save/load/instantiate.
        public var configuration: CanvasNode
        public func text(for field: Field) -> String? {
            switch field {
            case .title: return title
            case .body: return body
            case .instruction: return configuration.textGenerationPrompt
            case .model: return configuration.model
            case .ratio: return configuration.ratio
            case .resolution: return configuration.resolution
            default: return nil
            }
        }
    }
    public struct Edge: Codable, Equatable, Identifiable {
        public var id: String
        public var from: String
        public var to: String
        public var role: CanvasEdgeRole
        public var order: Int
    }
    public struct Graph: Codable, Equatable {
        public var schemaVersion = 1
        public var nodes: [Node]
        public var edges: [Edge]
        public var variables: [Variable]
    }
    public struct Provenance: Codable, Equatable {
        public struct Source: Codable, Equatable {
            public var localID: String
            public var nodeID: String
            public var createdAt: Date
            public var bodyRevision: String
            public var runID: UUID?
        }
        public var snapshotID: UUID
        public var projectID: String
        public var graphRevision: String
        public var capturedAt: Date
        public var messageID: UUID?
        public var sources: [Source]
        public var readReceipts: [CanvasReadReceipt]
        public var limitations: [String]
    }
    public var id: UUID
    public var version: Int
    public var name: String
    public var summary: String
    public var method: String
    public var scope: Scope
    public var projectID: String?
    public var graph: Graph
    public var provenance: Provenance

    public init(snapshot: CanvasAgentSnapshot, method: String, messageID: UUID?,
                receipts: [CanvasReadReceipt], selectedWorkflow: Bool = false) throws {
        let source = snapshot.graph
        let included = selectedWorkflow && !source.selectionIDs.isEmpty
            ? source.subgraphIDs(roots: source.selectionIDs, direction: .upstream) : Set(source.nodes.map(\.id))
        let facts = source.nodes.filter { included.contains($0.id) }
        guard !facts.isEmpty, Set(facts.map(\.id)).count == facts.count, facts.allSatisfy(\.bodyAvailable) else {
            throw AgentOperationError("没有可保存的完整正文，请检查节点来源后重新发送。")
        }
        id = UUID(); version = 0; name = "我的创作方法"; summary = ""
        self.method = method; scope = .personal; projectID = nil
        let mapping = Dictionary(uniqueKeysWithValues: facts.enumerated().map { ($0.element.id, "n\($0.offset + 1)") })
        var variables: [Variable] = []
        let nodes = facts.map { fact -> Node in
            let local = mapping[fact.id] ?? ""
            var config = fact.configuration
            config.pageId = ""; config.groupId = local; config.slot = 1
            config.taskId = nil; config.state = .idle; config.seed = nil; config.parentNodeId = nil
            config.generationTask = nil; config.generationRawOutput = nil
            config.generationDiagnostic = nil
            // Portable workflows currently carry generation inputs only, not remote draft identities.
            config.draftVideoID = nil; config.draftReference = nil
            config.generationSourceID = fact.configuration.generationSourceID.flatMap { mapping[$0].map { $0 + "#1" } }
            config.outputAttachmentIds = []; config.inputAttachmentIds = []; config.mediaLayoutAttachmentID = nil
            config.createdAt = .distantPast; config.updatedAt = .distantPast
            let media = fact.media.filter { config.isMediaSource || $0.role != "output" }
            for field in [Field.images, .video] {
                if field == .video && !(config.isMediaSource && config.kind == .video) { continue }
                if field == .images && config.isMediaSource && config.kind == .video { continue }
                let names = media.filter { $0.kind == (field == .images ? "image" : "video") }.map(\.name)
                if !names.isEmpty || (config.isMediaSource && (config.kind == .video ? field == .video : field == .images)) {
                    variables.append(Variable(name: "\(fact.title) · \(field.label)", kind: field.type,
                        bindings: [.init(nodeID: local, field: field)]))
                }
            }
            return Node(id: local, title: fact.title, body: fact.bodyText, configuration: config)
        }
        let edges = source.edges.filter {
            $0.purpose.isGenerationDependency && included.contains($0.fromNodeId) && included.contains($0.toNodeId)
        }
            .enumerated().map { index, edge in
                Edge(id: "e\(index + 1)", from: mapping[edge.fromNodeId] ?? "", to: mapping[edge.toNodeId] ?? "",
                     role: edge.role, order: index)
            }
        graph = Graph(nodes: nodes, edges: edges, variables: variables)
        provenance = Provenance(snapshotID: source.snapshotID, projectID: source.projectID,
            graphRevision: source.graphRevision, capturedAt: source.capturedAt, messageID: messageID,
            sources: facts.map { .init(localID: mapping[$0.id] ?? "", nodeID: $0.id,
                createdAt: $0.configuration.createdAt, bodyRevision: $0.bodyRevision, runID: $0.latestRunID) },
            readReceipts: receipts.filter { $0.snapshotID == source.snapshotID },
            limitations: source.omissions + [
                "方法来自待确认的回复；保存前需核对事实、用户决策与推测。图结构来自发送时的快照。",
                "复用不复制旧媒体与生成任务。输入素材需重新绑定，生成节点需在新画布执行。",
                selectedWorkflow ? "范围：发送时选区及其上游依赖。" : "范围：发送时整个项目。"
            ])
        try validate()
    }

    public func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw AgentOperationError(message) }
        }
        try require(graph.schemaVersion == 1, "不支持的工作流格式。")
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120, "Skill 名称需为 1–120 字。")
        try require(summary.count <= 400 && !method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "请填写方法说明，适用场景限 400 字。")
        try require(scope == .personal ? projectID == nil : projectID?.isEmpty == false, "Skill 保存范围不正确。")
        try require(!graph.nodes.isEmpty && graph.nodes.count <= 500 && graph.edges.count <= 2000
                    && graph.variables.count <= 200, "工作流规模超出支持范围。")
        let ids = Set(graph.nodes.map(\.id))
        try require(ids.count == graph.nodes.count && ids.allSatisfy { !$0.isEmpty }, "工作流节点身份重复或为空。")
        for node in graph.nodes {
            let c = node.configuration
            try require(c.groupId == node.id && c.slot == 1 && c.pageId.isEmpty && c.state == .idle
                && c.taskId == nil && c.generationTask == nil && c.generationRawOutput == nil && c.generationDiagnostic == nil
                && c.seed == nil && c.parentNodeId == nil && c.outputAttachmentIds.isEmpty
                && c.inputAttachmentIds.isEmpty && c.mediaLayoutAttachmentID == nil,
                "模板含旧任务、素材绑定或非局部节点身份。")
            try require(c.generationSourceID == nil || graph.nodes.contains {
                $0.configuration.id == c.generationSourceID && $0.id != node.id
            }, "生成来源必须是同一模板中的其他节点。")
            try require([c.x, c.y, c.width, c.height].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
                && c.width > 0 && c.height > 0 && node.body.utf8.count <= 96_000, "节点正文或尺寸超出支持范围。")
        }
        try require(Set(graph.edges.map(\.id)).count == graph.edges.count
            && Set(graph.edges.map(\.order)).count == graph.edges.count, "连线身份或顺序重复。")
        var reachable: [String: Set<String>] = [:]
        var pairs = Set<String>()
        for edge in graph.edges.sorted(by: { $0.order < $1.order }) {
            try require(ids.contains(edge.from) && ids.contains(edge.to) && edge.from != edge.to && edge.order >= 0,
                        "连线端点或顺序不正确。")
            try require(pairs.insert(edge.from + "\u{0}" + edge.to).inserted, "工作流含重复连线。")
            reachable[edge.from, default: []].insert(edge.to)
        }
        // Iterative traversal also rejects corrupted cyclic source documents.
        for root in ids {
            var seen = Set<String>(), queue = Array(reachable[root] ?? [])
            while let next = queue.popLast() {
                try require(next != root, "工作流含循环依赖，请先修复连线。")
                if seen.insert(next).inserted { queue.append(contentsOf: reachable[next] ?? []) }
            }
        }
        try require(Set(graph.variables.map(\.id)).count == graph.variables.count, "变量身份重复。")
        var occupied = Set<String>()
        for variable in graph.variables {
            try require(!variable.id.isEmpty && !variable.name.isEmpty && !variable.bindings.isEmpty, "变量需要名称和字段绑定。")
            if let min = variable.minimum, let max = variable.maximum {
                try require(min <= max, "变量的最小值不能超过最大值。")
            }
            if let value = variable.defaultValue {
                try variable.validate(value)
                if case .resources = value { throw AgentOperationError("媒体变量不能保存本地路径或旧素材默认值。") }
            }
            for binding in variable.bindings {
                guard let node = graph.nodes.first(where: { $0.id == binding.nodeID }) else {
                    throw AgentOperationError("变量绑定的节点不存在。")
                }
                try require(binding.field.type == variable.kind, "变量类型与绑定字段不一致。")
                try require(occupied.insert(binding.nodeID + ":" + binding.field.rawValue).inserted,
                            "同一字段只能绑定一个变量；一个变量可以绑定多个节点字段。")
                if let match = binding.match {
                    try require(!match.isEmpty && variable.kind == .text && node.text(for: binding.field)?.contains(match) == true,
                                "替换片段在绑定字段中不存在。")
                }
                if binding.field == .instruction { try require(node.configuration.kind == .text, "优化指令只能绑定文本节点。") }
                if binding.field == .duration || binding.field == .audio || binding.field == .resolution {
                    try require(node.configuration.kind == .video && !node.configuration.isMediaSource, "此参数只能绑定视频生成节点。")
                }
                if binding.field == .video { try require(node.configuration.isMediaSource && node.configuration.kind == .video, "视频素材只能绑定视频来源节点。") }
                if binding.field == .images {
                    try require(!(node.configuration.isMediaSource && node.configuration.kind == .video), "视频来源节点需要绑定视频素材。")
                }
            }
        }
        let lowered = method.lowercased()
        try require(!lowered.contains("clipslots-tools") && !lowered.contains("agent-tools"),
                    "创作 Skill 仅保存方法与工作流，请移除可执行工具声明。")
        try require((try markdown()).utf8.count <= AgentSkillReference.maximumBytes, "方法说明超过 64 KiB，请精简后保存。")
    }

    public func markdown() throws -> String {
        let variables = graph.variables.map { variable in
            let bindings = variable.bindings.map {
                "\($0.nodeID).\($0.field.rawValue)" + ($0.match.map { "（仅替换“\($0)”）" } ?? "（整个字段）")
            }.joined(separator: "、")
            return "- \(variable.name) [\(variable.kind.rawValue)] · \(variable.required ? "必填" : "可选") · \(bindings)"
        }.joined(separator: "\n")
        let digest = CanvasWorkflowSnapshot.digest(try CanvasWorkflowSnapshot.jsonData(graph))
        return """
        # \(name)

        \(summary)

        \(method)

        ## 变量与字段绑定
        \(variables.isEmpty ? "无变量；按保存的字段创建。" : variables)

        ## 使用方式
        在 ClipSlots 中填写变量，预览后确认创建新项目，再通过画布生成按钮执行。
        本文档不授予脚本、终端或文件写入权限。
        工作流版本：\(version)；workflow.json SHA256：\(digest)

        ## 已知限制
        \(provenance.limitations.map { "- " + $0 }.joined(separator: "\n"))
        """
    }

    public struct Instance {
        public var nodes: [Node]
        public var edges: [Edge]
        /// Keys are local node identities; resources are supplied by the app's picker.
        public var media: [String: [String]]
        public var issues: [String]
    }
    public func instantiate(values: [String: Value], models: [CrateModelCatalog.ModelInfo] = []) throws -> Instance {
        try validate()
        guard Set(values.keys).isSubset(of: Set(graph.variables.map(\.id))) else { throw AgentOperationError("出现未知变量。") }
        var instance = Instance(nodes: graph.nodes, edges: graph.edges.sorted { $0.order < $1.order }, media: [:], issues: [])
        for variable in graph.variables {
            guard let value = values[variable.id] ?? variable.defaultValue else {
                if variable.required { instance.issues.append("待填写：\(variable.name)") }
                continue
            }
            try variable.validate(value)
            for binding in variable.bindings {
                guard let index = instance.nodes.firstIndex(where: { $0.id == binding.nodeID }) else { continue }
                var node = instance.nodes[index]
                if case .text(let text) = value {
                    let result = binding.match.map { node.text(for: binding.field)?.replacingOccurrences(of: $0, with: text) ?? text } ?? text
                    switch binding.field {
                    case .title: node.title = result
                    case .body: node.body = result
                    case .instruction: node.configuration.textGenerationPrompt = result
                    case .model: node.configuration.model = result
                    case .ratio: node.configuration.ratio = result
                    case .resolution: node.configuration.resolution = result
                    default: break
                    }
                } else if case .integer(let number) = value { node.configuration.duration = number }
                else if case .boolean(let flag) = value { node.configuration.generateAudio = flag }
                else if case .resources(let resources) = value {
                    if node.configuration.isMediaSource && resources.count > 1 {
                        throw AgentOperationError("来源节点「\(node.title)」每次只能绑定一份素材。")
                    }
                    instance.media[node.id, default: []].append(contentsOf: resources)
                }
                instance.nodes[index] = node
            }
        }
        for node in instance.nodes {
            let c = node.configuration
            if c.isMediaSource && instance.media[node.id]?.isEmpty != false {
                instance.issues.append("\(node.title)：来源素材待绑定。")
            }
            guard c.canGenerate else { continue }
            if c.generationProvider == .byteartist {
                instance.issues.append("\(node.title)：请在画布加载 BA 工作流并核对输入绑定。")
                continue
            }
            guard let model = models.first(where: { $0.id == c.model && $0.enabled }) else {
                instance.issues.append("\(node.title)：模型 \(c.model) 尚未验证，请在画布确认可用模型。"); continue
            }
            if (c.kind == .video ? !model.isVideoGenerator : !model.isImageGenerator) {
                instance.issues.append("\(node.title)：模型与节点类型不兼容。")
            }
            if c.count != 1 { instance.issues.append("\(node.title)：当前执行链仅支持单次生成一份产物。") }
            if !c.ratio.isEmpty && (!model.supportsRatio || !model.ratioOptions.contains(where: { $0.value == c.ratio })) {
                instance.issues.append("\(node.title)：比例 \(c.ratio) 需要核对。")
            }
            if let duration = c.duration, !model.supportsDuration || model.durationSpec?.allows(duration) == false {
                instance.issues.append("\(node.title)：时长 \(duration) 秒不受当前模型支持。")
            }
            if c.generateAudio != nil && !model.supportsAudio { instance.issues.append("\(node.title)：模型不支持音频参数。") }
            if !c.resolution.isEmpty && (!model.supportsResolution || !model.resolutionOptions.contains(where: { $0.value == c.resolution })) {
                instance.issues.append("\(node.title)：分辨率 \(c.resolution) 需要核对。")
            }
        }
        return instance
    }
}
