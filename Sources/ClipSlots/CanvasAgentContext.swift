import SwiftUI
import Combine
import ClipSlotsKit

@MainActor
final class CanvasAgentContext: ObservableObject {
    static let summarizePrompt = """
    总结这个项目可复用的创作方法。先分页读取全图目录和连线，再读取关键流程的正文、文本优化指令、合成 prompt、参数及已有真实运行记录。
    按适用场景、可变输入、稳定步骤、连线依据、审美约束、验收标准、已知限制组织结果。
    分开列出图事实、用户已确认的决策和待确认的推测；关键结论附来源节点 ID。
    列出读取范围和遗漏，不把媒体索引说成看过画面。只输出供我预览的 Skill 方法草稿。
    """
    struct Preview: Identifiable {
        let id = UUID()
        let target: AgentCanvasReference
        let before: AgentSlotBody
        let conversationID: UUID
        var text: String
        var appliedHistoryID: String?
    }
    @Published var preview: Preview?
    struct SkillDraft: Identifiable {
        let id = UUID()
        let snapshot: CanvasAgentSnapshot
        let turn: CanvasAgentTurn
        let skill: WorkflowSkill
    }
    @Published var skillDraft: SkillDraft?
    struct GraphPreview: Identifiable {
        var id: String { mutation.mutationID }
        let mutation: AgentCanvasMutation
        let conversationID: UUID
        let runID: String
        var plan: AgentCanvasSync.Plan
        var isApplied = false
    }
    @Published private(set) var pendingGraphPreviews: [GraphPreview] = []
    @Published var graphPreview: GraphPreview?
    @Published private(set) var error: String?
    @Published private(set) var status: String?
    private weak var canvas: CanvasStore?
    private weak var store: SlotStoreObservable?
    let projectID: String
    private var projectObserver: AnyCancellable?
    var onLeaveProject: (() -> Void)?

    init(canvas: CanvasStore, store: SlotStoreObservable, projectID: String) {
        self.canvas = canvas
        self.store = store
        self.projectID = projectID
        projectObserver = canvas.$activeProjectId.sink { [weak self] next in
            guard let self, next != self.projectID else { return }
            self.dismissPreview()
            self.skillDraft = nil
            self.onLeaveProject?()
        }
    }

    var isActive: Bool { canvas?.activeProjectId == projectID }

    func belongs(to canvas: CanvasStore) -> Bool { self.canvas === canvas }

    func captureTurn(supportsTools: Bool) throws -> CanvasAgentTurn {
        guard isActive, let canvas, let store else { throw AgentCanvasError.staleTarget }
        let runs = GenerationRunStore.shared.runs(project: projectID)
        let (graph, _) = CanvasWorkflowCapture.snapshot(canvas: canvas, store: store, runs: runs)
        let snapshot = CanvasAgentSnapshot(graph: graph, runs: runs)
        try CanvasAgentSnapshotStore().save(snapshot)
        return CanvasAgentTurn(snapshot: graph, supportsTools: supportsTools)
    }

    func reader(for turn: CanvasAgentTurn) throws -> CanvasAgentReadTools {
        guard isActive, turn.projectID == projectID else { throw AgentCanvasError.staleTarget }
        let snapshot = try CanvasAgentSnapshotStore().load(project: projectID, id: turn.snapshotID)
        guard snapshot.graph.graphRevision == turn.graphRevision else {
            throw AgentOperationError("快照内容与消息修订不匹配，请重新发送。")
        }
        return CanvasAgentReadTools(snapshot: snapshot)
    }

    func locate(nodeID: String, turn: CanvasAgentTurn) {
        do {
            let graph = try reader(for: turn).snapshot.graph
            guard let source = graph.nodes.first(where: { $0.id == nodeID }),
                  canvas?.nodes.contains(where: {
                      $0.id == nodeID && $0.createdAt == source.configuration.createdAt
                      && $0.groupId == source.configuration.groupId && $0.slot == source.configuration.slot
                  }) == true else { throw AgentCanvasError.staleTarget }
            canvas?.focusAgentNode(nodeID)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func prepareSkill(method: String, messageID: UUID, turn: CanvasAgentTurn, receipts: [CanvasReadReceipt]) {
        do {
            let snapshot = try reader(for: turn).snapshot
            let skill = try WorkflowSkill(snapshot: snapshot, method: method, messageID: messageID, receipts: receipts)
            skillDraft = SkillDraft(snapshot: snapshot, turn: turn, skill: skill)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func createWorkflowProject(name: String, instance: WorkflowSkill.Instance) async throws {
        guard isActive, let canvas else { throw AgentCanvasError.staleTarget }
        try await canvas.createWorkflowProject(name: name, instance: instance)
    }

    func reference(for node: CanvasNode) throws -> AgentCanvasReference {
        guard isActive, let store,
              let content = store.canvasReadFullContent(groupId: node.groupId, slot: node.slot) else {
            throw AgentCanvasError.unavailable
        }
        let label = store.canvasSlotLabel(groupId: node.groupId, slot: node.slot) ?? ""
        let index = store.specialStorage.loadIndex()
        let group = index.specialSlots.first { $0.id == node.groupId }
        let pageName = index.pages.first { $0.id == node.pageId }?.name
        let path = CanvasCardText.pathLabel(pageName: pageName, groupName: group?.name, slot: node.slot,
                                            isUnfiled: SpecialSlotStorage.isReservedGroupId(node.groupId))
        return AgentCanvasReference(projectID: projectID, nodeID: node.id, nodeCreatedAt: node.createdAt,
            groupID: node.groupId, slot: node.slot,
            title: label.isEmpty ? path : "\(label) · \(path)",
            text: content.plainText ?? "", attachmentNames: content.attachments.map(\.name),
            contentRevision: content.contentId)
    }

    func addSelection(to model: AgentChatModel) {
        do {
            guard isActive, let canvas else { throw AgentCanvasError.staleTarget }
            let selected = canvas.nodes.filter { canvas.selectedNodeIds.contains($0.id) }
            guard !selected.isEmpty else { error = "先在画布选择 1–3 个节点，再添加引用。"; return }
            let snapshots = try selected.map { try reference(for: $0) }
            let ids = Set(snapshots.map(\.id))
            let next = model.draftReferences.filter { !ids.contains($0.id) } + snapshots
            guard next.count <= 3 else { error = "每轮最多引用 3 个节点，请先移除部分引用。"; return }
            guard next.reduce(0, { $0 + $1.text.utf8.count }) <= 96_000 else {
                error = "所选正文超过 96 KB，请减少引用或缩短正文。"; return
            }
            model.draftReferences = next
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func validate(_ target: AgentCanvasReference) throws {
        guard isActive, target.projectID == projectID, let canvas,
              canvas.nodes.contains(where: {
                  $0.id == target.nodeID && $0.createdAt == target.nodeCreatedAt
                  && $0.groupId == target.groupID && $0.slot == target.slot
              }) else { throw AgentCanvasError.staleTarget }
    }

    func locate(_ target: AgentCanvasReference) {
        do {
            try validate(target)
            canvas?.focusAgentNode(target.nodeID)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func prepare(text: String, conversationID: UUID) {
        do {
            guard isActive, let canvas, let store else { throw AgentCanvasError.staleTarget }
            let selected = canvas.nodes.filter { canvas.selectedNodeIds.contains($0.id) }
            guard selected.count == 1, let node = selected.first else {
                error = "先在画布选中一个回填目标，再打开文字预览。"; return
            }
            let target = try reference(for: node)
            guard let content = store.canvasReadFullContent(groupId: node.groupId, slot: node.slot) else {
                throw AgentCanvasError.unavailable
            }
            preview = Preview(target: target, before: AgentSlotBody(content), conversationID: conversationID, text: text)
            error = nil
            status = nil
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func apply(conversationID: UUID) -> Bool {
        do {
            guard var preview, preview.appliedHistoryID == nil,
                  preview.conversationID == conversationID, let canvas, let store else { return false }
            try validate(preview.target)
            let after = AgentSlotBody(text: preview.text)
            guard after != preview.before else { status = "正文没有变化。"; return false }
            let target = preview.target, before = preview.before
            try store.exchangeCanvasAgentBody(groupId: target.groupID, slot: target.slot,
                                               expected: before, replacement: after)
            // Capture dependencies weakly without retaining this preview or its editor.
            let historyID = canvas.recordAgentBodyEdit(detail: target.title, undo: { [weak self] in
                guard let self, let store = self.store else { throw AgentCanvasError.unavailable }
                try self.validate(target)
                try store.exchangeCanvasAgentBody(groupId: target.groupID, slot: target.slot,
                                                    expected: after, replacement: before)
            }, redo: { [weak self] in
                guard let self, let store = self.store else { throw AgentCanvasError.unavailable }
                try self.validate(target)
                try store.exchangeCanvasAgentBody(groupId: target.groupID, slot: target.slot,
                                                    expected: before, replacement: after)
            })
            preview.appliedHistoryID = historyID
            self.preview = preview
            canvas.focusAgentNode(target.nodeID)
            status = "已应用到 \(target.title)"
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func undoApplied() {
        guard let id = preview?.appliedHistoryID, let canvas else { return }
        guard canvas.history.undoTarget?.id == id else {
            error = "已有后续画布操作或此结果已撤销，请从画布历史依次撤销。"; return
        }
        guard canvas.undo() != nil else { error = canvas.agentHistoryError; return }
        status = "已撤销，原正文与富文本格式已恢复。"
        error = nil
    }

    func prepareMutation(_ payload: JSONValue, conversationID: UUID, runID: String) {
        do {
            guard isActive, let canvas else { throw AgentCanvasError.staleTarget }
            let mutation = try JSONDecoder().decode(AgentCanvasMutation.self, from: JSONEncoder().encode(payload))
            let plan = try AgentCanvasSync.plan(mutation, current: canvas.gatewayDocument(),
                expectedProject: projectID, expectedConversation: conversationID.uuidString, expectedRun: runID)
            guard !plan.alreadyApplied else { return }
            let preview = GraphPreview(mutation: mutation, conversationID: conversationID, runID: runID, plan: plan)
            if !pendingGraphPreviews.contains(where: {
                $0.id == preview.id && $0.conversationID == conversationID && $0.runID == runID
            }) { pendingGraphPreviews.append(preview) }
            pendingGraphPreviews = Array(pendingGraphPreviews.suffix(100))
        } catch { self.error = error.localizedDescription }
    }

    func presentMutation(_ source: GraphPreview, conversationID: UUID) {
        guard source.conversationID == conversationID, isActive else { return }
        do {
            guard let canvas else { throw AgentCanvasError.unavailable }
            var source = source
            source.plan = try AgentCanvasSync.plan(source.mutation, current: canvas.gatewayDocument(),
                expectedProject: projectID, expectedConversation: conversationID.uuidString, expectedRun: source.runID)
            graphPreview = source
            status = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func applyMutation(conversationID: UUID) {
        do {
            guard var preview = graphPreview, preview.conversationID == conversationID,
                  !preview.isApplied, isActive, let canvas, let store else { return }
            let plan = try canvas.applyGatewayMutation(preview.mutation,
                conversationID: conversationID.uuidString, runID: preview.runID) { node in
                    store.canvasReadFullContent(groupId: node.groupId, slot: node.slot) != nil
                }
            preview.plan = plan
            preview.isApplied = true
            graphPreview = preview
            pendingGraphPreviews.removeAll {
                $0.id == preview.id && $0.conversationID == conversationID && $0.runID == preview.runID
            }
            status = plan.alreadyApplied ? "此变更已应用。" : "已同步画布，支持从画布历史撤销。"
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func dismissPreview() {
        preview = nil
        graphPreview = nil
        pendingGraphPreviews = []
        status = nil
        error = nil
    }
}
