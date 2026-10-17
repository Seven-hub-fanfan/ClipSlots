import Foundation
import CryptoKit

enum GenerationWire {
    static func validateIdentifier(_ id: String) throws {
        guard !id.isEmpty, !id.hasPrefix("-"), !id.contains("\0"),
              !id.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw GenerationAdapterError.invalidInput("任务或能力标识不合法。")
        }
    }
    static func identifier(_ value: JSONValue?) throws -> String {
        if let string = value?.stringValue { try validateIdentifier(string); return string }
        if case .number(let n) = value, n.isFinite, n >= 0, n.rounded() == n,
           n < 9_007_199_254_740_992 {
            return String(format: "%.0f", n)
        }
        // Decimal IDs exceeding JS's safe integer range must arrive as strings.
        throw GenerationAdapterError.invalidResponse
    }
    static func mediaURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func decode(_ text: String) throws -> JSONValue {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let value = try? JSONValue.decode(jsonText: text) else {
            throw GenerationAdapterError.invalidResponse
        }
        return value
    }
    static func objects(_ text: String) throws -> [JSONValue] {
        if let whole = try? decode(text), whole.objectValue != nil { return [whole] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var result: [JSONValue] = []
        for line in lines {
            let value = try decode(String(line))
            guard value.objectValue != nil else { throw GenerationAdapterError.invalidResponse }
            result.append(value)
        }
        guard !result.isEmpty else { throw GenerationAdapterError.invalidResponse }
        return result
    }
    static func revision(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func error(_ value: JSONValue) -> GenerationAdapterError? {
        guard let code = value["code"]?.stringValue else { return nil }
        if code.hasPrefix("BA_CLI_AUTH_") || code == "BA_CLI_SSO_ERROR" { return .authenticationRequired }
        if code.hasPrefix("BA_CLI_") { return .commandFailed(code: code, phase: value["phase"]?.stringValue) }
        return nil
    }
    static func values(at path: ArraySlice<GenerationJSONPathComponent>, in value: JSONValue) -> [JSONValue] {
        guard let first = path.first else { return [value] }
        let rest = path.dropFirst()
        switch first {
        case .key(let key):
            guard let child = value[key] else { return [] }
            return values(at: rest, in: child)
        case .index(let index):
            guard let array = value.arrayValue, array.indices.contains(index) else { return [] }
            return values(at: rest, in: array[index])
        case .each:
            return (value.arrayValue ?? []).flatMap { values(at: rest, in: $0) }
        }
    }
    static func artifacts(_ raw: JSONValue, bindings: [GenerationOutputBinding]) -> [GenerationArtifact] {
        bindings.flatMap { binding in
            values(at: binding.path[...], in: raw).compactMap { value in
                switch binding.kind {
                case .image, .video, .audio:
                    guard let string = value.stringValue, mediaURL(string) != nil else { return nil }
                case .text:
                    guard value.stringValue != nil else { return nil }
                case .data: break
                }
                return GenerationArtifact(name: binding.name, kind: binding.kind, value: value)
            }
        }
    }
}

/// Deliberately a checked subset of JSON Schema, never silently ignores an unfamiliar
/// validation keyword. The CLI's --use-limit remains the media-specific second fence.
enum GenerationSchema {
    static let annotationKeys: Set<String> = ["$schema", "$id", "title", "description", "default", "examples"]
    static let validationKeys: Set<String> = ["type", "properties", "required", "additionalProperties",
        "enum", "const", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "minLength", "maxLength", "minItems", "maxItems", "items", "anyOf"]

    static func validate(_ value: JSONValue, schema: JSONValue, path: String = "inputs") throws {
        try check(schema)
        try validateChecked(value, schema: schema, path: path)
    }

    /// Audit the complete schema, including fields absent from this particular input.
    /// ECMAScript patterns are not evaluated with Foundation's different regex dialect.
    private static func check(_ schema: JSONValue, depth: Int = 0) throws {
        guard depth < 32, let rules = schema.objectValue else { throw invalidSchema() }
        let unknown = Set(rules.keys).subtracting(annotationKeys.union(validationKeys))
        guard unknown.isEmpty else {
            throw GenerationAdapterError.unsupportedSchema("输入契约含尚未适配的规则：\(unknown.sorted().joined(separator: "、"))。")
        }
        if let type = rules["type"] {
            let types = type.stringValue.map { [$0] } ?? type.arrayValue?.compactMap(\.stringValue) ?? []
            guard !types.isEmpty, Set(types).count == types.count,
                  type.arrayValue == nil || types.count == type.arrayValue?.count,
                  types.allSatisfy({ ["object", "array", "string", "number", "integer", "boolean", "null"].contains($0) })
            else { throw invalidSchema() }
        }
        if let properties = rules["properties"] {
            guard let fields = properties.objectValue else { throw invalidSchema() }
            for field in fields.values { try check(field, depth: depth + 1) }
        }
        if let required = rules["required"] {
            guard let keys = required.arrayValue, keys.allSatisfy({ $0.stringValue != nil }),
                  Set(keys.compactMap(\.stringValue)).count == keys.count else { throw invalidSchema() }
        }
        if let additional = rules["additionalProperties"] {
            if additional.objectValue != nil { try check(additional, depth: depth + 1) }
            else if additional != .bool(true) && additional != .bool(false) { throw invalidSchema() }
        }
        if let items = rules["items"] { try check(items, depth: depth + 1) }
        if let alternatives = rules["anyOf"] {
            guard let schemas = alternatives.arrayValue, !schemas.isEmpty else { throw invalidSchema() }
            for schema in schemas { try check(schema, depth: depth + 1) }
        }
        if let choices = rules["enum"] {
            guard let array = choices.arrayValue, !array.isEmpty,
                  array.enumerated().allSatisfy({ !array.prefix($0.offset).contains($0.element) })
            else { throw invalidSchema() }
        }
        for key in ["minLength", "maxLength", "minItems", "maxItems"] { _ = try countRule(rules[key]) }
        for key in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"] {
            if let raw = rules[key] {
                guard case .number(let n) = raw, n.isFinite, key != "multipleOf" || n > 0 else { throw invalidSchema() }
            }
        }
    }

    private static func validateChecked(_ value: JSONValue, schema: JSONValue, path: String) throws {
        guard let rules = schema.objectValue else {
            throw GenerationAdapterError.unsupportedSchema("输入契约不是受支持的对象 Schema。")
        }
        let unknown = Set(rules.keys).subtracting(annotationKeys.union(validationKeys))
        guard unknown.isEmpty else {
            throw GenerationAdapterError.unsupportedSchema("输入契约含尚未适配的规则：\(unknown.sorted().joined(separator: "、"))。")
        }
        if let type = rules["type"] {
            let allowed: [String]
            if let string = type.stringValue { allowed = [string] }
            else if let array = type.arrayValue, array.allSatisfy({ $0.stringValue != nil }) {
                allowed = array.compactMap(\.stringValue)
            } else { throw GenerationAdapterError.unsupportedSchema("Schema 类型声明无法识别。") }
            guard allowed.allSatisfy({ ["object", "array", "string", "number", "integer", "boolean", "null"].contains($0) }) else {
                throw GenerationAdapterError.unsupportedSchema("Schema 类型尚未适配。")
            }
            guard allowed.contains(where: { matches(value, type: $0) }) else { throw invalid(path) }
        }
        if let choices = rules["enum"] {
            guard let array = choices.arrayValue else { throw invalidSchema() }
            guard array.contains(value) else { throw invalid(path) }
        }
        if let constant = rules["const"], constant != value { throw invalid(path) }
        if let alternatives = rules["anyOf"]?.arrayValue {
            guard alternatives.contains(where: { (try? validateChecked(value, schema: $0, path: path)) != nil })
            else { throw invalid(path) }
        }
        switch value {
        case .object(let object):
            let properties: [String: JSONValue]
            if let raw = rules["properties"] {
                guard let fields = raw.objectValue else { throw invalidSchema() }; properties = fields
            } else { properties = [:] }
            if let required = rules["required"] {
                guard let array = required.arrayValue, array.allSatisfy({ $0.stringValue != nil }) else { throw invalidSchema() }
                for key in array.compactMap(\.stringValue) where object[key] == nil { throw invalid(path + "." + key) }
            }
            for (key, child) in object {
                if let field = properties[key] { try validateChecked(child, schema: field, path: path + "." + key) }
                else if let additional = rules["additionalProperties"] {
                    if additional == .bool(false) { throw invalid(path + "." + key) }
                    if additional.objectValue != nil { try validateChecked(child, schema: additional, path: path + "." + key) }
                    else if additional != .bool(true) && additional != .bool(false) { throw invalidSchema() }
                }
            }
        case .string(let text):
            // JSON Schema length is Unicode code points, not grapheme clusters.
            let count = text.unicodeScalars.count
            if let min = try countRule(rules["minLength"]), count < min { throw invalid(path) }
            if let max = try countRule(rules["maxLength"]), count > max { throw invalid(path) }
        case .number(let number):
            guard number.isFinite else { throw invalid(path) }
            for (key, compare) in [
                ("minimum", { (a: Double, b: Double) in a >= b }),
                ("maximum", { (a: Double, b: Double) in a <= b }),
                ("exclusiveMinimum", { (a: Double, b: Double) in a > b }),
                ("exclusiveMaximum", { (a: Double, b: Double) in a < b })
            ] {
                if let raw = rules[key] {
                    guard case .number(let bound) = raw, bound.isFinite else { throw invalidSchema() }
                    guard compare(number, bound) else { throw invalid(path) }
                }
            }
            if let raw = rules["multipleOf"] {
                guard case .number(let step) = raw, step.isFinite, step > 0 else { throw invalidSchema() }
                let ratio = number / step
                guard ratio.isFinite, abs(ratio - ratio.rounded()) < 1e-9 else { throw invalid(path) }
            }
        case .array(let array):
            if let min = try countRule(rules["minItems"]), array.count < min { throw invalid(path) }
            if let max = try countRule(rules["maxItems"]), array.count > max { throw invalid(path) }
            if let items = rules["items"] {
                for (i, child) in array.enumerated() { try validateChecked(child, schema: items, path: "\(path)[\(i)]") }
            }
        default: break
        }
    }
    static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (value, type) {
        case (.object, "object"), (.array, "array"), (.string, "string"), (.bool, "boolean"), (.null, "null"): return true
        case (.number(let n), "number"): return n.isFinite
        case (.number(let n), "integer"): return n.isFinite && n.rounded() == n && abs(n) < 9_007_199_254_740_992
        default: return false
        }
    }
    static func countRule(_ raw: JSONValue?) throws -> Int? {
        guard let raw else { return nil }
        guard case .number(let n) = raw, n.isFinite, n >= 0, n < Double(Int.max), n.rounded() == n else { throw invalidSchema() }
        return Int(n)
    }
    static func invalid(_ path: String) -> GenerationAdapterError {
        .invalidInput("\(path) 不符合能力输入契约。")
    }
    static func invalidSchema() -> GenerationAdapterError { .unsupportedSchema("输入契约中的校验规则不合法。") }
}
