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

// MARK: - Expansion Result (v2.6.4)

struct BatchImportExpansionResult {
    let items: [BatchImportItem]
    let folderCount: Int
    let fileCount: Int
    let skippedFolderCount: Int
    let totalDiscoveredFileCount: Int
    let limitedByMode: Bool
    let mode: ImportLimitMode
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

    // MARK: - Multi-folder expansion (v2.6.4)

    /// Expand a mixed selection of files and folders into `BatchImportItem` list.
    /// - Parameters:
    ///   - urls: Selected URLs (files + folders, in selection order).
    ///   - mode: Import limit strategy.
    ///   - sortRule: Sort rule for files within each folder.
    /// - Returns: Expansion result with items and stats.
    func expandSelection(
        urls: [URL],
        mode: ImportLimitMode,
        sortRule: FolderImportSortRule = .naturalNameAscending
    ) -> BatchImportExpansionResult {
        var allItems: [BatchImportItem] = []
        var fileCount = 0
        var folderCount = 0
        var skippedFolderCount = 0
        var totalDiscovered = 0

        // Separate file URLs from folder URLs
        var fileURLs: [URL] = []
        var folderURLs: [URL] = []

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                continue
            }
            if values.isDirectory == true {
                folderURLs.append(url)
            } else if values.isRegularFile == true {
                fileURLs.append(url)
            }
        }

        folderCount = folderURLs.count
        fileCount = fileURLs.count

        // Standalone files are always included (not subject to per-folder limits)
        for fileURL in fileURLs {
            allItems.append(BatchImportItem(fileURL: fileURL, sourceFolderName: nil))
        }

        switch mode {
        case .firstTenTotal:
            // Expand all folders, merge, take first 10 total
            var expanded: [BatchImportItem] = []
            for folderURL in folderURLs {
                let (items, skipped) = expandFolderFlat(folderURL, sortRule: sortRule)
                expanded.append(contentsOf: items)
                skippedFolderCount += skipped
                totalDiscovered += items.count
            }
            // Take first 10 from combined (minus standalone files already added)
            let remaining = max(0, 10 - allItems.count)
            allItems.append(contentsOf: expanded.prefix(remaining))
            return BatchImportExpansionResult(
                items: allItems,
                folderCount: folderCount,
                fileCount: fileCount,
                skippedFolderCount: skippedFolderCount,
                totalDiscoveredFileCount: totalDiscovered + fileCount,
                limitedByMode: totalDiscovered + fileCount > 10,
                mode: mode
            )

        case .allTotal:
            // Expand all folders, merge all
            for folderURL in folderURLs {
                let (items, skipped) = expandFolderFlat(folderURL, sortRule: sortRule)
                allItems.append(contentsOf: items)
                skippedFolderCount += skipped
                totalDiscovered += items.count
            }
            return BatchImportExpansionResult(
                items: allItems,
                folderCount: folderCount,
                fileCount: fileCount,
                skippedFolderCount: skippedFolderCount,
                totalDiscoveredFileCount: totalDiscovered + fileCount,
                limitedByMode: false,
                mode: mode
            )

        case .firstTenPerFolder:
            // Each folder: take first 10; standalone files all included
            for folderURL in folderURLs {
                let (items, skipped) = expandFolderFlat(folderURL, sortRule: sortRule, maxPerFolder: 10)
                allItems.append(contentsOf: items)
                skippedFolderCount += skipped
                totalDiscovered += items.count
            }
            let totalAvailable = totalDiscovered + fileCount
            return BatchImportExpansionResult(
                items: allItems,
                folderCount: folderCount,
                fileCount: fileCount,
                skippedFolderCount: skippedFolderCount,
                totalDiscoveredFileCount: totalAvailable,
                limitedByMode: totalAvailable > 10,
                mode: mode
            )

        case .allPerFolder:
            // Each folder: expand all; standalone files all included
            for folderURL in folderURLs {
                let (items, skipped) = expandFolderFlat(folderURL, sortRule: sortRule)
                allItems.append(contentsOf: items)
                skippedFolderCount += skipped
                totalDiscovered += items.count
            }
            return BatchImportExpansionResult(
                items: allItems,
                folderCount: folderCount,
                fileCount: fileCount,
                skippedFolderCount: skippedFolderCount,
                totalDiscoveredFileCount: totalDiscovered + fileCount,
                limitedByMode: false,
                mode: mode
            )
        }
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

    /// Expand a single folder: list files (non-recursive), sort, optionally cap.
    private func expandFolderFlat(
        _ folderURL: URL,
        sortRule: FolderImportSortRule,
        maxPerFolder: Int? = nil
    ) -> (items: [BatchImportItem], skippedSubfolderCount: Int) {
        let folderName = folderURL.lastPathComponent

        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return ([], 0)
        }

        var files: [URL] = []
        var skippedSubfolders = 0

        for url in children {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey]),
                  values.isHidden != true else {
                continue
            }
            if values.isDirectory == true {
                skippedSubfolders += 1
                continue
            }
            if values.isRegularFile == true {
                files.append(url)
            }
        }

        let sorted = sortFiles(files, rule: sortRule)
        let capped = maxPerFolder.map { Array(sorted.prefix($0)) } ?? sorted

        let items = capped.map { BatchImportItem(fileURL: $0, sourceFolderName: folderName) }
        return (items, skippedSubfolders)
    }
}
