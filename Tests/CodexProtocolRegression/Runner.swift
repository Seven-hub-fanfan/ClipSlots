import Foundation
import ClipSlotsKit

private final class FixtureTools: AgentToolExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func specs() -> [AgentToolSpec] {
        [AgentToolSpec(name: "list_slots", description: "list", parameters: ["type": "object"], originLabel: "test")]
    }
    func execute(call: AgentToolCall) async -> AgentToolResult {
        lock.withLock { count += 1 }
        return AgentToolResult(content: "{\"ok\":true,\"slots\":[]}", summary: "完成")
    }
}

private actor Events {
    var values: [AgentRunEvent] = []
    func append(_ event: AgentRunEvent) { values.append(event) }
}

@main
struct CodexProtocolRegression {
    static var checks = 0
    static var failures = 0
    static func check(_ condition: Bool, _ label: String) {
        checks += 1
        if !condition { failures += 1; print("FAIL: \(label)") }
    }

    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipslots-codex-tests-\(UUID())")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixture.py").path
        func configuration(_ mode: String) -> CodexServerConfiguration {
            .init(executable: "/usr/bin/python3", workingDirectory: root.path, codexHome: root.appendingPathComponent("auth").path,
                  arguments: [fixture, mode, root.appendingPathComponent(mode + ".jsonl").path])
        }
        func requests(_ mode: String) -> [JSONValue] {
            let text = (try? String(contentsOf: root.appendingPathComponent(mode + ".jsonl"))) ?? ""
            return text.split(separator: "\n").compactMap { try? JSONValue.decode(jsonText: String($0)) }
        }
        let tools = FixtureTools()
        let skillPath = root.appendingPathComponent("SKILL.md")
        try! "CODEX_SKILL_SNAPSHOT：按三个步骤整理。".write(to: skillPath, atomically: true, encoding: .utf8)
        let skillReference = try! AgentSkillReference.load(name: "fixture", path: skillPath.path)
        let user = AgentMessage(role: .user, content: "整理槽位", skillReferences: [skillReference])
        let config = AgentConfig(model: "")
        for mode in ["preview_tools", "preview_approval"] {
            do {
                var runtime = configuration(mode)
                runtime.interactiveRequests = true
                runtime.bridgeExecutable = "/not-executed"
                runtime.sandbox = "danger-full-access"
                let service = CodexAgentService(configuration: runtime)
                service.restoreSession("old-unrestricted-thread")
                var previewConfig = config
                previewConfig.canvasPreviewOnly = true
                let count = tools.calls
                let result = try await service.run(history: [user], config: previewConfig, tools: tools) { _ in }
                check(result.last?.content == "完成🙂", "\(mode) completes restricted turn")
                check(tools.calls == count, "\(mode) no tool execution")
                check(!requests(mode).contains { $0["method"]?.stringValue == "thread/resume" },
                      "\(mode) never resumes an unrestricted thread")
                check(requests(mode).first { $0["method"]?.stringValue == "thread/start" }?["params"]?["approvalPolicy"] == "never",
                      "\(mode) cannot escalate sandbox permissions")
                check(requests(mode).first { $0["method"]?.stringValue == "turn/start" }?["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue?.contains("CODEX_SKILL_SNAPSHOT") == true,
                      "\(mode) skill snapshot reaches restricted Codex turn")
            } catch { check(false, "\(mode): \(error.localizedDescription)") }
        }
        for mode in ["interactive_accept", "interactive_decline", "interactive_file", "interactive_questions",
                     "interactive_cancel", "interactive_expire", "interactive_disconnect", "interactive_finish"] {
            var runtime = configuration(mode)
            runtime.interactiveRequests = true
            runtime.interactionTimeout = mode == "interactive_expire" ? 0.15 : 5
            let service = CodexAgentService(configuration: runtime)
            let events = Events()
            let run = Task { try await service.run(history: [user], config: config, tools: nil) { await events.append($0) } }
            let deadline = Date().addingTimeInterval(3)
            var request: AgentInteraction?
            while request == nil && Date() < deadline {
                request = await events.values.compactMap { event in
                    if case .interactionRequested(let value) = event { return value }; return nil
                }.first
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let request else {
                run.cancel(); _ = try? await run.value
                check(false, "\(mode) request surfaced"); continue
            }
            check(!requests(mode).contains { $0["id"]?.intValue == 93 }, "\(mode) waits for actual user reply")
            do {
                let answer: JSONValue = mode == "interactive_questions"
                    ? ["answers": ["style": ["answers": ["自然"]], "note": ["answers": ["私密答案"]]]]
                    : ["decision": .string(mode == "interactive_decline" ? "decline" : "accept")]
                if mode == "interactive_cancel" {
                    run.cancel()
                } else if !["interactive_expire", "interactive_disconnect", "interactive_finish"].contains(mode) {
                    if mode == "interactive_questions" {
                        let invalid = try await request.respond(["answers": [:]])
                        check(!invalid && request.isPending, "incomplete answers cannot resume turn")
                    }
                    let accepted = try await request.respond(answer)
                    let duplicate = try await request.respond(answer)
                    check(accepted && !duplicate, "\(mode) answers once")
                }
                do {
                    let messages = try await run.value
                    check(!["interactive_cancel", "interactive_expire", "interactive_disconnect"].contains(mode)
                          && messages.last?.content == "完成🙂", "\(mode) completion")
                } catch {
                    check(["interactive_cancel", "interactive_expire", "interactive_disconnect"].contains(mode),
                          "\(mode) interrupted: \(error.localizedDescription)")
                    if mode == "interactive_expire" { check(error.localizedDescription.contains("超时"), "interaction deadline explicit") }
                }
                let stale = try await request.respond(answer)
                check(!stale && !request.isPending, "\(mode) stale card invalidated")
                let surfaced = await events.values.filter { if case .interactionRequested = $0 { return true }; return false }.count
                check(surfaced == 1, "\(mode) repeated RPC does not duplicate interaction")
                check(requests(mode).filter { $0["id"]?.intValue == 93 }.count <= 1, "\(mode) one protocol response maximum")
            } catch { run.cancel(); _ = try? await run.value; check(false, "\(mode): \(error.localizedDescription)") }
        }
        await automationChecks(root: root)
        do {
            let server = CodexAppServer()
            try await server.start(configuration("projects"))
            try await CodexWorkspaceAPI.createProject(server, name: "测试项目", path: root.path, key: "test-project")
            var projects = try await CodexWorkspaceAPI.projects(server, threads: [])
            check(projects.count == 1 && projects.first?.name == "测试项目", "project create readback")
            try await CodexWorkspaceAPI.renameProject(server, id: "test-project", name: "重命名")
            projects = try await CodexWorkspaceAPI.projects(server, threads: [])
            check(projects.first?.name == "重命名", "project rename readback")
            try await CodexWorkspaceAPI.deleteProject(server, id: "test-project")
            projects = try await CodexWorkspaceAPI.projects(server, threads: [])
            check(projects.isEmpty, "project delete readback")
            await server.close()
            let service = CodexAgentService(configuration: configuration("review"),
                reviewTarget: ["type": "baseBranch", "branch": "main"])
            let result = try await service.run(history: [user], config: config, tools: nil) { _ in }
            check(result.last?.content.contains("边界条件") == true, "native review result rendered")
            check(!requests("review").contains { $0["method"]?.stringValue == "turn/start" },
                  "review uses official review/start")
        } catch { check(false, "new desktop protocols: \(error.localizedDescription)") }
        do {
            let service = CodexAgentService(configuration: configuration("normal"))
            let events = Events()
            let first = try await service.run(history: [user], config: config, tools: tools) { await events.append($0) }
            check(service.sessionID == "fixture-thread", "thread identifier retained")
            check(first.last?.content == "完成🙂", "fragmented Unicode answer preserved")
            check(first.last?.reasoning == "已查看槽位摘要。", "reasoning summary persists with reply")
            check(first.filter { $0.role == .tool }.count == 1 && tools.calls == 1, "one tool execution and result")
            let recorded = await events.values
            check(recorded.contains { if case .sessionStarted = $0 { return true }; return false }, "thread persisted through event")
            check(recorded.contains { if case .contentDelta("完成🙂") = $0 { return true }; return false }, "stream delta before completion")
            check(recorded.contains { if case .usage(let usage) = $0 { return usage.promptTokens == 100 && usage.completionTokens == 20 }; return false },
                  "Codex token usage is displayed")
            _ = try await service.run(history: [user] + first + [AgentMessage(role: .user, content: "再看看")],
                                      config: config, tools: tools) { _ in }
            check(requests("normal").filter { $0["method"]?.stringValue == "thread/start" }.count == 1, "start once")
            check(requests("normal").filter { $0["method"]?.stringValue == "thread/resume" }.count == 1, "resume next turn")
            let turns = requests("normal").filter { $0["method"]?.stringValue == "turn/start" }
            check(turns.first?["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue?.contains("CODEX_SKILL_SNAPSHOT") == true,
                  "normal Codex turn receives explicit skill snapshot")
            check(turns.last?["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue == "再看看", "resume does not replay history")
            let restored = CodexAgentService(configuration: configuration("normal"))
            restored.restoreSession(service.sessionID)
            _ = try await restored.run(history: [AgentMessage(role: .user, content: "重启后继续")],
                                        config: config, tools: tools) { _ in }
            check(requests("normal").filter { $0["method"]?.stringValue == "thread/resume" }.count == 2, "new backend restores saved thread")
            restored.restoreSession(nil)
            let past = AgentMessage(role: .user, content: "过去的上下文", attachments: [
                AgentAttachment(path: "/tmp/prior.md", name: "prior.md")
            ])
            _ = try await restored.run(history: [past, AgentMessage(role: .assistant, content: "另一后端的回答"), user],
                                       config: config, tools: tools) { _ in }
            let imported = requests("normal").last { $0["method"]?.stringValue == "turn/start" }?["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue ?? ""
            check(imported.contains("过去的上下文") && imported.contains("另一后端的回答") && imported.contains("/tmp/prior.md"),
                  "rebuilt Codex thread imports intervening history and file references")
        } catch { check(false, "normal flow: \(error.localizedDescription)") }

        for mode in ["denied", "unsupported"] {
            do {
                let before = tools.calls
                let service = CodexAgentService(configuration: configuration(mode))
                let messages = try await service.run(history: [user], config: config, tools: tools) { _ in }
                check(messages.last?.content == "完成🙂", "\(mode) request does not hang")
                check(tools.calls == before, "\(mode) does not execute arbitrary tools")
            } catch { check(false, "\(mode): \(error.localizedDescription)") }
        }
        for mode in ["unauthenticated", "failure", "malformed", "abrupt"] {
            let start = Date()
            let service = CodexAgentService(configuration: configuration(mode))
            do {
                _ = try await service.run(history: [user], config: config, tools: tools) { _ in }
                check(false, "\(mode) must fail")
            } catch {
                check(Date().timeIntervalSince(start) < 5, "\(mode) fails promptly")
                if mode == "failure" { check(error.localizedDescription.contains("fixture quota exhausted"), "server error preserved") }
                if mode == "unauthenticated" {
                    check(!requests(mode).contains { $0["method"]?.stringValue == "turn/start" }, "no inference before login")
                }
                if mode == "malformed" || mode == "abrupt" {
                    check(service.sessionID == nil, "\(mode) does not persist an unusable unstarted thread")
                }
            }
        }
        do {
            let service = CodexAgentService(configuration: configuration("hang"))
            let run = Task { try await service.run(history: [user], config: config, tools: tools) { _ in } }
            let deadline = Date().addingTimeInterval(5)
            while !requests("hang").contains(where: { $0["method"]?.stringValue == "turn/start" }) && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let start = Date()
            run.cancel()
            do { _ = try await run.value; check(false, "cancel should throw") }
            catch { check(error is CancellationError, "cancel classified correctly") }
            check(Date().timeIntervalSince(start) < 3, "cancel idle stream without waiting for output")
        } catch { check(false, "cancel: \(error.localizedDescription)") }

        let server = CodexAppServer()
        do {
            try await server.start(configuration("rpc"))
            async let one = server.request("test/one")
            async let two = server.request("test/two")
            let results = try await (one, two)
            check(results.0["order"]?.intValue == 1 && results.1["order"]?.intValue == 2, "out of order replies routed by id")
            do { _ = try await server.request("test/timeout", timeout: 0.1); check(false, "request timeout") }
            catch { check(error.localizedDescription.contains("超时"), "silent RPC timeout") }
        } catch { check(false, "RPC: \(error.localizedDescription)") }
        await server.close()
        let cli = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("ClipSlotsCLI").path
        if FileManager.default.isExecutableFile(atPath: cli) {
            let dataRoot = root.appendingPathComponent("slot-data").path
            let registry = AgentToolRegistry(builtin: AgentBuiltinTools(cliPath: cli, runner: { path, arguments in
                await AgentProcessRunner.run(executable: "/usr/bin/env",
                    arguments: ["CLIPSLOTS_DATA_DIR=\(dataRoot)", path] + arguments)
            }))
            do {
                let service = CodexAgentService(configuration: configuration("slot_write"))
                let messages = try await service.run(history: [user], config: config, tools: registry) { _ in }
                check(messages.contains { $0.role == .tool && !$0.isFailure }, "Codex tool bridge reaches real ClipSlots CLI")
                let read = await registry.execute(call: AgentToolCall(id: "read", name: "read_slot", argumentsJSON: "{\"slot\":1}"))
                check(!read.isFailure && read.content.contains("Codex 工具联动验证"), "real isolated slot write verified by read-back")
            } catch { check(false, "real slot tools: \(error.localizedDescription)") }
        } else { check(false, "build ClipSlotsCLI before protocol integration tests") }
        let image = AgentAttachment(path: "/tmp/reference.png", name: "参考图.png")
        let attachment = AgentAttachment(path: "/tmp/notes.md", name: "notes.md")
        let input = CodexAgentService.input(for: AgentMessage(role: .user, content: "分析", attachments: [image, attachment]))
        check(input.count == 2 && input.last?["type"]?.stringValue == "localImage", "only images become image input")
        check(input.first?["text"]?.stringValue?.contains("/tmp/notes.md") == true, "file reference passed explicitly")
        do {
            var json = try JSONEncoder().encode(user)
            var value = try JSONSerialization.jsonObject(with: json) as! [String: Any]
            value.removeValue(forKey: "attachments")
            json = try JSONSerialization.data(withJSONObject: value)
            let legacy = try JSONDecoder().decode(AgentMessage.self, from: json)
            check(legacy.attachments == nil && legacy.content == user.content, "legacy conversations decode")
        } catch { check(false, "legacy decode: \(error.localizedDescription)") }

        for mode in ["custom", "busy"] {
            let service = CodexAgentService(configuration: configuration(mode))
            if mode == "busy" { service.restoreSession("fixture-thread") }
            do {
                _ = try await service.run(history: [user], config: config, tools: tools) { _ in }
                check(mode == "custom", "custom provider proceeds without OpenAI login")
            } catch { check(mode == "busy" && error.localizedDescription.contains("另一个客户端"), "active desktop thread refused") }
            if mode == "busy" {
                check(!requests(mode).contains { $0["method"]?.stringValue == "turn/start" }, "no overlapping remote turn")
            }
        }
        for mode in ["pages", "legacy", "cursor_loop"] {
            let server = CodexAppServer()
            do {
                try await server.start(configuration(mode))
                let threads = try await CodexWorkspaceAPI.threads(server)
                check(mode != "cursor_loop" && threads.count == 2, "thread pages merged")
                let projects = try await CodexWorkspaceAPI.projects(server, threads: threads)
                check(projects.count == 1 && !projects[0].isOfficial, "old engine derives unique projects from cwd")
                let (thread, messages) = try await CodexWorkspaceAPI.history(server, id: "fixture-thread")
                check(thread.provider == "custom" && thread.model == "custom-model", "thread config preserved")
                check(mode == "legacy" ? messages.count == 1 && messages[0].content == "旧版历史"
                      : messages.map(\.content) == ["桌面消息", "桌面答复"], "paginated and legacy history hydrated")
                let (_, again) = try await CodexWorkspaceAPI.history(server, id: "fixture-thread")
                check(messages.map(\.id) == again.map(\.id), "stable history identities across refresh")
                check(!requests(mode).contains { ["thread/resume", "turn/start"].contains($0["method"]?.stringValue ?? "") },
                      "browsing history never resumes or starts inference")
            } catch { check(mode == "cursor_loop" && error.localizedDescription.contains("重复"), "pagination failure is explicit: \(mode)") }
            await server.close()
        }
        do {
            var fallback = configuration("fallback")
            fallback.executable = "/missing/codex"
            fallback.fallbackExecutable = "/usr/bin/python3"
            let connection = try await CodexConnection.open(fallback)
            check(connection.executable == "/usr/bin/python3" && connection.fallbackReason != nil, "invalid engine falls back before inference")
            await connection.server.close()
        } catch { check(false, "fallback: \(error.localizedDescription)") }
        let summary = CodexWorkspaceAPI.transcript([
            ["id": "r", "type": "reasoning", "summary": ["公开摘要"], "content": ["SECRET_RAW_REASONING"]],
            ["id": "future", "type": "futureItem"]
        ], threadID: "test")
        check(summary.first?.reasoning == "公开摘要" && !summary.contains { $0.content.contains("SECRET") },
              "raw reasoning excluded from imported display")
        check(summary.last?.content.contains("暂不支持") == true, "future history item remains visible as unsupported")
        let mcpDenied = await AgentMCPServer.response(to: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "disabled_tool", "arguments": [:]]], tools: tools)
        check(mcpDenied?["result"]?["isError"]?.boolValue == true, "MCP disabled tool rejected")
        if FileManager.default.isExecutableFile(atPath: cli) {
            let messages: [JSONValue] = [
                ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]],
                ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]],
                ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                 "params": ["name": "write_slot", "arguments": ["slot": 1, "text": "MCP 隔离写入"]]],
                ["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                 "params": ["name": "read_slot", "arguments": ["slot": 1]]]
            ]
            let process = await AgentProcessRunner.run(executable: "/usr/bin/env",
                arguments: ["CLIPSLOTS_DATA_DIR=\(root.appendingPathComponent("mcp-data").path)", cli, "agent-mcp", "[]"],
                standardInput: messages.compactMap { try? $0.encodedText() }.joined(separator: "\n") + "\n")
            let responses = process.stdout.split(separator: "\n").compactMap { try? JSONValue.decode(jsonText: String($0)) }
            check(process.succeeded && responses.count == 4, "real stdio MCP handshake and tool responses")
            check(responses.last?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("MCP 隔离写入") == true,
                  "MCP slot write verified by real isolated read")
        }

        if let binary = ProcessInfo.processInfo.environment["CODEX_TEST_EXECUTABLE"] {
            let actual = CodexAppServer()
            do {
                let home = root.appendingPathComponent("official-empty-home")
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                try await actual.start(.init(executable: binary, workingDirectory: root.path, codexHome: home.path))
                let account = try await actual.request("account/read", params: ["refreshToken": false])
                check(account["account"] == .null, "official server uses isolated unauthenticated home")
                do {
                    try await CodexWorkspaceAPI.createProject(actual, name: "Temporary regression", path: root.path, key: UUID().uuidString)
                    let projects = try await CodexWorkspaceAPI.projects(actual, threads: [])
                    check(projects.count == 1, "official project create in isolated home")
                    if let project = projects.first {
                        try await CodexWorkspaceAPI.renameProject(actual, id: project.id, name: "Renamed regression")
                        let renamed = try await CodexWorkspaceAPI.projects(actual, threads: [])
                        check(renamed.first?.name == "Renamed regression", "official project rename readback")
                        try await CodexWorkspaceAPI.deleteProject(actual, id: project.id)
                        let removed = try await CodexWorkspaceAPI.projects(actual, threads: [])
                        check(removed.isEmpty, "official project delete readback")
                    }
                } catch let error as CodexServerError where error.isUnsupported {
                    print("Official engine does not expose project CRUD; UI reports this explicitly.")
                }
                let models = try await actual.request("model/list", params: ["limit": 100])
                check(models["data"]?.arrayValue != nil, "official model catalog shape")
                let thread = try await actual.request("thread/start", params: [
                    "cwd": .string(root.path), "sandbox": "read-only", "approvalPolicy": "never",
                    "dynamicTools": [CodexAgentService.bridgeTool], "experimentalRawEvents": false,
                    "config": ["mcp_servers.clipslots": [
                        "command": .string(cli), "args": ["agent-mcp", "[]"],
                        "env": ["CLIPSLOTS_DATA_DIR": .string(root.appendingPathComponent("official-mcp-data").path)]
                    ]]
                ])
                check(thread["thread"]?["id"]?.stringValue != nil, "official server accepts bridge schema without inference")
                let mcp = try await actual.request("mcpServerStatus/list",
                    params: ["threadId": thread["thread"]?["id"] ?? .null])
                let connected = mcp["data"]?.arrayValue?.first { $0["name"]?.stringValue == "clipslots" }
                check(connected?["tools"]?["read_slot"] != nil, "official engine discovers ClipSlots MCP tools")
                check(!FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path),
                      "no credential file created")
            } catch { check(false, "official handshake: \(error.localizedDescription)") }
            await actual.close()
            if ProcessInfo.processInfo.environment["CODEX_TEST_READ_DESKTOP"] == "1" {
                let desktop = CodexAppServer()
                do {
                    try await desktop.start(.init(executable: binary, workingDirectory: root.path))
                    let configuration = CodexWorkspaceSettings(try await desktop.request("config/read", params: ["includeLayers": false]))
                    let threads = try await CodexWorkspaceAPI.threads(desktop)
                    let projects = try await CodexWorkspaceAPI.projects(desktop, threads: threads)
                    check(!configuration.model.isEmpty, "real desktop effective model readable")
                    if let first = threads.first {
                        let (thread, messages) = try await CodexWorkspaceAPI.history(desktop, id: first.id)
                        check(thread.id == first.id && !messages.isEmpty, "real desktop history readable without resuming")
                        print("Desktop read-only: \(threads.count) threads, \(projects.count) projects, selected history \(messages.count) items.")
                    }
                    let skills = try await desktop.request("skills/list", params: ["cwds": [.string(root.path)]])
                    check(skills["data"]?.arrayValue != nil, "real desktop skill catalog readable")
                } catch { check(false, "desktop read-only: \(error.localizedDescription)") }
                await desktop.close()
            }
        }
        print("Codex protocol: \(checks) checks, \(failures) failures. No paid requests.")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor static func automationChecks(root: URL) {
        do {
            let url = root.appendingPathComponent("schedules/tasks.json")
            let store = try CodexAutomationStore(url: url)
            var task = CodexAutomation()
            task.name = "检查项目"; task.prompt = "只读检查"; task.cwd = root.path
            task.frequency = .once; task.nextRun = Date().addingTimeInterval(-10)
            try store.save(task)
            check(try CodexAutomationStore(url: url).state.tasks == [task], "schedule durable save")
            let now = Date()
            let record = try store.claim(task.id, now: now, scheduled: true)!
            check(store.state.tasks.first?.enabled == false, "once schedule disabled before execution")
            check(try store.claim(task.id, now: now, scheduled: false) == nil, "no overlapping schedule execution")
            do { try store.remove(task.id); check(false, "delete running task refused") }
            catch { check(true, "delete running task refused") }
            try store.updateRun(record.id, threadID: "run-thread")
            let recovered = try CodexAutomationStore(url: url)
            check(recovered.state.runs.first?.status == .interrupted && recovered.state.runs.first?.threadID == "run-thread",
                  "crashed run interrupted, thread preserved, no automatic replay")
            try recovered.updateRun(record.id, status: .completed, output: "结果")
            check(try CodexAutomationStore(url: url).state.runs.first?.output == "结果", "schedule result durable readback")
            try recovered.remove(task.id)
            check(recovered.state.tasks.isEmpty && recovered.state.runs.count == 1, "delete schedule retains history")
            task.cwd = "/nonexistent-schedule-dir"
            do { try recovered.save(task); check(false, "invalid directory refused") }
            catch { check(recovered.state.tasks.isEmpty, "invalid directory leaves storage unchanged") }
            task.cwd = root.path; task.enabled = true; task.frequency = .daily
            task.timeZoneID = "America/New_York"
            let formatter = ISO8601DateFormatter()
            task.nextRun = formatter.date(from: "2026-03-07T14:00:00Z")! // 09:00 EST before DST.
            task.advance(after: formatter.date(from: "2026-03-08T12:00:00Z")!)
            check(task.nextRun == formatter.date(from: "2026-03-08T13:00:00Z")!, "daily time preserved through DST")
            task.frequency = .weekly
            task.advance(after: formatter.date(from: "2026-03-22T15:00:00Z")!)
            check(task.nextRun == formatter.date(from: "2026-03-29T13:00:00Z")!, "missed weeks skip backlog")
            let file = root.appendingPathComponent("not-a-directory")
            try Data().write(to: file)
            let broken = try CodexAutomationStore(url: file.appendingPathComponent("tasks.json"))
            do { try broken.save(task); check(false, "failed disk write refused") }
            catch { check(broken.state.tasks.isEmpty, "failed disk write never publishes task") }
        } catch { check(false, "schedule storage: \(error.localizedDescription)") }
    }
}
