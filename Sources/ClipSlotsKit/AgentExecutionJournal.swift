import Foundation
import Darwin

/// Identity comes from the host's immutable submission, never model arguments.
public struct AgentExecutionScope: Codable, Equatable, Sendable {
    public let sessionID: String
    public let projectID: String?
    public let turnID: String
    public init(sessionID: String, projectID: String?, turnID: String) {
        self.sessionID = sessionID; self.projectID = projectID; self.turnID = turnID
    }
}

public protocol AgentToolExecutionScoped: AgentToolExecuting {
    var executionScope: AgentExecutionScope { get }
}

/// A reservation is durable before side effects start. Replays return recorded
/// results; an interrupted execution remains unknown until separately checked.
/// The journal makes no claim about exactly-once delivery to a remote service.
public final class AgentExecutionJournal: @unchecked Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public enum Phase: String, Codable, Sendable { case executing, completed }
        public let scope: AgentExecutionScope
        public let callID: String
        public let tool: String
        public let argumentsDigest: String
        public let reservationID: UUID
        public let ownerPID: Int32
        public let startedAt: Date
        public var completedAt: Date?
        public var phase: Phase
        public var result: AgentToolResult?
    }
    public enum Reservation: Sendable {
        case execute(Record), replay(AgentToolResult), unknown(Record)
    }
    private let root: URL
    public init(root: URL) { self.root = root.appendingPathComponent("tool-executions", isDirectory: true) }

    public func reserve(scope: AgentExecutionScope, call: AgentToolCall) throws -> Reservation {
        guard !scope.sessionID.isEmpty, !scope.turnID.isEmpty, !call.id.isEmpty,
              !call.name.isEmpty, call.argumentsJSON.utf8.count <= 1_048_576 else {
            throw AgentOperationError("工具调用身份不完整或参数过大，未执行。")
        }
        let digest = CanvasWorkflowSnapshot.digest(Data(call.argumentsJSON.utf8))
        return try locked(scope: scope, callID: call.id) { url in
            if let existing = try read(url) {
                guard existing.scope == scope, existing.callID == call.id,
                      existing.tool == call.name, existing.argumentsDigest == digest else {
                    throw AgentOperationError("同一工具调用 ID 的参数发生变化，已拒绝重复执行。")
                }
                if existing.phase == .completed, let result = existing.result { return .replay(result) }
                return .unknown(existing)
            }
            let record = Record(scope: scope, callID: call.id, tool: call.name,
                argumentsDigest: digest, reservationID: UUID(), ownerPID: getpid(),
                startedAt: Date(), completedAt: nil, phase: .executing, result: nil)
            try write(record, to: url)
            return .execute(record)
        }
    }

    public func complete(_ reservation: Record, result: AgentToolResult) throws {
        try locked(scope: reservation.scope, callID: reservation.callID) { url in
            guard var record = try read(url), record.reservationID == reservation.reservationID,
                  record.phase == .executing else {
                throw AgentOperationError("工具执行记录已改变，结果尚未确认。")
            }
            record.phase = .completed
            record.result = result
            record.completedAt = Date()
            try write(record, to: url)
        }
    }

    public func records(scope: AgentExecutionScope) throws -> [Record] {
        let directory = scopeDirectory(scope)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try read($0) }.sorted { $0.startedAt < $1.startedAt }
    }

    private func scopeDirectory(_ scope: AgentExecutionScope) -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(scope)) ?? Data()
        return root.appendingPathComponent(CanvasWorkflowSnapshot.digest(bytes), isDirectory: true)
    }
    private func locked<T>(scope: AgentExecutionScope, callID: String, _ body: (URL) throws -> T) throws -> T {
        let directory = scopeDirectory(scope)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let name = CanvasWorkflowSnapshot.digest(Data(callID.utf8))
        let lockURL = directory.appendingPathComponent(name + ".lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AgentOperationError("无法锁定工具执行记录，未执行。") }
        defer { Darwin.close(descriptor) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else {
                throw AgentOperationError("工具记录正在被另一进程使用，请稍后检查。")
            }
            usleep(10_000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body(directory.appendingPathComponent(name + ".json"))
    }
    private func read(_ url: URL) throws -> Record? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 12_000_000 else {
            throw AgentOperationError("工具执行记录格式异常，已保留原文件。")
        }
        // Decode errors are surfaced, never replaced with a fresh reservation.
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    }
    private func write(_ record: Record, to url: URL) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= 12_000_000 else { throw AgentOperationError("工具结果超过记录上限，执行结果需要核查。") }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentOperationError("工具执行记录无法确认落盘。") }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw AgentOperationError("工具执行记录尚未落盘确认。") }
    }
}

public final class AgentJournaledTools: AgentToolExecutionScoped, AgentCLICommandAuthorizing, @unchecked Sendable {
    private let base: AgentToolExecuting
    private let journal: AgentExecutionJournal
    private let scope: AgentExecutionScope
    private let declarations: [AgentToolSpec]
    public var executionScope: AgentExecutionScope { scope }
    public init(base: AgentToolExecuting, journal: AgentExecutionJournal, scope: AgentExecutionScope) {
        self.base = base; self.journal = journal; self.scope = scope
        declarations = base.specs()
    }
    public func specs() -> [AgentToolSpec] { base.specs() }
    public func permitsCLI(_ command: String) -> Bool {
        (base as? AgentCLICommandAuthorizing)?.permitsCLI(command) ?? false
    }
    public func restrictedForPreview() -> AgentJournaledTools {
        .init(base: AgentPreviewTools.restricted(base), journal: journal, scope: scope)
    }
    public func execute(call: AgentToolCall) async -> AgentToolResult {
        do {
            try Task.checkCancellation()
            guard let spec = base.specs().first(where: { $0.name == call.name }) else {
                return .failure("工具未在本轮开放。", code: "TOOL_NOT_ENABLED")
            }
            guard declarations.first(where: { $0.name == call.name }) == spec else {
                return .failure("工具声明已改变，请开启新一轮后再执行。", code: "TOOL_DECLARATION_CHANGED")
            }
            try GenerationSchema.validate(try call.arguments(), schema: spec.parameters)
            let reservation = try await Task.detached { [journal, scope] in
                try journal.reserve(scope: scope, call: call)
            }.value
            switch reservation {
            case .replay(let result): return result
            case .unknown:
                return .failure("此调用已开始，尚无已保存的完成结果。请核查实际内容，不会重复执行。",
                                code: "EXECUTION_UNKNOWN")
            case .execute(let record):
                try Task.checkCancellation()
                let result = await base.execute(call: call)
                try await Task.detached { [journal] in try journal.complete(record, result: result) }.value
                return result
            }
        } catch {
            return .failure(error.localizedDescription,
                code: error is CancellationError ? "CANCELLED" : "EXECUTION_JOURNAL_ERROR")
        }
    }
}
