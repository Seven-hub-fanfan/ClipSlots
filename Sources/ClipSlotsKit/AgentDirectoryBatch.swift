import Foundation
import Darwin

public struct AgentDirectoryWrite: Sendable {
    public let path: String
    public let data: Data
    public let expectedDigest: String?
    public init(path: String, data: Data, expectedDigest: String?) {
        self.path = path; self.data = data; self.expectedDigest = expectedDigest
    }
}

public struct AgentDirectoryMove: Sendable {
    public let source: String
    public let destination: String
    public let expectedIdentity: String
    public init(source: String, destination: String, expectedIdentity: String) {
        self.source = source; self.destination = destination; self.expectedIdentity = expectedIdentity
    }
}

struct AgentDirectoryUndoRecord {
    enum Change {
        case write(path: String, original: Data?, writtenDigest: String)
        case move(source: String, destination: String, identity: String)
        case directory(path: String, identity: String)
    }
    var changes: [Change]
    var bytes: Int
}

extension AgentDirectoryAccess {
    public static let maxBatchItems = 16
    public static let maxBatchBytes = 1_048_576
    public static let maxUndoBytes = 4_194_304

    public static func identity(_ value: stat) -> String {
        if value.st_mode & S_IFMT == S_IFDIR { return directoryIdentity(value) }
        return digest(Data("\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec)".utf8))
    }
    func leaf(_ path: String) throws -> (parts: [String], name: String, parent: Int32) {
        let parts = try components(path)
        guard let name = parts.last else { throw AgentDirectoryError.invalidPath }
        return (Array(parts.dropLast()), name, try directory(Array(parts.dropLast())))
    }
    func verifyParent(_ parts: [String], descriptor: Int32) throws {
        let current = try directory(parts); defer { close(current) }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, fstat(current, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino else { throw AgentDirectoryError.changed }
    }
    func info(_ parent: Int32, _ name: String) throws -> stat? {
        var value = stat()
        if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw AgentDirectoryError.permissionDenied
        }
        guard [S_IFREG, S_IFDIR].contains(value.st_mode & S_IFMT) else { throw AgentDirectoryError.outsideRoot }
        return value
    }
    public func fileIdentity(_ path: String) throws -> String {
        try withDirectoryLock {
            let target = try leaf(path); defer { close(target.parent) }
            guard let value = try info(target.parent, target.name) else { throw AgentDirectoryError.unavailable }
            return Self.identity(value)
        }
    }
    /// Descriptor traversal never follows a link. Every bounded result reports
    /// whether the entry/depth limit or an unreadable subtree prevented completion.
    public func tree(_ path: String = ".", maxDepth: Int = 4, maxEntries: Int = 500,
                     cancelled: @Sendable () -> Bool = { false }) throws -> JSONValue {
        try withDirectoryLock {
            guard (0...16).contains(maxDepth), (1...2000).contains(maxEntries) else { throw AgentDirectoryError.tooLarge }
            let rootParts = try components(path)
            var entries: [JSONValue] = [], errors: [JSONValue] = [], truncated = false
            func walk(_ parts: [String], _ depth: Int) throws {
                guard !cancelled() else { throw AgentDirectoryError.cancelled }
                let fd = try directory(parts)
                guard let stream = fdopendir(fd) else { close(fd); throw AgentDirectoryError.permissionDenied }
                defer { closedir(stream) }
                var children: [(String, stat)] = []
                while let entry = readdir(stream) {
                    try checkGrant()
                    guard !cancelled() else { throw AgentDirectoryError.cancelled }
                    var name = entry.pointee.d_name
                    let capacity = MemoryLayout.size(ofValue: name)
                    let text = withUnsafePointer(to: &name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
                    }
                    if text == "." || text == ".." { continue }
                    if children.count >= maxEntries - entries.count { truncated = true; break }
                    var value = stat()
                    if fstatat(fd, text, &value, AT_SYMLINK_NOFOLLOW) == 0 { children.append((text, value)) }
                    else { errors.append(["path": .string((parts + [text]).joined(separator: "/")), "error_code": "CHANGED"]) }
                }
                for (name, value) in children.sorted(by: { $0.0 < $1.0 }) {
                    try checkGrant()
                    guard !cancelled() else { throw AgentDirectoryError.cancelled }
                    guard entries.count < maxEntries else { truncated = true; return }
                    let childParts = parts + [name], childPath = childParts.joined(separator: "/")
                    let type = value.st_mode & S_IFMT
                    entries.append(["path": .string(childPath), "name": .string(name),
                        "kind": .string(type == S_IFDIR ? "directory" : type == S_IFREG ? "file" : "link_or_special"),
                        "bytes": .number(Double(value.st_size)), "identity": .string(Self.identity(value))])
                    if type == S_IFDIR {
                        if depth >= maxDepth { truncated = true; continue }
                        do { try walk(childParts, depth + 1) }
                        catch AgentDirectoryError.cancelled { throw AgentDirectoryError.cancelled }
                        catch { errors.append(["path": .string(childPath), "error_code": "UNREADABLE"]) }
                    }
                }
            }
            try walk(rootParts, 0)
            return ["path": .string(path), "entries": .array(entries), "errors": .array(errors),
                    "truncated": .bool(truncated), "complete": .bool(!truncated && errors.isEmpty)]
        }
    }
    private func reserveUndo(bytes: Int) throws {
        guard undoRecords.count < 32,
              undoRecords.values.reduce(0, { $0 + $1.bytes }) + bytes <= Self.maxUndoBytes else {
            throw AgentDirectoryError.tooLarge
        }
    }
    private func saveUndo(_ changes: [AgentDirectoryUndoRecord.Change], bytes: Int) -> JSONValue {
        guard !changes.isEmpty else { return .null }
        let id = UUID()
        undoRecords[id] = .init(changes: changes, bytes: bytes)
        return .string(id.uuidString.lowercased())
    }
    /// Approval is outside the descriptor lock; each item rechecks its own hash.
    /// The complete result has one item per input, including cancellation/decline.
    public func batchWrite(_ writes: [AgentDirectoryWrite], accepted: [Bool],
                           cancelled: @Sendable () -> Bool = { false }) throws -> JSONValue {
        if journalContext != nil { return try durableBatchWrite(writes, accepted: accepted, cancelled: cancelled) }
        return try withDirectoryLock {
            guard !writes.isEmpty, writes.count <= Self.maxBatchItems, accepted.count == writes.count,
                  writes.reduce(0, { $0 + $1.data.count }) <= Self.maxBatchBytes else { throw AgentDirectoryError.tooLarge }
            try reserveUndo(bytes: 0)
            var results: [JSONValue] = [], changes: [AgentDirectoryUndoRecord.Change] = [], retained = 0
            var paths: Set<String> = []
            for (index, write) in writes.enumerated() {
                var item: [String: JSONValue] = ["index": .number(Double(index)), "path": .string(write.path)]
                do {
                    guard accepted[index] else { item["status"] = "declined"; results.append(.object(item)); continue }
                    guard !cancelled() else { throw AgentDirectoryError.cancelled }
                    let canonical = try components(write.path).joined(separator: "/")
                    guard paths.insert(canonical).inserted else { throw AgentDirectoryError.changed }
                    let target = try leaf(canonical); defer { close(target.parent) }
                    let original = try readFile(parent: target.parent, name: target.name)
                    guard original.map(Self.digest) == write.expectedDigest else { throw AgentDirectoryError.changed }
                    try reserveUndo(bytes: retained + (original?.count ?? 0))
                    try writeLocked(canonical, data: write.data, expectedDigest: write.expectedDigest, cancelled: cancelled)
                    let hash = Self.digest(write.data)
                    changes.append(.write(path: canonical, original: original, writtenDigest: hash))
                    retained += original?.count ?? 0
                    item["status"] = "written"; item["sha256"] = .string(hash)
                    item["written_bytes"] = .number(Double(write.data.count))
                } catch {
                    item["status"] = "failed"; item["error_code"] = Self.errorCode(error)
                    item["detail"] = .string(error.localizedDescription)
                }
                results.append(.object(item))
            }
            return ["items": .array(results), "undo_id": saveUndo(changes, bytes: retained),
                    "complete": .bool(results.allSatisfy { $0["status"] == "written" })]
        }
    }
    func moveLocked(source: String, destination: String, identity: String) throws {
        let from = try leaf(source); defer { close(from.parent) }
        let to = try leaf(destination); defer { close(to.parent) }
        guard let value = try info(from.parent, from.name), Self.identity(value) == identity,
              try info(to.parent, to.name) == nil else { throw AgentDirectoryError.changed }
        try verifyParent(from.parts, descriptor: from.parent)
        try verifyParent(to.parts, descriptor: to.parent)
        guard renameatx_np(from.parent, from.name, to.parent, to.name, UInt32(RENAME_EXCL)) == 0 else {
            throw AgentDirectoryError.changed
        }
        var moved = stat()
        guard fstatat(to.parent, to.name, &moved, AT_SYMLINK_NOFOLLOW) == 0,
              [S_IFREG, S_IFDIR].contains(moved.st_mode & S_IFMT), Self.identity(moved) == identity else {
            // A concurrent source replacement can race rename. Restore only into
            // an absent source, then report conflict; never overwrite either path.
            if renameatx_np(to.parent, to.name, from.parent, from.name, UInt32(RENAME_EXCL)) == 0 {
                throw AgentDirectoryError.changed
            }
            throw AgentDirectoryError.conflictBackup(destination)
        }
        _ = fsync(from.parent); _ = fsync(to.parent)
    }
    public func organize(_ moves: [AgentDirectoryMove], createDirectories: [String] = [],
                         cancelled: @Sendable () -> Bool = { false }) throws -> JSONValue {
        if journalContext != nil {
            return try durableOrganize(moves, createDirectories: createDirectories, cancelled: cancelled)
        }
        return try withDirectoryLock {
            guard !moves.isEmpty, moves.count <= Self.maxBatchItems,
                  createDirectories.count <= Self.maxBatchItems else { throw AgentDirectoryError.tooLarge }
            try reserveUndo(bytes: 0)
            // Disallow self/ancestor moves and duplicate destinations. Chained
            // operations are allowed and use sequential, exact identity checks.
            var destinations: Set<String> = []
            for move in moves {
                let source = try components(move.source).joined(separator: "/")
                let destination = try components(move.destination).joined(separator: "/")
                guard !source.isEmpty, !destination.isEmpty, source != destination,
                      !destination.hasPrefix(source + "/"), destinations.insert(destination).inserted else {
                    throw AgentDirectoryError.invalidPath
                }
            }
            var changes: [AgentDirectoryUndoRecord.Change] = [], steps: [JSONValue] = []
            var failure: String?
            do {
                for path in createDirectories {
                    guard !cancelled() else { throw AgentDirectoryError.cancelled }
                    let target = try leaf(path); defer { close(target.parent) }
                    guard try info(target.parent, target.name) == nil else { throw AgentDirectoryError.changed }
                    try verifyParent(target.parts, descriptor: target.parent)
                    guard mkdirat(target.parent, target.name, 0o700) == 0,
                          let value = try info(target.parent, target.name) else { throw AgentDirectoryError.permissionDenied }
                    changes.append(.directory(path: path, identity: Self.identity(value)))
                    steps.append(["action": "mkdir", "path": .string(path), "status": "created"])
                }
                for (index, move) in moves.enumerated() {
                    guard !cancelled() else { throw AgentDirectoryError.cancelled }
                    try moveLocked(source: move.source, destination: move.destination, identity: move.expectedIdentity)
                    changes.append(.move(source: move.source, destination: move.destination, identity: move.expectedIdentity))
                    steps.append(["index": .number(Double(index)), "source": .string(move.source),
                                  "destination": .string(move.destination), "status": "moved"])
                }
            } catch { failure = Self.errorCode(error).stringValue }
            if let failure {
                let rollback = rollbackLocked(changes)
                return ["complete": false, "error_code": .string(failure), "steps": .array(steps),
                        "rollback": .array(rollback.results),
                        "rollback_complete": .bool(rollback.remaining.isEmpty),
                        "undo_id": saveUndo(rollback.remaining, bytes: 0)]
            }
            return ["complete": true, "steps": .array(steps), "undo_id": saveUndo(changes, bytes: 0)]
        }
    }
    private func rollbackLocked(_ changes: [AgentDirectoryUndoRecord.Change])
        -> (results: [JSONValue], remaining: [AgentDirectoryUndoRecord.Change]) {
        var results: [JSONValue] = [], remaining: [AgentDirectoryUndoRecord.Change] = []
        for (index, change) in changes.enumerated().reversed() {
            var path = ""
            do {
                switch change {
                case .write(let targetPath, let original, let digest):
                    path = targetPath
                    if let original { try writeLocked(path, data: original, expectedDigest: digest) }
                    else {
                        let target = try leaf(path); defer { close(target.parent) }
                        guard try readFile(parent: target.parent, name: target.name).map(Self.digest) == digest else {
                            throw AgentDirectoryError.changed
                        }
                        try verifyParent(target.parts, descriptor: target.parent)
                        let quarantine = ".clipslots-conflict-\(UUID().uuidString)"
                        guard renameatx_np(target.parent, target.name, target.parent, quarantine, UInt32(RENAME_EXCL)) == 0 else {
                            throw AgentDirectoryError.changed
                        }
                        if (try? readFile(parent: target.parent, name: quarantine).map(Self.digest)) != digest {
                            if renameatx_np(target.parent, quarantine, target.parent, target.name, UInt32(RENAME_EXCL)) == 0 {
                                throw AgentDirectoryError.changed
                            }
                            throw AgentDirectoryError.conflictBackup((target.parts + [quarantine]).joined(separator: "/"))
                        }
                        guard unlinkat(target.parent, quarantine, 0) == 0 else {
                            throw AgentDirectoryError.conflictBackup((target.parts + [quarantine]).joined(separator: "/"))
                        }
                    }
                case .move(let source, let destination, let identity):
                    path = destination
                    try moveLocked(source: destination, destination: source, identity: identity)
                case .directory(let targetPath, let identity):
                    path = targetPath
                    let target = try leaf(path); defer { close(target.parent) }
                    guard let value = try info(target.parent, target.name),
                          // Directory size/mtime change as children are moved. Keep
                          // the original inode identity but require it to be empty.
                          Self.directoryIdentity(value) == identity else {
                        throw AgentDirectoryError.changed
                    }
                    try verifyParent(target.parts, descriptor: target.parent)
                    guard unlinkat(target.parent, target.name, AT_REMOVEDIR) == 0 else { throw AgentDirectoryError.changed }
                }
                results.append(["index": .number(Double(index)), "path": .string(path), "status": "reverted"])
            } catch {
                remaining.insert(change, at: 0)
                results.append(["index": .number(Double(index)), "path": .string(path),
                                "status": "conflict", "error_code": Self.errorCode(error),
                                "detail": .string(error.localizedDescription)])
            }
        }
        return (results, remaining)
    }
    static func directoryIdentity(_ value: stat) -> String {
        digest(Data("\(value.st_dev):\(value.st_ino):\(value.st_mode & S_IFMT)".utf8))
    }
    public func undo(_ id: UUID, cancelled: @Sendable () -> Bool = { false }) throws -> JSONValue {
        guard !cancelled() else { throw AgentDirectoryError.cancelled }
        if journalContext != nil { return try durableUndo(id, cancelled: cancelled) }
        return try withDirectoryLock {
            guard let record = undoRecords.removeValue(forKey: id) else { throw AgentDirectoryError.invalidProposal }
            let result = rollbackLocked(record.changes)
            // The original identity is consumed. Remaining conflicts receive a new
            // identity for an explicit later retry, never an automatic repeat.
            return ["complete": .bool(result.remaining.isEmpty), "items": .array(result.results),
                    "undo_id": saveUndo(result.remaining, bytes: record.bytes)]
        }
    }
    public static func errorCode(_ error: Error) -> JSONValue {
        switch error {
        case AgentDirectoryError.changed: return "CHANGED"
        case AgentDirectoryError.revoked: return "GRANT_REVOKED"
        case AgentDirectoryError.cancelled, is CancellationError: return "CANCELLED"
        case AgentDirectoryError.outsideRoot: return "OUTSIDE_ROOT"
        case AgentDirectoryError.tooLarge: return "TOO_LARGE"
        case AgentDirectoryError.invalidProposal: return "INVALID_PROPOSAL"
        case AgentDirectoryError.conflictBackup: return "CONFLICT_BACKUP"
        case AgentDirectoryError.corruptJournal: return "JOURNAL_UNAVAILABLE"
        default: return "LOCAL_DIRECTORY_ERROR"
        }
    }
}
