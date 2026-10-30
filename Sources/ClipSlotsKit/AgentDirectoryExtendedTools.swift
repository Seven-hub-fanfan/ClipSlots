import Foundation
import Darwin

final class AgentDirectoryOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.withLock { stopped } }
    func cancel() { lock.withLock { stopped = true } }
}

actor AgentDirectoryShellProposals {
    struct Proposal: Sendable {
        let id: UUID
        let grantID: UUID
        let script: String
        let timeout: TimeInterval
        let expires: TimeInterval
    }
    private var pending: [UUID: Proposal] = [:]
    func propose(grantID: UUID, script: String, timeout: TimeInterval) throws -> Proposal {
        let now = ProcessInfo.processInfo.systemUptime
        pending = pending.filter { $0.value.expires > now }
        guard pending.count < 32, !script.isEmpty, script.utf8.count <= 65_536,
              !script.contains("\0"), timeout.isFinite, (1...120).contains(timeout) else {
            throw AgentDirectoryError.tooLarge
        }
        let proposal = Proposal(id: UUID(), grantID: grantID, script: script, timeout: timeout, expires: now + 300)
        pending[proposal.id] = proposal
        return proposal
    }
    func claim(_ id: UUID, grantID: UUID) throws -> Proposal {
        guard let proposal = pending.removeValue(forKey: id), proposal.grantID == grantID,
              proposal.expires > ProcessInfo.processInfo.systemUptime else { throw AgentDirectoryError.invalidProposal }
        return proposal
    }
}

extension AgentDirectoryTools {
    func checkCurrent() async throws {
        try Task.checkCancellation()
        guard access.isActive, await isCurrent() else { throw AgentDirectoryError.revoked }
    }
    func directoryOperation<T: Sendable>(
        _ body: @escaping @Sendable (@Sendable () -> Bool) throws -> T
    ) async throws -> T {
        let cancellation = AgentDirectoryOperationCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try body { cancellation.isCancelled }
            }.value
        } onCancel: { cancellation.cancel() }
    }
    func normalizedPath(_ supplied: String) -> String {
        var path = absolutePaths && supplied.hasPrefix("/") ? String(supplied.dropFirst()) : supplied
        if absolutePaths {
            for alias in ["var", "tmp", "etc"] where path == alias || path.hasPrefix(alias + "/") {
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/" + alias),
                   target == "private/" + alias || target == "/private/" + alias {
                    path = "private/" + path
                }
            }
        }
        return path
    }
    func extendedSpecs(path: JSONValue) -> [AgentToolSpec] {
        func object(_ fields: [String: JSONValue], _ required: [String]) -> JSONValue {
            ["type": "object", "additionalProperties": false, "properties": .object(fields),
             "required": .array(required.map(JSONValue.string))]
        }
        func spec(_ name: String, _ description: String, _ parameters: JSONValue) -> AgentToolSpec {
            .init(name: name, description: description, parameters: parameters, originLabel: "本地工作目录")
        }
        let token: JSONValue = ["type": "string"]
        let writes = object(["path": path, "content": ["type": "string"], "expected_sha256": token],
                            ["path", "content", "expected_sha256"])
        let moves = object(["source": path, "destination": path, "expected_identity": token],
                           ["source", "destination", "expected_identity"])
        var result = [
            spec("local_directory_tree", "读取目录树，最多2000项/16层；complete=false表示未读全。不跟随符号链接。identity可用于整理前核对。",
                 object(["path": path, "max_depth": ["type": "integer", "minimum": 0, "maximum": 16],
                         "max_entries": ["type": "integer", "minimum": 1, "maximum": 2000]], ["path"])),
            spec("local_directory_history", "读取当前会话/项目/授权目录的撤销日志，包含重启前undo_id和执行未知项。只核对磁盘，不重做或撤销操作。", object([:], []))
        ]
        if !readOnly && (absolutePaths || access.isWritable) {
            result += [
                spec("local_batch_write", "批量写入最多16个UTF-8文件、每文件256KiB、合计1MiB。按项确认/返回失败；成功项可用undo_id撤销。新文件expected_sha256为空，更新用最近读取哈希。父目录须存在。",
                     object(["writes": ["type": "array", "minItems": 1, "maxItems": 16, "items": writes]], ["writes"])),
                spec("local_organize_files", "按顺序移动普通文件或目录，不覆盖目标、不跟随链接；expected_identity取自目录树。可先创建最多16个目录；任一步失败逆序回滚并逐项返回冲突。最多16个移动。成功返回undo_id。",
                     object(["moves": ["type": "array", "minItems": 1, "maxItems": 16, "items": moves],
                             "create_directories": ["type": "array", "maxItems": 16, "items": path]], ["moves"])),
                spec("local_undo_directory", "确认后消费当前会话/项目/授权目录的undo_id并逆序撤销，支持跨调用和重启。文件已变化或执行未知则保留并返回冲突；余项给新undo_id以供显式核对重试。旧ID不能再消费。",
                     object(["undo_id": token], ["undo_id"]))
            ]
        }
        if allowShell && !readOnly {
            result += [
                spec("local_propose_shell", "提出一次性本机shell操作，返回proposal_id，不执行。仅完全访问模式可用。脚本最多64KiB，超时1至120秒；执行仍须用户确认，工作目录不是文件/网络沙箱。",
                     object(["script": ["type": "string"], "timeout_seconds": ["type": "number", "minimum": 1, "maximum": 120]], ["script"])),
                spec("local_execute_proposal", "消费本轮proposal_id，展示原脚本与目录供确认后执行。拒绝/过期/取消也消费；不可二次执行。取消或超时终止进程组，stdout/stderr合计64KiB。",
                     object(["proposal_id": token], ["proposal_id"]))
            ]
        }
        return result
    }
    private func approve(_ request: AgentInteraction, automatic: Bool = false) async throws -> JSONValue? {
        let answer = DirectoryApprovalAnswer()
        // A separate interaction captures the validated, immutable response.
        let interaction = AgentInteraction(kind: request.kind, params: request.params, timeout: request.remainingTime) {
            answer.set($0)
        }
        defer { interaction.invalidate() }
        if automatic { return ["decision": "accept"] }
        await onInteraction(interaction)
        while answer.value == nil && interaction.isPending {
            try await checkCurrent()
            try await Task.sleep(for: .milliseconds(40))
        }
        try await checkCurrent()
        return answer.value
    }
    private func approval(kind: AgentInteraction.Kind, params: JSONValue, automatic: Bool = false) async throws -> JSONValue? {
        let request = AgentInteraction(kind: kind, params: params, reply: { _ in })
        defer { request.invalidate() }
        return try await approve(request, automatic: automatic)
    }
    func executeExtended(call: AgentToolCall, input: JSONValue) async throws -> AgentToolResult {
        let result: JSONValue
        switch call.name {
        case "local_directory_history":
            result = try await directoryOperation { [access] _ in try access.directoryHistory() }
        case "local_directory_tree":
            let path = normalizedPath(input["path"]!.stringValue!)
            let depth = input["max_depth"]?.intValue ?? 4, count = input["max_entries"]?.intValue ?? 500
            if confirmReads {
                guard try await approval(kind: .commandApproval, params: [
                    "command": .string(call.name), "title": "读取目录树", "preview": .string(path),
                    "availableDecisions": ["accept", "decline"]
                ])?["decision"] == "accept" else { return .failure("未允许本次读取。", code: "DECLINED") }
            }
            result = try await directoryOperation { [access] cancelled in
                try access.tree(path, maxDepth: depth, maxEntries: count, cancelled: cancelled)
            }
        case "local_batch_write":
            let writes = (input["writes"]?.arrayValue ?? []).map {
                AgentDirectoryWrite(path: normalizedPath($0["path"]!.stringValue!), data: Data($0["content"]!.stringValue!.utf8),
                                    expectedDigest: $0["expected_sha256"]!.stringValue!.isEmpty ? nil : $0["expected_sha256"]!.stringValue!)
            }
            guard writes.allSatisfy({ $0.data.count <= AgentDirectoryAccess.maxFileBytes }),
                  writes.reduce(0, { $0 + $1.data.count }) <= AgentDirectoryAccess.maxBatchBytes else {
                throw AgentDirectoryError.tooLarge
            }
            let items: [JSONValue] = writes.enumerated().map { index, write in
                ["index": .number(Double(index)), "action": "write_file", "title": .string(write.path),
                 "path": .string(write.path), "preview": .string(String(decoding: write.data, as: UTF8.self)),
                 "item": ["changes": [["path": .string(write.path), "diff": .string(String(decoding: write.data, as: UTF8.self))]]],
                 "availableDecisions": ["accept", "decline"], "allowedModifications": []]
            }
            let accepted: [Bool]
            if automaticWrites { accepted = writes.map { _ in true } }
            else {
                let response = try await approval(kind: .fileApproval, params: [
                    "cwd": .string(access.url.path), "reason": "逐项确认本地批量写入", "items": .array(items)
                ])
                accepted = (response?["items"]?.arrayValue ?? []).map { $0["decision"] == "accept" }
            }
            result = try await directoryOperation { [access] cancelled in
                try access.batchWrite(writes, accepted: accepted.count == writes.count ? accepted : writes.map { _ in false },
                                      cancelled: cancelled)
            }
        case "local_organize_files":
            let moves = (input["moves"]?.arrayValue ?? []).map {
                AgentDirectoryMove(source: normalizedPath($0["source"]!.stringValue!),
                    destination: normalizedPath($0["destination"]!.stringValue!), expectedIdentity: $0["expected_identity"]!.stringValue!)
            }
            let directories = (input["create_directories"]?.arrayValue ?? []).map { normalizedPath($0.stringValue!) }
            guard try await approval(kind: .fileApproval, params: [
                "cwd": .string(access.url.path), "reason": "整理本地文件；失败会逆序回滚",
                "item": ["changes": .array(moves.map { ["path": .string($0.source), "diff": .string("移动到 " + $0.destination)] }
                    + directories.map { ["path": .string($0), "diff": "创建目录"] })]
            ], automatic: automaticWrites)?["decision"] == "accept" else {
                return .failure("整理未获允许，文件未改动。", code: "DECLINED")
            }
            result = try await directoryOperation { [access] cancelled in
                try access.organize(moves, createDirectories: directories, cancelled: cancelled)
            }
        case "local_undo_directory":
            guard let id = UUID(uuidString: input["undo_id"]?.stringValue ?? "") else { throw AgentDirectoryError.invalidProposal }
            guard try await approval(kind: .fileApproval, params: [
                "cwd": .string(access.url.path), "reason": "逆序撤销所属会话的目录操作；并发改动与执行未知项将保留",
                "item": ["changes": [["path": .string(id.uuidString), "diff": "撤销目录操作"]]]
            ])?["decision"] == "accept" else { return .failure("未允许撤销。", code: "DECLINED") }
            result = try await directoryOperation { [access] cancelled in
                guard !cancelled() else { throw AgentDirectoryError.cancelled }
                return try access.undo(id, cancelled: cancelled)
            }
        case "local_propose_shell":
            guard allowShell && !readOnly else { throw AgentDirectoryError.permissionDenied }
            let timeout: TimeInterval
            if case .number(let value)? = input["timeout_seconds"] { timeout = value } else { timeout = 45 }
            let proposal = try await shellProposals.propose(grantID: access.grantID,
                script: input["script"]!.stringValue!, timeout: timeout)
            result = ["proposal_id": .string(proposal.id.uuidString.lowercased()), "executed": false,
                      "expires_in_seconds": 300, "cwd": .string(access.url.path)]
        case "local_execute_proposal":
            guard allowShell && !readOnly, let id = UUID(uuidString: input["proposal_id"]?.stringValue ?? "") else {
                throw AgentDirectoryError.invalidProposal
            }
            let proposal = try await shellProposals.claim(id, grantID: access.grantID)
            guard try await approval(kind: .commandApproval, params: [
                "command": .string(proposal.script), "title": "执行一次性本机命令",
                "cwd": .string(access.url.path),
                "reason": "使用完全访问权限；工作目录不是文件或网络沙箱",
                "preview": .string(proposal.script), "availableDecisions": ["accept", "decline"]
            ])?["decision"] == "accept" else {
                return .failure("命令未获允许，提案已消费。", code: "DECLINED")
            }
            guard proposal.expires > ProcessInfo.processInfo.systemUptime else { throw AgentDirectoryError.invalidProposal }
            let descriptor = try access.withDirectoryLock {
                try access.directory([])
            }
            defer { close(descriptor) }
            let outcome = await withTaskGroup(of: AgentProcessResult.self) { group in
                group.addTask {
                    await AgentProcessRunner.run(executable: "/bin/sh", arguments: ["-c", proposal.script],
                        timeout: proposal.timeout, maxOutputBytes: 65_536, currentDirectoryDescriptor: descriptor)
                }
                group.addTask { [self] in
                    while !Task.isCancelled {
                        let current = await isCurrent()
                        if !access.isActive || !current {
                            return .init(exitCode: -1, stdout: "", stderr: "目录授权已失效。", timedOut: false, cancelled: true)
                        }
                        do { try await Task.sleep(for: .milliseconds(40)) }
                        catch { break }
                    }
                    return .init(exitCode: -1, stdout: "", stderr: "", timedOut: false, cancelled: true)
                }
                let first = await group.next()!
                group.cancelAll()
                // Exiting the task group waits for the runner to finish group termination.
                return first
            }
            result = ["proposal_id": .string(id.uuidString.lowercased()), "exit_code": .number(Double(outcome.exitCode)),
                      "stdout": .string(outcome.stdout), "stderr": .string(outcome.stderr),
                      "timed_out": .bool(outcome.timedOut), "cancelled": .bool(outcome.cancelled),
                      "output_truncated": .bool(outcome.outputTruncated), "succeeded": .bool(outcome.succeeded)]
        default: throw AgentDirectoryError.permissionDenied
        }
        return .init(content: try result.encodedText(), summary: "本地目录操作已返回")
    }
}

private final class DirectoryApprovalAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: JSONValue?
    var value: JSONValue? { lock.withLock { answer } }
    func set(_ value: JSONValue) { lock.withLock { if answer == nil { answer = value } } }
}
