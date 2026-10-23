import Foundation
import CryptoKit

/// Widget state is isolated by conversation, artifact and content revision.
/// The host must validate the current artifact before opening this store.
public final class AgentWidgetStateStore: @unchecked Sendable {
    private let root: URL
    private let lock: StorageLock

    private struct Snapshot: Codable {
        let key: AgentArtifactKey
        let conversationID: UUID
        let revision: UInt64
        let state: JSONValue
    }

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        root = directory.standardizedFileURL.resolvingSymlinksInPath()
        lock = StorageLock(lockURL: root.appendingPathComponent(".widget.lock"))
    }

    public func load(key: AgentArtifactKey, conversationID: UUID, revision: UInt64) throws -> JSONValue {
        try lock.withLock {
            guard !lock.isDegraded else { throw AgentArtifactError.storageUnavailable }
            let url = location(key, conversationID, revision)
            guard FileManager.default.fileExists(atPath: url.path) else { return .null }
            let bytes = try AgentArtifactFileAccess.readRegularFile(url, maximumBytes: 72 * 1024)
            let saved = try JSONDecoder().decode(Snapshot.self, from: bytes)
            guard saved.key == key, saved.conversationID == conversationID, saved.revision == revision else {
                throw AgentArtifactError.invalidMetadata
            }
            try validate(saved.state)
            return saved.state
        }
    }

    public func save(_ state: JSONValue, key: AgentArtifactKey, conversationID: UUID, revision: UInt64) throws {
        try validate(state)
        try lock.withLock {
            guard !lock.isDegraded else { throw AgentArtifactError.storageUnavailable }
            let url = location(key, conversationID, revision)
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            guard files.count < 4096 || files.contains(url) else { throw AgentArtifactError.capacityExceeded }
            let bytes = try JSONEncoder().encode(Snapshot(key: key, conversationID: conversationID,
                                                       revision: revision, state: state))
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func validate(_ state: JSONValue) throws {
        guard try JSONEncoder().encode(state).count <= 64 * 1024 else { throw AgentArtifactError.tooLarge }
    }

    private func location(_ key: AgentArtifactKey, _ conversationID: UUID, _ revision: UInt64) -> URL {
        let fields = [key.scope.projectID, key.scope.canvasID, key.path, conversationID.uuidString, String(revision)]
        let framed = fields.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest + ".json")
    }
}
