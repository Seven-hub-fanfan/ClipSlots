import Foundation

/// A private, expiring mailbox between the stdio child and the active native canvas.
/// It only submits proposals; the native history transaction remains the sole writer.
public struct AgentLiveMCPLease: Codable, Equatable, Sendable {
    public let directory: URL
    public let token: String
    public let runID: String
    public let expiresAt: Date
    public let projectID: String
    public let canvasID: String
    public let sessionID: UUID
    public let snapshotID: UUID

    public init(directory: URL, token: String, runID: String, expiresAt: Date,
                scope: AgentArtifactScope, sessionID: UUID, snapshotID: UUID) {
        self.directory = directory; self.token = token; self.runID = runID; self.expiresAt = expiresAt
        projectID = scope.projectID; canvasID = scope.canvasID
        self.sessionID = sessionID; self.snapshotID = snapshotID
    }

    public static let environmentKey = "CLIPSLOTS_LIVE_MCP_LEASE"
}

public struct AgentLiveMCPRequest: Codable, Sendable {
    public let id: UUID
    public let token: String
    public let deadline: Date
    public let name: String
    public let arguments: JSONValue

    public init(id: UUID = UUID(), token: String, deadline: Date, name: String, arguments: JSONValue) {
        self.id = id; self.token = token; self.deadline = deadline; self.name = name; self.arguments = arguments
    }
}

public enum AgentLiveMCPMailbox {
    public static let maximumBytes = 1_000_000

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw AgentExternalHandoffError.invalidConfiguration }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL, within directory: URL) throws -> T {
        try JSONDecoder().decode(type, from: AgentArtifactFileAccess.read(url, within: directory,
            maximumBytes: maximumBytes))
    }

    public static var specs: [AgentToolSpec] {
        [
            .init(name: "preview_canvas_mutation",
                  description: "提交当前连接的画布变更预览。不会直接写入；用户在原生画布确认后才应用。使用 clipslots_context 返回的 project_id/session_id/live_run_id。",
                  parameters: ["type": "object", "properties": ["mutation": ["type": "object"]],
                               "required": ["mutation"], "additionalProperties": false], originLabel: "当前画布"),
            .init(name: "canvas_mutation_status",
                  description: "查询本连接提交的 mutation_id：pending、applied 或 dismissed。",
                  parameters: ["type": "object", "properties": ["mutation_id": ["type": "string"]],
                               "required": ["mutation_id"], "additionalProperties": false], originLabel: "当前画布")
        ]
    }
}

public final class AgentExternalLiveMCPTools: AgentToolExecuting, @unchecked Sendable {
    private let reader: AgentExternalReadOnlyMCPTools
    private let lease: AgentLiveMCPLease

    public init(reader: AgentExternalReadOnlyMCPTools, lease: AgentLiveMCPLease) throws {
        guard reader.configuration.sessionID == lease.sessionID,
              reader.configuration.scope.projectID == lease.projectID,
              reader.configuration.scope.canvasID == lease.canvasID,
              reader.snapshotID == lease.snapshotID, lease.directory.isFileURL,
              lease.token.count == 64, UUID(uuidString: lease.runID) != nil,
              lease.expiresAt > Date() else { throw AgentExternalHandoffError.invalidConfiguration }
        self.reader = reader; self.lease = lease
    }

    public func specs() -> [AgentToolSpec] { reader.specs() + AgentLiveMCPMailbox.specs }

    public func execute(call: AgentToolCall) async -> AgentToolResult {
        guard !Task.isCancelled, Date() < lease.expiresAt else {
            return .failure("当前画布连接已过期或取消，请重新连接。", code: "LIVE_CONNECTION_EXPIRED")
        }
        guard let marker = try? AgentLiveMCPMailbox.read(AgentLiveMCPLease.self,
            from: lease.directory.appendingPathComponent("lease.json"), within: lease.directory), marker == lease else {
            return .failure("当前画布连接已取消，请重新连接。", code: "LIVE_CONNECTION_UNAVAILABLE")
        }
        if reader.specs().contains(where: { $0.name == call.name }) {
            let response = await reader.execute(call: call)
            guard call.name == "clipslots_context", !response.isFailure,
                  var object = (try? JSONValue.decode(jsonText: response.content))?.objectValue else { return response }
            object["read_only"] = false
            object["writes_require_native_confirmation"] = true
            object["live_run_id"] = .string(lease.runID)
            object["expires_at"] = .string(ISO8601DateFormatter().string(from: lease.expiresAt))
            return .init(content: (try? JSONValue.object(object).encodedText()) ?? response.content, summary: "当前画布连接")
        }
        guard AgentLiveMCPMailbox.specs.contains(where: { $0.name == call.name }) else {
            return .failure("该工具未启用。", code: "TOOL_NOT_ENABLED")
        }
        var requestURL: URL?
        var responseURL: URL?
        defer {
            if let requestURL { try? FileManager.default.removeItem(at: requestURL) }
            if let responseURL { try? FileManager.default.removeItem(at: responseURL) }
        }
        do {
            let request = AgentLiveMCPRequest(token: lease.token, deadline: min(lease.expiresAt, Date().addingTimeInterval(10)),
                                             name: call.name, arguments: try call.arguments())
            requestURL = lease.directory.appendingPathComponent(request.id.uuidString + ".request")
            responseURL = lease.directory.appendingPathComponent(request.id.uuidString + ".response")
            // Validate an existing private host marker before creating any file.
            let marker = try AgentLiveMCPMailbox.read(AgentLiveMCPLease.self,
                from: lease.directory.appendingPathComponent("lease.json"), within: lease.directory)
            guard marker == lease else { throw AgentExternalHandoffError.invalidConfiguration }
            try AgentLiveMCPMailbox.write(request, to: requestURL!)
            while Date() < request.deadline {
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: responseURL!.path) {
                    let value = try AgentLiveMCPMailbox.read(JSONValue.self, from: responseURL!, within: lease.directory)
                    return .init(content: try value.encodedText(), isFailure: value["ok"]?.boolValue == false,
                                 summary: value["status"]?.stringValue ?? "画布调用")
                }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            return .failure("原生画布未及时响应，请检查应用仍在当前项目。", code: "LIVE_CONNECTION_TIMEOUT")
        } catch is CancellationError {
            return .failure("画布调用已取消。", code: "CANCELLED")
        } catch {
            return .failure("当前画布连接不可用，请重新连接。", code: "LIVE_CONNECTION_UNAVAILABLE")
        }
    }
}
