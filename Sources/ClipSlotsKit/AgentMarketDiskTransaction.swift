import Foundation
import Darwin

/// Serializes cooperating processes and recovers an interrupted multi-file
/// change before any catalog read. The journal contains both byte generations;
/// rollback never replaces a value different from both recorded generations.
final class AgentMarketDiskTransaction {
    private struct Entry: Codable {
        var path: String
        var before: Data?
        var after: Data?
        var mode: UInt16
    }
    private struct Journal: Codable {
        var version = 1
        var committed = false
        var entries: [Entry]
    }
    private enum Failure: LocalizedError {
        case busy, recovery, invalidPath
        var errorDescription: String? {
            switch self {
            case .busy: return "目录正在提交，请稍后重试"
            case .recovery: return "目录恢复未完成，已保留现有文件，请检查磁盘权限或文件冲突后重试"
            case .invalidPath: return "目录文件路径无效"
            }
        }
    }
    private let root: URL
    private let directory: Int32
    private let lock: Int32
    private let journalPath = ".catalog-transaction.json"

    static func access<T>(root: URL, _ body: (AgentMarketDiskTransaction) throws -> T) throws -> T {
        let disk = try AgentMarketDiskTransaction(root: root)
        try disk.recover()
        return try body(disk)
    }
    private init(root: URL) throws {
        // Foundation's standardizedFileURL changes /private/tmp to /tmp only
        // for existing descendants. Keep the caller's spelling; openat pins
        // the root and validates every relative component independently.
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw Self.posix() }
        lock = openat(directory, ".catalog.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { let error = Self.posix(); close(directory); throw error }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(lock); close(directory); throw Failure.invalidPath
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(lock); close(directory)
            if code == EWOULDBLOCK { throw Failure.busy }
            throw Self.posix(code)
        }
    }
    deinit { flock(lock, LOCK_UN); close(lock); close(directory) }
    private static func posix(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
    private func relative(_ url: URL) throws -> String {
        let prefix = root.path + "/"
        guard url.path.hasPrefix(prefix) else { throw Failure.invalidPath }
        let path = String(url.path.dropFirst(prefix.count))
        guard valid(path) else { throw Failure.invalidPath }
        return path
    }
    private func valid(_ path: String) -> Bool {
        if path == "active.json" { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        func hash(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard parts.count >= 3, parts[0] == "scopes", hash(parts[1]) else { return false }
        return (parts.count == 3 && ["snapshot.json", "installed.json"].contains(parts[2]))
            || (parts.count == 5 && parts[2] == "skills" && hash(parts[3]) && parts[4] == "SKILL.md")
    }
    /// Pin each directory and refuse symlink descendants, including on recovery.
    private func parent(_ path: String, create: Bool) throws -> Int32? {
        var fd = dup(directory)
        guard fd >= 0 else { throw Self.posix() }
        for component in path.split(separator: "/").dropLast() {
            var next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, create {
                guard mkdirat(fd, String(component), 0o700) == 0 || errno == EEXIST else {
                    let error = Self.posix(); close(fd); throw error
                }
                guard fsync(fd) == 0 else { let error = Self.posix(); close(fd); throw error }
                next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if next < 0 {
                let code = errno; close(fd)
                if code == ENOENT, !create { return nil }
                throw Self.posix(code)
            }
            close(fd); fd = next
        }
        return fd
    }
    private func read(_ path: String) throws -> (Data?, UInt16) {
        guard let parent = try parent(path, create: false) else { return (nil, 0o600) }
        defer { close(parent) }
        let fd = openat(parent, (path as NSString).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return (nil, 0o600) }
            throw Self.posix()
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Self.posix() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidPath }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw Self.posix() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return (data, UInt16(info.st_mode & 0o777))
    }
    func read(_ url: URL) throws -> Data? { try read(relative(url)).0 }

    private func replace(_ path: String, data: Data?, mode: UInt16) throws {
        guard let parent = try parent(path, create: data != nil) else { return }
        defer { close(parent) }
        let name = (path as NSString).lastPathComponent
        guard let data else {
            guard unlinkat(parent, name, 0) == 0 || errno == ENOENT else { throw Self.posix() }
            guard fsync(parent) == 0 else { throw Self.posix() }
            return
        }
        let temporary = ".catalog-write-" + UUID().uuidString
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(mode))
        guard fd >= 0 else { throw Self.posix() }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw Self.posix() }
                guard count > 0 else { throw Self.posix(EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(parent, temporary, parent, name) == 0,
              fsync(parent) == 0 else { throw Self.posix() }
    }
    private func save(_ journal: Journal) throws {
        try replace(journalPath, data: JSONEncoder().encode(journal), mode: 0o600)
    }
    private func recover() throws {
        guard let bytes = try read(journalPath).0 else { return }
        guard let journal = try? JSONDecoder().decode(Journal.self, from: bytes),
              journal.version == 1, !journal.entries.isEmpty,
              Set(journal.entries.map(\.path)).count == journal.entries.count,
              journal.entries.allSatisfy({ valid($0.path) && $0.mode <= 0o777 }) else { throw Failure.recovery }
        if !journal.committed {
            var unresolved = false
            for entry in journal.entries.reversed() {
                do {
                    let current = try read(entry.path).0
                    if current == entry.before { continue }
                    guard current == entry.after else { unresolved = true; continue }
                    try replace(entry.path, data: entry.before, mode: entry.mode)
                } catch { unresolved = true }
            }
            guard !unresolved else { throw Failure.recovery }
        }
        // A committed journal must never undo a later user edit.
        try replace(journalPath, data: nil, mode: 0o600)
    }
    func apply(_ changes: [(URL, Data?)]) throws {
        // Alias items can resolve to the same skill path; the last value wins,
        // matching the previous ordered materialization behavior.
        var entries: [Entry] = []
        for (url, data) in changes {
            let path = try relative(url)
            if let index = entries.firstIndex(where: { $0.path == path }) { entries[index].after = data }
            else {
                let (before, mode) = try read(path)
                entries.append(Entry(path: path, before: before, after: data, mode: mode))
            }
        }
        entries.removeAll { $0.before == $0.after }
        guard !entries.isEmpty else { return }
        var journal = Journal(entries: entries)
        try save(journal)
        do {
            for entry in entries {
                guard try read(entry.path).0 == entry.before else { throw Failure.recovery }
                try replace(entry.path, data: entry.after, mode: entry.mode)
            }
            journal.committed = true
            try save(journal)
        } catch {
            // Keep the original journal when rollback is obstructed. Every
            // subsequent reader/writer retries recovery and fails closed.
            try? recover()
            throw error
        }
        // Commit already has a durable marker. Cleanup can be retried on open.
        try? recover()
    }
}
