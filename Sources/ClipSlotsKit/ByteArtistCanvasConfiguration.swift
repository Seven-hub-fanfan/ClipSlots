import Foundation

/// Provider drafts are independent of Crate's model/ratio/seed fields.
public struct ByteArtistCanvasConfiguration: Codable, Equatable {
    public struct Draft: Codable, Equatable {
        public var fields: [String: String] = [:]
        /// "prompt", "image:N", "firstFrame", "lastFrame"; absent means manual value.
        public var sources: [String: String] = [:]
        public var outputBindings: [GenerationOutputBinding] = []
        public init() {}
    }
    public var workflowID = ""
    public var drafts: [String: Draft] = [:]
    public init() {}
    public var draft: Draft {
        get { drafts[workflowID] ?? Draft() }
        set { drafts[workflowID] = newValue }
    }
    public mutating func select(_ capability: GenerationCapability) {
        workflowID = capability.id
        var draft = drafts[workflowID] ?? Draft()
        let properties = capability.inputSchema["properties"]?.objectValue ?? [:]
        // Preserve values that still belong to the schema; retire removed fields.
        draft.fields = draft.fields.filter { properties[$0.key] != nil }
        draft.sources = draft.sources.filter { properties[$0.key] != nil }
        for (key, rule) in properties where draft.fields[key] == nil && draft.sources[key] == nil {
            if let value = rule["default"], value != .null {
                draft.fields[key] = value.stringValue ?? (try? value.encodedText()) ?? ""
            }
            if ["prompt", "提示词", "正向提示词"].contains(key.lowercased()),
               rule["type"]?.stringValue == "string" { draft.sources[key] = "prompt" }
        }
        drafts[workflowID] = draft
    }

    public func input(capability: GenerationCapability, prompt: String, images: [String],
                      firstFrame: String?, lastFrame: String?) throws -> GenerationInput {
        guard workflowID == capability.id else { throw GenerationAdapterError.capabilityChanged }
        var values: [String: JSONValue] = [:]
        let properties = capability.inputSchema["properties"]?.objectValue ?? [:]
        for (key, rule) in properties {
            if let source = draft.sources[key] {
                let value: String?
                if source == "prompt" { value = prompt }
                else if source == "firstFrame" { value = firstFrame }
                else if source == "lastFrame" { value = lastFrame }
                else if source.hasPrefix("image:"), let index = Int(source.dropFirst(6)), images.indices.contains(index) {
                    value = images[index]
                } else { value = nil }
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw GenerationAdapterError.invalidInput("BA 输入「\(key)」绑定的提示词或素材不可用。")
                }
                values[key] = .string(value)
            } else if let raw = draft.fields[key] {
                if rule["type"]?.stringValue == "string" { values[key] = .string(raw) }
                else {
                    guard let value = try? JSONValue.decode(jsonText: raw) else {
                        throw GenerationAdapterError.invalidInput("BA 输入「\(key)」需要合法的 \(rule["type"]?.stringValue ?? "JSON") 值。")
                    }
                    values[key] = value
                }
            } else if let value = rule["default"], value != .null {
                values[key] = value
            } else { throw GenerationAdapterError.invalidInput("请填写 BA 输入「\(key)」。") }
        }
        try GenerationSchema.validate(.object(values), schema: capability.inputSchema)
        return GenerationInput(values: values)
    }
}

/// Unknown output layouts are shown for explicit selection, never guessed or downloaded.
/// Paths chosen by the user become the output contract for subsequent tasks.
public enum ByteArtistOutputSelection {
    public struct Candidate: Identifiable, Equatable {
        public var id: String { label }
        public let label: String
        public let url: URL
        public let path: [GenerationJSONPathComponent]
    }
    public static func candidates(_ value: JSONValue) -> [Candidate] {
        var result: [Candidate] = []
        func visit(_ value: JSONValue, path: [GenerationJSONPathComponent], label: String, depth: Int) {
            guard depth < 12, result.count < 100 else { return }
            if let text = value.stringValue, let url = GenerationWire.mediaURL(text) {
                result.append(.init(label: label.isEmpty ? "/" : label, url: url, path: path))
            } else if let array = value.arrayValue {
                for (index, item) in array.prefix(100).enumerated() {
                    visit(item, path: path + [.index(index)], label: label + "/\(index)", depth: depth + 1)
                }
            } else if let object = value.objectValue {
                for key in object.keys.sorted().prefix(100) {
                    visit(object[key]!, path: path + [.key(key)], label: label + "/" + key, depth: depth + 1)
                }
            }
        }
        visit(value, path: [], label: "", depth: 0)
        return result
    }
    public static func binding(_ candidate: Candidate, kind: GenerationArtifactKind,
                               allItems: Bool) -> GenerationOutputBinding {
        .init(name: candidate.label, kind: kind, path: candidate.path.map {
            if allItems, case .index = $0 { return .each }
            return $0
        })
    }
}
