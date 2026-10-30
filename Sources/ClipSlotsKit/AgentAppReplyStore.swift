import Foundation
import Darwin

/// Independent SQLite ledger: changing the active run never drops unresolved replies.
/// Every operation rereads disk under an OS lock. An attempt reservation commits before POST.
final class AgentAppReplyStore: @unchecked Sendable {
    let file: URL
    private let directory: URL
    private let lock: StorageLock
    #if DEBUG
    var testBoundary: ((String) -> Void)?
    var testQuotaBytes: Int64?
    #endif

    init(directory: URL) throws {
        guard directory.isFileURL else { throw AgentAppReplyError.preflight }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        file = self.directory.appendingPathComponent("app-replies.sqlite3")
        lock = StorageLock(lockURL: self.directory.appendingPathComponent(".app-replies.lock"))
    }

    private func transaction<T>(_ body: (AgentGatewayJournalDatabase) throws -> T) throws -> T {
        do {
            return try lock.withLock {
                guard !lock.isDegraded else { throw AgentAppReplyError.preflight }
                var info = stat()
                let exists = lstat(file.path, &info) == 0
                guard exists || errno == ENOENT else { throw AgentAppReplyError.preflight }
                let db = try AgentGatewayJournalDatabase(file: file, create: !exists)
                guard try db.scalar("PRAGMA user_version") == 2,
                      try db.textScalar("PRAGMA quick_check") == "ok" else { throw AgentAppReplyError.preflight }
                try db.execute("BEGIN IMMEDIATE")
                do {
                    let header = Data("clipslots.app-replies.v1".utf8)
                    if let stored = try db.value("header") {
                        guard stored == header else { throw AgentAppReplyError.preflight }
                    } else {
                        guard try db.scalar("SELECT COUNT(*) FROM state") == 0 else { throw AgentAppReplyError.preflight }
                        try db.putValue("header", data: header)
                    }
                    let result = try body(db)
                    #if DEBUG
                    testBoundary?("rows-written")
                    let quota = testQuotaBytes ?? (128 * 1024 * 1024)
                    #else
                    let quota: Int64 = 128 * 1024 * 1024
                    #endif
                    guard try db.scalar("SELECT COALESCE(SUM(length(payload)),0) FROM state") <= quota,
                          try db.scalar("SELECT COUNT(*) FROM state") <= 4097 else { throw AgentAppReplyError.preflight }
                    try db.execute("COMMIT")
                    #if DEBUG
                    testBoundary?("committed")
                    #endif
                    return result
                } catch {
                    try? db.execute("ROLLBACK")
                    throw error
                }
            }
        } catch let error as AgentAppReplyError { throw error }
        catch { throw AgentAppReplyError.preflight }
    }

    private func read(_ id: String, _ db: AgentGatewayJournalDatabase) throws -> AgentAppReplySnapshot? {
        guard id.utf8.count == 36, let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else {
            throw AgentAppReplyError.preflight
        }
        guard let data = try db.value("reply:" + id) else { return nil }
        guard data.count <= 128 * 1024 else { throw AgentAppReplyError.preflight }
        let record = try JSONDecoder().decode(AgentAppReplySnapshot.self, from: data)
        try record.submission.validate()
        guard record.submission.replyID == id, record.attempt < UInt64.max,
              (record.state == .saved) == (record.attempt == 0),
              (record.state == .accepted) == (record.receipt != nil),
              (record.state == .rejected) == (record.rejectionStatus != nil),
              record.rejectionStatus.map({ AgentAppReplyClient.rejections.contains($0) }) ?? true else {
            throw AgentAppReplyError.preflight
        }
        if let receipt = record.receipt { try receipt.validate(for: record.submission, readback: receipt.state != nil) }
        return record
    }

    private func save(_ record: AgentAppReplySnapshot, _ db: AgentGatewayJournalDatabase) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= 128 * 1024 else { throw AgentAppReplyError.preflight }
        try db.putValue("reply:" + record.submission.replyID, data: data)
    }

    func load(_ id: String) throws -> AgentAppReplySnapshot? { try transaction { try read(id, $0) } }

    /// Native recovery can discover unresolved identities without regenerating a page UUID.
    func records(binding: AgentRunBinding) throws -> [AgentAppReplySnapshot] {
        try transaction { db in
            try db.allValues().compactMap { key, _ in
                guard key.hasPrefix("reply:"), let record = try read(String(key.dropFirst(6)), db) else { return nil }
                return AgentGatewayDecisionIdentity.bindingBytes(record.submission.origin.authority.binding, binding)
                    ? record : nil
            }.sorted { $0.submission.replyID < $1.submission.replyID }
        }
    }

    @discardableResult
    func prepare(_ submission: AgentAppReplySubmission) throws -> AgentAppReplySnapshot {
        try submission.validate()
        return try transaction { db in
            if let prior = try read(submission.replyID, db) {
                guard prior.submission == submission else { throw AgentAppReplyError.preflight }
                return prior
            }
            var count = 0
            for (key, _) in try db.allValues() where key.hasPrefix("reply:") {
                guard let prior = try read(String(key.dropFirst(6)), db) else { throw AgentAppReplyError.preflight }
                let old = prior.submission.origin, incoming = submission.origin
                if AgentGatewayDecisionIdentity.bytes(old.endpoint.absoluteString, incoming.endpoint.absoluteString),
                   AgentGatewayDecisionIdentity.bindingBytes(old.authority.binding, incoming.authority.binding),
                   AgentGatewayDecisionIdentity.bytes(old.authority.originRunID, incoming.authority.originRunID) { count += 1 }
            }
            guard count < 128 else { throw AgentAppReplyError.preflight }
            let record = AgentAppReplySnapshot(submission: submission)
            try save(record, db); return record
        }
    }

    /// expectedAttempt prevents a delayed explicit retry from consuming another attempt.
    func claim(_ id: String, expectedAttempt: UInt64, explicitRetry: Bool) throws -> AgentAppReplySnapshot {
        try transaction { db in
            guard var record = try read(id, db), record.attempt == expectedAttempt,
                  record.receipt == nil, record.attempt < UInt64.max - 1,
                  explicitRetry || record.state == .saved else { throw AgentAppReplyError.unknown }
            record.attempt += 1; record.state = .unknown; record.rejectionStatus = nil
            try save(record, db); return record
        }
    }

    @discardableResult
    func reject(_ id: String, attempt: UInt64, status: Int) throws -> AgentAppReplySnapshot {
        try transaction { db in
            guard var record = try read(id, db), AgentAppReplyClient.rejections.contains(status) else {
                throw AgentAppReplyError.preflight
            }
            if record.attempt == attempt, record.receipt == nil {
                record.state = .rejected; record.rejectionStatus = status; try save(record, db)
            }
            return record
        }
    }

    @discardableResult
    func accept(_ id: String, receipt: AgentAppReplyReceipt, readback: Bool) throws -> AgentAppReplySnapshot {
        try transaction { db in
            guard var record = try read(id, db), record.attempt > 0 else { throw AgentAppReplyError.unknown }
            try receipt.validate(for: record.submission, readback: readback)
            if let prior = record.receipt {
                guard prior.sameAcceptance(as: receipt) else { throw AgentAppReplyError.unknown }
                // A POST receipt or late progress cannot remove a proven execution terminal.
                if receipt.state == nil || prior.state == "terminal" && receipt.state != "terminal" { return record }
                if prior.state == "terminal", receipt.phase != prior.phase { throw AgentAppReplyError.unknown }
            }
            record.receipt = receipt; record.state = .accepted; record.rejectionStatus = nil
            try save(record, db); return record
        }
    }
}
