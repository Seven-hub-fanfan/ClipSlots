import Foundation

/// Explicit per-message instruction reference. Reading a skill does not enable its tools.
public struct AgentSkillReference: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let markdown: String
    public static let maximumCount = 4
    public static let maximumBytes = 65_536

    public static func load(name: String, path: String) throws -> Self {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= maximumBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        guard let markdown = String(data: data, encoding: .utf8),
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return Self(name: name, path: url.path, markdown: markdown)
    }
}
