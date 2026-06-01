import Foundation

// MARK: - Slot Search Scope (v2.5.1)

enum SlotSearchScope: String, CaseIterable, Identifiable {
    case currentGroup
    case global

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentGroup: return "组内"
        case .global: return "全局"
        }
    }

    var systemImage: String {
        switch self {
        case .currentGroup: return "folder"
        case .global: return "globe"
        }
    }
}
