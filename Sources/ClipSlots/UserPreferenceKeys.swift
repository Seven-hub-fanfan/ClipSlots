import Foundation

// MARK: - User Preference Keys (v2.6.0)

enum UserPreferenceKeys {
    static let skipOverwriteConfirmation = "skipOverwriteConfirmation"
    static let skipBatchSaveConfirmation = "skipBatchSaveConfirmation"
    static let showSaveToast = "showSaveToast"
    static let showCopyToast = "showCopyToast"
    static let enableSlotConnection = "enableSlotConnection"
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
