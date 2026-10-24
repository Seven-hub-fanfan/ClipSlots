#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor
    func runCanvasAgentGenerationProbe(directory: URL) async {
        var passed = 0, failures: [String] = []
        func check(_ value: Bool, _ title: String) {
            if value { passed += 1 } else { failures.append(title) }
            NSLog("[CanvasAgentGeneration] \(value ? "PASS" : "FAIL") \(title)")
        }
        guard let fixture = ProcessInfo.processInfo.environment["CLIPSLOTS_CRATE_FIXTURE"],
              FileManager.default.isExecutableFile(atPath: fixture) else {
            failures.append("isolated local Crate fixture required")
            return
        }
        _ = canvas.createProject(name: "Agent 实际生成验收")
        canvas.isLibraryExpanded = false
        let sessions = AgentSessionStore()
        let model = sessions.canvasSession(canvas: canvas, store: store)
        let backend = CanvasAgentGenerationFixtureBackend()
        model.setBackend(backend)
        model.selectAccessMode(.fullAccess)
        model.selectAutomaticApproval(true)
        model.send(text: "新建灯塔图片和视频节点，连接后生成两张图片与一段视频。",
                   config: AgentConfig(), enabledSkills: [])
        for _ in 0..<600 where model.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(!model.isRunning && model.errorText == nil && backend.failure == nil,
              "Agent real mounted canvas generation completes: \(backend.failure ?? model.errorText ?? "complete")")
        check(backend.receipt?["ok"] == true && canvas.nodes.count == 4,
              "Agent receipt includes two image outputs and one video on real canvas")
        let generated = canvas.nodes.filter { $0.kind.isMediaNode }
        check(generated.count == 3 && generated.allSatisfy {
            if case .succeeded = $0.state { return $0.taskId != nil && $0.outputAttachmentIds.count == 1 }
            return false
        }, "native Crate outputs have independent task IDs and stored attachments")
        check(Set(generated.compactMap(\.taskId)).count == 3,
              "Agent multi-output generation never reuses a task")
        check(generated.allSatisfy {
            abs($0.width / $0.height - 16.0 / 9.0) < 0.01
        }, "Agent generated image and video preserve 16:9 geometry")
        check(model.transcript.contains { $0.canvasChanged },
              "successful canvas reply suppresses redundant manual preview")
        check(canvas.flushSave(), "generated graph flushes durably")
        let loaded = CanvasStorage().load(projectId: canvas.activeProjectId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(canvas.gatewayDocument()).write(to: directory.appendingPathComponent("generation-live.json"))
        try? encoder.encode(loaded).write(to: directory.appendingPathComponent("generation-reloaded.json"))
        check(loaded.nodes == canvas.nodes && loaded.edges == canvas.edges,
              "generated graph reload preserves tasks outputs and dependencies")
        check(generated.allSatisfy { node in
            guard let content = store.canvasReadFullContent(groupId: node.groupId, slot: node.slot) else { return false }
            return content.attachments.contains(where: { attachment in
                node.outputAttachmentIds.contains(attachment.id.uuidString) &&
                    (attachment.storageFileURL != nil || attachment.localFileReferencePath.map {
                        FileManager.default.fileExists(atPath: $0)
                    } == true)
            })
        }, "actual generated media files survive storage readback")

        model.clearHistory()
        model.selectAccessMode(.fullAccess)
        model.selectAutomaticApproval(true)
        let failing = CanvasAgentGenerationFixtureBackend(failing: true)
        model.setBackend(failing)
        model.send(text: "生成一张用于验证服务失败状态的图片。", config: AgentConfig(), enabledSkills: [])
        for _ in 0..<600 where model.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(!model.isRunning && failing.failure == nil && failing.receipt?["ok"] == false,
              "actual failed Crate task returns failed Agent receipt")
        check(canvas.nodes.contains {
            if case .failed = $0.state { return $0.outputAttachmentIds.isEmpty }
            return false
        }, "failed generation creates no invented media output")
        check(generated.allSatisfy { old in
            canvas.node(id: old.id)?.taskId == old.taskId
        }, "failed task preserves earlier successful outputs")

        func generationNode(at point: CGPoint, parent: String? = nil) -> CanvasNode? {
            guard let node = createNode(kind: .image, at: point, parentNodeId: parent,
                                        beginEditing: false, quiet: true) else { return nil }
            canvas.updateNode(id: node.id) { $0.mediaRole = .generation }
            return canvas.node(id: node.id)
        }
        func attempt(_ node: CanvasNode, prompt: String) async -> CanvasNode? {
            commitEdit(node, text: prompt)
            await generateAdjacentResults(canvas.node(id: node.id)!, singleAttempt: true)?.value
            return canvas.node(id: node.id)
        }
        func outputBytes(_ node: CanvasNode) -> Data? {
            let attachments = store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
            return CanvasMediaPick.primary(node: node, attachments: attachments)?.resolveData()
        }
        if let retry = generationNode(at: CGPoint(x: 480, y: 650)),
           let first = await attempt(retry, prompt: "CANVAS_RETRY_A") {
            let firstBytes = outputBytes(first)
            check(first.taskId != nil && firstBytes != nil, "retry A has actual initial task and media bytes")
            let failed = await attempt(first, prompt: "CANVAS_AGENT_FAIL RETRY_B")
            check(failed?.taskId != first.taskId && failed?.taskId != nil,
                  "retry B submits a new remote task after A succeeds")
            if let failed {
                if case .failed = failed.state { check(true, "retry B is a real service failure") }
                else { check(false, "retry B is a real service failure") }
                check(outputBytes(failed) == firstBytes, "failed retry preserves earlier media bytes")
                let recovered = recoverGeneration(failed)
                await recovered?.value
                check(failed.taskId != nil && canvas.node(id: retry.id)?.taskId == failed.taskId,
                      "explicit recovery queries only task B")
                if let third = await attempt(failed, prompt: "CANVAS_RETRY_C changed prompt") {
                    check(third.taskId != first.taskId && third.taskId != failed.taskId,
                          "changed prompt C submits a fresh task instead of recovering B")
                    check(outputBytes(third) != nil && outputBytes(third) != firstBytes,
                          "changed prompt C displays and stores different output bytes")
                    check(liveText(for: third) == "CANVAS_RETRY_C changed prompt",
                          "new attempt retains the newly committed prompt")
                    if let oldTicket = canvas.beginGeneration(third, restarting: true) {
                        let nodeCount = canvas.nodes.count
                        canvas.updateNodeGeneration(id: third.id, count: 4)
                        let duplicate = generateAdjacentResults(canvas.node(id: third.id)!)
                        check(duplicate == nil && canvas.nodes.count == nodeCount,
                              "a tracked direct task prevents duplicate run and sibling allocation")
                        canvas.endGeneration(oldTicket.token)
                        if let newTicket = canvas.beginGeneration(canvas.node(id: third.id)!, restarting: true) {
                            canvas.updateGeneration(oldTicket.token) {
                                $0.taskId = "obsolete-task"; $0.state = .succeeded(assetPath: "obsolete-output")
                            }
                            check(canvas.generationNode(newTicket.token)?.taskId == nil,
                                  "late old callback cannot overwrite the current attempt")
                            canvas.updateGeneration(newTicket.token) { $0.state = .idle }
                            canvas.endGeneration(newTicket.token)
                        } else { check(false, "late old callback cannot overwrite the current attempt") }
                    } else { check(false, "late old callback cannot overwrite the current attempt") }
                } else { check(false, "changed prompt C completes") }
            }
        } else { check(false, "retry fixture is created") }

        if let parent = generationNode(at: CGPoint(x: 500, y: 1000)) {
            canvas.updateNodeGeneration(id: parent.id, count: 4)
            commitEdit(parent, text: "CANVAS_AGENT_FAIL PARALLEL_SETUP")
            await generateAdjacentResults(canvas.node(id: parent.id)!)?.value
            let ids = Set(canvas.adjacentLastResultIDs[parent.id] ?? [])
            check(ids.count == 4 && ids.allSatisfy {
                if case .failed = canvas.node(id: $0)?.state { return true }; return false
            }, "four failed batch nodes are ready for marquee retry")
            let before = canvas.nodes.count
            for id in ids { commitEdit(canvas.node(id: id)!, text: "CANVAS_SELECTION_PARALLEL \(id)") }
            canvas.selectedNodeIds = ids
            runGenerationForSelection()
            await canvas.selectionGenerationTask?.value
            check(canvas.nodes.count == before, "marquee retry runs exactly selected nodes without extra siblings")
            check(ids.count == 4 && ids.allSatisfy {
                if case .succeeded = canvas.node(id: $0)?.state { return true }; return false
            }, "all four selected failed nodes finish fresh concurrent attempts")
            check(Set(ids.compactMap { canvas.node(id: $0)?.taskId }).count == 4,
                  "selected concurrent attempts own four independent tasks")
            let events = (try? String(contentsOf: directory.appendingPathComponent("attempt-events.jsonl")))?
                .split(separator: "\n").compactMap { try? JSONValue.decode(jsonText: String($0)) } ?? []
            let submits = events.filter { $0["event"] == "submitted"
                && $0["prompt"]?.stringValue?.contains("CANVAS_SELECTION_PARALLEL") == true }
            let completions = events.filter { $0["event"] == "completed" }
            check(submits.count == 4 && completions.first?["submitted"]?.intValue == 4,
                  "all four remote submissions precede the first successful result")
        } else { check(false, "parallel fixture is created") }

        if let upstream = generationNode(at: CGPoint(x: 500, y: 1400)),
           let downstream = generationNode(at: CGPoint(x: 1100, y: 1400), parent: upstream.id) {
            commitEdit(upstream, text: "CANVAS_DAG_UPSTREAM")
            commitEdit(downstream, text: "CANVAS_DAG_DOWNSTREAM")
            runGeneration(nodeIDs: [upstream.id, downstream.id], singleAttemptPerNode: true)
            await canvas.selectionGenerationTask?.value
            let previous = canvas.node(id: downstream.id)
            check(previous?.taskId != nil, "dependent task waits for and uses current upstream output")
            commitEdit(upstream, text: "CANVAS_AGENT_FAIL DAG_UPSTREAM")
            runGeneration(nodeIDs: [upstream.id, downstream.id], singleAttemptPerNode: true)
            await canvas.selectionGenerationTask?.value
            check(canvas.node(id: downstream.id)?.taskId == previous?.taskId,
                  "failed new upstream never launches downstream using stale successful siblings")
        } else { check(false, "dependency fixture is created") }

        PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-agent-generated.png").path)
        let report: [String: Any] = ["passed": passed, "failures": failures,
            "scope": "AgentChatModel to mounted canvas to real Crate subprocess, local HTTP media, durable storage"]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        model.stop()
        NSApp.terminate(nil)
    }
}

private final class CanvasAgentGenerationFixtureBackend: AgentBackend, @unchecked Sendable {
    let failing: Bool
    var receipt: JSONValue?
    var failure: String?
    init(failing: Bool = false) { self.failing = failing }

    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        guard let tools else { throw AgentOperationError("canvas tools absent") }
        func execute(_ name: String, _ input: JSONValue, allowFailure: Bool = false) async throws -> JSONValue {
            let call = AgentToolCall(id: UUID().uuidString, name: name, argumentsJSON: try input.encodedText())
            await onEvent(.assistantCompleted(.init(role: .assistant, content: "", toolCalls: [call])))
            await onEvent(.toolStarted(call))
            let result = await tools.execute(call: call)
            await onEvent(.toolCompleted(callId: call.id, name: name, result: result))
            if result.isFailure && !allowFailure { throw AgentOperationError(result.content) }
            return try JSONValue.decode(jsonText: result.content)
        }
        func node(_ result: JSONValue) throws -> JSONValue {
            guard let value = result["nodes"]?.arrayValue?.first else { throw AgentOperationError("node receipt absent") }
            return value
        }
        do {
            let text = try node(await execute("canvas_create_node",
                ["kind": "text", "text": failing ? "CANVAS_AGENT_FAIL" : "海边灯塔，镜头缓缓推进", "x": 80, "y": 80]))
            let image = try node(await execute("canvas_create_node",
                ["kind": "image", "text": failing ? "CANVAS_AGENT_FAIL" : "晨光中的灯塔",
                 "x": 480, "y": 80, "parent_ids": [text["node_id"]!]]))
            let catalog = try await execute("canvas_list_models", [:])
            guard catalog["models"]?.arrayValue?.contains(where: { $0["id"] == "seedream45" }) == true else {
                throw AgentOperationError("actual model catalog absent")
            }
            let rejected = try await execute("canvas_configure_node", ["node_id": image["node_id"]!,
                "expected_revision": image["node_revision"]!, "model": "gpt2"], allowFailure: true)
            guard rejected["ok"] == false else { throw AgentOperationError("invented model ID was accepted") }
            _ = try await execute("canvas_configure_node", ["node_id": image["node_id"]!,
                "expected_revision": image["node_revision"]!, "model": "seedream45",
                "ratio": "16:9", "resolution": "2K", "count": failing ? 1 : 2])
            var ids: [JSONValue] = [image["node_id"]!]
            if !failing {
                let video = try node(await execute("canvas_create_node", ["kind": "video",
                    "text": "摄像机向灯塔缓慢推进", "x": 1100, "y": 80, "parent_ids": [image["node_id"]!]]))
                _ = try await execute("canvas_configure_node", ["node_id": video["node_id"]!,
                    "expected_revision": video["node_revision"]!, "model": "seedance2-mini",
                    "ratio": "16:9", "resolution": "720p", "count": 1])
                ids.append(video["node_id"]!)
            }
            let current = try await execute("canvas_current", [:])
            receipt = try await execute("canvas_generate", ["node_ids": .array(ids),
                "expected_graph_revision": current["graph_revision"]!], allowFailure: failing)
            let answer = AgentMessage(role: .assistant, content: failing
                ? "生成服务失败，没有生成图片。" : "已生成两张灯塔图片和一段视频，产物已保存到画布。")
            await onEvent(.assistantCompleted(answer))
            return [answer]
        } catch { failure = error.localizedDescription; throw error }
    }
}
#endif
