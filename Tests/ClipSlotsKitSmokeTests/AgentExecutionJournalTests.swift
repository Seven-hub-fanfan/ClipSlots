import Foundation
import ClipSlotsKit

private final class JournalFileTools: AgentToolExecuting, @unchecked Sendable {
    let file: URL
    private let lock = NSLock()
    private var executions = 0
    var enabled = true
    var count: Int { lock.lock(); defer { lock.unlock() }; return executions }
    init(file: URL) { self.file = file }
    func specs() -> [AgentToolSpec] {
        enabled ? [.init(name: "write_fixture", description: "fixture",
            parameters: ["type": "object", "properties": ["text": ["type": "string"]],
                         "required": ["text"], "additionalProperties": false], originLabel: "test")] : []
    }
    func execute(call: AgentToolCall) async -> AgentToolResult {
        lock.lock(); executions += 1; lock.unlock()
        do {
            let text = try call.arguments()["text"]?.stringValue ?? ""
            try Data(text.utf8).write(to: file)
            try await Task.sleep(for: .milliseconds(60))
            return .init(content: #"{"ok":true}"#, summary: "written")
        } catch { return .failure(error.localizedDescription) }
    }
}

func runAgentExecutionJournalTests(_ t: TestRunner) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scope = AgentExecutionScope(sessionID: "session", projectID: "项目🙂", turnID: "turn")
        let journal = AgentExecutionJournal(root: root)
        let call = AgentToolCall(id: "call", name: "write_fixture", argumentsJSON: #"{"text":"第一次🙂"}"#)
        let base = JournalFileTools(file: root.appendingPathComponent("output.txt"))
        let wrapper = AgentJournaledTools(base: base, journal: journal, scope: scope)
        let results: [(Bool, String)] = smokeAwait {
            var checks: [(Bool, String)] = []
            let first = await wrapper.execute(call: call)
            checks.append((!first.isFailure && base.count == 1, "JOURNAL writes through actual executor"))
            do {
                try Data("用户后续编辑".utf8).write(to: base.file)
                let restarted = AgentJournaledTools(base: base, journal: AgentExecutionJournal(root: root), scope: scope)
                let replay = await restarted.execute(call: call)
                checks.append((replay == first && base.count == 1
                    && (try? String(contentsOf: base.file)) == "用户后续编辑",
                    "JOURNAL process restart replay returns result without overwriting user edits"))
                let changed = await restarted.execute(call: .init(id: call.id, name: call.name,
                    argumentsJSON: #"{"text":"changed"}"#))
                checks.append((changed.isFailure && base.count == 1,
                    "JOURNAL same execution ID with changed arguments never runs"))
                let concurrent = AgentToolCall(id: "race", name: call.name, argumentsJSON: call.argumentsJSON)
                async let a = wrapper.execute(call: concurrent)
                async let b = restarted.execute(call: concurrent)
                let pair = await [a, b]
                checks.append((pair.contains { !$0.isFailure } && base.count == 2,
                    "JOURNAL concurrent reservations across independent objects execute once"))
                let pending = AgentToolCall(id: "crashed", name: call.name, argumentsJSON: call.argumentsJSON)
                _ = try journal.reserve(scope: scope, call: pending)
                let unknown = await restarted.execute(call: pending)
                checks.append((unknown.isFailure && unknown.content.contains("EXECUTION_UNKNOWN") && base.count == 2,
                    "JOURNAL interrupted side effect is unknown and never blindly repeated"))
                base.enabled = false
                let revoked = await restarted.execute(call: call)
                checks.append((revoked.isFailure && base.count == 2,
                    "JOURNAL revoked tool permission is checked before returning recorded data"))
                base.enabled = true
                let other = AgentJournaledTools(base: base, journal: journal,
                    scope: .init(sessionID: "session", projectID: "other", turnID: "turn"))
                _ = await other.execute(call: call)
                checks.append((base.count == 3, "JOURNAL same call ID in another project has distinct identity"))
                let preview = AgentPreviewTools.restricted(wrapper)
                let denied = await preview.execute(call: call)
                checks.append((preview.specs().isEmpty && denied.isFailure && base.count == 3,
                    "JOURNAL decoration cannot smuggle writing tools into canvas preview"))
            } catch { checks.append((false, "JOURNAL async fixture \(error)")) }
            return checks
        }
        results.forEach { t.check($0.0, $0.1) }
        let records = try AgentExecutionJournal(root: root).records(scope: scope)
        t.equal(records.count, 3, "JOURNAL durable record identity remains stable between encoders")
        t.equal(records.filter { $0.phase == .completed }.count, 2, "JOURNAL completed and executing phases stay distinct")
        let stored = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("tool-executions"), includingPropertiesForKeys: nil)
        t.equal(stored.count, 2, "JOURNAL scope hashing separates projects")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
        for file in files {
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            t.equal(mode?.intValue, 0o600, "JOURNAL execution records are private")
        }
        guard let corrupt = files.first else { t.check(false, "JOURNAL record file missing"); return }
        let corruptScope = try JSONDecoder().decode(AgentExecutionJournal.Record.self, from: Data(contentsOf: corrupt)).scope
        try Data("corrupt".utf8).write(to: corrupt)
        t.expectThrows("JOURNAL corrupt records never reset into a fresh execution") {
            _ = try AgentExecutionJournal(root: root).records(scope: corruptScope)
        }
        t.equal(try String(contentsOf: corrupt), "corrupt", "JOURNAL failed decoding preserves original file")
    } catch { t.check(false, "JOURNAL setup \(error)") }
}
