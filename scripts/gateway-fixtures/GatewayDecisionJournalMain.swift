import Foundation
import Darwin
@testable import ClipSlotsKit

@main private enum Main {
    static let service = URL(string: "https://decision.fixture.invalid/v1")!
    static let binding = AgentRunBinding(sessionID: "decision-durability")
    static let assistant = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static var assertions = 0
    static func check(_ condition: Bool, _ label: String) {
        guard condition else { print("FAIL: \(label)"); exit(1) }
        assertions += 1; print("PASS: \(label)")
    }
    static func resolved(_ record: AgentGatewayDecisionRecord) throws -> AgentGatewayDecisionReceipt {
        let identity = record.identity, submission = record.submission!
        let value: JSONValue = ["schemaVersion": 1, "decisionSchemaVersion": 1,
            "binding": ["sessionID": .string(binding.sessionID)], "runID": "run", "clientInstanceID": .string(identity.clientInstanceID),
            "interactionID": "original", "kind": "waiting_question", "requestRevision": 1,
            "requestFingerprint": .string(identity.requestFingerprint), "createdAt": 100, "expiresAt": 1000,
            "serverTime": 102, "state": "resolved", "decision": ["requestKey": .string(submission.requestKey),
                "answerSHA256": .string(submission.answerSHA256), "acceptedAt": 101, "generation": 1, "messageIndex": 2]]
        return try JSONDecoder().decode(AgentGatewayDecisionReceipt.self, from: JSONEncoder().encode(value))
    }
    static func accepted(_ original: AgentGatewayJournal) throws -> AgentGatewayJournal {
        var next = original
        next.decisionRecords?["original"]?.receipt = try resolved(original.decisionRecords!["original"]!)
        next.ordinal += 1; next.cursor = "decision"; next.eventDigests["decision"] = "digest"
        return next
    }
    static func main() throws {
        let mode = CommandLine.arguments[1], root = URL(fileURLWithPath: CommandLine.arguments[2])
        guard root.path.contains("clipslots-decision-journal-") else { exit(2) }
        let writer = AgentGatewayJournalStore(baseURL: service, binding: binding, root: root)
        let lock = try writer.acquire(); defer { writer.release(lock) }
        if mode == "seed" {
            var journal = try writer.load()
            journal.runID = "run"; journal.phase = "streaming"
            journal.messages = [.init(id: assistant, role: .assistant, content: "kept-work")]
            journal.currentAssistantID = assistant
            let params: JSONValue = ["questions": [["id": "q", "question": "Synthetic secret", "isSecret": true]]]
            let identity = try AgentGatewayDecisionIdentity(binding: binding, runID: "run",
                clientInstanceID: journal.clientInstanceID, kind: "waiting_question", payload: [
                    "interactionID": "original", "requestRevision": 1, "requestFingerprint": .string(String(repeating: "a", count: 64)),
                    "createdAt": 100, "serverTime": 100, "expiresAt": 1000])
            let answer: JSONValue = ["answers": ["q": ["answers": [.string(String(repeating: "x", count: 262_144) + "e\u{301}")]]]]
            var record = AgentGatewayDecisionRecord(localID: UUID(), identity: identity, params: params)
            record.submission = .init(requestKey: "original-key", answerJSON: try answer.encodedText()); record.attempted = true
            journal.decisionRecords = ["original": record]
            try writer.save(journal)
            let before = writer.payloadBytesWritten, start = ProcessInfo.processInfo.systemUptime
            for number in 1...1000 {
                journal.messages[0].content += "x"; journal.ordinal += 1
                journal.cursor = "text-\(number)"; journal.eventDigests["text-\(number)"] = "digest"
                try writer.saveEvent(journal, eventID: "text-\(number)", digest: "digest",
                    delta: (assistant, "content", "x"))
            }
            let bytes = writer.payloadBytesWritten - before
            check(bytes < 2_000_000, "1000 events write below 2 MB with 256 KiB unresolved answer")
            let db = try AgentGatewayJournalDatabase(file: writer.databaseFile, create: false)
            check(try db.scalar("PRAGMA user_version") == 4, "new decision journal rejects pre-decision readers")
            check(try db.value("header")!.count < 4096, "immutable answer is excluded from event header")
            try db.close()
            print("{\"events\":1000,\"answerBytes\":262146,\"payloadBytesWritten\":\(bytes),\"seconds\":\(ProcessInfo.processInfo.systemUptime - start)}")
        } else if mode == "crash" {
            let original = try writer.load()
            writer.testBoundary = { if $0 == "decisions-written" { kill(getpid(), SIGKILL) } }
            try writer.saveEvent(accepted(original), eventID: "decision", digest: "digest")
            exit(3)
        } else if mode == "verify" {
            let original = try writer.load()
            check(original.cursor == "text-1000" && original.decisionRecords?["original"]?.state == .syncing,
                  "real SIGKILL rolls back acceptance and cursor together")
            let next = try accepted(original)
            writer.testQuotaBytes = 0
            do { try writer.saveEvent(next, eventID: "decision", digest: "digest"); exit(4) }
            catch { check(error as? AgentGatewayError == .journalUnavailable, "real quota abort is explicit") }
            let loaded = try writer.load()
            check(loaded.cursor == original.cursor && loaded.decisionRecords?["original"]?.receipt == nil,
                  "quota abort preserves original unknown answer and event cursor")
            writer.testQuotaBytes = nil
            try writer.saveEvent(next, eventID: "decision", digest: "digest")
            var accepted = try writer.load()
            check(accepted.cursor == "decision" && accepted.decisionRecords?["original"]?.state == .resolved,
                  "acceptance and cursor commit together after recovery")
            accepted.phase = "failed"; try writer.save(accepted)
            check(try writer.load().decisionRecords?["original"]?.state == .resolved,
                  "subsequent task failure cannot reverse accepted decision")
            var changed = accepted
            let saved = accepted.decisionRecords!["original"]!.submission!
            changed.decisionRecords?["original"]?.submission = .init(requestKey: saved.requestKey,
                answerJSON: saved.answerJSON.replacingOccurrences(of: "e\u{301}", with: "é"))
            do { try writer.save(changed); exit(5) }
            catch { check(error as? AgentGatewayError == .journalUnavailable, "canonical-equivalent Unicode cannot mutate original answer bytes") }
        } else if mode == "corrupt" {
            let db = try AgentGatewayJournalDatabase(file: writer.databaseFile, create: false)
            try db.putValue("decision:original", data: nil); try db.close()
            do { _ = try writer.load(); exit(6) }
            catch { check(error as? AgentGatewayError == .journalUnavailable, "missing original decision row fails closed") }
        } else { exit(2) }
        print("{\"mode\":\"\(mode)\",\"assertions\":\(assertions),\"failures\":0}")
    }
}
