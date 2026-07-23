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
    // NOTE: 保留常量仅为向后兼容旧数据；v2.10.0 起「自动切换」统一改用 autoAdvanceEnabled。
    static let autoAdvanceAfterPaste = "autoAdvanceAfterPaste"

    // v2.10.0: 三档金属拨杆共享开关（同时被 toolbar 拨杆与设置项读写）。
    static let autoStoreEnabled = "autoStoreEnabled"     // 拨杆1 自动存储（默认关）
    static let autoPasteEnabled = "autoPasteEnabled"     // 拨杆2 自动粘贴（默认关）
    static let autoAdvanceEnabled = "autoAdvanceEnabled" // 拨杆3 自动切换（默认开）

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
