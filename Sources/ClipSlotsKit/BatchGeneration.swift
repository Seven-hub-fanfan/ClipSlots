import Foundation

/// Frozen library inputs. Local paths are private batch data, never Agent-visible resource IDs.
public struct BatchGenerationSource: Codable, Equatable, Identifiable {
    public struct Reference: Codable, Equatable {
        public var id: String
        public var path: String
        public var version: String
    }
    public var pageID: String
    public var groupID: String
    public var groupCreatedAt: Date
    public var slot: Int
    public var title: String
    public var location: String
    public var revision: String
    public var prompt: String
    public var references: [Reference]
    public var blockingReason: String?
    public var id: String { CanvasNode.makeId(groupId: groupID, slot: slot) }

    public init(pageID: String, pageName: String = "", group: SpecialSlot, slot: Int, content: SlotContent) {
        self.pageID = pageID; groupID = group.id; groupCreatedAt = group.createdAt; self.slot = slot
        location = [pageName, group.name, "槽位 \(slot)"].filter { !$0.isEmpty }.joined(separator: " · ")
        prompt = content.plainText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = content.label.flatMap { $0.isEmpty ? nil : $0 } ?? String(prompt.prefix(72))
        if title.isEmpty { title = "槽位 \(slot)" }
        revision = Self.revision(of: content)
        let images = content.attachments.filter {
            ($0.type == .image || ($0.type == .file && CanvasAttachmentKind.from(fileName: $0.name) == .image))
                && !CrateGeneration.isGeneratedAssetName($0.name)
        }
        references = images.compactMap { image in
            guard let path = [image.storagePath, image.path, image.originalPath].compactMap({ $0 })
                .first(where: { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }) else { return nil }
            return Reference(id: "media-" + image.id.uuidString, path: path,
                             version: GenerationRunContext.fileVersion(path))
        }
        if prompt.isEmpty { blockingReason = "缺少文字提示词" }
        else if references.count != images.count { blockingReason = "参考图片不可读取" }
    }

    /// Stable across lightweight/full reads and attachment lazy migration.
    public static func revision(of content: SlotContent) -> String {
        struct Revision: Encodable {
            var contentID: String
            var updatedAt: Double
            var body: String
            var attachments: [String]
        }
        let value = Revision(contentID: content.contentId, updatedAt: content.updatedAt,
            body: content.plainText ?? "", attachments: content.attachments.map { "\($0.id)|\($0.name)|\($0.type)" })
        return CanvasWorkflowSnapshot.digest((try? CanvasWorkflowSnapshot.jsonData(value)) ?? Data())
    }

    public var filesAreCurrent: Bool {
        references.allSatisfy { $0.version != "missing" && GenerationRunContext.fileVersion($0.path) == $0.version }
    }

    public func facts(node: CanvasNode) -> CanvasWorkflowFacts {
        .init(node: node, title: title, body: prompt, bodyRevision: revision,
            inputImagePaths: references.map(\.path), expectedInputImages: references.count,
            media: references.map {
                .init(id: $0.id, attachmentID: String($0.id.dropFirst(6)),
                      name: URL(fileURLWithPath: $0.path).lastPathComponent, kind: "image", role: "input",
                      revision: $0.version, availability: "local")
            }, resourcePaths: Dictionary(references.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a }))
    }
}

public struct BatchGenerationGroup: Identifiable {
    public var page: SlotPage
    public var group: SpecialSlot
    public var sources: [BatchGenerationSource]
    public var id: String { group.id }
    public var eligibleCount: Int { sources.filter { $0.blockingReason == nil }.count }
}

public enum BatchGenerationSelection {
    public enum State { case none, mixed, all }
    public static func state(ids: Set<String>, selected: Set<String>) -> State {
        let count = ids.intersection(selected).count
        return count == 0 ? .none : count == ids.count ? .all : .mixed
    }
    public static func toggled(ids: Set<String>, selected: Set<String>) -> Set<String> {
        state(ids: ids, selected: selected) == .all ? selected.subtracting(ids) : selected.union(ids)
    }
}

public struct BatchGeneration: Codable, Equatable, Identifiable {
    public struct OutputNaming: Codable, Equatable {
        public var day: String
        public var sequence: Int
        public var label: String { "\(day)_批次-\(String(format: "%03d", sequence))" }
        public func folderName(itemNumber: Int, kind: CanvasNodeKind) -> String {
            "\(label)_\(kind == .video ? "视频" : "图片")-\(String(format: "%03d", itemNumber))"
        }
    }
    public enum Status: String, Codable {
        case pending, submitting, tracking, succeeded, failed, skipped, stopped, unknown, retained
        public var label: String {
            switch self {
            case .pending: return "等待提交"
            case .submitting: return "正在提交"
            case .tracking: return "生成中"
            case .succeeded: return "已写回"
            case .failed: return "失败"
            case .skipped: return "已跳过"
            case .stopped: return "已停止"
            case .unknown: return "提交待核对"
            case .retained: return "产物已保留"
            }
        }
    }
    public struct Item: Codable, Equatable, Identifiable {
        public var id = UUID()
        public var source: BatchGenerationSource
        public var node: CanvasNode
        public var runID = UUID()
        /// Chosen before any write: append remains idempotent across a crash.
        public var outputID = UUID()
        public var status: Status = .pending
        public var taskID: String?
        public var detail: String?
        public var localFile: String?
        public var canRecover: Bool {
            taskID != nil && [.stopped, .tracking, .failed, .unknown, .retained].contains(status)
        }
    }
    public var schemaVersion = 3
    public var id = UUID()
    public var projectID: String
    public var createdAt = Date()
    /// Optional so v1 journals and their UUID output paths remain readable.
    public var outputNaming: OutputNaming?
    /// Absent on older journals: their original serial behavior remains readable.
    public var concurrency: Int?
    public static let maximumConcurrency = 32
    public var effectiveConcurrency: Int { min(Self.maximumConcurrency, max(1, concurrency ?? 1)) }
    public var stopRequested = false
    public var items: [Item]
    public var completedCount: Int { items.filter { $0.status == .succeeded }.count }

    public init(projectID: String, groups: [BatchGenerationGroup], selected: Set<String>, configuration: CanvasNode) {
        self.projectID = projectID
        concurrency = Self.maximumConcurrency
        let capturedAt = createdAt
        items = groups.filter { selected.contains($0.id) }.flatMap { group in
            group.sources.map { source in
                var node = configuration
                node.pageId = source.pageID; node.groupId = source.groupID; node.slot = source.slot
                node.createdAt = capturedAt; node.taskId = nil; node.seed = nil
                node.state = .idle; node.outputAttachmentIds = []; node.inputAttachmentIds = []
                var item = Item(source: source, node: node)
                if let reason = source.blockingReason { item.status = .skipped; item.detail = reason }
                return item
            }
        }
    }

    /// A restart never authorizes another paid submission. Known IDs are query-only.
    public mutating func reconcile(runs: [GenerationRun]) {
        stopRequested = true
        for i in items.indices {
            let run = runs.first { $0.id == items[i].runID }
            if items[i].taskID == nil {
                items[i].taskID = run?.attempts.reversed().compactMap(\.taskID).first
            }
            switch items[i].status {
            case .submitting, .unknown:
                items[i].status = items[i].taskID != nil ? .stopped : .unknown
                items[i].detail = items[i].taskID != nil ? "可继续查询已提交任务" : "请在 Crate 核对提交结果；此处不会自动重提"
            case .pending, .tracking:
                items[i].status = .stopped
                items[i].detail = items[i].taskID == nil ? "尚未提交" : "可继续查询已提交任务"
            default: break
            }
        }
    }
}

/// Serial disk ownership; batches survive view switches and process restarts.
public final class BatchGenerationStorage: @unchecked Sendable {
    public let root: URL
    private let lock: StorageLock
    public init(root: URL = ClipSlotsPaths.dataRoot) {
        self.root = root.appendingPathComponent("generation-batches", isDirectory: true)
        lock = StorageLock(lockURL: self.root.appendingPathComponent(".storage.lock"))
    }

    /// Reserve a daily sequence before submitting. The counter survives deleted
    /// history, and an interrupted reservation may leave a gap but never reuse a name.
    public func create(_ batch: BatchGeneration, timeZone: TimeZone = .current) throws -> BatchGeneration {
        try locked {
            let journal = root.appendingPathComponent(batch.id.uuidString + ".json")
            if FileManager.default.fileExists(atPath: journal.path) {
                return try JSONDecoder().decode(BatchGeneration.self, from: Data(contentsOf: journal))
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            let day = formatter.string(from: batch.createdAt)
            let counterURL = root.appendingPathComponent(".sequences.json")
            var counters = FileManager.default.fileExists(atPath: counterURL.path)
                ? try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: counterURL)) : [:]
            let recordedMax = try loadAll().compactMap(\.outputNaming)
                .filter { $0.day == day }.map(\.sequence).max() ?? 0
            let previous = max(counters[day] ?? 0, recordedMax)
            guard previous < Int(Int32.max) else { throw CocoaError(.fileWriteInvalidFileName) }
            counters[day] = previous + 1
            try CanvasWorkflowSnapshot.jsonData(counters).write(to: counterURL, options: .atomic)
            var prepared = batch
            prepared.outputNaming = .init(day: day, sequence: previous + 1)
            try save(prepared)
            return prepared
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard !lock.isDegraded else { throw CocoaError(.fileLocking) }
            return try body()
        }
    }

    public func save(_ batch: BatchGeneration) throws {
        try locked {
            try CanvasWorkflowSnapshot.jsonData(batch).write(
                to: root.appendingPathComponent(batch.id.uuidString + ".json"), options: .atomic)
        }
    }
    public func loadAll() throws -> [BatchGeneration] {
        try locked {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                       options: .skipsHiddenFiles)
                .filter { $0.pathExtension == "json" }.map {
                    try JSONDecoder().decode(BatchGeneration.self, from: Data(contentsOf: $0))
                }.sorted { $0.createdAt > $1.createdAt }
        }
    }
    public func keepOutput(_ file: URL, batchID: UUID, itemID: UUID) throws -> URL {
        try locked {
            let fm = FileManager.default
            let batch = try JSONDecoder().decode(BatchGeneration.self, from:
                Data(contentsOf: root.appendingPathComponent(batchID.uuidString + ".json")))
            guard let index = batch.items.firstIndex(where: { $0.id == itemID }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            if let path = batch.items[index].localFile, fm.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            if batch.schemaVersion >= 3, let naming = batch.outputNaming {
                guard naming.day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                      naming.sequence > 0 else { throw CocoaError(.fileWriteInvalidFileName) }
                let dir = root.appendingPathComponent("outputs", isDirectory: true).appendingPathComponent(naming.label)
                let ownerURL = dir.appendingPathComponent(".owner")
                if fm.fileExists(atPath: dir.path) {
                    guard (try? String(contentsOf: ownerURL)) == batchID.uuidString else { throw CocoaError(.fileWriteFileExists) }
                } else {
                    let reservation = dir.deletingLastPathComponent().appendingPathComponent(".folder-\(UUID())")
                    defer { try? fm.removeItem(at: reservation) }
                    try fm.createDirectory(at: reservation, withIntermediateDirectories: true)
                    try Data(batchID.uuidString.utf8).write(to: reservation.appendingPathComponent(".owner"), options: .atomic)
                    try fm.moveItem(at: reservation, to: dir)
                }
                // Deterministic per-item prefix recovers a completed rename even
                // if the app closed before writing localFile to its journal.
                let prefix = String(format: "%03d", index + 1) + "_\(itemID.uuidString)_"
                let existing = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: .skipsHiddenFiles).filter { $0.lastPathComponent.hasPrefix(prefix) }
                guard existing.count <= 1 else { throw CocoaError(.fileWriteFileExists) }
                if let existing = existing.first {
                    guard try existing.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    return dir.appendingPathComponent(existing.lastPathComponent)
                }
                let target = dir.appendingPathComponent(prefix + file.lastPathComponent)
                let staging = dir.appendingPathComponent(".incoming-\(UUID())")
                defer { try? fm.removeItem(at: staging) }
                guard ingestExternalFile(at: file, to: staging) else { throw CocoaError(.fileWriteUnknown) }
                try fm.moveItem(at: staging, to: target)
                return target
            }
            let dir: URL
            if let naming = batch.outputNaming {
                guard naming.day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                      naming.sequence > 0 else { throw CocoaError(.fileWriteInvalidFileName) }
                dir = root.appendingPathComponent("outputs", isDirectory: true)
                    .appendingPathComponent(naming.folderName(itemNumber: index + 1, kind: batch.items[index].node.kind))
                let ownerURL = dir.appendingPathComponent(".owner")
                let owner = "\(batchID.uuidString)/\(itemID.uuidString)"
                if fm.fileExists(atPath: dir.path) {
                    guard (try? String(contentsOf: ownerURL, encoding: .utf8)) == owner else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                } else {
                    let reservation = dir.deletingLastPathComponent().appendingPathComponent(".folder-\(UUID())")
                    defer { try? fm.removeItem(at: reservation) }
                    try fm.createDirectory(at: reservation, withIntermediateDirectories: true)
                    try Data(owner.utf8).write(to: reservation.appendingPathComponent(".owner"), options: .atomic)
                    try fm.moveItem(at: reservation, to: dir)
                }
            } else {
                // Legacy recovery stays in the original directory; never move live attachments.
                dir = root.appendingPathComponent(batchID.uuidString).appendingPathComponent(itemID.uuidString)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let existing = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                      options: .skipsHiddenFiles)
            guard existing.count <= 1 else { throw CocoaError(.fileWriteFileExists) }
            if let existing = existing.first {
                guard try existing.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return dir.appendingPathComponent(existing.lastPathComponent)
            }
            let target = dir.appendingPathComponent(file.lastPathComponent)
            // Stage before rename: a crash or failed copy cannot expose a partial image.
            let staging = dir.appendingPathComponent(".incoming-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staging) }
            guard ingestExternalFile(at: file, to: staging) else { throw CocoaError(.fileWriteUnknown) }
            try fm.moveItem(at: staging, to: target)
            return target
        }
    }
}
