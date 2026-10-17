import Foundation
import ClipSlotsKit

func runBatchGenerationTests(_ t: TestRunner) {
    t.equal(BatchGenerationSelection.state(ids: [], selected: []), .none, "batch empty selection is none")
    t.equal(BatchGenerationSelection.state(ids: ["a", "b"], selected: ["a"]), .mixed, "batch page mixed state")
    t.equal(BatchGenerationSelection.toggled(ids: ["a", "b"], selected: ["a", "other"]),
            ["a", "b", "other"], "batch page select preserves other pages")
    t.equal(BatchGenerationSelection.toggled(ids: ["a", "b"], selected: ["a", "b", "other"]),
            ["other"], "batch page deselect preserves other pages")
    t.withFreshStore("batch generation") { storage in
        let first = try storage.createPage(name: "页面甲", withDefaultGroup: false)
        let second = try storage.createPage(name: "页面乙", withDefaultGroup: false)
        let a = try storage.createSpecialSlot(name: "同名组", pageId: first.page.id)
        let b = try storage.createSpecialSlot(name: "同名组", pageId: second.page.id)
        let empty = try storage.createSpecialSlot(name: "空组", pageId: first.page.id)
        t.expectThrows("batch library refuses private group insertion") {
            _ = try storage.ensureReservedGroup(id: "__canvas__batch-hidden", name: "不应出现")
        }
        t.check(storage.set(2, content: .init(text: "A prompt"), in: a.id), "batch source A")
        t.check(storage.set(1, content: .init(text: "B prompt"), in: b.id), "batch source B")
        t.check(storage.setLabel(2, label: "保留标签", in: a.id), "batch source label")
        var missing = SlotContent()
        missing.attachments = [.init(name: "note.pdf", type: .file)]
        t.check(storage.set(4, content: missing, in: a.id), "batch incomplete source")
        let current = storage.loadIndex().currentSpecialSlotId
        let groups = try storage.batchGenerationGroups(slotCount: 10)
        t.equal(storage.loadIndex().currentSpecialSlotId, current, "batch scan never changes selected group")
        t.check(!groups.contains { SpecialSlotStorage.isReservedGroupId($0.id) }, "batch hides reserved canvas groups")
        t.equal(groups.first { $0.id == empty.id }?.sources.count, 0, "batch empty group remains visible")
        t.equal(groups.filter { $0.group.name == "同名组" }.count, 2, "batch duplicate group names keep identities")
        let configuration = CanvasNode(pageId: "", groupId: "", slot: 1, kind: .image, x: 0, y: 0)
        let batch = BatchGeneration(projectID: "project-one", groups: groups,
                                    selected: [a.id, b.id, empty.id], configuration: configuration)
        t.equal(batch.effectiveConcurrency, 32, "new batch defaults to maximum 32")
        var bounded = batch
        bounded.concurrency = 999
        t.equal(bounded.effectiveConcurrency, 32, "batch concurrency clamps above maximum")
        bounded.concurrency = -1
        t.equal(bounded.effectiveConcurrency, 1, "batch concurrency clamps below minimum")
        bounded.concurrency = nil
        t.equal(bounded.effectiveConcurrency, 1, "legacy nil concurrency remains serial")
        t.equal(batch.items.map { $0.source.slot }, [2, 4, 1], "batch stable page/group/slot order")
        t.equal(batch.items.map { $0.source.prompt }, ["A prompt", "", "B prompt"], "batch reads each group's real data")
        t.equal(batch.items.filter { $0.status == .pending }.count, 2, "batch excludes missing prompt from submission")
        t.equal(batch.items.filter { $0.status == .skipped }.count, 1, "batch records incomplete input reason")
        t.check(batch.items.allSatisfy { $0.node.kind == .image && $0.node.count == 1 }, "batch uniform generation parameters")

        let disk = BatchGenerationStorage()
        try disk.save(batch)
        t.equal(try disk.loadAll(), [batch], "batch private state round trips")
        var stopped = batch
        stopped.reconcile(runs: [])
        t.check(stopped.stopRequested && !stopped.items.contains { $0.status == .pending }, "batch restart never auto-submits")
        var unknown = batch
        unknown.items[0].status = .submitting
        unknown.reconcile(runs: [])
        t.equal(unknown.items[0].status, .unknown, "batch interrupted submission needs reconciliation")
        t.check(!unknown.items[0].canRecover, "batch unknown ID cannot auto-query or retry")
        unknown.items[0].taskID = "remote-123"
        unknown.reconcile(runs: [])
        t.equal(unknown.items[0].status, .stopped, "batch known ID restores query-only state")
        t.check(unknown.items[0].canRecover, "batch known ID remains recoverable")

        let source = batch.items[0].source
        t.check(try storage.batchSourceIsCurrent(source), "batch frozen source initially current")
        let original = storage.get(2, in: a.id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("batch-output-\(UUID()).png")
        let bytes = Data("generated-output-bytes".utf8)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try checkBatchOutputFolders(t, template: batch, file: url, bytes: bytes)
        var output = SlotContent.SlotAttachment(name: "crate_batch.png", type: .image)
        output.id = batch.items[0].outputID; output.storagePath = url.path
        let saved = try storage.appendBatchOutput(output, source: source)
        t.equal(saved.plainText, original.plainText, "batch append preserves source prompt")
        t.equal(saved.label, original.label, "batch append preserves source label")
        t.equal(saved.attachments.first?.resolveData(), bytes, "batch managed output retains exact bytes")
        t.check(saved.attachments.first?.storagePath != url.path, "batch output ingested before temporary deletion")
        let again = try storage.appendBatchOutput(output, source: source)
        t.equal(again.attachments.count, 1, "batch recovery idempotent by preassigned output ID")
        t.check(try !storage.batchSourceIsCurrent(source), "batch append changes source revision")

        let changedSource = batch.items.last!.source
        t.check(storage.set(1, content: .init(text: "手动更新"), in: b.id), "batch manual edit fixture")
        t.expectThrows("batch never appends to changed source") {
            _ = try storage.appendBatchOutput(output, source: changedSource)
        }
        t.equal(storage.get(1, in: b.id).plainText, "手动更新", "batch conflict retains manual edit")
        t.equal(storage.get(1, in: b.id).attachments.count, 0, "batch conflict writes no attachment")
        _ = try storage.createSpecialSlot(name: "页面保留组", pageId: second.page.id)
        try storage.deleteSpecialSlot(id: b.id)
        t.expectThrows("batch deleted group refuses writeback") {
            _ = try storage.appendBatchOutput(output, source: changedSource)
        }
        t.check(!storage.loadIndex().specialSlots.contains { $0.id == b.id }, "batch never resurrects deleted group")

        let fileGroup = try storage.createSpecialSlot(name: "参考图片", pageId: first.page.id)
        var withImage = SlotContent(text: "reference")
        var reference = SlotContent.SlotAttachment(name: "input.png", type: .image)
        reference.storagePath = url.path
        withImage.attachments = [reference]
        t.check(storage.set(1, content: withImage, in: fileGroup.id), "batch reference fixture")
        let referenceSource = try storage.batchGenerationGroups(slotCount: 10).first { $0.id == fileGroup.id }!.sources[0]
        t.equal(referenceSource.references.count, 1, "batch includes actual reference path")
        t.check(referenceSource.filesAreCurrent, "batch reference version current")
        try Data("external-change".utf8).write(to: URL(fileURLWithPath: referenceSource.references[0].path))
        t.check(!referenceSource.filesAreCurrent, "batch rejects externally changed reference bytes")
        t.check(try !storage.batchSourceIsCurrent(referenceSource), "batch pre-submit rejects changed input")

        let fact = source.facts(node: batch.items[0].node)
        let snapshot = CanvasWorkflowSnapshot(projectID: batch.projectID, facts: [fact], edges: [], selectionIDs: [])
        var recording = GenerationRunContext(snapshot: snapshot, node: batch.items[0].node, resourceIDs: [:])
        recording.runID = batch.items[0].runID
        let runStore = GenerationRunStore()
        let request = GenerationRequestRecord(CrateImageRequest(model: "seedream45", prompt: "A prompt", ratio: "1:1"),
                                              resourceIDs: [:])
        let attempt = try runStore.beginAttempt(context: recording, requested: request, effective: request)
        try runStore.finishAttempt(context: recording, attemptID: attempt, status: .accepted, taskID: "known-after-crash")
        var interrupted = batch
        interrupted.items[0].status = .submitting
        interrupted.reconcile(runs: runStore.runs(project: batch.projectID))
        t.equal(interrupted.items[0].taskID, "known-after-crash", "batch recovers ID saved at service boundary")
        t.check(interrupted.items[0].canRecover, "batch service-boundary ID query only")
    }
}

private func checkBatchOutputFolders(_ t: TestRunner, template: BatchGeneration, file: URL, bytes: Data) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("batch-folders-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = BatchGenerationStorage(root: root)
    var first = template
    first.id = UUID()
    first.createdAt = ISO8601DateFormatter().date(from: "2026-10-08T23:59:59Z")!
    let utc = TimeZone(secondsFromGMT: 0)!
    first = try disk.create(first, timeZone: utc)
    t.equal(first.outputNaming?.label, "2026-10-08_批次-001", "batch ISO date with clear daily sequence")
    let one = try disk.keepOutput(file, batchID: first.id, itemID: first.items[0].id)
    let two = try disk.keepOutput(file, batchID: first.id, itemID: first.items[2].id)
    t.equal(one.deletingLastPathComponent().lastPathComponent, "2026-10-08_批次-001",
            "batch first image has readable batch folder")
    t.check(two.lastPathComponent.hasPrefix("003_"), "batch filename order stays stable across skipped items")
    t.check(one != two && one.deletingLastPathComponent() == two.deletingLastPathComponent(),
            "batch same-named outputs remain distinct in one directory")
    t.equal(try Data(contentsOf: one), bytes, "batch archived bytes intact")
    let reloaded = BatchGenerationStorage(root: root)
    t.equal(try reloaded.create(first, timeZone: TimeZone(secondsFromGMT: 12 * 3600)!), first,
            "batch creation replay preserves identity across timezone change")
    t.equal(try reloaded.keepOutput(file, batchID: first.id, itemID: first.items[0].id), one,
            "batch restart reuses output before localFile journal update")
    let otherFile = root.appendingPathComponent("renamed-output.png")
    try Data("must-not-replace".utf8).write(to: otherFile)
    t.equal(try reloaded.keepOutput(otherFile, batchID: first.id, itemID: first.items[0].id), one,
            "batch repeated retrieval with changed filename returns same image")
    t.equal(try Data(contentsOf: one), bytes, "batch repeat cannot overwrite existing bytes")
    let visibleFiles = try FileManager.default.contentsOfDirectory(at: one.deletingLastPathComponent(),
        includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
    t.equal(visibleFiles.count, 2, "batch folder exposes all outputs together")

    var next = template
    next.id = UUID(); next.createdAt = first.createdAt
    next = try reloaded.create(next, timeZone: utc)
    t.equal(next.outputNaming?.sequence, 2, "batch sequence survives storage instance restart")
    var tomorrow = template
    tomorrow.id = UUID(); tomorrow.createdAt = first.createdAt.addingTimeInterval(2)
    tomorrow = try disk.create(tomorrow, timeZone: utc)
    t.equal(tomorrow.outputNaming?.label, "2026-10-09_批次-001", "batch midnight starts new day's sequence")

    let conflictDir = disk.root.appendingPathComponent("outputs/2026-10-08_批次-002")
    try FileManager.default.createDirectory(at: conflictDir, withIntermediateDirectories: true)
    let unrelated = conflictDir.appendingPathComponent("personal.png")
    try bytes.write(to: unrelated)
    t.expectThrows("batch unowned directory collision refuses reuse") {
        _ = try disk.keepOutput(file, batchID: next.id, itemID: next.items[0].id)
    }
    t.equal(try Data(contentsOf: unrelated), bytes, "batch directory conflict leaves unrelated file intact")

    var legacy = template
    legacy.id = UUID()
    var object = try JSONSerialization.jsonObject(with: CanvasWorkflowSnapshot.jsonData(legacy)) as! [String: Any]
    object["schemaVersion"] = 1; object.removeValue(forKey: "outputNaming")
    legacy = try JSONDecoder().decode(BatchGeneration.self, from: JSONSerialization.data(withJSONObject: object))
    try disk.save(legacy)
    let oldOutput = try disk.keepOutput(file, batchID: legacy.id, itemID: legacy.items[0].id)
    t.equal(oldOutput.deletingLastPathComponent().lastPathComponent, legacy.items[0].id.uuidString,
            "batch v1 recovery retains UUID directory")
    legacy.items[0].localFile = oldOutput.path
    try disk.save(legacy)
    t.equal(try reloaded.keepOutput(otherFile, batchID: legacy.id, itemID: legacy.items[0].id), oldOutput,
            "batch legacy localFile remains directly recoverable")

    var v2 = template
    v2.id = UUID()
    v2.schemaVersion = 2
    v2 = try disk.create(v2, timeZone: utc)
    let v2Output = try disk.keepOutput(file, batchID: v2.id, itemID: v2.items[0].id)
    t.check(v2Output.deletingLastPathComponent().lastPathComponent.hasSuffix("_图片-001"),
            "schema v2 recovery preserves historical per-image paths")

    let resultLock = NSLock()
    var sequences: [Int] = [], failures: [String] = []
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
        do {
            var concurrent = template
            concurrent.id = UUID(); concurrent.createdAt = first.createdAt
            let saved = try BatchGenerationStorage(root: root).create(concurrent, timeZone: utc)
            resultLock.lock(); defer { resultLock.unlock() }
            sequences.append(saved.outputNaming?.sequence ?? -1)
        } catch {
            resultLock.lock(); defer { resultLock.unlock() }
            failures.append(String(describing: error))
        }
    }
    t.check(failures.isEmpty, "batch concurrent allocations succeed: \(failures)")
    t.equal(sequences.sorted(), Array(3...10), "batch independent writers allocate unique monotonic sequences")
    for batch in try disk.loadAll() where batch.outputNaming?.day == "2026-10-08" {
        try FileManager.default.removeItem(at: disk.root.appendingPathComponent(batch.id.uuidString + ".json"))
    }
    var afterDelete = template
    afterDelete.id = UUID(); afterDelete.createdAt = first.createdAt
    let reserved = try disk.create(afterDelete, timeZone: utc)
    t.equal(reserved.outputNaming?.sequence, 11, "batch deleting history never reuses an occupied sequence")
}
