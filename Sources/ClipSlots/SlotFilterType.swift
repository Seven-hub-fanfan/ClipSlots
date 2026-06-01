import Foundation

// MARK: - Slot Filter Type (v2.5)

enum SlotFilterType: String, CaseIterable, Identifiable {
    case all
    case text
    case image
    case file
    case url
    case empty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:   return "全部"
        case .text:  return "文本"
        case .image: return "图片"
        case .file:  return "文件"
        case .url:   return "URL"
        case .empty: return "空槽位"
        }
    }

    var systemImage: String {
        switch self {
        case .all:   return "square.grid.2x2"
        case .text:  return "text.alignleft"
        case .image: return "photo"
        case .file:  return "doc"
        case .url:   return "link"
        case .empty: return "circle.dashed"
        }
    }
}
