import Foundation

/// 画布「附件列表编辑」的**撤销字节暂存**（v2.16.5）。
///
/// ## 为什么需要它
///
/// 画布上对附件的增删（拖入入参文件、删除入参、提升为主体）此前**不进撤销栈**：
/// 附件被删除后，`SlotStorage.set` 的 staging→原子 swap 只克隆新列表仍引用的 `.bin`，
/// 被删附件的字节随旧槽位目录一起被物理删除，Cmd+Z 无法把它写回来（旧内容只能靠
/// `.trash` 人工捞）。
///
/// 解决办法与 `stashSlotForCanvasUndo` 同源：**把字节搬到磁盘暂存区**，而不是把可能几 MB
/// 的附件塞进内存历史。一次附件编辑对应一个 token（= 历史条目 id），两个方向共用同一目录：
///
///   - 正向（before → after）执行前：before 独有（即被删）的 `.bin` 复制到 `<token>/`。
///   - 撤销（after → before）：after 独有的 `.bin` 从槽位移入暂存；before 独有的复制回槽位。
///   - 重做（before → after）：反向再来一遍。
///
/// 暂存根目录刻意放在 `canvas/.attach_stash/`：它与画布文档同生共域，历史条目被截断 /
/// 项目切换清栈时由 `CanvasStore` 按 token 调 `discard` 收走。
public enum CanvasAttachmentStash {

    /// 暂存根目录。
    public static func rootDirectory() -> URL {
        ClipSlotsPaths.dataRoot
            .appendingPathComponent("canvas", isDirectory: true)
            .appendingPathComponent(".attach_stash", isDirectory: true)
    }

    public static func directory(token: String) -> URL {
        rootDirectory().appendingPathComponent(token, isDirectory: true)
    }

    /// 槽位附件目录：`<storageBase>/<groupId>/<slot>/attachments/`。
    ///
    /// 普通组与画布私有组目录布局一致，只是 `storageBase` 分别是 `special_slots/` 与
    /// `canvas/private_slots/`（见调用方传入的 `SpecialSlotStorage.storageRoot`）。
    public static func slotBinsDirectory(storageBase: URL,
                                         groupId: String,
                                         slot: Int) -> URL {
        storageBase
            .appendingPathComponent(groupId, isDirectory: true)
            .appendingPathComponent(String(slot), isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
    }

    // MARK: - 正向预暂存

    /// 在写入新附件列表**之前**，把被删附件的 `.bin` 复制进暂存区。
    ///
    /// 用复制而不是移动：复制后旧文件仍在槽位目录里，随后 `set` 的原子 swap 会把它随旧目录
    /// 删除；若写入前流程意外中断，槽位也没有任何损失。APFS 上 `copyItem` 走 clonefile，
    /// 复制本身不占额外磁盘空间。
    ///
    /// - Returns: 确实复制成功（原本存在）的附件 id。内联字节型附件没有 `.bin`，返回时被跳过；
    ///   调用方应保证落库附件都已外置（本项目所有写路径都经过 externalize）。
    @discardableResult
    public static func copyRemovedBins(ids: [String],
                                       storageBase: URL,
                                       groupId: String,
                                       slot: Int,
                                       token: String) -> [String] {
        guard !ids.isEmpty else { return [] }
        let fm = FileManager.default
        let bins = slotBinsDirectory(storageBase: storageBase, groupId: groupId, slot: slot)
        let stash = directory(token: token)
        try? fm.createDirectory(at: stash, withIntermediateDirectories: true)
        var copied: [String] = []
        for id in ids {
            let source = bins.appendingPathComponent(binName(id))
            let dest = stash.appendingPathComponent(binName(id))
            guard fm.fileExists(atPath: source.path) else {
                NSLog("[ClipSlots] attach stash: \(id) 无外置 .bin，跳过（可能仍是内联字节）")
                continue
            }
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            do {
                try fm.copyItem(at: source, to: dest)
                copied.append(id)
            } catch {
                NSLog("[ClipSlots] attach stash 复制失败 \(id)：\(error.localizedDescription)")
            }
        }
        return copied
    }

    // MARK: - 双向 swap（撤销 / 重做时）

    /// 在写入目标附件列表**之前**，把槽位与暂存区之间需要换方向的 `.bin` 归位。
    ///
    /// - Parameters:
    ///   - stashAwayIds: 目标列表里**不再引用**、必须从槽位移入暂存的 id（当前文件在槽位）。
    ///   - restoreIds: 目标列表里**重新引用**、必须从暂存复制回槽位的 id（当前文件在暂存）。
    public static func swap(stashAwayIds: [String],
                            restoreIds: [String],
                            storageBase: URL,
                            groupId: String,
                            slot: Int,
                            token: String) throws {
        let fm = FileManager.default
        let bins = slotBinsDirectory(storageBase: storageBase, groupId: groupId, slot: slot)
        let stash = directory(token: token)
        try fm.createDirectory(at: bins, withIntermediateDirectories: true)

        // 1) 先把目标列表不再引用的文件移出槽位，避免 set 的 externalize 把它们克隆进新 staging。
        for id in stashAwayIds {
            let source = bins.appendingPathComponent(binName(id))
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.createDirectory(at: stash, withIntermediateDirectories: true)
            let dest = stash.appendingPathComponent(binName(id))
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: source, to: dest)
        }

        // 2) 再把目标列表重新引用的文件复制回槽位（externalize 按 storagePath 克隆进 staging）。
        for id in restoreIds {
            let source = stash.appendingPathComponent(binName(id))
            let dest = bins.appendingPathComponent(binName(id))
            guard fm.fileExists(atPath: source.path) else {
                NSLog("[ClipSlots] attach stash: 恢复时找不到 \(id) 的暂存字节，该附件将缺失")
                continue
            }
            if fm.fileExists(atPath: dest.path) { continue } // 槽位已有同 id 字节，以槽位为准
            try fm.copyItem(at: source, to: dest)
        }
    }

    /// 删除一个历史条目对应的暂存字节（条目被截断 / 清栈时）。
    public static func discard(token: String) {
        let dir = directory(token: token)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// 外置文件名。与 SlotStorage externalize 的命名保持一致（`<id>.bin`）。
    private static func binName(_ id: String) -> String {
        "\(id).bin"
    }
}
