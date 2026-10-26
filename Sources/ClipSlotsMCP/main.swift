import Foundation
import ClipSlotsKit

// Dedicated stdio executable. Never invokes the ClipSlots business CLI.
let arguments = Array(CommandLine.arguments.dropFirst())
Task.detached {
    do {
        if arguments.isEmpty || arguments == ["--slots"] {
            await AgentMCPServer.serve(tools: AgentNativeSlotTools())
        } else if arguments == ["--slots", "--read-only"] {
            await AgentMCPServer.serve(tools: AgentAccessTools(base: AgentNativeSlotTools(), mode: .allDirectoriesReadOnly))
        } else {
            let flags = arguments.first == "--mcp" ? Array(arguments.dropFirst()) : arguments
            let config = try AgentExternalReadOnlyMCPConfiguration.parse(arguments: flags)
            if let encoded = ProcessInfo.processInfo.environment[AgentLiveMCPLease.environmentKey] {
                let lease = try JSONDecoder().decode(AgentLiveMCPLease.self, from: Data(encoded.utf8))
                let reader = try AgentExternalReadOnlyMCPTools(configuration: config)
                let live = try AgentExternalLiveMCPTools(reader: reader, lease: lease)
                await AgentMCPServer.serve(tools: flags.contains("--read-only") ? AgentMCPReadOnlyTools(base: live) : live)
            } else {
                try await AgentMCPServer.serveReadOnly(configuration: config)
            }
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("ClipSlots MCP：\(error.localizedDescription)\n".utf8))
        exit(2)
    }
}
dispatchMain()
