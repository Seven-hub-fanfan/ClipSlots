import AppKit

struct PasteboardItem: Codable {
    let type: String
    let data: Data
}

struct SlotContent: Codable {
    var items: [[PasteboardItem]] = []
    var timestamp: Date = Date()
    var label: String? = nil
    var htmlSource: String? = nil

    /// Unique content identity. Regenerated on every save/overwrite. Used as the
    /// primary cache-breaker for thumbnails, SwiftUI View identity, and file paths.
    var contentId: String = UUID().uuidString
    /// Monotonic timestamp updated on every save/overwrite. Combined with contentId
    /// to form the thumbnail cache key so that even same-contentId overwrites
    /// (impossible in practice but defensive) still miss the cache.
    var updatedAt: TimeInterval = Date().timeIntervalSince1970

    var isEmpty: Bool { items.isEmpty }

    /// Legacy hash — still available for diagnostics but no longer the primary
    /// cache key. The new key is `thumbnailKey(specialSlotId:slot:)`.
    var contentHash: String {
        let totalBytes = items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } }
        return "\(timestamp.timeIntervalSince1970)-\(totalBytes)"
    }

    /// Composite cache key that scopes a thumbnail by special-slot, slot number,
    /// content identity, and save timestamp. Changing any dimension invalidates
    /// the cached thumbnail.
    func thumbnailKey(specialSlotId: String, slot: Int) -> String {
        "\(specialSlotId)::\(slot)::\(contentId)::\(updatedAt)"
    }

    var preview: String {
        for itemList in items {
            for item in itemList {
                if item.type == "public.utf8-plain-text" || item.type == "NSStringPboardType" {
                    if let str = String(data: item.data, encoding: .utf8) {
                        let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.count > 30 ? String(t.prefix(30)) + "…" : t
                    }
                }
                if item.type == "public.rtf" { return "[RTF]" }
                if item.type == "public.html" { return "[HTML]" }
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

    var plainText: String? {
        for itemList in items {
            for item in itemList {
                if item.type == "public.utf8-plain-text" || item.type == "NSStringPboardType" {
                    return String(data: item.data, encoding: .utf8)
                }
            }
        }
        return nil
    }
}

final class ClipboardManager {
    static let shared = ClipboardManager()
    private let pasteboard = NSPasteboard.general

    func capture() -> SlotContent {
        var content = SlotContent()
        content.timestamp = Date()

        guard let pbItems = pasteboard.pasteboardItems, !pbItems.isEmpty else {
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

    func restore(_ content: SlotContent) -> Bool {
        guard !content.items.isEmpty else { return false }
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

    func restorePlainText(_ content: SlotContent) -> Bool {
        if let text = content.plainText {
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
        return restore(content)
    }

    /// Poll pasteboard changeCount to detect when the target app has consumed content after Cmd+V.
    /// Calls completion after consumption or timeout (5s).
    func waitForPasteCompletion(timeout: TimeInterval = 5.0, completion: @escaping () -> Void) {
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

    var changeCount: Int { pasteboard.changeCount }
}

// MARK: - v2.7.33 SlotContent Convenience Init

extension SlotContent {
    init(text: String) {
        let data = text.data(using: .utf8)!
        let item = PasteboardItem(type: "public.utf8-plain-text", data: data)
        self.items = [[item]]
        self.timestamp = Date()
    }
}

// MARK: - v2.7.32 HTML Detection

extension SlotContent {
    var isHTMLFileURL: Bool {
        guard let url = primaryFileURL else { return false }
        return ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    var isHTMLDocument: Bool {
        if isHTMLFileURL { return true }
        let raw = (plainText ?? preview).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw.hasPrefix("<!doctype html") || raw.hasPrefix("<html") || raw.contains("<body") || raw.contains("</html>")
    }

    var htmlDocumentSource: String? {
        if let url = primaryFileURL, isHTMLFileURL {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
            if let text = try? String(contentsOf: url) { return text }
        }
        let raw = (plainText ?? preview).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != "[HTML]" else { return nil }
        return raw
    }
}
