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

    /// 画布数据根（`canvas/`）：项目索引、各项目的画布文档，以及 v2.14.0 起的**画布私有内容**。
    public static var canvas: URL { dataRoot.appendingPathComponent("canvas", isDirectory: true) }

    /// 画布私有内容的存储根（v2.14.0）。
    ///
    /// ## 为什么它必须是一个**独立的根**，而不是 `special_slots/` 里的一个保留组
    ///
    /// v2.11.8~v2.13.x 把画布上「没有对应槽位的节点」寄存在 `special_slots/` 的保留组里
    /// （`__unfiled__` / `__canvas__<projectId>`），靠"在发布边界上过滤掉"来对用户隐身。
    /// 这个做法在产品上是错的，实践也证明了：
    ///
    ///   - 过滤点不止一处（`specialSlots` 有两条旁路赋值没过滤），漏一处用户就在编辑页的组标签栏
    ///     看到「未入库」「画布·项目」这种组，还会被算进"这一页有几个组"的计数里；
    ///   - 它们挂在某个真实页面下（字段不能为空），所以天然"占用槽位页面"；
    ///   - 用户的诉求是「画布里的东西只在画布里管」，而不是「在槽位库里藏好」。
    ///
    /// 所以 v2.14.0 起画布私有内容搬到这里：**槽位库的索引（`special_slots/index.json`）里再也
    /// 没有它们的任何记录**，页面数、组数、组标签栏、切组快捷键、`clipslots list-groups` 全部
    /// 结构性地看不见它 —— 不是被过滤掉，而是压根不在那张表里。
    ///
    /// 复用 `SpecialSlotStorage`（换一个 baseDir）而不是另写一套存储，是因为画布节点要的能力
    /// （内容落盘 + 附件外置 + Label + 手动缩略图 + `.trash` 兜底 + 跨进程锁）它全都有；重写一份
    /// 只会得到一套没被验证过的、少了一半安全网的存储。
    public static var canvasPrivateSlots: URL { canvas.appendingPathComponent("private_slots", isDirectory: true) }
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
