import Foundation

// MARK: - Import Limit Mode (v2.6.4)

enum ImportLimitMode: String, CaseIterable, Identifiable {
    case firstTenTotal
    case allTotal
    case firstTenPerFolder
    case allPerFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstTenTotal:
            return "合并后只导入前 10 个"
        case .allTotal:
            return "合并后导入全部"
        case .firstTenPerFolder:
            return "每个文件夹导入前 10 个"
        case .allPerFolder:
            return "每个文件夹导入全部"
        }
    }

    var shortTitle: String {
        switch self {
        case .firstTenTotal, .firstTenPerFolder:
            return "只导入前 10 个"
        case .allTotal, .allPerFolder:
            return "导入全部"
        }
    }

    var description: String {
        switch self {
        case .firstTenTotal:
            return "所有文件合并排序后，只保存前 10 个到当前槽位组。"
        case .allTotal:
            return "导入所有文件，超过当前槽位组后自动保存到后续槽位组。"
        case .firstTenPerFolder:
            return "每个文件夹最多取前 10 个文件，再按文件夹顺序保存。"
        case .allPerFolder:
            return "展开每个文件夹的全部文件，按文件夹顺序保存。"
        }
    }

    /// Which modes are relevant given the selection.
    static func availableModes(
        folderCount: Int,
        fileCount: Int
    ) -> [ImportLimitMode] {
        if folderCount <= 1 && fileCount == 0 {
            // Single folder, no standalone files
            return [.firstTenTotal, .allTotal]
        }
        if folderCount == 0 && fileCount > 1 {
            // Multiple standalone files only
            return [.firstTenTotal, .allTotal]
        }
        if folderCount >= 2 {
            // Multiple folders (with or without standalone files)
            return [.firstTenTotal, .allTotal, .firstTenPerFolder, .allPerFolder]
        }
        // Single folder + files
        return [.firstTenTotal, .allTotal]
    }

    /// Default mode based on selection.
    static func defaultMode(
        folderCount: Int,
        fileCount: Int
    ) -> ImportLimitMode {
        if folderCount >= 2 {
            return .allPerFolder
        }
        return .allTotal
    }
}
