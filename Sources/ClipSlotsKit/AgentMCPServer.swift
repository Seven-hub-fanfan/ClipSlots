import Foundation

/// Stdio MCP adapter for resumed desktop threads, which cannot add dynamic tools.
/// Reuses the same registry and CLI locking as the app; does not modify client configuration.
public enum AgentMCPServer {
    public static func response(to request: JSONValue, tools: AgentToolExecuting) async -> JSONValue? {
        guard let id = request["id"] else { return nil }
        let result: JSONValue
        switch request["method"]?.stringValue {
        case "initialize":
            result = ["protocolVersion": "2024-11-05", "capabilities": ["tools": [:]],
                      "serverInfo": ["name": "clipslots", "version": "2.17.37"]]
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
        let registry = AgentToolRegistry(builtin: AgentBuiltinTools(cliPath: cliPath),
                                         skills: AgentSkillTools(enabledSkills: skills))
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
