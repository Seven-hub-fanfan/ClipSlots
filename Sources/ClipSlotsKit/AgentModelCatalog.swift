import Foundation

public struct AgentDiscoveredModel: Equatable, Sendable {
    public let id: String
    public let contextWindow: Int?
    public let supportsImages: Bool?
    public let displayName: String?
    public let description: String?
    public let recommended: Bool
    public let available: Bool
    public let subscriptionRequired: Bool
    public let automatic: Bool
    public let ratings: [String: Int]

    public init(id: String, contextWindow: Int?, supportsImages: Bool?,
                displayName: String? = nil, description: String? = nil, recommended: Bool = false,
                available: Bool = true, subscriptionRequired: Bool = false,
                automatic: Bool = false, ratings: [String: Int] = [:]) {
        self.id = id; self.contextWindow = contextWindow; self.supportsImages = supportsImages
        self.displayName = displayName; self.description = description; self.recommended = recommended
        self.available = available; self.subscriptionRequired = subscriptionRequired
        self.automatic = automatic; self.ratings = ratings
    }
}

/// Parse only explicitly reported capabilities. Model names are not evidence of image support.
public enum AgentModelCatalog {
    public static func modelsURL(endpoint: URL) throws -> URL {
        guard AgentGatewayPreferences.credentialOrigin(url: endpoint) != nil,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw AgentGatewayError.invalidConfiguration
        }
        var path = components.path
        if path.hasSuffix("/chat/completions") { path.removeLast("/chat/completions".count) }
        components.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? "/models" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).withLeadingSlash + "/models"
        guard let url = components.url else { throw AgentGatewayError.invalidConfiguration }
        return url
    }

    public static func parse(_ bytes: Data) throws -> [AgentDiscoveredModel] {
        guard bytes.count <= 1024 * 1024 else { throw AgentArtifactError.tooLarge }
        let value = try JSONDecoder().decode(JSONValue.self, from: bytes)
        guard let data = value["data"]?.arrayValue, data.count <= 2048 else {
            throw AgentOperationError("服务没有返回有效的模型列表。")
        }
        var seen = Set<String>()
        return try data.map { row in
            guard let id = row["id"]?.stringValue, !id.isEmpty, id.utf8.count <= 256,
                  !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(id).inserted else { throw AgentOperationError("模型列表包含无效或重复 ID。") }
            let reported = row["context_window"]?.intValue
            let context = reported.flatMap { (1...100_000_000).contains($0) ? $0 : nil }
            let image: Bool?
            if case .bool(let support) = row["capabilities"]?["image_input"] { image = support }
            else { image = nil }
            func text(_ key: String, limit: Int) -> String? {
                guard let value = row[key]?.stringValue, !value.isEmpty,
                      value.utf8.count <= limit,
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }) else { return nil }
                return value
            }
            let subscription = row["subscription_required"]?.boolValue == true
            let available = row["available"]?.boolValue ?? !subscription
            let ratings = (row["ratings"]?.objectValue ?? [:]).compactMapValues { value -> Int? in
                guard let rating = value.intValue, (1...5).contains(rating) else { return nil }
                return rating
            }
            return AgentDiscoveredModel(id: id, contextWindow: context, supportsImages: image,
                displayName: text("display_name", limit: 256), description: text("description", limit: 4096),
                recommended: row["recommended"]?.boolValue == true, available: available,
                subscriptionRequired: subscription, automatic: row["automatic"]?.boolValue == true || id == "auto",
                ratings: ratings)
        }
    }
}

private extension String {
    var withLeadingSlash: String { "/" + self }
}
