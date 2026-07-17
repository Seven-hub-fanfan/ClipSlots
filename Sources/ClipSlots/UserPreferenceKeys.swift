import Foundation
import ClipSlotsKit

// MARK: - User Preference Keys (v2.6.0)

enum UserPreferenceKeys {
    static let skipOverwriteConfirmation = "skipOverwriteConfirmation"
    static let skipBatchSaveConfirmation = "skipBatchSaveConfirmation"
    static let showSaveToast = "showSaveToast"
    static let showCopyToast = "showCopyToast"
    static let enableSlotConnection = "enableSlotConnection"
    // v2.9.31: auto-advance to next group/page after pasting the last non-empty slot.
    static let autoAdvanceAfterPaste = "autoAdvanceAfterPaste"

    // v2.9.36: persist the last paste location so the footer status bar and the
    // slot-card badge can keep pointing at "上次粘贴" across relaunches.
    static let lastPastePageId = "lastPastePageId"
    static let lastPasteGroupId = "lastPasteGroupId"
    // -1 means "never pasted yet".
    static let lastPasteSlotIndex = "lastPasteSlotIndex"
}

extension UserDefaults {
    var skipOverwriteConfirmation: Bool {
        bool(forKey: UserPreferenceKeys.skipOverwriteConfirmation)
    }
    var skipBatchSaveConfirmation: Bool {
        bool(forKey: UserPreferenceKeys.skipBatchSaveConfirmation)
    }
    var showSaveToast: Bool {
        // Default true — if key not present, object(forKey:) returns nil → false
        if object(forKey: UserPreferenceKeys.showSaveToast) == nil { return true }
        return bool(forKey: UserPreferenceKeys.showSaveToast)
    }
    var showCopyToast: Bool {
        if object(forKey: UserPreferenceKeys.showCopyToast) == nil { return true }
        return bool(forKey: UserPreferenceKeys.showCopyToast)
    }
}
