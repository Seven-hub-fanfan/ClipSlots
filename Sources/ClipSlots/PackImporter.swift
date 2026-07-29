import Foundation
import ClipSlotsKit

// MARK: - 冲突解决策略 (v2.10.14)

/// 导入时页名/组名冲突的处理方式。
enum PackConflictResolution {
    case append     // 追加新建（名称后加 -导入 后缀）
    case overwrite  // 覆盖同名页/组的内容
    case skip       // 跳过该页/组
}

/// 导入结果统计。
struct PackImportResult {
    var importedPages: Int = 0
    var importedGroups: Int = 0
    var importedSlots: Int = 0
    var skippedGroups: Int = 0
    var errors: [String] = []
}

enum PackImportError: Error, LocalizedError {
    case unzipFailed(String)
    case manifestMissing
    case manifestCorrupt(String)
    // PK-3 (v2.10.15): 页/组创建失败（达到每页上限、候选名耗尽等）时抛出，
    // 触发整包回滚而非留下半成品脏数据。
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unzipFailed(let s): return "解压失败：\(s)"
        case .manifestMissing: return "包内缺少 manifest.json，不是有效的槽位包"
        case .manifestCorrupt(let s): return "manifest.json 解析失败：\(s)"
        case .writeFailed(let s): return "导入写入失败：\(s)"
        }
    }
}

// MARK: - PackImporter

/// 负责解压 .clipslotspack、检测冲突、把页面/组/槽位写回存储。
///
/// 冲突策略（与产品约定一致）：
/// - 页名 / 组名冲突：由调用方通过 resolver 闭包逐一决定 追加/覆盖/跳过。
/// - 槽位组 UUID：导入「追加/新建」路径始终生成全新的组 id，绝不覆盖本地已有组；
///   仅当用户显式选择「覆盖」某个同名组时，才复用该组 id 并替换其槽位内容。
struct PackImporter {
    private let storage = SpecialSlotStorage.shared
    private let maxChildSlots: Int

    init(maxChildSlots: Int) {
        self.maxChildSlots = max(1, maxChildSlots)
    }

    /// 只读取 manifest（用于导入前预览包内容），不做任何写入。
    func readManifest(from packURL: URL) throws -> PackManifest {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("clipslotspack_peek_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        // 仅解出 manifest.json，避免为读元信息而解压整个大包。
        try unzip(packURL, to: tmp, members: ["manifest.json"])
        return try loadManifest(in: tmp)
    }

    /// 执行导入。resolver 闭包在需要用户决策时被同步调用（应在主线程运行）。
    @discardableResult
    func importPack(
        from packURL: URL,
        resolvePageConflict: (_ pageName: String) -> PackConflictResolution,
        resolveGroupConflict: (_ pageName: String, _ groupName: String) -> PackConflictResolution
    ) throws -> PackImportResult {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("clipslotspack_in_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        try unzip(packURL, to: tmp)
        let manifest = try loadManifest(in: tmp)
        let pagesRoot = tmp.appendingPathComponent("pages", isDirectory: true)

        var result = PackImportResult()

        // PK-3 (v2.10.15): 记录本次导入新建的页/组 id；任一步骤抛错时在 catch 中软删除回滚，
        // 避免半成品页/组残留库中成为脏数据（用户看到「导入失败」却仍需手动清理）。
        var createdPageIds: [String] = []
        var createdGroupIds: [String] = []

        // P2-9 (v2.10.16): 覆盖模式下对「已有组」原本会 clearAllSlots 清空原内容，回滚只能靠内存快照
        // 经 storage.set 逐槽写回——而 storage.set 会分配新磁盘空间，若失败诱因正是「磁盘已满」，回滚
        // 同样失败且被 try? 吞掉，最终「旧数据没了、新数据只写了一半」，组被损坏。
        // PK-3 (v2.10.30): 改为「磁盘级 rename 备份」（不占新空间）：覆盖前把被覆盖组目录整体 moveItem
        // 到同卷备份路径并登记到此清单；catch 回滚时先删半成品新组目录，再把备份 rename 回原位——回滚
        // 完全不依赖空闲磁盘空间，磁盘满也能可靠还原。导入整体成功后再删除这些备份目录。
        var overwrittenBackups: [GroupDirBackup] = []

        do {
        for manifestPage in manifest.pages {
            // PK-4 (v2.10.15): manifest 的 page.id 是不可信输入，校验拼出的路径 standardize 后
            // 仍在临时根目录内，防止 `../` 路径穿越读取包外任意文件（Zip-Slip 读侧信息泄露）。
            guard let pageDir = safeChildURL(in: pagesRoot, component: manifestPage.id, isDirectory: true) else {
                result.errors.append("页面 id 非法「\(manifestPage.id)」，已跳过")
                continue
            }
            let packPage = (try? loadJSON(PackPage.self, from: pageDir.appendingPathComponent("page.json")))
                ?? PackPage(id: manifestPage.id, name: manifestPage.name, order: 0)

            // 读取该页所有组（按 order 排序）。
            let groupsRoot = pageDir.appendingPathComponent("groups", isDirectory: true)
            let packGroups = loadGroups(in: groupsRoot)
            guard !packGroups.isEmpty else { continue }

            // 决定目标页面。
            let existingPage = storage.loadIndex().pages.first { $0.name == packPage.name }
            var targetPageId: String
            var overwritingExistingPage = false

            if existingPage != nil {
                switch resolvePageConflict(packPage.name) {
                case .skip:
                    continue
                case .append:
                    guard let newId = createUniquePage(baseName: packPage.name + "-导入") else {
                        // PK-3 (v2.10.15): 创建失败改为抛错，触发整包回滚而非静默残留。
                        throw PackImportError.writeFailed("创建页面「\(packPage.name)」失败")
                    }
                    targetPageId = newId
                    createdPageIds.append(newId) // PK-3 (v2.10.15): 追踪新建页以便回滚
                case .overwrite:
                    targetPageId = existingPage!.id
                    overwritingExistingPage = true
                }
            } else {
                guard let newId = createPageDirectly(name: packPage.name) else {
                    // PK-3 (v2.10.15): 创建失败改为抛错，触发整包回滚而非静默残留。
                    throw PackImportError.writeFailed("创建页面「\(packPage.name)」失败")
                }
                targetPageId = newId
                createdPageIds.append(newId) // PK-3 (v2.10.15): 追踪新建页以便回滚
            }

            result.importedPages += 1

            for (groupDir, packGroup) in packGroups {
                let slotsRoot = groupDir.appendingPathComponent("slots", isDirectory: true)

                // 决定目标组。
                var targetGroupId: String
                if overwritingExistingPage,
                   let existingGroup = storage.loadIndex().specialSlots.first(where: { $0.pageId == targetPageId && $0.name == packGroup.name }) {
                    switch resolveGroupConflict(packPage.name, packGroup.name) {
                    case .skip:
                        result.skippedGroups += 1
                        continue
                    case .append:
                        guard let newId = createUniqueGroup(baseName: packGroup.name + "-导入", inPage: targetPageId) else {
                            // PK-3 (v2.10.15): 创建失败改为抛错，触发整包回滚而非静默残留。
                            throw PackImportError.writeFailed("创建槽位组「\(packGroup.name)」失败")
                        }
                        targetGroupId = newId
                        createdGroupIds.append(newId) // PK-3 (v2.10.15): 追踪新建组以便回滚
                    case .overwrite:
                        targetGroupId = existingGroup.id
                        // PK-3 (v2.10.30): 覆盖前用磁盘级 rename 把被覆盖组目录整体移到同卷备份路径
                        // （不占新空间），替代旧的「内存快照 + storage.set 回滚」。rename 后原组目录被清空，
                        // 后续 writeSlots 会把新内容写入一个全新的空组目录；一旦中途失败，catch 回滚只需把
                        // 备份 rename 回原位即可完整还原，且不依赖任何空闲磁盘空间（磁盘满也能成功）。
                        overwrittenBackups.append(try backupGroupDirForOverwrite(targetGroupId))
                    }
                } else {
                    // 无冲突或新页：始终新建组（新 UUID），绝不覆盖本地已有组。
                    guard let newId = createUniqueGroup(baseName: packGroup.name, inPage: targetPageId) else {
                        // PK-3 (v2.10.15): 创建失败（可能已达每页上限）改为抛错，触发整包回滚。
                        throw PackImportError.writeFailed("创建槽位组「\(packGroup.name)」失败（可能已达每页上限）")
                    }
                    targetGroupId = newId
                    createdGroupIds.append(newId) // PK-3 (v2.10.15): 追踪新建组以便回滚
                }

                let slotCount = writeSlots(from: slotsRoot, declaredSlots: packGroup.slots, into: targetGroupId)
                result.importedGroups += 1
                result.importedSlots += slotCount
            }
        }
        } catch {
            // PK-3 (v2.10.15): 回滚本次导入新建的内容（软删除到 .trash）——先删组再删页
            // （删页会连带清理其下所有组），随后原样抛出，保证「导入失败」即无残留脏数据。
            for gid in createdGroupIds { try? storage.deleteSpecialSlot(id: gid) }
            for pid in createdPageIds { try? storage.deletePage(id: pid) }

            // PK-3 (v2.10.30): 用磁盘级 rename 回滚被覆盖组——先删掉中途可能写了一半的新组目录
            // （rename 目标须为空），再把备份目录原样 moveItem 回原位。整个过程只做 rename/删除，不
            // 分配新空间，因此即使失败诱因是「磁盘已满」也能可靠还原，杜绝旧的「快照 + storage.set 回滚」
            // 在满盘时同样失败、被 try? 吞掉而留下「旧数据没了、新数据半写」的损坏态。被覆盖组均为
            // 「已有组」，与上面删除的 createdGroupIds 互不相交，两段回滚互不影响。
            for backup in overwrittenBackups {
                guard let backupDir = backup.backupDir else { continue }
                do {
                    if fm.fileExists(atPath: backup.groupDir.path) {
                        try fm.removeItem(at: backup.groupDir)
                    }
                    try fm.moveItem(at: backupDir, to: backup.groupDir)
                } catch {
                    // rename 回滚是空间无关操作，正常不会失败；万一失败也记录（不再静默吞掉），备份目录
                    // 仍原样保留在 special_slots 下（.import_backup_<groupId>_<uuid>）供人工恢复。
                    NSLog("[ClipSlots] PackImporter PK-3 回滚失败：无法将备份 \(backupDir.path) 还原到 "
                        + "\(backup.groupDir.path)：\(error)。原数据仍完整保存在该备份目录中。")
                }
            }
            // rename 改变了组目录 inode，使各 SlotStorage 的内存缓存指纹失效；主动清缓存确保回滚后
            // 后续读取立即反映还原后的磁盘内容。
            storage.invalidateContentCaches()
            throw error
        }

        // PK-3 (v2.10.30): 导入整体成功——被覆盖组已被新内容替换，删除其磁盘级 rename 备份以释放空间。
        for backup in overwrittenBackups {
            if let backupDir = backup.backupDir {
                try? fm.removeItem(at: backupDir)
            }
        }

        return result
    }

    // MARK: - 写入单组的槽位

    private func writeSlots(from slotsRoot: URL, declaredSlots: [Int], into groupId: String) -> Int {
        let fm = FileManager.default
        // 优先用 group.json 声明的槽位序号；缺失时回退到扫描目录。
        var slotNumbers = declaredSlots
        if slotNumbers.isEmpty {
            let dirs = (try? fm.contentsOfDirectory(at: slotsRoot, includingPropertiesForKeys: nil)) ?? []
            slotNumbers = dirs.compactMap { Int($0.lastPathComponent) }.sorted()
        }

        var written = 0
        for slot in slotNumbers {
            guard slot >= 1, slot <= maxChildSlots else { continue }
            let slotDir = slotsRoot.appendingPathComponent("\(slot)", isDirectory: true)
            guard let packSlot = try? loadJSON(PackSlot.self, from: slotDir.appendingPathComponent("slot.json")) else { continue }

            let attachmentsDir = slotDir.appendingPathComponent("attachments", isDirectory: true)
            var restored: [SlotContent.SlotAttachment] = []
            for att in packSlot.attachments {
                let type = SlotContent.AttachmentType(rawValue: att.type) ?? .file
                var data: Data? = nil
                if let file = att.file {
                    // P1-2 (v2.10.18): 附件路径做 safeChildURL 校验，防止 Zip Slip 路径穿越读取包外文件。
                    if let safeURL = safeChildURL(in: attachmentsDir, component: file, isDirectory: false) {
                        data = try? Data(contentsOf: safeURL)
                    }
                }
                // 槽位 UUID 始终新生成，附件字节内联，路径不跨机还原。
                restored.append(SlotContent.SlotAttachment(
                    id: UUID(),
                    name: att.name,
                    type: type,
                    path: nil,
                    url: att.url,
                    data: data
                ))
            }

            var content = SlotContent()
            content.items = packSlot.items
            content.htmlSource = packSlot.htmlSource
            content.label = packSlot.label
            content.attachments = restored
            content.contentId = UUID().uuidString

            _ = storage.set(slot, content: content, in: groupId)
            // PK-5 (v2.10.15): 经核对 SlotStorage.set / writeSlotContent 并不落盘 content.label
            // （仅通过 getLabel 保留槽位目录里已有的旧 label.txt）。导入写入的是全新槽位目录，
            // 旧 label 为空，故 set 不会持久化包内标签——setLabel 是必要的第二次写入，不能删除。
            if let label = packSlot.label, !label.isEmpty {
                storage.setLabel(slot, label: label, in: groupId)
            }
            written += 1
        }
        return written
    }

    // MARK: - 页/组创建（含去重与容错）

    // PK-3 (v2.10.30): 覆盖导入前对被覆盖组目录做「磁盘级 rename 备份」的句柄，用于成功后删除或失败时回滚。
    private struct GroupDirBackup {
        let groupId: String
        let groupDir: URL       // 组在磁盘上的原目录（special_slots/<groupId>/）
        let backupDir: URL?     // 已 rename 到的备份目录；nil 表示备份时原目录不存在，无需还原
    }

    /// PK-3 (v2.10.30): 覆盖导入前，用磁盘级 moveItem（rename，不占用新磁盘空间）把被覆盖组目录整体
    /// 移到「同卷」备份路径。返回句柄供导入成功后删除、或失败时把备份原样 rename 回原位。
    ///
    /// 相比旧的「内存快照 + storage.set 回滚」：storage.set 需分配新空间，若失败诱因是磁盘满，回滚同样
    /// 失败并被 try? 吞掉，导致原数据丢失；而 rename 回滚是空间无关操作，磁盘满也能可靠还原。
    ///
    /// 备份目录刻意放在 special_slots 根下（与原组目录同一卷），保证 moveItem 是原子 rename 而非跨卷拷贝；
    /// 移走后立即重建一个空的原组目录，与旧 clearAllSlots「清空并保留空目录」的落地状态保持一致，随后
    /// writeSlots 会把新内容写入其中。
    private func backupGroupDirForOverwrite(_ groupId: String) throws -> GroupDirBackup {
        let fm = FileManager.default
        let groupDir = ClipSlotsPaths.specialSlots.appendingPathComponent(groupId, isDirectory: true)
        guard fm.fileExists(atPath: groupDir.path) else {
            // 索引有该组但磁盘无目录（罕见）——无需备份/还原。
            return GroupDirBackup(groupId: groupId, groupDir: groupDir, backupDir: nil)
        }
        let backupDir = ClipSlotsPaths.specialSlots
            .appendingPathComponent(".import_backup_\(groupId)_\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.moveItem(at: groupDir, to: backupDir)
        } catch {
            throw PackImportError.writeFailed("备份被覆盖组「\(groupId)」目录失败：\(error.localizedDescription)")
        }
        // rename 会失效该组 SlotStorage 的内存缓存指纹，且后续 writeSlots 的 set() 会重建目录并刷新缓存；
        // 这里主动清一次缓存，确保覆盖过程中任何对该组的读取都反映「已清空」的新状态。
        storage.invalidateContentCaches()
        // 重建空的原组目录，保持与旧 clearAllSlots 一致的「空目录存在」落地状态。
        try? fm.createDirectory(at: groupDir, withIntermediateDirectories: true)
        return GroupDirBackup(groupId: groupId, groupDir: groupDir, backupDir: backupDir)
    }

    /// 新页（无名称冲突场景），失败返回 nil。
    private func createPageDirectly(name: String) -> String? {
        createUniquePage(baseName: name)
    }

    /// 创建页面，若名称冲突则追加数字后缀重试。返回新页 id。
    private func createUniquePage(baseName: String) -> String? {
        let base = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = nameCandidates(base: base.isEmpty ? "导入页面" : base)
        for name in candidates {
            if let result = try? storage.createPage(name: name, withDefaultGroup: false) {
                return result.page.id
            }
        }
        return nil
    }

    /// 在指定页面创建组，若名称冲突则追加数字后缀重试。返回新组 id。
    private func createUniqueGroup(baseName: String, inPage pageId: String) -> String? {
        let base = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = nameCandidates(base: base.isEmpty ? "导入组" : base)
        for name in candidates {
            do {
                let group = try storage.createSpecialSlot(name: name, pageId: pageId)
                return group.id
            } catch SpecialSlotError.duplicateName {
                continue   // 换下一个候选名
            } catch {
                return nil // 其它错误（如达到每页上限）直接失败
            }
        }
        return nil
    }

    /// 生成候选名序列：原名、原名-2、原名-3 …（各自截断到 30 字符以内）。
    private func nameCandidates(base: String) -> [String] {
        var out: [String] = [String(base.prefix(30))]
        for i in 2...20 {
            let suffix = "-\(i)"
            let head = String(base.prefix(max(1, 30 - suffix.count)))
            out.append(head + suffix)
        }
        return out
    }

    // MARK: - ZIP / JSON helpers

    /// PK-4 (v2.10.15): 用不可信的 manifest id 拼接子路径前做防穿越校验。将拼出的 URL 做
    /// standardize（解析 `..`/`.`）后，验证其仍位于 root 之内；否则返回 nil，调用方跳过。
    /// 避免 `../` 逃逸出临时解压目录读取包外任意文件（Zip-Slip 读侧信息泄露）。
    private func safeChildURL(in root: URL, component: String, isDirectory: Bool) -> URL? {
        let resolved = root.appendingPathComponent(component, isDirectory: isDirectory).standardizedFileURL
        let rootResolved = root.standardizedFileURL
        let rootPrefix = rootResolved.path.hasSuffix("/") ? rootResolved.path : rootResolved.path + "/"
        guard resolved.path == rootResolved.path || resolved.path.hasPrefix(rootPrefix) else { return nil }
        return resolved
    }

    private func unzip(_ packURL: URL, to dest: URL, members: [String] = []) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            throw PackImportError.unzipFailed(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -q 静默，-o 覆盖；members 非空时仅解出指定成员。
        var args = ["-q", "-o", packURL.path]
        args.append(contentsOf: members)
        args.append(contentsOf: ["-d", dest.path])
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw PackImportError.unzipFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "unzip exit \(process.terminationStatus)"
            throw PackImportError.unzipFailed(msg)
        }
    }

    private func loadManifest(in root: URL) throws -> PackManifest {
        let url = root.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PackImportError.manifestMissing
        }
        do {
            return try loadJSON(PackManifest.self, from: url)
        } catch {
            throw PackImportError.manifestCorrupt(error.localizedDescription)
        }
    }

    /// 列出某页 groups/ 下的所有组，按 group.json 的 order 升序返回 (目录, 元信息)。
    private func loadGroups(in groupsRoot: URL) -> [(URL, PackGroup)] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: groupsRoot, includingPropertiesForKeys: nil) else { return [] }
        var out: [(URL, PackGroup)] = []
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let group = try? loadJSON(PackGroup.self, from: dir.appendingPathComponent("group.json")) else { continue }
            out.append((dir, group))
        }
        return out.sorted { $0.1.order < $1.1.order }
    }

    private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
