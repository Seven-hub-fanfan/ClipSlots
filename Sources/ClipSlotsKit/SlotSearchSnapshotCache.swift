import Foundation
import CryptoKit
import SQLite3

/// Rebuildable search data only. Business files remain the source of truth.
/// Paths include nested text files: editing a body without touching content.json
/// must invalidate the snapshot, including a same-size write with restored mtime.
struct SlotSearchSnapshot: Codable {
    struct Metadata: Codable {
        let slotCount: Int
        private let legacyStamps: [Stamp]
        private let packedStamps: Data?
        let generation: String
        let relativePaths: Bool?

        enum CodingKeys: String, CodingKey { case slotCount, stamps, packedStamps, generation, relativePaths }

        init(slotCount: Int, stamps: [Stamp], generation: String, relativePaths: Bool?) {
            self.slotCount = slotCount
            self.legacyStamps = []
            self.packedStamps = Self.pack(stamps)
            self.generation = generation
            self.relativePaths = relativePaths
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            slotCount = try values.decode(Int.self, forKey: .slotCount)
            generation = try values.decode(String.self, forKey: .generation)
            relativePaths = try values.decodeIfPresent(Bool.self, forKey: .relativePaths)
            packedStamps = try values.decodeIfPresent(Data.self, forKey: .packedStamps)
            legacyStamps = packedStamps == nil ? try values.decode([Stamp].self, forKey: .stamps) : []
            if let packedStamps, !Self.visit(packedStamps, { _, _ in true }) {
                throw DecodingError.dataCorruptedError(forKey: .packedStamps, in: values,
                                                        debugDescription: "invalid search stamp cache")
            }
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(slotCount, forKey: .slotCount)
            try values.encode(generation, forKey: .generation)
            try values.encodeIfPresent(relativePaths, forKey: .relativePaths)
            if let packedStamps { try values.encode(packedStamps, forKey: .packedStamps) }
            else { try values.encode(legacyStamps, forKey: .stamps) }
        }
        var stamps: [Stamp] {
            guard let packedStamps else { return legacyStamps }
            var result: [Stamp] = []
            _ = Self.visit(packedStamps) { path, identity in
                result.append(.init(path: path, identity: identity)); return true
            }
            return result
        }
        var cacheCost: Int {
            if let packedStamps { return 256 + packedStamps.count }
            return legacyStamps.reduce(256) { $0 + $1.path.utf8.count + $1.identity.count * 8 + 96 }
        }
        private static func pack(_ stamps: [Stamp]) -> Data {
            var result = Data()
            for stamp in stamps {
                let path = Data(stamp.path.utf8)
                var length = UInt32(path.count).littleEndian
                withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
                result.append(path)
                result.append(UInt8(stamp.identity.count))
                for var value in stamp.identity.map({ $0.littleEndian }) {
                    withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
                }
            }
            return result
        }
        private static func visit(_ data: Data, _ body: (String, [Int64]) -> Bool) -> Bool {
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    guard buffer.count - offset >= 4 else { return false }
                    let length = Int(UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                    offset += 4
                    guard length <= buffer.count - offset, buffer.count - offset - length >= 1,
                          let path = String(bytes: buffer[offset..<(offset + length)], encoding: .utf8) else { return false }
                    offset += length
                    let count = Int(buffer[offset]); offset += 1
                    guard count == 1 || count == 8, count * 8 <= buffer.count - offset else { return false }
                    var identity: [Int64] = []
                    identity.reserveCapacity(count)
                    for _ in 0..<count {
                        identity.append(Int64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: Int64.self)))
                        offset += 8
                    }
                    guard body(path, identity) else { return false }
                }
                return true
            }
        }
        func isCurrent(groupPath: String, slotCount: Int, isCancelled: () -> Bool) -> Bool {
            guard self.slotCount == slotCount else { return false }
            let descriptor = open(groupPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK)
            defer { if descriptor >= 0 { close(descriptor) } }
            var roots: Set<Int> = []
            func matches(_ stored: String, _ identity: [Int64]) -> Bool {
                let path = relativePaths == true ? groupPath + "/" + stored : stored
                let prefix = groupPath + "/"
                guard path.hasPrefix(prefix) else { return false }
                let relative = path.dropFirst(prefix.count)
                if !relative.contains("/"), let slot = Int(relative) { roots.insert(slot) }
                return !isCancelled() && Stamp.read(String(relative), relativeTo: descriptor,
                                                     fallbackPath: path).identity == identity
            }
            let valid: Bool
            if let packedStamps {
                valid = Self.visit(packedStamps, matches)
            } else {
                valid = legacyStamps.allSatisfy { matches($0.path, $0.identity) }
            }
            if descriptor >= 0 {
                var opened = stat(), current = stat()
                guard fstat(descriptor, &opened) == 0, stat(groupPath, &current) == 0,
                      opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
                      opened.st_mode == current.st_mode else { return false }
            }
            return valid && slotCount > 0 && roots == Set(1...slotCount)
        }

        func compacted(groupPath: String) -> Metadata {
            if relativePaths == true {
                return packedStamps != nil ? self : Metadata(slotCount: slotCount, stamps: legacyStamps,
                    generation: generation, relativePaths: true)
            }
            let prefix = groupPath + "/"
            guard stamps.allSatisfy({ $0.path.hasPrefix(prefix) }) else { return self }
            return Metadata(slotCount: slotCount,
                stamps: stamps.map { Stamp(path: String($0.path.dropFirst(prefix.count)), identity: $0.identity) },
                generation: generation, relativePaths: true)
        }

        func absoluteStamps(groupPath: String) -> [Stamp] {
            relativePaths == true ? stamps.map { Stamp(path: groupPath + "/" + $0.path, identity: $0.identity) } : stamps
        }
    }
    struct Stamp: Codable, Equatable {
        let path: String
        let identity: [Int64]

        static func read(_ path: String) -> Stamp {
            var value = stat()
            guard stat(path, &value) == 0 else {
                // Distinguish absence from an unreadable/otherwise failed lookup.
                return Stamp(path: path, identity: [-Int64(errno)])
            }
            return Stamp(path: path, identity: [
                Int64(value.st_dev), Int64(value.st_ino), Int64(value.st_mode), value.st_size,
                Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
                Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)
            ])
        }

        static func read(_ relative: String, relativeTo descriptor: Int32, fallbackPath: String) -> Stamp {
            guard descriptor >= 0 else { return read(fallbackPath) }
            var value = stat()
            guard fstatat(descriptor, relative, &value, 0) == 0 else {
                return .init(path: fallbackPath, identity: [-Int64(errno)])
            }
            return .init(path: fallbackPath, identity: [
                Int64(value.st_dev), Int64(value.st_ino), Int64(value.st_mode), value.st_size,
                Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
                Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)
            ])
        }
    }

    let slotCount: Int
    let stamps: [Stamp]
    let slots: [Int: SlotContent]
    let generation: String?

    init(slotCount: Int, stamps: [Stamp], slots: [Int: SlotContent], generation: String? = nil) {
        self.slotCount = slotCount
        self.stamps = stamps
        self.slots = slots
        self.generation = generation
    }

    /// File events can prioritize work but cannot prove freshness. Reconcile all
    /// stamps and return the precise slot set, including newly created children
    /// whose previously stamped parent directory changed.
    func changedSlots(base: URL, slotCount: Int, prioritySlots: Set<Int> = [],
                      isCancelled: () -> Bool) -> Set<Int>? {
        guard slotCount > 0, !isCancelled() else { return nil }
        let all = Set(1...slotCount)
        guard self.slotCount == slotCount else { return all }
        var changed: Set<Int> = []
        let prefix = base.path + "/"
        let ordered = prioritySlots.isEmpty ? stamps : stamps.sorted { left, right in
            func priority(_ stamp: Stamp) -> Bool {
                guard stamp.path.hasPrefix(prefix),
                      let first = stamp.path.dropFirst(prefix.count).split(separator: "/").first,
                      let slot = Int(first) else { return false }
                return prioritySlots.contains(slot)
            }
            return priority(left) && !priority(right)
        }
        for stamp in ordered {
            guard !isCancelled() else { return nil }
            guard stamp.path.hasPrefix(prefix),
                  let first = stamp.path.dropFirst(prefix.count).split(separator: "/").first,
                  let slot = Int(first), all.contains(slot) else { return all }
            if Stamp.read(stamp.path) != stamp { changed.insert(slot) }
        }
        // Malformed/old cache metadata must not suppress unvisited slots.
        let roots = Set(stamps.filter { $0.path.hasPrefix(prefix) }
            .compactMap { stamp -> Int? in
                let path = stamp.path.dropFirst(prefix.count)
                return path.contains("/") ? nil : Int(path)
            })
        guard roots == all else { return all }
        return changed
    }

    func isCurrent(slotCount: Int, isCancelled: () -> Bool) -> Bool {
        guard self.slotCount == slotCount else { return false }
        for stamp in stamps {
            if isCancelled() || Stamp.read(stamp.path) != stamp { return false }
        }
        return true
    }

    /// Enumerate only structural directories. Attachment payloads are immutable
    /// and don't contribute bytes to search; attachments.json supplies their names.
    static func inputs(base: URL, slotCount: Int, slots: Set<Int>? = nil,
                       isCancelled: () -> Bool = { false }) -> [Stamp]? {
        var paths: [String] = []
        if slotCount > 0 {
            for slot in 1...slotCount where slots == nil || slots?.contains(slot) == true {
                guard !isCancelled() else { return nil }
                let directory = base.appendingPathComponent(String(slot)).path
                paths.append(contentsOf: [directory, directory + "/content.json",
                    directory + "/label.txt", directory + "/attachments.json"])
                let identity = Stamp.read(directory).identity
                if identity.count == 1 && identity[0] == -Int64(ENOENT) { continue }
                guard identity.count > 2, identity[2] & Int64(S_IFMT) == Int64(S_IFDIR),
                      let names = SlotSearchFileIO.names(directory, isCancelled: isCancelled) else { return nil }
                for item in names where item.hasPrefix("item_") {
                    guard !isCancelled() else { return nil }
                    let itemPath = directory + "/" + item
                    paths.append(itemPath)
                    guard let files = SlotSearchFileIO.names(itemPath, isCancelled: isCancelled) else { return nil }
                    for file in files where file.hasSuffix(".bin") {
                        paths.append(itemPath + "/" + file)
                    }
                }
            }
        }
        guard !isCancelled() else { return nil }
        return paths.sorted().map(Stamp.read)
    }
}

/// A single bounded SQLite page cache avoids one cache-file open per slot/group.
/// Independent processes coordinate through SQLite; no DB mutex is held while
/// acquiring StorageLock. Corruption/unavailable cache always falls back to files.
final class SlotSearchSnapshotCache {
    static let shared = SlotSearchSnapshotCache()
    private let lock = NSLock()
    private var databases: [String: OpaquePointer] = [:]
    private var databaseOrder: [String] = []
    private var libraryAliases: [String: (identity: [Int64], resolved: String)] = [:]
    private let encoder: PropertyListEncoder = {
        let value = PropertyListEncoder()
        value.outputFormat = .binary
        return value
    }()
    private let decoder = PropertyListDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private final class CachedMetadata: NSObject {
        let value: SlotSearchSnapshot.Metadata
        init(_ value: SlotSearchSnapshot.Metadata) { self.value = value }
    }
    private final class CachedContent: NSObject {
        let value: SlotContent
        init(_ value: SlotContent) { self.value = value }
    }
    // Separate cost limits: compact file stamps and recently decoded hits. A
    // library scan never permanently retains every group's storage/content.
    private let metadataCache = ResourceCache<CachedMetadata>(category: .searchMetadata)
    private let contentCache = ResourceCache<CachedContent>(category: .searchContent, countLimit: 75000)

    deinit { for database in databases.values { sqlite3_close(database) } }

    private func database(for group: URL) -> OpaquePointer? {
        // Parent identifies the library, including private and isolated libraries.
        // Resolving every path component for every group made an unchanged hot
        // query perform thousands of redundant filesystem lookups. Cache only
        // the bounded library alias, rechecking root identity on every use.
        let parentURL = group.deletingLastPathComponent()
        let parentPath = parentURL.path
        let identity = Array(SlotSearchSnapshot.Stamp.read(parentPath).identity.prefix(3))
        let library: String
        if identity.count == 3, let cached = libraryAliases[parentPath], cached.identity == identity {
            library = cached.resolved
        } else {
            library = parentURL.resolvingSymlinksInPath().path
            if identity.count == 3 {
                if libraryAliases.count >= 16 { libraryAliases.removeAll(keepingCapacity: true) }
                libraryAliases[parentPath] = (identity, library)
            }
        }
        if let database = databases[library] {
            databaseOrder.removeAll { $0 == library }
            databaseOrder.append(library)
            return database
        }
        let hash = SHA256.hash(data: Data(library.utf8)).map { String(format: "%02x", $0) }.joined()
        let parent: URL
        if let override = ProcessInfo.processInfo.environment["CLIPSLOTS_SEARCH_CACHE_DIR"],
           !override.isEmpty {
            parent = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            parent = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("com.clipslots/search-v1", isDirectory: true)
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("clipslots-search-v1")
        }
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        var handle: OpaquePointer?
        let path = parent.appendingPathComponent(hash + ".sqlite").path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 40)
        let schema = """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            PRAGMA cache_size=-4096;
            CREATE TABLE IF NOT EXISTS search_groups (
                path TEXT PRIMARY KEY, generation TEXT NOT NULL, value BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS search_slots (
                path TEXT NOT NULL, slot INTEGER NOT NULL, haystack TEXT NOT NULL,
                value BLOB NOT NULL, PRIMARY KEY(path, slot)) WITHOUT ROWID;
            CREATE TRIGGER IF NOT EXISTS search_slot_insert_invalidates AFTER INSERT ON search_slots
              BEGIN DELETE FROM search_groups WHERE path=new.path; END;
            CREATE TRIGGER IF NOT EXISTS search_slot_update_invalidates AFTER UPDATE ON search_slots
              BEGIN DELETE FROM search_groups WHERE path=old.path OR path=new.path; END;
            CREATE TRIGGER IF NOT EXISTS search_slot_delete_invalidates AFTER DELETE ON search_slots
              BEGIN DELETE FROM search_groups WHERE path=old.path; END;
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        chmod(path, 0o600)
        if databaseOrder.count >= 8 {
            let oldest = databaseOrder.removeFirst()
            if let expired = databases.removeValue(forKey: oldest) { sqlite3_close(expired) }
        }
        databases[library] = handle
        databaseOrder.append(library)
        return handle
    }

    private func metadata(database: OpaquePointer, path: String) -> SlotSearchSnapshot.Metadata? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT generation,value FROM search_groups WHERE path=?",
                                 -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let generationText = sqlite3_column_text(statement, 0) else { return nil }
        let generation = String(cString: generationText)
        if let cached = metadataCache.object(forKey: path as NSString),
           cached.value.generation == generation { return cached.value }
        #if DEBUG
        let decodeStart = SlotSearchDiagnostics.now
        defer { SlotSearchDiagnostics.record("metadataDecodeMS", since: decodeStart) }
        #endif
        guard let pointer = sqlite3_column_blob(statement, 1) else { return nil }
        let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 1)))
        guard let decoded = try? decoder.decode(SlotSearchSnapshot.Metadata.self, from: data),
              decoded.generation == generation else { return nil }
        let value = decoded.compacted(groupPath: path)
        metadataCache.setObject(CachedMetadata(value), forKey: path as NSString,
                                cost: metadataCost(value))
        return value
    }

    private func metadataCost(_ value: SlotSearchSnapshot.Metadata) -> Int {
        value.cacheCost
    }

    private func decodeContent(_ data: Data) -> SlotContent? {
        // Hash the actual row bytes, not merely a persisted identity/generation:
        // raw cache corruption or a same-ID external rewrite cannot reuse a hit.
        let key = Data(SHA256.hash(data: data)) as NSData
        if let cached = contentCache.object(forKey: key) { return cached.value }
        guard let value = try? decoder.decode(SlotContent.self, from: data) else { return nil }
        contentCache.setObject(CachedContent(value), forKey: key, cost: value.memoryCacheCost)
        return value
    }

    private func rows(database: OpaquePointer, path: String, query: String,
                      isCancelled: () -> Bool) -> [Int: SlotContent]? {
        // instr is a conservative candidate filter. NFC preserves Swift's
        // canonical-equivalence matching. The authoritative Swift matcher still
        // runs afterwards, including grapheme boundaries and media filters.
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().precomposedStringWithCanonicalMapping
        var statement: OpaquePointer?
        let sql = needle.isEmpty
            ? "SELECT slot,value FROM search_slots WHERE path=?"
            : "SELECT slot,value FROM search_slots WHERE path=? AND instr(haystack,?)>0"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, transient)
        if !needle.isEmpty { sqlite3_bind_text(statement, 2, needle, Int32(needle.utf8.count), transient) }
        var slots: [Int: SlotContent] = [:]
        while !isCancelled() {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return slots }
            guard status == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 1) else { return nil }
            let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 1)))
            guard let content = decodeContent(data) else { return nil }
            slots[Int(sqlite3_column_int(statement, 0))] = content
        }
        return nil
    }

    func load(group: URL, isCancelled: () -> Bool = { false }) -> SlotSearchSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard !isCancelled(), let database = database(for: group),
              sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        guard let value = metadata(database: database, path: group.path),
              let slots = rows(database: database, path: group.path, query: "", isCancelled: isCancelled)
            else { return nil }
        return SlotSearchSnapshot(slotCount: value.slotCount,
                                  stamps: value.absoluteStamps(groupPath: group.path), slots: slots,
                                  generation: value.generation)
    }

    func query(group: URL, slotCount: Int, query: String,
               isCancelled: () -> Bool) -> [Int: SlotContent]? {
        // One SQLite read transaction keeps stamps and payloads from different
        // processes consistent; never acquires StorageLock while holding this.
        lock.lock(); defer { lock.unlock() }
        guard !isCancelled(), let database = database(for: group),
              sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        guard let value = metadata(database: database, path: group.path) else { return nil }
        #if DEBUG
        let validationStart = SlotSearchDiagnostics.now
        #endif
        guard value.isCurrent(groupPath: group.path, slotCount: slotCount, isCancelled: isCancelled) else { return nil }
        #if DEBUG
        SlotSearchDiagnostics.record("stampValidationMS", since: validationStart)
        #endif
        return rows(database: database, path: group.path, query: query, isCancelled: isCancelled)
    }

    @discardableResult
    func save(_ snapshot: SlotSearchSnapshot, group: URL, changedSlots: Set<Int>? = nil,
              isCancelled: () -> Bool = { false }) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isCancelled() else { return false }
        let value = SlotSearchSnapshot.Metadata(slotCount: snapshot.slotCount,
                                                stamps: snapshot.stamps, generation: UUID().uuidString,
                                                relativePaths: false).compacted(groupPath: group.path)
        guard let data = try? encoder.encode(value), let database = database(for: group),
              sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        var committed = false
        defer { if !committed { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) } }
        if changedSlots != nil {
            guard let expected = snapshot.generation,
                  metadata(database: database, path: group.path)?.generation == expected else { return false }
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO search_groups(path,generation,value) VALUES(?,?,?)",
                                -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, group.path, -1, transient)
        sqlite3_bind_text(statement, 2, value.generation, -1, transient)
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient)
        }
        var deletion: OpaquePointer?
        let deleteSQL = changedSlots == nil ? "DELETE FROM search_slots WHERE path=?"
            : "DELETE FROM search_slots WHERE path=? AND slot=?"
        guard sqlite3_prepare_v2(database, deleteSQL,
                                -1, &deletion, nil) == SQLITE_OK, let deletion else { return false }
        defer { sqlite3_finalize(deletion) }
        sqlite3_bind_text(deletion, 1, group.path, -1, transient)
        if let changedSlots {
            for slot in changedSlots {
                guard !isCancelled() else { return false }
                sqlite3_reset(deletion)
                sqlite3_bind_int(deletion, 2, Int32(slot))
                guard sqlite3_step(deletion) == SQLITE_DONE else { return false }
            }
        } else if sqlite3_step(deletion) != SQLITE_DONE { return false }
        var insertion: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO search_slots(path,slot,haystack,value) VALUES(?,?,?,?)",
                                -1, &insertion, nil) == SQLITE_OK, let insertion else { return false }
        defer { sqlite3_finalize(insertion) }
        for (slot, content) in snapshot.slots where changedSlots == nil || changedSlots?.contains(slot) == true {
            guard !isCancelled() else { return false }
            guard let payload = try? encoder.encode(content) else { return false }
            let haystack = SlotSearchIndex.slotHaystack(slot: slot, content: content, label: content.label ?? "")
                .precomposedStringWithCanonicalMapping
            sqlite3_reset(insertion)
            sqlite3_bind_text(insertion, 1, group.path, -1, transient)
            sqlite3_bind_int(insertion, 2, Int32(slot))
            sqlite3_bind_text(insertion, 3, haystack, Int32(haystack.utf8.count), transient)
            _ = payload.withUnsafeBytes {
                sqlite3_bind_blob(insertion, 4, $0.baseAddress, Int32(payload.count), transient)
            }
            guard sqlite3_step(insertion) == SQLITE_DONE else { return false }
            contentCache.setObject(CachedContent(content), forKey: Data(SHA256.hash(data: payload)) as NSData,
                                   cost: content.memoryCacheCost)
        }
        // Slot-row changes invalidate their group header even from a separate
        // process. Publish the new header last, in this same transaction, so an
        // altered haystack cannot silently hide its payload on the next search.
        guard !isCancelled(), sqlite3_step(statement) == SQLITE_DONE else { return false }
        committed = sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK
        if committed {
            metadataCache.setObject(CachedMetadata(value), forKey: group.path as NSString, cost: metadataCost(value))
        }
        return committed
    }
}
