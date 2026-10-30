import Foundation
import Darwin

/// App-private storage and an immutable owner. A new turn can reuse an owner,
/// but a different conversation/project/authorization/root never opens its log.
public struct AgentDirectoryJournalContext: Sendable {
    public let root: URL
    public let authorizationID: String
    public let sessionID: String
    public let projectID: String?
    public init(root: URL, authorizationID: String, sessionID: String, projectID: String?) {
        self.root = root; self.authorizationID = authorizationID
        self.sessionID = sessionID; self.projectID = projectID
    }
}

private struct DirectoryJournalOwner: Codable, Equatable {
    var authorization: String
    var session: String
    var project: String?
    var device: UInt64
    var inode: UInt64
}

private struct DirectoryJournalStep: Codable {
    var kind: String
    var path: String
    var destination: String?
    var identity: String?
    var original: Data?
    var originalToken: String?
    var originalMode: UInt32?
    var writtenMode: UInt32?
    var writtenDigest: String?
    var writtenBytes: Int = 0
    var afterToken: String?
    var temporary: String?
    var reverseTemporary: String?
    var reverseToken: String?
    var cleanupPaths: [String]?
    var previousReverseTokens: [String]?
    var state: String = "intent"
}

private struct DirectoryJournalRecord: Codable {
    var id = UUID()
    var created = Date()
    var steps: [DirectoryJournalStep] = []
}

private struct DirectoryJournalDocument: Codable {
    var version = 1
    var owner: DirectoryJournalOwner
    var records: [DirectoryJournalRecord] = []
}

/// Cross-object and cross-process exclusion uses an owner-only no-follow flock.
/// The journal is fsynced before each side effect and after every transition.
/// Opening a journal never modifies the selected directory.
private final class DirectoryJournalFile {
    static let maxEncodedBytes = 12_582_912
    let directory: Int32
    let lockFile: Int32
    let name: String
    let owner: DirectoryJournalOwner
    var document: DirectoryJournalDocument

    init(context: AgentDirectoryJournalContext, owner: DirectoryJournalOwner, selectedRoot: URL) throws {
        guard context.root.isFileURL, !context.root.path.contains("\0"),
              !context.sessionID.isEmpty, !context.authorizationID.isEmpty else {
            throw AgentDirectoryError.corruptJournal
        }
        let supplied = context.root.standardizedFileURL
        let root = supplied.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(supplied.lastPathComponent, isDirectory: true)
        // The selected directory must not be able to replace its own undo bytes.
        // Full-access / remains governed by full-access authority, not a sandbox.
        guard selectedRoot.path == "/" || !(root.path == selectedRoot.path
            || root.path.hasPrefix(selectedRoot.path + "/")) else { throw AgentDirectoryError.corruptJournal }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw AgentDirectoryError.corruptJournal }
        var value = stat()
        guard fstat(directory, &value) == 0, value.st_uid == getuid(),
              value.st_mode & 0o077 == 0 else { close(directory); throw AgentDirectoryError.corruptJournal }
        self.owner = owner
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        name = AgentDirectoryAccess.digest(try encoder.encode(owner)) + ".json"
        lockFile = openat(directory, name + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFile >= 0 else { close(directory); throw AgentDirectoryError.corruptJournal }
        guard fstat(lockFile, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == getuid(), value.st_nlink == 1, value.st_mode & 0o077 == 0,
              flock(lockFile, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFile); close(directory); throw AgentDirectoryError.corruptJournal
        }
        document = .init(owner: owner)
        do {
            if let data = try read() {
                let saved = try JSONDecoder().decode(DirectoryJournalDocument.self, from: data)
                guard saved.version == 1, saved.owner == owner, saved.records.count <= 32,
                      Set(saved.records.map(\.id)).count == saved.records.count,
                      saved.records.allSatisfy({ $0.steps.count <= 32 && $0.steps.allSatisfy {
                          ["write", "move", "directory"].contains($0.kind)
                          && ["intent", "ready", "applied", "reverting", "reverted", "notApplied", "unknown"].contains($0.state)
                          && ($0.original?.count ?? 0) <= AgentDirectoryAccess.maxFileBytes
                      } }), Self.retainedBytes(saved) <= AgentDirectoryAccess.maxUndoBytes else {
                    throw AgentDirectoryError.corruptJournal
                }
                document = saved
            }
        } catch {
            flock(lockFile, LOCK_UN); close(lockFile); close(directory)
            throw AgentDirectoryError.corruptJournal
        }
    }
    deinit { flock(lockFile, LOCK_UN); close(lockFile); close(directory) }
    static func retainedBytes(_ document: DirectoryJournalDocument) -> Int {
        document.records.reduce(0) { $0 + $1.steps.reduce(0) { $0 + ($1.original?.count ?? 0) } }
    }
    func reserve(bytes: Int = 0) throws {
        guard document.records.count < 32,
              Self.retainedBytes(document) + bytes <= AgentDirectoryAccess.maxUndoBytes else {
            throw AgentDirectoryError.tooLarge
        }
    }
    private func read() throws -> Data? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw AgentDirectoryError.corruptJournal
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= Self.maxEncodedBytes else { throw AgentDirectoryError.corruptJournal }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; throw AgentDirectoryError.corruptJournal }
            if n == 0 { break }
            result.append(contentsOf: buffer.prefix(n))
            guard result.count <= Self.maxEncodedBytes else { throw AgentDirectoryError.corruptJournal }
        }
        guard result.count == info.st_size else { throw AgentDirectoryError.corruptJournal }
        return result
    }
    func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maxEncodedBytes else { throw AgentDirectoryError.tooLarge }
        let temporary = "." + UUID().uuidString + ".tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentDirectoryError.corruptJournal }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw AgentDirectoryError.corruptJournal }
                guard n > 0 else { throw AgentDirectoryError.corruptJournal }
                offset += n
            }
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, name) == 0,
              fsync(directory) == 0 else { throw AgentDirectoryError.corruptJournal }
    }
}

extension AgentDirectoryAccess {
    /// Birth time avoids treating a later inode reuse as the same file.
    static func fileToken(_ value: stat) -> String {
        digest(Data("\(value.st_dev):\(value.st_ino):\(value.st_mode & S_IFMT):\(value.st_birthtimespec.tv_sec):\(value.st_birthtimespec.tv_nsec)".utf8))
    }
    private func journalFile() throws -> DirectoryJournalFile {
        guard let context = journalContext else { throw AgentDirectoryError.corruptJournal }
        let fd = try directory([]); defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw AgentDirectoryError.revoked }
        return try DirectoryJournalFile(context: context, owner: .init(
            authorization: context.authorizationID, session: context.sessionID, project: context.projectID,
            device: UInt64(value.st_dev), inode: UInt64(value.st_ino)), selectedRoot: url)
    }
    private func current(_ path: String) throws -> (stat?, Data?) {
        let target = try leaf(path); defer { close(target.parent) }
        let value = try info(target.parent, target.name)
        return (value, (value?.st_mode ?? 0) & S_IFMT == S_IFREG
            ? try readFile(parent: target.parent, name: target.name) : nil)
    }
    private func absent(_ path: String) throws -> Bool {
        let target = try leaf(path); defer { close(target.parent) }
        return try info(target.parent, target.name) == nil
    }
    private func matches(_ path: String, token: String?, digest: String?, mode: UInt32? = nil) throws -> Bool {
        let (value, bytes) = try current(path)
        if token == nil { return value == nil && digest == nil }
        return value.map(Self.fileToken) == token && bytes.map(Self.digest) == digest
            && (mode == nil || value.map { UInt32($0.st_mode & 0o777) } == mode)
    }
    private func matchesIdentity(_ path: String, _ identity: String) -> Bool {
        (try? fileIdentityLocked(path)) == identity
    }
    private func fileIdentityLocked(_ path: String) throws -> String {
        let target = try leaf(path); defer { close(target.parent) }
        guard let value = try info(target.parent, target.name) else { throw AgentDirectoryError.unavailable }
        return Self.identity(value)
    }
    /// Determine interrupted transitions from real disk evidence. Unknown never
    /// becomes empty and is never automatically replayed or reversed.
    private func reconcile(_ step: inout DirectoryJournalStep) {
        if step.state == "reverted" || step.state == "notApplied" { return }
        // Committed chained moves must be reversed in order. A later step may
        // legitimately have moved the earlier destination again.
        if step.state == "applied" && step.kind != "write" { return }
        do {
            if step.kind == "write" {
                if step.state == "reverting" {
                    if try matches(step.path, token: step.reverseToken,
                                   digest: step.original.map(Self.digest), mode: step.originalMode) {
                        step.state = "reverted"; return
                    }
                    // If the inverse was not committed, it may be explicitly retried.
                    if try matches(step.path, token: step.afterToken, digest: step.writtenDigest, mode: step.writtenMode) {
                        step.state = "applied"; return
                    }
                } else {
                    if let token = step.afterToken,
                       try matches(step.path, token: token, digest: step.writtenDigest, mode: step.writtenMode) {
                        step.state = "applied"; return
                    }
                    if try matches(step.path, token: step.originalToken, digest: step.original.map(Self.digest), mode: step.originalMode) {
                        step.state = "notApplied"; return
                    }
                }
            } else if step.kind == "move", let destination = step.destination, let identity = step.identity {
                let atSource = matchesIdentity(step.path, identity)
                let atDestination = matchesIdentity(destination, identity)
                let sourceAbsent = try absent(step.path)
                let destinationAbsent = try absent(destination)
                if step.state == "reverting", atSource, destinationAbsent { step.state = "reverted"; return }
                if atDestination, sourceAbsent { step.state = "applied"; return }
                if atSource, destinationAbsent, step.state != "reverting" { step.state = "notApplied"; return }
            } else if step.kind == "directory" {
                let (value, _) = try current(step.path)
                if let value, step.afterToken == Self.fileToken(value) { step.state = "applied"; return }
                if value == nil {
                    step.state = step.state == "reverting" ? "reverted" : "notApplied"; return
                }
            }
        } catch { /* unreadable/changed is execution unknown, never permission to overwrite */ }
        step.state = "unknown"
    }
    private func reconcile(_ file: DirectoryJournalFile) throws {
        for r in file.document.records.indices {
            for s in file.document.records[r].steps.indices { reconcile(&file.document.records[r].steps[s]) }
            for s in file.document.records[r].steps.indices {
                let step = file.document.records[r].steps[s]
                if step.state == "notApplied", step.afterToken == nil, artifactExists(step) {
                    file.document.records[r].steps[s].state = "unknown"
                }
            }
        }
        // An inverse restores prior bytes into a new inode. Preserve undo lineage
        // only when the previous committed identity and exact bytes are proven.
        for r in file.document.records.indices {
            for step in file.document.records[r].steps where step.state == "reverted" {
                try restoreLineage(file, excluding: r, step: step)
            }
        }
        try file.save()
    }
    private func restoreLineage(_ file: DirectoryJournalFile, excluding: Int, step: DirectoryJournalStep) throws {
        guard step.kind == "write", let original = step.original, let restored = step.reverseToken,
              try matches(step.path, token: restored, digest: Self.digest(original), mode: step.originalMode) else { return }
        for r in file.document.records.indices where r < excluding {
            for s in file.document.records[r].steps.indices {
                let earlier = file.document.records[r].steps[s]
                if earlier.kind == "write", earlier.path == step.path, earlier.afterToken == step.originalToken,
                   earlier.writtenDigest == Self.digest(original), !["reverted", "notApplied"].contains(earlier.state) {
                    file.document.records[r].steps[s].afterToken = restored
                    file.document.records[r].steps[s].state = "applied"
                }
            }
        }
    }
    private func report(_ step: DirectoryJournalStep, index: Int) -> JSONValue {
        var result: [String: JSONValue] = ["index": .number(Double(index)), "path": .string(step.path),
            "action": .string(step.kind), "state": .string(step.state)]
        if let destination = step.destination { result["destination"] = .string(destination) }
        // Staged artifacts are preserved after an interrupted operation.
        for (key, name) in [("retained_path", step.temporary), ("reverse_retained_path", step.reverseTemporary)] {
            if let name, let target = try? leaf(step.path) {
                defer { close(target.parent) }
                var value = stat()
                if fstatat(target.parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 {
                    result[key] = .string((target.parts + [name]).joined(separator: "/"))
                }
            }
        }
        if let paths = step.cleanupPaths, let target = try? leaf(step.path) {
            defer { close(target.parent) }
            result["cleanup_retained_paths"] = .array(paths.compactMap { name in
                var value = stat()
                guard fstatat(target.parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
                return .string((target.parts + [name]).joined(separator: "/"))
            })
        }
        return .object(result)
    }
    /// A read/reconcile tool makes IDs recoverable even if the original result
    /// never reached the conversation. Only App-private metadata is changed.
    public func directoryHistory() throws -> JSONValue {
        try withDirectoryLock {
            guard journalContext != nil else {
                return ["persistent": false, "records": .array(undoRecords.keys.map {
                    ["undo_id": .string($0.uuidString.lowercased())]
                })]
            }
            let file = try journalFile()
            try reconcile(file)
            return ["persistent": true, "records": .array(file.document.records.map { record in
                ["undo_id": .string(record.id.uuidString.lowercased()),
                 "items": .array(record.steps.enumerated().map { report($0.element, index: $0.offset) }),
                 "execution_unknown": .bool(record.steps.contains { $0.state == "unknown" })]
            })]
        }
    }
    private func checkpoint(_ stage: String) { journalCheckpoint?(stage) }
    private func artifactExists(_ step: DirectoryJournalStep) -> Bool {
        guard let target = try? leaf(step.path) else {
            // An unreadable/moved parent is not proof of artifact absence.
            return step.temporary != nil || step.reverseTemporary != nil
        }
        defer { close(target.parent) }
        return ([step.temporary, step.reverseTemporary].compactMap { $0 } + (step.cleanupPaths ?? [])).contains { name in
            var value = stat()
            return fstatat(target.parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT
        }
    }
    /// Cleanup is only part of an explicitly approved inverse, never startup.
    /// First quarantine, then recheck the retained entry before unlinking it.
    private func cleanup(_ file: DirectoryJournalFile, record r: Int, step s: Int) throws {
        let step = file.document.records[r].steps[s]
        let names = Set([step.temporary, step.reverseTemporary].compactMap({ $0 }) + (step.cleanupPaths ?? []))
        for name in names {
            let target = try leaf(step.path); defer { close(target.parent) }
            guard let value = try info(target.parent, name) else { continue }
            let quarantine = ".clipslots-cleanup-\(UUID().uuidString)"
            var retained = file.document.records[r].steps[s].cleanupPaths ?? []
            guard retained.count < 64 else { throw AgentDirectoryError.tooLarge }
            retained.append(quarantine)
            file.document.records[r].steps[s].cleanupPaths = retained
            try file.save()
            try verifyParent(target.parts, descriptor: target.parent)
            guard renameatx_np(target.parent, name, target.parent, quarantine, UInt32(RENAME_EXCL)) == 0 else {
                throw AgentDirectoryError.changed
            }
            _ = fsync(target.parent)
            let path = (target.parts + [quarantine]).joined(separator: "/")
            do {
                let (moved, bytes) = try current(path)
                guard let moved, Self.fileToken(moved) == Self.fileToken(value) else { throw AgentDirectoryError.changed }
                if moved.st_mode & S_IFMT == S_IFDIR {
                    guard Self.fileToken(moved) == step.afterToken,
                          unlinkat(target.parent, quarantine, AT_REMOVEDIR) == 0 else { throw AgentDirectoryError.changed }
                } else {
                    let known = [(step.originalToken, step.original.map(Self.digest)),
                                 (step.afterToken, step.writtenDigest),
                                 (step.reverseToken, step.original.map(Self.digest))]
                        + (step.previousReverseTokens ?? []).map { (Optional($0), step.original.map(Self.digest)) }
                    guard known.contains(where: { $0.0 != nil && $0.0 == Self.fileToken(moved) && $0.1 == bytes.map(Self.digest) }),
                          unlinkat(target.parent, quarantine, 0) == 0 else { throw AgentDirectoryError.changed }
                }
            } catch {
                // Put back only into an absent old name; either retained path is
                // already journaled and stays visible after another crash.
                _ = renameatx_np(target.parent, quarantine, target.parent, name, UInt32(RENAME_EXCL))
                _ = fsync(target.parent)
                throw error
            }
            _ = fsync(target.parent)
        }
    }
    private func transition(_ file: DirectoryJournalFile, record: Int, step: Int,
                            stage: String, temporary: String, token: String?, reverse: Bool = false) throws {
        if reverse {
            if let previous = file.document.records[record].steps[step].reverseTemporary, previous != temporary {
                var paths = file.document.records[record].steps[step].cleanupPaths ?? []
                var tokens = file.document.records[record].steps[step].previousReverseTokens ?? []
                guard paths.count < 64, tokens.count < 64 else { throw AgentDirectoryError.tooLarge }
                paths.append(previous)
                if let token = file.document.records[record].steps[step].reverseToken { tokens.append(token) }
                file.document.records[record].steps[step].cleanupPaths = paths
                file.document.records[record].steps[step].previousReverseTokens = tokens
                file.document.records[record].steps[step].reverseToken = nil
            }
            file.document.records[record].steps[step].reverseTemporary = temporary
            if let token { file.document.records[record].steps[step].reverseToken = token }
        } else {
            file.document.records[record].steps[step].temporary = temporary
            if let token { file.document.records[record].steps[step].afterToken = token }
            file.document.records[record].steps[step].state = stage == "intent" ? "intent"
                : stage == "ready" ? "ready" : "applied"
        }
        // Fixture hook before saving 'applied' exercises the filesystem/log gap.
        if stage == "applied" { checkpoint(reverse ? "undo-filesystem" : "write-filesystem") }
        try file.save()
        checkpoint(reverse ? "undo-" + stage : "write-" + stage)
    }
    func durableBatchWrite(_ writes: [AgentDirectoryWrite], accepted: [Bool],
                           cancelled: @Sendable () -> Bool) throws -> JSONValue {
        try withDirectoryLock {
            guard !writes.isEmpty, writes.count <= Self.maxBatchItems, accepted.count == writes.count,
                  writes.allSatisfy({ $0.data.count <= Self.maxFileBytes }),
                  writes.reduce(0, { $0 + $1.data.count }) <= Self.maxBatchBytes else { throw AgentDirectoryError.tooLarge }
            let file = try journalFile(); try file.reserve()
            let r = file.document.records.count
            file.document.records.append(.init())
            var results: [JSONValue] = [], paths: Set<String> = []
            for (index, write) in writes.enumerated() {
                var result: [String: JSONValue] = ["index": .number(Double(index)), "path": .string(write.path)]
                do {
                    guard accepted[index] else { result["status"] = "declined"; results.append(.object(result)); continue }
                    guard !cancelled() else { throw AgentDirectoryError.cancelled }
                    let path = try components(write.path).joined(separator: "/")
                    guard !path.isEmpty, paths.insert(path).inserted else { throw AgentDirectoryError.changed }
                    let (value, original) = try current(path)
                    guard original.map(Self.digest) == write.expectedDigest, value == nil || original != nil else {
                        throw AgentDirectoryError.changed
                    }
                    guard DirectoryJournalFile.retainedBytes(file.document) + (original?.count ?? 0) <= Self.maxUndoBytes else {
                        throw AgentDirectoryError.tooLarge
                    }
                    let s = file.document.records[r].steps.count
                    file.document.records[r].steps.append(.init(kind: "write", path: path,
                        original: original, originalToken: value.map(Self.fileToken),
                        originalMode: value.map { UInt32($0.st_mode & 0o777) },
                        writtenMode: value.map { UInt32($0.st_mode & 0o777) } ?? 0o600,
                        writtenDigest: Self.digest(write.data), writtenBytes: write.data.count))
                    try file.save()
                    checkpoint("write-recorded")
                    try writeLocked(path, data: write.data, expectedDigest: write.expectedDigest,
                        cancelled: cancelled, expectedToken: value.map(Self.fileToken),
                        transition: { stage, temp, token in
                            try self.transition(file, record: r, step: s, stage: stage, temporary: temp, token: token)
                        })
                    result["status"] = "written"; result["sha256"] = .string(Self.digest(write.data))
                    result["written_bytes"] = .number(Double(write.data.count))
                } catch {
                    // A journal failure can follow a filesystem commit. Do not
                    // advertise absence or continue more side effects in that case.
                    if case AgentDirectoryError.corruptJournal = error { throw error }
                    result["status"] = "failed"; result["error_code"] = Self.errorCode(error)
                    result["detail"] = .string(error.localizedDescription)
                }
                results.append(.object(result))
            }
            for s in file.document.records[r].steps.indices { reconcile(&file.document.records[r].steps[s]) }
            // Keep unknown and staged artifacts visible; prune ordinary failures.
            file.document.records[r].steps.removeAll { $0.state == "notApplied" && $0.temporary == nil }
            let id: JSONValue = file.document.records[r].steps.isEmpty ? .null
                : .string(file.document.records[r].id.uuidString.lowercased())
            if id == .null { file.document.records.remove(at: r) }
            try file.save()
            return ["items": .array(results), "undo_id": id, "persistent": true,
                    "complete": .bool(results.allSatisfy { $0["status"] == "written" })]
        }
    }
    func durableOrganize(_ moves: [AgentDirectoryMove], createDirectories: [String],
                         cancelled: @Sendable () -> Bool) throws -> JSONValue {
        try withDirectoryLock {
            guard !moves.isEmpty, moves.count <= Self.maxBatchItems,
                  createDirectories.count <= Self.maxBatchItems else { throw AgentDirectoryError.tooLarge }
            var destinations: Set<String> = []
            for move in moves {
                let source = try components(move.source).joined(separator: "/")
                let destination = try components(move.destination).joined(separator: "/")
                guard !source.isEmpty, !destination.isEmpty, source != destination,
                      !destination.hasPrefix(source + "/"), destinations.insert(destination).inserted else {
                    throw AgentDirectoryError.invalidPath
                }
            }
            let file = try journalFile(); try file.reserve()
            let r = file.document.records.count
            file.document.records.append(.init())
            try file.save()
            var results: [JSONValue] = [], failure: String?
            do {
                for supplied in createDirectories {
                    guard !cancelled() else { throw AgentDirectoryError.cancelled }
                    let path = try components(supplied).joined(separator: "/")
                    let target = try leaf(path); defer { close(target.parent) }
                    guard try info(target.parent, target.name) == nil else { throw AgentDirectoryError.changed }
                    let s = file.document.records[r].steps.count
                    let temp = ".clipslots-mkdir-\(UUID().uuidString)"
                    file.document.records[r].steps.append(.init(kind: "directory", path: path, temporary: temp))
                    try file.save(); checkpoint("mkdir-intent")
                    try verifyParent(target.parts, descriptor: target.parent)
                    guard mkdirat(target.parent, temp, 0o700) == 0,
                          let value = try info(target.parent, temp) else { throw AgentDirectoryError.permissionDenied }
                    checkpoint("mkdir-created")
                    file.document.records[r].steps[s].afterToken = Self.fileToken(value)
                    file.document.records[r].steps[s].identity = Self.identity(value)
                    file.document.records[r].steps[s].state = "ready"
                    _ = fsync(target.parent)
                    try file.save(); checkpoint("mkdir-ready")
                    guard !cancelled() else { throw AgentDirectoryError.cancelled }
                    try verifyParent(target.parts, descriptor: target.parent)
                    guard renameatx_np(target.parent, temp, target.parent, target.name, UInt32(RENAME_EXCL)) == 0 else {
                        throw AgentDirectoryError.changed
                    }
                    _ = fsync(target.parent); checkpoint("mkdir-filesystem")
                    file.document.records[r].steps[s].state = "applied"
                    try file.save(); checkpoint("mkdir-applied")
                    results.append(["action": "mkdir", "path": .string(path), "status": "created"])
                }
                for (index, move) in moves.enumerated() {
                    guard !cancelled() else { throw AgentDirectoryError.cancelled }
                    let s = file.document.records[r].steps.count
                    file.document.records[r].steps.append(.init(kind: "move", path: move.source,
                        destination: move.destination, identity: move.expectedIdentity))
                    try file.save(); checkpoint("move-intent")
                    try moveLocked(source: move.source, destination: move.destination, identity: move.expectedIdentity)
                    checkpoint("move-filesystem")
                    file.document.records[r].steps[s].state = "applied"
                    try file.save(); checkpoint("move-applied")
                    results.append(["index": .number(Double(index)), "source": .string(move.source),
                        "destination": .string(move.destination), "status": "moved"])
                }
            } catch {
                if case AgentDirectoryError.corruptJournal = error { throw error }
                failure = Self.errorCode(error).stringValue
            }
            if let failure {
                for s in file.document.records[r].steps.indices { reconcile(&file.document.records[r].steps[s]) }
                let rollback = try reverse(file, record: r)
                let id = try finish(file, record: r)
                return ["complete": false, "error_code": .string(failure), "steps": .array(results),
                    "rollback": .array(rollback), "rollback_complete": .bool(id == .null), "undo_id": id, "persistent": true]
            }
            try file.save()
            return ["complete": true, "steps": .array(results),
                "undo_id": .string(file.document.records[r].id.uuidString.lowercased()), "persistent": true]
        }
    }
    private func reverse(_ file: DirectoryJournalFile, record r: Int,
                         cancelled: @Sendable () -> Bool = { false }) throws -> [JSONValue] {
        var results: [JSONValue] = []
        for s in file.document.records[r].steps.indices.reversed() {
            var step = file.document.records[r].steps[s]
            if cancelled() {
                results.append(["index": .number(Double(s)), "path": .string(step.path),
                                "status": "conflict", "error_code": "CANCELLED"])
                continue
            }
            if ["notApplied", "reverted"].contains(step.state) {
                do {
                    try cleanup(file, record: r, step: s)
                    results.append(["index": .number(Double(s)), "path": .string(step.path), "status": "reverted"])
                } catch {
                    results.append(["index": .number(Double(s)), "path": .string(step.path), "status": "conflict",
                                    "error_code": Self.errorCode(error)])
                }
                continue
            }
            do {
                // Unknown is reviewable, but it never authorizes a blind retry.
                guard step.state == "applied" else { throw AgentDirectoryError.changed }
                step.state = "reverting"; file.document.records[r].steps[s] = step
                try file.save(); checkpoint("undo-intent")
                if step.kind == "write" {
                    guard try matches(step.path, token: step.afterToken, digest: step.writtenDigest, mode: step.writtenMode) else {
                        throw AgentDirectoryError.changed
                    }
                    if let original = step.original {
                        try writeLocked(step.path, data: original, expectedDigest: step.writtenDigest,
                            cancelled: cancelled, expectedToken: step.afterToken, mode: step.originalMode.map(mode_t.init),
                            transition: { stage, temp, token in
                                try self.transition(file, record: r, step: s, stage: stage,
                                                    temporary: temp, token: token, reverse: true)
                            })
                    } else {
                        let target = try leaf(step.path); defer { close(target.parent) }
                        let temp = ".clipslots-undo-\(UUID().uuidString)"
                        file.document.records[r].steps[s].reverseTemporary = temp
                        try file.save()
                        try verifyParent(target.parts, descriptor: target.parent)
                        guard renameatx_np(target.parent, target.name, target.parent, temp, UInt32(RENAME_EXCL)) == 0 else {
                            throw AgentDirectoryError.changed
                        }
                        let (value, bytes) = try current((target.parts + [temp]).joined(separator: "/"))
                        guard value.map(Self.fileToken) == step.afterToken, bytes.map(Self.digest) == step.writtenDigest else {
                            if renameatx_np(target.parent, temp, target.parent, target.name, UInt32(RENAME_EXCL)) != 0 {
                                throw AgentDirectoryError.conflictBackup((target.parts + [temp]).joined(separator: "/"))
                            }
                            throw AgentDirectoryError.changed
                        }
                        // Saving before unlink retains a recovery path in the gap.
                        _ = fsync(target.parent); checkpoint("undo-filesystem")
                        guard unlinkat(target.parent, temp, 0) == 0 else {
                            throw AgentDirectoryError.conflictBackup((target.parts + [temp]).joined(separator: "/"))
                        }
                        _ = fsync(target.parent)
                    }
                } else if step.kind == "move", let destination = step.destination, let identity = step.identity {
                    try moveLocked(source: destination, destination: step.path, identity: identity)
                    checkpoint("undo-filesystem")
                } else if step.kind == "directory", let identity = step.identity {
                    let target = try leaf(step.path); defer { close(target.parent) }
                    guard let value = try info(target.parent, target.name),
                          Self.identity(value) == identity else { throw AgentDirectoryError.changed }
                    let temp = ".clipslots-undo-dir-\(UUID().uuidString)"
                    file.document.records[r].steps[s].reverseTemporary = temp
                    try file.save()
                    try verifyParent(target.parts, descriptor: target.parent)
                    guard renameatx_np(target.parent, target.name, target.parent, temp, UInt32(RENAME_EXCL)) == 0 else {
                        throw AgentDirectoryError.changed
                    }
                    do {
                        guard let retained = try info(target.parent, temp), Self.identity(retained) == identity,
                              unlinkat(target.parent, temp, AT_REMOVEDIR) == 0 else { throw AgentDirectoryError.changed }
                    } catch {
                        if renameatx_np(target.parent, temp, target.parent, target.name, UInt32(RENAME_EXCL)) != 0 {
                            throw AgentDirectoryError.conflictBackup((target.parts + [temp]).joined(separator: "/"))
                        }
                        throw error
                    }
                    _ = fsync(target.parent); checkpoint("undo-filesystem")
                } else { throw AgentDirectoryError.corruptJournal }
                file.document.records[r].steps[s].state = "reverted"
                try restoreLineage(file, excluding: r, step: file.document.records[r].steps[s])
                try cleanup(file, record: r, step: s)
                try file.save(); checkpoint("undo-applied")
                results.append(["index": .number(Double(s)), "path": .string(step.path), "status": "reverted"])
            } catch {
                if case AgentDirectoryError.corruptJournal = error { throw error }
                if file.document.records[r].steps[s].state != "reverted" {
                    file.document.records[r].steps[s].state = "unknown"
                }
                try file.save()
                results.append(["index": .number(Double(s)), "path": .string(step.path), "status": "conflict",
                    "error_code": Self.errorCode(error), "detail": .string(error.localizedDescription)])
            }
        }
        return results
    }
    private func finish(_ file: DirectoryJournalFile, record r: Int) throws -> JSONValue {
        // Retained staged files stay discoverable; no automatic removal of an
        // artifact which might have been edited since the crash.
        let remaining = file.document.records[r].steps.filter {
            !["reverted", "notApplied"].contains($0.state) || artifactExists($0)
        }
        file.document.records[r].steps = remaining
        let id: JSONValue
        if remaining.isEmpty { file.document.records.remove(at: r); id = .null }
        else { id = .string(file.document.records[r].id.uuidString.lowercased()) }
        try file.save()
        return id
    }
    func durableUndo(_ id: UUID, cancelled: @Sendable () -> Bool) throws -> JSONValue {
        try withDirectoryLock {
            guard !cancelled() else { throw AgentDirectoryError.cancelled }
            let file = try journalFile()
            guard let r = file.document.records.firstIndex(where: { $0.id == id }) else { throw AgentDirectoryError.invalidProposal }
            try reconcile(file)
            // Consume and publish the successor identity BEFORE the first inverse.
            file.document.records[r].id = UUID()
            try file.save(); checkpoint("undo-claimed")
            let results = try reverse(file, record: r, cancelled: cancelled)
            let successor = try finish(file, record: r)
            return ["complete": .bool(successor == .null), "items": .array(results), "undo_id": successor, "persistent": true]
        }
    }
}
