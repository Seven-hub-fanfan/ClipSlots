import Foundation
import CryptoKit
import Darwin

struct AgentGatewayJournalStore {
    let file: URL
    let origin: String
    let binding: AgentRunBinding
    private let root: URL

    init(baseURL: URL, binding: AgentRunBinding, root: URL) {
        self.root = root
        self.binding = binding
        // The full configured service root is part of the scope, not just host.
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
            // State, reconstructed messages, reservations and committed cursor
            // occupy one atomic replacement. No independent cursor sidecar.
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw AgentGatewayError.journalUnavailable }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw AgentGatewayError.journalUnavailable }
        } catch { throw AgentGatewayError.journalUnavailable }
    }

    /// Held over async work. A second controller/process cannot create a run
    /// using a stale snapshot for the same service root and binding.
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
