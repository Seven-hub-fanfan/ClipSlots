import Foundation
import CryptoKit

/// Safe, display-only subset of config/read. Never persist the raw configuration.
public struct CodexWorkspaceSettings: Sendable {
    public var model: String
    public var provider: String
    public var effort: String
    public var requiresOpenAIAuth: Bool
    public init(_ response: JSONValue, provider override: String? = nil) {
        let config = response["config"] ?? [:]
        model = config["model"]?.stringValue ?? ""
        provider = override ?? config["model_provider"]?.stringValue ?? "openai"
        effort = config["model_reasoning_effort"]?.stringValue ?? ""
        requiresOpenAIAuth = provider == "openai"
            || config["model_providers"]?[provider]?["requires_openai_auth"]?.boolValue == true
    }
}

public struct CodexThreadSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let cwd: String
    public let model: String?
    public let provider: String?
    public let effort: String?
    public let projectID: String?
    public let updatedAt: Date
    public let isActive: Bool
    public let historyMode: String?
    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.id = id
        let name = json["name"]?.stringValue ?? ""
        let preview = json["preview"]?.stringValue ?? ""
        title = String((name.isEmpty ? (preview.isEmpty ? "未命名会话" : preview) : name).prefix(100))
        cwd = json["cwd"]?.stringValue ?? ""
        model = json["model"]?.stringValue
        provider = json["modelProvider"]?.stringValue
        effort = json["reasoningEffort"]?.stringValue
        projectID = json["projectId"]?.stringValue
        updatedAt = Date(timeIntervalSince1970: Double(json["updatedAt"]?.intValue ?? 0))
        isActive = json["status"]?["type"]?.stringValue == "active"
        historyMode = json["historyMode"]?.stringValue
    }
}

public struct CodexProject: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var path: String
    public var isOfficial: Bool
    public init(id: String, name: String, path: String, isOfficial: Bool) {
        self.id = id; self.name = name; self.path = path; self.isOfficial = isOfficial
    }
}

public struct CodexConnection: Sendable {
    public let server: CodexAppServer
    public let executable: String
    public let fallbackReason: String?

    /// Every connection rechecks the installed binary. Updating the app on disk
    /// never changes an in-flight process. Fallback is only before any user turn.
    public static func open(_ configuration: CodexServerConfiguration) async throws -> CodexConnection {
        let primary = CodexAppServer()
        do {
            try await primary.start(configuration)
            let config = try await primary.request("config/read", params: ["includeLayers": false], timeout: 12)
            guard case .object = config["config"] else { throw CodexServerError("Codex 配置协议不兼容。") }
            return .init(server: primary, executable: configuration.executable, fallbackReason: nil)
        } catch {
            await primary.close()
            try Task.checkCancellation()
            guard let fallback = configuration.fallbackExecutable, fallback != configuration.executable,
                  FileManager.default.isExecutableFile(atPath: fallback) else { throw error }
            var backup = configuration
            backup.executable = fallback
            let server = CodexAppServer()
            do {
                try await server.start(backup)
                let config = try await server.request("config/read", params: ["includeLayers": false], timeout: 12)
                guard case .object = config["config"] else { throw CodexServerError("内置 Codex 配置协议不兼容。") }
                return .init(server: server, executable: fallback,
                             fallbackReason: "桌面引擎暂不可用，已回退内置版本；下次连接会重新检查。")
            } catch { await server.close(); throw error }
        }
    }
}

public enum CodexWorkspaceAPI {
    /// Cursor loops fail explicitly instead of presenting an incomplete list as complete.
    public static func pages(_ server: CodexAppServer, method: String,
                             params: [String: JSONValue] = [:]) async throws -> [JSONValue] {
        var all: [JSONValue] = []
        var seen = Set<String>()
        var parameters = params
        if parameters["limit"] == nil { parameters["limit"] = 100 }
        for _ in 0..<500 {
            try Task.checkCancellation()
            let page = try await server.request(method, params: .object(parameters))
            guard let data = page["data"]?.arrayValue else { throw CodexServerError("Codex 返回的列表格式不兼容：\(method)") }
            all += data
            guard let cursor = page["nextCursor"]?.stringValue, !cursor.isEmpty else { return all }
            guard seen.insert(cursor).inserted else { throw CodexServerError("Codex 分页游标重复，请刷新后重试。") }
            parameters["cursor"] = .string(cursor)
        }
        throw CodexServerError("会话数据超过本次读取上限，请缩小搜索范围。")
    }

    public static func threads(_ server: CodexAppServer) async throws -> [CodexThreadSummary] {
        // Empty provider filter includes custom providers, unlike the server default.
        let rows = try await pages(server, method: "thread/list",
                                   params: ["modelProviders": [], "sortKey": "updated_at"])
        var seen = Set<String>()
        return rows.compactMap(CodexThreadSummary.init).filter { seen.insert($0.id).inserted }
    }

    public static func projects(_ server: CodexAppServer, threads: [CodexThreadSummary]) async throws -> [CodexProject] {
        var projects: [CodexProject] = []
        do {
            projects = try await pages(server, method: "project/list").compactMap { row in
                guard let id = row["id"]?.stringValue,
                      let path = row["roots"]?.arrayValue?.first?["path"]?.stringValue else { return nil }
                return CodexProject(id: id, name: row["name"]?.stringValue ?? URL(fileURLWithPath: path).lastPathComponent,
                                    path: path, isOfficial: true)
            }
        } catch let error as CodexServerError where error.isUnsupported { }
        var paths = Set(projects.map(\.path))
        for thread in threads where !thread.cwd.isEmpty && paths.insert(thread.cwd).inserted {
            projects.append(.init(id: thread.cwd, name: URL(fileURLWithPath: thread.cwd).lastPathComponent,
                                  path: thread.cwd, isOfficial: false))
        }
        return projects
    }

    public static func history(_ server: CodexAppServer, id: String) async throws -> (CodexThreadSummary, [AgentMessage]) {
        let response = try await server.request("thread/read", params: ["threadId": .string(id), "includeTurns": false])
        guard let value = response["thread"], let thread = CodexThreadSummary(value) else {
            throw CodexServerError("Codex 未返回会话详情。")
        }
        let items: [JSONValue]
        do {
            items = try await pages(server, method: "thread/items/list",
                                    params: ["threadId": .string(id), "sortDirection": "asc"])
                .compactMap { $0["item"] }
        } catch let error as CodexServerError where error.isUnsupported {
            let legacy = try await server.request("thread/read", params: ["threadId": .string(id), "includeTurns": true])
            items = (legacy["thread"]?["turns"]?.arrayValue ?? []).flatMap { $0["items"]?.arrayValue ?? [] }
        }
        return (thread, transcript(items, threadID: id))
    }

    public static func createProject(_ server: CodexAppServer, name: String, path: String,
                                     key: String = UUID().uuidString) async throws {
        _ = try await server.request("project/create", params: [
            "idempotencyKey": .string(key), "name": .string(name),
            "roots": [["path": .string(path)]]
        ])
    }

    public static func renameProject(_ server: CodexAppServer, id: String, name: String) async throws {
        _ = try await server.request("project/update", params: ["projectId": .string(id), "name": .string(name)])
    }

    public static func deleteProject(_ server: CodexAppServer, id: String) async throws {
        _ = try await server.request("project/delete", params: ["projectId": .string(id)])
    }

    /// Stable item identities prevent refreshes from rebuilding every rendered row.
    public static func stableID(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public static func transcript(_ items: [JSONValue], threadID: String) -> [AgentMessage] {
        var output: [AgentMessage] = []
        var seen = Set<String>()
        for (index, item) in items.enumerated() {
            let key = item["id"]?.stringValue ?? "item-\(index)"
            guard seen.insert(key).inserted else { continue }
            let id = stableID(threadID + "/" + key)
            let type = item["type"]?.stringValue ?? "unknown"
            switch type {
            case "userMessage":
                let text = (item["content"]?.arrayValue ?? []).compactMap { part -> String? in
                    switch part["type"]?.stringValue {
                    case "text": return part["text"]?.stringValue
                    case "localImage": return part["path"]?.stringValue.map { "📎 " + $0 }
                    case "image": return "📎 图片"
                    case "skill": return part["name"]?.stringValue.map { "$" + $0 }
                    case "mention": return part["name"]?.stringValue.map { "@" + $0 }
                    default: return nil
                    }
                }.joined(separator: "\n")
                output.append(AgentMessage(id: id, role: .user, content: text))
            case "agentMessage", "plan":
                output.append(AgentMessage(id: id, role: .assistant, content: item["text"]?.stringValue ?? ""))
            case "reasoning":
                let summary = (item["summary"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n")
                if !summary.isEmpty { output.append(AgentMessage(id: id, role: .assistant, content: "", reasoning: summary)) }
            case "commandExecution", "mcpToolCall", "dynamicToolCall", "fileChange", "webSearch":
                let name = item["tool"]?.stringValue ?? type
                let arguments = item["command"]?.stringValue ?? item["query"]?.stringValue
                    ?? (try? item["arguments"]?.encodedText()) ?? type
                let call = AgentToolCall(id: key, name: name, argumentsJSON: arguments)
                output.append(AgentMessage(id: id, role: .assistant, content: "", toolCalls: [call]))
                let status = item["status"]?.stringValue ?? "completed"
                let failed = ["failed", "declined", "inProgress"].contains(status) || item["success"]?.boolValue == false
                    || (item["exitCode"]?.intValue ?? 0) != 0
                let result = item["aggregatedOutput"]?.stringValue
                    ?? (try? (item["result"] ?? item["contentItems"] ?? item["error"])?.encodedText()) ?? status
                output.append(AgentMessage(id: stableID(threadID + "/" + key + "/result"), role: .tool,
                    content: String(result.prefix(16_000)), toolCallId: key, toolName: name, isFailure: failed))
            case "contextCompaction":
                output.append(AgentMessage(id: id, role: .assistant, content: "上下文已压缩"))
            case "enteredReviewMode", "exitedReviewMode":
                output.append(AgentMessage(id: id, role: .assistant, content: item["review"]?.stringValue ?? "代码审查"))
            default:
                output.append(AgentMessage(id: id, role: .assistant, content: "桌面记录 · \(type)（此项目暂不支持展开）"))
            }
        }
        return output
    }
}
