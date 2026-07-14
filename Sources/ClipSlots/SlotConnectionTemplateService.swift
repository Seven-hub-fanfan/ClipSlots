import Foundation
import ClipSlotsKit
import UniformTypeIdentifiers

// MARK: - Slot Connection Template Service

enum SlotConnectionTemplateService {
    static let fileExtension = "clipslotslink"
    static let currentVersion = SlotConnectionTemplate.currentVersion

    // MARK: - Encode / Decode

    static func encode(_ template: SlotConnectionTemplate) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(template)
    }

    // v2.7.66: Normalize an export URL so the file extension is never
    // duplicated (e.g. "foo.clipslotslink.clipslotslink"). NSSavePanel appends
    // the allowed content type extension, so a default name that already ends
    // with `.clipslotslink` would otherwise produce a double extension.
    static func sanitizedExportURL(_ url: URL) -> URL {
        var last = url.lastPathComponent
        let suffix = ".\(fileExtension)"
        let dupSuffix = suffix + suffix
        while last.hasSuffix(dupSuffix) {
            last = String(last.dropLast(suffix.count))
        }
        // Ensure exactly one extension.
        if !last.hasSuffix(suffix) {
            last += suffix
        }
        return url.deletingLastPathComponent().appendingPathComponent(last)
    }

    // v2.7.66: Decode robustly by trying multiple date strategies. The export
    // path uses ISO8601, but older files (and some hand-edited ones) may use the
    // default (deferredToDate / numeric reference-date) strategy. Trying both
    // prevents a spurious "模板格式无效" when only the date format differs.
    private static func decodeTemplate(_ data: Data) throws -> SlotConnectionTemplate {
        let iso = JSONDecoder()
        iso.dateDecodingStrategy = .iso8601
        if let template = try? iso.decode(SlotConnectionTemplate.self, from: data) {
            return template
        }
        // Fallback: default (deferredToDate) date strategy. Let this throw the
        // real decoding error if it also fails, so callers can surface details.
        return try JSONDecoder().decode(SlotConnectionTemplate.self, from: data)
    }

    static func decode(_ data: Data) throws -> SlotConnectionTemplate {
        let template = try decodeTemplate(data)

        guard template.version <= currentVersion else {
            throw SlotConnectionError.unsupportedTemplateVersion
        }
        guard template.slotCount <= 10 else {
            throw SlotConnectionError.invalidTemplate
        }

        let map = SlotConnectionMap(edges: template.edges)
        try validateConnectionMap(map)

        return template
    }

    // MARK: - Bundle Encode / Decode

    // v2.7.65: Bundle encoding now routes through the service with the SAME
    // ISO8601 date strategy as single templates, fixing the previous asymmetry
    // where bundles used a raw JSONEncoder (deferredToDate) while single
    // templates used ISO8601. `decodeBundle` stays backward compatible by
    // falling back to the legacy (default) date strategy for old files.
    static func encodeBundle(_ bundle: SlotConnectionTemplateBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    static func decodeBundle(_ data: Data) throws -> SlotConnectionTemplateBundle {
        // Prefer the new ISO8601 format.
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        if let bundle = try? isoDecoder.decode(SlotConnectionTemplateBundle.self, from: data) {
            return bundle
        }
        // Backward compatibility: bundles exported before v2.7.65 used the
        // default (deferredToDate) date strategy.
        return try JSONDecoder().decode(SlotConnectionTemplateBundle.self, from: data)
    }

    // MARK: - Built-in Template: Full 10-Slot Chain

    static func makeFullTenSlotChainTemplate(appVersion: String) -> SlotConnectionTemplate {
        let edges: [SlotConnectionEdge] = [
            SlotConnectionEdge(fromSlot: 1, fromPort: .right, toSlot: 2, toPort: .left, colorId: 0),
            SlotConnectionEdge(fromSlot: 2, fromPort: .right, toSlot: 3, toPort: .left, colorId: 0),
            SlotConnectionEdge(fromSlot: 3, fromPort: .right, toSlot: 4, toPort: .left, colorId: 0),
            SlotConnectionEdge(fromSlot: 4, fromPort: .right, toSlot: 5, toPort: .left, colorId: 0),
            SlotConnectionEdge(fromSlot: 5, fromPort: .bottom, toSlot: 6, toPort: .top, colorId: 0),
            SlotConnectionEdge(fromSlot: 6, fromPort: .right, toSlot: 7, toPort: .left, colorId: 0),
            SlotConnectionEdge(fromSlot: 7, fromPort: .right, toSlot: 8, toPort: .left, colorId: 0),
            SlotConnectionEdge(fromSlot: 8, fromPort: .right, toSlot: 9, toPort: .left, colorId: 0),
            SlotConnectionEdge(fromSlot: 9, fromPort: .right, toSlot: 10, toPort: .left, colorId: 0),
        ]

        return SlotConnectionTemplate(
            name: "十槽位全串联",
            description: "将 1 到 10 号槽位按数字顺序串联，粘贴槽位 1 时自动粘贴全部槽位内容。适合多段 Prompt 组合、邮件模板、代码片段组合。",
            appVersion: appVersion,
            tags: ["官方", "全串联", "prompt", "10-slots"],
            edges: edges
        )
    }

    // MARK: - Make Template from Current Map

    static func makeTemplate(from map: SlotConnectionMap, name: String, appVersion: String) -> SlotConnectionTemplate {
        let slotCount = Set(map.edges.flatMap { [$0.fromSlot, $0.toSlot] }).count
        return SlotConnectionTemplate(
            name: name,
            description: "ClipSlots 槽位连接模板",
            appVersion: appVersion,
            slotCount: max(slotCount, 2),
            edges: map.edges
        )
    }

    // v2.7.7: export a bundle containing multiple slot groups / pages.
    static func makeBundleTemplate(from entries: [SlotConnectionTemplateBundleEntry], name: String, appVersion: String) -> SlotConnectionTemplateBundle {
        SlotConnectionTemplateBundle(
            name: name,
            appVersion: appVersion,
            entries: entries
        )
    }
}

// MARK: - v2.7.7 Template Bundle

struct SlotConnectionTemplateBundle: Codable, Identifiable {
    static let currentVersion = 1
    var id: UUID = UUID()
    var name: String
    var version: Int = SlotConnectionTemplateBundle.currentVersion
    var appVersion: String
    var createdAt: Date = Date()
    var entries: [SlotConnectionTemplateBundleEntry]
}

struct SlotConnectionTemplateBundleEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var pageId: String
    var groupId: String
    var groupName: String
    var map: SlotConnectionMap
}
