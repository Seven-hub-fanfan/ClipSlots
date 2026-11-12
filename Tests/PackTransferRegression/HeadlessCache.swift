import Foundation
import ClipSlotsKit

// Only UI cache invalidation is stubbed. Storage, exporter and importer are
// production implementations and operate in the runner's isolated data root.
extension SlotContent {
    static func invalidateInlineCaches(contentId: String, updatedAt: TimeInterval) {}
    static func purgeAllInlineImageCaches() {}
}
