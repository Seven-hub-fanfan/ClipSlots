import Foundation
@testable import ClipSlotsKit

private actor TaskGatewayTransport: AgentGatewayTransport {
    let binding: AgentRunBinding
    private var frames: [Data]
    private(set) var requests: [URLRequest] = []
    private(set) var streams: [URLRequest] = []
    init(binding: AgentRunBinding, frames: [Data]) { self.binding = binding; self.frames = frames }
    func enqueue(_ frames: [Data]) { self.frames += frames }
    func send(request: URLRequest) async throws -> AgentGatewayHTTPResponse {
        requests.append(request)
        let value: JSONValue = ["schemaVersion": 1,
            "binding": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(binding)),
            "runID": "task-run", "phase": "streaming",
            "requestKey": request.value(forHTTPHeaderField: "Idempotency-Key").map(JSONValue.string) ?? .null]
        return .init(statusCode: 200, body: try JSONEncoder().encode(value))
    }
    func stream(request: URLRequest) async throws -> AgentHTTPStream {
        streams.append(request)
        let data = frames.removeFirst()
        return .init(statusCode: 200, chunks: AsyncThrowingStream { $0.yield(data); $0.finish() })
    }
}

func runTaskSubagentGatewayTests(_ t: TestRunner) {
    smokeAwait {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-gateway-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = URL(string: "https://task-gateway.fixture.invalid/v1")!
        let binding = AgentRunBinding(sessionID: "task-session")
        let message = UUID()
        func frame(_ type: String, _ id: String, _ payload: JSONValue) throws -> Data {
            let value: JSONValue = ["schemaVersion": 1,
                "binding": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(binding)),
                "runID": "task-run", "eventID": .string(id), "payload": payload]
            return Data("event: \(type)\nid: \(id)\ndata: ".utf8)
                + (try JSONEncoder().encode(value)) + Data("\n\n".utf8)
        }
        func child(_ phase: String, parent: String = "one", text: String? = nil) -> JSONValue {
            var payload: [String: JSONValue] = ["subagent_id": "child", "parent_tool_call_id": .string(parent),
                "phase": .string(phase), "agent_type": "分析", "task_description": "synthetic"]
            if let text { payload["text"] = .string(text) }
            return .object(payload)
        }
        do {
            let plan: JSONValue = ["schema_version": "agent_task_snapshot.v1", "plan_ready": true,
                "tasks": [["task_id": "one", "subject": "分析", "status": "in_progress"]]]
            let initial = try frame("initial", "initial", ["messageID": .string(message.uuidString)])
            let firstText = try frame("content", "body|1", ["messageID": .string(message.uuidString), "delta": "前🙂"])
            let task = try frame("task_snapshot", "plan|2", plan)
            let started = try frame("subagent_event", "child|3", child("started"))
            let content = try frame("subagent_event", "child|4", child("content", text: "分析正文🙂"))
            let transport = TaskGatewayTransport(binding: binding, frames: [initial + firstText + task + started + content])
            let gateway = AgentGatewayBackend(baseURL: base, binding: binding, journalRoot: root, transport: transport,
                timing: .init(sleep: { _ in throw CancellationError() }))
            do {
                _ = try await gateway.run(history: [], config: .init(model: "fixture"), tools: nil) { _ in }
                t.check(false, "TASK gateway incomplete stream cannot report completion")
            } catch {}
            let before = await gateway.snapshot
            t.equal(before.taskSubagents.entries.count, 2, "TASK gateway without canvas projects plan and child")
            t.equal(before.cursor, "child|4", "TASK gateway persists child state at exact cursor")
            t.equal(before.taskSubagents.entries[0].anchor?.contentBytes, "前🙂".utf8.count,
                    "TASK gateway anchors plan to durable body")
            let reopened = AgentGatewayBackend(baseURL: base, binding: binding, journalRoot: root, transport: transport,
                timing: .init(sleep: { _ in throw CancellationError() }))
            let restored = await reopened.snapshot
            t.equal(restored.taskSubagents, before.taskSubagents, "TASK SQLite reopen preserves projection atomically")
            let stopped = try frame("subagent_event", "child|5", child("stopped"))
            let successor = try frame("subagent_event", "child|6", child("started", parent: "two"))
            let late = try frame("subagent_event", "old|7", child("started"))
            let suffix = try frame("content", "body|8", ["messageID": .string(message.uuidString), "delta": "后"])
            let done = try frame("run_completed", "done", ["messageID": .string(message.uuidString)])
            await transport.enqueue([content + stopped + successor + late + suffix + done])
            _ = try await reopened.resume(history: [], config: .init(model: "fixture"), tools: nil) { _ in }
            let finished = await reopened.snapshot
            let children = finished.taskSubagents.entries.compactMap { entry -> AgentSubagentState? in
                if case .subagent(let state) = entry.content { return state }; return nil
            }
            t.equal(children.map(\.status), [.stopped, .endedUnknown], "TASK gateway parent done preserves stopped and unknown")
            t.equal(children.first?.text, "分析正文🙂", "TASK gateway reconnect replay does not duplicate child text")
            t.equal(children.last?.parentToolCallID, "two", "TASK gateway late old start cannot replace successor")
            t.equal(finished.messages.last?.content, "前🙂后", "TASK gateway received metadata does not enter model body")
            let requests = await transport.requests
            t.equal(requests.filter { $0.httpMethod == "POST" }.count, 1, "TASK gateway restart does not resubmit run")
            let streams = await transport.streams
            t.equal(streams.last?.value(forHTTPHeaderField: "Last-Event-ID"), "child|4",
                    "TASK gateway resumes after durable child cursor")

            // Readback is independent of transcript state, preserves all dirty
            // children and rejects a retired parent even when phase is started.
            var readback = AgentSubagentCanvasProjection()
            _ = try readback.receive(child("started"), eventID: "a", projectID: "project",
                conversationID: "session", runID: "run")
            _ = try readback.receive(child("stopped"), eventID: "b", projectID: "project",
                conversationID: "session", runID: "run")
            _ = try readback.receive(child("started", parent: "two"), eventID: "c", projectID: "project",
                conversationID: "session", runID: "run")
            let scope = readback.scopes["child"]
            let old = try readback.receive(child("started"), eventID: "old", projectID: "project",
                conversationID: "session", runID: "run")
            t.check(old == nil && readback.scopes["child"] == scope, "TASK readback retired start cannot replace successor scope")
            var other = child("started").objectValue!
            other["subagent_id"] = "other"
            _ = try readback.receive(.object(other), eventID: "other", projectID: "project",
                conversationID: "session", runID: "run")
            let encoded = try JSONEncoder().encode(readback)
            var readbackRestored = try JSONDecoder().decode(AgentSubagentCanvasProjection.self, from: encoded)
            t.equal(Set(readbackRestored.finishAll().compactMap { $0.source?.subagentID }), ["child", "other"],
                    "TASK readback restart flushes every dirty child")
            t.check(readbackRestored.finishAll().isEmpty, "TASK readback completed flush does not repeat")
        } catch { t.check(false, "TASK gateway unexpected error \(error)") }
    }
}
