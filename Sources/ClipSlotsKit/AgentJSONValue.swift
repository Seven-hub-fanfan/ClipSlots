import Foundation

// MARK: - JSONValue
//
// Agent 链路里到处都要处理"结构未知但必须往返 JSON"的数据：
//   1. Function Calling 的 parameters JSON Schema（我们要构造并原样发给模型）；
//   2. 模型回传的 tool_call.arguments（一串 JSON 文本，键名由 schema 决定）；
//   3. Skill 在 SKILL.md 里自带的工具声明（第三方写的，不能假设形状）。
//
// 用 `[String: Any]` + JSONSerialization 也能跑，但那样这三处全都失去类型安全，
// 而且 Codable 边界上要来回手搓桥接。这里定义一个最小 JSON 值模型：
// 可 Codable、可字面量构造、可安全取值，Kit 内所有 Agent 代码只认它。
//
// 刻意不做的事：不追求成为通用 JSON 库（没有 KeyPath 查询、没有 merge、没有 JSONPath）。
// 只覆盖 Agent 这条链路真正需要的操作，避免把它养成第二个"什么都塞"的工具类。

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        // 注意顺序：Bool 必须先试，否则 JSON 里的 true/false 在某些解码器上会被
        // 当成数字 1/0。Int 不单独建 case——JSON 数字本身没有整/浮之分，
        // 取整需求由 `intValue` 在读取侧处理。
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法识别的 JSON 值")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v):
            // 整数值用 Int 编码，避免 schema 里的 `"maxLength": 20` 被写成 `20.0`
            // ——DeepSeek 侧对 JSON Schema 的类型校验比较严，浮点会被拒。
            if v == v.rounded(), abs(v) < 9_007_199_254_740_992 { try c.encode(Int(v)) }
            else { try c.encode(v) }
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: 取值（读取侧一律走这些，不做强制解包）

    public var stringValue: String? {
        switch self {
        case .string(let v): return v
        default: return nil
        }
    }

    /// 数字取整。模型偶尔会把 `slot` 写成 `"3"`（字符串），所以字符串也尝试解析一次
    /// ——这属于对模型输出的容错，不是纵容脏数据：解析失败仍返回 nil，由调用方报错。
    public var intValue: Int? {
        switch self {
        case .number(let v):
            guard v == v.rounded(), abs(v) < Double(Int.max) else { return nil }
            return Int(v)
        case .string(let v): return Int(v.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let v): return v
        case .string(let v):
            switch v.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        switch self {
        case .array(let v): return v
        default: return nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        switch self {
        case .object(let v): return v
        default: return nil
        }
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// 是否是"缺省"：null 或空串。模型经常用空串占位可选参数，
    /// 参数校验必须把它等同于"没传"，否则会拿空串去查页面/组名。
    public var isBlank: Bool {
        switch self {
        case .null: return true
        case .string(let v): return v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }

    // MARK: 构造

    public static func decode(jsonText: String) throws -> JSONValue {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 模型在无参工具上经常回传空串而不是 `{}`，直接当空对象处理。
        if trimmed.isEmpty { return .object([:]) }
        guard let data = trimmed.data(using: .utf8) else {
            throw AgentJSONError.notUTF8
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func encodedText(pretty: Bool = false) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        let data = try enc.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

public enum AgentJSONError: Error, Equatable {
    case notUTF8
}

// MARK: - 字面量支持
//
// 有了这些，构造 JSON Schema 的代码读起来接近 schema 本身的样子，
// 不用被 `.object([...])`/`.string(...)` 包裹淹没。

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
