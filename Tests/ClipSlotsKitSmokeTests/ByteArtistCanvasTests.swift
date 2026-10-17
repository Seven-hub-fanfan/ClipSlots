import Foundation
import ClipSlotsKit

private actor BACanvasFixture {
    var calls: [GenerationCLIInvocation] = []
    var unknown = false
    var statuses: [String] = []
    var output: JSONValue = [["images": ["https://example.test/one.png", "https://example.test/two.png"]]]
    let reference = """
    # 图像测试能力
    > workflow id: `123456789012345678`

    ## 输入
    | 名称 | internal_name | format | 输入描述 | 默认值 | 限制 | 节点来源 |
    | --- | --- | --- | --- | --- | --- | --- |
    | prompt | prompt | input | 文本 | | | Test:prompt |
    | image | image | image_upload | 参考图 | | | Test:image |

    ## 输出
    | 名称 | internal_name | format | 节点来源 |
    | --- | --- | --- | --- |
    | images | images | image | Test:images |

    ## 输入 Schema
    ```json
    {"type":"object","additionalProperties":false,"properties":{"prompt":{"type":"string","minLength":1},"steps":{"type":"integer","default":12,"minimum":1,"maximum":20},"audio":{"type":"boolean","default":false},"image":{"type":"string","default":"https://example.test/source.png"}}}
    ```
    """
    func setUnknown(_ value: Bool) { unknown = value }
    func setStatuses(_ values: [String]) { statuses = values }
    func setOutput(_ value: JSONValue) { output = value }
    func execute(_ call: GenerationCLIInvocation) throws -> ToolProcess.Output {
        calls.append(call)
        if call.arguments == ["--version"] { return .init(status: 0, stdout: "ba 1.1.5", stderr: "") }
        let json: JSONValue
        if call.submitting {
            if unknown { return .init(status: 1, stdout: "", stderr: "") }
            json = ["event": "task_created", "task_id": "task-1"]
        } else if call.arguments.contains("auth") { json = ["loggedIn": true] }
        else if call.arguments.contains("skill") { json = ["markdown": .string(reference)] }
        else if call.arguments.contains("references") {
            let path = call.environment["BA_REFERENCES_DIR"].map { $0 + "/workflow-123456789012345678.md" }
                ?? "/global/workflow.md"
            json = [["workflow_id": "123456789012345678", "title": "图像测试能力", "file_path": .string(path), "content": .string(reference)]]
        } else if call.arguments.contains("list") {
            json = ["data": ["total": 61, "workflows": [["id": "123456789012345678",
                "name": "图像测试能力", "description": "图像生成"]]]]
        } else {
            json = ["task_id": "task-1", "status": .string(statuses.isEmpty ? "finished" : statuses.removeFirst()),
                    "output_result": output, "request_id": "request-proof"]
        }
        return .init(status: 0, stdout: try json.encodedText(), stderr: "")
    }
}

func runByteArtistCanvasTests(_ t: TestRunner) {
    let results: [(Bool, String)] = smokeAwait {
        var checks: [(Bool, String)] = []
        func check(_ ok: Bool, _ label: String) { checks.append((ok, "BA-CANVAS \(label)")) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ba-canvas-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let fixture = BACanvasFixture()
            let runtime = try ByteArtistRuntime(root: root, executor: { try await fixture.execute($0) })
            try await runtime.adapter.preflight()
            let available = try await runtime.adapter.localReferences()
            check(available.count == 1, "local reference candidates discovered")
            let globalCall = await fixture.calls.last!
            check(globalCall.environment["BA_REFERENCES_DIR"] == nil, "local discovery does not accidentally point at private catalog")
            try await runtime.adapter.refreshReference(id: available[0].id)
            let cap = try await runtime.adapter.discover()[0]
            check(cap.kind == .image && cap.referencePath?.hasPrefix(root.path) == true, "selected reference refreshed into isolated catalog")
            var config = ByteArtistCanvasConfiguration()
            config.select(cap)
            check(config.draft.sources["prompt"] == "prompt" && config.draft.fields["steps"] == "12", "schema defaults and prompt binding")
            config.draft.fields["steps"] = "18"
            config.draft.fields["audio"] = "true"
            let prepared = try await runtime.prepare(configuration: config, capability: cap, prompt: "上游\n本节点",
                images: [], firstFrame: nil, lastFrame: nil)
            check(prepared.input.values["prompt"] == "上游\n本节点" &&
                  prepared.input.values["steps"] == 18 && prepared.input.values["audio"] == true,
                  "typed parameters and composed prompt reach prepared input")
            var invalid = config
            invalid.draft.fields["steps"] = "21"
            do {
                _ = try invalid.input(capability: cap, prompt: "x", images: [], firstFrame: nil, lastFrame: nil)
                check(false, "schema numeric bounds block invalid input")
            } catch { check(true, "schema numeric bounds block invalid input") }
            invalid = config; invalid.draft.sources["image"] = "image:2"
            do {
                _ = try invalid.input(capability: cap, prompt: "x", images: [], firstFrame: nil, lastFrame: nil)
                check(false, "missing referenced image blocked")
            } catch { check(true, "missing referenced image blocked") }
            let other = GenerationCapability(context: .byteartist, id: "987", title: "Other", revision: "",
                kind: .video, inputSchema: ["type": "object", "properties": [:]])
            config.select(other); config.select(cap)
            check(config.draft.fields["steps"] == "18", "workflow switching keeps separate drafts")
            var node = CanvasNode(pageId: "p", groupId: "g", slot: 1, kind: .image, x: 0, y: 0)
            node.generationProvider = .byteartist; node.byteArtist = config
            let encoded = try JSONEncoder().encode(node)
            check(try JSONDecoder().decode(CanvasNode.self, from: encoded) == node, "node provider and drafts survive persistence")
            let legacy = try JSONValue.decode(jsonText: String(decoding: encoded, as: UTF8.self))
            var legacyObject = legacy.objectValue!
            legacyObject.removeValue(forKey: "generationProvider"); legacyObject.removeValue(forKey: "byteArtist")
            let old = try JSONDecoder().decode(CanvasNode.self, from: Data(JSONValue.object(legacyObject).encodedText().utf8))
            check(old.generationProvider == .crate, "legacy nodes remain Crate")
            let fact = CanvasWorkflowFacts(node: node, title: "", body: "prompt", bodyRevision: "", bodyAvailable: true)
            let plan = CanvasWorkflowResolver.resolve(fact, all: [node.id: fact], edges: [])
            check(plan.imageRequest == nil && plan.videoRequest == nil && plan.prompt == "prompt", "BA planning bypasses Crate validation")
            let snapshot = CanvasWorkflowSnapshot(projectID: "project", facts: [fact], edges: [], selectionIDs: [])
            let context = GenerationRunContext(snapshot: snapshot, node: node, resourceIDs: [:])
            let history = GenerationRunStore(root: root)
            let submitted = try await runtime.submit(prepared, recording: context, history: history)
            node.generationTask = submitted.task; node.taskId = submitted.task.taskID
            node.generationProvider = .crate
            let restored = try JSONDecoder().decode(CanvasNode.self, from: JSONEncoder().encode(node))
            check(restored.generationTask?.context == .byteartist && restored.needsGenerationRecovery,
                  "source switch leaves existing task ownership recoverable")
            let count = await fixture.calls.filter(\.submitting).count
            let result = try await runtime.wait(restored.generationTask!, timeout: 2) { _ in }
            check(result.status == .outputMismatch && result.rawOutput != nil, "unknown output is retained without guessed download")
            check(await fixture.calls.filter(\.submitting).count == count, "recovery never submits a replacement")
            let candidates = ByteArtistOutputSelection.candidates(result.rawOutput!)
            check(candidates.count == 2 && candidates[0].label == "/0/images/0", "output choices expose exact paths")
            let binding = ByteArtistOutputSelection.binding(candidates[0], kind: .image, allItems: true)
            let mapped = try GenerationTaskHandle(context: submitted.task.context, taskID: submitted.task.taskID,
                capabilityID: cap.id, kind: .image, outputBindings: [binding])
            let mappedResult = try await runtime.wait(mapped, timeout: 2) { _ in }
            check(mappedResult.status == .succeeded && mappedResult.artifacts.count == 2, "explicit output selection resolves all array media")
            let official: JSONValue = [
                ["slot_key": "102#images#0", "node_key": "images", "format": "image",
                 "value": "https://example.test/one.png", "class_type": "SaveImage", "index": 0],
                ["slot_key": "102#images#1", "node_key": "images", "format": "image",
                 "value": "https://example.test/two.png", "class_type": "SaveImage", "index": 1]]
            await fixture.setOutput(official)
            await fixture.setStatuses(["waiting", "running", "processing", "finished"])
            let tracked = try await runtime.wait(submitted.task, timeout: 2, interval: 0.01) { _ in }
            check(tracked.status == .succeeded && tracked.artifacts.count == 2,
                  "official result contract automatically resolves legacy task after running and unknown nonterminal states")
            check(tracked.diagnostic?.requestID == "request-proof" && tracked.diagnostic?.rawStatus == "finished",
                  "raw status and request identity retained")
            let online = try await runtime.adapter.workflows(page: 1, pageSize: 50, query: "图")
            check(online.total == 61 && online.hasMore && online.workflows.first?.title == "图像测试能力",
                  "online account workflow discovery returns pagination and title")
            let listingCall = await fixture.calls.last!
            check(listingCall.arguments.contains("--name") && listingCall.arguments.contains("图"),
                  "online search uses official query arguments")
            check(ByteArtistContract.mediaArtifacts([["format": "image", "value": "https://example.test/evil"]], kind: .image).isEmpty,
                  "automatic outputs reject arbitrary objects without official slot identity")
            check(ByteArtistContract.mediaArtifacts([["slot_key": "x", "node_key": "images", "format": "video",
                "value": "https://example.test/video"]], kind: .image).isEmpty, "automatic output enforces requested media kind")
            await fixture.setOutput([])
            let emptyResult = try await runtime.wait(submitted.task, timeout: 1) { _ in }
            check(emptyResult.status == .outputMismatch && emptyResult.diagnostic?.stage == "empty-output",
                  "finished empty output is distinguished from missing mapping")
            await fixture.setStatuses(["failed"])
            let failedResult = try await runtime.wait(submitted.task, timeout: 1) { _ in }
            check(failedResult.status == .failed, "only explicit terminal failure ends tracking as failed")
            await fixture.setOutput(official)
            var draftChange = config
            draftChange.draft.fields["old-field"] = "obsolete"
            draftChange.select(cap)
            check(draftChange.draft.fields["old-field"] == nil && draftChange.draft.fields["steps"] == "18",
                  "schema refresh removes obsolete fields and preserves valid values")
            let run = history.latest(project: "project", node: node)!
            check(run.attempts[0].taskHandle == submitted.task && run.requestedRequest.provider == .byteartist,
                  "history persists provider, exact typed input and task ownership")
            let crateRecord = GenerationRequestRecord(CrateImageRequest(model: "test", prompt: "x", ratio: "1:1"), resourceIDs: [:])
            var crateContext = context; crateContext.runID = UUID()
            let crateAttempt = try history.beginAttempt(context: crateContext, requested: crateRecord, effective: crateRecord)
            try history.finishAttempt(context: crateContext, attemptID: crateAttempt, status: .accepted, taskID: "task-1")
            try history.updateTask(project: "project", taskID: "task-1", outcome: "BA-only", provider: .byteartist)
            check(history.load(project: "project", id: context.runID)?.outcome == "BA-only" &&
                  history.load(project: "project", id: crateContext.runID)?.outcome == "accepted", "identical task IDs never cross provider history")
            await fixture.setUnknown(true)
            var unknownContext = context; unknownContext.runID = UUID()
            do { _ = try await runtime.submit(prepared, recording: unknownContext, history: history); check(false, "unknown submit rejects") }
            catch {
                check(history.load(project: "project", id: unknownContext.runID)?.requiresSubmissionReconciliation == true,
                      "ambiguous submission persists reconciliation barrier")
            }
            let file = root.appendingPathComponent("image.png")
            try Data("original".utf8).write(to: file)
            config.draft.sources["image"] = "image:0"
            let filePrepared = try await runtime.prepare(configuration: config, capability: cap, prompt: "x",
                images: [file.path], firstFrame: nil, lastFrame: nil)
            let before = await fixture.calls.filter(\.submitting).count
            try Data("changed-input".utf8).write(to: file)
            do { _ = try await runtime.submit(filePrepared, recording: context, history: history); check(false, "stale file blocks submit") }
            catch {
                check(await fixture.calls.filter(\.submitting).count == before, "stale file blocked before subprocess")
            }
            check(ByteArtistOutputSelection.candidates(["url": "file:///etc/passwd", "data": "javascript:alert(1)"]).isEmpty,
                  "output selection rejects local and active-content schemes")
            check(LocalTool.ba.pinnedVersion == "1.1.5" &&
                  LocalToolchain.authenticated(#"{"loggedIn":true}"#, tool: .ba), "BA environment version and auth contract")
        } catch { check(false, "unexpected error \(error)") }
        return checks
    }
    for (ok, label) in results { t.check(ok, label) }
}
