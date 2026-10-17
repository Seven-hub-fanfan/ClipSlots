import Foundation

/// App-owned clipboard data. Capture freezes bytes as well as graph identities.
public final class CanvasStructureCapture {
    public let projectID: String
    public let graph: CanvasDocument
    public let roots: [String]
    public let stage: URL
    public let token = UUID().uuidString
    private let slots: [String: Int]
    private let storage: SlotStorage

    public init(projectID: String, document: CanvasDocument, roots: [String], root: URL,
                content: (CanvasNode) throws -> SlotContent) throws {
        let groups = Set(roots.filter { id in document.groups.contains { $0.id == id } })
            .reduce(into: Set<String>()) { $0.formUnion(CanvasGroupHierarchy.subtreeIDs($1, groups: document.groups)) }
        let pileIDs = Set(document.piles.filter {
            roots.contains($0.id) || $0.groupID.map(groups.contains) == true
        }.map(\.id))
        var ids = Set(roots).intersection(Set(document.nodes.map(\.id)))
        ids.formUnion(document.groups.filter { groups.contains($0.id) }.flatMap(\.nodeIDs))
        ids.formUnion(document.piles.filter { pileIDs.contains($0.id) }.flatMap(\.memberIDs))
        let nodes = document.nodes.filter { ids.contains($0.id) }
        guard !nodes.isEmpty, nodes.count <= SpecialSlotStorage.unfiledCapacity else {
            throw AgentOperationError("请选择要复制的节点、编组或堆叠；一次最多 60 个节点。")
        }
        self.projectID = projectID; self.roots = roots
        stage = root.appendingPathComponent("canvas/.structure-copy-\(UUID().uuidString)", isDirectory: true)
        storage = SlotStorage(slotsDir: stage)
        slots = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset + 1) })
        graph = CanvasDocument(nodes: nodes,
            edges: document.edges.filter { ids.contains($0.toNodeId) },
            groups: document.groups.filter { groups.contains($0.id) },
            piles: document.piles.filter { pileIDs.contains($0.id) })
        do {
            for node in nodes {
                let value = try content(node)
                guard value.attachments.allSatisfy({ attachment in
                    if attachment.type != .image && attachment.type != .file { return true }
                    if attachment.data?.isEmpty == false || attachment.url?.isEmpty == false { return true }
                    return [attachment.storagePath, attachment.path, attachment.originalPath].compactMap { $0 }
                        .contains { FileManager.default.fileExists(atPath: $0) }
                }) else { throw AgentOperationError("部分本地素材不可用，未创建不完整副本。") }
                guard storage.set(slots[node.id]!, content: value, replacingLabel: true) else {
                    throw AgentOperationError("复制正文或素材失败，原内容已保留。")
                }
            }
            storage.finishPendingWritesBeforeMovingDirectory()
        } catch {
            storage.finishPendingWritesBeforeMovingDirectory()
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }
    deinit {
        storage.finishPendingWritesBeforeMovingDirectory()
        try? FileManager.default.removeItem(at: stage)
    }
    public func content(_ id: String) throws -> SlotContent {
        guard let slot = slots[id], var value = storage.getOrUnknown(slot) else { throw AgentCanvasError.unavailable }
        value.label = storage.getLabel(slot)
        if value.hasManualThumbnail {
            guard let url = storage.manualThumbnailURL(slot: slot) else { throw AgentCanvasError.unavailable }
            value.pendingManualThumbnailData = try Data(contentsOf: url)
        }
        return value
    }
    public var bounds: CGRect {
        CanvasGeometry.bounds(of: graph.nodes.map(\.frame) + graph.groups.compactMap(\.containerFrame)
            + graph.piles.map { CanvasPileGeometry.frame($0, nodes: graph.nodes) })
    }
}

/// Contents first, graph last. The journal removes only this transaction's
/// uncommitted copies after an interruption; originals are never moved.
public final class CanvasStructureCopyTransaction {
    private let root: URL
    private let fm = FileManager.default
    public init(root: URL) { self.root = root }
    private struct Claim: Codable { let slot: Int; let contentID: String }
    private struct Journal: Codable {
        let projectID: String
        let beforeRevision: String
        let afterRevision: String
        let claims: [Claim]
    }
    private func docURL(_ project: String) -> URL {
        root.appendingPathComponent("canvas/projects/\(project)/canvas.json")
    }
    private func journalURL(_ project: String) -> URL {
        root.appendingPathComponent("canvas/projects/\(project)/structure-copy-journal.json")
    }
    private func groupURL(_ project: String) -> URL {
        root.appendingPathComponent("canvas/private_slots/\(CanvasProject(id: project, name: "").privateGroupId)")
    }
    private func validProject(_ id: String) -> Bool { id == CanvasProject.defaultId || UUID(uuidString: id) != nil }

    public func append(_ capture: CanvasStructureCapture, to before: CanvasDocument, projectID: String,
                       slots: [Int], delta: CGSize, checkpoint: ((Int) throws -> Void)? = nil) throws -> CanvasDocument {
        guard validProject(projectID), delta.width.isFinite, delta.height.isFinite,
              slots.count == capture.graph.nodes.count, Set(slots).count == slots.count,
              slots.allSatisfy({ (1...SpecialSlotStorage.unfiledCapacity).contains($0) }) else {
            throw AgentCanvasError.staleTarget
        }
        let privateGroup = CanvasProject(id: projectID, name: "").privateGroupId
        let mapping = Dictionary(uniqueKeysWithValues: zip(capture.graph.nodes, slots).map { ($0.0.id, "\(privateGroup)#\($0.1)") })
        let groupMap = Dictionary(uniqueKeysWithValues: capture.graph.groups.map { ($0.id, UUID().uuidString) })
        let pileMap = Dictionary(uniqueKeysWithValues: capture.graph.piles.map { ($0.id, "PILE-" + UUID().uuidString) })
        var next = before
        guard Set(before.nodes.map(\.id)).count == before.nodes.count,
              capture.graph.nodes.allSatisfy({ CanvasGroupHierarchy.validWorldFrame($0.frame) }),
              CanvasPile.normalized(capture.graph.piles, nodes: capture.graph.nodes) == capture.graph.piles else {
            throw AgentCanvasError.conflict
        }
        var contents: [SlotContent] = []
        var copies: [CanvasNode] = []
        for (node, slot) in zip(capture.graph.nodes, slots) {
            var copy = node, content = try capture.content(node.id)
            content.contentId = UUID().uuidString; content.updatedAt = Date().timeIntervalSince1970
            var attachments: [String: String] = [:]
            for i in content.attachments.indices {
                let old = content.attachments[i].id.uuidString, new = UUID()
                attachments[old] = new.uuidString
                content.attachments[i].id = new
            }
            copy.groupId = privateGroup; copy.pageId = SpecialSlotStorage.canvasPrivatePageId; copy.slot = slot
            copy.createdAt = Date(); copy.updatedAt = copy.createdAt
            copy.x += delta.width; copy.y += delta.height
            guard CanvasGroupHierarchy.validWorldFrame(copy.frame) else { throw AgentCanvasError.conflict }
            copy.state = .idle; copy.taskId = nil; copy.generationTask = nil
            copy.generationRawOutput = nil; copy.generationDiagnostic = nil
            copy.parentNodeId = node.parentNodeId.flatMap { mapping[$0] }
            copy.generationSourceID = node.generationSourceID.flatMap { mapping[$0] }
            copy.inputAttachmentIds = node.inputAttachmentIds.compactMap { attachments[$0] }
            copy.outputAttachmentIds = node.outputAttachmentIds.compactMap { attachments[$0] }
            copy.mediaLayoutAttachmentID = node.mediaLayoutAttachmentID.flatMap { attachments[$0] }
                ?? content.attachments.first?.id.uuidString
            copies.append(copy); contents.append(content)
        }
        let edgeTime = Date()
        let newEdges = capture.graph.edges.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            .enumerated().compactMap { index, edge -> CanvasEdge? in
            guard let to = mapping[edge.toNodeId] else { return nil }
            let from = mapping[edge.fromNodeId] ?? (capture.projectID == projectID
                && before.nodes.contains(where: { $0.id == edge.fromNodeId }) ? edge.fromNodeId : nil)
            guard let from else { return nil }
            var copy = edge
            copy.id = UUID().uuidString; copy.fromNodeId = from; copy.toNodeId = to
            copy.createdAt = edgeTime.addingTimeInterval(Double(index) / 1000)
            return copy
        }
        next.nodes += copies; next.edges += newEdges
        next.nodes = CanvasEdgeGraph.reconcilingDraftReferences(nodes: next.nodes, edges: next.edges)
        next.groups += capture.graph.groups.map { group in
            var copy = group
            copy.id = groupMap[group.id]!
            copy.nodeIDs = group.nodeIDs.compactMap { mapping[$0] }
            copy.parentGroupID = group.parentGroupID.flatMap { groupMap[$0] }
            copy.containerFrame = group.containerFrame?.offsetBy(dx: delta.width, dy: delta.height)
            copy.measuredLayoutSignature = nil; copy.workflowSkillID = nil
            return copy
        }
        next.piles += capture.graph.piles.map { pile in
            var copy = pile
            copy.id = pileMap[pile.id]!; copy.memberIDs = pile.memberIDs.compactMap { mapping[$0] }
            copy.groupID = pile.groupID.flatMap { groupMap[$0] }
            copy.x += delta.width; copy.y += delta.height
            return copy
        }
        guard CanvasPile.normalized(next.piles, nodes: next.nodes) == next.piles,
              next.piles.allSatisfy({ CanvasGroupHierarchy.validWorldFrame(CanvasPileGeometry.frame($0, nodes: next.nodes)) }) else {
            throw AgentCanvasError.conflict
        }
        try CanvasGroupHierarchy.validate(next.groups, nodeIDs: Set(next.nodes.map(\.id)))
        let stage = root.appendingPathComponent("canvas/.copy-\(UUID())")
        let storage = SlotStorage(slotsDir: stage)
        defer {
            storage.finishPendingWritesBeforeMovingDirectory()
            try? fm.removeItem(at: stage)
        }
        for i in slots.indices {
            guard storage.set(slots[i], content: contents[i], replacingLabel: true) else { throw AgentCanvasError.writeFailed }
            try Data(contents[i].contentId.utf8).write(
                to: stage.appendingPathComponent("\(slots[i])/.copy-owner"), options: .atomic)
        }
        // Diagnostic writes also acquire StorageLock. Drain before taking it.
        storage.finishPendingWritesBeforeMovingDirectory()
        return try StorageLock.shared.withLock {
            guard !StorageLock.shared.isDegraded else { throw AgentCanvasError.busy }
            try recover(projectID: projectID)
            let disk = try JSONDecoder().decode(CanvasDocument.self, from: Data(contentsOf: docURL(projectID)))
            guard AgentCanvasSync.revision(disk) == AgentCanvasSync.revision(before) else { throw AgentCanvasError.conflict }
            let target = groupURL(projectID)
            // A directory, even if visually empty, may contain labels or an unreadable attachment.
            guard slots.allSatisfy({ !fm.fileExists(atPath: target.appendingPathComponent(String($0)).path) }),
                  Set(slots).isDisjoint(with: Set(before.nodes.filter { $0.groupId == privateGroup }.map(\.slot))) else {
                throw AgentCanvasError.conflict
            }
            let journal = Journal(projectID: projectID, beforeRevision: AgentCanvasSync.revision(before),
                afterRevision: AgentCanvasSync.revision(next),
                claims: zip(slots, contents).map { Claim(slot: $0.0, contentID: $0.1.contentId) })
            do {
                try CanvasWorkflowSnapshot.jsonData(journal).write(to: journalURL(projectID), options: .atomic)
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                let privateStorage = SpecialSlotStorage(baseDirectory: root.appendingPathComponent("canvas/private_slots"),
                                                       role: .canvasPrivate)
                guard Set(slots).isDisjoint(with: privateStorage.stashedCanvasUndoSlots(in: privateGroup)) else {
                    throw AgentCanvasError.conflict
                }
                for i in slots.indices {
                    try fm.moveItem(at: stage.appendingPathComponent(String(slots[i])),
                                    to: target.appendingPathComponent(String(slots[i])))
                    try checkpoint?(i + 1)
                }
                try CanvasWorkflowSnapshot.jsonData(next).write(to: docURL(projectID), options: .atomic)
            } catch {
                try recover(projectID: projectID)
                throw error
            }
            try? fm.removeItem(at: journalURL(projectID))
            return next
        }
    }

    public func recover(projectID: String) throws {
        guard validProject(projectID) else { return }
        let file = journalURL(projectID)
        guard fm.fileExists(atPath: file.path) else { return }
        try StorageLock.shared.withLock {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
            guard journal.projectID == projectID else { throw AgentCanvasError.conflict }
            let disk = try JSONDecoder().decode(CanvasDocument.self, from: Data(contentsOf: docURL(projectID)))
            let revision = AgentCanvasSync.revision(disk)
            guard revision == journal.beforeRevision || revision == journal.afterRevision else { throw AgentCanvasError.conflict }
            if revision == journal.beforeRevision {
                for claim in journal.claims {
                    guard (1...SpecialSlotStorage.unfiledCapacity).contains(claim.slot) else { throw AgentCanvasError.conflict }
                    let dir = groupURL(projectID).appendingPathComponent(String(claim.slot))
                    guard fm.fileExists(atPath: dir.path) else { continue }
                    let owner = try String(contentsOf: dir.appendingPathComponent(".copy-owner"))
                    guard owner == claim.contentID else { throw AgentCanvasError.conflict }
                    try fm.removeItem(at: dir)
                }
            }
            try fm.removeItem(at: file)
        }
    }
}
