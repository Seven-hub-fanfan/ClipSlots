import Foundation
import ClipSlotsKit

func runCanvasStructureCopyTests(_ t: TestRunner) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("structure-copy-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let project = CanvasProject(id: "default", name: "fixture")
        let storage = SpecialSlotStorage(baseDirectory: root.appendingPathComponent("canvas/private_slots"), role: .canvasPrivate)
        _ = try storage.ensureReservedGroup(id: project.privateGroupId, name: "fixture")
        let nodes = (1...3).map { CanvasNode(pageId: SpecialSlotStorage.canvasPrivatePageId,
            groupId: project.privateGroupId, slot: $0, kind: .text, x: CGFloat($0 * 100), y: 100) }
        let data = Data((0..<4096).map { UInt8($0 % 251) })
        var content = SlotContent(text: "正文🙂")
        content.label = "原标签"
        content.attachments = [.init(name: "source.bin", type: .file, data: data)]
        content.manualThumbnailId = UUID().uuidString; content.pendingManualThumbnailData = data
        for node in nodes { t.check(storage.set(node.slot, content: content, in: node.groupId, replacingLabel: true), "copy source writes") }
        let child = CanvasNodeGroup(id: "child", nodeIDs: [nodes[1].id],
            containerFrame: CGRect(x: 180, y: 80, width: 380, height: 400), parentGroupID: "group")
        let group = CanvasNodeGroup(id: "group", nodeIDs: [nodes[0].id],
            containerFrame: CGRect(x: 80, y: 80, width: 500, height: 450))
        let pile = CanvasPile(id: "pile", memberIDs: [nodes[0].id, nodes[1].id],
                             at: CGPoint(x: 100, y: 100), groupID: "group")
        let internalEdge = CanvasEdge(fromNodeId: nodes[0].id, toNodeId: nodes[1].id, role: .prompt)
        let incoming = CanvasEdge(fromNodeId: nodes[2].id, toNodeId: nodes[1].id, role: .prompt)
        let before = CanvasDocument(nodes: nodes, edges: [internalEdge, incoming], groups: [group, child], piles: [pile])
        let docs = CanvasStorage(rootOverride: root)
        t.check(docs.save(before, projectId: "default"), "copy graph baseline writes")
        let capture = try CanvasStructureCapture(projectID: "default", document: before, roots: ["group"], root: root) { node in
            var value = storage.get(node.slot, in: node.groupId)
            value.label = storage.getLabel(node.slot, in: node.groupId)
            value.pendingManualThumbnailData = data
            return value
        }
        t.equal(capture.graph.nodes.count, 2, "group capture includes descendants and pile members once")
        let transaction = CanvasStructureCopyTransaction(root: root)
        enum Interrupted: Error { case injected }
        t.expectThrows("copy interruption rejects partial graph") {
            _ = try transaction.append(capture, to: before, projectID: "default", slots: [4, 5], delta: .zero) { _ in
                throw Interrupted.injected
            }
        }
        t.equal(AgentCanvasSync.revision(CanvasStorage(rootOverride: root).load(projectId: "default")),
                AgentCanvasSync.revision(before), "failed copy retains original graph")
        t.check(!FileManager.default.fileExists(atPath: storage.storageRoot.appendingPathComponent("\(project.privateGroupId)/4").path),
                "interrupted copy removes only its own staged content")
        let after = try transaction.append(capture, to: before, projectID: "default", slots: [4, 5],
                                          delta: CGSize(width: 40, height: 40))
        t.equal(after.nodes.count, 5, "copy commits all nodes")
        t.equal(after.groups.count, 4, "copy commits complete nested container tree")
        let copies = Array(after.nodes.suffix(2)), groups = Array(after.groups.suffix(2))
        t.check(groups[1].parentGroupID == groups[0].id && groups[0].id != group.id,
                "copied child belongs to new independent parent")
        t.equal(copies[0].x - nodes[0].x, 40, "world coordinates translate once")
        t.equal(after.piles.last?.memberIDs, copies.map(\.id), "copy remaps ordered pile members")
        t.check(after.edges.contains { $0.fromNodeId == nodes[2].id && $0.toNodeId == copies[1].id },
                "same project preserves external incoming dependency")
        let restored = SlotStorage(slotsDir: storage.storageRoot.appendingPathComponent(project.privateGroupId)).get(4)
        t.equal(restored.plainText, content.plainText, "copied body survives fresh storage read")
        t.equal(SlotStorage(slotsDir: storage.storageRoot.appendingPathComponent(project.privateGroupId)).getLabel(4),
                content.label, "copy keeps label")
        t.check(restored.attachments.first?.id != content.attachments.first?.id
                && restored.attachments.first?.storagePath != content.attachments.first?.storagePath,
                "copied attachment receives independent identity")
        t.equal(try Data(contentsOf: URL(fileURLWithPath: restored.attachments[0].storagePath!)), data,
                "copied attachment bytes survive")
        t.equal(try Data(contentsOf: storage.manualThumbnailURL(4, in: project.privateGroupId)!), data,
                "manual thumbnail bytes survive")
        t.equal(storage.get(1, in: project.privateGroupId).plainText, content.plainText, "source retained after commit")
        t.expectThrows("occupied target cannot be overwritten") {
            _ = try transaction.append(capture, to: after, projectID: "default", slots: [4, 6], delta: .zero)
        }
        t.expectThrows("stale disk graph cannot be overwritten") {
            _ = try transaction.append(capture, to: before, projectID: "default", slots: [6, 7], delta: .zero)
        }
        // Simulate the durable state left by process death between directory
        // publication and the final graph write, then use production load recovery.
        let journalURL = root.appendingPathComponent("canvas/projects/default/structure-copy-journal.json")
        let orphan = storage.storageRoot.appendingPathComponent("\(project.privateGroupId)/6")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("owned-copy".utf8).write(to: orphan.appendingPathComponent(".copy-owner"))
        try Data("retained-or-cleaned".utf8).write(to: orphan.appendingPathComponent("payload"))
        let journal: JSONValue = ["projectID": "default",
            "beforeRevision": .string(AgentCanvasSync.revision(after)), "afterRevision": "not-committed",
            "claims": [["slot": 6, "contentID": "owned-copy"]]]
        try Data(journal.encodedText().utf8).write(to: journalURL)
        let recovery = CanvasStorage(rootOverride: root)
        _ = recovery.load(projectId: "default")
        t.check(!recovery.lastLoadFailed(projectId: "default") && !FileManager.default.fileExists(atPath: orphan.path)
                && !FileManager.default.fileExists(atPath: journalURL.path),
                "production reload recovers interrupted directory publication before reconciliation")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("someone-else".utf8).write(to: orphan.appendingPathComponent(".copy-owner"))
        try Data(journal.encodedText().utf8).write(to: journalURL)
        let conflictRecovery = CanvasStorage(rootOverride: root)
        _ = conflictRecovery.load(projectId: "default")
        t.check(conflictRecovery.lastLoadFailed(projectId: "default")
                && FileManager.default.fileExists(atPath: orphan.path),
                "recovery ownership conflict preserves content and blocks private reconciliation")
        try FileManager.default.removeItem(at: journalURL)
        try FileManager.default.removeItem(at: orphan)
        let other = CanvasProject(name: "other")
        t.check(docs.save(.empty, projectId: other.id), "cross-project baseline writes")
        let foreign = try transaction.append(capture, to: .empty, projectID: other.id, slots: [1, 2], delta: .zero)
        t.equal(foreign.edges.count, 1, "cross-project copy drops unavailable external source")
        t.equal(CanvasKeyBinding.action(keyCode: 8, command: true, shift: false), .copy, "Cmd C structure shortcut")
        t.equal(CanvasKeyBinding.action(keyCode: 2, command: true, shift: false), .duplicate, "Cmd D structure shortcut")
        t.equal(CanvasKeyBinding.action(keyCode: 2, command: true, shift: true), .none, "modified Cmd D not intercepted")
    } catch { t.check(false, "structure copy tests: \(error)") }
}
