import Foundation

public struct ByteArtistWorkflowSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public init(id: String, title: String, description: String = "") {
        self.id = id; self.title = title; self.description = description
    }
}

public struct ByteArtistWorkflowPage: Sendable {
    public let workflows: [ByteArtistWorkflowSummary]
    public let total: Int
    public let page: Int
    public let pageSize: Int
    public var hasMore: Bool { page * pageSize < total }
}

public struct ByteArtistCatalogDiscovery: Sendable {
    public let capabilities: [GenerationCapability]
    public let issues: [String]
}

public struct ByteArtistSlot: Equatable, Sendable {
    public let key: String
    public let format: String
    public let description: String
    public let limits: String
}

/// Slot tables are emitted by the official reference generator. Do not derive
/// executable capabilities from workflow names or list descriptions.
public enum ByteArtistContract {
    public static func validateField(_ raw: String, schema: JSONValue) throws {
        let value = schema["type"]?.stringValue == "string" ? JSONValue.string(raw)
            : try JSONValue.decode(jsonText: raw)
        try GenerationSchema.validate(value, schema: schema)
    }
    public static func slots(_ reference: String, output: Bool = false) -> [ByteArtistSlot] {
        guard let start = reference.range(of: output ? "\n## 输出\n" : "\n## 输入\n") else { return [] }
        let section = reference[start.upperBound...].components(separatedBy: "\n## ").first ?? ""
        return section.split(separator: "\n").compactMap { line in
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "<br/>", with: "\n") }
            guard cells.count >= (output ? 6 : 9), !cells[1].isEmpty,
                  cells[1] != "名称", !cells[1].hasPrefix("---") else { return nil }
            return ByteArtistSlot(key: cells[2].isEmpty ? cells[1] : cells[2], format: cells[3],
                                  description: output ? "" : cells[4], limits: output ? "" : cells[6])
        }
    }
    public static func outputKinds(_ reference: String) -> [GenerationArtifactKind] {
        var used = Set<String>()
        return slots(reference, output: true).compactMap {
            guard let kind = GenerationArtifactKind(rawValue: $0.format),
                  used.insert(kind.rawValue).inserted else { return nil }
            return kind
        }
    }
    public static func summary(_ reference: String) -> String {
        guard let start = reference.range(of: "> workflow id:"),
              let end = reference[start.upperBound...].range(of: "\n\n") else { return "" }
        let section = reference[end.upperBound...].components(separatedBy: "\n## ").first ?? ""
        let text = section.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "暂无描述" || text.hasPrefix("#") ? "" : text
    }
    /// Verified official result envelope: output_result[] contains format and
    /// value, together with slot/node identity. Explicit user bindings take
    /// priority; this parser never walks arbitrary URLs in server diagnostics.
    public static func mediaArtifacts(_ output: JSONValue, kind: GenerationArtifactKind) -> [GenerationArtifact] {
        guard [.image, .video, .audio].contains(kind), let items = output.arrayValue,
              !items.isEmpty, items.count <= 100 else { return [] }
        var artifacts: [GenerationArtifact] = []
        for item in items {
            guard let format = item["format"]?.stringValue,
                  let declared = GenerationArtifactKind(rawValue: format) else { return [] }
            if declared != kind { continue }
            guard let key = item["node_key"]?.stringValue, !key.isEmpty,
                  item["slot_key"]?.stringValue?.isEmpty == false,
                  let value = item["value"]?.stringValue, GenerationWire.mediaURL(value) != nil else { return [] }
            artifacts.append(.init(name: key, kind: declared, value: .string(value)))
        }
        return artifacts
    }
}

public struct GenerationTaskDiagnostic: Codable, Equatable, Sendable {
    public var stage: String
    public var rawStatus: String?
    public var requestID: String?
    public var logID: String?
    public var message: String?
    public init(stage: String, rawStatus: String? = nil, requestID: String? = nil,
                logID: String? = nil, message: String? = nil) {
        self.stage = stage; self.rawStatus = rawStatus; self.requestID = requestID
        self.logID = logID; self.message = message
    }
    public var stageLabel: String {
        switch stage {
        case "preparing": return "检查输入"
        case "submitting": return "提交中"
        case "queued": return "排队中"
        case "running": return "生成中"
        case "unknown": return "等待状态确认"
        case "awaiting-output": return "已完成，需确认产物"
        case "empty-output": return "已完成，未返回产物"
        case "query-paused": return "查询已暂停"
        case "downloading": return "下载产物"
        case "saving": return "保存产物"
        case "succeeded": return "生成完成"
        case "failed": return "生成失败"
        default: return message ?? "等待处理"
        }
    }
}
