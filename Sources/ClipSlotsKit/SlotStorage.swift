import Foundation

struct SlotManifest: Codable {
    struct Entry: Codable {
        let description: String
        let itemCount: Int
        let slot: Int
        let totalBytes: Int
        let types: [String]
        let updatedAt: String
    }

    var entries: [Entry] = []
    var version: Int = 1
}

public final class SlotStorage {
    public static let shared = SlotStorage()

    private let baseURL: URL
    private var cache: [Int: SlotContent] = [:]
    private let queue = DispatchQueue(label: "com.clipslots.storage", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(slotsDir: URL? = nil) {
        if let slotsDir {
            baseURL = slotsDir
        } else {
            baseURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/clipslots/slots")
        }
        do {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        } catch {
            NSLog("[ClipSlots] SlotStorage init: failed to create base dir \(baseURL.path): \(error)")
        }
    }

    // MARK: - Slot Content

    public func get(_ slot: Int) -> SlotContent {
        queue.sync {
            if let cached = cache[slot] { return cached }

            let slotDir = baseURL.appendingPathComponent(String(slot))
            let content = readSlotContent(from: slotDir)
            cache[slot] = content
            return content
        }
    }

    @discardableResult
    public func set(_ slot: Int, content: SlotContent) -> Bool {
        // v2.9.4 (#4): wrap the whole write in the cross-process lock so a CLI and
        // the GUI cannot clobber each other. flock is acquired OUTSIDE `queue`
        // (StorageLock uses its own NSRecursiveLock), never dispatched onto the
        // serial `queue`, so no queue.sync self-deadlock is possible. A lock
        // timeout degrades to a failed write (returns false) rather than a hang.
        return (try? StorageLock.shared.withLock {
            let ok: Bool = queue.sync {
                do {
                    try writeSlotContent(content, to: slot)
                    cache[slot] = content
                    NSLog("[ClipSlots] SlotStorage.set OK slot=\(slot) preview=\(content.preview)")
                    return true
                } catch {
                    NSLog("[ClipSlots] SlotStorage.set FAIL slot=\(slot) error=\(error)")
                    return false
                }
            }
            // v2.8.0 (perf H2): manifest.json is a write-only diagnostic file (never
            // read back for correctness — `readManifest()` has no callers). Regenerating
            // it walks all 10 slot directories off disk, which previously ran inside the
            // synchronous save path and blocked the caller (usually the main thread) on
            // every save. Move it to the serial background queue so `set` returns as soon
            // as the slot itself is persisted and the in-memory cache is updated.
            if ok { scheduleManifestUpdate() }
            return ok
        }) ?? false
    }

    public func clear(_ slot: Int) {
        // v2.9.4 (#4): cross-process lock around the delete write.
        try? StorageLock.shared.withLock {
            queue.sync {
                cache[slot] = SlotContent()
                let slotDir = baseURL.appendingPathComponent(String(slot))
                do {
                    try FileManager.default.removeItem(at: slotDir)
                } catch {
                    let nsErr = error as NSError
                    if nsErr.domain == NSCocoaErrorDomain && nsErr.code == 4 { /* file not found */ }
                    else { NSLog("[ClipSlots] SlotStorage.clear FAIL slot=\(slot): \(error)") }
                }
            }
            scheduleManifestUpdate()
        }
    }

    public func clearAll() {
        // v2.9.4 (#4): cross-process lock around the wipe-and-recreate.
        try? StorageLock.shared.withLock {
            queue.sync {
                cache.removeAll()
                do {
                    try FileManager.default.removeItem(at: baseURL)
                    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
                    NSLog("[ClipSlots] SlotStorage.clearAll OK")
                } catch {
                    NSLog("[ClipSlots] SlotStorage.clearAll FAIL: \(error)")
                }
            }
            scheduleManifestUpdate()
        }
    }

    /// v2.8.0 (perf H2): regenerate the diagnostic manifest asynchronously on the
    /// serial storage queue so it never blocks the save/clear critical path.
    private func scheduleManifestUpdate() {
        queue.async { [weak self] in
            do {
                try self?.updateManifest()
            } catch {
                NSLog("[ClipSlots] SlotStorage manifest update FAIL: \(error)")
            }
        }
    }

    public func snapshot() -> [Int: SlotContent] {
        queue.sync { cache }
    }

    /// v2.9.15 (fix): drop the in-memory SlotContent cache so the next `get(_:)`
    /// re-reads from disk. `get(_:)` serves cached SlotContent and never notices a
    /// change made by ANOTHER process (the `clipslots` CLI). Labels bypass this
    /// cache (getLabel reads label.txt directly every call), which is exactly why a
    /// CLI `write` used to surface the new label while the body still showed the
    /// stale "空槽位 0 B". The GUI's FSEvents watcher now calls this before reloading
    /// so external writes are reflected. (The body was always correctly persisted to
    /// disk — this was a read-cache staleness bug, not a write bug.)
    public func invalidateCache() {
        queue.sync { cache.removeAll() }
    }

    // MARK: - Label

    public func getLabel(_ slot: Int) -> String? {
        let labelFile = baseURL.appendingPathComponent(String(slot)).appendingPathComponent("label.txt")
        guard let content = try? String(contentsOf: labelFile, encoding: .utf8) else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func setLabel(_ slot: Int, label: String?) {
        // v2.9.4 (#4): cross-process lock around the label write.
        try? StorageLock.shared.withLock {
            queue.sync {
                let slotDir = baseURL.appendingPathComponent(String(slot))
                do {
                    try FileManager.default.createDirectory(at: slotDir, withIntermediateDirectories: true)
                } catch {
                    NSLog("[ClipSlots] setLabel: create dir FAIL slot=\(slot): \(error)")
                    return
                }
                let labelFile = slotDir.appendingPathComponent("label.txt")
                if let label = label, !label.isEmpty {
                    do {
                        try label.write(to: labelFile, atomically: true, encoding: .utf8)
                    } catch {
                        NSLog("[ClipSlots] setLabel: write FAIL slot=\(slot): \(error)")
                    }
                } else {
                    do { try FileManager.default.removeItem(at: labelFile) } catch {
                        let nsErr = error as NSError
                        if !(nsErr.domain == NSCocoaErrorDomain && nsErr.code == 4) {
                            NSLog("[ClipSlots] setLabel: remove FAIL: \(error)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Content Metadata (persisted alongside item data)

    private struct SlotContentMeta: Codable {
        let contentId: String
        let updatedAt: TimeInterval
    }

    // MARK: - Internal Read/Write

    private func readSlotContent(from slotDir: URL) -> SlotContent {
        var content = SlotContent()

        var isSlotDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: slotDir.path, isDirectory: &isSlotDir), isSlotDir.boolValue else {
            return content
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: slotDir.path),
           let modDate = attrs[.modificationDate] as? Date {
            content.timestamp = modDate
        }

        // Enumerate all item_N directories, sorted
        let itemDirs: [URL]
        do {
            itemDirs = try FileManager.default.contentsOfDirectory(at: slotDir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("item_") }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            NSLog("[ClipSlots] readSlotContent list FAIL slotDir=\(slotDir.path): \(error)")
            return content
        }

        var groups: [[PasteboardItem]] = []

        for itemDir in itemDirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: itemDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(at: itemDir, includingPropertiesForKeys: nil)
            } catch {
                NSLog("[ClipSlots] readSlotContent read itemDir FAIL \(itemDir.path): \(error)")
                continue
            }

            var items: [PasteboardItem] = []
            for file in files where file.pathExtension == "bin" {
                let encodedType = file.deletingPathExtension().lastPathComponent
                let typeName = decodeSafeFileName(encodedType)
                do {
                    let data = try Data(contentsOf: file)
                    items.append(PasteboardItem(type: typeName, data: data))
                } catch {
                    NSLog("[ClipSlots] readSlotContent read file FAIL type=\(typeName): \(error)")
                }
            }

            if !items.isEmpty {
                groups.append(items)
            }
        }

        content.items = groups

        // Restore content identity from metadata file (v2.3.6+).
        // Slots saved before v2.3.6 won't have this file — we generate new IDs
        // so the first thumbnail load after upgrade is a one-time cache miss.
        let metaURL = slotDir.appendingPathComponent("content.json")
        if let metaData = try? Data(contentsOf: metaURL),
           let meta = try? decoder.decode(SlotContentMeta.self, from: metaData) {
            content.contentId = meta.contentId
            content.updatedAt = meta.updatedAt
        } else {
            // Legacy slot: generate stable-ish IDs so restarts don't thrash.
            content.contentId = UUID().uuidString
            content.updatedAt = content.timestamp.timeIntervalSince1970
        }

        // v2.8.3 (fix): restore slot attachments persisted alongside item data.
        // Prior to v2.8.3 attachments lived only in SlotStorage's in-memory cache
        // and were never serialized, so they vanished on the next app launch
        // (cold cache → disk read reconstructed SlotContent without attachments).
        // Missing/legacy file → keep the default empty array (fully backward compatible).
        let attachmentsURL = slotDir.appendingPathComponent("attachments.json")
        if let attData = try? Data(contentsOf: attachmentsURL),
           let atts = try? decoder.decode([SlotContent.SlotAttachment].self, from: attData) {
            content.attachments = atts
        }

        return content
    }

    private func writeSlotContent(_ content: SlotContent, to slot: Int) throws {
        let slotDir = baseURL.appendingPathComponent(String(slot))

        // Preserve label before wiping
        let existingLabel = getLabel(slot)

        // Remove entire slot directory to avoid stale residues
        if FileManager.default.fileExists(atPath: slotDir.path) {
            try FileManager.default.removeItem(at: slotDir)
        }
        try FileManager.default.createDirectory(at: slotDir, withIntermediateDirectories: true)

        // Restore label
        if let label = existingLabel, !label.isEmpty {
            try label.write(to: slotDir.appendingPathComponent("label.txt"), atomically: true, encoding: .utf8)
        }

        // v2.8.3 (fix): a slot may carry attachments even when its main content is
        // empty (attachments are added independently in the node canvas). Persist
        // if EITHER items or attachments exist so attachments are never dropped.
        guard !content.isEmpty || !content.attachments.isEmpty else { return }

        for (groupIdx, items) in content.items.enumerated() {
            let targetDir = slotDir.appendingPathComponent("item_\(groupIdx)")
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

            for item in items {
                let safeName = encodeSafeFileName(item.type) + ".bin"
                let typeFile = targetDir.appendingPathComponent(safeName)
                try item.data.write(to: typeFile, options: .atomic)
            }
        }

        // Persist content identity so thumbnail keys survive app restarts.
        let meta = SlotContentMeta(contentId: content.contentId, updatedAt: content.updatedAt)
        let metaData = try encoder.encode(meta)
        try metaData.write(to: slotDir.appendingPathComponent("content.json"), options: .atomic)

        // v2.8.3 (fix): persist slot attachments alongside item data so they
        // survive app restarts. The whole slot dir was wiped above, so when the
        // attachment list is empty we simply skip writing the file (a fresh read
        // will fall back to the default empty array).
        if !content.attachments.isEmpty {
            let attData = try encoder.encode(content.attachments)
            try attData.write(to: slotDir.appendingPathComponent("attachments.json"), options: .atomic)
        }
    }

    // MARK: - Safe Filename Encoding

    private let slashPlaceholder = "$slash$"

    private func encodeSafeFileName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: slashPlaceholder)
    }

    private func decodeSafeFileName(_ encoded: String) -> String {
        encoded.replacingOccurrences(of: slashPlaceholder, with: "/")
    }

    // MARK: - Manifest

    private func manifestURL() -> URL {
        baseURL.appendingPathComponent("manifest.json")
    }

    private func readManifest() throws -> SlotManifest {
        let data = try Data(contentsOf: manifestURL())
        return try decoder.decode(SlotManifest.self, from: data)
    }

    private func updateManifest() throws {
        var entries: [SlotManifest.Entry] = []

        for slot in 1...10 {
            let slotDir = baseURL.appendingPathComponent(String(slot))

            var isSlotDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: slotDir.path, isDirectory: &isSlotDir), isSlotDir.boolValue else {
                continue
            }

            // Find the first item_N directory
            let itemDirs = try FileManager.default.contentsOfDirectory(at: slotDir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("item_") }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            guard !itemDirs.isEmpty, let firstItemDir = itemDirs.first else { continue }

            var types: [String] = []
            var totalBytes = 0
            var preview = "(empty)"
            let itemCount = itemDirs.count

            // Read all item dirs for types and totals
            for itemDir in itemDirs {
                let files = try FileManager.default.contentsOfDirectory(at: itemDir, includingPropertiesForKeys: [.fileSizeKey])
                for file in files where file.pathExtension == "bin" {
                    let encodedType = file.deletingPathExtension().lastPathComponent
                    let typeName = decodeSafeFileName(encodedType)
                    types.append(typeName)

                    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                    if let size = attrs[.size] as? Int { totalBytes += size }

                    // Preview from the first item dir only
                    if itemDir == firstItemDir {
                        if typeName == "public.utf8-plain-text" || typeName == "NSStringPboardType" {
                            if let data = try? Data(contentsOf: file),
                               let str = String(data: data, encoding: .utf8) {
                                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                                preview = String(trimmed.prefix(37))
                            }
                        } else if typeName == "public.rtf" {
                            preview = "[Rich Text]"
                        } else if typeName.contains("image") {
                            preview = "[Image \(totalBytes / 1024)KB]"
                        } else if typeName == "public.file-url" {
                            if let data = try? Data(contentsOf: file),
                               let urlStr = String(data: data, encoding: .utf8),
                               let url = URL(string: urlStr) {
                                preview = "[File] \(url.lastPathComponent)"
                            } else {
                                preview = "[File]"
                            }
                        }
                    }
                }
            }

            if let label = getLabel(slot), !label.isEmpty {
                preview = "[\(label)] \(preview)"
            }

            if preview.hasPrefix("[Rich Text]"),
               let richTextFile = firstItemDir.appendingPathComponent(encodeSafeFileName("public.utf8-plain-text") + ".bin") as URL?,
               FileManager.default.fileExists(atPath: richTextFile.path),
               let data = try? Data(contentsOf: richTextFile),
               let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let chars = trimmed.count
                let suffix = chars > 0 ? " \(chars) chars: \(String(trimmed.prefix(37)))" : ""
                preview = "[Rich Text]\(suffix)"
            }

            entries.append(SlotManifest.Entry(
                description: preview,
                itemCount: itemCount,
                slot: slot,
                totalBytes: totalBytes,
                types: types.sorted(),
                updatedAt: ISO8601DateFormatter().string(from: Date())
            ))
        }

        let manifest = SlotManifest(entries: entries, version: 1)
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(), options: .atomic)
    }
}
