import Foundation
import Darwin
@testable import ClipSlotsKit

@main private enum Main {
    static let service = URL(string: "https://steer.fixture.invalid/v1")!
    static let binding = AgentRunBinding(sessionID: "durability")
    static let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let assistant = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static func check(_ value: @autoclosure () throws -> Bool, _ text: String) rethrows {
        guard try value() else { print("FAIL: \(text)"); exit(1) }
        print("PASS: \(text)")
    }
    static func receipt(_ client: String, placed: Bool) throws -> AgentGatewaySteerReceipt {
        var fields: [String: JSONValue] = ["schemaVersion": 1, "steerSchemaVersion": 1,
            "binding": ["sessionID": "durability"], "runID": "run", "clientInstanceID": .string(client),
            "submissionID": .string(id.uuidString), "messageID": .string(id.uuidString),
            "requestKey": .string("steer-" + id.uuidString),
            "state": .string(placed ? "placed" : "accepted"), "revision": .number(placed ? 2 : 1),
            "sequence": 1, "acceptedAt": 100]
        if placed { fields["placement"] = ["point": "model_boundary", "generation": 1, "messageIndex": 3, "placedAt": 101] }
        return try .init(validating: .object(fields))
    }
    static func placed(_ original: AgentGatewayJournal) throws -> AgentGatewayJournal {
        var next = original
        next.currentAssistantID = nil; next.completedAssistantIDs = [assistant]
        next.messages.append(try original.steerSubmissions![id.uuidString]!.message)
        let placement = try receipt(next.clientInstanceID, placed: true)
        next.steerStates?[id.uuidString]?.receipt = placement
        next.steerStates?[id.uuidString]?.eventApplied = true
        next.ordinal += 1; next.cursor = "placement"
        next.eventDigests["placement"] = "placement"
        return next
    }
    static func main() throws {
        let mode = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        guard root.path.hasPrefix("/tmp/clipslots-steer-journal-") ||
            root.path.hasPrefix("/private/tmp/clipslots-steer-journal-") else { exit(2) }
        let writer = AgentGatewayJournalStore(baseURL: service, binding: binding, root: root)
        let lock = try writer.acquire(); defer { writer.release(lock) }
        if mode == "seed" {
            var journal = try writer.load()
            journal.runID = "run"; journal.phase = "streaming"; journal.wireMessageOffset = 2
            journal.messages = [.init(id: assistant, role: .assistant, content: "原工作🙂")]
            journal.currentAssistantID = assistant
            let message = AgentMessage(id: id, role: .user, content: String(repeating: "x", count: 262_144))
            let body = try AgentGatewaySteerSubmission(message: message, binding: binding, runID: "run",
                clientInstanceID: journal.clientInstanceID, supportsImages: false)
            journal.steerSubmissions = [id.uuidString: body]
            journal.steerStates = [id.uuidString: .init(attempted: true,
                receipt: try receipt(journal.clientInstanceID, placed: false))]
            try writer.save(journal)
            let before = writer.payloadBytesWritten
            for number in 1...1000 {
                journal.messages[0].content += "x"
                journal.ordinal += 1; journal.cursor = "text-\(number)"
                journal.eventDigests["text-\(number)"] = "digest-\(number)"
                try writer.saveEvent(journal, eventID: "text-\(number)", digest: "digest-\(number)",
                    delta: (assistant, "content", "x"))
            }
            let written = writer.payloadBytesWritten - before
            try check(written < 2_000_000, "1000 stream events write less than 2 MB with 256 KiB pending input")
            let db = try AgentGatewayJournalDatabase(file: writer.databaseFile, create: false)
            let header = try db.value("header")!
            try check(header.count < 4096, "long immutable steer body is excluded from event header")
            try check(db.scalar("SELECT COUNT(*) FROM state WHERE key LIKE 'steer_body:%'") == 1,
                      "one durable immutable body row retained")
            try db.close()
            print("{\"events\":1000,\"pendingTextBytes\":262144,\"payloadBytesWritten\":\(written)}")
        } else if mode == "crash" {
            let journal = try writer.load()
            writer.testBoundary = { if $0 == "steers-written" { kill(getpid(), SIGKILL) } }
            let next = try placed(journal)
            try writer.saveEvent(next, eventID: "placement", digest: "placement")
            exit(3)
        } else if mode == "verify" {
            let original = try writer.load()
            check(original.cursor == "text-1000" && original.steerStates?[id.uuidString]?.receipt?.state == .accepted,
                  "real SIGKILL rolls back both placement and cursor")
            check(original.messages.count == 1 && original.steerStates?[id.uuidString]?.eventApplied == false,
                  "real SIGKILL preserves pending original message")
            let next = try placed(original)
            writer.testQuotaBytes = 0
            do { try writer.saveEvent(next, eventID: "placement", digest: "placement"); exit(4) }
            catch let error as AgentGatewayError { check(error == .journalUnavailable, "quota abort is explicit") }
            let recovered = try writer.load()
            check(recovered.cursor == original.cursor && recovered.messages.count == 1
                  && recovered.steerStates?[id.uuidString]?.receipt?.state == .accepted,
                  "quota abort rolls back state, body and cursor")
            writer.testQuotaBytes = nil
            try writer.saveEvent(next, eventID: "placement", digest: "placement")
            let loaded = try writer.load()
            check(loaded.cursor == "placement" && loaded.messages.count == 2
                  && loaded.steerStates?[id.uuidString]?.eventApplied == true, "placement commits atomically after recovery")
            check(loaded.messages[1].content.utf8.count == 262_144, "full original body survives crash and quota abort")
        } else if mode == "corrupt" {
            let db = try AgentGatewayJournalDatabase(file: writer.databaseFile, create: false)
            try db.putValue("steer_body:" + id.uuidString, data: nil)
            try db.close()
            do { _ = try writer.load(); exit(5) }
            catch let error as AgentGatewayError { check(error == .journalUnavailable, "missing steer body fails closed without header fallback") }
        } else { exit(2) }
    }
}
