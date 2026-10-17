import Foundation
import UniformTypeIdentifiers
import Darwin

/// Creates an entirely new private project. No writes target existing node identities.
/// The project index is the final visibility commit; stage directories are never discovered.
public final class WorkflowProjectTransaction {
    public struct Prepared {
        public let project: CanvasProject
        public let document: CanvasDocument
        fileprivate let stage: URL
        fileprivate let group: URL
    }
    public struct Receipt {
        public let project: CanvasProject
        public let document: CanvasDocument
        public let contentFingerprint: String
    }
    private let root: URL
    private let fm = FileManager.default
    public init(root: URL = ClipSlotsPaths.dataRoot) { self.root = root }
    private var canvas: URL { root.appendingPathComponent("canvas", isDirectory: true) }
    private var privateRoot: URL { canvas.appendingPathComponent("private_slots", isDirectory: true) }
    private var indexURL: URL { canvas.appendingPathComponent("projects.json") }
    private func projectDir(_ project: CanvasProject) -> URL {
        canvas.appendingPathComponent("projects/\(project.id)", isDirectory: true)
    }
    private func liveGroup(_ project: CanvasProject) -> URL { privateRoot.appendingPathComponent(project.privateGroupId) }
    private func stashGroup(_ project: CanvasProject) -> URL { projectDir(project).appendingPathComponent(".workflow-content") }
    private func journalURL(_ project: CanvasProject) -> URL { projectDir(project).appendingPathComponent(".workflow-exchange.json") }

    public func prepare(name: String, instance: WorkflowSkill.Instance,
                        checkpoint: ((Int) throws -> Void)? = nil) throws -> Prepared {
        guard !instance.nodes.isEmpty, instance.nodes.count <= SpecialSlotStorage.unfiledCapacity else {
            throw AgentOperationError("单个新项目最多容纳 \(SpecialSlotStorage.unfiledCapacity) 个私有节点，请保存较小的流程。")
        }
        guard Set(instance.nodes.map(\.id)).count == instance.nodes.count else { throw AgentOperationError("节点身份重复。") }
        let project = CanvasProject(name: CanvasProject.sanitizedName(name))
        let stage = canvas.appendingPathComponent(".workflow-stage-\(project.id)", isDirectory: true)
        let group = stage.appendingPathComponent("contents", isDirectory: true)
        try fm.createDirectory(at: group, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let storage = SlotStorage(slotsDir: group)
            defer { storage.finishPendingWritesBeforeMovingDirectory() }
            var nodes: [CanvasNode] = []
            var mapping: [String: String] = [:]
            for (index, item) in instance.nodes.enumerated() {
                try Task.checkCancellation()
                var node = item.configuration
                node.groupId = project.privateGroupId; node.pageId = SpecialSlotStorage.canvasPrivatePageId; node.slot = index + 1
                node.createdAt = Date().addingTimeInterval(Double(index) / 1000); node.updatedAt = node.createdAt
                node.state = .idle; node.taskId = nil; node.seed = nil; node.parentNodeId = nil
                node.generationTask = nil; node.generationRawOutput = nil
                node.generationDiagnostic = nil
                node.inputAttachmentIds = []; node.outputAttachmentIds = []; node.mediaLayoutAttachmentID = nil
                var content = SlotContent(text: item.body)
                for path in instance.media[item.id] ?? [] {
                    let url = URL(fileURLWithPath: path)
                    let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey, .fileSizeKey])
                    guard properties.isRegularFile == true,
                          let type = properties.contentType, type.conforms(to: .image) || type.conforms(to: .movie) else {
                        throw AgentOperationError("素材不可用或不是图片/视频：\(url.lastPathComponent)")
                    }
                    guard node.isMediaSource && node.kind == .video ? type.conforms(to: .movie) : type.conforms(to: .image) else {
                        throw AgentOperationError("素材类型与节点不匹配：\(url.lastPathComponent)")
                    }
                    let attachment = SlotContent.SlotAttachment(name: url.lastPathComponent,
                        type: type.conforms(to: .image) ? .image : .file, path: path)
                    content.attachments.append(attachment)
                }
                if !node.isMediaSource { node.inputAttachmentIds = content.attachments.map { $0.id.uuidString } }
                // Preserve the template's layout on first display. The native probe upgrades this
                // attachment-ID marker to a version marker without resizing/repositioning the node.
                if node.isMediaSource { node.mediaLayoutAttachmentID = content.attachments.first?.id.uuidString }
                guard storage.set(node.slot, content: content) else { throw AgentOperationError("节点内容写入失败，未创建项目。") }
                // The ordinary label setter swallows IO errors; transaction labels must fail together.
                try Data(item.title.utf8).write(to: group.appendingPathComponent("\(node.slot)/label.txt"), options: .atomic)
                let restored = SlotStorage(slotsDir: group).get(node.slot)
                guard restored.plainText == content.plainText, restored.attachments.count == content.attachments.count,
                      restored.attachments.allSatisfy({ $0.storagePath.map { fm.fileExists(atPath: $0) } == true }) else {
                    throw AgentOperationError("节点或素材写入校验失败，未创建项目。")
                }
                mapping[item.id] = node.id; nodes.append(node)
                try checkpoint?(index + 1)
            }
            for index in nodes.indices {
                nodes[index].generationSourceID = instance.nodes[index].configuration.generationSourceID
                    .flatMap { source in
                        instance.nodes.first(where: { $0.configuration.id == source }).flatMap { mapping[$0.id] }
                    }
            }
            let timestamp = Date()
            let edges = try instance.edges.sorted { $0.order < $1.order }.enumerated().map { index, edge -> CanvasEdge in
                guard let from = mapping[edge.from], let to = mapping[edge.to] else { throw AgentOperationError("连线端点缺失。") }
                // Unique timestamps retain semantic ordering even after the new random IDs sort differently.
                return CanvasEdge(fromNodeId: from, toNodeId: to, role: edge.role,
                    createdAt: timestamp.addingTimeInterval(Double(index) / 1000))
            }
            let document = CanvasDocument(nodes: nodes, edges: edges)
            let docDir = stage.appendingPathComponent("project", isDirectory: true)
            try fm.createDirectory(at: docDir, withIntermediateDirectories: true)
            try CanvasWorkflowSnapshot.jsonData(document).write(to: docDir.appendingPathComponent("canvas.json"), options: .atomic)
            return Prepared(project: project, document: document, stage: stage, group: group)
        } catch { try? fm.removeItem(at: stage); throw error }
    }
    public func discard(_ prepared: Prepared) { try? fm.removeItem(at: prepared.stage) }

    public func commit(_ prepared: Prepared, expected: CanvasProjectIndex,
                       privateStorage: SpecialSlotStorage,
                       checkpoint: (() throws -> Void)? = nil) throws -> Receipt {
        defer { discard(prepared) }
        return try StorageLock.shared.withLock {
            guard !StorageLock.shared.isDegraded else { throw AgentCanvasError.busy }
            let current = try JSONDecoder().decode(CanvasProjectIndex.self, from: Data(contentsOf: indexURL))
            guard current == expected else { throw AgentOperationError("项目列表已变化，请重新预览后创建。") }
            let project = prepared.project, targetGroup = liveGroup(project), targetDoc = projectDir(project)
            guard !fm.fileExists(atPath: targetGroup.path), !fm.fileExists(atPath: targetDoc.path) else {
                throw AgentOperationError("新项目身份冲突，请重试。")
            }
            do {
                try fm.createDirectory(at: privateRoot, withIntermediateDirectories: true)
                try fm.moveItem(at: prepared.group, to: targetGroup)
                _ = try privateStorage.ensureReservedGroup(id: project.privateGroupId, name: project.privateGroupName)
                try fm.createDirectory(at: targetDoc.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: prepared.stage.appendingPathComponent("project"), to: targetDoc)
                let fingerprint = try Self.fingerprint(targetGroup)
                try checkpoint?()
                let next = CanvasProjectIndex(projects: current.projects + [project], activeProjectId: project.id)
                try CanvasWorkflowSnapshot.jsonData(next).write(to: indexURL, options: .atomic)
                // Nothing fallible follows the visibility commit.
                return Receipt(project: project, document: prepared.document, contentFingerprint: fingerprint)
            } catch {
                // Remove the discoverable document before retiring its backing group.
                if !fm.fileExists(atPath: targetDoc.path) || (try? fm.removeItem(at: targetDoc)) != nil {
                    try? privateStorage.deleteCanvasPrivateGroup(id: project.privateGroupId)
                }
                throw error
            }
        }
    }

    private struct Journal: Codable {
        var projectID: String
        var before: CanvasDocument
        var after: CanvasDocument
        var targetIsLive: Bool
        var fingerprint: String
    }
    /// Only nodes/edges determine edits; panning/zooming may safely survive an undo.
    private static func sameGraph(_ a: CanvasDocument, _ b: CanvasDocument) -> Bool {
        func semantic(_ nodes: [CanvasNode]) -> [CanvasNode] {
            nodes.map {
                var node = $0
                node.updatedAt = .distantPast
                node.mediaLayoutAttachmentID = nil
                return node
            }
        }
        return semantic(a.nodes) == semantic(b.nodes) && a.edges == b.edges
    }
    public func exchange(_ receipt: Receipt, undo: Bool) throws -> CanvasDocument {
        try StorageLock.shared.withLock {
            guard !StorageLock.shared.isDegraded else { throw AgentCanvasError.busy }
            let project = receipt.project, docURL = projectDir(project).appendingPathComponent("canvas.json")
            try recover(projectID: project.id)
            let current = try JSONDecoder().decode(CanvasDocument.self, from: Data(contentsOf: docURL))
            let expected = undo ? receipt.document : CanvasDocument.empty
            guard Self.sameGraph(current, expected) else { throw AgentOperationError("工作流节点或连线已改变，保留现状，无法整组撤销/重做。") }
            let from = undo ? liveGroup(project) : stashGroup(project)
            let to = undo ? stashGroup(project) : liveGroup(project)
            guard try Self.fingerprint(from) == receipt.contentFingerprint else {
                throw AgentOperationError("工作流正文、标签或素材已改变，保留现状，无法整组撤销/重做。")
            }
            if fm.fileExists(atPath: to.path) {
                guard try fm.contentsOfDirectory(atPath: to.path).isEmpty else {
                    throw AgentOperationError("目标内容目录已有新内容，无法覆盖。")
                }
                try fm.removeItem(at: to)
            }
            var after = undo ? CanvasDocument.empty : receipt.document
            after.panX = current.panX; after.panY = current.panY; after.zoom = current.zoom; after.updatedAt = Date()
            let journal = Journal(projectID: project.id, before: current, after: after, targetIsLive: !undo,
                                  fingerprint: receipt.contentFingerprint)
            try CanvasWorkflowSnapshot.jsonData(journal).write(to: journalURL(project), options: .atomic)
            do {
                try fm.moveItem(at: from, to: to)
                try CanvasWorkflowSnapshot.jsonData(after).write(to: docURL, options: .atomic)
            } catch {
                try recover(projectID: project.id)
                throw error
            }
            try? fm.removeItem(at: journalURL(project))
            return after
        }
    }

    /// Resolve an interrupted swap before CanvasStorage exposes the graph to reconciliation/UI.
    public func recover(projectID: String) throws {
        guard UUID(uuidString: projectID) != nil else { return }
        let project = CanvasProject(id: projectID, name: "")
        let journalFile = journalURL(project)
        guard fm.fileExists(atPath: journalFile.path) else { return }
        try StorageLock.shared.withLock {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalFile))
            guard journal.projectID == projectID else { throw AgentCanvasError.conflict }
            let doc = try JSONDecoder().decode(CanvasDocument.self,
                from: Data(contentsOf: projectDir(project).appendingPathComponent("canvas.json")))
            let committed = Self.sameGraph(doc, journal.after)
            guard committed || Self.sameGraph(doc, journal.before) else { throw AgentCanvasError.conflict }
            let shouldBeLive = committed ? journal.targetIsLive : !journal.targetIsLive
            let desired = shouldBeLive ? liveGroup(project) : stashGroup(project)
            let other = shouldBeLive ? stashGroup(project) : liveGroup(project)
            if fm.fileExists(atPath: other.path) {
                guard !fm.fileExists(atPath: desired.path), try Self.fingerprint(other) == journal.fingerprint else {
                    throw AgentCanvasError.conflict
                }
                try fm.moveItem(at: other, to: desired)
            }
            guard try Self.fingerprint(desired) == journal.fingerprint else { throw AgentCanvasError.conflict }
            try fm.removeItem(at: journalFile)
        }
    }
    /// Stat identity, size and nanosecond mtime catch normal edits without hashing GB media on Cmd+Z.
    private static func fingerprint(_ directory: URL) throws -> String {
        let canonical = directory.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: canonical.path),
              let enumerator = FileManager.default.enumerator(atPath: canonical.path) else {
            throw AgentCanvasError.unavailable
        }
        var records: [String] = []
        for case let relative as String in enumerator {
            let url = canonical.appendingPathComponent(relative)
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard attributes.isRegularFile == true else { continue }
            var value = stat()
            guard stat(url.path, &value) == 0 else { throw AgentCanvasError.unavailable }
            // Diagnostic manifests are rebuilt asynchronously; they are not user content.
            if relative == "manifest.json" { continue }
            records.append("\(relative):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec)")
        }
        return CanvasWorkflowSnapshot.digest(Data(records.sorted().joined(separator: "\n").utf8))
    }
}
