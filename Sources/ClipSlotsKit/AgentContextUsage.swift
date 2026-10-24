import Foundation

/// Category counts are tokenizer estimates; the provider's prompt total stays authoritative.
public struct AgentContextUsage: Equatable, Sendable {
    public let model: String
    public let endpoint: URL
    public let workspace: Int
    public let toolsAndAgent: Int
    public let history: Int
    public let system: Int
    public var estimatedTotal: Int { workspace + toolsAndAgent + history + system }

    public init(model: String, endpoint: URL, history messages: [AgentMessage],
                systemPrompt: String, toolSchemas: String) {
        self.model = model
        self.endpoint = endpoint
        var workspace = 0, tools = Self.estimate(toolSchemas), history = 0
        for message in messages where message.isWireVisible {
            let plain = Self.estimate(message.content + (message.reasoning ?? ""))
            if message.role == .tool || !message.toolCalls.isEmpty {
                tools += plain + message.toolCalls.reduce(0) { $0 + Self.estimate($1.argumentsJSON + $1.name) }
            } else { history += plain }
            // wireContent strips preview bytes and local paths before measuring the extra context.
            workspace += max(0, Self.estimate(message.wireContent) - Self.estimate(message.content))
        }
        self.workspace = workspace
        toolsAndAgent = tools
        self.history = history
        system = Self.estimate(systemPrompt)
    }

    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var ascii = 0, unicode = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { unicode += 1 }
        }
        return max(1, Int(ceil(Double(ascii) / 4 + Double(unicode) * 1.5)))
    }
}
