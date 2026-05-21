import AppKit

struct PasteboardItem: Codable {
    let type: String
    let data: Data
}

struct SlotContent: Codable {
    var items: [[PasteboardItem]] = []
    var timestamp: Date = Date()
    var label: String? = nil

    var isEmpty: Bool { items.isEmpty }

    var preview: String {
        for itemList in items {
            for item in itemList {
                if item.type == "public.utf8-plain-text" || item.type == "NSStringPboardType" {
                    if let str = String(data: item.data, encoding: .utf8) {
                        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        return String(trimmed.prefix(50))
                    }
                }
                if item.type == "public.rtf" {
                    if let rtf = String(data: item.data, encoding: .utf8) {
                        let stripped = rtf.replacingOccurrences(of: "\\[\\\\a-z0-9]+[ ]?", with: "", options: .regularExpression)
                        let text = String(stripped.filter { !$0.isNewline && $0 != "\\" && $0 != "{" && $0 != "}" }.prefix(50))
                        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                            return "[富文本] " + text
                        }
                    }
                    return "[富文本]"
                }
                if item.type == "public.file-url" {
                    if let urlStr = String(data: item.data, encoding: .utf8), let url = URL(string: urlStr) {
                        return "[文件] " + url.lastPathComponent
                    }
                    return "[文件]"
                }
                if item.type.hasPrefix("public.") && item.type.contains("image") {
                    return "[图片 \(item.data.count / 1024)KB]"
                }
            }
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
        return content
    }

    func restore(_ content: SlotContent) -> Bool {
        guard !content.items.isEmpty else { return false }
        pasteboard.clearContents()
        var pbItems: [NSPasteboardItem] = []
        for itemList in content.items {
            let pbItem = NSPasteboardItem()
            for item in itemList {
                pbItem.setData(item.data, forType: NSPasteboard.PasteboardType(item.type))
            }
            pbItems.append(pbItem)
        }
        guard !pbItems.isEmpty else { return false }
        return pasteboard.writeObjects(pbItems)
    }

    func restorePlainText(_ content: SlotContent) -> Bool {
        if let text = content.plainText {
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
        return restore(content)
    }

    var changeCount: Int { pasteboard.changeCount }
}
