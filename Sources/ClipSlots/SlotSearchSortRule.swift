import Foundation
import ClipSlotsKit

// MARK: - Search Sort Rule (v2.6.0)

enum SlotSearchSortRule: String, CaseIterable, Identifiable {
    case smart          // 智能（当前页 → 当前组 → pageOrder → groupOrder → slot）
    case slotOrder      // 槽位顺序
    case nameAscending  // 名称 A-Z
    case nameDescending // 名称 Z-A
    case typeOrder      // 类型（文本 → 图片 → 文件 → URL → 空）
    case pageGroupSlot  // 页面/组/槽位

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart:          return "智能"
        case .slotOrder:      return "槽位顺序"
        case .nameAscending:  return "名称 A-Z"
        case .nameDescending: return "名称 Z-A"
        case .typeOrder:      return "类型"
        case .pageGroupSlot:  return "页面/组/槽位"
        }
    }
}
