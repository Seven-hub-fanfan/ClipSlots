import Foundation
import Darwin
import CryptoKit

public enum AgentDirectoryError: LocalizedError {
    case invalidPath, unavailable, permissionDenied, outsideRoot, unsupportedFile, tooLarge
    case changed, corruptCatalog, corruptJournal, revoked, cancelled, invalidProposal
    case conflictBackup(String)
    public var errorDescription: String? {
        switch self {
        case .invalidPath: return "请选择有效的本地文件夹。"
        case .unavailable: return "工作目录不可用，请重新定位或授权。"
        case .permissionDenied: return "没有访问此目录的权限，请在目录选择器中重新授权。"
        case .outsideRoot: return "路径必须位于本轮工作目录内，且不能经过符号链接。"
        case .unsupportedFile: return "此工具仅支持普通 UTF-8 文本文件。"
        case .tooLarge: return "文件超过 256 KB，请缩小文件后重试。"
        case .changed: return "文件在确认期间已变化，未写入；请重新读取后操作。"
        case .corruptCatalog: return "工作目录列表无法读取，原文件已保留，请检查存储权限或备份。"
        case .corruptJournal: return "目录撤销日志不可用，原记录已保留；本次未继续修改文件。"
        case .revoked: return "本轮目录授权已失效，请重新选择或授权；没有使用替代目录。"
        case .cancelled: return "目录操作已停止。"
        case .invalidProposal: return "提案已消费、过期或不属于当前目录授权，请重新提出操作。"
        case .conflictBackup(let path): return "文件发生并发冲突，原文件已保留在 \(path)，请核对后处理。"
        }
    }
}

public struct AgentWorkingDirectory: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var path: String
    public var bookmark: Data
    /// Changes on explicit authorization replacement, not on OS bookmark refresh.
    /// Optional for catalogs saved before persistent directory undo.
    public var authorizationID: UUID?
    public let addedAt: Date

    public static func authorize(_ url: URL, id: UUID = UUID()) throws -> Self {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw AgentDirectoryError.invalidPath
        }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        try AgentDirectoryAccess.validate(canonical)
        let bookmark = try canonical.bookmarkData(options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil)
        return Self(id: id, name: canonical.lastPathComponent.isEmpty ? canonical.path : canonical.lastPathComponent,
                    path: canonical.path, bookmark: bookmark, authorizationID: UUID(), addedAt: Date())
    }

    public func resolve(journal: AgentDirectoryJournalContext? = nil) throws -> AgentDirectoryAccess {
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch { throw AgentDirectoryError.unavailable }
        // A stale bookmark is usable if the OS still resolves it; caller can renew it.
        return try AgentDirectoryAccess(url: url, bookmarkNeedsRefresh: stale, journal: journal)
    }
}

/// One catalog writer is owned by the App. Saving a damaged catalog never overwrites it.
public final class AgentDirectoryCatalog {
    private struct Document: Codable {
        var version = 1
        var directories: [AgentWorkingDirectory]
    }
    public let url: URL
    public init(root: URL) { url = root.appendingPathComponent("agent-workdirs.json") }
    public func load() throws -> [AgentWorkingDirectory] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == 1,
              Set(document.directories.map(\.id)).count == document.directories.count else {
            throw AgentDirectoryError.corruptCatalog
        }
        return document.directories
    }
    public func save(_ directories: [AgentWorkingDirectory]) throws {
        _ = try load()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Document(directories: directories))
        // macOS must be able to restore the catalog while the desktop is locked.
        // File protection made a newly saved catalog unreadable in that state;
        // owner-only POSIX access matches the app's other local state files.
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Lifetime of the OS grant and root descriptor matches one Agent invocation.
/// File operations traverse descriptors, refusing symlinks at every component.
public final class AgentDirectoryAccess: @unchecked Sendable {
    public let url: URL
    public let bookmarkNeedsRefresh: Bool
    public var isWritable: Bool {
        (try? checkGrant()) != nil && faccessat(descriptor, ".", W_OK, 0) == 0
    }
    public var isActive: Bool { (try? checkGrant()) != nil }
    public let grantID = UUID()
    private let scopedURL: URL
    private let scoped: Bool
    private let descriptor: Int32
    private let lock = NSLock()
    private let lifetimeLock = NSLock()
    private var revoked = false
    private var scopeReleased = false
    var undoRecords: [UUID: AgentDirectoryUndoRecord] = [:]
    let journalContext: AgentDirectoryJournalContext?
    // Used only by native crash fixtures; production never installs a checkpoint.
    @_spi(DirectoryJournalTesting) public var journalCheckpoint: ((String) -> Void)?
    public static let maxFileBytes = 262_144

    public init(url: URL, bookmarkNeedsRefresh: Bool = false,
                journal: AgentDirectoryJournalContext? = nil) throws {
        guard url.isFileURL, !url.path.contains("\0") else { throw AgentDirectoryError.invalidPath }
        self.scopedURL = url
        scoped = url.startAccessingSecurityScopedResource()
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.bookmarkNeedsRefresh = bookmarkNeedsRefresh
        self.journalContext = journal
        do { try Self.validate(self.url) }
        catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        descriptor = open(self.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw AgentDirectoryError.permissionDenied
        }
    }
    deinit {
        close(descriptor)
        if scoped && !scopeReleased { scopedURL.stopAccessingSecurityScopedResource() }
    }
    /// Revocation serializes with descriptor operations; removed/replaced grants
    /// cannot authorize another operation even while old tools retain this object.
    public func revoke() {
        lifetimeLock.withLock {
            revoked = true
            if scoped && !scopeReleased {
                scopedURL.stopAccessingSecurityScopedResource()
                scopeReleased = true
            }
        }
    }
    func checkGrant() throws {
        guard lifetimeLock.withLock({ !revoked }) else { throw AgentDirectoryError.revoked }
        var held = stat(), current = stat()
        guard fstat(descriptor, &held) == 0, lstat(url.path, &current) == 0,
              current.st_mode & S_IFMT == S_IFDIR,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino else {
            throw AgentDirectoryError.revoked
        }
    }
    func withDirectoryLock<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock { try checkGrant(); return try body() }
    }
    static func validate(_ url: URL) throws {
        guard url.isFileURL, let value = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              value.isDirectory == true else { throw AgentDirectoryError.unavailable }
        guard access(url.path, R_OK | X_OK) == 0 else { throw AgentDirectoryError.permissionDenied }
    }
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func components(_ path: String) throws -> [String] {
        guard !path.contains("\0"), !path.hasPrefix("/"), !path.hasPrefix("~") else {
            throw AgentDirectoryError.outsideRoot
        }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !pieces.contains(".."), pieces.allSatisfy({ $0.utf8.count <= 255 }) else {
            throw AgentDirectoryError.outsideRoot
        }
        return pieces.filter { $0 != "." }
    }
    func directory(_ components: [String]) throws -> Int32 {
        try checkGrant()
        // A new file description prevents one list call from advancing the next call's cursor.
        var current = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw AgentDirectoryError.unavailable }
        for component in components {
            let child = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard child >= 0 else { throw AgentDirectoryError.outsideRoot }
            current = child
        }
        return current
    }
    func readFile(parent: Int32, name: String, cancelled: @Sendable () -> Bool = { false }) throws -> Data? {
        try checkGrant()
        guard !cancelled() else { throw AgentDirectoryError.cancelled }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw AgentDirectoryError.permissionDenied
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw AgentDirectoryError.unsupportedFile
        }
        guard info.st_size >= 0, info.st_size <= Self.maxFileBytes else { throw AgentDirectoryError.tooLarge }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try checkGrant()
            guard !cancelled() else { throw AgentDirectoryError.cancelled }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw AgentDirectoryError.permissionDenied }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maxFileBytes else { throw AgentDirectoryError.tooLarge }
        }
        var after = stat(), entry = stat()
        guard fstat(fd, &after) == 0,
              fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              Self.sameVersion(info, after), Self.sameVersion(after, entry),
              data.count == after.st_size else { throw AgentDirectoryError.changed }
        return data
    }
    static func sameVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
    public func read(_ path: String, cancelled: @Sendable () -> Bool = { false }) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let parts = try components(path)
        guard let name = parts.last else { throw AgentDirectoryError.unsupportedFile }
        let parent = try directory(Array(parts.dropLast())); defer { close(parent) }
        guard let data = try readFile(parent: parent, name: name, cancelled: cancelled) else { throw AgentDirectoryError.unavailable }
        return data
    }
    public func list(_ path: String = ".", offset: Int = 0, cancelled: @Sendable () -> Bool = { false }) throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        let fd = try directory(components(path))
        guard let stream = fdopendir(fd) else { close(fd); throw AgentDirectoryError.permissionDenied }
        defer { closedir(stream) }
        var entries: [JSONValue] = []
        var visited = 0
        var hasMore = false
        // No recursion; entries are paged to bound memory and model context.
        while let entry = readdir(stream) {
            try checkGrant()
            guard !cancelled() else { throw AgentDirectoryError.cancelled }
            var name = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: name)
            let text = withUnsafePointer(to: &name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if text == "." || text == ".." { continue }
            if visited < max(0, offset) { visited += 1; continue }
            if entries.count == 100 { hasMore = true; break }
            var info = stat()
            guard fstatat(fd, text, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            entries.append(["name": .string(text), "kind": .string(type == S_IFDIR ? "directory" : type == S_IFREG ? "file" : "link_or_special"),
                            "bytes": .number(Double(info.st_size))])
        }
        return ["path": .string(path), "entries": .array(entries),
                "next_offset": hasMore ? .number(Double(max(0, offset) + entries.count)) : .null]
    }
    /// Compare the exact inspected version again after approval. Atomic rename
    /// replaces the directory entry, never follows a target symlink or hardlink.
    public func write(_ path: String, data: Data, expectedDigest: String?) throws {
        if journalContext != nil {
            let result = try batchWrite([.init(path: path, data: data, expectedDigest: expectedDigest)], accepted: [true])
            guard result["complete"] == true else { throw AgentDirectoryError.changed }
            return
        }
        lock.lock(); defer { lock.unlock() }
        try writeLocked(path, data: data, expectedDigest: expectedDigest)
    }
    func writeLocked(_ path: String, data: Data, expectedDigest: String?,
                     cancelled: @Sendable () -> Bool = { false }, expectedToken: String? = nil,
                     mode: mode_t? = nil,
                     transition: ((String, String, String?) throws -> Void)? = nil) throws {
        try checkGrant()
        guard !cancelled() else { throw AgentDirectoryError.cancelled }
        guard data.count <= Self.maxFileBytes else { throw AgentDirectoryError.tooLarge }
        let parts = try components(path)
        guard let name = parts.last else { throw AgentDirectoryError.invalidPath }
        let parent = try directory(Array(parts.dropLast())); defer { close(parent) }
        let original = try readFile(parent: parent, name: name)
        guard original.map(Self.digest) == expectedDigest else { throw AgentDirectoryError.changed }
        var originalInfo = stat()
        let previousMode = original != nil && fstatat(parent, name, &originalInfo, AT_SYMLINK_NOFOLLOW) == 0
            ? originalInfo.st_mode & 0o777 : 0o600
        if let expectedToken {
            guard original != nil, Self.fileToken(originalInfo) == expectedToken else { throw AgentDirectoryError.changed }
        }
        let temporary = ".clipslots-write-\(UUID().uuidString)"
        try transition?("intent", temporary, nil)
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentDirectoryError.permissionDenied }
        var keepTemporary = false
        defer { close(fd); if !keepTemporary { unlinkat(parent, temporary, 0) } }
        guard fchmod(fd, mode ?? previousMode) == 0 else { throw AgentDirectoryError.permissionDenied }
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                try checkGrant()
                guard !cancelled() else { throw AgentDirectoryError.cancelled }
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                if n < 0 { if errno == EINTR { continue }; throw AgentDirectoryError.permissionDenied }
                guard n > 0 else { throw AgentDirectoryError.permissionDenied }
                written += n
            }
        }
        guard fsync(fd) == 0 else { throw AgentDirectoryError.permissionDenied }
        var prepared = stat()
        guard fstat(fd, &prepared) == 0 else { throw AgentDirectoryError.permissionDenied }
        try transition?("ready", temporary, Self.fileToken(prepared))
        // Do not replace a path that appeared/changed while creating the temp file.
        guard try readFile(parent: parent, name: name).map(Self.digest) == expectedDigest else {
            throw AgentDirectoryError.changed
        }
        guard !cancelled() else { throw AgentDirectoryError.cancelled }
        try checkGrant()
        try verifyParent(Array(parts.dropLast()), descriptor: parent)
        if expectedDigest == nil {
            guard linkat(parent, temporary, parent, name, 0) == 0 else { throw AgentDirectoryError.changed }
        } else {
            // Exchange retains the displaced entry until its identity and bytes
            // have been checked. A change in the last check/rename gap is never
            // silently deleted by ordinary atomic replacement.
            guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_SWAP)) == 0 else {
                throw AgentDirectoryError.changed
            }
            var displaced = stat(), target = stat(), ours = stat()
            let versionMatches = fstatat(parent, temporary, &displaced, AT_SYMLINK_NOFOLLOW) == 0
                && displaced.st_dev == originalInfo.st_dev && displaced.st_ino == originalInfo.st_ino
                && displaced.st_mode == originalInfo.st_mode && displaced.st_size == originalInfo.st_size
                && displaced.st_mtimespec.tv_sec == originalInfo.st_mtimespec.tv_sec
                && displaced.st_mtimespec.tv_nsec == originalInfo.st_mtimespec.tv_nsec
            let bytesMatch = (try? readFile(parent: parent, name: temporary).map(Self.digest)) == expectedDigest
            if !versionMatches || !bytesMatch {
                let targetIsOurs = fstatat(parent, name, &target, AT_SYMLINK_NOFOLLOW) == 0 && fstat(fd, &ours) == 0
                    && target.st_dev == ours.st_dev && target.st_ino == ours.st_ino
                    && (try? readFile(parent: parent, name: name).map(Self.digest)) == Self.digest(data)
                if targetIsOurs && renameatx_np(parent, temporary, parent, name, UInt32(RENAME_SWAP)) == 0 {
                    throw AgentDirectoryError.changed
                }
                keepTemporary = true
                throw AgentDirectoryError.conflictBackup((Array(parts.dropLast()) + [temporary]).joined(separator: "/"))
            }
        }
        // The rename/link is the commit point. Never report it as absent merely
        // because a later directory fsync fails.
        // Persistence failure after the commit point must retain the displaced
        // entry for recovery, rather than delete it in the usual cleanup.
        do {
            if fsync(parent) != 0, transition != nil { throw AgentDirectoryError.corruptJournal }
            try transition?("applied", temporary, Self.fileToken(prepared))
        }
        catch { keepTemporary = true; throw error }
    }
}
