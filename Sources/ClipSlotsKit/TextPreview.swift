import Foundation

/// A display summary only. Copy, full preview, search and generation retain full text.
public enum TextPreview {
    public static let byteLimit = 16 * 1024

    public static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }

    public static func prefix(_ data: Data, characters: Int = 30, html: Bool = false,
                              ellipsis: Bool = true) -> String? {
        let bytes = Data(data.prefix(byteLimit))
        let isUTF16 = bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff])
        var decoded: String?
        // A prefix may end inside a UTF-8 scalar or a UTF-16 surrogate pair.
        for removed in 0...min(4, bytes.count) {
            let candidate = Data(bytes.dropLast(removed))
            if isUTF16 {
                if candidate.count % 2 == 0 { decoded = String(data: candidate, encoding: .utf16) }
            } else { decoded = String(data: candidate, encoding: .utf8) }
            if decoded != nil { break }
        }
        if decoded == nil { decoded = String(data: bytes, encoding: .utf16) }
        guard var text = decoded else { return nil }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        if html {
            text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]*$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = String(trimmed.prefix(characters))
        let hasMore = !trimmed.dropFirst(characters).isEmpty || data.count > byteLimit
        return head + (ellipsis && hasMore && !head.isEmpty ? "…" : "")
    }
}

extension SlotContent.SlotAttachment {
    private static let summaryCache = ResourceCache<NSString>(category: .attachmentSummary)
    /// Reads at most 16KiB of an immutable stored text attachment, never the full payload.
    public func textSummary(characters: Int = 30) -> String {
        let key = "\(id)::\(storagePath ?? "")::\(characters)" as NSString
        if let hit = Self.summaryCache.object(forKey: key) { return hit as String }
        let bytes: Data?
        if let data { bytes = Data(data.prefix(TextPreview.byteLimit)) }
        else if let url = storageFileURL, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            bytes = try? handle.read(upToCount: TextPreview.byteLimit)
        } else { bytes = nil }
        let result = bytes.flatMap { TextPreview.prefix($0, characters: characters, ellipsis: false) } ?? ""
        Self.summaryCache.setObject(result as NSString, forKey: key, cost: result.utf8.count * 2)
        return result
    }
}
