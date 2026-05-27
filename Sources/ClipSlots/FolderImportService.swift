import Foundation
import AppKit

// MARK: - Options & Results

struct FolderImportOptions {
    var maxFiles: Int = 10
    var includeHiddenFiles: Bool = false
    var recursive: Bool = false
    var sortRule: FolderImportSortRule = .naturalNameAscending
}

struct FolderImportPreview {
    var folderURL: URL
    var importableFiles: [URL]
    var skippedURLs: [URL]
    var totalImportableCount: Int
    var willImportFiles: [URL]
    var overflowed: Bool
}

struct FolderImportResult {
    var preview: FolderImportPreview
    var importedCount: Int
    var importedSlots: [Int]
}

// MARK: - Service

final class FolderImportService {

    func preview(folderURL: URL, options: FolderImportOptions) throws -> FolderImportPreview {
        let children = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        )

        let importable = children.filter { isImportableFile($0, includeHidden: options.includeHiddenFiles) }
        let skipped = children.filter { !importable.contains($0) }
        let sorted = sortFiles(importable, rule: options.sortRule)
        let willImport = Array(sorted.prefix(options.maxFiles))

        return FolderImportPreview(
            folderURL: folderURL,
            importableFiles: sorted,
            skippedURLs: skipped,
            totalImportableCount: sorted.count,
            willImportFiles: willImport,
            overflowed: sorted.count > options.maxFiles
        )
    }

    func makeSlotContent(for fileURL: URL) -> SlotContent {
        let urlString = fileURL.absoluteString
        let data = Data(urlString.utf8)

        let item = PasteboardItem(
            type: "public.file-url",
            data: data
        )

        // Also include public.url for better compatibility
        let urlItem = PasteboardItem(
            type: "public.url",
            data: data
        )

        return SlotContent(
            items: [[item, urlItem]],
            timestamp: Date(),
            label: fileURL.lastPathComponent
        )
    }

    // MARK: - Private

    private func isImportableFile(_ url: URL, includeHidden: Bool) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey]) else {
            return false
        }
        guard values.isRegularFile == true else { return false }
        if !includeHidden, values.isHidden == true { return false }
        return true
    }

    private func sortFiles(_ files: [URL], rule: FolderImportSortRule) -> [URL] {
        switch rule {
        case .naturalNameAscending:
            return files.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }
    }
}
