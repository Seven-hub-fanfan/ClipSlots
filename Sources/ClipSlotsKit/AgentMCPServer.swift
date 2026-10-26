import Foundation

/// Stdio protocol adapter shared by the dedicated MCP binary and compatibility CLI.
public enum AgentMCPServer {
    public static var version: String {
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let plist = executable?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        if let plist, let data = try? Data(contentsOf: plist),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let value = info["CFBundleShortVersionString"] as? String { return value }
        return "2.17.94"
    }

    public static func response(to request: JSONValue, tools: AgentToolExecuting) async -> JSONValue? {
        guard let id = request["id"] else { return nil }
        let result: JSONValue
        switch request["method"]?.stringValue {
        case "initialize":
            let requested = request["params"]?["protocolVersion"]?.stringValue ?? ""
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
            result = ["protocolVersion": .string(supported.contains(requested) ? requested : "2025-11-25"),
                      "capabilities": ["tools": [:]],
                      "serverInfo": ["name": "clipslots", "version": .string(version)]]
        case "ping": result = [:]
        case "tools/list":
            result = ["tools": .array(tools.specs().map {
                ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.parameters]
            })]
        case "tools/call":
            let p = request["params"] ?? [:]
            let name = p["name"]?.stringValue ?? ""
            let response: AgentToolResult
            if tools.specs().contains(where: { $0.name == name }) {
                response = await tools.execute(call: .init(id: id.stringValue ?? UUID().uuidString, name: name,
                    argumentsJSON: (try? (p["arguments"] ?? [:]).encodedText()) ?? "{}"))
            } else { response = .failure("该工具未启用。", code: "TOOL_NOT_ENABLED") }
            result = ["content": [["type": "text", "text": .string(response.content)]],
                      "isError": .bool(response.isFailure)]
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    public static func serve(cliPath: String, bundlePath: String, skillSlugs: Set<String>) async {
        let skills = AgentSkillCatalog.discover(bundlePath: bundlePath).filter { skillSlugs.contains($0.slug) }
        let registry = AgentToolRegistry(builtin: AgentNativeSlotTools(), skills: AgentSkillTools(enabledSkills: skills))
        await serve(tools: registry)
    }

    public static func serveReadOnly(configuration: AgentExternalReadOnlyMCPConfiguration,
                                     dataRoot: URL = ClipSlotsPaths.dataRoot) async throws {
        let tools = try AgentExternalReadOnlyMCPTools(configuration: configuration, dataRoot: dataRoot)
        await serve(tools: tools)
    }

    public static func serve(tools: AgentToolExecuting) async {
        var buffer = Data()
        while true {
            let data = FileHandle.standardInput.availableData
            if data.isEmpty { return }
            buffer.append(data)
            guard buffer.count <= 2_000_000 else { return }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let request = try? JSONDecoder().decode(JSONValue.self, from: line),
                      let response = await response(to: request, tools: tools),
                      var encoded = try? JSONEncoder().encode(response) else { continue }
                encoded.append(10)
                do { try FileHandle.standardOutput.write(contentsOf: encoded) } catch { return }
            }
        }
    }
}

/// Restricts a connected live host without granting access to its write tools.
public final class AgentMCPReadOnlyTools: AgentToolExecuting {
    private let base: AgentToolExecuting
    private let names: Set<String>
    public init(base: AgentToolExecuting) {
        self.base = base
        names = AgentNativeSlotTools.readers.union(CanvasAgentActionTools.readers).union([
            "clipslots_context", "artifact_list", "artifact_metadata", "artifact_read",
            "canvas_overview", "canvas_nodes", "canvas_edges", "canvas_groups", "canvas_piles",
            "canvas_read_group", "canvas_read_node", "canvas_read_run", "canvas_mutation_status"
        ])
    }
    public func specs() -> [AgentToolSpec] { base.specs().filter { names.contains($0.name) } }
    public func execute(call: AgentToolCall) async -> AgentToolResult {
        guard names.contains(call.name) else { return .failure("此 MCP 连接为只读。", code: "READ_ONLY_SCOPE") }
        let result = await base.execute(call: call)
        if call.name == "clipslots_context", !result.isFailure,
           var value = (try? JSONValue.decode(jsonText: result.content))?.objectValue {
            value["read_only"] = true
            value["writes_enabled"] = false
            return .init(content: (try? JSONValue.object(value).encodedText()) ?? result.content, summary: result.summary)
        }
        return result
    }
}
