import Foundation
import AppKit

// MARK: - Batch Import Models (v2.6.0)

struct BatchImportItem {
    let fileURL: URL
    let sourceFolderName: String?

    var fileName: String { fileURL.lastPathComponent }
}

struct BatchSavePlan {
    var items: [BatchImportItem]
    var startSlot: Int
    var willOverwriteCount: Int
    var needsNewGroups: Int
    var skippedFolderCount: Int
    var skippedUnsupportedCount: Int
    var availableCapacity: Int
    var willSaveCount: Int { min(items.count, availableCapacity) }
    var willSkipCount: Int { max(0, items.count - availableCapacity) }
}

// MARK: - Service

final class BatchImportService {
    private let folderImportService = FolderImportService()

    // MARK: - Detection

    /// Detect multiple file URLs from clipboard content. Returns nil if not a batch save scenario.
    func detectBatchItems(from content: SlotContent) -> [BatchImportItem]? {
        let regularFiles = content.detectedRegularFileURLs
        let folders = content.detectedFolderURLs

        // Not file content at all
        if regularFiles.isEmpty && folders.isEmpty {
            return nil
        }

        // Single folder — keep existing folder import behavior
        if folders.count == 1 && regularFiles.isEmpty {
            return nil
        }

        var items: [BatchImportItem] = []

        // Add regular files
        for fileURL in regularFiles {
            items.append(BatchImportItem(fileURL: fileURL, sourceFolderName: nil))
        }

        // Expand folders (non-recursive, one level only)
        lastSkippedSubfolderCount = 0
        for folderURL in folders {
            let expanded = expandFolder(folderURL)
            items.append(contentsOf: expanded.items)
            lastSkippedSubfolderCount += expanded.skippedSubfolderCount
        }

        // Single file → not batch
        if items.count <= 1 {
            return nil
        }

        return items
    }

    // MARK: - Folder expansion (non-recursive)

    private func expandFolder(_ folderURL: URL) -> (items: [BatchImportItem], skippedSubfolderCount: Int) {
        let folderName = folderURL.lastPathComponent

        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return ([], 0)
        }

        var items: [BatchImportItem] = []
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
                items.append(BatchImportItem(fileURL: url, sourceFolderName: folderName))
            }
        }

        return (items, skippedSubfolders)
    }

    var lastSkippedSubfolderCount: Int = 0

    // MARK: - Capacity Calculation

    /// Calculate how many files can be saved starting from `startSlot` in the current page.
    /// Returns total available slot count.
    func calculateCapacity(
        startSlot: Int,
        currentGroupSlotCount: Int,
        existingGroupsInPage: [SpecialSlot],
        maxSpecialSlots: Int,
        maxSlotsPerGroup: Int
    ) -> Int {
        // Slots available in the current group from startSlot
        let currentGroupAvailable = max(0, maxSlotsPerGroup - startSlot + 1)

        // Slots available in existing subsequent groups
        var subsequentAvailable = 0
        for _ in existingGroupsInPage.sorted(by: { $0.order < $1.order }) {
            subsequentAvailable += maxSlotsPerGroup
        }

        // Slots available in new groups we can create
        let existingCount = existingGroupsInPage.count
        let canCreate = max(0, maxSpecialSlots - existingCount)
        let newGroupSlots = canCreate * maxSlotsPerGroup

        return currentGroupAvailable + subsequentAvailable + newGroupSlots
    }

    // MARK: - Plan Generation

    func makePlan(
        items: [BatchImportItem],
        startSlot: Int,
        currentGroupId: String,
        currentPageId: String,
        existingGroups: [SpecialSlot],
        currentSlotContent: [Int: SlotContent],
        maxSpecialSlots: Int,
        maxSlotsPerGroup: Int
    ) -> BatchSavePlan {
        // Sort groups in this page by order
        let pageGroups = existingGroups
            .filter { $0.pageId == currentPageId }
            .sorted { $0.order < $1.order }

        // Find current group index
        let currentGroupIdx = pageGroups.firstIndex(where: { $0.id == currentGroupId }) ?? 0

        // Calculate available capacity
        let currentGroupAvailable = max(0, maxSlotsPerGroup - startSlot + 1)

        // Subsequent existing groups in this page
        var subsequentSlots = 0
        for _ in (currentGroupIdx + 1)..<pageGroups.count {
            subsequentSlots += maxSlotsPerGroup
        }

        // New groups we can create
        let canCreateNew = max(0, maxSpecialSlots - pageGroups.count)
        let newGroupSlots = canCreateNew * maxSlotsPerGroup

        let totalCapacity = currentGroupAvailable + subsequentSlots + newGroupSlots

        // Count overwrites in the current group from startSlot
        var overwriteCount = 0
        for slot in startSlot...maxSlotsPerGroup {
            if let content = currentSlotContent[slot], !content.isEmpty {
                overwriteCount += 1
            }
        }

        return BatchSavePlan(
            items: items,
            startSlot: startSlot,
            willOverwriteCount: overwriteCount,
            needsNewGroups: max(0, ((items.count - currentGroupAvailable - subsequentSlots + maxSlotsPerGroup - 1) / maxSlotsPerGroup)),
            skippedFolderCount: 0,
            skippedUnsupportedCount: 0,
            availableCapacity: totalCapacity
        )
    }

    // MARK: - Content Creation

    func makeSlotContent(for fileURL: URL) -> SlotContent {
        folderImportService.makeSlotContent(for: fileURL)
    }
}
