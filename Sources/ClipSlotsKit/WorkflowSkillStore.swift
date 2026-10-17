import Foundation
import Darwin

/// Versions are immutable directory renames; current.json is the sole visibility commit.
/// A failed/crashed save may leave an unreachable version, never a partial visible Skill.
public final class WorkflowSkillStore {
    public struct Entry: Codable, Equatable, Identifiable {
        public var id: UUID
        public var version: Int
        public var name: String
        public var summary: String
        public var scope: WorkflowSkill.Scope
        public var projectID: String?
        public var savedAt: Date
        public var nodeCount: Int
        public var edgeCount: Int
        public var digests: [String: String]
        public var sourceLabel: String {
            (scope == .personal ? "个人 Skill" : "当前项目") + " · v\(version) · \(id.uuidString.prefix(6))"
        }
    }
    private let root: URL
    private let fm = FileManager.default
    public init(root: URL = ClipSlotsPaths.dataRoot) {
        self.root = root.appendingPathComponent("workflow-skills", isDirectory: true)
    }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func versionDirectory(_ entry: Entry) -> URL {
        directory(entry.id).appendingPathComponent("versions/\(entry.version)", isDirectory: true)
    }
    public func markdownURL(_ entry: Entry) -> URL { versionDirectory(entry).appendingPathComponent("SKILL.md") }
    private func decode<T: Decodable>(_ type: T.Type, at url: URL, limit: Int = 16_000_000) throws -> T {
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= limit else {
            throw AgentOperationError("Skill 文件类型或大小不正确。")
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    public func list(projectID: String? = nil) -> [Entry] {
        let paths = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return paths.compactMap { path -> Entry? in
            guard let id = UUID(uuidString: path.lastPathComponent),
                  let entry = try? decode(Entry.self, at: path.appendingPathComponent("current.json"), limit: 32_000),
                  entry.id == id, entry.version > 0,
                  entry.scope == .personal || entry.projectID == projectID else { return nil }
            // Only metadata is read during discovery; hashes are checked when selected.
            guard fm.fileExists(atPath: versionDirectory(entry).appendingPathComponent("manifest.json").path) else { return nil }
            return entry
        }.sorted {
            $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    public func versions(of entry: Entry) -> [Entry] {
        // Follow only the committed chain: orphan versions from failed writes stay hidden.
        guard let current = try? decode(Entry.self, at: directory(entry.id).appendingPathComponent("current.json"), limit: 32_000) else { return [] }
        var result: [Entry] = [], version = current.version, seen = Set<Int>()
        while version > 0 && seen.insert(version).inserted {
            let url = directory(entry.id).appendingPathComponent("versions/\(version)/manifest.json")
            guard let manifest = try? decode(Manifest.self, at: url, limit: 32_000), manifest.entry.id == entry.id else { break }
            result.append(manifest.entry)
            version = manifest.previousVersion ?? 0
        }
        return result
    }
    private struct Metadata: Codable {
        var id: UUID
        var version: Int
        var name: String
        var summary: String
        var method: String
        var scope: WorkflowSkill.Scope
        var projectID: String?
    }
    private struct Manifest: Codable {
        var entry: Entry
        var previousVersion: Int?
    }
    public func load(_ entry: Entry, projectID: String? = nil) throws -> WorkflowSkill {
        guard entry.scope == .personal || (entry.projectID != nil && entry.projectID == projectID) else {
            throw AgentOperationError("此 Skill 仅在来源项目中可用。")
        }
        guard versions(of: entry).contains(entry) else { throw AgentOperationError("该 Skill 版本尚未提交或已损坏。") }
        let dir = versionDirectory(entry)
        var files: [String: Data] = [:]
        for name in ["metadata.json", "workflow.json", "provenance.json", "SKILL.md"] {
            let url = dir.appendingPathComponent(name)
            let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= 16_000_000 else { throw AgentOperationError("Skill 文件过大或损坏。") }
            let data = try Data(contentsOf: url)
            guard CanvasWorkflowSnapshot.digest(data) == entry.digests[name] else {
                throw AgentOperationError("Skill 文档与工作流校验不一致，请恢复完整版本后再使用。")
            }
            files[name] = data
        }
        let decoder = JSONDecoder()
        let metadata = try decoder.decode(Metadata.self, from: files["metadata.json"] ?? Data())
        let graph = try decoder.decode(WorkflowSkill.Graph.self, from: files["workflow.json"] ?? Data())
        let provenance = try decoder.decode(WorkflowSkill.Provenance.self, from: files["provenance.json"] ?? Data())
        guard metadata.id == entry.id, metadata.version == entry.version, metadata.scope == entry.scope,
              metadata.projectID == entry.projectID, metadata.name == entry.name, metadata.summary == entry.summary else {
            throw AgentOperationError("Skill 清单与内容不一致。")
        }
        // Decode the aggregate without a second, permissive initializer.
        struct Aggregate: Encodable {
            var id: UUID; var version: Int; var name: String; var summary: String; var method: String
            var scope: WorkflowSkill.Scope; var projectID: String?
            var graph: WorkflowSkill.Graph; var provenance: WorkflowSkill.Provenance
        }
        let aggregate = Aggregate(id: metadata.id, version: metadata.version, name: metadata.name,
            summary: metadata.summary, method: metadata.method, scope: metadata.scope, projectID: metadata.projectID,
            graph: graph, provenance: provenance)
        let skill = try decoder.decode(WorkflowSkill.self, from: CanvasWorkflowSnapshot.jsonData(aggregate))
        try skill.validate()
        guard Data(try skill.markdown().utf8) == files["SKILL.md"] else { throw AgentOperationError("方法文档与变量声明冲突。") }
        return skill
    }
    /// expectedVersion prevents a stale editor from overwriting an intervening save.
    @discardableResult
    public func save(_ draft: WorkflowSkill, expectedVersion: Int? = nil) throws -> Entry {
        try draft.validate()
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw AgentOperationError("无法锁定 Skill 存储。") }
        defer { flock(fd, LOCK_UN); close(fd) }
        let deadline = Date().addingTimeInterval(2)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard (errno == EWOULDBLOCK || errno == EAGAIN), Date() < deadline else {
                throw AgentOperationError("Skill 存储正忙，请稍后重试。")
            }
            usleep(20_000)
        }
        let dir = directory(draft.id), currentURL = dir.appendingPathComponent("current.json")
        let current: Entry? = fm.fileExists(atPath: currentURL.path)
            ? try decode(Entry.self, at: currentURL, limit: 32_000) : nil
        guard (current?.version ?? 0) == (expectedVersion ?? 0) else {
            throw AgentOperationError("Skill 已有新版本，请重新打开后比较保存。")
        }
        if let current {
            guard current.id == draft.id && current.scope == draft.scope && current.projectID == draft.projectID else {
                throw AgentOperationError("更新版本不能更改所属范围，请另存为新 Skill。")
            }
            _ = try load(current, projectID: draft.projectID)
        }
        var skill = draft
        skill.version = (current?.version ?? 0) + 1
        // Skipping abandoned directories avoids replacing any committed/previous artifact.
        while fm.fileExists(atPath: dir.appendingPathComponent("versions/\(skill.version)").path) { skill.version += 1 }
        let metadata = Metadata(id: skill.id, version: skill.version, name: skill.name, summary: skill.summary,
            method: skill.method, scope: skill.scope, projectID: skill.projectID)
        let files: [String: Data] = [
            "metadata.json": try CanvasWorkflowSnapshot.jsonData(metadata),
            "workflow.json": try CanvasWorkflowSnapshot.jsonData(skill.graph),
            "provenance.json": try CanvasWorkflowSnapshot.jsonData(skill.provenance),
            "SKILL.md": Data(try skill.markdown().utf8)
        ]
        guard files.values.allSatisfy({ $0.count <= 16_000_000 }) else { throw AgentOperationError("Skill 内容过大。") }
        let entry = Entry(id: skill.id, version: skill.version, name: skill.name, summary: skill.summary,
            scope: skill.scope, projectID: skill.projectID, savedAt: Date(),
            nodeCount: skill.graph.nodes.count, edgeCount: skill.graph.edges.count,
            digests: files.mapValues(CanvasWorkflowSnapshot.digest))
        let stage = dir.appendingPathComponent(".stage-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        for (name, data) in files {
            let url = stage.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            guard try Data(contentsOf: url) == data else { throw AgentOperationError("Skill 写入校验失败。") }
        }
        try CanvasWorkflowSnapshot.jsonData(Manifest(entry: entry, previousVersion: current?.version))
            .write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
        let target = versionDirectory(entry)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: stage, to: target)
        try CanvasWorkflowSnapshot.jsonData(entry).write(to: currentURL, options: .atomic)
        return entry
    }
    public func agentSkill(_ entry: Entry) -> AgentSkill {
        AgentSkill(slug: "workflow_" + entry.id.uuidString.lowercased().replacingOccurrences(of: "-", with: "_"),
            name: entry.name, description: entry.sourceLabel + " · " + entry.summary, version: String(entry.version),
            directory: versionDirectory(entry).path, markdownPath: markdownURL(entry).path,
            source: entry.scope == .personal ? .personal : .project, declaredTools: [], scripts: [])
    }
}
