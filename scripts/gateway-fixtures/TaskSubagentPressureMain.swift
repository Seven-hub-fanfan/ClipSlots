import Foundation
import Darwin
@testable import ClipSlotsKit

/// Full requested workload with explicit I/O/time stop conditions. A stopped
/// baseline is diagnostic evidence, never a passing 50k stress report.
@main enum TaskSubagentPressureMain {
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
        guard [2, 5].contains(CommandLine.arguments.count),
              CommandLine.arguments[1].hasPrefix("/tmp/clipslots-child-pressure-") else { exit(2) }
        let logicalLimit = CommandLine.arguments.count == 5 ? UInt64(CommandLine.arguments[2])! : 1_073_741_824
        let physicalLimit = CommandLine.arguments.count == 5 ? UInt64(CommandLine.arguments[3])! : 536_870_912
        let secondsLimit = CommandLine.arguments.count == 5 ? Double(CommandLine.arguments[4])! : 180
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = AgentGatewayJournalStore(baseURL: URL(string: "https://fixture.invalid/v1")!,
            binding: .init(sessionID: "child-pressure", projectID: nil), root: root)
        var journal = try store.load()
        journal.runID = "run"; journal.phase = "streaming"
        journal.taskSubagents = .init()
        journal.command = .init(key: "unknown-receipt", path: ["runs", "continue"],
                               body: ["fixture": true], attempted: true)
        try store.save(journal)
        let started = ProcessInfo.processInfo.systemUptime
        let diskBefore = try diskWrites()
        let outputURL = root.appendingPathComponent("samples.jsonl")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let delta = "中文正文🙂" + String(repeating: "x", count: 44)
        let requested = 50_000
        var committed = 0
        var stopReason: String?
        var latencies: [Double] = []
        for number in 1...requested {
            let key = "child|\(number)"
            var payload: JSONValue = ["schema_version": "subagent_event.v1", "subagent_id": "child",
                "parent_tool_call_id": "parent", "phase": .string(number == 1 ? "started" :
                    number == requested ? "stopped" : "content")]
            if number > 1 && number < requested {
                var object = payload.objectValue!
                object["text"] = .string(delta); payload = .object(object)
            }
            let tick = ProcessInfo.processInfo.systemUptime
            var next = journal
            do {
                guard try next.taskSubagents!.receiveSubagent(payload, eventID: key, runID: "run", anchor: nil)
                else { throw CocoaError(.validationMissingMandatoryProperty) }
                next.ordinal += 1; next.cursor = key
                let digest = AgentGatewayJournalStore.digest(Data(try payload.encodedText().utf8))
                next.eventDigests[key] = digest
                try store.saveEvent(next, eventID: key, digest: digest, delta: nil)
                journal = next; committed += 1
            } catch { stopReason = "commit_error:" + String(describing: error); break }
            latencies.append((ProcessInfo.processInfo.systemUptime - tick) * 1000)
            if number.isMultiple(of: 100) || number == requested {
                let disk = try diskWrites() - diskBefore
                let sample: [String: Any] = ["event": number, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                    "logicalBytesWritten": store.payloadBytesWritten, "diskBytesWritten": disk,
                    "lastEventLatencyMS": latencies.last!]
                try output.write(contentsOf: JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) + Data("\n".utf8))
                try output.synchronize()
                if store.payloadBytesWritten > logicalLimit { stopReason = "logical_io_budget"; break }
                if disk > physicalLimit { stopReason = "physical_io_budget"; break }
                if ProcessInfo.processInfo.systemUptime - started > secondsLimit { stopReason = "time_budget"; break }
            }
        }
        let restored = try store.load()
        try JSONSerialization.data(withJSONObject: latencies)
            .write(to: root.appendingPathComponent("latencies.json"))
        let ordered = latencies.sorted()
        let report: [String: Any] = ["requestedEvents": requested, "committedEvents": committed,
            "full50kCompleted": committed == requested, "stopReason": stopReason as Any? ?? NSNull(),
            "persistentEventP95MS": ordered.isEmpty ? 0 : ordered[max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)],
            "logicalBytesWritten": store.payloadBytesWritten, "diskBytesWritten": try diskWrites() - diskBefore,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "recoveredProjectionMatches": restored.taskSubagents == journal.taskSubagents,
            "recoveredCursorMatches": restored.cursor == journal.cursor,
            "unknownReceiptRetained": restored.command?.key == journal.command?.key
                && restored.command?.body == journal.command?.body
                && restored.command?.attempted == journal.command?.attempted,
            "expectedBodyBytes": max(0, min(committed - 1, requested - 2)) * delta.utf8.count,
            "recoveredBodyBytes": restored.taskSubagents?.entries.compactMap { entry -> Int? in
                if case .subagent(let state) = entry.content { return state.text.utf8.count }; return nil
            }.first ?? 0,
            "providerRequests": 0, "gui": false, "build": "Debug Kit objects; optimized driver",
            "limits": ["logicalBytes": logicalLimit, "physicalBytes": physicalLimit,
                       "seconds": secondsLimit, "checkedEveryEvents": 100]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("report.json"))
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
