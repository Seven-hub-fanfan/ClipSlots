import Foundation

/// Cancellation is checked between bounded copy chunks and once more at commit.
public final class FileImportCancellation {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    public func check() throws { if isCancelled { throw CancellationError() } }
}

/// Owns unpublished files on the destination volume. No storage lock or slot
/// write queue may be held while constructing this object. Commit only renames
/// these files; there is deliberately no physical-copy fallback inside the lock.
public final class PreparedSlotBody {
    private static let sweepLock = NSLock()
    private static var sweptRoots: Set<String> = []
    private let directory: URL
    private var files: [UUID: URL] = [:]
    private var lease: Int32 = -1
    public let cancellation: FileImportCancellation

    public init(content: SlotContent, storageRoot: URL,
                cancellation: FileImportCancellation = FileImportCancellation(),
                preferClone: Bool = true,
                progress: ((Int64, Int64) throws -> Void)? = nil) throws {
        self.cancellation = cancellation
        directory = storageRoot.appendingPathComponent(".file-import-\(UUID().uuidString)")
        try cancellation.check()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        lease = open(directory.appendingPathComponent(".lease").path, O_CREAT | O_RDWR, 0o600)
        guard lease >= 0, flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            if lease >= 0 { close(lease); lease = -1 }
            try? fm.removeItem(at: directory)
            throw AgentCanvasError.unavailable
        }
        do {
            Self.sweepAbandoned(in: storageRoot)
            let referenced = Set(content.items.flatMap { $0 }.filter { $0.type == "public.file-url" }
                .compactMap { String(data: $0.data, encoding: .utf8) })
            for (url, file) in content.managedBodyFiles ?? [:] where referenced.contains(url) {
                try cancellation.check()
                let target = directory.appendingPathComponent(file.id.uuidString)
                if let data = file.data {
                    try data.write(to: target)
                } else {
                    guard let path = file.storagePath ?? file.localFileReferencePath else {
                        throw AgentCanvasError.unavailable
                    }
                    try Self.copy(URL(fileURLWithPath: path), to: target, preferClone: preferClone,
                                  cancellation: cancellation, progress: progress)
                }
                files[file.id] = target
            }
            try cancellation.check()
        } catch {
            try? fm.removeItem(at: directory)
            close(lease); lease = -1
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        if lease >= 0 { close(lease) }
    }

    func stage(_ id: UUID, to destination: URL) throws {
        try cancellation.check()
        guard let source = files[id], rename(source.path, destination.path) == 0 else {
            throw AgentCanvasError.writeFailed
        }
        files.removeValue(forKey: id)
    }

    private static func signature(_ value: stat) -> [Int64] {
        [Int64(value.st_dev), Int64(value.st_ino), value.st_size,
         Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
         Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)]
    }

    private static func copy(_ source: URL, to target: URL, preferClone: Bool,
                             cancellation: FileImportCancellation,
                             progress: ((Int64, Int64) throws -> Void)?) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var before = stat()
        guard fstat(input.fileDescriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG else { throw AgentCanvasError.unavailable }
        try progress?(0, before.st_size)
        try cancellation.check()
        if !preferClone || clonefile(source.path, target.path, 0) != 0 {
            guard FileManager.default.createFile(atPath: target.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw AgentCanvasError.writeFailed
            }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            var count: Int64 = 0
            var lastUpdate = ProcessInfo.processInfo.systemUptime
            while true {
                try cancellation.check()
                let block = try input.read(upToCount: 1024 * 1024) ?? Data()
                if block.isEmpty { break }
                try output.write(contentsOf: block)
                count += Int64(block.count)
                let now = ProcessInfo.processInfo.systemUptime
                if count == Int64(block.count) || now - lastUpdate >= 0.1 {
                    try progress?(count, before.st_size)
                    lastUpdate = now
                }
            }
            guard count == before.st_size else { throw AgentCanvasError.conflict }
            try output.synchronize()
            guard fchmod(output.fileDescriptor, before.st_mode & 0o777) == 0 else {
                throw AgentCanvasError.writeFailed
            }
        }
        var after = stat()
        var current = stat()
        guard fstat(input.fileDescriptor, &after) == 0, stat(source.path, &current) == 0,
              signature(before) == signature(after), signature(before) == signature(current) else {
            throw AgentCanvasError.conflict
        }
        try cancellation.check()
        try progress?(before.st_size, before.st_size)
    }

    private static func sweepAbandoned(in root: URL) {
        sweepLock.lock()
        let first = sweptRoots.insert(root.standardizedFileURL.path).inserted
        sweepLock.unlock()
        guard first else { return }
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.creationDateKey, .isSymbolicLinkKey, .isDirectoryKey])) ?? []
            where entry.lastPathComponent.hasPrefix(".file-import-") {
            guard let values = try? entry.resourceValues(forKeys: [.creationDateKey, .isSymbolicLinkKey, .isDirectoryKey]),
                  values.isSymbolicLink != true, values.isDirectory == true,
                  let created = values.creationDate,
                  created.timeIntervalSinceNow < -86400 else { continue }
            let fd = open(entry.appendingPathComponent(".lease").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { try? fm.removeItem(at: entry) }
            close(fd)
        }
    }
}
