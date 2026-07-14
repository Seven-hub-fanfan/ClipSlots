import AppKit

public struct PasteboardItem: Codable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

public struct SlotContent: Codable {
    public var items: [[PasteboardItem]] = []
    public var timestamp: Date = Date()
    public var label: String? = nil
    public var htmlSource: String? = nil
    // v2.7.61: Slot attachments - only visible and editable in node canvas
    // Empty array = disabled, no change to existing behavior
    public var attachments: [SlotAttachment] = []
    
    // 向后兼容：旧模板没有 attachments 字段时自动填充空数组
    enum CodingKeys: String, CodingKey {
        case items, timestamp, label, htmlSource, attachments, contentId, updatedAt
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // v2.8.2 (P1-B): decode leniently so a corrupt / partial / legacy payload
        // (e.g. missing items or timestamp) still loads with sensible defaults
        // instead of throwing and dropping the whole slot.
        items = try container.decodeIfPresent([[PasteboardItem]].self, forKey: .items) ?? []
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        label = try container.decodeIfPresent(String.self, forKey: .label)
        htmlSource = try container.decodeIfPresent(String.self, forKey: .htmlSource)
        attachments = try container.decodeIfPresent([SlotAttachment].self, forKey: .attachments) ?? []
        // v2.8.1 (P1-1): older persisted payloads predate contentId/updatedAt.
        // Decode leniently with sensible defaults so legacy data still loads.
        contentId = try container.decodeIfPresent(String.self, forKey: .contentId) ?? UUID().uuidString
        updatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? timestamp.timeIntervalSince1970
    }

    public init() {}

    public init(items: [[PasteboardItem]] = [], timestamp: Date = Date(), label: String? = nil, htmlSource: String? = nil, attachments: [SlotAttachment] = [], contentId: String = UUID().uuidString, updatedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.items = items
        self.timestamp = timestamp
        self.label = label
        self.htmlSource = htmlSource
        self.attachments = attachments
        self.contentId = contentId
        self.updatedAt = updatedAt
    }

    // MARK: - Slot Attachment

    public struct SlotAttachment: Codable, Identifiable {
        public var id: UUID = UUID()
        public var name: String
        public var type: AttachmentType
        public var path: String?
        public var url: String?
        public var data: Data?
        public var createdAt: Date = Date()

        public init(id: UUID = UUID(), name: String, type: AttachmentType, path: String? = nil, url: String? = nil, data: Data? = nil, createdAt: Date = Date()) {
            self.id = id
            self.name = name
            self.type = type
            self.path = path
            self.url = url
            self.data = data
            self.createdAt = createdAt
        }
    }

    public enum AttachmentType: String, Codable {
        case image
        case file
        case text
        case url
        case reference
    }

    /// Unique content identity. Regenerated on every save/overwrite. Used as the
    /// primary cache-breaker for thumbnails, SwiftUI View identity, and file paths.
    public var contentId: String = UUID().uuidString
    /// Monotonic timestamp updated on every save/overwrite. Combined with contentId
    /// to form the thumbnail cache key so that even same-contentId overwrites
    /// (impossible in practice but defensive) still miss the cache.
    public var updatedAt: TimeInterval = Date().timeIntervalSince1970

    /// v2.8.1 (P1-2): true when this snapshot was produced by `capture()` from an
    /// actually empty system pasteboard (vs. a default/never-captured value). Lets
    /// `restore()` know it should clear the pasteboard rather than no-op, so an
    /// injected paste payload is not left behind when the original clipboard was empty.
    /// Not persisted (absent from CodingKeys).
    public var capturedEmpty: Bool = false

    public var isEmpty: Bool { items.isEmpty }

    /// Legacy hash — still available for diagnostics but no longer the primary
    /// cache key. The new key is `thumbnailKey(specialSlotId:slot:)`.
    public var contentHash: String {
        let totalBytes = items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } }
        return "\(timestamp.timeIntervalSince1970)-\(totalBytes)"
    }

    /// Composite cache key that scopes a thumbnail by special-slot, slot number,
    /// content identity, and save timestamp. Changing any dimension invalidates
    /// the cached thumbnail.
    public func thumbnailKey(specialSlotId: String, slot: Int) -> String {
        "\(specialSlotId)::\(slot)::\(contentId)::\(updatedAt)"
    }

    public var preview: String {
        for itemList in items {
            for item in itemList {
                if item.type == "public.utf8-plain-text" || item.type == "NSStringPboardType" {
                    // v2.8.7 (B): legacy NSStringPboardType is often UTF-16, so fall
                    // back to utf16 when utf8 decode fails, otherwise preview is empty.
                    if let str = String(data: item.data, encoding: .utf8) ?? String(data: item.data, encoding: .utf16) {
                        let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.count > 30 ? String(t.prefix(30)) + "…" : t
                    }
                }
                if item.type == "public.rtf" { return "[RTF]" }
                if item.type == "public.html" {
                    // v2.8.6: show the real readable text (HTML tags stripped) so an
                    // HTML slot looks exactly like a plain-text slot, instead of the
                    // bare "[HTML]" placeholder. A plain-text item, when present, is
                    // matched earlier in this loop and takes priority.
                    if let str = String(data: item.data, encoding: .utf8) ?? String(data: item.data, encoding: .utf16) {
                        let stripped = str
                            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                            .replacingOccurrences(of: "&nbsp;", with: " ")
                            .replacingOccurrences(of: "&lt;", with: "<")
                            .replacingOccurrences(of: "&gt;", with: ">")
                            .replacingOccurrences(of: "&amp;", with: "&")
                            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !stripped.isEmpty {
                            return stripped.count > 30 ? String(stripped.prefix(30)) + "…" : stripped
                        }
                    }
                    return "[HTML]"
                }
                if item.type == "public.file-url" {
                    if let urlStr = String(data: item.data, encoding: .utf8), let url = URL(string: urlStr) {
                        return "[文件]" + url.lastPathComponent
                    }
                    return "[文件]"
                }
                if item.type.hasPrefix("public.") && item.type.contains("image") {
                    return "[图片 \(item.data.count / 1024)KB]"
                }
            }
        }
        // Fallback: show first type name
        if let firstType = items.first?.first?.type {
            let short = firstType.replacingOccurrences(of: "public.", with: "")
            return "[\(short)]"
        }
        return "(空)"
    }

    public var plainText: String? {
        for itemList in items {
            for item in itemList {
                if item.type == "public.utf8-plain-text" || item.type == "NSStringPboardType" {
                    // v2.8.7 (B): legacy NSStringPboardType is often UTF-16.
                    return String(data: item.data, encoding: .utf8) ?? String(data: item.data, encoding: .utf16)
                }
            }
        }
        return nil
    }
}

public final class ClipboardManager {
    public static let shared = ClipboardManager()
    private let pasteboard = NSPasteboard.general

    public init() {}

    public func capture() -> SlotContent {
        var content = SlotContent()
        content.timestamp = Date()

        guard let pbItems = pasteboard.pasteboardItems, !pbItems.isEmpty else {
            content.capturedEmpty = true
            return content
        }

        var allItems: [[PasteboardItem]] = []
        for pbItem in pbItems {
            var items: [PasteboardItem] = []
            for type in pbItem.types {
                if let data = pbItem.data(forType: type) {
                    items.append(PasteboardItem(type: type.rawValue, data: data))
                }
            }
            if !items.isEmpty { allItems.append(items) }
        }
        content.items = allItems
        let types = allItems.flatMap { $0.map { $0.type } }
        NSLog("[ClipSlots] CLIPBOARD capture: changeCount=\(pasteboard.changeCount) items=\(pbItems.count), types: \(types), preview=\(content.preview)")
        return content
    }

    public func restore(_ content: SlotContent) -> Bool {
        guard !content.items.isEmpty else {
            // v2.8.1 (P1-2): the original clipboard was genuinely empty — clear the
            // pasteboard so an injected paste payload isn't left behind. A non-empty
            // capturedEmpty=false snapshot means "never captured / unknown", so we
            // leave the pasteboard untouched to avoid wiping real user content.
            if content.capturedEmpty {
                pasteboard.clearContents()
                NSLog("[ClipSlots] CLIPBOARD restore: original was empty, cleared pasteboard")
                return true
            }
            return false
        }
        pasteboard.clearContents()
        var pbItems: [NSPasteboardItem] = []
        for itemList in content.items {
            let pbItem = NSPasteboardItem()
            for item in itemList {
                let type = NSPasteboard.PasteboardType(item.type)
                let ok = pbItem.setData(item.data, forType: type)
                if !ok {
                    NSLog("[ClipSlots] WARNING: setData failed for type \(item.type) (\(item.data.count) bytes)")
                }
            }
            pbItems.append(pbItem)
        }
        guard !pbItems.isEmpty else { return false }
        let result = pasteboard.writeObjects(pbItems)
        let types = content.items.flatMap { $0.map { $0.type } }
        NSLog("[ClipSlots] CLIPBOARD restore: \(content.items.count) groups, types: \(types), result: \(result)")
        return result
    }

    public func restorePlainText(_ content: SlotContent) -> Bool {
        if let text = content.plainText {
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
        return restore(content)
    }

    /// Poll pasteboard changeCount to detect when the target app has consumed content after Cmd+V.
    /// Calls completion after consumption or timeout (5s).
    public func waitForPasteCompletion(timeout: TimeInterval = 5.0, completion: @escaping () -> Void) {
        let startCount = pasteboard.changeCount
        let deadline = DispatchTime.now() + timeout
        let checkInterval: TimeInterval = 0.05

        func check() {
            guard DispatchTime.now() < deadline else {
                NSLog("[ClipSlots] Paste completion timed out after \(timeout)s")
                completion()
                return
            }
            if pasteboard.changeCount != startCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { completion() }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + checkInterval) { check() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
    }

    public var changeCount: Int { pasteboard.changeCount }
}

// MARK: - v2.7.33 SlotContent Convenience Init

extension SlotContent {
    public init(text: String) {
        let data = text.data(using: .utf8) ?? Data()
        let item = PasteboardItem(type: "public.utf8-plain-text", data: data)
        self.items = [[item]]
        self.timestamp = Date()
    }
}

// MARK: - v2.7.32 HTML Detection

extension SlotContent {
    public var isHTMLFileURL: Bool {
        guard let url = primaryFileURL else { return false }
        return ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    /// v2.8.6: HTML captured to a slot is now presented as plain text everywhere
    /// (see `preview`), so we no longer surface the raw `public.html` bytes as a
    /// render source. Only genuine rich-paste (`htmlSource`) or `.html` files are
    /// treated as HTML documents.
    public var isHTMLDocument: Bool {
        if isHTMLFileURL { return true }
        if let htmlSource, !htmlSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    public var htmlDocumentSource: String? {
        if let url = primaryFileURL, isHTMLFileURL {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
            if let text = try? String(contentsOf: url) { return text }
        }
        if let htmlSource, !htmlSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return htmlSource }
        return nil
    }
}
