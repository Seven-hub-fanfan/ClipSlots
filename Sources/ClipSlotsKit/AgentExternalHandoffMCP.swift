import Foundation

public struct AgentExternalReadOnlyMCPConfiguration: Equatable, Sendable {
    public let scope: AgentArtifactScope
    public let snapshotID: UUID?
    public let sessionID: UUID?

    public init(scope: AgentArtifactScope, snapshotID: UUID? = nil, sessionID: UUID? = nil) {
        self.scope = scope; self.snapshotID = snapshotID; self.sessionID = sessionID
    }

    public static func parse(arguments: [String]) throws -> Self {
        let aliases = ["--project": "project", "--project-id": "project",
                       "--canvas": "canvas", "--canvas-id": "canvas",
                       "--snapshot": "snapshot", "--snapshot-id": "snapshot",
                       "--session": "session", "--session-id": "session"]
        var values: [String: String] = [:]
        var readOnlySeen = false
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--read-only", !readOnlySeen {
                readOnlySeen = true; index += 1; continue
            }
            guard let key = aliases[flag], values[key] == nil, index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else { throw AgentExternalHandoffError.invalidConfiguration }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard let project = values["project"], let canvas = values["canvas"],
              values["snapshot"] == nil || UUID(uuidString: values["snapshot"] ?? "") != nil,
              values["session"] == nil || UUID(uuidString: values["session"] ?? "") != nil else {
            throw AgentExternalHandoffError.invalidConfiguration
        }
        return try .init(scope: AgentArtifactScope(projectID: project, canvasID: canvas),
                         snapshotID: values["snapshot"].flatMap(UUID.init(uuidString:)),
                         sessionID: values["session"].flatMap(UUID.init(uuidString:)))
    }
}

/// Read-only route: no general registry, live stores, shell or Skill executors.
public final class AgentExternalReadOnlyMCPTools: AgentToolExecuting, @unchecked Sendable {
    public let configuration: AgentExternalReadOnlyMCPConfiguration
    public let snapshotID: UUID
    private let canvas: CanvasAgentReadTools
    private let artifacts: AgentArtifactRepository

    public convenience init(configuration: AgentExternalReadOnlyMCPConfiguration,
                            dataRoot: URL = ClipSlotsPaths.dataRoot) throws {
        let snapshots = dataRoot.appendingPathComponent("agent-canvas-snapshots", isDirectory: true)
        let projectFolder = snapshots.appendingPathComponent(CanvasWorkflowSnapshot.digest(Data(configuration.scope.projectID.utf8)))
        let file: URL
        if let id = configuration.snapshotID {
            file = projectFolder.appendingPathComponent(id.uuidString + ".json")
        } else {
            let files = try FileManager.default.contentsOfDirectory(at: projectFolder,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            guard !files.isEmpty, files.count <= 4096 else { throw AgentExternalHandoffError.invalidConfiguration }
            let dated = try files.map { ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) }
            guard let newest = dated.sorted(by: { ($0.1, $0.0.lastPathComponent) > ($1.1, $1.0.lastPathComponent) }).first else {
                throw AgentExternalHandoffError.invalidConfiguration
            }
            file = newest.0
        }
        let data = try AgentArtifactFileAccess.read(file, within: snapshots, maximumBytes: 32_000_000)
        let snapshot = try JSONDecoder().decode(CanvasAgentSnapshot.self, from: data)
        guard snapshot.graph.snapshotID.uuidString.caseInsensitiveCompare(file.deletingPathExtension().lastPathComponent) == .orderedSame else {
            throw AgentExternalHandoffError.invalidConfiguration
        }
        try self.init(configuration: configuration, snapshot: snapshot,
                      artifacts: AgentArtifactRepository(directory: dataRoot.appendingPathComponent("agent_artifacts")))
    }

    public init(configuration: AgentExternalReadOnlyMCPConfiguration, snapshot: CanvasAgentSnapshot,
                artifacts: AgentArtifactRepository) throws {
        guard configuration.scope.projectID == snapshot.graph.projectID,
              configuration.scope.canvasID == snapshot.canvasID,
              configuration.snapshotID == nil || configuration.snapshotID == snapshot.graph.snapshotID else {
            throw AgentExternalHandoffError.invalidConfiguration
        }
        self.configuration = .init(scope: configuration.scope, snapshotID: snapshot.graph.snapshotID, sessionID: configuration.sessionID)
        self.snapshotID = snapshot.graph.snapshotID
        self.canvas = CanvasAgentReadTools(snapshot: snapshot)
        self.artifacts = artifacts
    }

    public func specs() -> [AgentToolSpec] {
        let integer: JSONValue = ["type": "integer", "minimum": 0]
        let path: JSONValue = ["type": "string", "maxLength": 1024]
        func spec(_ name: String, _ description: String, _ properties: [String: JSONValue],
                  required: [String] = []) -> AgentToolSpec {
            .init(name: name, description: description, parameters: [
                "type": "object", "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)), "additionalProperties": false
            ], originLabel: "项目只读")
        }
        return [
            spec("clipslots_context", "读取当前项目、画布、固定快照和只读权限；不代表已连接内部 Agent。", [:]),
            spec("artifact_list", "分页列出当前项目/画布的本地产物元数据，不包含正文或文件地址。",
                 ["offset": integer, "limit": ["type": "integer", "minimum": 1, "maximum": 40]]),
            spec("artifact_metadata", "读取当前项目/画布内相对路径的产物修订和加载状态。",
                 ["path": path], required: ["path"]),
            spec("artifact_read", "读取当前修订的本地产物片段。revision 为精确十进制字符串；正文按 Unicode 字符分页，二进制按字节分页并返回 base64。",
                 ["path": path, "revision": ["type": "string", "pattern": "^[0-9]+$"],
                  "offset": integer, "limit": ["type": "integer", "minimum": 1, "maximum": 8000]],
                 required: ["path", "revision"])
        ] + canvas.specs()
    }

    public func execute(call: AgentToolCall) async -> AgentToolResult {
        guard !Task.isCancelled else { return .failure("读取已取消。", code: "CANCELLED") }
        if canvas.specs().contains(where: { $0.name == call.name }) { return await canvas.execute(call: call) }
        do {
            guard let spec = specs().first(where: { $0.name == call.name }) else {
                return .failure("此连接只开放项目快照和产物读取。", code: "READ_ONLY_SCOPE")
            }
            let args = try call.arguments()
            guard let object = args.objectValue,
                  Set(object.keys).isSubset(of: Set(spec.parameters["properties"]?.objectValue?.keys.map { $0 } ?? [])) else {
                throw AgentExternalHandoffError.invalidConfiguration
            }
            var result: [String: JSONValue] = [
                "ok": true, "read_only": true,
                "project_id": .string(configuration.scope.projectID),
                "canvas_id": .string(configuration.scope.canvasID),
                "snapshot_id": .string(snapshotID.uuidString),
                "session_id": configuration.sessionID.map { .string($0.uuidString) } ?? .null
            ]
            if call.name == "artifact_list" {
                let records = try artifacts.records(in: configuration.scope)
                let range = try page(args, total: records.count, maximum: 40, fallback: 20)
                result["artifacts"] = .array(records[range].map(metadata))
                result["next_offset"] = range.upperBound < records.count ? .number(Double(range.upperBound)) : .null
                result["total"] = .number(Double(records.count))
            } else if call.name != "clipslots_context" {
                guard let path = args["path"]?.stringValue else { throw AgentArtifactError.invalidPath }
                let key = try AgentArtifactKey(scope: configuration.scope, path: path)
                guard let record = try artifacts.record(for: key), !record.isDeleted else {
                    return .failure("当前项目/画布内没有此产物。", code: "ARTIFACT_NOT_FOUND")
                }
                result["artifact"] = metadata(record)
                if call.name == "artifact_read" {
                    guard let revision = args["revision"]?.stringValue, !revision.isEmpty,
                          revision.allSatisfy({ $0.isASCII && $0.isNumber }),
                          UInt64(revision) == record.revision, record.hasCurrentContent, let data = record.content else {
                        return .failure("产物修订已改变或正文尚未加载，请先读取元数据。", code: "ARTIFACT_REVISION_CONFLICT")
                    }
                    let total: Int
                    let range: Range<Int>
                    if let text = record.text {
                        total = text.count
                        range = try page(args, total: total, maximum: 8000, fallback: 4000)
                        result["encoding"] = "unicode_characters"
                        result["chunk"] = .string(String(text.dropFirst(range.lowerBound).prefix(range.count)))
                    } else {
                        total = data.count
                        range = try page(args, total: total, maximum: 8000, fallback: 4000)
                        result["encoding"] = "base64"
                        result["chunk"] = .string(data.subdata(in: range).base64EncodedString())
                    }
                    result["offset"] = .number(Double(range.lowerBound))
                    result["end"] = .number(Double(range.upperBound))
                    result["total"] = .number(Double(total))
                    result["next_offset"] = range.upperBound < total ? .number(Double(range.upperBound)) : .null
                }
            }
            return .init(content: try JSONValue.object(result).encodedText(), summary: "已读取项目资料")
        } catch { return .failure(error.localizedDescription, code: "SCOPED_READ_ERROR") }
    }

    private func metadata(_ record: AgentArtifactRecord) -> JSONValue {
        let state: String
        switch record.resourceState {
        case .missing: state = "missing"
        case .loading: state = "loading"
        case .ready: state = "ready"
        case .error: state = "error"
        }
        return ["path": .string(record.key.path), "title": .string(record.title),
                "revision": .string(String(record.revision)),
                "content_revision": record.contentRevision.map { .string(String($0)) } ?? .null,
                "mime_type": .string(record.mimeType), "state": .string(state),
                "current_content_available": .bool(record.hasCurrentContent),
                "bytes": .number(Double(record.content?.count ?? 0))]
    }

    private func page(_ args: JSONValue, total: Int, maximum: Int, fallback: Int) throws -> Range<Int> {
        let offset = args["offset"]?.intValue ?? 0
        let limit = args["limit"]?.intValue ?? fallback
        guard (args["offset"] == nil || args["offset"]?.intValue != nil),
              (args["limit"] == nil || args["limit"]?.intValue != nil),
              offset >= 0, offset <= total, limit > 0, limit <= maximum else {
            throw AgentExternalHandoffError.invalidConfiguration
        }
        return offset..<(offset + min(limit, total - offset))
    }
}
