import Foundation

// MARK: - Slot Search Matcher (v2.5)

struct SlotSearchMatcher {

    /// Whether the search/filter is currently active.
    static func isActive(query: String, filter: SlotFilterType) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filter != .all
    }

    /// Check if a slot matches the given search query and type filter.
    static func matches(
        slot: Int,
        content: SlotContent,
        label: String,
        query: String,
        filter: SlotFilterType
    ) -> Bool {
        // 1. Type filter first
        if !matchesFilter(content: content, filter: filter) {
            return false
        }

        // 2. Query match
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedQuery.isEmpty {
            return true
        }

        let searchable = searchableText(slot: slot, content: content, label: label)
        return searchable.localizedCaseInsensitiveContains(normalizedQuery)
    }

    // MARK: - Private

    private static func searchableText(
        slot: Int,
        content: SlotContent,
        label: String
    ) -> String {
        var parts: [String] = []

        // Slot number
        parts.append("\(slot)")
        parts.append("槽位 \(slot)")

        // Label (from store, not content.label)
        if !label.isEmpty {
            parts.append(label)
        }

        // Content preview
        let preview = content.preview
        if !preview.isEmpty {
            parts.append(preview)
        }

        // File detection
        if let url = content.primaryFileURL {
            parts.append(url.lastPathComponent)
            parts.append(url.path)
            parts.append(url.pathExtension)
        }

        // Web URL detection (v2.5)
        if let url = content.detectedWebURL {
            parts.append(url.absoluteString)
            if let host = url.host {
                parts.append(host)
            }
        }

        return parts.joined(separator: " ")
    }

    private static func matchesFilter(
        content: SlotContent,
        filter: SlotFilterType
    ) -> Bool {
        switch filter {
        case .all:
            return true

        case .empty:
            return content.isEmpty

        case .file:
            return content.primaryFileURL != nil

        case .url:
            return content.detectedWebURL != nil

        case .image:
            return content.hasImage || content.isImageFile

        case .text:
            // Non-empty but not file, not URL, not image
            return !content.isEmpty
                && content.primaryFileURL == nil
                && content.detectedWebURL == nil
                && !content.hasImage
                && !content.isImageFile
        }
    }
}
