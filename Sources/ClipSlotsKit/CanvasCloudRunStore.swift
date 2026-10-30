import Foundation
import CryptoKit
import Darwin

public struct CanvasCloudRunRecord: Codable, Equatable, Identifiable {
    public struct CachedResult: Codable, Equatable {
        public let fileExtension: String
        public let sha256: String
        public let bytes: Int
        public let metadata: CanvasCloudResourceMetadata
    }
    public let id: UUID
    public let projectID: String
    public let nodeID: String
    public let nodeCreatedAt: Date
    public let configuration: CanvasCloudConfiguration
    public var task: CanvasCloudTask
    public var result: CachedResult?
    public var projected = false
}

/// Separate from graph projection. A result bundle is installed atomically
/// with its receipt, so a killed audio import can recover the complete bytes.
public final class CanvasCloudRunStore: @unchecked Sendable {
    private let root: URL
    #if DEBUG
    var afterResultInstall: (() -> Void)?
    #endif
    public init(root: URL) { self.root = root.appendingPathComponent("cloud-generation-runs", isDirectory: true) }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func directory(project: String, node: String, createdAt: Date) -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode([project, node, String(createdAt.timeIntervalSinceReferenceDate)])) ?? Data()
        return root.appendingPathComponent(Self.digest(data), isDirectory: true)
    }
    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CanvasCloudError.invalid("云端任务记录目录无效")
        }
    }
    private func locked<T>(project: String, node: String, createdAt: Date, _ body: (URL) throws -> T) throws -> T {
        let directory = directory(project: project, node: node, createdAt: createdAt)
        try ensureDirectory(root); try ensureDirectory(directory)
        let fd = open(directory.appendingPathComponent("record.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CanvasCloudError.invalid("无法锁定云端任务记录") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CanvasCloudError.invalid("云端任务记录正在被使用，请稍后取回结果") }
        defer { _ = flock(fd, LOCK_UN) }
        return try body(directory)
    }
    private func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CanvasCloudError.invalid("云端任务记录无法读取") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= limit else { throw CanvasCloudError.invalid("云端任务记录损坏或过大") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw CanvasCloudError.invalid("云端任务记录读取失败") }
            if count == 0 { break }
            guard count <= limit - data.count else { throw CanvasCloudError.invalid("云端任务记录过大") }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == info.st_size else { throw CanvasCloudError.invalid("云端任务记录读取不完整") }
        return data
    }
    private func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CanvasCloudError.invalid("云端任务目录无法确认落盘") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CanvasCloudError.invalid("云端任务目录尚未落盘") }
    }
    private func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-\(UUID().uuidString)")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CanvasCloudError.invalid("云端任务记录无法保存") }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 { if errno == EINTR { continue }; throw CanvasCloudError.invalid("云端任务记录保存失败") }
                guard count > 0 else { throw CanvasCloudError.invalid("云端任务记录保存不完整") }
                written += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
            throw CanvasCloudError.invalid("云端任务记录尚未落盘")
        }
        try syncDirectory(url.deletingLastPathComponent())
    }
    private func save(_ record: CanvasCloudRunRecord, directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= 262_144 else { throw CanvasCloudError.invalid("云端任务参数过大") }
        try write(data, to: directory.appendingPathComponent(record.id.uuidString + ".json"))
    }
    private func sameIdentity(_ a: CanvasCloudRunRecord, _ b: CanvasCloudRunRecord) -> Bool {
        a.id == b.id && a.projectID == b.projectID && a.nodeID == b.nodeID && a.nodeCreatedAt == b.nodeCreatedAt
            && a.configuration == b.configuration && a.task.provider == b.task.provider && a.task.mode == b.task.mode
            && a.task.model == b.task.model && a.task.service == b.task.service && a.task.receiptID == b.task.receiptID
            && a.task.createdAt == b.task.createdAt
    }
    private func load(_ id: UUID, directory: URL) throws -> CanvasCloudRunRecord {
        var record = try JSONDecoder().decode(CanvasCloudRunRecord.self,
            from: read(directory.appendingPathComponent(id.uuidString + ".json"), limit: 262_144))
        guard record.id == id, record.task.receiptID == id,
              directory == self.directory(project: record.projectID, node: record.nodeID, createdAt: record.nodeCreatedAt)
        else { throw CanvasCloudError.invalid("云端任务记录身份不一致") }
        let bundle = directory.appendingPathComponent(id.uuidString + "-result", isDirectory: true)
        var info = stat()
        if lstat(bundle.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw CanvasCloudError.invalid("云端结果目录无效") }
            let accepted = try JSONDecoder().decode(CanvasCloudRunRecord.self,
                from: read(bundle.appendingPathComponent("record.json"), limit: 262_144))
            guard sameIdentity(record, accepted), accepted.task.state == .complete, accepted.result != nil,
                  record.task.id == nil || record.task.id == accepted.task.id else {
                throw CanvasCloudError.invalid("云端结果与任务回执不一致")
            }
            let projected = record.projected && record.result == accepted.result
            record = accepted; record.projected = projected
        } else if errno != ENOENT { throw CanvasCloudError.invalid("云端结果目录无法读取") }
        return record
    }
    private func records(directory: URL) throws -> [CanvasCloudRunRecord] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                    throw CanvasCloudError.invalid("云端任务记录文件身份无效")
                }
                return try load(id, directory: directory)
            }.sorted {
                $0.task.createdAt == $1.task.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.task.createdAt > $1.task.createdAt
            }
    }
    public func latest(project: String, node: String, createdAt: Date) throws -> CanvasCloudRunRecord? {
        var info = stat()
        let directory = directory(project: project, node: node, createdAt: createdAt)
        if lstat(directory.path, &info) != 0, errno == ENOENT { return nil }
        return try locked(project: project, node: node, createdAt: createdAt) { try records(directory: $0).first }
    }
    public func record(project: String, node: String, createdAt: Date, id: UUID) throws -> CanvasCloudRunRecord {
        try locked(project: project, node: node, createdAt: createdAt) { try load(id, directory: $0) }
    }
    public func adopt(project: String, node: String, createdAt: Date,
                      configuration: CanvasCloudConfiguration, task: CanvasCloudTask) throws -> CanvasCloudRunRecord {
        guard task.id?.isEmpty == false, [.pending, .complete].contains(task.state) else {
            throw CanvasCloudError.invalid("旧云端任务没有可查询的回执")
        }
        return try locked(project: project, node: node, createdAt: createdAt) { directory in
            if let existing = try records(directory: directory).first(where: {
                $0.task.id == task.id && $0.task.provider == task.provider && $0.task.mode == task.mode
                    && $0.task.model == task.model && $0.task.service == task.service
            }) { return existing }
            let id = UUID()
            var original = configuration; original.task = nil
            var identity = task; identity.receiptID = id
            let record = CanvasCloudRunRecord(id: id, projectID: project, nodeID: node, nodeCreatedAt: createdAt,
                configuration: original, task: identity)
            try save(record, directory: directory)
            return record
        }
    }
    public func begin(project: String, node: String, createdAt: Date,
                      configuration: CanvasCloudConfiguration) throws -> CanvasCloudRunRecord {
        guard !project.isEmpty, !node.isEmpty, createdAt.timeIntervalSinceReferenceDate.isFinite,
              configuration.task == nil, configuration.validationError == nil else {
            throw CanvasCloudError.invalid("云端任务身份或参数无效")
        }
        return try locked(project: project, node: node, createdAt: createdAt) { directory in
            let previous = try records(directory: directory).first
            if let previous, [.submitting, .unknown, .pending].contains(previous.task.state),
               configuration.replacesReceiptID != previous.id {
                throw CanvasCloudError.invalid("已有云端任务或未核对回执，请先取回结果，或在核对后明确新建任务")
            }
            let id = UUID()
            let record = CanvasCloudRunRecord(id: id, projectID: project, nodeID: node, nodeCreatedAt: createdAt,
                configuration: configuration, task: .init(configuration: configuration, receiptID: id))
            try save(record, directory: directory)
            return record
        }
    }
    private func change(_ original: CanvasCloudRunRecord, _ update: (inout CanvasCloudRunRecord, URL) throws -> Void) throws -> CanvasCloudRunRecord {
        try locked(project: original.projectID, node: original.nodeID, createdAt: original.nodeCreatedAt) { directory in
            var current = try load(original.id, directory: directory)
            guard sameIdentity(current, original) else { throw CanvasCloudError.invalid("云端任务记录身份已变更") }
            try update(&current, directory); try save(current, directory: directory)
            return current
        }
    }
    public func accept(_ original: CanvasCloudRunRecord, task: CanvasCloudTask) throws -> CanvasCloudRunRecord {
        try change(original) { current, _ in
            guard task.provider == current.task.provider, task.mode == current.task.mode,
                  task.model == current.task.model, task.service == current.task.service,
                  task.rigCheck == current.task.rigCheck,
                  task.state == .pending, task.id.map(CanvasCloudTask.validID) == true,
                  current.task.id == nil || current.task.id == task.id else {
                throw CanvasCloudError.invalid("云端任务回执身份不一致")
            }
            if current.task.state == .complete { return }
            guard [.submitting, .unknown, .pending].contains(current.task.state) else {
                throw CanvasCloudError.invalid("已拒绝的云端任务不能被重新接受")
            }
            current.task.id = task.id; current.task.state = .pending
            if current.task.mode == .rig { current.task.submissionStarted = true }
        }
    }
    public func checkpointRig(_ original: CanvasCloudRunRecord, check: CanvasCloudRigCheck) throws -> CanvasCloudRunRecord {
        try change(original) { current, _ in
            guard current.task.provider == .tripo, current.task.mode == .rig, current.task.id == nil,
                  current.task.submissionStarted == false, current.task.state != .failed,
                  check.sourceTaskID == current.configuration.sourceTaskID,
                  check.service.submissionPath == "animations/rig-check", check.service.statusPrefix == "tasks/" else {
                throw CanvasCloudError.invalid("骨骼检查不属于此任务")
            }
            if let previous = current.task.rigCheck {
                guard previous.sourceTaskID == check.sourceTaskID, previous.service == check.service,
                      previous.id == nil || previous.id == check.id,
                      previous.state != .complete || previous == check,
                      previous.state != .pending || check.state != .submitting else {
                    throw CanvasCloudError.invalid("骨骼检查回执不能回退或替换")
                }
            }
            guard check.id.map(CanvasCloudTask.validID) ?? (check.state != .pending) else {
                throw CanvasCloudError.invalid("骨骼检查任务 ID 无效")
            }
            current.task.rigCheck = check
        }
    }
    public func startSubmission(_ original: CanvasCloudRunRecord) throws -> CanvasCloudRunRecord {
        try change(original) { current, _ in
            guard current.task.canResumeRigCheck, current.task.rigCheck?.riggable == true,
                  current.task.rigCheck?.state == .complete, current.task.state != .failed else {
                throw CanvasCloudError.invalid("骨骼检查未完成或最终提交已经开始")
            }
            current.task.submissionStarted = true
        }
    }
    public func finishWaiting(_ original: CanvasCloudRunRecord, rejected: Bool = false) throws -> CanvasCloudRunRecord {
        try change(original) { current, _ in
            if current.task.state != .failed, current.task.id == nil && current.result == nil {
                current.task.state = current.task.canResumeRigCheck ? .pending : (rejected ? .failed : .unknown)
            }
        }
    }
    public func cache(_ original: CanvasCloudRunRecord, result: CanvasCloudClient.Result) throws -> CanvasCloudRunRecord {
        guard !result.data.isEmpty, result.data.count <= 150 * 1024 * 1024,
              ["mp3", "glb", "spz"].contains(result.fileExtension) else {
            throw CanvasCloudError.invalid("云端结果为空、过大或类型无效")
        }
        return try change(original) { current, directory in
            guard result.metadata.provider == current.task.provider,
                  current.task.id == nil || current.task.id == result.metadata.taskID,
                  result.metadata.taskID.map(CanvasCloudTask.validID) ?? true,
                  result.metadata.receiptID == nil || result.metadata.receiptID == current.id,
                  result.fileExtension == (current.task.provider == .tripo ? "glb" : current.task.provider == .worldLabs ? "spz" : "mp3"),
                  current.task.state != .failed else { throw CanvasCloudError.invalid("云端结果不属于此任务") }
            var metadata = result.metadata; metadata.receiptID = current.id
            let cached = CanvasCloudRunRecord.CachedResult(fileExtension: result.fileExtension,
                sha256: Self.digest(result.data), bytes: result.data.count, metadata: metadata)
            if let previous = current.result {
                guard previous == cached else { throw CanvasCloudError.invalid("云端结果已保存，不接受冲突产物") }
                return
            }
            current.task.id = result.metadata.taskID; current.task.state = .complete; current.result = cached
            let bundle = directory.appendingPathComponent(current.id.uuidString + "-result", isDirectory: true)
            let staging = directory.appendingPathComponent(".result-\(UUID().uuidString)", isDirectory: true)
            try ensureDirectory(staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            try write(result.data, to: staging.appendingPathComponent("data." + result.fileExtension))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try write(encoder.encode(current), to: staging.appendingPathComponent("record.json"))
            guard rename(staging.path, bundle.path) == 0 else { throw CanvasCloudError.invalid("云端结果保存失败") }
            try syncDirectory(directory)
            #if DEBUG
            afterResultInstall?()
            #endif
        }
    }
    public func cachedResult(_ original: CanvasCloudRunRecord) throws -> CanvasCloudClient.Result? {
        try locked(project: original.projectID, node: original.nodeID, createdAt: original.nodeCreatedAt) { directory in
            let current = try load(original.id, directory: directory)
            guard sameIdentity(current, original) else { throw CanvasCloudError.invalid("云端任务记录身份不一致") }
            guard let result = current.result else { return nil }
            let url = directory.appendingPathComponent(current.id.uuidString + "-result/data." + result.fileExtension)
            guard ["mp3", "glb", "spz"].contains(result.fileExtension), result.bytes > 0, result.bytes <= 150 * 1024 * 1024 else {
                throw CanvasCloudError.invalid("保存的云端结果描述无效")
            }
            let data = try read(url, limit: 150 * 1024 * 1024)
            guard data.count == result.bytes, Self.digest(data) == result.sha256 else {
                throw CanvasCloudError.invalid("保存的云端结果字节校验失败")
            }
            return .init(data: data, fileExtension: result.fileExtension, metadata: result.metadata)
        }
    }
    public func markProjected(_ original: CanvasCloudRunRecord) throws -> CanvasCloudRunRecord {
        try change(original) { current, _ in
            guard current.result != nil else { throw CanvasCloudError.invalid("云端结果尚未保存") }
            current.projected = true
        }
    }
}
