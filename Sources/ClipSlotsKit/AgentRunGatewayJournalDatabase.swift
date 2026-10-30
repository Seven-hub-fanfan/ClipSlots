import Foundation
import Darwin
import SQLite3

/// Narrow SQLite wrapper for the authoritative journal. SQL values are bound;
/// the only interpolated numbers are local monotonically increasing revisions.
final class AgentGatewayJournalDatabase {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private(set) var payloadBytesWritten: UInt64 = 0

    init(file: URL, create: Bool) throws {
        let fd = open(file.path, O_RDWR | O_NOFOLLOW | (create ? O_CREAT | O_EXCL : 0), 0o600)
        guard fd >= 0 else { throw AgentGatewayError.journalUnavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size <= 512 * 1024 * 1024,
              sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }; handle = nil
            throw AgentGatewayError.journalUnavailable
        }
        do {
            guard fchmod(fd, 0o600) == 0 else { throw AgentGatewayError.journalUnavailable }
            sqlite3_busy_timeout(handle, 1_000)
            try execute("""
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=FULL;
                PRAGMA fullfsync=ON;
                PRAGMA checkpoint_fullfsync=ON;
                PRAGMA wal_autocheckpoint=1024;
                PRAGMA journal_size_limit=16777216;
                PRAGMA cache_size=-4096;
                PRAGMA mmap_size=0;
                """)
            if create {
                try execute("""
                    CREATE TABLE state(key TEXT PRIMARY KEY, payload BLOB NOT NULL);
                    CREATE TABLE events(id TEXT PRIMARY KEY, digest TEXT NOT NULL);
                    CREATE TABLE messages(position INTEGER PRIMARY KEY, payload BLOB NOT NULL);
                    CREATE TABLE chunks(position INTEGER NOT NULL, kind TEXT NOT NULL,
                        sequence INTEGER NOT NULL, body BLOB NOT NULL,
                        PRIMARY KEY(position, kind, sequence));
                    CREATE TABLE tools(id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                    CREATE TABLE archive(revision INTEGER NOT NULL, kind TEXT NOT NULL,
                        identity TEXT NOT NULL, payload BLOB NOT NULL,
                        PRIMARY KEY(revision, kind, identity));
                    PRAGMA user_version=2;
                    """)
            }
        } catch {
            if let handle { sqlite3_close(handle) }; handle = nil
            throw AgentGatewayError.journalUnavailable
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func close() throws {
        guard let handle else { return }
        guard sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK,
              sqlite3_close(handle) == SQLITE_OK else { throw AgentGatewayError.journalUnavailable }
        self.handle = nil
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw AgentGatewayError.journalUnavailable
        }
    }

    private func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &value, nil) == SQLITE_OK, let value else {
            throw AgentGatewayError.journalUnavailable
        }
        defer { sqlite3_finalize(value) }
        return try body(value)
    }

    private func text(_ statement: OpaquePointer, _ position: Int32, _ value: String) throws {
        let bytes = value.utf8.count
        guard bytes <= Int(Int32.max),
              sqlite3_bind_text(statement, position, value, Int32(bytes), transient) == SQLITE_OK else {
            throw AgentGatewayError.journalUnavailable
        }
    }

    private func blob(_ statement: OpaquePointer, _ position: Int32, _ value: Data) throws {
        guard value.count <= 128 * 1024 * 1024 else { throw AgentGatewayError.journalUnavailable }
        if value.isEmpty {
            guard sqlite3_bind_zeroblob(statement, position, 0) == SQLITE_OK else {
                throw AgentGatewayError.journalUnavailable
            }
        } else {
            let result = value.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress,
                                                                   Int32(value.count), transient) }
            guard result == SQLITE_OK else { throw AgentGatewayError.journalUnavailable }
        }
    }

    private func done(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AgentGatewayError.journalUnavailable }
    }

    private func data(_ statement: OpaquePointer, _ column: Int32) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0, count <= 128 * 1024 * 1024 else { throw AgentGatewayError.journalUnavailable }
        if count == 0 { return Data() }
        guard let pointer = sqlite3_column_blob(statement, column) else { throw AgentGatewayError.journalUnavailable }
        return Data(bytes: pointer, count: count)
    }

    private func string(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard let value = String(data: try data(statement, column), encoding: .utf8) else {
            throw AgentGatewayError.journalUnavailable
        }
        return value
    }

    func scalar(_ sql: String) throws -> Int64 {
        try statement(sql) {
            guard sqlite3_step($0) == SQLITE_ROW else { throw AgentGatewayError.journalUnavailable }
            return sqlite3_column_int64($0, 0)
        }
    }

    func textScalar(_ sql: String) throws -> String {
        try statement(sql) {
            guard sqlite3_step($0) == SQLITE_ROW else { throw AgentGatewayError.journalUnavailable }
            return try string($0, 0)
        }
    }

    func value(_ key: String) throws -> Data? {
        try statement("SELECT payload FROM state WHERE key=?") {
            try text($0, 1, key)
            let result = sqlite3_step($0)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw AgentGatewayError.journalUnavailable }
            return try data($0, 0)
        }
    }

    func allValues() throws -> [(String, Data)] {
        try statement("SELECT key,payload FROM state") {
            var result: [(String, Data)] = []
            while true {
                let step = sqlite3_step($0)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW else { throw AgentGatewayError.journalUnavailable }
                result.append((try string($0, 0), try data($0, 1)))
            }
        }
    }

    func putValue(_ key: String, data: Data?) throws {
        if let data {
            payloadBytesWritten += UInt64(key.utf8.count + data.count)
            try statement("INSERT INTO state(key,payload) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload") {
                try text($0, 1, key); try blob($0, 2, data); try done($0)
            }
        } else {
            try statement("DELETE FROM state WHERE key=?") { try text($0, 1, key); try done($0) }
        }
    }

    func events() throws -> [String: String] {
        try statement("SELECT id,digest FROM events") {
            var result: [String: String] = [:]
            while true {
                let step = sqlite3_step($0)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW else { throw AgentGatewayError.journalUnavailable }
                result[try string($0, 0)] = try string($0, 1)
            }
        }
    }

    func eventDigest(_ id: String) throws -> String? {
        try statement("SELECT digest FROM events WHERE id=?") {
            try text($0, 1, id)
            let step = sqlite3_step($0)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW else { throw AgentGatewayError.journalUnavailable }
            return try string($0, 0)
        }
    }

    func putEvent(_ id: String, digest: String) throws {
        payloadBytesWritten += UInt64(id.utf8.count + digest.utf8.count)
        try statement("INSERT INTO events(id,digest) VALUES(?,?)") {
            try text($0, 1, id); try text($0, 2, digest); try done($0)
        }
    }

    func messages() throws -> [(Int, Data)] {
        try statement("SELECT position,payload FROM messages ORDER BY position") {
            var result: [(Int, Data)] = []
            while true {
                let step = sqlite3_step($0)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW else { throw AgentGatewayError.journalUnavailable }
                result.append((Int(sqlite3_column_int64($0, 0)), try data($0, 1)))
            }
        }
    }

    func putMessage(_ position: Int, data: Data) throws {
        payloadBytesWritten += UInt64(MemoryLayout<Int64>.size + data.count)
        try statement("INSERT INTO messages(position,payload) VALUES(?,?) ON CONFLICT(position) DO UPDATE SET payload=excluded.payload") {
            sqlite3_bind_int64($0, 1, Int64(position)); try blob($0, 2, data); try done($0)
        }
    }

    func chunks(position: Int, kind: String) throws -> Data {
        try statement("SELECT body FROM chunks WHERE position=? AND kind=? ORDER BY sequence") {
            sqlite3_bind_int64($0, 1, Int64(position)); try text($0, 2, kind)
            var result = Data()
            while true {
                let step = sqlite3_step($0)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW else { throw AgentGatewayError.journalUnavailable }
                let chunk = try data($0, 0)
                guard result.count <= 128 * 1024 * 1024 - chunk.count else { throw AgentGatewayError.journalUnavailable }
                result.append(chunk)
            }
        }
    }

    func appendChunk(_ position: Int, kind: String, sequence: Int64, body: Data) throws {
        if body.isEmpty { return }
        payloadBytesWritten += UInt64(16 + kind.utf8.count + body.count)
        try statement("INSERT INTO chunks(position,kind,sequence,body) VALUES(?,?,?,?)") {
            sqlite3_bind_int64($0, 1, Int64(position)); try text($0, 2, kind)
            sqlite3_bind_int64($0, 3, sequence); try blob($0, 4, body); try done($0)
        }
    }

    func replaceChunks(_ position: Int, kind: String, sequence: Int64, body: Data) throws {
        try statement("DELETE FROM chunks WHERE position=? AND kind=?") {
            sqlite3_bind_int64($0, 1, Int64(position)); try text($0, 2, kind); try done($0)
        }
        try appendChunk(position, kind: kind, sequence: sequence, body: body)
    }

    func tools() throws -> [String: AgentGatewayToolRecord] {
        try statement("SELECT id,payload FROM tools") {
            var result: [String: AgentGatewayToolRecord] = [:]
            while true {
                let step = sqlite3_step($0)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW else { throw AgentGatewayError.journalUnavailable }
                result[try string($0, 0)] = try JSONDecoder().decode(AgentGatewayToolRecord.self, from: data($0, 1))
            }
        }
    }

    func putTool(_ id: String, data: Data) throws {
        payloadBytesWritten += UInt64(id.utf8.count + data.count)
        try statement("INSERT INTO tools(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload") {
            try text($0, 1, id); try blob($0, 2, data); try done($0)
        }
    }

    /// Called inside the state transaction, so an interrupted v2 upgrade
    /// retains the original header and schema together.
    func createTaskTables() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS task_entries(position INTEGER PRIMARY KEY, payload BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS task_chunks(position INTEGER NOT NULL, kind TEXT NOT NULL,
                sequence INTEGER NOT NULL, body BLOB NOT NULL,
                PRIMARY KEY(position, kind, sequence));
            CREATE TABLE IF NOT EXISTS task_receipts(id TEXT PRIMARY KEY, digest TEXT NOT NULL);
            PRAGMA user_version=3;
            """)
    }

    func archiveTasks(revision: Int64) throws {
        try execute("""
            INSERT INTO archive(revision,kind,identity,payload)
            SELECT \(revision), 'task_entry', CAST(position AS TEXT), payload FROM task_entries;
            INSERT INTO archive(revision,kind,identity,payload)
            SELECT \(revision), 'task_chunk', position || ':' || kind || ':' || sequence, body FROM task_chunks;
            INSERT INTO archive(revision,kind,identity,payload)
            SELECT \(revision), 'task_receipt', id, CAST(digest AS BLOB) FROM task_receipts;
            INSERT INTO archive(revision,kind,identity,payload)
            SELECT \(revision), 'value', key, payload FROM state WHERE key='task_presence';
            """)
    }

    func taskEntries() throws -> [(Int, Data)] {
        try statement("SELECT position,payload FROM task_entries ORDER BY position") {
            var result: [(Int, Data)] = []
            while true {
                let step = sqlite3_step($0)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW else { throw AgentGatewayError.journalUnavailable }
                result.append((Int(sqlite3_column_int64($0, 0)), try data($0, 1)))
            }
        }
    }

    func putTaskEntry(_ position: Int, data: Data) throws {
        payloadBytesWritten += UInt64(8 + data.count)
        try statement("INSERT INTO task_entries(position,payload) VALUES(?,?) ON CONFLICT(position) DO UPDATE SET payload=excluded.payload") {
            sqlite3_bind_int64($0, 1, Int64(position)); try blob($0, 2, data); try done($0)
        }
    }

    func taskChunks(position: Int, kind: String) throws -> String {
        try statement("SELECT body FROM task_chunks WHERE position=? AND kind=? ORDER BY sequence") {
            sqlite3_bind_int64($0, 1, Int64(position)); try text($0, 2, kind)
            var result = Data()
            while true {
                let step = sqlite3_step($0)
                if step == SQLITE_DONE {
                    guard let value = String(data: result, encoding: .utf8) else {
                        throw AgentGatewayError.journalUnavailable
                    }
                    return value
                }
                guard step == SQLITE_ROW else { throw AgentGatewayError.journalUnavailable }
                let chunk = try data($0, 0)
                guard result.count <= 128 * 1024 * 1024 - chunk.count else {
                    throw AgentGatewayError.journalUnavailable
                }
                result.append(chunk)
            }
        }
    }

    func putTaskText(_ position: Int, kind: String, sequence: Int64, body: Data, replace: Bool) throws {
        if replace {
            try statement("DELETE FROM task_chunks WHERE position=? AND kind=?") {
                sqlite3_bind_int64($0, 1, Int64(position)); try text($0, 2, kind); try done($0)
            }
        }
        if body.isEmpty { return }
        payloadBytesWritten += UInt64(16 + kind.utf8.count + body.count)
        try statement("INSERT INTO task_chunks(position,kind,sequence,body) VALUES(?,?,?,?)") {
            sqlite3_bind_int64($0, 1, Int64(position)); try text($0, 2, kind)
            sqlite3_bind_int64($0, 3, sequence); try blob($0, 4, body); try done($0)
        }
    }

    func taskTextKinds(position: Int) throws -> Set<String> {
        try statement("SELECT DISTINCT kind FROM task_chunks WHERE position=?") {
            sqlite3_bind_int64($0, 1, Int64(position))
            var result: Set<String> = []
            while true {
                let step = sqlite3_step($0)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW else { throw AgentGatewayError.journalUnavailable }
                result.insert(try string($0, 0))
            }
        }
    }

    func removeTaskText(_ position: Int, kind: String) throws {
        try statement("DELETE FROM task_chunks WHERE position=? AND kind=?") {
            sqlite3_bind_int64($0, 1, Int64(position)); try text($0, 2, kind); try done($0)
        }
    }

    func taskReceipts() throws -> [String: String] {
        try statement("SELECT id,digest FROM task_receipts") {
            var result: [String: String] = [:]
            while true {
                let step = sqlite3_step($0)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW else { throw AgentGatewayError.journalUnavailable }
                result[try string($0, 0)] = try string($0, 1)
            }
        }
    }

    func putTaskReceipt(_ id: String, digest: String) throws {
        payloadBytesWritten += UInt64(id.utf8.count + digest.utf8.count)
        try statement("INSERT INTO task_receipts(id,digest) VALUES(?,?)") {
            try text($0, 1, id); try text($0, 2, digest); try done($0)
        }
    }
}
