import Foundation
import Darwin
import ClipSlotsKit

private actor Checks {
    var values: [JSONValue] = []
    func check(_ passed: Bool, _ name: String) { values.append(["name": .string(name), "passed": .bool(passed)]) }
}
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var current = true
    func step() -> Bool { lock.withLock { count += 1; return count > 4 } }
    func revoke() { lock.withLock { current = false } }
    var valid: Bool { lock.withLock { current } }
}
private actor Requests {
    var count = 0
    var last: AgentInteraction?
    func receive(_ request: AgentInteraction) { count += 1; last = request }
}

@main enum DirectoryBatchMain {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard root.path.hasPrefix("/private/tmp/clipslots-directory-batch-") else { exit(2) }
        let checks = Checks(), fm = FileManager.default
        let work = root.appendingPathComponent("项目 with spaces"), outside = root.appendingPathComponent("outside")
        for path in [work, outside] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
        func put(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: work.appendingPathComponent(path)) }
        func text(_ path: String) -> String? { try? String(contentsOf: work.appendingPathComponent(path), encoding: .utf8) }
        let access = try AgentDirectoryAccess(url: work)
        try put("input.txt", "original🙂")
        try put("executable.sh", "#!/bin/sh\nprintf original")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.appendingPathComponent("executable.sh").path)
        let originalHash = AgentDirectoryAccess.digest(Data("original🙂".utf8))
        let writes = [
            AgentDirectoryWrite(path: "input.txt", data: Data("updated🙂".utf8), expectedDigest: originalHash),
            AgentDirectoryWrite(path: "missing/new.txt", data: Data("bad".utf8), expectedDigest: nil),
            AgentDirectoryWrite(path: "created.txt", data: Data("created".utf8), expectedDigest: nil),
            AgentDirectoryWrite(path: "declined.txt", data: Data("declined".utf8), expectedDigest: nil)
        ]
        let batch = try access.batchWrite(writes, accepted: [true, true, true, false])
        await checks.check(batch["items"]?.arrayValue?.map { $0["status"]?.stringValue ?? "" }
            == ["written", "failed", "written", "declined"], "batch returns all item outcomes")
        await checks.check(text("input.txt") == "updated🙂" && text("created.txt") == "created" && text("declined.txt") == nil,
                           "batch actual partial filesystem effects")
        try put("input.txt", "user-later🙂")
        let undoID = UUID(uuidString: batch["undo_id"]!.stringValue!)!
        let undo = try access.undo(undoID)
        await checks.check(undo["complete"] == false && text("input.txt") == "user-later🙂" && text("created.txt") == nil,
                           "undo keeps concurrent edit and reverts independent new file")
        do { _ = try access.undo(undoID); await checks.check(false, "undo identity consumed once") }
        catch { await checks.check(true, "undo identity consumed once") }
        let newUndo = UUID(uuidString: undo["undo_id"]!.stringValue!)!
        try put("input.txt", "updated🙂")
        let retried = try access.undo(newUndo)
        await checks.check(retried["complete"] == true && text("input.txt") == "original🙂", "explicit new undo resolves restored version")
        let executableHash = AgentDirectoryAccess.digest(try access.read("executable.sh"))
        try access.write("executable.sh", data: Data("#!/bin/sh\nprintf updated".utf8), expectedDigest: executableHash)
        let mode = try fm.attributesOfItem(atPath: work.appendingPathComponent("executable.sh").path)[.posixPermissions] as? NSNumber
        await checks.check(mode?.intValue == 0o755, "atomic replacement preserves ordinary executable mode")
        try Data("outside-secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(at: work.appendingPathComponent("link"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: work.appendingPathComponent("leaf.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try fm.linkItem(at: outside.appendingPathComponent("secret.txt"), to: work.appendingPathComponent("hard.txt"))
        try access.write("hard.txt", data: Data("inside-new".utf8),
                         expectedDigest: AgentDirectoryAccess.digest(Data("outside-secret".utf8)))
        await checks.check(try String(contentsOf: outside.appendingPathComponent("secret.txt"), encoding: .utf8) == "outside-secret",
                           "hardlink replacement does not modify external inode")
        let symlinkBatch = try access.batchWrite([
            .init(path: "link/new.txt", data: Data("bad".utf8), expectedDigest: nil),
            .init(path: "leaf.txt", data: Data("bad".utf8), expectedDigest: nil),
            .init(path: "../outside/secret.txt", data: Data("bad".utf8), expectedDigest: nil)
        ], accepted: [true, true, true])
        await checks.check(symlinkBatch["items"]?.arrayValue?.allSatisfy { $0["status"] == "failed" } == true,
                           "batch rejects symlink leaf parent and traversal")
        try fm.createDirectory(at: work.appendingPathComponent("nested/deep"), withIntermediateDirectories: true)
        try put("nested/deep/file.txt", "nested-original")
        let tree = try access.tree(maxDepth: 4, maxEntries: 100)
        await checks.check(tree["complete"] == true && tree["entries"]?.arrayValue?.contains { $0["path"] == "nested/deep/file.txt" } == true,
                           "real recursive tree includes nested file")
        await checks.check(tree["entries"]?.arrayValue?.contains { $0["path"] == "link/secret.txt" } == false,
                           "tree does not follow external symlink")
        await checks.check(try access.tree(maxDepth: 0)["complete"] == false, "depth bound is explicit incomplete")
        await checks.check(try access.tree(maxEntries: 2)["entries"]?.arrayValue?.count == 2
            && access.tree(maxEntries: 2)["complete"] == false, "entry bound limits actual traversal result")
        try put("a.txt", "A"); try put("b.txt", "B"); try put("collision.txt", "COLLISION")
        let aid = try access.fileIdentity("a.txt"), bid = try access.fileIdentity("b.txt")
        let failure = try access.organize([
            .init(source: "a.txt", destination: "sorted/a.txt", expectedIdentity: aid),
            .init(source: "b.txt", destination: "sorted/b.txt", expectedIdentity: bid),
            .init(source: "missing.txt", destination: "sorted/c.txt", expectedIdentity: "missing")
        ], createDirectories: ["sorted"])
        await checks.check(failure["complete"] == false && failure["rollback_complete"] == true
            && failure["rollback"]?.arrayValue?.compactMap { $0["index"]?.intValue } == [2, 1, 0],
                           "organize failure rolls actual operations back in reverse order")
        await checks.check(text("a.txt") == "A" && text("b.txt") == "B" && !fm.fileExists(atPath: work.appendingPathComponent("sorted").path),
                           "organize failed transaction leaves original bytes and removes own empty directory")
        let collision = try access.organize([.init(source: "a.txt", destination: "collision.txt", expectedIdentity: aid)])
        await checks.check(collision["complete"] == false && text("collision.txt") == "COLLISION", "organize never overwrites occupied destination")
        try put("rollback-user.txt", "ROLLBACK-ORIGINAL")
        let rollbackConflict = try access.organize([
            .init(source: "rollback-user.txt", destination: "conflict-dir/user.txt", expectedIdentity: try access.fileIdentity("rollback-user.txt")),
            .init(source: "missing-again.txt", destination: "conflict-dir/missing.txt", expectedIdentity: "missing")
        ], createDirectories: ["conflict-dir"], cancelled: {
            if fm.fileExists(atPath: work.appendingPathComponent("conflict-dir/user.txt").path) {
                try? Data("ROLLBACK-USER-LATER".utf8).write(to: work.appendingPathComponent("conflict-dir/user.txt"), options: .atomic)
            }
            return false
        })
        await checks.check(rollbackConflict["complete"] == false && rollbackConflict["rollback_complete"] == false
            && text("conflict-dir/user.txt") == "ROLLBACK-USER-LATER" && text("rollback-user.txt") == nil
            && rollbackConflict["undo_id"]?.stringValue != nil,
                           "actual concurrent edit during organize keeps bytes and reports reverse rollback conflicts")
        let large = Data(repeating: 0xab, count: 1_048_577)
        try large.write(to: work.appendingPathComponent("large.bin"))
        let organized = try access.organize([
            .init(source: "large.bin", destination: "sorted/large.bin", expectedIdentity: try access.fileIdentity("large.bin")),
            .init(source: "nested", destination: "sorted/nested", expectedIdentity: try access.fileIdentity("nested"))
        ], createDirectories: ["sorted"])
        await checks.check(organized["complete"] == true && (try? Data(contentsOf: work.appendingPathComponent("sorted/large.bin"))) == large
            && text("sorted/nested/deep/file.txt") == "nested-original", "organize moves large binary and directory without rewriting")
        let organizedUndo = try access.undo(UUID(uuidString: organized["undo_id"]!.stringValue!)!)
        await checks.check(organizedUndo["complete"] == true && text("nested/deep/file.txt") == "nested-original",
                           "organize successful undo restores directory and large file")
        let cancellation = Flag()
        let cancelledBatch = try access.batchWrite((0..<16).map {
            .init(path: "cancel-\($0).txt", data: Data(repeating: 65, count: 8192), expectedDigest: nil)
        }, accepted: Array(repeating: true, count: 16), cancelled: { cancellation.step() })
        await checks.check(cancelledBatch["items"]?.arrayValue?.count == 16
            && cancelledBatch["items"]?.arrayValue?.contains { $0["error_code"] == "CANCELLED" } == true,
                           "cancelled batch preserves full outcomes without completing remaining writes")
        let requests = Requests(), validity = Flag()
        let tools = AgentDirectoryTools(base: AgentPreviewTools(), access: access, allowShell: true,
            isCurrent: { validity.valid }) { request in
                await requests.receive(request)
                if request.params["items"] != nil {
                    let values: [JSONValue] = request.batchItems.enumerated().map { index, item in
                        ["index": item["index"]!, "action": item["action"]!,
                         "decision": .string(index == 1 ? "decline" : "accept"), "modifications": [:]]
                    }
                    _ = try? await request.respond(["items": .array(values)])
                } else { _ = try? await request.respond(["decision": "accept"]) }
            }
        @Sendable func invoke(_ name: String, _ args: JSONValue, _ custom: AgentDirectoryTools? = nil) async throws -> AgentToolResult {
            await (custom ?? tools).execute(call: .init(id: UUID().uuidString, name: name, argumentsJSON: try args.encodedText()))
        }
        let toolBatch = try await invoke("local_batch_write", ["writes": [
            ["path": "approved-0.txt", "content": "approved0", "expected_sha256": ""],
            ["path": "approved-1.txt", "content": "declined1", "expected_sha256": ""],
            ["path": "approved-2.txt", "content": "approved2", "expected_sha256": ""]]])
        await checks.check(!toolBatch.isFailure && text("approved-0.txt") == "approved0"
            && text("approved-1.txt") == nil && text("approved-2.txt") == "approved2", "actual tool dispatch obeys individual approvals")
        let immutable = await requests.last
        await checks.check(try await immutable?.respond(["items": []]) == false, "approval cannot be answered twice or with missing items")
        let malformed = try await invoke("local_batch_write", ["writes": [["path": "malformed.txt", "content": "bad"]]])
        await checks.check(malformed.isFailure && text("malformed.txt") == nil, "nested schema fails before mutation")
        try put("approval-race.txt", "before")
        let raceTools = AgentDirectoryTools(base: AgentPreviewTools(), access: access) { request in
            try? Data("user-during-approval".utf8).write(to: work.appendingPathComponent("approval-race.txt"), options: .atomic)
            let values: [JSONValue] = request.batchItems.map {
                ["index": $0["index"]!, "action": $0["action"]!, "decision": "accept", "modifications": [:]]
            }
            _ = try? await request.respond(["items": .array(values)])
        }
        let race = try await invoke("local_batch_write", ["writes": [
            ["path": "approval-race.txt", "content": "model-after", "expected_sha256": .string(AgentDirectoryAccess.digest(Data("before".utf8)))],
            ["path": "approval-independent.txt", "content": "independent", "expected_sha256": ""]
        ]], raceTools)
        let raceResult = try JSONValue.decode(jsonText: race.content)
        await checks.check(raceResult["items"]?.arrayValue?.map { $0["status"] } == ["failed", "written"]
            && text("approval-race.txt") == "user-during-approval" && text("approval-independent.txt") == "independent",
                           "concurrent change during actual approval preserves user bytes and processes other item")
        let pressureStart = ProcessInfo.processInfo.systemUptime
        var pressureOK = true
        for round in 0..<50 {
            let pressure = try access.batchWrite((0..<16).map {
                .init(path: "pressure-\($0).txt", data: Data("round-\(round)-file-\($0)🙂".utf8), expectedDigest: nil)
            }, accepted: Array(repeating: true, count: 16))
            pressureOK = pressureOK && pressure["complete"] == true
            let pressureUndo = try access.undo(UUID(uuidString: pressure["undo_id"]!.stringValue!)!)
            pressureOK = pressureOK && pressureUndo["complete"] == true
        }
        let pressureSeconds = ProcessInfo.processInfo.systemUptime - pressureStart
        await checks.check(pressureOK && (0..<16).allSatisfy { text("pressure-\($0).txt") == nil },
                           "50 real batches 800 writes and reverse undos preserve bounded undo lifecycle")
        try fm.createDirectory(at: work.appendingPathComponent("wide"), withIntermediateDirectories: true)
        for index in 0..<2500 { try put("wide/f-\(index).txt", "file-\(index)") }
        let wideStart = ProcessInfo.processInfo.systemUptime
        let wide = try access.tree("wide", maxEntries: 2000)
        let wideSeconds = ProcessInfo.processInfo.systemUptime - wideStart
        await checks.check(wide["complete"] == false && wide["truncated"] == true && wide["entries"]?.arrayValue?.count == 2000,
                           "2500-entry actual directory returns 2000 bounded entries with explicit truncation")
        let readonly = tools.restrictedForPreview()
        for name in AgentDirectoryTools.names.subtracting(["local_read_file", "local_list_directory", "local_directory_tree", "local_directory_history"]) {
            await checks.check(try await invoke(name, [:], readonly).isFailure
                && !readonly.specs().contains { $0.name == name }, "preview strips writer/proposal \(name)")
        }
        let proposal = try await invoke("local_propose_shell", [
            "script": "printf 'shell-once🙂' >> once.txt; printf '%s' \"$PWD\" > shell-cwd.txt; printf shell-output",
            "timeout_seconds": 2])
        let proposed = try JSONValue.decode(jsonText: proposal.content)
        let arguments: JSONValue = ["proposal_id": proposed["proposal_id"]!]
        await checks.check(text("once.txt") == nil && proposed["executed"] == false, "shell proposal has zero process effects")
        let execution = try await invoke("local_execute_proposal", arguments)
        let executed = try JSONValue.decode(jsonText: execution.content)
        await checks.check(executed["succeeded"] == true && text("once.txt") == "shell-once🙂"
            && text("shell-cwd.txt") == work.path && executed["stdout"] == "shell-output", "one-time approved shell runs real process in descriptor cwd")
        let repeated = try await invoke("local_execute_proposal", arguments)
        await checks.check(repeated.isFailure && text("once.txt") == "shell-once🙂", "consumed proposal cannot run twice")
        let fresh = AgentDirectoryTools(base: AgentPreviewTools(), access: access, allowShell: true) { request in
            _ = try? await request.respond(["decision": "accept"])
        }
        await checks.check(try await invoke("local_execute_proposal", arguments, fresh).isFailure,
                           "old proposal does not revive in new tool instance")
        let concurrentProposal = try JSONValue.decode(jsonText: try await invoke("local_propose_shell",
            ["script": "printf concurrent >> concurrent-once.txt"]).content)
        async let first = invoke("local_execute_proposal", ["proposal_id": concurrentProposal["proposal_id"]!])
        async let second = invoke("local_execute_proposal", ["proposal_id": concurrentProposal["proposal_id"]!])
        let pair = try await [first, second]
        await checks.check(pair.filter(\.isFailure).count == 1 && text("concurrent-once.txt") == "concurrent",
                           "concurrent claim admits one actual subprocess")
        let deniedTools = AgentDirectoryTools(base: AgentPreviewTools(), access: access, automaticWrites: true,
                                              allowShell: true) { request in
            _ = try? await request.respond(["decision": "decline"])
        }
        let deniedProposal = try JSONValue.decode(jsonText: try await invoke("local_propose_shell",
            ["script": "printf bad > denied-shell.txt"], deniedTools).content)
        let deniedArgs: JSONValue = ["proposal_id": deniedProposal["proposal_id"]!]
        let deniedExecution = try await invoke("local_execute_proposal", deniedArgs, deniedTools)
        let deniedRepeat = try await invoke("local_execute_proposal", deniedArgs, deniedTools)
        await checks.check(deniedExecution.isFailure && deniedRepeat.isFailure && text("denied-shell.txt") == nil,
                           "shell always asks even in automatic mode; declined proposal is consumed")
        let pendingRequests = Requests()
        let waitingTools = AgentDirectoryTools(base: AgentPreviewTools(), access: access, allowShell: true) {
            await pendingRequests.receive($0)
        }
        let cancelledProposal = try JSONValue.decode(jsonText: try await invoke("local_propose_shell",
            ["script": "printf bad > cancelled-shell.txt"], waitingTools).content)
        let cancelledArgs: JSONValue = ["proposal_id": cancelledProposal["proposal_id"]!]
        let waitingTask = Task { try await invoke("local_execute_proposal", cancelledArgs, waitingTools) }
        for _ in 0..<20 { if await pendingRequests.count > 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        waitingTask.cancel()
        let cancelledExecution = try await waitingTask.value
        let cancelledRepeat = try await invoke("local_execute_proposal", cancelledArgs, waitingTools)
        await checks.check(cancelledExecution.isFailure && text("cancelled-shell.txt") == nil
            && cancelledRepeat.isFailure,
                           "cancellation during approval consumes proposal without process effects")
        let revocationAccess = try AgentDirectoryAccess(url: work), revocationRequests = Requests()
        let revocationTools = AgentDirectoryTools(base: AgentPreviewTools(), access: revocationAccess) {
            await revocationRequests.receive($0)
        }
        let revokedWrite = Task {
            try await invoke("local_batch_write", ["writes": [["path": "revocation-write.txt", "content": "bad",
                                                                "expected_sha256": ""]]], revocationTools)
        }
        for _ in 0..<20 { if await revocationRequests.count > 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        revocationAccess.revoke()
        let revocationOutcome = try await revokedWrite.value
        if let request = await revocationRequests.last {
            let response: JSONValue = ["items": [["index": 0, "action": "write_file", "decision": "accept", "modifications": [:]]]]
            await checks.check(try await request.respond(response) == false, "revocation invalidates pending approval")
        }
        await checks.check(revocationOutcome.isFailure && text("revocation-write.txt") == nil,
                           "grant revoked during approval never writes or falls back")
        let liveAccess = try AgentDirectoryAccess(url: work), liveRequests = Requests()
        let liveTools = AgentDirectoryTools(base: AgentPreviewTools(), access: liveAccess, allowShell: true) { request in
            await liveRequests.receive(request)
            _ = try? await request.respond(["decision": "accept"])
        }
        let childScript = """
        /usr/bin/python3 -c 'import os,time,signal
        p=os.fork()
        if p==0:
         open("live-child.pid","w").write(str(os.getpid()))
         signal.signal(signal.SIGTERM,signal.SIG_IGN)
         time.sleep(30)
         os._exit(0)
        time.sleep(30)'
        """
        let liveProposal = try JSONValue.decode(jsonText: try await invoke("local_propose_shell",
            ["script": .string(childScript), "timeout_seconds": 15], liveTools).content)
        let liveTask = Task { try await invoke("local_execute_proposal", ["proposal_id": liveProposal["proposal_id"]!], liveTools) }
        for _ in 0..<100 { if text("live-child.pid") != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let liveChild = text("live-child.pid").flatMap(Int32.init)
        liveAccess.revoke()
        let liveExecution = try await liveTask.value
        let liveResult = try JSONValue.decode(jsonText: liveExecution.content)
        let childStatus = if let liveChild {
            await AgentProcessRunner.run(executable: "/bin/ps", arguments: ["-p", String(liveChild), "-o", "state="])
        } else { AgentProcessResult(exitCode: -1, stdout: "missing", stderr: "", timedOut: false) }
        await checks.check(liveChild != nil && liveResult["cancelled"] == true
            && (childStatus.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || childStatus.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z")),
                           "running shell grant revocation waits for actual stubborn child group exit")
        let isolatedScope = AgentDirectoryTools(base: AgentPreviewTools(), access: access) { _ in }
        let isolatedShell = try await invoke("local_propose_shell", ["script": "printf bypass"], isolatedScope)
        await checks.check(!isolatedScope.specs().contains { $0.name == "local_propose_shell" }
            && isolatedShell.isFailure,
                           "selected directory grants never inherit unrestricted shell capability")
        validity.revoke()
        let staleTool = try await invoke("local_read_file", ["path": "input.txt"])
        await checks.check(staleTool.isFailure, "old run ownership rejects retained directory tool")
        let renamed = root.appendingPathComponent("original-root")
        try fm.moveItem(at: work, to: renamed)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("replacement-root".utf8).write(to: work.appendingPathComponent("input.txt"))
        do { _ = try access.read("input.txt"); await checks.check(false, "replaced root fails closed") }
        catch { await checks.check(true, "replaced root fails closed") }
        let revoked = try AgentDirectoryAccess(url: work); revoked.revoke()
        await checks.check(!revoked.isActive && !revoked.isWritable, "explicit revoke expires OS scope and writer publication")
        do { try revoked.write("revoked.txt", data: Data(), expectedDigest: nil); await checks.check(false, "revoked grant has no fallback write") }
        catch { await checks.check(!fm.fileExists(atPath: work.appendingPathComponent("revoked.txt").path), "revoked grant has no fallback write") }
        let values = await checks.values
        print(try JSONValue.object(["checks": .array(values), "batch": batch, "undo": undo,
            "organizeFailure": failure, "organizedUndo": organizedUndo, "tree": tree,
            "toolBatch": try JSONValue.decode(jsonText: toolBatch.content), "shellExecution": executed,
            "pressureSeconds": .number(pressureSeconds), "wideTreeSeconds": .number(wideSeconds),
            "failed": .number(Double(values.filter { $0["passed"] != true }.count))]).encodedText())
    }
}
