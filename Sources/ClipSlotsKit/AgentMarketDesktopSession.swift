import Foundation
import CryptoKit

/// Reads only the reference desktop's active access-token record. Never copies its
/// refresh token, cookies, other storage values or identity into ClipSlots settings.
/// The token remains in memory and may be sent only to the two official API origins.
public struct AgentMarketDesktopSession: Sendable {
    public let token: String
    public let scope: String
    public let origin: String
    public let organization: String?

    public static func read(home: String = NSHomeDirectory(), now: Date = Date()) -> Self? {
        let root = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/@tap/desktop/Local Storage/leveldb")
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil),
              let current = try? String(contentsOf: root.appendingPathComponent("CURRENT"), encoding: .utf8),
              let manifest = try? Data(contentsOf: root.appendingPathComponent(current.trimmingCharacters(in: .whitespacesAndNewlines))),
              let live = try? MarketLevelDB.liveFiles(manifest) else { return nil }
        var records: [MarketLevelDB.Record] = []
        for file in files {
            let number = UInt64(file.deletingPathExtension().lastPathComponent) ?? 0
            guard (file.pathExtension == "ldb" && live.tables.contains(number))
                    || (file.pathExtension == "log" && live.logs.contains(number)),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size < 32 * 1024 * 1024,
                  let data = try? Data(contentsOf: file),
                  let parsed = try? (file.pathExtension == "ldb" ? MarketLevelDB.table(data) : MarketLevelDB.batchLog(data))
            else { continue }
            records += parsed
        }
        var latest: [String: MarketLevelDB.Record] = [:]
        for record in records {
            guard let separator = record.key.firstIndex(of: 0),
                  let origin = String(bytes: record.key.prefix(separator), encoding: .utf8),
                  origin.hasPrefix("_"),
                  let url = URL(string: String(origin.dropFirst())),
                  (String(origin.dropFirst()) == "tapnow://app"
                    || (url.scheme == "https" && ["app.tapnow.media", "app.tapnow.ai"].contains(url.host ?? ""))),
                  decode(Array(record.key.dropFirst(separator + 1))) == "access_token"
            else { continue }
            if record.sequence >= (latest[origin]?.sequence ?? 0) { latest[origin] = record }
        }
        for (origin, record) in latest.sorted(by: { $0.value.sequence > $1.value.sequence }) {
            guard record.type == 1, let token = decode(record.value), token.count < 16_384,
                  token.split(separator: ".").count == 3 else { continue }
            let segment = String(token.split(separator: ".")[1])
            let base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            guard let payload = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)),
                  let claims = try? JSONDecoder().decode(JSONValue.self, from: payload),
                  let expiry = claims["exp"]?.intValue,
                  Double(expiry) > now.timeIntervalSince1970 + 30,
                  let subject = claims["sub"]?.stringValue ?? claims["user_id"]?.stringValue ?? claims["uid"]?.stringValue
            else { continue }
            let identity = origin + "|" + subject + "|" + (claims["org_id"]?.stringValue ?? "")
            return Self(token: token, scope: String(SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)),
                        origin: String(origin.dropFirst()), organization: claims["org_id"]?.stringValue)
        }
        return nil
    }

    private static func decode(_ bytes: [UInt8]) -> String? {
        guard let format = bytes.first else { return nil }
        if format == 1 { return String(bytes: bytes.dropFirst(), encoding: .utf8) }
        if format == 0 { return String(data: Data(bytes.dropFirst()), encoding: .utf16LittleEndian) }
        return nil
    }
}

// Small read-only Chromium LevelDB decoder; no DB lock, write, native library or
// runtime is loaded. Manifest membership and sequence/tombstone checks are essential.
enum MarketLevelDB {
    struct Record { var key: [UInt8]; var value: [UInt8]; var sequence: UInt64; var type: UInt8 }
    enum Invalid: Error { case data }
    struct Cursor {
        var bytes: [UInt8]; var i = 0
        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, i <= bytes.count, count <= bytes.count - i else { throw Invalid.data }
            defer { i += count }; return Array(bytes[i..<i + count])
        }
        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                let b = try take(1)[0]
                if shift == 63 && b > 1 { throw Invalid.data }
                result |= UInt64(b & 127) << shift
                if b < 128 { return result }
            }
            throw Invalid.data
        }
        mutating func string() throws -> [UInt8] {
            let n = try varint(); guard n <= 32 * 1024 * 1024 else { throw Invalid.data }
            return try take(Int(n))
        }
    }
    static func little(_ b: [UInt8]) -> UInt64 {
        b.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    static func logs(_ data: Data) throws -> [[UInt8]] {
        let b = Array(data); var i = 0, partial: [UInt8] = [], result: [[UInt8]] = []
        while i + 7 <= b.count {
            let remaining = 32768 - i % 32768
            if remaining < 7 { i += remaining; continue }
            let length = Int(little(Array(b[i + 4..<i + 6]))), type = b[i + 6]
            if length == 0 && type == 0 { i += remaining; continue }
            guard length + 7 <= remaining, i + 7 + length <= b.count else { break } // active log may have an incomplete tail
            let part = Array(b[i + 7..<i + 7 + length]); i += 7 + length
            switch type {
            case 1: result.append(part); partial = []
            case 2: partial = part
            case 3: partial += part
            case 4: partial += part; result.append(partial); partial = []
            default: throw Invalid.data
            }
        }
        return result
    }
    static func liveFiles(_ data: Data) throws -> (tables: Set<UInt64>, logs: Set<UInt64>) {
        var tables = Set<UInt64>(), log: UInt64 = 0, previous: UInt64 = 0
        for entry in try logs(data) {
            var c = Cursor(bytes: entry)
            while c.i < c.bytes.count {
                switch try c.varint() {
                case 1: _ = try c.string()
                case 2: log = try c.varint()
                case 3, 4: _ = try c.varint()
                case 5: _ = try c.varint(); _ = try c.string()
                case 6: _ = try c.varint(); tables.remove(try c.varint())
                case 7:
                    _ = try c.varint(); tables.insert(try c.varint())
                    _ = try c.varint(); _ = try c.string(); _ = try c.string()
                case 9: previous = try c.varint()
                default: throw Invalid.data
                }
            }
        }
        return (tables, Set([log, previous].filter { $0 != 0 }))
    }
    static func batchLog(_ data: Data) throws -> [Record] {
        var result: [Record] = []
        for entry in try logs(data) {
            guard entry.count >= 12 else { continue }
            var c = Cursor(bytes: entry)
            let seq = little(try c.take(8)), count = little(try c.take(4))
            guard count <= 100_000 else { throw Invalid.data }
            for offset in 0..<count {
                let type = try c.take(1)[0], key = try c.string()
                guard type <= 1 else { throw Invalid.data }
                let value = type == 1 ? try c.string() : []
                result.append(.init(key: key, value: value, sequence: seq + offset, type: type))
            }
        }
        return result
    }
    static func snappy(_ bytes: [UInt8]) throws -> [UInt8] {
        var c = Cursor(bytes: bytes); let size = try c.varint()
        guard size <= 32 * 1024 * 1024 else { throw Invalid.data }
        var out: [UInt8] = []; out.reserveCapacity(Int(size))
        while c.i < bytes.count {
            let tag = try c.take(1)[0], kind = tag & 3
            if kind == 0 {
                var length = Int(tag >> 2) + 1
                if length > 60 { length = Int(little(try c.take(length - 60))) + 1 }
                guard out.count + length <= size else { throw Invalid.data }
                out += try c.take(length)
            } else {
                let length = kind == 1 ? 4 + Int((tag >> 2) & 7) : 1 + Int(tag >> 2)
                let offset = kind == 1 ? Int(tag & 0xe0) << 3 | Int(try c.take(1)[0])
                    : Int(little(try c.take(kind == 2 ? 2 : 4)))
                guard offset > 0, offset <= out.count, out.count + length <= size else { throw Invalid.data }
                for _ in 0..<length { out.append(out[out.count - offset]) }
            }
        }
        guard out.count == size else { throw Invalid.data }; return out
    }
    static func entries(_ block: [UInt8]) throws -> [([UInt8], [UInt8])] {
        guard block.count >= 4 else { throw Invalid.data }
        let restart = Int(little(Array(block.suffix(4))))
        guard restart <= (block.count - 4) / 4 else { throw Invalid.data }
        let limit = block.count - 4 - restart * 4
        var c = Cursor(bytes: Array(block.prefix(limit))), key: [UInt8] = [], result: [([UInt8], [UInt8])] = []
        while c.i < limit {
            let shared = try c.varint(), added = try c.varint(), valueLength = try c.varint()
            guard shared <= key.count, added <= limit, valueLength <= limit else { throw Invalid.data }
            key = Array(key.prefix(Int(shared))) + (try c.take(Int(added)))
            result.append((key, try c.take(Int(valueLength))))
        }
        return result
    }
    static func table(_ data: Data) throws -> [Record] {
        let b = Array(data)
        guard b.count >= 48, little(Array(b.suffix(8))) == 0xdb4775248b80fb57 else { throw Invalid.data }
        var footer = Cursor(bytes: Array(b.suffix(48).prefix(40)))
        _ = try footer.varint(); _ = try footer.varint()
        let indexOffset = try footer.varint(), indexLength = try footer.varint()
        func block(_ offset: UInt64, _ length: UInt64) throws -> [UInt8] {
            guard offset < b.count, length < b.count, offset + length + 5 <= b.count else { throw Invalid.data }
            let value = Array(b[Int(offset)..<Int(offset + length)])
            switch b[Int(offset + length)] {
            case 0: return value
            case 1: return try snappy(value)
            default: throw Invalid.data
            }
        }
        var result: [Record] = []
        for (_, handle) in try entries(block(indexOffset, indexLength)) {
            var c = Cursor(bytes: handle)
            let offset = try c.varint(), length = try c.varint()
            for (key, value) in try entries(block(offset, length)) where key.count >= 8 {
                let trailer = little(Array(key.suffix(8)))
                result.append(.init(key: Array(key.dropLast(8)), value: value, sequence: trailer >> 8, type: UInt8(trailer & 255)))
            }
        }
        return result
    }
}
