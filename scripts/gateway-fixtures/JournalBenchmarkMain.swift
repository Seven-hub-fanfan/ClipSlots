import Foundation
import Darwin
@testable import ClipSlotsKit

protocol JournalBenchmarkStore {
    var storageFile: URL { get }
    var payloadBytesWritten: UInt64 { get }
    func load() throws -> AgentGatewayJournal
    func save(_ journal: AgentGatewayJournal) throws
    func saveEvent(_ journal: AgentGatewayJournal, eventID: String, digest: String,
                   delta: (messageID: UUID, kind: String, text: String)?) throws
}
extension AgentGatewayJournalStore: JournalBenchmarkStore {}

/// Runs against the linked production journal, with no service or user storage.
@main
struct JournalBenchmarkMain {
    static let sizes = [256, 384, 512, 768, 1024, 2048, 4096, 8192]
    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func diskWrites() throws -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { throw CocoaError(.featureUnsupported) }
        return info.ri_diskio_byteswritten
    }
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard root.path.hasPrefix("/tmp/clipslots-journal-") ||
              root.path.hasPrefix("/private/tmp/clipslots-journal-") else { exit(2) }
        let label = CommandLine.arguments[2]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var reports: [[String: Any]] = []
        for count in [1_000, 10_000, 50_000] {
            let directory = root.appendingPathComponent("\(count)")
            let store: any JournalBenchmarkStore
            if label.hasPrefix("baseline") {
                store = JournalBaselineReference(baseURL: URL(string: "https://journal.fixture.invalid/v1")!,
                    binding: .init(sessionID: "fixture", projectID: "fixture"), root: directory)
            } else {
                store = AgentGatewayJournalStore(baseURL: URL(string: "https://journal.fixture.invalid/v1")!,
                    binding: .init(sessionID: "fixture", projectID: "fixture"), root: directory)
            }
            var journal = try store.load()
            journal.runID = "fixture-run"; journal.phase = "streaming"
            let id = UUID()
            journal.messages = [.init(id: id, role: .assistant, content: "")]
            journal.currentAssistantID = id
            journal.command = .init(key: "unknown-receipt", path: ["runs", "continue"],
                                    body: ["fixture": "pending"], attempted: true)
            let diskBefore = try diskWrites()
            try store.save(journal)
            var written = store.payloadBytesWritten
            var latencies: [Double] = []
            var failureAt: Int?
            let start = ProcessInfo.processInfo.systemUptime
            let samples = directory.appendingPathComponent("samples.jsonl")
            FileManager.default.createFile(atPath: samples.path, contents: nil)
            let output = try FileHandle(forWritingTo: samples)
            for event in 1...count {
                let previous = journal
                let bytes = sizes[(event - 1) % sizes.count]
                // Variable UTF-8 body has exactly the specified byte size.
                let text = String(repeating: "中", count: bytes / 3) + String(repeating: "x", count: bytes % 3)
                let field = event % 3 == 0 ? "thinking" : "content"
                if field == "content" { journal.messages[0].content += text }
                else { journal.messages[0].reasoning = (journal.messages[0].reasoning ?? "") + text }
                journal.ordinal += 1
                let key = "event-\(event)"
                journal.cursor = key
                journal.eventDigests[key] = AgentGatewayJournalStore.digest(Data(text.utf8))
                if label.hasSuffix("mixed"), event.isMultiple(of: 500) {
                    let call = "tool-\(event / 500)"
                    let result = "已完成但尚未补交的工具结果\(event)🙂"
                    journal.tools[call] = .init(request: .init(executionID: call, callID: call,
                        name: "fixture_tool", argumentsJSON: "{}", targetClientInstanceID: journal.clientInstanceID,
                        expiresAt: 4_000_000_000), phase: "completed", content: result, isFailure: false,
                        summary: "fixture", submissionKey: "unknown-receipt")
                    journal.messages.append(.init(role: .tool, content: result, toolCallId: call, toolName: "fixture_tool"))
                    journal.messages[0].toolCalls.append(.init(id: call, name: "fixture_tool", argumentsJSON: "{}"))
                    journal.artifactUpdates = (journal.artifactUpdates ?? []) + [
                        ["artifactID": .string("artifact-\(event)"), "revision": .number(Double(event))]
                    ]
                }
                let tick = ProcessInfo.processInfo.systemUptime
                do {
                    try store.saveEvent(journal, eventID: key, digest: journal.eventDigests[key]!,
                        delta: (id, field == "content" ? "content" : "reasoning", text))
                    let latency = (ProcessInfo.processInfo.systemUptime - tick) * 1000
                    latencies.append(latency)
                    let size = UInt64(try FileManager.default.attributesOfItem(atPath: store.storageFile.path)[.size] as? Int ?? 0)
                    written = store.payloadBytesWritten
                    let sample: [String: Any] = ["event": event, "deltaBytes": bytes, "latencyMS": latency,
                        "snapshotBytes": size, "cumulativeLogicalWriteBytes": written,
                        "processDiskWriteBytes": try diskWrites() - diskBefore]
                    try output.write(contentsOf: JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]))
                    try output.write(contentsOf: Data([10]))
                } catch {
                    failureAt = event; journal = previous
                    break
                }
            }
            try output.synchronize(); try output.close()
            let recovered = try store.load()
            let ordered = latencies.sorted()
            let p95 = ordered.isEmpty ? 0 : ordered[min(ordered.count - 1, Int(ceil(Double(ordered.count) * 0.95)) - 1)]
            let report: [String: Any] = ["requestedEvents": count, "committedEvents": latencies.count,
                "failedAtEvent": failureAt as Any? ?? NSNull(),
                "logicalBytesWritten": written, "persistentCommitP95MS": p95,
                "processDiskWriteBytes": try diskWrites() - diskBefore,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
                "recoveredCursorMatches": recovered.cursor == journal.cursor,
                "recoveredContentMatches": recovered.messages == journal.messages,
                "recoveredToolsMatch": try canonical(recovered.tools) == canonical(journal.tools),
                "recoveredArtifactUpdatesMatch": recovered.artifactUpdates == journal.artifactUpdates,
                "unknownReceiptRetained": recovered.command?.key == journal.command?.key,
                "unreportedToolCount": recovered.tools.count,
                "providerRequests": 0, "label": label, "deltaByteSizes": sizes,
                "scope": "journal persistence only; running concurrently with headless resource soaks",
                "completeRequestedScenario": failureAt == nil]
            reports.append(report)
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
            print("\(label) requested=\(count) committed=\(latencies.count) failure=\(failureAt.map(String.init) ?? "none") p95MS=\(p95) written=\(written)")
            fflush(stdout)
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("report.json"), options: .atomic)
    }
}
