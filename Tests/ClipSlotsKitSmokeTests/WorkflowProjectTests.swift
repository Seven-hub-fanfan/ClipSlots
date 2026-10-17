import Foundation
import ClipSlotsKit

func runWorkflowProjectTests(_ t: TestRunner) {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("workflow-project-\(UUID())")
    defer { try? fm.removeItem(at: root) }
    let transaction = WorkflowProjectTransaction(root: root)
    let projects = CanvasProjectStorage(rootOverride: root)
    let original = projects.load()
    let privateStorage = SpecialSlotStorage(baseDirectory: root.appendingPathComponent("canvas/private_slots"), role: .canvasPrivate)
    let source = CanvasNode(pageId: "page", groupId: "group", slot: 1, kind: .image, mediaRole: .source, x: 0, y: 0)
    let text = CanvasNode(pageId: "page", groupId: "group", slot: 2, kind: .text, x: 0, y: 300)
    let output = CanvasNode(pageId: "page", groupId: "group", slot: 3, kind: .video, x: 500, y: 0)
    let date = Date(timeIntervalSince1970: 1234)
    let graph = CanvasWorkflowSnapshot(projectID: "old-project", facts: [
        .init(node: source, title: "产品图", body: "图片说明", bodyRevision: "r1"),
        .init(node: text, title: "风格", body: "低饱和的柔光", bodyRevision: "r2"),
        .init(node: output, title: "视频", body: "缓慢推近", bodyRevision: "r3")
    ], edges: [.init(id: "z", fromNodeId: source.id, toNodeId: output.id, role: .firstFrame, createdAt: date),
               .init(id: "a", fromNodeId: text.id, toNodeId: output.id, role: .prompt, createdAt: date)], selectionIDs: [])
    struct Failure: Error {}
    do {
        let png = root.appendingPathComponent("reference.png")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a9sAAAAASUVORK5CYII=") ?? Data()
        try bytes.write(to: png)
        let skill = try WorkflowSkill(snapshot: .init(graph: graph, runs: []), method: "柔光产品短片", messageID: nil, receipts: [])
        let media = skill.graph.variables.first?.id ?? ""
        let instance = try skill.instantiate(values: [media: .resources([png.path])])
        t.expectThrows("failure halfway through node staging aborts entire project") {
            _ = try transaction.prepare(name: "中途失败", instance: instance) { if $0 == 2 { throw Failure() } }
        }
        t.equal(CanvasProjectStorage(rootOverride: root).load(), original, "staging failure changes no project index")
        let abandoned = try transaction.prepare(name: "提交失败", instance: instance)
        t.expectThrows("failure immediately before visibility commit reports failure") {
            _ = try transaction.commit(abandoned, expected: original, privateStorage: privateStorage) { throw Failure() }
        }
        t.equal(CanvasProjectStorage(rootOverride: root).load(), original, "failed final commit never exposes partial graph")
        t.check(!fm.fileExists(atPath: projects.docURL(projectId: abandoned.project.id).path),
                "failed commit removes discoverable project document")
        let prepared = try transaction.prepare(name: "复用流程", instance: instance)
        let receipt = try transaction.commit(prepared, expected: original, privateStorage: privateStorage)
        let project = receipt.project
        let reopened = CanvasProjectStorage(rootOverride: root).load()
        t.equal(reopened.projects.count, original.projects.count + 1, "one successful group creates one project")
        t.equal(reopened.activeProjectId, project.id, "visibility commit activates complete project")
        let disk = CanvasStorage(rootOverride: root).load(projectId: project.id)
        t.equal(disk.nodes, receipt.document.nodes, "all nodes survive restart")
        t.equal(disk.edges.map(\.role), [.prompt, .firstFrame], "new identities preserve semantic edge order")
        t.check(Set(disk.nodes.map(\.id)).isDisjoint(with: Set(graph.nodes.map(\.id))), "reused nodes have independent identities")
        t.check(Set(disk.edges.map(\.id)).isDisjoint(with: Set(graph.edges.map(\.id))), "reused edges have new identities")
        t.check(disk.nodes.allSatisfy { $0.state == .idle && $0.taskId == nil && $0.outputAttachmentIds.isEmpty },
                "creating workflow never resumes old paid tasks or copies outputs")
        let actual = privateStorage.get(1, in: project.privateGroupId)
        t.equal(actual.plainText, "图片说明", "source body is fully restored in private slots")
        t.equal(privateStorage.getLabel(2, in: project.privateGroupId), "风格", "titles are preserved as actual slot labels")
        let attachmentPath = actual.attachments.first?.storagePath ?? ""
        t.equal(try Data(contentsOf: URL(fileURLWithPath: attachmentPath)), bytes, "moved staging directory resolves managed media bytes")
        try Data([1, 2, 3]).write(to: png)
        t.equal(try Data(contentsOf: URL(fileURLWithPath: attachmentPath)), bytes, "later external file edits cannot alter copied reference")
        var probed = disk
        probed.nodes[0].mediaLayoutAttachmentID = "native-probe-version"
        probed.nodes[0].updatedAt = Date()
        try CanvasWorkflowSnapshot.jsonData(probed).write(to: projects.docURL(projectId: project.id), options: .atomic)
        let live = root.appendingPathComponent("canvas/private_slots/\(project.privateGroupId)")
        let stash = projects.docURL(projectId: project.id).deletingLastPathComponent().appendingPathComponent(".workflow-content")
        let empty = try transaction.exchange(receipt, undo: true)
        t.check(empty.nodes.isEmpty && empty.edges.isEmpty && !fm.fileExists(atPath: live.path),
                "one undo removes graph and private contents despite derived media probe metadata")
        t.check(fm.fileExists(atPath: stash.path), "undo retains complete bytes in a private stash")
        t.check(CanvasStorage(rootOverride: root).load(projectId: project.id).nodes.isEmpty, "undone graph remains empty after restart")
        let restored = try transaction.exchange(receipt, undo: false)
        t.equal(restored.nodes, disk.nodes, "redo restores the same new identities and parameters")
        t.equal(restored.edges, disk.edges, "redo restores all ordered edges")
        t.equal(try Data(contentsOf: URL(fileURLWithPath: attachmentPath)), bytes, "redo preserves complete attachment bytes")

        // Simulate process death between directory swap and canvas.json commit.
        struct Journal: Encodable {
            var projectID: String; var before: CanvasDocument; var after: CanvasDocument
            var targetIsLive: Bool; var fingerprint: String
        }
        let journalURL = projects.docURL(projectId: project.id).deletingLastPathComponent().appendingPathComponent(".workflow-exchange.json")
        let current = CanvasStorage(rootOverride: root).load(projectId: project.id)
        let journal = Journal(projectID: project.id, before: current, after: .empty, targetIsLive: false,
                              fingerprint: receipt.contentFingerprint)
        try CanvasWorkflowSnapshot.jsonData(journal).write(to: journalURL, options: .atomic)
        try fm.moveItem(at: live, to: stash)
        let recovered = CanvasStorage(rootOverride: root).load(projectId: project.id)
        t.equal(recovered.nodes, disk.nodes, "crash before graph commit restores full original graph")
        t.check(fm.fileExists(atPath: attachmentPath) && !fm.fileExists(atPath: journalURL.path),
                "crash recovery restores backing bytes before exposing graph")
        try CanvasWorkflowSnapshot.jsonData(journal).write(to: journalURL, options: .atomic)
        try fm.moveItem(at: live, to: stash)
        try CanvasWorkflowSnapshot.jsonData(CanvasDocument.empty).write(to: projects.docURL(projectId: project.id), options: .atomic)
        let committedUndo = CanvasStorage(rootOverride: root).load(projectId: project.id)
        t.check(committedUndo.nodes.isEmpty && fm.fileExists(atPath: stash.path),
                "crash after graph commit retains complete undone state")
        _ = try transaction.exchange(receipt, undo: false)
        var edited = privateStorage.get(2, in: project.privateGroupId)
        edited.items = SlotContent(text: "手工编辑，请保留").items
        edited.contentId = UUID().uuidString
        edited.updatedAt = Date().timeIntervalSince1970
        t.check(privateStorage.set(2, content: edited, in: project.privateGroupId), "manual edit setup")
        t.expectThrows("group undo refuses to overwrite subsequent body edits") { _ = try transaction.exchange(receipt, undo: true) }
        t.equal(privateStorage.get(2, in: project.privateGroupId).plainText, "手工编辑，请保留", "conflicting manual content remains intact")
        t.equal(CanvasStorage(rootOverride: root).load(projectId: project.id).nodes.count, 3, "conflict changes no node or edge")
    } catch { t.check(false, "workflow project atomicity: \(error)") }
}
