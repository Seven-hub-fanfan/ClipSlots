import Foundation
import CryptoKit

/// History owns bytes independently of live slot directories and the recycle bin.
/// Blobs are content addressed, copied with APFS COW (never hard linked), and hashed
/// in 1 MiB chunks. JSON history contains only metadata, even for large attachments.
public final class SlotUndoMediaArchive {
    public static let shared = SlotUndoMediaArchive()
    public static let defaultByteLimit: Int64 = 2 * 1024 * 1024 * 1024

    private struct Record: Codable {
        var slot: Int
        var key: String
        var id: String
        var digest: String
        var bytes: Int64
    }
    private struct Manifest: Codable {
        var id: String
        var groupID: String
        var signature: String
        var records: [Record]
    }
    private let root: URL
    private let byteLimit: Int64
    private let lock = NSRecursiveLock()
    private var pending = Set<String>()
    private let fm = FileManager.default

    public init(root: URL = ClipSlotsPaths.undoDir.appendingPathComponent("media"),
                byteLimit: Int64 = SlotUndoMediaArchive.defaultByteLimit) {
        self.root = root
        self.byteLimit = byteLimit
    }
    private var blobs: URL { root.appendingPathComponent("blobs") }
    private var manifests: URL { root.appendingPathComponent("snapshots") }

    private func manifestURL(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw AgentCanvasError.conflict }
        return manifests.appendingPathComponent(id + ".json")
    }
    private func blobURL(_ digest: String) throws -> URL {
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw AgentCanvasError.conflict
        }
        return blobs.appendingPathComponent(digest + ".bin")
    }
    private static func fingerprint(_ url: URL) throws -> (String, Int64) {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
            throw AgentOperationError("历史素材不是可读取的普通文件。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            digest.update(data: chunk)
            bytes += Int64(chunk.count)
        }
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
    private func put(data: Data?, source: URL?) throws -> (String, Int64) {
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        let sourceBytes = data.map { Int64($0.count) }
            ?? source.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init) ?? 0
        guard sourceBytes <= byteLimit else {
            throw AgentOperationError("单次撤销素材超过 2 GiB 上限，本次操作未执行。")
        }
        let temporary = blobs.appendingPathComponent(".pending-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        if let data {
            try data.write(to: temporary, options: .atomic)
        } else if let source, cloneOrCopyItem(at: source, to: temporary) {
            // Clone first, then hash the immutable copy; source edits cannot tear it.
        } else {
            throw AgentOperationError("附件原文件不可用，未保存不完整的撤销记录。")
        }
        let (digest, count) = try Self.fingerprint(temporary)
        let target = try blobURL(digest)
        if fm.fileExists(atPath: target.path) {
            let existing = try Self.fingerprint(target)
            guard existing.0 == digest, existing.1 == count else {
                throw AgentOperationError("历史素材校验失败，请保留现状后重试。")
            }
            return (digest, count)
        }
        let used = try fm.contentsOfDirectory(at: blobs, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "bin" }
            .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard count <= byteLimit, used <= byteLimit - count else {
            throw AgentOperationError("撤销素材已达到 2 GiB 上限，本次操作未执行；可减少保留的撤销步数后重试。")
        }
        try fm.moveItem(at: temporary, to: target)
        return (digest, count)
    }
    private static func needsBytes(_ file: SlotContent.SlotAttachment) -> Bool {
        if file.data?.isEmpty == false || file.storagePath?.isEmpty == false { return true }
        guard file.type == .image || file.type == .file else { return false }
        if file.localFileReferencePath != nil { return true }
        if let raw = file.url, let url = URL(string: raw),
           ["https", "http"].contains(url.scheme?.lowercased() ?? "") { return false }
        return true
    }

    /// Legacy recovery only searches exact group/slot/UUID identities. Multiple
    /// archived versions must agree byte for byte; never choose the newest by date.
    private func source(for file: SlotContent.SlotAttachment, slot: Int, group: String,
                        storageRoot: URL, recoverLegacy: Bool, body: Bool) throws -> URL? {
        let slotDir = storageRoot.appendingPathComponent(group).appendingPathComponent(String(slot))
        let relative = body ? "body-files/\(file.id.uuidString)/\(URL(fileURLWithPath: file.name).lastPathComponent)"
            : "attachments/\(file.id.uuidString).bin"
        let canonical = slotDir.appendingPathComponent(relative)
        if fm.fileExists(atPath: canonical.path) { return canonical }
        if let path = file.storagePath, fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let path = file.localFileReferencePath, fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard recoverLegacy else { return nil }
        let trash = storageRoot.appendingPathComponent(".trash")
        var candidates: [URL] = []
        for entry in (try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? [] {
            let name = entry.lastPathComponent
            let archivedSlot: URL
            if ["slot_cleared_", "slot_overwritten_"].contains(where: {
                name.hasPrefix("\($0)\(group)_\(slot)_")
            }) {
                archivedSlot = entry
            } else if name.hasPrefix("group_cleared_\(group)_") || name.hasPrefix("deleted_\(group)_") {
                archivedSlot = entry.appendingPathComponent(String(slot))
            } else { continue }
            let metadata: [SlotContent.SlotAttachment]
            if body {
                guard let raw = try? Data(contentsOf: archivedSlot.appendingPathComponent("content.json")),
                      let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      let managed = json["managedBodyFiles"],
                      let bytes = try? JSONSerialization.data(withJSONObject: managed),
                      let files = try? JSONDecoder().decode([String: SlotContent.SlotAttachment].self, from: bytes)
                else { continue }
                metadata = Array(files.values)
            } else {
                metadata = (try? JSONDecoder().decode([SlotContent.SlotAttachment].self,
                    from: Data(contentsOf: archivedSlot.appendingPathComponent("attachments.json")))) ?? []
            }
            guard metadata.contains(where: {
                $0.id == file.id && $0.name == file.name && $0.type == file.type && $0.createdAt == file.createdAt
            }) else { continue }
            let candidate = archivedSlot.appendingPathComponent(relative)
            if fm.fileExists(atPath: candidate.path) { candidates.append(candidate) }
        }
        guard let first = candidates.first else { return nil }
        let expected = try Self.fingerprint(first)
        for candidate in candidates.dropFirst() {
            let actual = try Self.fingerprint(candidate)
            guard actual.0 == expected.0, actual.1 == expected.1 else {
                throw AgentOperationError("旧历史存在多个不同版本的附件，无法确定原图，已保留现状。")
            }
        }
        return first
    }

    /// Caller holds StorageLock and serializes pending slot writes before capture.
    /// Pending manifests are pinned until the owning history is durably saved.
    public func seal(_ input: SlotUndoSnapshot, storageRoot: URL,
                     recoverLegacy: Bool = false) throws -> SlotUndoSnapshot {
        lock.lock(); defer { lock.unlock() }
        if input.mediaArchiveID != nil { return try preparedForRestore(input) }
        var output = input
        let id = UUID().uuidString
        var records: [Record] = []
        let existingBlobs = Set(((try? fm.contentsOfDirectory(atPath: blobs.path)) ?? []))
        do {
            for slot in output.slots.keys.sorted() {
                guard var content = output.slots[slot] else { continue }
                func archive(_ file: SlotContent.SlotAttachment, key: String, body: Bool) throws -> SlotContent.SlotAttachment {
                    guard Self.needsBytes(file) else { return file }
                    let sourceURL = try source(for: file, slot: slot, group: input.groupId,
                        storageRoot: storageRoot, recoverLegacy: recoverLegacy, body: body)
                    let (digest, count) = try put(data: file.data, source: sourceURL)
                    records.append(Record(slot: slot, key: key, id: file.id.uuidString, digest: digest, bytes: count))
                    var sealed = file
                    sealed.data = nil
                    sealed.storagePath = try blobURL(digest).path
                    return sealed
                }
                content.attachments = try content.attachments.map {
                    try archive($0, key: "attachment:\($0.id.uuidString)", body: false)
                }
                if let managed = content.managedBodyFiles {
                    content.managedBodyFiles = try Dictionary(uniqueKeysWithValues: managed.map {
                        ($0.key, try archive($0.value, key: "body:\($0.key)", body: true))
                    })
                }
                if let thumbnailID = content.manualThumbnailId {
                    guard UUID(uuidString: thumbnailID) != nil else { throw AgentCanvasError.conflict }
                    let url = storageRoot.appendingPathComponent(input.groupId)
                        .appendingPathComponent("\(slot)/attachments/\(thumbnailID).bin")
                    let (digest, count) = try put(data: content.pendingManualThumbnailData, source: url)
                    records.append(Record(slot: slot, key: "thumbnail", id: thumbnailID, digest: digest, bytes: count))
                    content.pendingManualThumbnailData = nil
                }
                output.slots[slot] = content
            }
            output.mediaArchiveID = id
            try fm.createDirectory(at: manifests, withIntermediateDirectories: true)
            try JSONEncoder().encode(Manifest(id: id, groupID: input.groupId,
                signature: output.identitySignature, records: records))
                .write(to: manifestURL(id), options: .atomic)
            pending.insert(id)
            return output
        } catch {
            try? fm.removeItem(at: manifestURL(id))
            // Only this failed capture's newly created files may be removed.
            // Never infer ownership from a partial history reference set.
            for digest in Set(records.map(\.digest)) where !existingBlobs.contains(digest + ".bin") {
                if let url = try? blobURL(digest) { try? fm.removeItem(at: url) }
            }
            throw error
        }
    }

    public func preparedForRestore(_ snapshot: SlotUndoSnapshot) throws -> SlotUndoSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard let id = snapshot.mediaArchiveID else {
            throw AgentOperationError("该历史尚未完成素材校验。")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL(id)))
        guard manifest.id == id, manifest.groupID == snapshot.groupId,
              manifest.signature == snapshot.identitySignature else { throw AgentCanvasError.conflict }
        var output = snapshot
        var consumed = Set<Int>()
        func media(_ slot: Int, _ key: String, _ id: String) throws -> URL {
            guard let index = manifest.records.firstIndex(where: { $0.slot == slot && $0.key == key && $0.id == id }),
                  consumed.insert(index).inserted else { throw AgentCanvasError.conflict }
            let record = manifest.records[index]
            let url = try blobURL(record.digest)
            let actual = try Self.fingerprint(url)
            guard actual.0 == record.digest, actual.1 == record.bytes else {
                throw AgentOperationError("历史附件不完整或校验失败，撤销未执行，当前内容与历史记录均已保留。")
            }
            return url
        }
        for slot in output.slots.keys {
            guard var content = output.slots[slot] else { continue }
            for i in content.attachments.indices where Self.needsBytes(content.attachments[i]) {
                let file = content.attachments[i]
                content.attachments[i].storagePath = try media(slot, "attachment:\(file.id.uuidString)", file.id.uuidString).path
                content.attachments[i].data = nil
            }
            if var managed = content.managedBodyFiles {
                for (key, file) in managed {
                    managed[key]?.storagePath = try media(slot, "body:\(key)", file.id.uuidString).path
                    managed[key]?.data = nil
                }
                content.managedBodyFiles = managed
            }
            if let thumbnailID = content.manualThumbnailId {
                content.pendingManualThumbnailData = try Data(contentsOf: media(slot, "thumbnail", thumbnailID),
                                                             options: .mappedIfSafe)
            }
            output.slots[slot] = content
        }
        guard consumed.count == manifest.records.count else { throw AgentCanvasError.conflict }
        return output
    }

    /// Validate staged, cold-readable bytes before the transaction exposes them.
    public func validateRestored(_ actual: SlotContent, expected: SlotContent) throws {
        guard actual.attachments.map(\.id) == expected.attachments.map(\.id),
              actual.attachments.map(\.name) == expected.attachments.map(\.name),
              actual.attachments.map(\.type) == expected.attachments.map(\.type),
              actual.attachments.map(\.url) == expected.attachments.map(\.url),
              actual.manualThumbnailId == expected.manualThumbnailId,
              actual.htmlSource == expected.htmlSource,
              (expected.isEmpty && !expected.hasManualThumbnail || actual.contentId == expected.contentId),
              (actual.label ?? "") == (expected.label ?? "") else { throw AgentCanvasError.writeFailed }
        guard actual.items.count == expected.items.count,
              actual.managedBodyFiles?.count == expected.managedBodyFiles?.count else {
            throw AgentCanvasError.writeFailed
        }
        for (a, b) in zip(actual.items, expected.items) {
            guard a.count == b.count else { throw AgentCanvasError.writeFailed }
            for representation in b {
                guard let restored = a.first(where: { $0.type == representation.type }) else {
                    throw AgentCanvasError.writeFailed
                }
                if ["public.file-url", "public.url"].contains(representation.type),
                   let raw = String(data: representation.data, encoding: .utf8),
                   let originalFile = expected.managedBodyFiles?[raw] {
                    guard let target = String(data: restored.data, encoding: .utf8),
                          actual.managedBodyFiles?[target]?.id == originalFile.id else {
                        throw AgentCanvasError.writeFailed
                    }
                } else if restored.data != representation.data {
                    throw AgentCanvasError.writeFailed
                }
            }
        }
        func equalBytes(_ a: SlotContent.SlotAttachment, _ b: SlotContent.SlotAttachment) throws {
            guard Self.needsBytes(b) else { return }
            guard let left = a.storageFileURL, let right = b.storageFileURL else { throw AgentCanvasError.writeFailed }
            let lhs = try Self.fingerprint(left), rhs = try Self.fingerprint(right)
            guard lhs.0 == rhs.0, lhs.1 == rhs.1 else { throw AgentCanvasError.writeFailed }
        }
        for (a, b) in zip(actual.attachments, expected.attachments) { try equalBytes(a, b) }
        let actualBody = Array((actual.managedBodyFiles ?? [:]).values)
        for file in (expected.managedBodyFiles ?? [:]).values {
            guard let restored = actualBody.first(where: { $0.id == file.id }) else { throw AgentCanvasError.writeFailed }
            try equalBytes(restored, file)
        }
    }

    public func releasePending(_ id: String?) {
        lock.lock(); defer { lock.unlock() }
        if let id { pending.remove(id) }
    }

    /// Call only after BOTH history stacks have been successfully persisted.
    /// On startup the persisted stacks are the reference set. Do not prune on a
    /// failed write; an older durable history may still own the old media.
    public func prune(referencedIDs: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        let retained = referencedIDs.union(pending)
        var digests = Set<String>()
        let urls = (try? fm.contentsOfDirectory(at: manifests, includingPropertiesForKeys: nil)) ?? []
        // Decode every retained manifest before deleting anything.
        for url in urls where retained.contains(url.deletingPathExtension().lastPathComponent) {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
            digests.formUnion(manifest.records.map(\.digest))
        }
        for url in urls where !retained.contains(url.deletingPathExtension().lastPathComponent) {
            try fm.removeItem(at: url)
        }
        for url in (try? fm.contentsOfDirectory(at: blobs, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "bin" && !digests.contains(url.deletingPathExtension().lastPathComponent) {
            try fm.removeItem(at: url)
        }
    }
}
