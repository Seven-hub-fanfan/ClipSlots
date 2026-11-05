import Foundation
import UniformTypeIdentifiers
import Darwin

/// A source identity is captured at drag start. Only the dragged body/attachment
/// is compared on drop; concurrent additions, labels and ordering survive.
public struct SlotFileMove: Codable {
    public let groupID: String
    public let pageID: String
    public let groupCreatedAt: Date
    public let slot: Int
    public let body: SlotContent?
    public let attachment: SlotContent.SlotAttachment?
    public let attachmentBundle: [SlotContent.SlotAttachment]?
    public let fileVersions: [String: String]

    public init(snapshot: SlotEditorSnapshot, attachment: SlotContent.SlotAttachment? = nil,
                moveAllAttachments: Bool = false) {
        groupID = snapshot.group.id
        pageID = snapshot.group.pageId
        groupCreatedAt = snapshot.group.createdAt
        slot = snapshot.slot
        self.attachment = moveAllAttachments ? nil : attachment
        attachmentBundle = moveAllAttachments ? snapshot.content.attachments : nil
        if attachment == nil && !moveAllAttachments {
            var body = snapshot.content
            body.attachments = []
            body.manualThumbnailId = nil
            self.body = body
        } else { body = nil }
        let files = attachmentBundle ?? attachment.map { [$0] } ?? Self.files(in: snapshot.content)
        fileVersions = Dictionary(files.compactMap { file -> (String, String)? in
            guard let path = file.storagePath ?? file.localFileReferencePath else { return nil }
            return (path, Self.version(path, owned: file.storagePath != nil))
        }, uniquingKeysWith: { a, _ in a })
    }

    // Atomic slot rewrites clone immutable owned files to new inodes. Comparing
    // their inode would reject an otherwise unchanged attachment after adding
    // another item. External references keep the stricter original fingerprint.
    private static func version(_ path: String, owned: Bool) -> String {
        guard owned else { return GenerationRunContext.fileVersion(path) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "missing" }
        return "owned:\(attributes[.size] ?? 0)|\(attributes[.modificationDate] ?? "")"
    }

    static func isCurrent(path: String, expected: String) -> Bool {
        expected != "missing" && version(path, owned: expected.hasPrefix("owned:")) == expected
    }

    public static func files(in content: SlotContent) -> [SlotContent.SlotAttachment] {
        content.items.flatMap { representations -> [SlotContent.SlotAttachment] in
            if representations.contains(where: { $0.type == UTType.fileURL.identifier }) {
                return SlotContent(items: [representations]).detectedFileURLs.map { url in
                    if let owned = content.managedBodyFiles?[url.absoluteString] { return owned }
                    return .init(name: url.lastPathComponent,
                        type: SlotContent.imageFileExtensions.contains(url.pathExtension.lowercased()) ? .image : .file,
                        path: url.path)
                }
            }
            guard let image = representations.first(where: { $0.type == UTType.png.identifier && !$0.data.isEmpty })
                    ?? representations.first(where: { SlotContent.isImagePasteboardType($0.type) && !$0.data.isEmpty })
            else { return [] }
            let ext = UTType(image.type)?.preferredFilenameExtension ?? "png"
            return [.init(name: "粘贴图片.\(ext)", type: .image, data: image.data)]
        }
    }

    public static func isTextBody(_ content: SlotContent) -> Bool {
        guard !content.items.contains(where: { group in
            group.contains { $0.type == UTType.fileURL.identifier || SlotContent.isImagePasteboardType($0.type) }
        }) else { return false }
        return content.plainText?.isEmpty == false
    }

    /// Files remain files; a text body becomes one UTF-8 text attachment when
    /// dropped on an attachment button. Body-to-body moves preserve originals.
    public static func bodyAttachments(in content: SlotContent) -> [SlotContent.SlotAttachment] {
        let fileItems = files(in: content)
        if !fileItems.isEmpty { return fileItems }
        guard isTextBody(content), let text = content.plainText else { return [] }
        return [.init(name: String(text.prefix(30)), type: .text, data: Data(text.utf8))]
    }
}

public enum SlotFileMoveDestination: Equatable { case body, attachments }

/// Stages every changed slot before touching live directories. A small durable
/// journal permits rollback after a failed rename or interrupted process.
/// Destination is exchanged first, source second; no source byte is removed
/// until its destination is fully prepared. Old trees remain until commit.
enum SlotMoveDiskTransaction {
    private struct Entry: Codable {
        var live: URL
        var staged: URL
        var originalInode: UInt64?
        var preparedInode: UInt64
    }
    private struct Journal: Codable { var entries: [Entry]; var committed: Bool }
    static var root: URL { ClipSlotsPaths.dataRoot.appendingPathComponent(".slot-moves") }
    static var hasPending: Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty
    }
    private static let fm = FileManager.default
    private static func canonicalPath(_ url: URL) -> String {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        // Foundation leaves missing leaf paths unresolved on some macOS
        // versions. After a rename, the staged leaf can legitimately be absent.
        while !fm.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        let prefix = ancestor.resolvingSymlinksInPath().path
        return suffix.isEmpty ? prefix : prefix + "/" + suffix.joined(separator: "/")
    }
    private static func inode(_ url: URL) -> UInt64? {
        var value = stat()
        return lstat(url.path, &value) == 0 ? UInt64(value.st_ino) : nil
    }
    private static func swap(_ a: URL, _ b: URL) throws {
        let result = a.path.withCString { x in b.path.withCString { y in
            renameatx_np(AT_FDCWD, x, AT_FDCWD, y, UInt32(RENAME_SWAP))
        } }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    static func recover() throws {
        guard fm.fileExists(atPath: root.path) else { return }
        for directory in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let journalURL = directory.appendingPathComponent("journal.json")
            guard fm.fileExists(atPath: journalURL.path) else {
                // A pre-journal stage has never touched a live slot.
                try fm.removeItem(at: directory)
                continue
            }
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            let dataPath = canonicalPath(ClipSlotsPaths.dataRoot)
            let stagePath = canonicalPath(directory)
            guard journal.entries.allSatisfy({
                canonicalPath($0.live).hasPrefix(dataPath + "/")
                    && canonicalPath($0.staged).hasPrefix(stagePath + "/")
            }) else { throw AgentCanvasError.conflict }
            if !journal.committed {
                for entry in journal.entries.reversed() {
                    let liveInode = inode(entry.live)
                    if liveInode == entry.preparedInode {
                        if let original = entry.originalInode {
                            guard inode(entry.staged) == original else { throw AgentCanvasError.conflict }
                            try swap(entry.live, entry.staged)
                        } else {
                            guard inode(entry.staged) == nil else { throw AgentCanvasError.conflict }
                            try fm.moveItem(at: entry.live, to: entry.staged)
                        }
                    } else if liveInode != entry.originalInode { throw AgentCanvasError.conflict }
                }
            }
            try fm.removeItem(at: directory)
        }
    }
    static func commit(_ changes: [(live: URL, content: SlotContent)],
                       checkpoint: ((Int) throws -> Void)? = nil) throws {
        try recover()
        let directory = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let journalURL = directory.appendingPathComponent("journal.json")
        var journal = Journal(entries: [], committed: false)
        do {
            for (index, change) in changes.enumerated() {
                let stageRoot = directory.appendingPathComponent(String(index))
                let staged = stageRoot.appendingPathComponent("1")
                try fm.createDirectory(at: stageRoot, withIntermediateDirectories: true)
                let original = inode(change.live)
                if original != nil, !cloneOrCopyItem(at: change.live, to: staged) {
                    throw AgentCanvasError.writeFailed
                }
                let staging = SlotStorage(moveStagingDirectory: stageRoot)
                guard staging.set(1, content: change.content) else { throw AgentCanvasError.writeFailed }
                try SlotStorage.rebasePreparedSlot(staged, to: change.live)
                guard let prepared = inode(staged) else { throw AgentCanvasError.writeFailed }
                journal.entries.append(Entry(live: change.live, staged: staged,
                    originalInode: original, preparedInode: prepared))
            }
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            for (index, entry) in journal.entries.enumerated() {
                if entry.originalInode != nil { try swap(entry.live, entry.staged) }
                else { try fm.moveItem(at: entry.staged, to: entry.live) }
                try checkpoint?(index + 1)
            }
            journal.committed = true
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        } catch {
            if fm.fileExists(atPath: journalURL.path) { try recover() }
            else { try? fm.removeItem(at: directory) }
            throw error
        }
        // Cleanup is not part of the success decision; committed recovery can
        // repeat it safely, without reverting already accepted moves.
        try? fm.removeItem(at: directory)
    }
}
