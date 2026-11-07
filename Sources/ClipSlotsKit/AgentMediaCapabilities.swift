import Foundation

/// Missing /models metadata means unknown, not text-only. Unknown models receive
/// the real image request and the provider decides whether it is supported.
public enum AgentMediaCapabilities {
    public static func imageSupport(endpoint: URL, model: String, reported: Bool? = nil) -> Bool? {
        if let reported { return reported }
        guard isOfficialDeepSeek(endpoint) else { return nil }
        // Verified 2026-11-06 against api-docs.deepseek.com/guides/vision/.
        switch model {
        case "deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp": return true
        case "deepseek-v4-pro": return false
        default: return nil
        }
    }

    public static func isOfficialDeepSeek(_ endpoint: URL) -> Bool {
        endpoint.scheme == "https" && endpoint.host?.lowercased() == "api.deepseek.com"
            && (endpoint.port == nil || endpoint.port == 443)
            && ["/chat/completions", "/v1/chat/completions"].contains(endpoint.path)
    }

    /// The bound here is on the encoded request, including base64 and history.
    /// Other providers retain an application memory bound; their own limits
    /// remain authoritative and are reported from the HTTP response.
    public static func validateRequestBytes(_ bytes: Data, endpoint: URL) throws {
        let limit = isOfficialDeepSeek(endpoint) ? 48 * 1024 * 1024 : 96 * 1024 * 1024
        guard bytes.count <= limit else {
            throw AgentOperationError(isOfficialDeepSeek(endpoint)
                ? "完整请求超过 DeepSeek 的 48 MiB 上限，请减少图片或新建对话。"
                : "完整请求超过 App 的 96 MiB 内存保护上限，请减少附件或新建对话。")
        }
    }
}
