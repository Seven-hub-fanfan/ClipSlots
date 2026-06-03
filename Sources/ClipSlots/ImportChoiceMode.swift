import Foundation

// MARK: - UI-layer Import Choice (v2.6.7)

/// Simplified two-option mode exposed to the user in ImportOptionsSheet.
/// The underlying ImportLimitMode enum remains for execution but is not shown directly.
enum ImportChoiceMode: String, CaseIterable, Identifiable, Codable {
    case all
    case firstTen

    var id: String { rawValue }
}

// MARK: - Import Selection Summary (v2.6.7)

/// Describes what the user selected before showing import options.
struct ImportSelectionSummary {
    let fileCount: Int
    let folderCount: Int

    var hasFolders: Bool { folderCount > 0 }

    var displayText: String {
        if folderCount == 1 && fileCount == 0 {
            return "已选择：1 个文件夹"
        }
        if folderCount > 1 && fileCount == 0 {
            return "已选择：\(folderCount) 个文件夹"
        }
        if folderCount == 0 && fileCount > 0 {
            return "已选择：\(fileCount) 个文件"
        }
        return "已选择：\(folderCount) 个文件夹，\(fileCount) 个文件"
    }
}

// MARK: - Pending Import Selection (v2.6.7)

/// Holds the pending import task until the user confirms via ImportOptionsSheet.
struct PendingImportSelection: Identifiable {
    let id = UUID()
    let urls: [URL]
    let summary: ImportSelectionSummary
    let startSlot: Int
    let source: ImportSource

    enum ImportSource {
        case toolbar
        case hotkey
    }
}

// MARK: - Resolve Choice → Limit Mode (v2.6.7)

func resolveExpansionMode(choice: ImportChoiceMode, summary: ImportSelectionSummary) -> ImportLimitMode {
    switch choice {
    case .all:
        return summary.hasFolders ? .allPerFolder : .allTotal
    case .firstTen:
        return summary.hasFolders ? .firstTenPerFolder : .firstTenTotal
    }
}
