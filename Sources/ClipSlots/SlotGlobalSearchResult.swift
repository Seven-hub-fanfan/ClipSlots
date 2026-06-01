import Foundation

// MARK: - Slot Global Search Result (v2.5.1)

struct SlotGlobalSearchResult: Identifiable {
    let pageId: String
    let pageName: String
    let groupId: String
    let groupName: String
    let slot: Int
    let content: SlotContent
    let label: String

    var id: String { "\(pageId)-\(groupId)-\(slot)" }

    var title: String {
        if !label.isEmpty { return label }
        if !content.preview.isEmpty { return content.preview }
        return "槽位 \(slot)"
    }

    var subtitle: String {
        "\(pageName) / \(groupName) / 槽位 \(slot)"
    }
}
