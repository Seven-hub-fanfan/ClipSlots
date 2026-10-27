import Foundation

public struct ModelServiceConnection: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var name = ""
    public var baseURL = ""
    public var discoveryURL = ""
    public var discoveryPath = "data"
    public var authHeader = "Authorization"
    public var authPrefix = "Bearer "
    public var requiresKey = true
    public var keyAccount = UUID().uuidString
    public var timeout: Double = 120
    public var concurrency = 2
    public var enabled = true
    public init() {}
    public static let keyService = "com.clipslots.model-services"
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...14).contains(concurrency),
              (5...1800).contains(timeout), !authHeader.isEmpty,
              !(authHeader + authPrefix).contains("\n"), !(authHeader + authPrefix).contains("\r") else {
            throw ModelWorkspaceError.invalid("请填写服务名称，并检查认证、并发与超时。")
        }
        try ModelProfile.validateURL(baseURL)
        if !discoveryURL.isEmpty { try ModelProfile.validateURL(url(discoveryURL)) }
    }
    public func url(_ path: String) -> String {
        if path.hasPrefix("https://") || path.hasPrefix("http://") { return path }
        return baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// Node semantics map to explicit wire keys, never TapNow's private defaults.
public struct ModelInputMapping: Codable, Equatable, Sendable {
    public var promptField = "prompt"
    public var parameterFields: [String: String] = [:]
    public var referenceFields: [String: String] = [:]
    public var referenceEncoding = "dataURL"
    public var referenceShape = "array"
    public init() {}
    public func validate() throws {
        let reserved = ["model", "messages", "stream", "authorization", "api_key", "token", "secret", "password"]
        let keys = [promptField] + Array(parameterFields.values) + Array(referenceFields.values)
        guard keys.allSatisfy({ !$0.isEmpty && !reserved.contains($0.lowercased()) }),
              Set(keys).count == keys.count, ["dataURL", "base64Object"].contains(referenceEncoding),
              ["array", "single"].contains(referenceShape) else {
            throw ModelWorkspaceError.invalid("输入映射字段重复、保留字段或参考编码无效。")
        }
    }
}

public enum ModelHubResolver {
    public static func resolve(_ profile: ModelProfile, services: [ModelServiceConnection]) throws -> ModelProfile {
        guard let id = profile.serviceID else { try profile.validate(); return profile }
        guard let service = services.first(where: { $0.id == id && $0.enabled }) else {
            throw ModelWorkspaceError.invalid("共享服务未配置或已停用。")
        }
        try service.validate()
        var result = profile
        result.endpoint = service.url(profile.endpoint)
        if profile.contract == .asyncMedia { result.asynchronous.queryURL = service.url(profile.asynchronous.queryURL) }
        result.authHeader = service.authHeader; result.authPrefix = service.authPrefix
        result.requiresKey = service.requiresKey; result.timeout = service.timeout
        result.credentialService = ModelServiceConnection.keyService; result.credentialAccount = service.keyAccount
        result.serviceConcurrency = service.concurrency
        try result.validate()
        return result
    }
}

public struct TapNowModelCatalog: Codable, Sendable {
    public var sourceProduct: String
    public var sourceVersion: String
    public var observedAt: String
    public var counts: [String: Int]
    public var entries: [Entry]
    public struct Entry: Codable, Identifiable, Sendable {
        public var id: String
        public var kind: ModelKind
        public var model: String
        public var displayName: String
        public var description: String
        public var provider: String?
        public var visibility: String
        public var audioType: String?
        public var modes: [String]
        public var config: JSONValue
        public var defaultParameters: JSONValue
        public var sourceSymbol: String
        public var sourceRange: JSONValue
        public var statusTitle: String {
            switch visibility { case "hidden": return "客户端隐藏"; case "regional": return "地区条件"; default: return "客户端目录" }
        }
        public func draft() -> ModelProfile {
            var p = ModelProfile(); p.name = displayName; p.catalogID = id; p.kind = kind
            p.model = ""; p.endpoint = ""; p.supportsImages = modes.contains("image_input")
            p.contract = kind == .llm ? .chatCompletions : kind == .image ? .imageGenerations : .asyncMedia
            return p
        }
        public func validate(question: ModelQuestion, profile: ModelProfile) throws {
            guard let variants = config["variants"]?.arrayValue, !variants.isEmpty,
                  let requested = profile.catalogVariantKey ?? question.generationMode else { return }
            let types: [String: [String]] = [
                "text": ["text_to_image", "text_to_video"], "image": ["image_to_video", "image_to_image"],
                "reference": ["reference_to_video", "reference_to_image", "image_to_image"],
                "start_end": ["start_end_to_video"]
            ]
            guard let variant = variants.first(where: { $0["key"]?.stringValue == requested })
                ?? variants.first(where: { types[requested]?.contains($0["modelType"]?.stringValue ?? "") == true }) else {
                throw ModelWorkspaceError.invalid("目录未声明此生成方式，请选择支持的模型或指定目录变体。")
            }
            if requested == "text", !question.references.isEmpty { throw ModelWorkspaceError.invalid("文字生成变体不能包含参考素材。") }
            for kind in [ModelKind.image, .video, .audio] {
                let count = question.references.filter { ref in
                    let mime = ModelEvaluationService.mime(for: ref)
                    return (ref.mediaKind ?? (mime.hasPrefix("image/") ? .image : mime.hasPrefix("video/") ? .video : .audio)) == kind
                }.count
                let range = variant["reference\(kind.rawValue.capitalized)Range"]
                if let minimum = range?["min"]?.intValue, count < minimum {
                    throw ModelWorkspaceError.invalid("目录要求至少 \(minimum) 个\(kind.title)参考。")
                }
                if let maximum = range?["max"]?.intValue, count > maximum {
                    throw ModelWorkspaceError.invalid("目录最多允许 \(maximum) 个\(kind.title)参考。")
                }
            }
            let options = variant["options"]
            for (semantic, option) in ["aspectRatio": "aspectRatios", "duration": "durations", "resolution": "resolutions"] {
                guard profile.mapping?.parameterFields[semantic] != nil,
                      let value = question.nodeParameters?[semantic], let allowed = options?[option]?.arrayValue else { continue }
                guard allowed.contains(value) else { throw ModelWorkspaceError.invalid("\(semantic) 不在目录变体支持范围内。") }
            }
        }
    }
    public static func load() throws -> Self {
        guard let url = Bundle.module.url(forResource: "TapNowModelCatalog", withExtension: "json", subdirectory: "Resources") else {
            throw ModelWorkspaceError.invalid("模型目录资源缺失。")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

public struct DiscoveredModel: Identifiable, Sendable {
    public var id: String
    public var title: String
}
