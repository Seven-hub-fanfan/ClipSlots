import Foundation
import Darwin
@testable import ClipSlotsKit

private actor Artifacts {
    var context: AgentAppReplyToolContext?
    var payload: JSONValue?
    func receive(_ event: AgentRunEvent) {
        if case .artifactUpdated(let value, let captured) = event { payload = value; context = captured }
    }
}

private final class CrashAfterReceipt: AgentGatewayScopedToolRecovering, @unchecked Sendable {
    let base: AgentGatewayRecoverableTools
    var executionScope: AgentExecutionScope { base.executionScope }
    init(_ base: AgentGatewayRecoverableTools) { self.base = base }
    func specs() -> [AgentToolSpec] { base.specs() }
    func execute(call: AgentToolCall) async -> AgentToolResult {
        _ = await base.execute(call: call)
        kill(getpid(), SIGKILL)
        return .failure("unreachable", code: "TEST")
    }
    func recoveredResult(call: AgentToolCall) async throws -> AgentToolResult? {
        try await base.recoveredResult(call: call)
    }
    func recoveredResult(call: AgentToolCall, scope: AgentExecutionScope) async throws -> AgentToolResult? {
        try await base.recoveredResult(call: call, scope: scope)
    }
}

private struct Saved: Codable {
    let record: AgentAppReplySnapshot
    let context: AgentAppReplyToolContext
}

@main private enum Main {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let endpoint = URL(string: CommandLine.arguments[2])!
        let mode = CommandLine.arguments[3]
        guard root.path.contains("clipslots-app-reply-tools-"), endpoint.host == "127.0.0.1" else { exit(2) }
        let binding = AgentRunBinding(sessionID: "tools-session", projectID: "tools-project", canvasID: "tools-project")
        let runRoot = root.appendingPathComponent("reply-run")
        let executions = AgentExecutionJournal(root: root)
        let access = try AgentDirectoryAccess(url: root)
        let declarationChanged = mode == "changed"
        let directory = AgentDirectoryTools(base: AgentPreviewTools(), access: access,
            automaticWrites: !declarationChanged, onInteraction: { _ in })
        let config = AgentConfig(model: "synthetic", systemPrompt: "local test", maxToolRounds: 8)
        let saved: Saved
        if mode.hasPrefix("restore") {
            saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: root.appendingPathComponent("state.json")))
        } else {
            let original = AgentGatewayBackend(baseURL: endpoint, binding: binding,
                journalRoot: root.appendingPathComponent("original"), apiKeyProvider: { "app-reply-page-auth" })
            let originals = AgentGatewayRecoverableTools(base: AgentDirectoryTools(base: AgentPreviewTools(),
                access: access, automaticWrites: true, onInteraction: { _ in }),
                journal: executions, scope: .init(sessionID: binding.sessionID, projectID: binding.projectID, turnID: "user-turn"))
            let app: JSONValue = ["artifactID": "tools-app", "path": "apps/tool.html", "revision": 1,
                "content": "<p>tool test</p>", "mimeType": "text/html",
                "appReplyManifest": ["schemaVersion": 1, "manifestRevision": .string(String(repeating: "a", count: 64)),
                                     "actions": ["previs_reply"]]]
            let artifacts = Artifacts()
            _ = try await original.run(history: [.init(role: .user, content: "test:app-artifact:" + app.encodedText())],
                config: config, tools: originals, onEvent: { await artifacts.receive($0) })
            guard let context = await artifacts.context else { throw AgentAppReplyError.preflight }
            let originalBefore = try Data(contentsOf: AgentGatewayJournalStore(baseURL: endpoint, binding: binding,
                root: root.appendingPathComponent("original")).databaseFile)
            try originalBefore.write(to: root.appendingPathComponent("original-before.sqlite"))
            let origin = try AgentAppReplyOrigin(endpoint: endpoint, authority: context.authority)
            let replyID = UUID().uuidString.lowercased()
            let reply: JSONValue = ["reply_id": .string(replyID), "action": "previs_reply",
                "payload": ["write_file": ["path": "side-effect.txt", "content": "reply-file🙂",
                                           "expected_sha256": ""], "call_id": "same-call-id"]]
            let client = try AgentAppReplyClient(directory: root.appendingPathComponent("ledger"),
                                                 credential: { _ in "app-reply-page-auth" })
            let record = try await client.submit(.init(origin: origin, replyJSON: reply.encodedText()))
            saved = .init(record: record, context: context)
            try JSONEncoder().encode(saved).write(to: root.appendingPathComponent("state.json"), options: .atomic)
        }
        let backend = AgentGatewayBackend(baseURL: endpoint, binding: binding, journalRoot: runRoot,
                                          apiKeyProvider: { "app-reply-page-auth" })
        try await backend.attachAppReply(saved.record, toolContext: saved.context)
        let scope = AgentAppReplyToolContext.executionScope(binding: binding, replyID: saved.record.submission.replyID)
        let recoverable = AgentGatewayRecoverableTools(base: directory, journal: executions, scope: scope)
        let tools: AgentToolExecuting = mode == "crash-receipt" ? CrashAfterReceipt(recoverable) : recoverable
        var activated = false
        if mode != "no-activation" {
            // Intentionally attempted on restart: this must remain false and retain the old snapshot.
            activated = try await backend.activateAppReplyTools(tools, config: config)
        }
        var failure: String?
        do {
            _ = try await backend.resume(history: [], config: config, tools: tools, onEvent: { event in
                if mode == "crash-before-execute", case .toolStarted = event { kill(getpid(), SIGKILL) }
            })
        } catch { failure = String(describing: error) }
        let reconciledPhase = await backend.snapshot.phase
        if mode == "restore-receipt", reconciledPhase == "waiting_suspended" {
            // Separate explicit control action, after the ordinary resume only supplements the receipt.
            try await backend.prepareAppReplyContinuation()
            _ = try await backend.resume(history: [], config: config, tools: tools, onEvent: { _ in })
        }
        let snapshot = await backend.snapshot
        let receipts = try executions.records(scope: scope)
        let journalStore = AgentGatewayJournalStore(baseURL: endpoint, binding: binding, root: runRoot)
        let journal = try journalStore.load()
        let originalFile = AgentGatewayJournalStore(baseURL: endpoint, binding: binding,
            root: root.appendingPathComponent("original")).databaseFile
        let originalUnchanged = try Data(contentsOf: originalFile) == Data(contentsOf: root.appendingPathComponent("original-before.sqlite"))
        let sourceJournal = try AgentGatewayJournalStore(baseURL: endpoint, binding: binding,
            root: root.appendingPathComponent("original")).load()
        let database = try AgentGatewayJournalDatabase(file: journalStore.databaseFile, create: false)
        let schema = try database.scalar("PRAGMA user_version")
        try database.close()
        let output: [String: JSONValue] = [
            "mode": .string(mode), "activated": .bool(activated), "error": failure.map(JSONValue.string) ?? .null,
            "reconciledPhase": .string(reconciledPhase),
            "phase": .string(snapshot.phase), "scope": .string(scope.turnID),
            "owner": .string(journal.toolSnapshots?[scope.turnID]?.instanceID.uuidString ?? ""),
            "sourceOwner": .string(sourceJournal.toolSnapshots?[saved.context.submissionKey]?.instanceID.uuidString ?? ""),
            "originalUnchanged": .bool(originalUnchanged), "hostReceipts": .number(Double(receipts.count)),
            "file": (try? String(contentsOf: root.appendingPathComponent("side-effect.txt"), encoding: .utf8))
                .map(JSONValue.string) ?? .null,
            "tools": .array(snapshot.messages.filter { $0.role == .tool }.map { .string($0.content) })]
        var detailed = output
        detailed["schema"] = .number(Double(schema))
        detailed["messages"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(snapshot.messages))
        detailed["reservations"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(journal.tools))
        print(try JSONValue.object(detailed).encodedText())
    }
}
