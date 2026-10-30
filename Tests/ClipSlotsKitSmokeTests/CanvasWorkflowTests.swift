import Foundation
import ClipSlotsKit

func runCanvasWorkflowTests(_ t: TestRunner) {
    let date = Date(timeIntervalSince1970: 1234)
    func node(_ slot: Int, _ kind: CanvasNodeKind) -> CanvasNode {
        CanvasNode(pageId: "page", groupId: "group", slot: slot, kind: kind, x: 10, y: 20,
                   createdAt: date, updatedAt: date)
    }
    let style = node(1, .text), source = node(2, .image), other = node(4, .text)
    var video = node(3, .video)
    video.model = "video-model"; video.resolution = "4k"; video.duration = 8; video.generateAudio = true
    var text = node(5, .text)
    text.textGenerationPrompt = "保留产品，改成黄昏"
    let media = CanvasWorkflowMedia(id: "media-source", attachmentID: "source", name: "参考.png", kind: "image",
                                   role: "source", revision: "v1", availability: "local")
    let facts: [CanvasWorkflowFacts] = [
        .init(node: style, title: "风格", body: "低饱和胶片", bodyRevision: "style-1"),
        .init(node: source, title: "产品", body: "参考图片说明", bodyRevision: "source-1",
              primaryAssetPath: "/private/product.png", media: [media], resourcePaths: [media.id: "/private/product.png"]),
        .init(node: video, title: "视频", body: "慢慢推近", bodyRevision: "video-1",
              inputImagePaths: ["/private/tail.png"], expectedInputImages: 1,
              resourcePaths: ["media-tail": "/private/tail.png"]),
        .init(node: other, title: "无关分支", body: "不应混入上下文", bodyRevision: "other-1"),
        .init(node: text, title: "优化提示词", body: "海边的产品特写，柔光照明", bodyRevision: "text-1")
    ]
    let edges: [CanvasEdge] = [
        .init(id: "b", fromNodeId: source.id, toNodeId: video.id, role: .auto, createdAt: date),
        .init(id: "a", fromNodeId: style.id, toNodeId: video.id, role: .prompt, createdAt: date),
        .init(id: "c", fromNodeId: source.id, toNodeId: text.id, role: .reference, createdAt: date)
    ]
    let all = Dictionary(uniqueKeysWithValues: facts.map { ($0.node.id, $0) })
    let plan = CanvasWorkflowResolver.resolve(facts[2], all: all, edges: edges)
    t.equal(plan.prompt, "低饱和胶片\n\n慢慢推近", "workflow uses generation prompt order")
    t.equal(plan.videoRequest?.firstFramePath, "/private/product.png", "auto image fills video first frame")
    t.equal(plan.videoRequest?.lastFramePath, "/private/tail.png", "own image fills remaining last frame")
    t.check(plan.blockingReasons.isEmpty, "valid workflow has no blockers")
    t.equal(plan.fragments.first?.sourceNodeID, style.id, "prompt fragment keeps actual source identity")
    let textPlan = CanvasWorkflowResolver.resolve(facts[4], all: all, edges: edges)
    t.equal(textPlan.prompt, CanvasImagePrompt.request(intent: facts[4].body, existing: "",
        references: ["参考图片说明"]), "text optimization uses current body, not a stale separate instruction")
    t.equal(textPlan.fragments.first?.edgeID, "c", "text optimization reads text even for reference role")
    t.check(textPlan.imageRequest == nil && textPlan.videoRequest == nil, "text optimization never creates media request")

    let samples = [
        "  中文🙂 e\u{301} & < > \" ' \\\\ $() `字符` \t\n",
        "\n# 分镜\n\n| 时间 | 画面 |\n| --- | --- |\n| 00:01 | 慢推 |\n\n    保留缩进\n",
        String(repeating: "镜头：角色走进森林，光影流动。🙂\n", count: 2500)
    ]
    for (index, sample) in samples.enumerated() {
        for kind in [CanvasNodeKind.image, .video] {
            let target = node(8, kind)
            let source = CanvasWorkflowFacts(node: style, title: "", body: sample, bodyRevision: "")
            let targetFact = CanvasWorkflowFacts(node: target, title: "", body: "", bodyRevision: "")
            let inputPlan = CanvasWorkflowResolver.resolve(targetFact,
                all: [style.id: source, target.id: targetFact],
                edges: [.init(fromNodeId: style.id, toNodeId: target.id)])
            t.equal(Data(inputPlan.prompt.utf8), Data(sample.utf8), "\(kind) sample \(index) keeps exact UTF-8 through edge")
            do {
                let args = try inputPlan.imageRequest.map(CrateGeneration.submitArguments)
                    ?? inputPlan.videoRequest.map(CrateGeneration.submitArguments) ?? []
                let promptIndex = args.firstIndex(of: "--prompt").map { $0 + 1 }
                t.equal(promptIndex.map { Data(args[$0].utf8) }, Data(sample.utf8),
                        "\(kind) sample \(index) reaches CLI as one intact argument")
            } catch { t.check(false, "\(kind) sample \(index) request: \(error)") }
        }
    }

    let snapshot = CanvasWorkflowSnapshot(projectID: "project-A", facts: facts, edges: edges, selectionIDs: [video.id])
    t.equal(snapshot.subgraphIDs(roots: [video.id], direction: .upstream), Set([style.id, source.id, video.id]),
            "upstream closure includes dependencies and excludes unrelated nodes")
    t.equal(snapshot.subgraphIDs(roots: [source.id], direction: .downstream), Set([source.id, video.id, text.id]),
            "downstream closure includes both branches")
    t.equal(snapshot.subgraphIDs(roots: ["unknown"], direction: .both), [], "unknown graph root gives no access")
    let readVideo = snapshot.nodes.first { $0.id == video.id }
    t.equal(readVideo?.plannedRequest?.firstFrame, media.id, "snapshot request maps paths to resource IDs")
    t.equal(readVideo?.plannedRequest?.lastFrame, "media-tail", "snapshot preserves own frame binding")
    t.equal(readVideo?.bindings.first { $0.role == .firstFrame }?.sourceNodeID, source.id,
            "effective frame source is traceable")
    t.equal(readVideo?.bindings.first { $0.role == .lastFrame }?.sourceNodeID, video.id,
            "own media has target-node provenance")
    do {
        let bytes = try CanvasWorkflowSnapshot.jsonData(snapshot)
        t.check(!String(decoding: bytes, as: UTF8.self).contains("/private/"), "serialized snapshot leaks no resource paths")
        t.equal(try JSONDecoder().decode(CanvasWorkflowSnapshot.self, from: bytes), snapshot, "snapshot roundtrip")
    } catch { t.check(false, "snapshot persistence: \(error)") }
    var changed = facts
    changed[2].node.x = 999
    changed[2].node.updatedAt = Date()
    let moved = CanvasWorkflowSnapshot(projectID: "project-A", facts: changed, edges: edges, selectionIDs: [])
    t.equal(moved.graphRevision, snapshot.graphRevision, "layout/selection changes preserve semantic revision")
    changed[0].body = "饱和霓虹色"
    let edited = CanvasWorkflowSnapshot(projectID: "project-A", facts: changed, edges: edges, selectionIDs: [])
    t.check(edited.graphRevision != snapshot.graphRevision, "body mutation invalidates semantic revision without relying on contentId")
    changed = facts
    changed[1].media[0].revision = "replaced-file"
    t.check(CanvasWorkflowSnapshot(projectID: "project-A", facts: changed, edges: edges, selectionIDs: []).graphRevision
            != snapshot.graphRevision, "media replacement invalidates semantic revision")
    var changedEdges = edges
    changedEdges[0].role = .lastFrame
    t.check(CanvasWorkflowSnapshot(projectID: "project-A", facts: facts, edges: changedEdges, selectionIDs: []).graphRevision
            != snapshot.graphRevision, "edge role invalidates semantic revision")
    changed = facts
    changed[1].bodyAvailable = false
    let unreadable = CanvasWorkflowResolver.resolve(facts[2],
        all: Dictionary(uniqueKeysWithValues: changed.map { ($0.node.id, $0) }), edges: edges)
    t.check(!unreadable.blockingReasons.isEmpty, "unreadable upstream is not silently empty")
    changed = facts
    changed[2].inputImagePaths = []
    t.check(!CanvasWorkflowResolver.resolve(changed[2], all: all, edges: edges).blockingReasons.isEmpty,
            "missing own reference image blocks generation")
    let withCycle = CanvasWorkflowSnapshot(projectID: "project-A", facts: facts,
        edges: edges + [.init(fromNodeId: video.id, toNodeId: source.id)], selectionIDs: [])
    t.equal(withCycle.subgraphIDs(roots: [video.id], direction: .upstream), Set([style.id, source.id, video.id]),
            "corrupt graph cycle traversal terminates")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-runs-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GenerationRunStore(root: root)
    let context = GenerationRunContext(snapshot: snapshot, node: video, resourceIDs: ["/private/product.png": media.id])
    let requested = GenerationRequestRecord(CrateVideoRequest(model: "video-model", prompt: "真实请求",
        ratio: "16:9", resolution: "4k", duration: 8, generateAudio: true, firstFramePath: "/private/product.png", seed: 42),
        resourceIDs: context.resourceIDs)
    var effective = requested
    effective.seed = nil
    do {
        t.check(store.latest(project: "project-A", node: video) == nil, "legacy generation history stays unavailable")
        let first = try store.beginAttempt(context: context, requested: requested, effective: effective)
        t.check(store.load(project: "project-A", id: context.runID)?.requiresSubmissionReconciliation == true,
                "persisted submitting record protects crash/unknown boundary")
        t.expectThrows("inflight run blocks duplicate attempt at persistence boundary") {
            _ = try store.beginAttempt(context: context, requested: requested, effective: effective)
        }
        try store.finishAttempt(context: context, attemptID: first, status: .rejected, detail: "unsupported ratio")
        effective.ratio = ""
        let second = try store.beginAttempt(context: context, requested: requested, effective: effective)
        try store.finishAttempt(context: context, attemptID: second, status: .accepted, taskID: "task-1", seed: 777)
        let reopened = GenerationRunStore(root: root)
        let run = reopened.load(project: "project-A", id: context.runID)
        t.equal(run?.attempts.count, 2, "parameter fallback preserves both attempts after restart")
        t.equal(run?.attempts.last?.droppedParameters, ["seed", "ratio"], "effective request identifies dropped parameters")
        t.equal(run?.requestedRequest.seed, 42, "original requested seed preserved")
        t.equal(run?.attempts.last?.returnedSeed, 777, "returned server seed distinguished from requested seed")
        t.equal(run?.attempts.last?.taskID, "task-1", "accepted task persisted immediately")
        t.expectThrows("accepted run blocks resubmit after restart") {
            _ = try reopened.beginAttempt(context: context, requested: requested, effective: effective)
        }
        t.expectThrows("late failure cannot erase accepted receipt") {
            try reopened.finishAttempt(context: context, attemptID: second, status: .unknown)
        }
        t.expectThrows("conflicting receipt cannot replace accepted task identity") {
            try reopened.finishAttempt(context: context, attemptID: second, status: .accepted, taskID: "wrong", seed: 777)
        }
        try reopened.finishAttempt(context: context, attemptID: second, status: .accepted, taskID: "task-1", seed: 777)
        t.equal(reopened.load(project: "project-A", id: context.runID)?.attempts.count, 2, "duplicate accepted receipt is idempotent")
        t.check(run?.requiresSubmissionReconciliation == false, "explicit rejection followed by accepted task is reconciled")
        t.check(reopened.load(project: "project-B", id: context.runID) == nil, "run records remain project scoped")
        try reopened.updateTask(project: "project-A", taskID: "task-1", outcome: "succeeded", outputIDs: ["output-1"])
        t.equal(reopened.load(project: "project-A", id: context.runID)?.outputAttachmentIDs, ["output-1"],
                "task recovery updates original run output")
        try reopened.updateTask(project: "project-A", taskID: "task-1", outcome: "running")
        t.equal(reopened.load(project: "project-A", id: context.runID)?.outcome, "succeeded", "late query does not reopen completed outcome")
        try reopened.updateTask(project: "project-A", taskID: "legacy-task", outcome: "succeeded")
        t.equal(reopened.runs(project: "project-A").count, 1, "legacy recovery does not invent a submitted request")
        let unknownContext = GenerationRunContext(snapshot: snapshot, node: video, resourceIDs: [:])
        let unknownAttempt = try reopened.beginAttempt(context: unknownContext, requested: requested, effective: requested)
        try reopened.finishAttempt(context: unknownContext, attemptID: unknownAttempt, status: .unknown)
        t.check(reopened.latest(project: "project-A", node: video)?.requiresSubmissionReconciliation == true,
                "unknown submission cannot be treated as safe to resubmit")
        t.expectThrows("unknown run blocks repeat submission after restart") {
            _ = try GenerationRunStore(root: root).beginAttempt(context: unknownContext, requested: requested, effective: requested)
        }
        var wrongContext = unknownContext
        wrongContext.nodeCreatedAt = Date()
        t.expectThrows("reused node id does not mutate original attempt") {
            try reopened.finishAttempt(context: wrongContext, attemptID: unknownAttempt, status: .unknown)
        }
        let malformed = root.appendingPathComponent("generation-runs")
            .appendingPathComponent(CanvasWorkflowSnapshot.digest(Data(context.projectID.utf8)))
            .appendingPathComponent(unknownContext.runID.uuidString + ".json")
        let corruptBytes = Data("broken record".utf8)
        try corruptBytes.write(to: malformed)
        t.expectThrows("corrupt run record is not overwritten by new submission") {
            _ = try reopened.beginAttempt(context: unknownContext, requested: requested, effective: requested)
        }
        t.equal(try Data(contentsOf: malformed), corruptBytes, "corrupt history bytes retained")
        let input = root.appendingPathComponent("input.png")
        try Data([1, 2, 3]).write(to: input)
        let fileContext = GenerationRunContext(snapshot: snapshot, node: video, resourceIDs: [input.path: media.id])
        var fileRequest = requested
        fileRequest.firstFrame = media.id
        t.check(fileContext.inputsAreCurrent(fileRequest), "unchanged captured resource passes submission fence")
        try Data([1, 2, 3, 4]).write(to: input)
        t.check(!fileContext.inputsAreCurrent(fileRequest), "changed resource blocked before submission")
        try FileManager.default.removeItem(at: input)
        t.check(!fileContext.inputsAreCurrent(fileRequest), "deleted resource blocked before submission")
        let blockedRoot = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blockedRoot)
        t.expectThrows("cannot submit without a durable begin-attempt record") {
            _ = try GenerationRunStore(root: blockedRoot).beginAttempt(context: context, requested: requested, effective: effective)
        }
    } catch { t.check(false, "run record persistence: \(error)") }
}
