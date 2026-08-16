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
    /// UNDO-1/2 的撤销 + 重做栈落盘目录（v2.10.95 起）。
    public static var undoDir: URL { specialSlots.appendingPathComponent(".undo", isDirectory: true) }
    public static var undoStackFile: URL { undoDir.appendingPathComponent("undo_stack.json") }
    public static var redoStackFile: URL { undoDir.appendingPathComponent("redo_stack.json") }

    /// UNDO-3 (v2.10.97): 撤销/重做栈当前磁盘占用（字节）。设置面板展示用。
    /// 只统计 `.undo` 目录下的常规文件，目录不存在时返回 0。
    public static func undoStackDiskBytes() -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: undoDir,
                                                     includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for url in items {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
