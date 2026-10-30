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
        var readbackRequest: AgentCanvasReadbackRequest?
    }
    @Published private(set) var pendingGraphPreviews: [GraphPreview] = []
    @Published var graphPreview: GraphPreview?
    @Published private(set) var error: String?
    @Published private(set) var status: String?
    @Published private(set) var isLoadingReferences = false
    @Published private(set) var referenceCaptureErrors: [String: String] = [:]
    private(set) weak var canvas: CanvasStore?
    private(set) weak var store: SlotStoreObservable?
    var operationHistoryIDs: [UUID: Set<String>] = [:]
    let projectID: String
    private(set) var activationEpoch = UUID()
    private var projectObserver: AnyCancellable?
    private var selectionObserver: AnyCancellable?
    private var referenceTask: Task<Void, Never>?
    private var referenceTicket = UUID()
    private var readbackSource: (any AgentCanvasSnapshotReading)?
    private var readbackBatcher: AgentCanvasReadbackBatcher?
    private var readbackEpoch = UUID()
    private var readbackTasks: [String: (request: AgentCanvasReadbackRequest, task: Task<Void, Never>)] = [:]
    private struct ReadbackObservation {
        let before: CanvasDocument
        let watchesAll: Bool
        let nodeIDs: Set<String>
        let edgeIDs: Set<String>
        let nodes: [String: CanvasNode]
        let edges: [String: CanvasEdge]
        var changedNodes = Set<String>()
        var changedEdges = Set<String>()
        var deletedNodes = Set<String>()
    }
    private var readbackObservations: [UUID: ReadbackObservation] = [:]
    private var readbackNodeObserver: AnyCancellable?
    private var readbackEdgeObserver: AnyCancellable?
    private var lastReadbackNodeIDs = Set<String>()
    var onLeaveProject: (() -> Void)?

    init(canvas: CanvasStore, store: SlotStoreObservable?, projectID: String,
         readbackSource: (any AgentCanvasSnapshotReading)? = nil) {
        self.canvas = canvas
        self.store = store
        self.projectID = projectID
        self.readbackSource = readbackSource
        readbackNodeObserver = canvas.nodeEditEvents.sink { [weak self] nodes in
            guard let self, !self.readbackObservations.isEmpty else { return }
            let ids = Set(nodes.map(\.id))
            let watched = self.readbackObservations.values.reduce(into: Set<String>()) { $0.formUnion($1.nodeIDs) }
            let watchesAll = self.readbackObservations.values.contains(where: \.watchesAll)
            let live = Dictionary(nodes.filter { watchesAll || watched.contains($0.id) }.map { ($0.id, $0) },
                                  uniquingKeysWith: { _, new in new })
            let deleted = self.lastReadbackNodeIDs.subtracting(ids)
            self.lastReadbackNodeIDs = ids
            for id in Array(self.readbackObservations.keys) {
                guard var observation = self.readbackObservations[id] else { continue }
                let observedIDs = observation.watchesAll ? ids.union(observation.nodeIDs) : observation.nodeIDs
                for nodeID in observedIDs where live[nodeID] != observation.nodes[nodeID] {
                    observation.changedNodes.insert(nodeID)
                }
                observation.deletedNodes.formUnion(deleted)
                self.readbackObservations[id] = observation
            }
        }
        readbackEdgeObserver = canvas.edgeEditEvents.sink { [weak self] edges in
            guard let self, !self.readbackObservations.isEmpty else { return }
            let watched = self.readbackObservations.values.reduce(into: Set<String>()) { $0.formUnion($1.edgeIDs) }
            let watchesAll = self.readbackObservations.values.contains(where: \.watchesAll)
            let live = Dictionary(edges.filter { watchesAll || watched.contains($0.id) }.map { ($0.id, $0) },
                                  uniquingKeysWith: { _, new in new })
            for id in Array(self.readbackObservations.keys) {
                guard var observation = self.readbackObservations[id] else { continue }
                let observedIDs = observation.watchesAll ? Set(live.keys).union(observation.edgeIDs) : observation.edgeIDs
                for edgeID in observedIDs where live[edgeID] != observation.edges[edgeID] {
                    observation.changedEdges.insert(edgeID)
                }
                self.readbackObservations[id] = observation
            }
        }
        projectObserver = canvas.$activeProjectId.sink { [weak self] next in
            guard let self, next != self.projectID else { return }
            self.activationEpoch = UUID()
            self.dismissPreview()
            self.skillDraft = nil
            self.onLeaveProject?()
        }
    }

    var isActive: Bool { canvas?.activeProjectId == projectID }

    func belongs(to canvas: CanvasStore) -> Bool { self.canvas === canvas }

    func observeSelection(to model: AgentChatModel) {
        selectionObserver?.cancel()
        guard let canvas else { return }
        selectionObserver = canvas.selectedNodesDidChange.prepend(canvas.selectedNodeIds).removeDuplicates()
            .map { [weak model] ids in (ids, model?.selectedConversationID) }
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self, weak model] event in
                let (ids, conversation) = event
                guard let self, let model, self.isActive, !ids.isEmpty,
                      model.selectedConversationID == conversation else { return }
                self.addSelection(to: model)
            }
    }

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
            contentRevision: content.contentId, mediaKind: Self.mediaKind(node, content: content))
    }

    private static func mediaKind(_ node: CanvasNode, content: SlotContent) -> AgentCanvasReference.MediaKind {
        let attachment = content.attachments.first
        let suffix = attachment.map { URL(fileURLWithPath: $0.name).pathExtension.lowercased() } ?? ""
        if ["mp3", "wav", "m4a", "aac", "aiff", "ogg", "flac"].contains(suffix) { return .audio }
        if node.kind == .video || ["mp4", "mov", "m4v", "webm"].contains(suffix) { return .video }
        if node.kind == .image || attachment?.canvasIsImageLike == true { return .image }
        return attachment == nil ? .text : .file
    }

    func addSelection(to model: AgentChatModel) {
        do {
            guard isActive, let canvas else { throw AgentCanvasError.staleTarget }
            let selected = canvas.nodes.filter { canvas.selectedNodeIds.contains($0.id) }
            guard !selected.isEmpty else { error = "先在画布选择节点。"; return }
            guard selected.count <= AgentCanvasReference.maxReferences else {
                error = "每轮最多引用 \(AgentCanvasReference.maxReferences) 个节点，请缩小选择范围。"; return
            }
            let snapshots = try selected.map { try reference(for: $0) }
            let existing = Dictionary(model.draftReferences.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            let refreshed = snapshots.map { snapshot in
                if let old = existing[snapshot.id], old.contentRevision == snapshot.contentRevision,
                   old.mediaKind == snapshot.mediaKind, old.title == snapshot.title { return old }
                return snapshot
            }
            let ids = Set(refreshed.map(\.id))
            let next = model.draftReferences.filter { !ids.contains($0.id) } + refreshed
            guard next.count <= AgentCanvasReference.maxReferences else {
                error = "每轮最多引用 \(AgentCanvasReference.maxReferences) 个节点，请先移除部分引用。"; return
            }
            guard next.reduce(0, { $0 + $1.text.utf8.count }) <= AgentCanvasReference.maxTextBytes else {
                error = "所选正文超过 96 KB，请减少引用或缩短正文。"; return
            }
            model.draftReferences = next
            error = nil
            captureReferenceImages(to: model)
        } catch { self.error = error.localizedDescription }
    }

    func captureReferenceImages(to model: AgentChatModel) {
        guard isActive, let store else { return }
        referenceTask?.cancel()
        let ticket = UUID()
        referenceTicket = ticket
        let references = model.draftReferences
        let conversation = model.selectedConversationID
        isLoadingReferences = true
        referenceCaptureErrors = [:]
        do {
            let sources = try references.map { reference -> SlotContent.SlotAttachment? in
                try validate(reference)
                guard let content = store.canvasReadFullContent(groupId: reference.groupID, slot: reference.slot),
                      content.contentId == reference.contentRevision else { throw AgentCanvasError.conflict }
                return content.attachments.first
            }
            referenceTask = Task { [weak self, weak model] in
                guard let self, let model else { return }
                defer {
                    if referenceTicket == ticket { isLoadingReferences = false; referenceTask = nil }
                }
                for (reference, source) in zip(references, sources) {
                    guard !Task.isCancelled, isActive, referenceTicket == ticket,
                          model.selectedConversationID == conversation else { return }
                    guard let source else { continue }
                    do {
                        let image = await CanvasAttachmentThumbnails.load(source, maxPixel: 1280)
                        try Task.checkCancellation()
                        guard referenceTicket == ticket, model.selectedConversationID == conversation else { return }
                        try validate(reference)
                        guard store.canvasReadFullContent(groupId: reference.groupID, slot: reference.slot)?.contentId
                                == reference.contentRevision else { throw AgentCanvasError.conflict }
                        guard let index = model.draftReferences.firstIndex(where: {
                            $0.id == reference.id && $0.contentRevision == reference.contentRevision
                        }) else { continue }
                        let bitmap = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                            .map(NSBitmapImageRep.init(cgImage:))
                        let data = bitmap?.representation(using: .jpeg, properties: [.compressionFactor: 0.65])
                        var images: [AgentAttachment]?
                        if reference.mediaKind == .image {
                            guard let data else { throw AgentAttachmentImport.ImportError.unavailable }
                            images = [try AgentAttachmentImport.captureImage(data, name: source.name)]
                        }
                        let replacement = AgentCanvasReference(projectID: reference.projectID, nodeID: reference.nodeID,
                            nodeCreatedAt: reference.nodeCreatedAt, groupID: reference.groupID, slot: reference.slot,
                            title: reference.title, text: reference.text, attachmentNames: reference.attachmentNames,
                            contentRevision: reference.contentRevision, images: images, mediaKind: reference.mediaKind,
                            previewImage: data)
                        var proposed = model.draftReferences
                        proposed[index] = replacement
                        try AgentAttachmentImport.validate(model.draftAttachments + proposed.flatMap { $0.images ?? [] })
                        model.draftReferences = proposed
                    } catch is CancellationError { return }
                    catch {
                        guard referenceTicket == ticket, model.selectedConversationID == conversation else { return }
                        referenceCaptureErrors[reference.id] = error.localizedDescription
                    }
                }
            }
        } catch { self.error = error.localizedDescription; isLoadingReferences = false }
    }

    private func validate(_ target: AgentCanvasReference) throws {
        guard isActive, target.projectID == projectID, let canvas,
              canvas.nodes.contains(where: {
                  $0.id == target.nodeID && $0.createdAt == target.nodeCreatedAt
                  && $0.groupId == target.groupID && $0.slot == target.slot
              }) else { throw AgentCanvasError.staleTarget }
    }

    func validateReferences(_ references: [AgentCanvasReference]) throws {
        for reference in references { try validate(reference) }
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

    private func beginReadbackObservation(_ request: AgentCanvasReadbackRequest, id: UUID) throws {
        guard isActive, let canvas, readbackObservations.count < 128 else { throw AgentGatewayError.busy }
        let before = canvas.gatewayDocument()
        let nodeIDs = Set(request.isFullSnapshot ? before.nodes.map(\.id) : request.nodeIDs)
        let edgeIDs = Set(request.isFullSnapshot ? before.edges.map(\.id) : request.edgeIDs)
        if readbackObservations.isEmpty { lastReadbackNodeIDs = Set(before.nodes.map(\.id)) }
        readbackObservations[id] = .init(before: before, watchesAll: request.isFullSnapshot,
            nodeIDs: nodeIDs, edgeIDs: edgeIDs,
            nodes: Dictionary(before.nodes.filter { nodeIDs.contains($0.id) }.map { ($0.id, $0) },
                              uniquingKeysWith: { _, new in new }),
            edges: Dictionary(before.edges.filter { edgeIDs.contains($0.id) }.map { ($0.id, $0) },
                              uniquingKeysWith: { _, new in new }))
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
            _ = try submitMutation(payload, conversationID: conversationID, runID: runID)
        } catch { self.error = error.localizedDescription }
    }

    /// A host must supply the authority explicitly. Missing configuration
    /// preserves the durable request; it never guesses a URL or an empty graph.
    func configureReadbackSource(_ source: (any AgentCanvasSnapshotReading)?) {
        cancelReadbacks()
        readbackSource = source
    }

    func cancelReadbacks() {
        readbackEpoch = UUID()
        readbackTasks.values.forEach { $0.task.cancel() }; readbackTasks.removeAll()
        readbackObservations.removeAll()
        let previous = readbackBatcher
        readbackBatcher = nil
        Task { await previous?.cancelAll() }
    }

    func prepareReadback(_ request: AgentCanvasReadbackRequest,
                         isCurrent: @escaping @MainActor () -> Bool) {
        let key = request.coordinationKey
        if let existing = readbackTasks[key] {
            if existing.request != request { error = "同一读回标识的内容已改变。" }
            return
        }
        guard readbackTasks.count < 128 else {
            error = "画布读回队列已满，原请求已保留，请稍后重试。"; return
        }
        let epoch = readbackEpoch
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if readbackEpoch == epoch { readbackTasks.removeValue(forKey: key) } }
            do { _ = try await submitReadback(request, isCurrent: isCurrent) }
            catch {
                guard readbackEpoch == epoch, isCurrent(), !(error is CancellationError) else { return }
                self.error = (error as? AgentGatewayError)?.localizedDescription
                    ?? "权威画布快照尚不可用，原变更已保留，可在配置读回源后重试。"
            }
        }
        readbackTasks[key] = (request, task)
    }

    @discardableResult
    func submitReadback(_ request: AgentCanvasReadbackRequest,
                        isCurrent: @escaping @MainActor () -> Bool) async throws -> String {
        try request.validate()
        guard isActive, isCurrent(), request.projectID == projectID,
              let conversation = UUID(uuidString: request.conversationID), let canvas else {
            throw AgentGatewayError.originMismatch
        }
        let receipt = CanvasWorkflowSnapshot.digest(Data(
            "\(request.conversationID)\u{0}\(request.runID)\u{0}\(request.mutationID)".utf8))
        if canvas.gatewayDocument().appliedAgentMutationIDs.contains(receipt) { return "applied" }
        if let existing = pendingGraphPreviews.first(where: {
            $0.id == request.mutationID && $0.conversationID == conversation && $0.runID == request.runID
        }) {
            guard existing.readbackRequest == request else { throw AgentGatewayError.malformedPayload }
            return "pending"
        }
        guard let readbackSource else { throw AgentCanvasError.unavailable }
        if readbackBatcher == nil {
            readbackBatcher = AgentCanvasReadbackBatcher(reader: readbackSource, serialGate: .shared)
        }
        guard let batcher = readbackBatcher else { throw AgentCanvasError.unavailable }
        let epoch = readbackEpoch, observationID = UUID()
        if request.isFullSnapshot {
            // Include nested tool callbacks already scheduled by the host.
            // Their failures do not prevent a subsequent authoritative query.
            let toolReads = readbackTasks.values.filter { !$0.request.isFullSnapshot }.map(\.task)
            for task in toolReads { await task.value }
            try Task.checkCancellation()
            guard epoch == readbackEpoch, isActive, isCurrent() else { throw CancellationError() }
        } else {
            try beginReadbackObservation(request, id: observationID)
        }
        defer { readbackObservations.removeValue(forKey: observationID) }
        let snapshot = try await batcher.read(request) { [weak self] in
            guard request.isFullSnapshot else { return }
            try await MainActor.run {
                guard let self, self.readbackEpoch == epoch, self.isActive, isCurrent() else {
                    throw CancellationError()
                }
                try self.beginReadbackObservation(request, id: observationID)
            }
        }
        try Task.checkCancellation()
        guard epoch == readbackEpoch, isActive, isCurrent() else { throw CancellationError() }
        guard let observation = readbackObservations[observationID] else { throw CancellationError() }
        let current = canvas.gatewayDocument()
        let result = try AgentCanvasReadbackSync.plan(request: request, snapshot: snapshot,
            before: observation.before, current: current, activeProject: projectID,
            conversation: request.conversationID, run: request.runID,
            locallyChangedNodeIDs: observation.changedNodes, locallyChangedEdgeIDs: observation.changedEdges,
            locallyDeletedNodeIDs: observation.deletedNodes)
        guard !result.changedNodeIDs.isEmpty || !result.changedEdgeIDs.isEmpty else {
            return result.deletedNodeIDs.isEmpty ? "no_change" : "deleted_during_readback"
        }
        let changedNodes = Set(result.changedNodeIDs), changedEdges = Set(result.changedEdgeIDs)
        guard changedNodes.count <= 1000, changedEdges.count <= 2000 else {
            throw AgentGatewayError.requestTooLarge
        }
        let mutation = AgentCanvasMutation(projectID: projectID, conversationID: request.conversationID,
            runID: request.runID, mutationID: request.mutationID,
            changes: result.document.nodes.filter { changedNodes.contains($0.id) }.map { node in
                .init(before: current.nodes.first { $0.id == node.id }, after: node)
            },
            addedEdges: result.document.edges.filter { changedEdges.contains($0.id) },
            removedEdges: current.edges.filter { changedEdges.contains($0.id) })
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(mutation))
        return try submitMutation(value, conversationID: conversation, runID: request.runID, readbackRequest: request)
    }

    func submitMutation(_ payload: JSONValue, conversationID: UUID, runID: String,
                        readbackRequest: AgentCanvasReadbackRequest? = nil) throws -> String {
        guard isActive, let canvas else { throw AgentCanvasError.staleTarget }
        let mutation = try JSONDecoder().decode(AgentCanvasMutation.self, from: JSONEncoder().encode(payload))
        let plan = try AgentCanvasSync.plan(mutation, current: canvas.gatewayDocument(),
            expectedProject: projectID, expectedConversation: conversationID.uuidString, expectedRun: runID)
        if plan.alreadyApplied { return "applied" }
        if let existing = pendingGraphPreviews.first(where: {
            $0.id == mutation.mutationID && $0.conversationID == conversationID && $0.runID == runID
        }) {
            let old = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(existing.mutation))
            let new = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(mutation))
            guard old == new else { throw AgentOperationError("同一变更标识的内容已改变。") }
            return "pending"
        }
        let preview = GraphPreview(mutation: mutation, conversationID: conversationID, runID: runID,
                                   plan: plan, readbackRequest: readbackRequest)
        if !pendingGraphPreviews.contains(where: {
            $0.id == preview.id && $0.conversationID == conversationID && $0.runID == runID
        }) {
            guard pendingGraphPreviews.count < 100 else {
                throw AgentOperationError("待确认的画布预览已满，请先处理现有变更。")
            }
            pendingGraphPreviews.append(preview)
        }
        return "pending"
    }

    func mutationStatus(_ payload: JSONValue, conversationID: UUID, runID: String) throws -> String {
        guard isActive, let canvas else { throw AgentCanvasError.staleTarget }
        let mutation = try JSONDecoder().decode(AgentCanvasMutation.self, from: JSONEncoder().encode(payload))
        // The committed receipt survives undo, so replay can never silently reapply it.
        let key = CanvasWorkflowSnapshot.digest(Data(
            "\(conversationID.uuidString)\u{0}\(runID)\u{0}\(mutation.mutationID)".utf8))
        if canvas.gatewayDocument().appliedAgentMutationIDs.contains(key) { return "applied" }
        return pendingGraphPreviews.contains {
            $0.id == mutation.mutationID && $0.conversationID == conversationID && $0.runID == runID
        } ? "pending" : "dismissed"
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
        cancelReadbacks()
        preview = nil
        graphPreview = nil
        pendingGraphPreviews = []
        status = nil
        error = nil
    }

    func cancelReferenceCapture() {
        referenceTask?.cancel()
        referenceTicket = UUID()
        isLoadingReferences = false
        referenceCaptureErrors = [:]
    }

    func pendingExternalConnectionCancelled(runID: String) {
        pendingGraphPreviews.removeAll { $0.runID == runID }
        if graphPreview?.runID == runID, graphPreview?.isApplied == false { graphPreview = nil }
    }
}
