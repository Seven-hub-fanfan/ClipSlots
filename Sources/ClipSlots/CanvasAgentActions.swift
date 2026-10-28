import AppKit
import ClipSlotsKit

extension CanvasAgentContext {
    func actionTools(for turn: CanvasAgentTurn, mode: AgentAccessMode, automaticApproval: Bool? = nil, conversationID: UUID,
                     isCurrent: @escaping @MainActor @Sendable () -> Bool,
                     onInteraction: @escaping @Sendable (AgentInteraction) async -> Void) throws -> CanvasAgentActionTools {
        let frozen = try reader(for: turn)
        return CanvasAgentActionTools(base: frozen, mode: mode, automaticApproval: automaticApproval,
                                      onInteraction: onInteraction) { [weak self] call, input in
            guard let self else { throw AgentCanvasError.unavailable }
            return try await self.executeAction(call, input: input, conversationID: conversationID, isCurrent: isCurrent)
        }
    }

    @MainActor
    private func executeAction(_ call: AgentToolCall, input: JSONValue, conversationID: UUID,
                               isCurrent: @escaping @MainActor @Sendable () -> Bool) async throws -> JSONValue {
        func validateScope() throws {
            try Task.checkCancellation()
            guard isActive, isCurrent(), let canvas, !canvas.documentLoadFailed else {
                throw AgentCanvasError.staleTarget
            }
        }
        try validateScope()
        guard let canvas, let store else { throw AgentCanvasError.unavailable }
        guard await store.flushCanvasTextDocumentsAsync() else { throw AgentCanvasError.busy }
        try validateScope()
        func text(_ key: String) throws -> String {
            guard let value = input[key]?.stringValue else { throw AgentOperationError("缺少参数 \(key)") }
            return value
        }
        func point() throws -> CGPoint {
            guard let xValue = input["x"], let yValue = input["y"],
                  case .number(let x) = xValue, case .number(let y) = yValue,
                  x.isFinite, y.isFinite else { throw AgentOperationError("坐标无效。") }
            return CGPoint(x: x, y: y)
        }
        func targets(_ key: String = "node_ids") throws -> Set<String> {
            let values = input[key]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard !values.isEmpty, Set(values).count == values.count,
                  values.allSatisfy({ canvas.node(id: $0) != nil }) else {
                throw AgentOperationError("节点不存在或列表包含重复项，请重新读取画布。")
            }
            return Set(values)
        }
        func checkGraph() throws {
            guard try text("expected_graph_revision") == AgentCanvasSync.revision(canvas.gatewayDocument()) else {
                throw AgentCanvasError.conflict
            }
        }
        func checkNode() throws -> CanvasNode {
            guard let node = canvas.node(id: try text("node_id")),
                  try text("expected_revision") == liveRevision(node) else { throw AgentCanvasError.conflict }
            guard canvas.connectionPolicy.canConnect(nodeID: node.id), !canvas.isStoppingGeneration(node),
                  !isGenerating(node) else { throw AgentOperationError("节点被锁定或正在生成，请稍后重试。") }
            return node
        }
        func writable(_ ids: Set<String>) throws {
            guard !canvas.connectionPolicy.readOnly,
                  ids.allSatisfy({ canvas.connectionPolicy.canConnect(nodeID: $0) }) else {
                throw AgentOperationError("当前节点或画布不允许修改。")
            }
        }
        func receipt(_ summary: String, history: String? = nil, nodeIDs: [String] = []) throws -> JSONValue {
            if let history { operationHistoryIDs[conversationID, default: []].insert(history) }
            return ["ok": true, "project_id": .string(projectID), "summary": .string(summary),
                    "history_id": history.map(JSONValue.string) ?? .null,
                    "graph_revision": .string(AgentCanvasSync.revision(canvas.gatewayDocument())),
                    "nodes": .array(try nodeIDs.compactMap { canvas.node(id: $0) }.map { try liveValue($0) })]
        }
        if call.name == "canvas_current" {
            let offset = min(canvas.nodes.count, max(0, input["offset"]?.intValue ?? 0))
            let page = Array(canvas.nodes.dropFirst(offset).prefix(20))
            return ["ok": true, "project_id": .string(projectID),
                    "graph_revision": .string(AgentCanvasSync.revision(canvas.gatewayDocument())),
                    "node_count": .number(Double(canvas.nodes.count)),
                    "selected_node_ids": .array(canvas.selectedNodeIds.sorted().map(JSONValue.string)),
                    "nodes": .array(try page.map { try liveValue($0, bodyLimit: 4000) }),
                    "edges": try json(canvas.edges), "groups": try json(canvas.groups),
                    "next_offset": offset + page.count < canvas.nodes.count ? .number(Double(offset + page.count)) : .null,
                    "summary": "已读取当前画布"]
        }
        if call.name == "canvas_get_node" {
            guard let node = canvas.node(id: try text("node_id")) else { throw AgentCanvasError.staleTarget }
            return try liveValue(node)
        }
        if call.name == "canvas_list_models" {
            let models = try await CrateModelCatalogStore.shared.modelsForAgent()
            try validateScope()
            return ["ok": true, "models": .array(models.filter(\.enabled).map { model in
                ["id": .string(model.id), "name": .string(model.displayName),
                 "generation_types": .array(model.generationTypes.map(JSONValue.string)),
                 "ratios": .array(model.ratioOptions.map { .string($0.value) }),
                 "resolutions": .array(model.resolutionOptions.map { .string($0.value) }),
                 "parameters": model.manifest["parameters"] ?? .array([]),
                 "defaults": model.manifest["defaults"] ?? .object([:]),
                 "dimensions": model.manifest["dimensions"] ?? .object([:]),
                 "dimension_options": model.manifest["dimensionOptions"] ?? .array([]),
                 "inputs": model.manifest["inputs"] ?? .object([:]),
                 "references": model.manifest["references"] ?? .object([:]),
                 "rules": model.manifest["rules"] ?? .object([:])]
            }), "summary": "已读取实际可用模型，请使用精确ID"]
        }
        try writable([])
        if call.name == "canvas_create_node" {
            guard let kind = CanvasNodeKind(rawValue: try text("kind")),
                  [.text, .image, .video].contains(kind) else { throw AgentOperationError("不支持此节点类型。") }
            let parents = input["parent_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard Set(parents).count == parents.count,
                  parents.allSatisfy({ canvas.node(id: $0) != nil }) else { throw AgentCanvasError.staleTarget }
            try writable(Set(parents))
            let group = canvas.privateGroupId, name = canvas.activeProject.privateGroupName
            let occupied = canvas.occupiedSlots(inGroup: group).union(canvas.agentReservedPrivateSlots)
            let slot: Int? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let storage = SpecialSlotStorage.canvasPrivate
                    do {
                        _ = try storage.ensureReservedGroup(id: group, name: name)
                        let stashed = storage.stashedCanvasUndoSlots(in: group)
                        continuation.resume(returning: (1...SpecialSlotStorage.unfiledCapacity).first {
                            !occupied.contains($0) && !stashed.contains($0)
                                && storage.getOrUnknown($0, in: group)?.isEmpty == true
                        })
                    } catch { continuation.resume(returning: nil) }
                }
            }
            try validateScope()
            guard await store.flushCanvasTextDocumentsAsync() else { throw AgentCanvasError.busy }
            try validateScope()
            guard let slot, !canvas.occupiedSlots(inGroup: group).contains(slot),
                  !canvas.agentReservedPrivateSlots.contains(slot),
                  parents.allSatisfy({ canvas.node(id: $0) != nil }) else {
                throw AgentOperationError("没有可用槽位或画布已变化，请重新读取后重试。")
            }
            try writable(Set(parents))
            guard let source = store.canvasReadFullContent(groupId: group, slot: slot), source.isEmpty else {
                throw AgentCanvasError.conflict
            }
            let before = AgentSlotBody(source), after = AgentSlotBody(text: try text("text"))
            var bodyWritten = false
            let undoBody: () throws -> Void = { [weak store, weak canvas] in
                guard let store, canvas?.activeProjectId == self.projectID else { throw AgentCanvasError.staleTarget }
                if bodyWritten {
                    try store.exchangeCanvasAgentBody(groupId: group, slot: slot, expected: after, replacement: before)
                }
            }
            let redoBody: () throws -> Void = { [weak store, weak canvas] in
                guard let store, canvas?.activeProjectId == self.projectID else { throw AgentCanvasError.staleTarget }
                try store.exchangeCanvasAgentBody(groupId: group, slot: slot, expected: before, replacement: after)
            }
            var created: CanvasNode?
            let history = try canvas.performAgentEdit(detail: "新建\(kind.displayName)", undoBody: undoBody, redoBody: redoBody) {
                try store.exchangeCanvasAgentBody(groupId: group, slot: slot, expected: before, replacement: after)
                bodyWritten = true
                created = canvas.placeSlot(pageId: store.currentPageId, groupId: group, slot: slot,
                    name: kind.displayName, at: try point(),
                    kind: kind, parentNodeIds: parents, avoidOverlap: true).node
                if let created, kind.isMediaNode {
                    canvas.updateNode(id: created.id) { $0.mediaRole = .generation }
                }
                guard created != nil else { throw AgentCanvasError.writeFailed }
            }
            if let created { canvas.focusAgentNode(created.id) }
            return try receipt("已新建\(kind.displayName)节点", history: history, nodeIDs: [created!.id])
        }
        if call.name == "canvas_edit_node" {
            let node = try checkNode()
            guard let content = store.canvasReadFullContent(groupId: node.groupId, slot: node.slot) else {
                throw AgentCanvasError.unavailable
            }
            let before = AgentSlotBody(content), after = AgentSlotBody(text: try text("text"))
            guard before != after else { return try receipt("正文没有变化", nodeIDs: [node.id]) }
            var written = false
            let undo: () throws -> Void = { [weak store, weak canvas] in
                guard let store, canvas?.activeProjectId == self.projectID,
                      canvas?.node(id: node.id)?.createdAt == node.createdAt else { throw AgentCanvasError.staleTarget }
                if written {
                    try store.exchangeCanvasAgentBody(groupId: node.groupId, slot: node.slot,
                                                       expected: after, replacement: before)
                }
            }
            let redo: () throws -> Void = { [weak store, weak canvas] in
                guard let store, canvas?.activeProjectId == self.projectID,
                      canvas?.node(id: node.id)?.createdAt == node.createdAt else { throw AgentCanvasError.staleTarget }
                try store.exchangeCanvasAgentBody(groupId: node.groupId, slot: node.slot,
                                                   expected: before, replacement: after)
            }
            let history = try canvas.performAgentEdit(detail: "修改正文", undoBody: undo, redoBody: redo) {
                try store.exchangeCanvasAgentBody(groupId: node.groupId, slot: node.slot,
                                                   expected: before, replacement: after)
                written = true
            }
            return try receipt("已保存节点正文", history: history, nodeIDs: [node.id])
        }
        if call.name == "canvas_configure_node" || call.name == "canvas_move_node" {
            var node = try checkNode()
            if let modelID = input["model"]?.stringValue, node.generationProvider == .crate {
                let models = try await CrateModelCatalogStore.shared.modelsForAgent()
                try validateScope()
                node = try checkNode()
                let available = node.kind == .video ? CrateModelCatalog.videoModels(models)
                    : CrateModelCatalog.imageModels(models)
                guard available.contains(where: { $0.id == modelID }) else {
                    throw AgentOperationError("模型ID“\(modelID)”不可用，节点未修改。请调用canvas_list_models选择精确ID。")
                }
            }
            let history = try canvas.performAgentEdit(detail: call.name == "canvas_move_node" ? "移动节点" : "调整生成参数") {
                if call.name == "canvas_move_node" {
                    canvas.moveNode(id: node.id, to: try point())
                } else {
                    let duration: Int?? = input["duration"].map { $0 == .null ? nil : $0.intValue }
                    let audio: Bool?? = input["generate_audio"].map { $0 == .null ? nil : $0.boolValue }
                    canvas.updateNodeGeneration(id: node.id, model: input["model"]?.stringValue,
                        ratio: input["ratio"]?.stringValue, count: input["count"]?.intValue,
                        resolution: input["resolution"]?.stringValue, duration: duration, generateAudio: audio)
                }
            }
            return try receipt("已更新节点", history: history, nodeIDs: [node.id])
        }
        if call.name == "canvas_undo" || call.name == "canvas_redo" {
            let id = try text("history_id")
            guard operationHistoryIDs[conversationID]?.contains(id) == true,
                  (call.name == "canvas_undo" ? canvas.history.undoTarget?.id : canvas.history.redoTarget?.id) == id else {
                throw AgentOperationError("已有后续操作，请从画布历史依次撤销或重做。")
            }
            guard (call.name == "canvas_undo" ? canvas.undo() : canvas.redo()) != nil else {
                throw AgentOperationError(canvas.agentHistoryError ?? "操作冲突，未移动历史游标。")
            }
            guard canvas.flushSave() else { throw AgentCanvasError.writeFailed }
            return try receipt(call.name == "canvas_undo" ? "已撤销画布操作" : "已重做画布操作")
        }
        try checkGraph()
        if call.name == "canvas_layout_nodes" {
            let ids = try targets()
            try writable(ids)
            guard ids.allSatisfy({ id in
                guard let node = canvas.node(id: id) else { return false }
                return !isGenerating(node) && !canvas.isStoppingGeneration(node)
            }) else { throw AgentOperationError("节点正在生成或停止中，未排布。") }
            guard let layout = CanvasGroupLayoutType(rawValue: try text("layout")) else {
                throw AgentOperationError("不支持此布局方式。")
            }
            let history = try canvas.performAgentEdit(detail: layout == .grid ? "方格布局" : "横向布局") {
                try canvas.layoutAgentNodes(ids, layout: layout)
            }
            return try receipt(history == nil ? "节点布局没有变化" : "已排布节点并保存",
                               history: history, nodeIDs: ids.sorted())
        }
        if call.name == "canvas_generate" {
            let ids = try targets()
            try writable(ids)
            guard ids.allSatisfy({ canvas.node(id: $0)?.canGenerate == true }),
                  canvas.selectionGenerationTask == nil, let handler = canvas.agentGenerationHandler else {
                throw AgentOperationError("请打开画布并选择可生成的图片或视频节点；已有任务时不会重复提交。")
            }
            let previousTasks = Dictionary(canvas.nodes.map { ($0.id, $0.taskId) },
                                           uniquingKeysWith: { first, _ in first })
            guard let task = handler(ids) else { throw AgentOperationError("生成未提交，请检查节点参数和生成服务。") }
            await task.value
            try validateScope()
            let results = ids.union(ids.flatMap { canvas.adjacentLastResultIDs[$0] ?? [] })
            let values = try results.sorted().compactMap { canvas.node(id: $0) }.map { try liveValue($0) }
            let successful = results.allSatisfy {
                guard let node = canvas.node(id: $0), let taskID = node.taskId,
                      taskID != (previousTasks[node.id] ?? nil) else { return false }
                if case .succeeded = node.state { return true }; return false
            }
            return ["ok": .bool(successful), "project_id": .string(projectID), "nodes": .array(values),
                    "graph_revision": .string(AgentCanvasSync.revision(canvas.gatewayDocument())),
                    "summary": .string(successful ? "生成已完成，产物已保存" : "生成未全部完成，请查看节点实际状态")]
        }
        var changedIDs: Set<String> = []
        let history = try canvas.performAgentEdit(detail: "调整画布结构") {
            switch call.name {
            case "canvas_connect_nodes":
                let from = try text("from_node_id"), to = try text("to_node_id")
                try writable([from, to])
                guard canvas.node(id: from) != nil, canvas.node(id: to) != nil else { throw AgentCanvasError.staleTarget }
                let role = input["role"]?.stringValue.flatMap(CanvasEdgeRole.init(rawValue:)) ?? .auto
                guard canvas.connect(from: from, to: to, role: role) == nil else {
                    throw AgentOperationError("连线被拒绝：请检查重复连接、循环或端口用途。")
                }
                changedIDs = [from, to]
            case "canvas_disconnect_edge":
                let id = try text("edge_id")
                guard let edge = canvas.edges.first(where: { $0.id == id }) else { throw AgentCanvasError.staleTarget }
                try writable([edge.fromNodeId, edge.toNodeId])
                guard canvas.disconnect(edgeId: id) else { throw AgentOperationError("连线没有移除。") }
                changedIDs = [edge.fromNodeId, edge.toNodeId]
            case "canvas_group_nodes":
                let ids = try targets(); try writable(ids)
                guard canvas.groupNodes(ids, name: try text("name"), allowSingle: true) != nil else {
                    throw AgentOperationError("无法创建编组。")
                }
                changedIDs = ids
            case "canvas_delete_nodes":
                let ids = try targets(); try writable(ids)
                guard ids.allSatisfy({ canvas.node(id: $0).map { !isGenerating($0) } == true }) else {
                    throw AgentOperationError("节点正在生成，未删除。")
                }
                canvas.removeNodes(ids: ids)
            default: throw AgentOperationError("未实现的画布工具。")
            }
        }
        return try receipt("已保存画布结构", history: history, nodeIDs: changedIDs.sorted())
    }

    private func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    private func liveRevision(_ node: CanvasNode) throws -> String {
        guard let content = store?.canvasReadFullContent(groupId: node.groupId, slot: node.slot) else {
            throw AgentCanvasError.unavailable
        }
        let value: JSONValue = ["configuration": try json(node), "body_items": try json(content.items),
                               "html_source": content.htmlSource.map(JSONValue.string) ?? .null]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return CanvasWorkflowSnapshot.digest(try encoder.encode(value))
    }

    private func liveValue(_ node: CanvasNode, bodyLimit: Int = 96000) throws -> JSONValue {
        guard let store, let content = store.canvasReadFullContent(groupId: node.groupId, slot: node.slot) else {
            throw AgentCanvasError.unavailable
        }
        let body = content.plainText ?? ""
        return ["node_id": .string(node.id), "node_revision": .string(try liveRevision(node)),
                "configuration": try json(node), "body_text": .string(String(body.prefix(bodyLimit))),
                "body_truncated": .bool(body.count > bodyLimit),
                "attachment_names": .array(content.attachments.map { .string($0.name) })]
    }

    private func isGenerating(_ node: CanvasNode) -> Bool {
        switch node.state { case .queued, .running: return true; default: return false }
    }
}
