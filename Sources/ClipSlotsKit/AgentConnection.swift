import Foundation
import CryptoKit

public enum AgentAPIProvider: String, CaseIterable, Sendable {
    case claude, gemini, gpt, deepseek, grok, kimi, custom
    public var name: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .gpt: return "GPT"
        case .deepseek: return "DeepSeek"
        case .grok: return "Grok"
        case .kimi: return "Kimi"
        case .custom: return "自定义 API"
        }
    }
    public var baseURL: String {
        switch self {
        case .claude: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .gpt: return "https://api.openai.com/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .grok: return "https://api.x.ai/v1"
        case .kimi: return "https://api.moonshot.ai/v1"
        case .custom: return ""
        }
    }
    public var defaultModel: String {
        switch self {
        case .grok: return "grok-4.7"
        case .kimi: return "kimi-k3"
        default: return ""
        }
    }
    public var contract: ModelAPIContract {
        switch self {
        case .claude: return .anthropicMessages
        case .gemini: return .geminiContent
        default: return .chatCompletions
        }
    }

    public func profile(baseURL: String, model: String) throws -> ModelProfile {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        try ModelProfile.validateURL(base)
        guard let url = URL(string: base), url.query == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")) else {
            throw ModelWorkspaceError.invalid("请填写 HTTPS 地址；本机接口可以使用 HTTP。")
        }
        let suffix: String
        switch self {
        case .claude: suffix = "/messages"
        case .gemini: suffix = "/models/{model}:generateContent"
        default: suffix = "/chat/completions"
        }
        if base.hasSuffix(suffix) { base.removeLast(suffix.count) }
        let endpoint = base + suffix
        var profile = ModelProfile()
        profile.id = "agent-api-" + rawValue
        profile.name = name
        profile.endpoint = endpoint
        profile.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.contract = contract
        profile.imageInputCapability = AgentMediaCapabilities.imageSupport(
            endpoint: URL(string: endpoint)!, model: profile.model)
        profile.supportsImages = profile.imageInputCapability == true
        profile.timeout = 120
        if self == .claude { profile.authHeader = "x-api-key"; profile.authPrefix = "" }
        if self == .gemini { profile.authHeader = "x-goog-api-key"; profile.authPrefix = "" }
        profile.credentialService = AgentKeychain.service
        if self == .deepseek && base == self.baseURL {
            profile.credentialAccount = AgentKeychain.account
        } else {
            let digest = SHA256.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
            profile.credentialAccount = "api-\(rawValue)-\(digest)"
        }
        try profile.validate()
        return profile
    }
}

/// Explicit sidebar/workspace connections override only that scope. Existing
/// model-hub defaults and the legacy DeepSeek credentials are left intact.
public enum AgentConnectionPreferences {
    public static func key(scope: String) -> String { "agent.connection.\(scope).profile" }
    public static func profile(scope: String, defaults: UserDefaults = .standard) -> ModelProfile? {
        guard let data = defaults.data(forKey: key(scope: scope)),
              let profile = try? JSONDecoder().decode(ModelProfile.self, from: data),
              (try? profile.validate()) != nil else { return nil }
        return profile
    }
    public static func save(_ profile: ModelProfile, scope: String, defaults: UserDefaults = .standard) throws {
        try profile.validate()
        defaults.set(try JSONEncoder().encode(profile), forKey: key(scope: scope))
    }
    public static func provider(_ profile: ModelProfile?) -> AgentAPIProvider? {
        profile.flatMap { AgentAPIProvider(rawValue: $0.id.replacingOccurrences(of: "agent-api-", with: "")) }
    }
}

/// The same native wire conversion is used by connection verification and chat.
public struct AgentProviderTransport: AgentTransport {
    public let profile: ModelProfile
    private let http: any ModelHTTPTransport
    private let streaming: any AgentTransport
    public init(profile: ModelProfile, http: any ModelHTTPTransport = ModelURLSessionTransport(),
                streaming: any AgentTransport = URLSessionAgentTransport()) {
        self.profile = profile; self.http = http; self.streaming = streaming
    }
    public func request(_ chat: URLRequest) throws -> URLRequest {
        var modified = chat
        let modelID = profile.model.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        modified.url = URL(string: profile.endpoint.replacingOccurrences(of: "{model}", with: modelID))
        let bearer = chat.value(forHTTPHeaderField: "Authorization") ?? ""
        modified.setValue(nil, forHTTPHeaderField: "Authorization")
        if profile.requiresKey {
            let key = bearer.hasPrefix("Bearer ") ? String(bearer.dropFirst(7)) : bearer
            modified.setValue(profile.authPrefix + key, forHTTPHeaderField: profile.authHeader)
        }
        if let body = modified.httpBody, case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: body) {
            for (name, value) in profile.parameters where !["messages", "model", "stream", "tools", "tool_choice"].contains(name) {
                fields[name] = value
            }
            if profile.contract == .geminiContent, let messages = fields["messages"]?.arrayValue {
                var names: [String: JSONValue] = [:]
                fields["messages"] = .array(messages.map { message in
                    for call in message["tool_calls"]?.arrayValue ?? [] {
                        if let id = call["id"]?.stringValue { names[id] = call["function"]?["name"] }
                    }
                    if let id = message["tool_call_id"]?.stringValue, let name = names[id], var value = message.objectValue {
                        value["name"] = name; return .object(value)
                    }
                    return message
                })
            }
            modified.httpBody = try JSONEncoder().encode(ModelTextWire.body(fields, contract: profile.contract))
        }
        for (name, value) in profile.headers ?? [:] { modified.setValue(value, forHTTPHeaderField: name) }
        if profile.contract == .anthropicMessages { modified.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        modified.timeoutInterval = profile.timeout
        if let bytes = modified.httpBody, let url = modified.url {
            try AgentMediaCapabilities.validateRequestBytes(bytes, endpoint: url)
        }
        return modified
    }
    public func stream(request: URLRequest) async throws -> AgentHTTPStream {
        var modified = try self.request(request)
        if profile.contract != .chatCompletions {
            modified.setValue("application/json", forHTTPHeaderField: "Accept")
            let frozen = modified
            let (data, status) = try await ModelRequestBudget.shared.withPermit(profile: profile) { try await http.send(frozen) }
            guard (200...299).contains(status) else {
                return .init(statusCode: status, chunks: .init { $0.yield(data); $0.finish() })
            }
            let assistant = try ModelTextWire.assistant(JSONDecoder().decode(JSONValue.self, from: data), contract: profile.contract)
            var delta = assistant.objectValue ?? [:]
            if let calls = delta["tool_calls"]?.arrayValue {
                delta["tool_calls"] = .array(calls.enumerated().map { index, call in
                    var value = call.objectValue ?? [:]; value["index"] = .number(Double(index)); return .object(value)
                })
            }
            let chunk: JSONValue = ["choices": [["index": 0, "delta": .object(delta), "finish_reason": assistant["tool_calls"] == nil ? "stop" : "tool_calls"]]]
            let text = "data: " + (try chunk.encodedText()) + "\n\ndata: [DONE]\n\n"
            return .init(statusCode: status, chunks: .init { $0.yield(Data(text.utf8)); $0.finish() })
        }
        // Preserve streaming and admission limits for existing Chat providers.
        let frozen = modified
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    try await ModelRequestBudget.shared.withPermit(profile: profile) {
                        let response = try await streaming.stream(request: frozen)
                        guard (200...299).contains(response.statusCode) else {
                            var bytes = Data()
                            for try await data in response.chunks {
                                let remaining = max(0, 65_536 - bytes.count)
                                bytes.append(data.prefix(remaining))
                                if bytes.count >= 65_536 { break }
                            }
                            let key = profile.requiresKey
                                ? frozen.value(forHTTPHeaderField: profile.authHeader).map {
                                    $0.hasPrefix(profile.authPrefix) ? String($0.dropFirst(profile.authPrefix.count)) : $0
                                } : nil
                            let (message, code) = AgentService.parseErrorBody(bytes, redacting: key)
                            throw AgentError.http(status: response.statusCode, message: message, code: code)
                        }
                        for try await data in response.chunks { continuation.yield(data) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return .init(statusCode: 200, chunks: chunks)
    }

    public func verify(apiKey: String) async throws {
        guard !apiKey.isEmpty, !apiKey.contains("\n"), !apiKey.contains("\r") else {
            throw ModelWorkspaceError.credential
        }
        var chat = URLRequest(url: URL(string: profile.endpoint)!)
        chat.httpMethod = "POST"
        chat.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let fields: [String: JSONValue] = ["model": .string(profile.model), "stream": false,
            "messages": [["role": "user", "content": "Reply OK."]]]
        chat.httpBody = try JSONEncoder().encode(JSONValue.object(fields))
        var probe = try request(chat)
        probe.timeoutInterval = 45
        let (data, status) = try await http.send(probe)
        try Task.checkCancellation()
        guard (200...299).contains(status) else {
            // Do not reflect server bodies that might contain supplied credentials.
            throw AgentError.http(status: status, message: nil, code: nil)
        }
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        let assistant = try ModelTextWire.assistant(root, contract: profile.contract)
        guard assistant["content"]?.stringValue?.isEmpty == false else {
            throw AgentError.invalidResponse("接口没有返回有效的对话内容，请检查模型 ID。")
        }
    }
}
