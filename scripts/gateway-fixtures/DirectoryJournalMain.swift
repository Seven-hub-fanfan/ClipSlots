import Foundation
import Darwin
@_spi(DirectoryJournalTesting) import ClipSlotsKit

// Compile this fixture alongside the real App Store; no UI/provider is involved.
enum ClipSlotsPaths { static let dataRoot = URL(fileURLWithPath: "/private/tmp/clipslots-unused-store") }
private final class UndoCancellation: @unchecked Sendable {
    var stopped = false
}

@main enum DirectoryJournalMain {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard root.path.hasPrefix("/private/tmp/clipslots-directory-journal-") else { exit(2) }
        let requested = CommandLine.arguments[2]
        let operation = requested.hasPrefix("crash-") ? String(requested.dropFirst(6)) : requested
        let store = AgentWorkingDirectoryStore(root: root.appendingPathComponent("app-private"))
        let directory = root.appendingPathComponent("selected")
        if operation == "setup" {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("ORIGINAL🙂".utf8).write(to: directory.appendingPathComponent("original.txt"))
            try Data("MOVE".utf8).write(to: directory.appendingPathComponent("move.txt"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: directory.appendingPathComponent("original.txt").path)
            let id = try await store.add(directory)
            print(try JSONValue.object(["directory_id": .string(id.uuidString)]).encodedText())
            return
        }
        guard let id = store.directories.first?.id else { exit(3) }
        let session = operation.hasPrefix("other-session") ? "session-B" : "session-A"
        let project = operation.hasPrefix("other-project") ? "project-B" : "project-A"
        let access = try store.access(id, sessionID: session, projectID: project)
        if requested.hasPrefix("crash-") {
            let stage = CommandLine.arguments[3]
            access.journalCheckpoint = { value in
                guard value == stage else { return }
                FileHandle.standardOutput.write(Data("{\"checkpoint\":\"\(value)\"}\n".utf8))
                // The supervisor supplies an actual SIGKILL from another process.
                while true { pause() }
            }
        }
        let tools = AgentDirectoryTools(base: AgentPreviewTools(), access: access) { request in
            if request.params["items"] != nil {
                _ = try? await request.respond(["items": .array(request.batchItems.map {
                    ["index": $0["index"]!, "action": $0["action"]!, "decision": "accept", "modifications": [:]]
                })])
            } else { _ = try? await request.respond(["decision": "accept"]) }
        }
        func invoke(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
            let result = await tools.execute(call: .init(id: UUID().uuidString, name: name,
                                                        argumentsJSON: try arguments.encodedText()))
            if result.isFailure { return ["tool_failed": true, "content": .string(result.content)] }
            return try JSONValue.decode(jsonText: result.content)
        }
        let result: JSONValue
        switch operation {
        case "write":
            result = try await invoke("local_write_file", ["path": "original.txt", "content": "WRITTEN🙂",
                "expected_sha256": .string(AgentDirectoryAccess.digest(Data("ORIGINAL🙂".utf8)))])
        case "write-again":
            result = try await invoke("local_write_file", ["path": "original.txt", "content": "WRITTEN-TWICE🙂",
                "expected_sha256": .string(AgentDirectoryAccess.digest(Data("WRITTEN🙂".utf8)))])
        case "new":
            result = try await invoke("local_batch_write", ["writes": [
                ["path": "created.txt", "content": "CREATED", "expected_sha256": ""],
                ["path": "independent.txt", "content": "INDEPENDENT", "expected_sha256": ""]
            ]])
        case "organize":
            result = try await invoke("local_organize_files", ["moves": [
                ["source": "move.txt", "destination": "organized/move.txt",
                 "expected_identity": .string(try access.fileIdentity("move.txt"))]
            ], "create_directories": ["organized"]])
        case "chain":
            let identity = try access.fileIdentity("move.txt")
            result = try await invoke("local_organize_files", ["moves": [
                ["source": "move.txt", "destination": "mid.txt", "expected_identity": .string(identity)],
                ["source": "mid.txt", "destination": "final.txt", "expected_identity": .string(identity)]
            ]])
        case "history", "other-session", "other-project":
            result = try await invoke("local_directory_history", [:])
        case "undo", "other-session-undo", "other-project-undo":
            result = try await invoke("local_undo_directory", ["undo_id": .string(CommandLine.arguments[requested.hasPrefix("crash-") ? 4 : 3])])
        case "cancel-undo":
            let flag = UndoCancellation()
            access.journalCheckpoint = { if $0 == "undo-applied" { flag.stopped = true } }
            result = try access.undo(UUID(uuidString: CommandLine.arguments[3])!, cancelled: { flag.stopped })
        case "reauthorize":
            _ = try await store.add(access.url, replacing: id)
            let next = try store.access(id, sessionID: session, projectID: project)
            result = try next.directoryHistory()
        case "roundtrip":
            let written = try access.batchWrite([.init(path: "same-call.txt", data: Data("ONE".utf8), expectedDigest: nil)],
                                               accepted: [true])
            access.revoke()
            let next = try store.access(id, sessionID: session, projectID: project)
            result = try next.undo(UUID(uuidString: written["undo_id"]!.stringValue!)!)
        case "stress":
            let start = ProcessInfo.processInfo.systemUptime
            var complete = true
            for round in 0..<25 {
                let current = try store.access(id, sessionID: session, projectID: project)
                let value = try current.batchWrite((0..<16).map {
                    .init(path: "pressure-\($0).txt", data: Data("round-\(round)🙂".utf8), expectedDigest: nil)
                }, accepted: Array(repeating: true, count: 16))
                current.revoke()
                let nextStore = AgentWorkingDirectoryStore(root: root.appendingPathComponent("app-private"))
                let next = try nextStore.access(id, sessionID: session, projectID: project)
                complete = complete && value["complete"] == true
                let reversed = try next.undo(UUID(uuidString: value["undo_id"]!.stringValue!)!)
                complete = complete && reversed["complete"] == true
                next.revoke()
            }
            result = ["complete": .bool(complete), "writes": 400,
                      "seconds": .number(ProcessInfo.processInfo.systemUptime - start)]
        case "record-limit":
            var successful = 0
            for index in 0..<32 {
                let next = try store.access(id, sessionID: session, projectID: project)
                let value = try next.batchWrite([.init(path: "retained-\(index).txt", data: Data("X".utf8), expectedDigest: nil)],
                                               accepted: [true])
                if value["complete"] == true { successful += 1 }
                next.revoke()
            }
            let next = try store.access(id, sessionID: session, projectID: project)
            var rejected = false
            do { _ = try next.batchWrite([.init(path: "overflow.txt", data: Data("BAD".utf8), expectedDigest: nil)], accepted: [true]) }
            catch AgentDirectoryError.tooLarge { rejected = true }
            result = ["successful": .number(Double(successful)), "rejected": .bool(rejected),
                      "history": try next.directoryHistory()]
        case "byte-limit":
            var successful = 0
            for round in 0..<4 {
                var writes: [AgentDirectoryWrite] = []
                for index in 0..<4 {
                    let name = "budget-\(round)-\(index).txt"
                    let original = Data(repeating: 65, count: AgentDirectoryAccess.maxFileBytes)
                    try original.write(to: directory.appendingPathComponent(name))
                    writes.append(.init(path: name, data: Data("X".utf8), expectedDigest: AgentDirectoryAccess.digest(original)))
                }
                let value = try access.batchWrite(writes, accepted: Array(repeating: true, count: 4))
                if value["complete"] == true { successful += 1 }
            }
            let value = try access.batchWrite([.init(path: "original.txt", data: Data("BAD".utf8),
                expectedDigest: AgentDirectoryAccess.digest(Data("ORIGINAL🙂".utf8)))], accepted: [true])
            result = ["successful": .number(Double(successful)), "overflow": value, "history": try access.directoryHistory()]
        default: exit(4)
        }
        print(try result.encodedText())
    }
}
