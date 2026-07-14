import Foundation
import ClipSlotsKit

// MARK: - Slot Global Search Result (v2.5.2)

struct SlotGlobalSearchResult: Identifiable {
    let pageId: String
    let pageName: String
    let groupId: String
    let groupName: String
    let slot: Int
    let content: SlotContent
    let label: String

    // v2.5.2: Order fields for stable sorting
    let pageOrder: Int
    let groupOrder: Int

    var id: String { "\(pageId)-\(groupId)-\(slot)" }

    // MARK: Display helpers

    var displayTitle: String {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLabel.isEmpty {
            return trimmedLabel
        }

        if let fileURL = content.primaryFileURL {
            return fileURL.lastPathComponent
        }

        if let webURL = content.detectedWebURL {
            return webURL.host ?? webURL.absoluteString
        }

        let preview = content.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty {
            return preview
        }

        return "槽位 \(slot)"
    }

    var displaySubtitle: String {
        "\(pageName) / \(groupName) / 槽位 \(slot) · \(contentTypeTitle)"
    }

    var contentTypeTitle: String {
        if content.isEmpty { return "空槽位" }
        if content.detectedWebURL != nil { return "URL" }
        if content.primaryFileURL != nil {
            if content.isImageFile { return "图片文件" }
            return "文件"
        }
        if content.hasImage { return "图片" }
        return "文本"
    }

    // MARK: - Preview icon (v2.5.3)

    var previewIconName: String {
        if content.detectedWebURL != nil { return "link" }
        if content.isImageFile || content.hasImage { return "photo" }
        if content.isVideoFile { return "play.rectangle" }
        if let ext = content.primaryFileURL?.pathExtension.lowercased(), ext == "pdf" {
            return "doc.richtext"
        }
        if content.primaryFileURL != nil { return "doc" }
        if content.isEmpty { return "circle.dashed" }
        return "text.alignleft"
    }

    // MARK: - Sort helpers (v2.6.0)

    var contentTypeOrder: Int {
        if content.isEmpty { return 4 }
        if content.detectedWebURL != nil { return 3 }
        if content.primaryFileURL != nil { return 2 }
        if content.hasImage { return 1 }
        return 0  // text
    }
}
