import Foundation

/// A bounded disposable copy for an explicit native share action.
public struct AgentArtifactLocalCopy {
    public let directory: URL
    public let fileURL: URL

    public init(content: Data, path: String, temporaryRoot: URL = FileManager.default.temporaryDirectory) throws {
        guard content.count <= 64 * 1024 * 1024 else { throw AgentArtifactError.tooLarge }
        let normalized = try AgentArtifactKey.normalize(path)
        guard temporaryRoot.isFileURL else { throw AgentArtifactError.invalidFile }
        let directory = temporaryRoot.appendingPathComponent("clipslots-artifact-share-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent((normalized as NSString).lastPathComponent)
        do {
            try content.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.directory = directory; self.fileURL = url
    }

    public func remove() throws { try FileManager.default.removeItem(at: directory) }
}
