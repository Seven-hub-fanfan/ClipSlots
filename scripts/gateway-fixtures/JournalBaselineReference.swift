import Foundation
import CryptoKit
import Darwin
@testable import ClipSlotsKit

/// Frozen S3 persistence path. Changes relative to production are its type name,
/// the byte counter and the benchmark protocol adapter. load/save/acquire/release
/// otherwise keep the original JSON/atomic replacement/fsync implementation.
final class JournalBaselineReference: JournalBenchmarkStore {
    let file: URL
    let origin: String
    let binding: AgentRunBinding
    private let root: URL
    private(set) var payloadBytesWritten: UInt64 = 0
    var storageFile: URL { file }

    init(baseURL: URL, binding: AgentRunBinding, root: URL) {
        self.root = root
        self.binding = binding
        origin = baseURL.absoluteString
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedBinding = (try? encoder.encode(binding)) ?? Data()
        let digest = Self.digest(Data(origin.utf8) + encodedBinding)
        file = root.appendingPathComponent("gateway-\(digest).json")
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func load() throws -> AgentGatewayJournal {
        if !FileManager.default.fileExists(atPath: file.path) {
            return AgentGatewayJournal(origin: origin, binding: binding,
                                       clientInstanceID: UUID().uuidString)
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 32_000_000 else {
                throw AgentGatewayError.journalUnavailable
            }
            let journal = try JSONDecoder().decode(AgentGatewayJournal.self, from: Data(contentsOf: file))
            guard journal.schemaVersion == 1, journal.origin == origin, journal.binding == binding,
                  !journal.clientInstanceID.isEmpty,
                  journal.cursor.map({ journal.eventDigests[$0] != nil }) ?? true else {
                throw AgentGatewayError.journalUnavailable
            }
            return journal
        } catch { throw AgentGatewayError.journalUnavailable }
    }

    func save(_ journal: AgentGatewayJournal) throws {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(journal)
            guard data.count <= 32_000_000 else { throw AgentGatewayError.journalUnavailable }
            try data.write(to: file, options: .atomic)
            payloadBytesWritten += UInt64(data.count)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw AgentGatewayError.journalUnavailable }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw AgentGatewayError.journalUnavailable }
        } catch { throw AgentGatewayError.journalUnavailable }
    }

    func saveEvent(_ journal: AgentGatewayJournal, eventID: String, digest: String,
                   delta: (messageID: UUID, kind: String, text: String)?) throws {
        try save(journal)
    }

    func acquire() throws -> Int32 {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw AgentGatewayError.journalUnavailable }
        let fd = open(file.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AgentGatewayError.journalUnavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw AgentGatewayError.busy
        }
        return fd
    }

    func release(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
