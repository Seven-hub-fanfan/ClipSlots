import Foundation

/// Convert the established Chat message shape to documented native protocols.
public enum ModelTextWire {
    public static func body(_ chat: [String: JSONValue], contract: ModelAPIContract) -> JSONValue {
        if contract == .chatCompletions { return .object(chat) }
        var result = chat
        let messages = result.removeValue(forKey: "messages")?.arrayValue ?? []
        result.removeValue(forKey: "stream")
        result.removeValue(forKey: "stream_options")
        let tools = result.removeValue(forKey: "tools")?.arrayValue ?? []
        result.removeValue(forKey: "tool_choice")
        let system = messages.filter { $0["role"]?.stringValue == "system" }.compactMap { $0["content"]?.stringValue }.joined(separator: "\n")
        let turns = messages.filter { $0["role"]?.stringValue != "system" }
        func parts(_ value: JSONValue?, format: ModelAPIContract) -> JSONValue {
            let input = value?.arrayValue ?? [["type": "text", "text": value ?? ""]]
            return .array(input.compactMap { part in
                if let text = part["text"]?.stringValue, !text.isEmpty {
                    return format == .geminiContent ? ["text": .string(text)] : ["type": .string(format == .responses ? "input_text" : "text"), "text": .string(text)]
                }
                guard let url = part["image_url"]?["url"]?.stringValue else { return nil }
                if format == .responses { return ["type": "input_image", "image_url": .string(url)] }
                guard let comma = url.firstIndex(of: ","), url.hasPrefix("data:") else { return nil }
                let mime = String(url.dropFirst(5).prefix { $0 != ";" })
                let encoded = String(url[url.index(after: comma)...])
                return format == .geminiContent
                    ? ["inlineData": ["mimeType": .string(mime), "data": .string(encoded)]]
                    : ["type": "image", "source": ["type": "base64", "media_type": .string(mime), "data": .string(encoded)]]
            })
        }
        switch contract {
        case .responses:
            if !system.isEmpty { result["instructions"] = .string(system) }
            result["input"] = .array(turns.flatMap { message -> [JSONValue] in
                if message["role"]?.stringValue == "tool" {
                    return [["type": "function_call_output", "call_id": message["tool_call_id"] ?? "", "output": message["content"] ?? ""]]
                }
                var items: [JSONValue] = []
                if message["content"]?.stringValue?.isEmpty == false || message["content"]?.arrayValue != nil {
                    items.append(["role": message["role"] ?? "user", "content": message["role"]?.stringValue == "assistant" ? message["content"] ?? "" : parts(message["content"], format: contract)])
                }
                items += (message["tool_calls"]?.arrayValue ?? []).map {
                    ["type": "function_call", "call_id": $0["id"] ?? "", "name": $0["function"]?["name"] ?? "", "arguments": $0["function"]?["arguments"] ?? "{}"]
                }
                return items
            })
            if !tools.isEmpty { result["tools"] = .array(tools.map {
                var fields = $0["function"]?.objectValue ?? [:]; fields["type"] = "function"; return .object(fields)
            }) }
        case .anthropicMessages:
            if !system.isEmpty { result["system"] = .string(system) }
            result["max_tokens"] = result["max_tokens"] ?? 1024
            result["messages"] = .array(turns.map { message in
                if message["role"]?.stringValue == "tool" {
                    return ["role": "user", "content": [["type": "tool_result", "tool_use_id": message["tool_call_id"] ?? "", "content": message["content"] ?? ""]]]
                }
                var content = parts(message["content"], format: contract).arrayValue ?? []
                content += (message["tool_calls"]?.arrayValue ?? []).map {
                    ["type": "tool_use", "id": $0["id"] ?? "", "name": $0["function"]?["name"] ?? "",
                     "input": (try? JSONValue.decode(jsonText: $0["function"]?["arguments"]?.stringValue ?? "{}")) ?? .object([:])]
                }
                return ["role": message["role"] ?? "user", "content": .array(content)]
            })
            if !tools.isEmpty { result["tools"] = .array(tools.map {
                ["name": $0["function"]?["name"] ?? "", "description": $0["function"]?["description"] ?? "",
                 "input_schema": $0["function"]?["parameters"] ?? .object([:])]
            }) }
        case .geminiContent:
            result.removeValue(forKey: "model")
            if !system.isEmpty { result["systemInstruction"] = ["parts": [["text": .string(system)]]] }
            result["contents"] = .array(turns.map { message in
                if message["role"]?.stringValue == "tool" {
                    return ["role": "user", "parts": [["functionResponse": ["name": message["name"] ?? "tool",
                        "response": ["result": message["content"] ?? ""]]]]]
                }
                var content = parts(message["content"], format: contract).arrayValue ?? []
                content += (message["tool_calls"]?.arrayValue ?? []).map {
                    ["functionCall": ["name": $0["function"]?["name"] ?? "",
                        "args": (try? JSONValue.decode(jsonText: $0["function"]?["arguments"]?.stringValue ?? "{}")) ?? .object([:])]]
                }
                return ["role": message["role"]?.stringValue == "assistant" ? "model" : "user", "parts": .array(content)]
            })
            if !tools.isEmpty { result["tools"] = [["functionDeclarations": .array(tools.map { $0["function"] ?? .object([:]) })]] }
        default: break
        }
        return .object(result)
    }
    public static func assistant(_ root: JSONValue, contract: ModelAPIContract) throws -> JSONValue {
        if contract == .chatCompletions, let value = root["choices"]?.arrayValue?.first?["message"] { return value }
        var text: [String] = [], calls: [JSONValue] = []
        func call(_ id: String?, _ name: JSONValue?, _ args: JSONValue?, encoded: Bool = false) -> JSONValue {
            ["id": .string(id ?? UUID().uuidString), "type": "function",
             "function": ["name": name ?? "", "arguments": encoded ? args ?? "{}" : .string((try? (args ?? .object([:])).encodedText()) ?? "{}")]]
        }
        switch contract {
        case .responses:
            for item in root["output"]?.arrayValue ?? [] {
                if item["type"]?.stringValue == "function_call" {
                    calls.append(call(item["call_id"]?.stringValue, item["name"], item["arguments"], encoded: true))
                }
                text += (item["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
            }
        case .anthropicMessages:
            for part in root["content"]?.arrayValue ?? [] {
                if let value = part["text"]?.stringValue { text.append(value) }
                if part["type"]?.stringValue == "tool_use" { calls.append(call(part["id"]?.stringValue, part["name"], part["input"])) }
            }
        case .geminiContent:
            for part in root["candidates"]?.arrayValue?.first?["content"]?["parts"]?.arrayValue ?? [] {
                if part["thought"]?.boolValue != true, let value = part["text"]?.stringValue { text.append(value) }
                if let function = part["functionCall"] { calls.append(call(function["id"]?.stringValue, function["name"], function["args"])) }
            }
        default: break
        }
        guard !text.isEmpty || !calls.isEmpty else { throw ModelWorkspaceError.response }
        var fields: [String: JSONValue] = ["role": "assistant", "content": .string(text.joined(separator: "\n"))]
        if !calls.isEmpty { fields["tool_calls"] = .array(calls) }
        return .object(fields)
    }
}
