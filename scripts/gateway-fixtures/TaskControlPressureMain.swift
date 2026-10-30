import Foundation
import Darwin
@testable import ClipSlotsKit

/// Repeated ordinary checkpoints against a private copy of the completed
/// 50k child journal. A quota stop remains diagnostic evidence.
@main enum TaskControlPressureMain {
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

    static func canonical(_ journal: AgentGatewayJournal) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(journal)
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2,
              CommandLine.arguments[1].hasPrefix("/tmp/clipslots-child-control-") else { exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let writer = AgentGatewayJournalStore(baseURL: URL(string: "https://fixture.invalid/v1")!,
            binding: .init(sessionID: "child-pressure", projectID: nil), root: root)
        var journal = try writer.load()
        let original = journal
        let inspect = try AgentGatewayJournalDatabase(file: writer.databaseFile, create: false)
        let archiveBefore = try inspect.scalar("SELECT COUNT(*) FROM archive")
        let bytesBefore = try inspect.scalar("PRAGMA page_count") * inspect.scalar("PRAGMA page_size")
        let diskBefore = try diskWrites()
        let started = ProcessInfo.processInfo.systemUptime
        var samples: [[String: Any]] = []
        var stopReason: String?
        let requested = 20
        for index in 1...requested {
            // The first ten are identical; the rest change only parent phase.
            var next = journal
            if index > 10 { next.phase = index.isMultiple(of: 2) ? "recovering" : "unknown" }
            let tick = ProcessInfo.processInfo.systemUptime
            do { try writer.save(next); journal = next }
            catch { stopReason = String(describing: error); break }
            samples.append([
                "checkpoint": index, "changedParentPhase": index > 10,
                "latencyMS": (ProcessInfo.processInfo.systemUptime - tick) * 1000,
                "databaseBytes": try inspect.scalar("PRAGMA page_count") * inspect.scalar("PRAGMA page_size"),
                "archiveRows": try inspect.scalar("SELECT COUNT(*) FROM archive"),
                "logicalBytesWritten": writer.payloadBytesWritten,
                "diskBytesWritten": try diskWrites() - diskBefore,
            ])
            try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("samples.json"))
        }
        let restored = try writer.load()
        let report: [String: Any] = [
            "requestedCheckpoints": requested, "committedCheckpoints": samples.count,
            "stopReason": stopReason as Any? ?? NSNull(),
            "databaseBytesBefore": bytesBefore,
            "databaseBytesAfter": try inspect.scalar("PRAGMA page_count") * inspect.scalar("PRAGMA page_size"),
            "archiveRowsBefore": archiveBefore,
            "archiveRowsAfter": try inspect.scalar("SELECT COUNT(*) FROM archive"),
            "logicalBytesWritten": writer.payloadBytesWritten, "diskBytesWritten": try diskWrites() - diskBefore,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "recoveredJournalMatches": try canonical(restored) == canonical(journal),
            "childProjectionRetained": try canonicalProjection(restored.taskSubagents) == canonicalProjection(original.taskSubagents),
            "eventIdentityRetained": restored.eventDigests == original.eventDigests && restored.cursor == original.cursor,
            "unknownReceiptRetained": restored.command?.key == original.command?.key
                && restored.command?.body == original.command?.body
                && restored.command?.attempted == original.command?.attempted,
            "providerRequests": 0, "gui": false, "quotaBytes": 536_870_912,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("report.json"))
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }

    static func canonicalProjection(_ projection: AgentTaskSubagentProjection?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(projection)
    }
}
