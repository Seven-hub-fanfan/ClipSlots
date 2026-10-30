import Foundation
import Darwin
@testable import ClipSlotsKit

@main
struct JournalTestMain {
    static let service = URL(string: "https://journal.fixture.invalid/v1")!
    static let binding = AgentRunBinding(sessionID: "journal-fixture", projectID: "project", canvasID: "canvas")
    static let messageID = UUID(uuidString: "33D7A8DE-49BF-4C42-9DCC-3F72BEE95132")!
    static let boundaries = ["transaction-begin", "task-schema-written", "event-written", "tasks-archived", "tasks-written", "state-written", "messages-written",
                             "tools-written", "before-commit", "after-commit"]
    static var passed = 0
    static var failures: [String] = []

    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) rethrows {
        if try value() { passed += 1 }
        else { failures.append(name); print("FAIL: \(name)") }
    }
    static func store(_ root: URL) -> AgentGatewayJournalStore {
        .init(baseURL: service, binding: binding, root: root)
    }
    static func canonical(_ journal: AgentGatewayJournal) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(journal)
    }
    static func seed(_ root: URL, legacy: Bool = false) throws -> AgentGatewayJournal {
        let writer = store(root)
        var journal = try writer.load()
        journal.runID = "original-run"; journal.phase = "unknown"
        journal.messages = [.init(id: messageID, role: .assistant, content: "原文🙂",
                                 reasoning: "原思考🧪")]
        journal.currentAssistantID = messageID
        journal.ordinal = 1; journal.cursor = "original"
        journal.eventDigests = ["original": AgentGatewayJournalStore.digest(Data("original".utf8))]
        journal.command = .init(key: "unreceived-request", path: ["runs", "continue"],
                               body: ["fixture": "pending"], attempted: true)
        journal.tools = ["execution": .init(request: .init(executionID: "execution", callID: "call",
            name: "fixture_tool", argumentsJSON: "{}", targetClientInstanceID: journal.clientInstanceID,
            expiresAt: 4_000_000_000), phase: "completed", content: "待补交的结果🙂",
            isFailure: false, summary: "summary", submissionKey: "submission")]
        journal.artifactUpdates = [["artifactID": "original-artifact", "revision": 1]]
        var projection = AgentTaskSubagentProjection()
        _ = try projection.receiveSubagent(["schema_version": "subagent_event.v1", "phase": "content",
            "subagent_id": "child", "parent_tool_call_id": "parent", "text": "原子任务🙂"],
            eventID: "original", runID: "original-run", anchor: nil, now: Date(timeIntervalSince1970: 10))
        journal.taskSubagents = projection
        if legacy {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try canonical(journal).write(to: writer.file, options: .atomic)
        } else {
            let lock = try writer.acquire()
            defer { writer.release(lock) }
            try writer.save(journal)
        }
        return journal
    }
    static func next(_ journal: AgentGatewayJournal) throws -> AgentGatewayJournal {
        var value = journal
        value.messages[0].content += "新增中文🙂"
        value.messages[0].reasoning = (value.messages[0].reasoning ?? "") + "新增推理🧪"
        value.ordinal += 1; value.cursor = "new-event"
        value.eventDigests["new-event"] = AgentGatewayJournalStore.digest(Data("new-event".utf8))
        value.phase = "waiting_confirmation"
        value.pendingInteraction = ["fixture": "interaction"]
        value.tools["new-tool"] = .init(request: .init(executionID: "new-tool", callID: "new-call",
            name: "fixture_tool", argumentsJSON: "{}", targetClientInstanceID: value.clientInstanceID,
            expiresAt: 4_000_000_000), phase: "reserved", submissionKey: "submission")
        value.artifactUpdates = (value.artifactUpdates ?? []) + [["artifactID": "new-artifact", "revision": 2]]
        value.canvasMutations = [["mutation_id": "new-mutation", "changes": []]]
        _ = try value.taskSubagents?.receiveSubagent(["schema_version": "subagent_event.v1", "phase": "content",
            "subagent_id": "child", "parent_tool_call_id": "parent", "text": "新增子任务🙂"],
            eventID: "new-event", runID: "original-run", anchor: nil, now: Date(timeIntervalSince1970: 20))
        return value
    }
    static func child(_ root: URL, mode: String, boundary: String = "") throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [mode, root.path, boundary]
        var environment = ProcessInfo.processInfo.environment
        environment["CLIPSLOTS_DATA_DIR"] = root.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
    static func downgradeFixtureToV2(_ root: URL, original: AgentGatewayJournal) throws {
        let db = try AgentGatewayJournalDatabase(file: store(root).databaseFile, create: false)
        var header = original
        header.messages = []; header.eventDigests = [:]; header.tools = [:]
        header.toolSnapshots = nil; header.artifactUpdates = nil
        header.canvasMutations = nil; header.canvasReadbacks = nil
        try db.execute("BEGIN IMMEDIATE")
        try db.putValue("header", data: canonical(header))
        try db.putValue("task_presence", data: nil)
        try db.execute("""
            DROP TABLE task_entries; DROP TABLE task_chunks; DROP TABLE task_receipts;
            PRAGMA user_version=2;
            COMMIT;
            """)
        try db.close()
    }
    static func controlReplacement(_ journal: AgentGatewayJournal) throws -> AgentGatewayJournal {
        var changed = journal
        var entries = changed.taskSubagents!.entries
        if case .subagent(var state) = entries[0].content {
            state.text = "替换🙂"; state.timeline = [.text(state.text)]
            entries[0].content = .subagent(state)
        }
        changed.taskSubagents = try .init(journalEntries: entries, receipts: changed.taskSubagents!.journalReceipts)
        return changed
    }
    static func controlKilled(_ root: URL, _ boundary: String, v2: Bool) throws {
        let original = try seed(root)
        if v2 { try downgradeFixtureToV2(root, original: original) }
        let inspect = try AgentGatewayJournalDatabase(file: store(root).databaseFile, create: false)
        let oldHeader = try inspect.value("header")
        try inspect.close()
        let process = try child(root, mode: "control-crash", boundary: boundary)
        process.waitUntilExit()
        try check(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL,
                  "control \(v2 ? "v2" : "v3") \(boundary) reaches real crash boundary")
        let committed = boundary == "after-commit"
        try check(canonical(store(root).load()) == canonical(committed ? controlReplacement(original) : original),
                  "control \(v2 ? "v2" : "v3") \(boundary) recovers entire predecessor or replacement")
        let after = try AgentGatewayJournalDatabase(file: store(root).databaseFile, create: false)
        if committed {
            if v2 {
                try check(Data(after.textScalar("SELECT payload FROM archive WHERE kind='value' AND identity='header'").utf8) == oldHeader,
                          "v2 committed replacement archives exact embedded child predecessor")
            } else {
                try check(after.scalar("SELECT COUNT(*) FROM archive WHERE kind='task_chunk'") == 2,
                          "v3 committed replacement archives both child text streams")
                try check(after.scalar("SELECT COUNT(*) FROM archive WHERE kind='task_receipt'") == 1,
                          "v3 committed replacement archives old unknown receipt")
                if case .subagent(let state) = original.taskSubagents!.entries[0].content {
                    try check(Data(after.textScalar("SELECT payload FROM archive WHERE kind='task_chunk' AND identity LIKE '0:body:%'").utf8) == Data(state.text.utf8),
                              "v3 committed replacement archives exact previous body bytes")
                    try check(Data(after.textScalar("SELECT payload FROM archive WHERE kind='task_chunk' AND identity LIKE '0:timeline:0:%'").utf8) == Data(state.text.utf8),
                              "v3 committed replacement archives exact previous timeline bytes")
                }
            }
        } else {
            try check(after.scalar("SELECT COUNT(*) FROM archive") == 0,
                      "control crash rolls back archive with state")
        }
        try check(after.scalar("PRAGMA user_version") == (v2 && !committed ? 2 : 3),
                  "control schema and predecessor archive commit atomically")
        try after.close()
    }
    static func killed(_ root: URL, _ boundary: String, legacy: Bool = false, v2: Bool = false) throws {
        let original = try seed(root, legacy: legacy)
        if v2 { try downgradeFixtureToV2(root, original: original) }
        let legacyBytes = legacy ? try Data(contentsOf: store(root).file) : nil
        let process = try child(root, mode: "crash", boundary: boundary)
        process.waitUntilExit()
        try check(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL,
                  "\(boundary) uses real SIGKILL")
        let reader = store(root)
        let lock = try reader.acquire()
        defer { reader.release(lock) }
        let recovered = try reader.load()
        let committed = ["after-commit", "migration-after-install"].contains(boundary)
        try check(canonical(recovered) == canonical(committed ? next(original) : original),
                  "\(boundary) recovers entire old or new state")
        try check(recovered.eventDigests[recovered.cursor!] != nil, "\(boundary) cursor has committed event")
        try check(recovered.tools["execution"]?.content == original.tools["execution"]?.content,
                  "\(boundary) retains unreported tool result")
        try check(recovered.command?.key == "unreceived-request", "\(boundary) retains unknown receipt")
        if let legacyBytes {
            try check(Data(contentsOf: reader.file) == legacyBytes, "\(boundary) retains original migration bytes")
        }
        if v2 {
            let inspect = try AgentGatewayJournalDatabase(file: reader.databaseFile, create: false)
            try check(inspect.scalar("PRAGMA user_version") == (committed ? 3 : 2),
                      "v2 \(boundary) schema and projection commit together")
        }
    }
    static func crashChild(_ root: URL, boundary: String) throws {
        let writer = store(root)
        let lock = try writer.acquire()
        defer { writer.release(lock) }
        let original = try writer.load()
        writer.testBoundary = { stage in if stage == boundary { kill(getpid(), SIGKILL) } }
        let changed = try next(original)
        if boundary.hasPrefix("migration") { try writer.save(changed) }
        else { try writer.saveEvent(changed, eventID: "new-event", digest: changed.eventDigests["new-event"]!) }
        exit(3) // The requested fault boundary must have been reached.
    }
    static func controlCrashChild(_ root: URL, boundary: String) throws {
        let writer = store(root)
        let lock = try writer.acquire()
        defer { writer.release(lock) }
        let original = try writer.load()
        writer.testBoundary = { stage in if stage == boundary { kill(getpid(), SIGKILL) } }
        try writer.save(controlReplacement(original))
        exit(3)
    }
    static func raceChild(_ root: URL) throws {
        let writer = store(root)
        let lock = try writer.acquire()
        defer { writer.release(lock) }
        var journal = try writer.load()
        try Data("ready".utf8).write(to: root.appendingPathComponent("ready"), options: .atomic)
        for index in 1...1_000 {
            let text = "增量\(index)🙂"
            journal.messages[0].content += text
            journal.ordinal += 1
            let key = "race-\(index)"
            journal.cursor = key
            let digest = AgentGatewayJournalStore.digest(Data(text.utf8))
            journal.eventDigests[key] = digest
            try writer.saveEvent(journal, eventID: key, digest: digest, delta: (messageID, "content", text))
        }
    }
    static func run() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { exit(2) }
        let root = URL(fileURLWithPath: args[2]).standardizedFileURL
        guard root.path.hasPrefix("/tmp/clipslots-journal-") ||
              root.path.hasPrefix("/private/tmp/clipslots-journal-") else { exit(2) }
        if args[1] == "crash" { try crashChild(root, boundary: args[3]); return }
        if args[1] == "control-crash" { try controlCrashChild(root, boundary: args[3]); return }
        if args[1] == "race" { try raceChild(root); return }
        guard args[1] == "test" else { exit(2) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in boundaries { try killed(root.appendingPathComponent(name), name) }
        for name in ["migration-before-install", "migration-after-install"] {
            try killed(root.appendingPathComponent(name), name, legacy: true)
        }
        for name in ["task-schema-written", "tasks-written", "before-commit", "after-commit"] {
            try killed(root.appendingPathComponent("v2-\(name)"), name, v2: true)
        }
        for v2 in [false, true] {
            for name in ["tasks-archived", "tasks-written", "before-commit", "after-commit"] {
                try controlKilled(root.appendingPathComponent("control-\(v2)-\(name)"), name, v2: v2)
            }
        }
        for mutation in ["unchanged", "replace", "clear"] {
            let directory = root.appendingPathComponent("v2-control-\(mutation)")
            let original = try seed(directory)
            try downgradeFixtureToV2(directory, original: original)
            let writer = store(directory)
            var changed = try writer.load()
            let before = try AgentGatewayJournalDatabase(file: writer.databaseFile, create: false)
            let oldHeader = try before.value("header")
            try before.close()
            if mutation == "replace" { changed = try controlReplacement(changed) }
            if mutation == "clear" { changed.taskSubagents = nil }
            try writer.save(changed)
            try check(canonical(writer.load()) == canonical(changed), "v2 \(mutation) control upgrade retains exact new state")
            let after = try AgentGatewayJournalDatabase(file: writer.databaseFile, create: false)
            try check(Data(after.textScalar("SELECT payload FROM archive WHERE kind='value' AND identity='header'").utf8) == oldHeader,
                      "v2 \(mutation) control upgrade keeps exact previous header, body and receipts")
            try writer.save(changed)
            try check(after.scalar("SELECT COUNT(*) FROM archive WHERE kind='value' AND identity='header'") == 1
                && after.scalar("SELECT COUNT(*) FROM archive WHERE kind LIKE 'task_%'") == 0,
                      "v2 \(mutation) repeat after upgrade creates no duplicate archive")
            try after.close()
        }
        let v2Root = root.appendingPathComponent("v2-quota")
        let v2Original = try seed(v2Root)
        try downgradeFixtureToV2(v2Root, original: v2Original)
        let v2Writer = store(v2Root)
        var v2State = try v2Writer.load()
        try check(canonical(v2State) == canonical(v2Original), "read-only v2 load retains full child projection")
        v2Writer.testQuotaBytes = 0
        do {
            let changed = try next(v2State)
            try v2Writer.saveEvent(changed, eventID: "new-event", digest: changed.eventDigests["new-event"]!)
            failures.append("v2 quota upgrade accepted")
        } catch { passed += 1 }
        try check(canonical(store(v2Root).load()) == canonical(v2Original),
                  "v2 failed upgrade retains exact old child body, receipts and cursor")
        let v2Inspect = try AgentGatewayJournalDatabase(file: v2Writer.databaseFile, create: false)
        try check(v2Inspect.scalar("PRAGMA user_version") == 2, "quota failure rolls back schema upgrade")
        v2Writer.testQuotaBytes = nil
        v2State = try v2Writer.load()
        let v3State = try next(v2State)
        try v2Writer.saveEvent(v3State, eventID: "new-event", digest: v3State.eventDigests["new-event"]!)
        try check(canonical(store(v2Root).load()) == canonical(v3State),
                  "v2 upgrade retries with same event and exact projection")
        try v2Inspect.close()
        let checkpointRoot = root.appendingPathComponent("child-checkpoints")
        _ = try seed(checkpointRoot)
        let checkpointWriter = store(checkpointRoot)
        var checkpoint = try checkpointWriter.load()
        let controlInspect = try AgentGatewayJournalDatabase(file: checkpointWriter.databaseFile, create: false)
        let controlBytes = try controlInspect.scalar("PRAGMA page_count") * controlInspect.scalar("PRAGMA page_size")
        for index in 0..<25 {
            // Parent-only mutations include uncertain command state; child
            // metadata, body, timeline and receipts remain unchanged.
            checkpoint.phase = index.isMultiple(of: 2) ? "recovering" : "unknown"
            try checkpointWriter.save(checkpoint)
        }
        try check(controlInspect.scalar("SELECT COUNT(*) FROM archive") == 0,
                  "unchanged children are not archived on repeated parent control saves")
        try check(controlInspect.scalar("PRAGMA page_count") * controlInspect.scalar("PRAGMA page_size") <= controlBytes + 4096,
                  "repeated child checkpoints do not consume archive quota")
        try check(canonical(checkpointWriter.load()) == canonical(checkpoint),
                  "skipped child writes preserve complete journal including unknown command")
        let childTool: JSONValue = ["phase": "tool_completed", "subagent_id": "child", "parent_tool_call_id": "parent",
            "tool_event": ["schema_version": "tool_event.v1", "type": "tool_event", "tool": "Read",
                "tool_call_id": "read", "status": "completed", "request": ["path": "fixture"],
                "response": "完整结果🙂"]]
        _ = try checkpoint.taskSubagents?.receiveSubagent(childTool, eventID: "tool", runID: "original-run",
            anchor: nil, now: Date(timeIntervalSince1970: 30))
        _ = try checkpoint.taskSubagents?.receiveSubagent(["phase": "content", "subagent_id": "child",
            "parent_tool_call_id": "parent", "text": "工具后正文"],
            eventID: "suffix", runID: "original-run", anchor: nil, now: Date(timeIntervalSince1970: 40))
        try checkpointWriter.save(checkpoint)
        try check(canonical(checkpointWriter.load()) == canonical(checkpoint),
                  "control checkpoint persists interleaved child text, tool and timeline")
        try check(controlInspect.scalar("SELECT COUNT(DISTINCT revision) FROM archive") == 1,
                  "changed child tool and timeline preserve one predecessor")
        var replacement = checkpoint
        var rewritten = replacement.taskSubagents!.entries
        if case .subagent(var state) = rewritten[0].content {
            state.text = "替换🙂"; state.timeline = [.text(state.text)]
            rewritten[0].content = .subagent(state)
        }
        replacement.taskSubagents = try .init(journalEntries: rewritten, receipts: checkpoint.taskSubagents!.journalReceipts)
        try checkpointWriter.save(replacement)
        try check(canonical(checkpointWriter.load()) == canonical(replacement),
                  "control checkpoint replaces and shortens text without retaining stale suffix")
        try check(controlInspect.scalar("SELECT COUNT(DISTINCT revision) FROM archive") == 2,
                  "child replacement preserves its exact previous generation")
        replacement.taskSubagents?.finish(runID: "original-run", now: Date(timeIntervalSince1970: 50))
        try checkpointWriter.save(replacement)
        try check(canonical(checkpointWriter.load()) == canonical(replacement),
                  "parent termination checkpoint keeps unknown child and exact body")
        try check(controlInspect.scalar("SELECT COUNT(DISTINCT revision) FROM archive") == 3,
                  "metadata-only child termination preserves predecessor")
        replacement.taskSubagents = nil
        try checkpointWriter.save(replacement)
        try check(checkpointWriter.load().taskSubagents == nil, "absent projection round trips as nil")
        try check(controlInspect.scalar("SELECT COUNT(DISTINCT revision) FROM archive") == 4,
                  "clearing child projection archives old body, metadata and receipt")
        try checkpointWriter.save(replacement)
        try check(controlInspect.scalar("SELECT COUNT(DISTINCT revision) FROM archive") == 4,
                  "repeated nil projection creates no further archives")
        try controlInspect.close()
        let receiptOnlyRoot = root.appendingPathComponent("child-receipt-only-control")
        let receiptOnly = try seed(receiptOnlyRoot)
        let receiptWriter = store(receiptOnlyRoot)
        var receiptChange = try receiptWriter.load()
        _ = try receiptChange.taskSubagents?.receiveSubagent(["phase": "progress", "subagent_id": "child",
            "parent_tool_call_id": "parent"], eventID: "receipt-only", runID: "original-run", anchor: nil)
        try check(receiptChange.taskSubagents?.entries == receiptOnly.taskSubagents?.entries,
                  "receipt-only fixture leaves all child metadata and text unchanged")
        try receiptWriter.save(receiptChange)
        try check(canonical(receiptWriter.load()) == canonical(receiptChange), "receipt-only control retains new dedup identity")
        let receiptInspect = try AgentGatewayJournalDatabase(file: receiptWriter.databaseFile, create: false)
        try check(receiptInspect.scalar("SELECT COUNT(*) FROM archive WHERE kind='task_receipt'") == 1,
                  "receipt-only control archives the previous receipt ledger")
        try receiptWriter.save(receiptChange)
        try check(receiptInspect.scalar("SELECT COUNT(DISTINCT revision) FROM archive") == 1,
                  "receipt-only repeat reuses current child rows")
        try receiptInspect.close()
        for mutation in ["body-replaced", "projection-removed", "old-receipt-changed"] {
            let directory = root.appendingPathComponent("v2-event-\(mutation)")
            let original = try seed(directory)
            try downgradeFixtureToV2(directory, original: original)
            let writer = store(directory)
            var changed = try next(writer.load())
            if mutation == "projection-removed" { changed.taskSubagents = nil }
            else if mutation == "body-replaced" { changed = try controlReplacement(changed) }
            else {
                var receipts = changed.taskSubagents!.journalReceipts
                receipts["original-run\u{0}original"] = "changed-old-receipt"
                changed.taskSubagents = try .init(journalEntries: changed.taskSubagents!.entries, receipts: receipts)
            }
            do {
                try writer.saveEvent(changed, eventID: "new-event", digest: changed.eventDigests["new-event"]!)
                failures.append("v2 first event accepted \(mutation)")
            } catch { passed += 1 }
            try check(canonical(store(directory).load()) == canonical(original),
                      "v2 first event \(mutation) leaves old bytes, cursor and receipts intact")
            let after = try AgentGatewayJournalDatabase(file: writer.databaseFile, create: false)
            try check(after.scalar("PRAGMA user_version") == 2 && after.scalar("SELECT COUNT(*) FROM archive") == 0,
                      "v2 rejected \(mutation) rolls back schema and predecessor archive")
            try after.close()
        }
        let conflictRoot = root.appendingPathComponent("child-receipt-conflict")
        let conflictOriginal = try seed(conflictRoot)
        let conflictWriter = store(conflictRoot)
        var conflict = try next(conflictWriter.load())
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(conflict.taskSubagents!)) as! [String: Any]
        var receipts = object["receipts"] as! [String: String]
        receipts["original-run\u{0}original"] = "forged-old-digest"
        object["receipts"] = receipts
        conflict.taskSubagents = try JSONDecoder().decode(AgentTaskSubagentProjection.self,
            from: JSONSerialization.data(withJSONObject: object))
        do {
            try conflictWriter.saveEvent(conflict, eventID: "new-event", digest: conflict.eventDigests["new-event"]!)
            failures.append("forged old child receipt accepted")
        } catch { passed += 1 }
        try check(canonical(store(conflictRoot).load()) == canonical(conflictOriginal),
                  "old child receipt conflict rolls back new content and cursor")
        for mutation in ["body-replaced", "projection-removed"] {
            let writer = store(conflictRoot)
            var changed = try next(writer.load())
            if mutation == "projection-removed" { changed.taskSubagents = nil }
            else {
                var entries = changed.taskSubagents!.entries
                if case .subagent(var state) = entries[0].content {
                    state.text = "替换先前的字节"; state.timeline = [.text(state.text)]
                    entries[0].content = .subagent(state)
                }
                changed.taskSubagents = try .init(journalEntries: entries,
                    receipts: changed.taskSubagents!.journalReceipts)
            }
            do {
                try writer.saveEvent(changed, eventID: "new-event", digest: changed.eventDigests["new-event"]!)
                failures.append("\(mutation) streaming event accepted")
            } catch { passed += 1 }
            try check(canonical(store(conflictRoot).load()) == canonical(conflictOriginal),
                      "\(mutation) rolls back child bytes, receipts and cursor")
        }
        for corruption in ["missing-body", "orphan-body", "receipt-digest"] {
            let directory = root.appendingPathComponent(corruption)
            let original = try seed(directory)
            let writer = store(directory)
            // An intact frozen legacy snapshot must not mask authoritative DB
            // corruption or rewind to its cursor.
            try canonical(original).write(to: writer.file)
            let inspect = try AgentGatewayJournalDatabase(file: writer.databaseFile, create: false)
            if corruption == "missing-body" {
                try inspect.execute("DELETE FROM task_chunks WHERE kind='body'")
            } else if corruption == "orphan-body" {
                try inspect.putTaskText(999, kind: "body", sequence: 1, body: Data("orphan".utf8), replace: false)
            } else {
                try inspect.execute("UPDATE task_receipts SET digest='corrupt'")
            }
            try inspect.close()
            let before = try Data(contentsOf: writer.databaseFile)
            do { _ = try writer.load(); failures.append("\(corruption) silently recovered") }
            catch { passed += 1 }
            try check(Data(contentsOf: writer.databaseFile) == before, "\(corruption) failure keeps corrupt evidence")
        }
        let unicodeRoot = root.appendingPathComponent("child-unicode-bytes")
        _ = try seed(unicodeRoot)
        let unicodeWriter = store(unicodeRoot)
        var unicode = try unicodeWriter.load()
        let originalReceipts = unicode.taskSubagents!.journalReceipts
        for text in ["é", "e\u{301}", "a\u{301}\u{323}", "a\u{323}\u{301}"] {
            var entries = unicode.taskSubagents!.entries
            if case .subagent(var state) = entries[0].content {
                state.text = text; state.timeline = [.text(text)]; entries[0].content = .subagent(state)
            }
            unicode.taskSubagents = try .init(journalEntries: entries, receipts: originalReceipts)
            try unicodeWriter.save(unicode)
            try check(canonical(unicodeWriter.load()) == canonical(unicode),
                      "canonically equivalent child strings preserve exact UTF-8 bytes")
        }
        for (round, delay) in [0.001, 0.003, 0.007, 0.013, 0.027].enumerated() {
            let directory = root.appendingPathComponent("race-\(round)")
            let original = try seed(directory)
            let process = try child(directory, mode: "race")
            let ready = directory.appendingPathComponent("ready")
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !FileManager.default.fileExists(atPath: ready.path) && process.isRunning &&
                  ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.001) }
            try check(FileManager.default.fileExists(atPath: ready.path), "race \(round) child reaches writer")
            Thread.sleep(forTimeInterval: delay)
            kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
            try check(process.terminationStatus == SIGKILL, "race \(round) killed inside actual writes")
            let reader = store(directory)
            let recovered = try reader.load()
            let last = recovered.ordinal - original.ordinal
            var expected = original.messages[0].content
            if last > 0 { for index in 1...last { expected += "增量\(index)🙂" } }
            try check(recovered.messages[0].content == expected, "race \(round) has no missing text chunks")
            try check(recovered.messages[0].reasoning == original.messages[0].reasoning, "race \(round) preserves reasoning")
            try check(recovered.eventDigests.count == recovered.ordinal, "race \(round) events and ordinal agree")
            try check(recovered.cursor == (last == 0 ? "original" : "race-\(last)"), "race \(round) cursor matches text")
            try check(recovered.tools["execution"]?.content == original.tools["execution"]?.content,
                      "race \(round) retains tool side effect result")
        }
        let normalRoot = root.appendingPathComponent("contracts")
        let original = try seed(normalRoot)
        let first = store(normalRoot), stale = store(normalRoot)
        var state = try first.load()
        var staleState = try stale.load()
        state.phase = "recovering"; try first.save(state)
        staleState.phase = "streaming"
        do { try stale.save(staleState); failures.append("stale writer was accepted") }
        catch { passed += 1 }
        try check(store(normalRoot).load().phase == "recovering", "stale writer cannot replace committed state")
        let writer = store(normalRoot)
        state = try writer.load()
        var changed = try next(state)
        writer.testQuotaBytes = 0
        do { try writer.saveEvent(changed, eventID: "new-event", digest: changed.eventDigests["new-event"]!); failures.append("quota failure was accepted") }
        catch { passed += 1 }
        try check(canonical(store(normalRoot).load()) == canonical(state), "quota failure rolls back every field and cursor")
        writer.testQuotaBytes = nil
        state = try writer.load()
        changed = try next(state)
        do {
            try writer.saveEvent(changed, eventID: "new-event", digest: changed.eventDigests["new-event"]!,
                                 delta: (messageID, "content", "mismatched"))
            failures.append("mismatched delta was accepted")
        } catch { passed += 1 }
        try check(canonical(store(normalRoot).load()) == canonical(state), "invalid delta cannot commit cursor")
        state = try writer.load()
        changed = try next(state)
        try writer.saveEvent(changed, eventID: "new-event", digest: changed.eventDigests["new-event"]!)
        try check(canonical(writer.load()) == canonical(changed), "mixed tool/artifact/content state round trips")
        var emptyReasoning = changed
        emptyReasoning.messages.append(.init(role: .assistant, content: "", reasoning: ""))
        try writer.save(emptyReasoning)
        try check(writer.load().messages.last?.reasoning == "", "explicit empty reasoning stays distinct from nil")
        var ended = try writer.load()
        ended.phase = "completed"; try writer.save(ended)
        var fresh = AgentGatewayJournal(origin: writer.origin, binding: binding, clientInstanceID: original.clientInstanceID)
        fresh.runID = "next-run"; fresh.phase = "starting"
        try writer.save(fresh)
        let inspect = try AgentGatewayJournalDatabase(file: writer.databaseFile, create: false)
        try check(inspect.scalar("SELECT COUNT(*) FROM archive WHERE kind='tool'") == 2,
                  "new run archives both reported and unreported tool records")
        try check(inspect.scalar("SELECT COUNT(*) FROM archive WHERE kind='event'") == 2,
                  "new run archives deduplication receipts")
        try check(inspect.scalar("SELECT COUNT(*) FROM archive WHERE kind='chunk'") >= 2,
                  "new run archives content and reasoning chunks")
        try check(inspect.scalar("SELECT COUNT(*) FROM archive WHERE kind='value' AND identity='header'") == 1,
                  "new run retains archived unknown command and binding")
        try check(inspect.scalar("SELECT COUNT(*) FROM archive WHERE kind='task_entry' AND revision=(SELECT MAX(revision) FROM archive)") == 1,
                  "new run archives child identity and terminal metadata")
        try check(inspect.scalar("SELECT COUNT(*) FROM archive WHERE kind='task_chunk' AND revision=(SELECT MAX(revision) FROM archive)") == 4,
                  "new run archives both child body and timeline chunks")
        try check(inspect.scalar("SELECT COUNT(*) FROM archive WHERE kind='task_receipt' AND revision=(SELECT MAX(revision) FROM archive)") == 2,
                  "new run archives child deduplication receipts")
        let files = try FileManager.default.contentsOfDirectory(at: normalRoot, includingPropertiesForKeys: nil)
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                      "journal file \(file.lastPathComponent) is private")
        }
        let legacyRoot = root.appendingPathComponent("legacy-unreadable")
        _ = try seed(legacyRoot, legacy: true)
        let bad = store(legacyRoot)
        try Data("broken JSON".utf8).write(to: bad.file)
        do { _ = try bad.load(); failures.append("corrupt legacy was silently reset") }
        catch { passed += 1 }
        let forged = AgentGatewayJournal(origin: bad.origin, binding: binding, clientInstanceID: "new-client")
        do { try bad.save(forged); failures.append("save overwrote corrupt legacy") }
        catch { passed += 1 }
        try check(!FileManager.default.fileExists(atPath: bad.databaseFile.path), "bad migration never installs a database")
        let oversizeRoot = root.appendingPathComponent("oversize")
        let oversizeOriginal = try seed(oversizeRoot)
        let oversizeWriter = store(oversizeRoot)
        var oversize = try oversizeWriter.load()
        oversize.messages[0].content = String(repeating: "x", count: 128 * 1024 * 1024 + 1)
        do { try oversizeWriter.save(oversize); failures.append("unrecoverable oversized message was accepted") }
        catch { passed += 1 }
        try check(canonical(store(oversizeRoot).load()) == canonical(oversizeOriginal),
                  "oversized message is rejected before changing recoverable state")
        let report: [String: Any] = ["passed": passed, "failures": failures, "providerRequests": 0,
            "sigkillBoundaries": boundaries + ["migration-before-install", "migration-after-install"],
            "randomWriteKillRounds": 5, "productionRestarted": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("report.json"), options: .atomic)
        print("Journal persistence: \(passed) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }

    static func main() {
        do { try run() }
        catch {
            failures.append("Unexpected error after \(passed) checks: \(error)")
            let report: [String: Any] = ["passed": passed, "failures": failures, "providerRequests": 0]
            if CommandLine.arguments.count > 2,
               CommandLine.arguments[2].hasPrefix("/tmp/clipslots-journal-") {
                let path = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("failure.json")
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: path)
            }
            print(failures.joined(separator: "\n"))
            exit(1)
        }
    }
}
