import Foundation

// v2.9.29: single source of truth for the ClipSlots on-disk DATA directory.
//
// By default data lives under ~/.local/share/clipslots, but the CLIPSLOTS_DATA_DIR
// environment variable overrides the root (env > default). The cross-process
// storage lock ALWAYS follows the data root so GUI and CLI keep coordinating on
// the same lock file even when the data dir is redirected (e.g. tests / sandboxes).
//
// NOTE: this governs DATA only. The user config (config.toml) stays under
// ~/.config/clipslots and is intentionally NOT affected by this.
public enum ClipSlotsPaths {
    public static var dataRoot: URL {
        if let e = ProcessInfo.processInfo.environment["CLIPSLOTS_DATA_DIR"], !e.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (e as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/clipslots", isDirectory: true)
    }
    public static var specialSlots: URL { dataRoot.appendingPathComponent("special_slots", isDirectory: true) }
    public static var slots: URL { dataRoot.appendingPathComponent("slots", isDirectory: true) }
    public static var lockFile: URL { specialSlots.appendingPathComponent(".storage.lock") }
}
