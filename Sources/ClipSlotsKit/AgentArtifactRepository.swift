import Foundation
import CryptoKit
import Darwin

public struct AgentArtifactLimits: Sendable {
    public let maximumContentBytes: Int
    public let maximumRecords: Int
    public let maximumRepositoryBytes: Int

    public init(maximumContentBytes: Int = 32 * 1024 * 1024, maximumRecords: Int = 256,
                maximumRepositoryBytes: Int = 128 * 1024 * 1024) {
        self.maximumContentBytes = max(1, min(maximumContentBytes, 64 * 1024 * 1024))
        self.maximumRecords = max(1, min(maximumRecords, 4096))
        self.maximumRepositoryBytes = max(1, min(maximumRepositoryBytes, 1024 * 1024 * 1024))
    }

    internal var maximumSnapshotBytes: Int { maximumContentBytes * 2 + 64 * 1024 }
}

/// Synchronous disk transactions: call off the main actor for larger artifacts.
/// Each instance shares an OS lock and rereads the snapshot before every mutation.
public final class AgentArtifactRepository: @unchecked Sendable {
    public let directory: URL
    public let limits: AgentArtifactLimits
    private let lock: StorageLock
    private var fetches: [AgentArtifactKey: AgentArtifactFetchToken] = [:]

    public init(directory: URL? = nil, limits: AgentArtifactLimits = .init()) throws {
        let root = directory ?? ClipSlotsPaths.dataRoot.appendingPathComponent("agent_artifacts", isDirectory: true)
        guard root.isFileURL else { throw AgentArtifactError.storageUnavailable }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        self.directory = root.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        self.limits = limits
        self.lock = StorageLock(lockURL: self.directory.appendingPathComponent(".artifact.lock"))
    }

    public func record(for key: AgentArtifactKey) throws -> AgentArtifactRecord? {
        try transaction {
            guard var record = try read(key) else { return nil }
            recoverInterruptedFetch(&record)
            return record
        }
    }

    public func records(in scope: AgentArtifactScope, includeDeleted: Bool = false) throws -> [AgentArtifactRecord] {
        try transaction {
            let urls = try snapshotURLs()
            guard urls.count <= limits.maximumRecords else { throw AgentArtifactError.capacityExceeded }
            let storedBytes = try urls.reduce(0) { total, url in
                total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            guard storedBytes <= limits.maximumRepositoryBytes else { throw AgentArtifactError.capacityExceeded }
            var result: [AgentArtifactRecord] = []
            for url in urls {
                var record = try decode(url)
                guard url == snapshotURL(record.key) else { throw AgentArtifactError.storageUnavailable }
                guard record.key.scope == scope, includeDeleted || !record.isDeleted else { continue }
                recoverInterruptedFetch(&record)
                result.append(record)
            }
            return result.sorted { $0.key.path < $1.key.path }
        }
    }

    @discardableResult
    public func merge(_ update: AgentArtifactUpdate) throws -> AgentArtifactRecord {
        try transaction {
            var current = try read(update.key)
            if let current, update.revision < current.revision { return current }
            if let current, current.isDeleted, update.revision == current.revision { return current }
            if let bytes = update.content, bytes.count > limits.maximumContentBytes { throw AgentArtifactError.tooLarge }
            if let title = update.title, title.utf8.count > 2048 { throw AgentArtifactError.invalidMetadata }
            if let mime = update.mimeType,
               mime.utf8.count > 256 || mime.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                throw AgentArtifactError.invalidMetadata
            }
            if let old = current, old.revision == update.revision,
               old.contentRevision == update.revision, let bytes = update.content, old.content != bytes {
                throw AgentArtifactError.revisionConflict
            }
            let advanced = current == nil || update.revision > (current?.revision ?? 0)
            if current == nil {
                current = AgentArtifactRecord(key: update.key, revision: update.revision, contentRevision: nil,
                    content: nil, title: (update.key.path as NSString).lastPathComponent,
                    mimeType: "application/octet-stream", resourceState: .missing, isDeleted: false,
                    updatedAt: Date(), mutationID: UUID())
            }
            guard var record = current else { throw AgentArtifactError.storageUnavailable }
            let previous = record
            record.revision = update.revision
            record.isDeleted = false
            if let title = update.title { record.title = title }
            if let mime = update.mimeType { record.mimeType = mime }
            if let bytes = update.content {
                record.content = bytes
                record.contentRevision = update.revision
                record.resourceState = .ready
            } else if advanced {
                // Keep older bytes visible, but never label them as the new revision.
                record.resourceState = .missing
            }
            if record != previous || advanced {
                record.mutationID = UUID()
                record.updatedAt = Date()
                try save(record)
                fetches.removeValue(forKey: update.key)
            }
            recoverInterruptedFetch(&record)
            return record
        }
    }

    /// Deletion is a durable revisioned tombstone, not remote revocation.
    @discardableResult
    public func delete(_ key: AgentArtifactKey, revision: UInt64) throws -> AgentArtifactRecord {
        try transaction {
            guard var record = try read(key) else { throw AgentArtifactError.missingArtifact }
            if revision < record.revision || (record.isDeleted && revision == record.revision) { return record }
            guard revision > record.revision else { throw AgentArtifactError.revisionConflict }
            record.revision = revision
            record.content = nil
            record.contentRevision = nil
            record.resourceState = .missing
            record.isDeleted = true
            record.updatedAt = Date()
            record.mutationID = UUID()
            try save(record)
            fetches.removeValue(forKey: key)
            return record
        }
    }

    public func beginFetch(for key: AgentArtifactKey) throws -> AgentArtifactFetchToken {
        try transaction {
            guard var record = try read(key), !record.isDeleted else { throw AgentArtifactError.missingArtifact }
            record.resourceState = .loading
            record.mutationID = UUID()
            record.updatedAt = Date()
            let token = AgentArtifactFetchToken(key: key, revision: record.revision, mutationID: record.mutationID)
            try save(record)
            fetches[key] = token
            return token
        }
    }

    /// Returns false for stale, cancelled, duplicate, deleted or cross-instance responses.
    @discardableResult
    public func completeFetch(_ token: AgentArtifactFetchToken, content: Data) throws -> Bool {
        try finish(token, content: content, error: nil)
    }

    @discardableResult
    public func failFetch(_ token: AgentArtifactFetchToken, message: String) throws -> Bool {
        try finish(token, content: nil, error: String(message.prefix(2048)))
    }

    @discardableResult
    public func cancelFetch(_ token: AgentArtifactFetchToken) throws -> Bool {
        try failFetch(token, message: "加载已取消，可重试。")
    }

    private func finish(_ token: AgentArtifactFetchToken, content: Data?, error: String?) throws -> Bool {
        try transaction {
            guard fetches[token.key] == token, var record = try read(token.key), !record.isDeleted,
                  record.revision == token.revision, record.mutationID == token.mutationID else { return false }
            if let content {
                guard content.count <= limits.maximumContentBytes else { throw AgentArtifactError.tooLarge }
                guard record.contentRevision != record.revision || record.content == content else {
                    throw AgentArtifactError.revisionConflict
                }
                record.content = content
                record.contentRevision = token.revision
                record.resourceState = .ready
            } else {
                record.resourceState = .error(error ?? "产物加载失败。")
            }
            record.updatedAt = Date()
            record.mutationID = UUID()
            try save(record)
            fetches.removeValue(forKey: token.key)
            return true
        }
    }

    private func recoverInterruptedFetch(_ record: inout AgentArtifactRecord) {
        if record.resourceState == .loading, fetches[record.key]?.mutationID != record.mutationID {
            record.resourceState = .error("加载已中断，可重试。")
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard !lock.isDegraded else { throw AgentArtifactError.storageUnavailable }
            return try body()
        }
    }

    private func snapshotURL(_ key: AgentArtifactKey) -> URL {
        // Length-framed fields avoid delimiter collisions. Artifact paths never become disk paths.
        let fields = [key.scope.projectID, key.scope.canvasID, key.path]
        let framed = fields.map { "\($0.utf8.count):\($0)" }.joined()
        let name = SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json").standardizedFileURL
    }

    private func snapshotURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }.map(\.standardizedFileURL)
    }

    private func read(_ key: AgentArtifactKey) throws -> AgentArtifactRecord? {
        let url = snapshotURL(key)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw AgentArtifactError.storageUnavailable
        }
        let record = try decode(url)
        guard record.key == key else { throw AgentArtifactError.storageUnavailable }
        return record
    }

    private func decode(_ url: URL) throws -> AgentArtifactRecord {
        let data = try AgentArtifactFileAccess.readRegularFile(url, maximumBytes: limits.maximumSnapshotBytes)
        let record = try JSONDecoder().decode(AgentArtifactRecord.self, from: data)
        guard (record.content?.count ?? 0) <= limits.maximumContentBytes,
              record.title.utf8.count <= 2048, record.mimeType.utf8.count <= 256,
              record.contentRevision.map({ $0 <= record.revision }) ?? (record.content == nil),
              (record.content == nil) == (record.contentRevision == nil),
              record.resourceState != .ready || record.hasCurrentContent,
              !record.isDeleted || record.content == nil else { throw AgentArtifactError.invalidMetadata }
        return record
    }

    private func save(_ record: AgentArtifactRecord) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= limits.maximumSnapshotBytes else { throw AgentArtifactError.tooLarge }
        let target = snapshotURL(record.key)
        let urls = try snapshotURLs()
        let exists = urls.contains(target)
        guard urls.count + (exists ? 0 : 1) <= limits.maximumRecords else { throw AgentArtifactError.capacityExceeded }
        var total = data.count
        for url in urls where url != target {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= limits.maximumSnapshotBytes else {
                throw AgentArtifactError.storageUnavailable
            }
            total += size
        }
        guard total <= limits.maximumRepositoryBytes else { throw AgentArtifactError.capacityExceeded }
        let temporary = directory.appendingPathComponent(".artifact-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, target.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

public enum AgentArtifactFileAccess {
    /// No grant is inferred from an artifact path. The parent must supply an authorized directory.
    public static func read(_ url: URL, within authorizedDirectory: URL,
                            maximumBytes: Int = 32 * 1024 * 1024) throws -> Data {
        guard url.isFileURL, authorizedDirectory.isFileURL else { throw AgentArtifactError.invalidFile }
        let root = authorizedDirectory.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
            throw AgentArtifactError.invalidFile
        }
        return try readRegularFile(candidate, maximumBytes: max(1, min(maximumBytes, 64 * 1024 * 1024)))
    }

    internal static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AgentArtifactError.invalidFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            throw AgentArtifactError.invalidFile
        }
        guard info.st_size <= maximumBytes else { throw AgentArtifactError.tooLarge }
        let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard bytes.count <= maximumBytes else { throw AgentArtifactError.tooLarge }
        return bytes
    }
}
