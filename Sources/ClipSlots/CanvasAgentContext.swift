import SwiftUI
import Combine
import ClipSlotsKit

@MainActor
final class CanvasAgentContext: ObservableObject {
    struct Preview: Identifiable {
        let id = UUID()
        let target: AgentCanvasReference
        let before: AgentSlotBody
        let conversationID: UUID
        var text: String
        var appliedHistoryID: String?
    }
    @Published var preview: Preview?
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
            self.onLeaveProject?()
        }
    }

    var isActive: Bool { canvas?.activeProjectId == projectID }

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

    func dismissPreview() {
        preview = nil
        status = nil
        error = nil
    }
}
