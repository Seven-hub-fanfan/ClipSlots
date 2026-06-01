import Foundation

// MARK: - Web URL Detection (v2.5)

extension SlotContent {

    /// Detected web URL if the content is a plain http/https URL.
    var detectedWebURL: URL? {
        // Try plainText first (full text of first text item)
        for itemList in items {
            for item in itemList {
                if item.type == "public.utf8-plain-text" || item.type == "NSStringPboardType" {
                    if let str = String(data: item.data, encoding: .utf8) {
                        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let url = URL(string: trimmed),
                           let scheme = url.scheme?.lowercased(),
                           (scheme == "http" || scheme == "https") {
                            return url
                        }
                    }
                }
            }
        }
        return nil
    }
}
