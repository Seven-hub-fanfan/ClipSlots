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

    // D-1 (v2.10.31) / P0-2 (v2.10.50): 附件字节一律流式 copyItem 落盘为路径引用，绝不整块读进内存
    // （从根本上规避大文件/大批量导入 OOM）。原「<20MB 内联、>20MB 流式」的分界阈值已随全量流式化移除。

    // PACK-2 (v2.10.32): JSON 元数据（manifest.json / group.json / slot.json）读取上限（10MB）。
    // D-1 只给「附件字节」加了流式阈值，元数据仍无差别 Data(contentsOf:)。恶意包可放一个高压缩比的
    // 超大 manifest.json（ZIP 把数 GB 压到极小），解压后整块读入 + JSONDecoder 再翻倍即 OOM。读取前
    // 先用 fileSizeKey 探测大小，超限直接抛错，绝不整块读进内存。
    private static let maxJSONBytes = 10 * 1024 * 1024

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

    /// v2.10.58: 基于「内容」而非文件扩展名判断一个文件是否是有效的槽位包。
    ///
    /// 背景：此前导入端仅靠 `.clipslotspack` 扩展名来区分「包导入」与「普通文件写入槽位」，
    /// 一旦用户把导出的包改名（扩展名变化），导入就误走普通文件路径，把整个 ZIP 当作普通
    /// 文件塞进槽位。这里尝试仅解出并解析 `manifest.json`：解析成功即认定为槽位包，
    /// 从而不再依赖文件名。探测只解压 manifest.json，成本极低；任何失败都视为「不是包」。
    func isValidPack(at url: URL) -> Bool {
        (try? readManifest(from: url)) != nil
    }

    /// 执行导入。resolver 闭包在需要用户决策时被同步调用（应在主线程运行）。
    /// v2.10.39: onProgress 在后台线程被调用，用于驱动进度条；参数为 (已写入槽位数, 总槽位数, 当前组名)。
    @discardableResult
    func importPack(
        from packURL: URL,
        resolvePageConflict: (_ pageName: String) -> PackConflictResolution,
        resolveGroupConflict: (_ pageName: String, _ groupName: String) -> PackConflictResolution,
        onProgress: ((_ done: Int, _ total: Int, _ currentName: String) -> Void)? = nil
    ) throws -> PackImportResult {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("clipslotspack_in_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        // P2-3 (v2.10.53): 先清扫上次导入遗留的孤儿临时目录（崩溃/回滚失败留下的 .import_backup_ /
        // .rollback_discard_），既释放累积占用，又能从「备份是唯一副本」的中断态恢复数据；须在本次创建
        // 任何新备份之前执行。
        sweepStaleImportTempDirs()

        try unzip(packURL, to: tmp)
        let manifest = try loadManifest(in: tmp)
        let pagesRoot = tmp.appendingPathComponent("pages", isDirectory: true)

        // v2.10.39: 预统计总槽位数，供进度条显示分母。轻量遍历各页组的 slots 声明；
        // 声明为空时回退扫描 slots 目录，与 writeSlots 的口径保持一致。失败不影响导入，
        // 仅令进度条退化为不确定态（total=0）。
        let totalSlots = countTotalSlots(manifest: manifest, pagesRoot: pagesRoot)
        var doneSlots = 0
        onProgress?(0, totalSlots, "")

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

        // P1-2 (v2.10.35): 登记本次导入流式落盘到 imported_attachments/ 的大附件路径，供 catch 回滚清理，
        // 避免导入失败后这些独立于组目录的大文件成为无主孤儿永久残留。
        var importedAttachmentPaths: [URL] = []

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

                let slotCount = try writeSlots(from: slotsRoot, declaredSlots: packGroup.slots, into: targetGroupId, importedAttachmentPaths: &importedAttachmentPaths)
                result.importedGroups += 1
                result.importedSlots += slotCount
                // v2.10.39: 每写完一个组上报一次进度（组级粒度，足够驱动进度条）。
                doneSlots += slotCount
                onProgress?(doneSlots, totalSlots, packGroup.name)
            }
        }
        } catch {
            // P1-2 (v2.10.35): 先清理本次导入已流式落盘的大附件（imported_attachments/ 下），它们独立于组
            // 目录，rename/删组回滚都不会触及，不清理即成无主孤儿永久残留。放在回滚最前面，确保无论后续
            // 组/页回滚成败都先释放这些大文件占用的磁盘空间。
            for url in importedAttachmentPaths { try? fm.removeItem(at: url) }

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
                guard let backupDir = backup.backupDir else {
                    // D-4 (v2.10.31): backupDir == nil 表示覆盖时该组磁盘目录本不存在，backupGroupDirForOverwrite
                    // 会重建一个空目录并让 writeSlots 往里写——此刻 groupDir 里是「半写入的新内容」。旧逻辑
                    // 直接 continue 跳过，导致失败后半写入组目录残留（既没回滚也没清理）成为脏数据。这里补上
                    // 清理：把该半写入目录 removeItem 掉，保证导入失败时不留残物。
                    if fm.fileExists(atPath: backup.groupDir.path) {
                        do {
                            try fm.removeItem(at: backup.groupDir)
                        } catch {
                            NSLog("[ClipSlots] PackImporter D-4 回滚清理半写入组目录失败："
                                + "\(backup.groupDir.path)：\(error)")
                        }
                    }
                    continue
                }
                // D-3 (v2.10.31): 旧实现「先 removeItem 半写入 groupDir，再 moveItem 备份回来」两步非原子——
                // 若在「删掉半写入内容之后、把备份移回之前」崩溃/失败，正式位置将永久为空，原组数据永久丢失
                // （高危数据丢失）。改为「先落地新的再删旧的」：把半写入 groupDir 先 rename 到临时丢弃名（不删除）
                // → 再把备份 rename 到正式位置 → 确认成功后才删临时目录。任何时刻正式位置或备份至少有一份完整
                // 数据；备份未能就位时还会把半写入内容原样搬回，绝不让正式位置落到「空」。
                let discardDir = backup.groupDir.deletingLastPathComponent()
                    .appendingPathComponent(".rollback_discard_\(backup.groupId)_\(UUID().uuidString)", isDirectory: true)
                do {
                    var vacated = false
                    if fm.fileExists(atPath: backup.groupDir.path) {
                        try fm.moveItem(at: backup.groupDir, to: discardDir)  // 半写入内容先挪走，暂不删除
                        vacated = true
                    }
                    do {
                        try fm.moveItem(at: backupDir, to: backup.groupDir)   // 备份 rename 回正式位置
                    } catch {
                        // 备份未能就位：把刚挪走的半写入内容原样搬回，保证正式位置不为空，再抛出。
                        if vacated { try? fm.moveItem(at: discardDir, to: backup.groupDir) }
                        throw error
                    }
                    // 备份已完整就位，此时才删除挪到临时名的半写入内容（先落地新的再删旧的）。
                    if vacated { try? fm.removeItem(at: discardDir) }
                } catch {
                    // rename 回滚是空间无关操作，正常不会失败；万一失败也记录（不再静默吞掉），备份目录
                    // 仍原样保留在 special_slots 下（.import_backup_<groupId>_<uuid>）供人工恢复。
                    NSLog("[ClipSlots] PackImporter D-3 回滚失败：无法将备份 \(backupDir.path) 还原到 "
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

        // bug #1 (v2.10.33): belt-and-suspenders sweep of the process-wide inline image
        // caches after a bulk import. Each imported slot already got a fresh identity +
        // per-slot cache eviction above; this final purge guarantees the grid re-decodes
        // every visible slot from its own bytes so no local thumbnail can bleed onto an
        // imported slot even under an unforeseen cache-key coincidence. Cheap: caches are
        // lazily rebuilt on next render.
        SlotContent.purgeAllInlineImageCaches()

        // v2.10.66: 进度条收口。分母 totalSlots 预统计的是包内「声明」的槽位数，而 doneSlots 只累加
        // 实际写入成功的槽位——被跳过的组（resolveGroupConflict=.skip）与元数据损坏无法加载的槽位都不计入，
        // 因此正常成功路径下 doneSlots 常 < totalSlots，进度条永远停在 <100%。导入既已整体成功，这里补发
        // 一次满值，把进度条明确推到 100%（total=0 的不确定态下发 (0,0) 无副作用）。
        onProgress?(totalSlots, totalSlots, "")

        return result
    }

    // MARK: - 统计总槽位数（进度条分母）

    /// v2.10.39: 轻量预统计包内总槽位数，供进度条显示分母。遍历各页 groups 的 slots 声明，
    /// 声明为空时回退扫描 slots 目录（与 writeSlots 口径一致）。任何读取失败都被吞掉并跳过，
    /// 统计仅用于展示，绝不影响导入正确性；返回 0 时进度条退化为不确定态。
    private func countTotalSlots(manifest: PackManifest, pagesRoot: URL) -> Int {
        let fm = FileManager.default
        var total = 0
        for manifestPage in manifest.pages {
            guard let pageDir = safeChildURL(in: pagesRoot, component: manifestPage.id, isDirectory: true) else { continue }
            let groupsRoot = pageDir.appendingPathComponent("groups", isDirectory: true)
            for (groupDir, packGroup) in loadGroups(in: groupsRoot) {
                var slotNumbers = packGroup.slots
                if slotNumbers.isEmpty {
                    let slotsRoot = groupDir.appendingPathComponent("slots", isDirectory: true)
                    let dirs = (try? fm.contentsOfDirectory(at: slotsRoot, includingPropertiesForKeys: nil)) ?? []
                    slotNumbers = dirs.compactMap { Int($0.lastPathComponent) }
                }
                total += slotNumbers.filter { $0 >= 1 && $0 <= maxChildSlots }.count
            }
        }
        return total
    }

    // MARK: - 写入单组的槽位

    private func writeSlots(from slotsRoot: URL, declaredSlots: [Int], into groupId: String, importedAttachmentPaths: inout [URL]) throws -> Int {
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
                let attId = UUID()  // 槽位 UUID 始终新生成；也用作持久落盘的文件名前缀
                // P0-2 (v2.10.50): 附件字节全部流式落盘为路径引用，不再内联；data 恒为 nil，仅为兼容
                // SlotAttachment 构造与「仅本地引用」（att.file == nil）态而保留。
                let data: Data? = nil
                var persistentPath: String? = nil
                if let file = att.file {
                    // P1-2 (v2.10.18): 附件路径做 safeChildURL 校验，防止 Zip Slip 路径穿越读取包外文件。
                    if let safeURL = safeChildURL(in: attachmentsDir, component: file, isDirectory: false) {
                        // PACK-1 (v2.10.32): safeChildURL 用 standardizedFileURL，不解析符号链接；
                        // 而 /usr/bin/unzip 会原样恢复 symlink 条目。恶意包可放一个「名字正常、target
                        // 指向 ../../../etc/passwd」的符号链接附件——名字级 Zip Slip 校验全过，随后
                        // Data(contentsOf:)/copyItem 会跟随 symlink 读到解压目录外的任意本地文件当作
                        // 附件字节吸入用户数据，再分享即信息外泄。这里在读取前用 lstat 语义（不跟随链接）
                        // 判断是否符号链接，遇到即整体跳过并记录可读报错，绝不读取其目标。
                        let isSymlink = (try? safeURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                        if isSymlink {
                            NSLog("[ClipSlots] PackImporter PACK-1 拒绝符号链接附件（防越界读取包外文件）："
                                + "\(att.name)（条目 \(file)）")
                        } else if !resolvedURLStaysWithin(safeURL, root: attachmentsDir) {
                            // P0-1 (v2.10.34): PACK-1 的 `.isSymbolicLinkKey` 只判断路径「末段(leaf)」是否
                            // 软链，safeChildURL 又只用 standardizedFileURL 解析 `..`/`.`——两者都不检查
                            // 「中间目录组件」是否为软链。恶意包可放一个指向系统目录的软链【目录】条目
                            // （如 attachments/sub -> /etc），再令 file="sub/passwd"：名字级 Zip Slip 校验
                            // 与 leaf 软链判定全过，随后 Data(contentsOf:)/copyItem 跟随中间软链读到解压
                            // 目录外的 /etc/passwd 当作附件字节吸入用户数据（分享即外泄）。这里在真正读取
                            // 前用 resolvingSymlinksInPath() 把【每一级组件】的软链全解析出真实路径，再重做
                            // 一次「仍在 attachmentsDir 之内」的前缀校验；越界即整条附件跳过、绝不读其目标。
                            NSLog("[ClipSlots] PackImporter P0-1 拒绝越界附件（软链穿越解压目录外，防任意文件读取）："
                                + "\(att.name)（条目 \(file)）")
                        } else {
                        // P0-2 (v2.10.50): 附件字节【全部】流式化。D-1（v2.10.31）只给 >20MB 的大文件走
                        // copyItem 流式落盘，<20MB 仍用 `Data(contentsOf:)` 整块读入内存再内联进
                        // attachments.json——批量导入大量中等附件（几 MB × 上百个）时进程内存峰值仍可观，
                        // 且这块字节要等 JSONEncoder 把 attachments.json 编码落盘后才释放。这里统一为：
                        // 无论大小，所有附件都用 FileManager.copyItem（内核级流式拷贝、不进进程内存）落盘为
                        // 「路径引用」（data=nil, path=持久文件），彻底消除附件字节的 Data 中转与内联。
                        // ⚠️ 安全红线全部保留：上方 Zip Slip 名字校验、leaf 软链判定（PACK-1）、中间目录软链
                        // 越界校验（P0-1 v2.10.34）三重校验都在真正读取【之前】，safeURL 已通过校验才走到这里；
                        // 本改动只替换「搬运方式」（Data→copyItem），不触碰任一校验点。落盘路径同样登记
                        // importedAttachmentPaths，导入失败时 catch 回滚一并清理，绝不残留孤儿附件。
                        if let dest = copyLargeAttachmentToStore(from: safeURL, attachmentId: attId) {
                            persistentPath = dest.path
                            // P1-2 (v2.10.35): 登记本次流式落盘的附件路径。这些文件写在独立于组目录的
                            // imported_attachments/ 下，若随后某页/组创建失败触发 catch 回滚，原本只删组目录
                            // （rename 回滚）不会触及它们，遂成无主孤儿（可反复失败累积、可能含分享包中的
                            // 敏感文件）。这里记录路径清单，catch 回滚时一并清理。
                            importedAttachmentPaths.append(dest)
                        } else {
                            // 拷贝失败：记录可读报错，保留附件元信息（无字节），绝不静默把整块读进内存。
                            NSLog("[ClipSlots] PackImporter P0-2 附件流式落盘失败，已跳过其字节："
                                + "\(att.name)（源 \(safeURL.path)）")
                        }
                        }
                    }
                }
                // 附件 UUID 始终新生成；小文件字节内联，大文件以持久路径引用，路径不跨机还原。
                // v2.10.37: 保留导出时记录的 originalPath（本地文件引用）。当包内未内嵌字节
                // （att.file == nil，data/persistentPath 均为空）时，附件成为「仅本地引用」状态：
                // path/data 皆为空、仅携带 originalPath，粘贴前的可达性检测与附件面板断链角标
                // 会据此把它标记为断链，给出明确提示而非静默失败 / 破损缩略图。
                restored.append(SlotContent.SlotAttachment(
                    id: attId,
                    name: att.name,
                    type: type,
                    path: persistentPath,
                    url: att.url,
                    data: data,
                    originalPath: att.linkType == "localFile" ? att.originalPath : nil
                ))
            }

            var content = SlotContent()
            content.items = packSlot.items
            content.htmlSource = packSlot.htmlSource
            content.label = packSlot.label
            content.attachments = restored
            // bug #1 (v2.10.33): every imported slot MUST get a brand-new content identity
            // so it can never share a thumbnail-cache key (`contentId::updatedAt`) with a
            // pre-existing local slot. The old code minted a fresh `contentId` but reused
            // the default `updatedAt`; whatever the pack carried, we now overwrite BOTH and
            // then evict any (defensively) matching cache entry, so the grid always decodes
            // the imported slot's own bytes instead of bleeding a local slot's image.
            content.contentId = UUID().uuidString
            content.updatedAt = Date().timeIntervalSince1970
            SlotContent.invalidateInlineCaches(contentId: content.contentId, updatedAt: content.updatedAt)

            // P0-1 (v2.10.35): 此前 `_ = storage.set(...)` 直接丢弃返回值、`written += 1` 无条件自增。
            // 但 storage.set 的失败是「返回 false 而不抛异常」的软失败（锁超时 / invalidated / writeSlotContent
            // 抛错如磁盘满 / STG-2 幽灵组守卫），一旦发生：新内容根本没落盘，writeSlots 仍返回正数、do 块正常
            // 结束、不进 catch，从而完全绕过覆盖模式「先落新再删旧」的 rename 回滚，且成功尾段还会把承载原始
            // 数据的备份目录删除 → 被覆盖组数据永久丢失，UI 却提示「导入完成」。这里改为检查返回值：任一槽位
            // set 失败即抛 writeFailed，交由 importPack 的 catch 走 rename 回滚把原数据完整还原；计数也只在
            // 真正写入成功后自增，杜绝虚高统计。
            guard storage.set(slot, content: content, in: groupId) else {
                throw PackImportError.writeFailed("写入槽位 \(slot) 失败（组「\(groupId)」，可能磁盘已满或锁超时）")
            }
            // PK-5 (v2.10.15): 经核对 SlotStorage.set / writeSlotContent 并不落盘 content.label
            // （仅通过 getLabel 保留槽位目录里已有的旧 label.txt）。导入写入的是全新槽位目录，
            // 旧 label 为空，故 set 不会持久化包内标签——setLabel 是必要的第二次写入，不能删除。
            if let label = packSlot.label, !label.isEmpty {
                // P1 (v2.10.62): setLabel 是软失败（锁超时 / invalidated 返回 false 而不抛异常）。此前丢弃
                // 返回值 → 「内容进了、标签丢了」却仍计入成功、绕过回滚。改为校验：写标签失败即抛 writeFailed，
                // 交由 importPack 的 catch 走 rename 回滚把原数据完整还原，杜绝「内容对、标签缺」的静默不一致。
                guard storage.setLabel(slot, label: label, in: groupId) else {
                    throw PackImportError.writeFailed("写入槽位 \(slot) 标签失败（组「\(groupId)」，可能锁超时）")
                }
            }
            written += 1
        }
        return written
    }

    /// D-1 (v2.10.31): 把「超过内联阈值」的大附件从解压临时目录流式拷贝到持久附件目录，返回落盘 URL。
    /// 用 FileManager.copyItem（内核级流式拷贝，不把文件内容读进进程内存），从根本上规避大文件 OOM。
    /// 目标目录 dataRoot/imported_attachments/ 与其它「以 path 引用外部文件」的附件同一存储语义，导出/
    /// 展示均按路径读取；文件名以新生成的附件 UUID 为前缀避免碰撞。拷贝失败返回 nil（调用方记录并降级）。
    private func copyLargeAttachmentToStore(from src: URL, attachmentId: UUID) -> URL? {
        let fm = FileManager.default
        let dir = ClipSlotsPaths.dataRoot.appendingPathComponent("imported_attachments", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[ClipSlots] PackImporter D-1 无法创建持久附件目录 \(dir.path)：\(error)")
            return nil
        }
        let dest = dir.appendingPathComponent("\(attachmentId.uuidString)_\(src.lastPathComponent)")
        do {
            // copyItem 目标已存在会报错；文件名前缀含唯一附件 id，碰撞极罕见，仍稳妥清理。
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: src, to: dest)
            return dest
        } catch {
            NSLog("[ClipSlots] PackImporter D-1 流式拷贝大附件失败 \(src.path) → \(dest.path)：\(error)")
            return nil
        }
    }

    // MARK: - 页/组创建（含去重与容错）

    // PK-3 (v2.10.30): 覆盖导入前对被覆盖组目录做「磁盘级 rename 备份」的句柄，用于成功后删除或失败时回滚。
    private struct GroupDirBackup {
        let groupId: String
        let groupDir: URL       // 组在磁盘上的原目录（special_slots/<groupId>/）
        let backupDir: URL?     // 已 rename 到的备份目录；nil 表示备份时原目录不存在，无需还原
    }

    /// P2-3 (v2.10.53): 导入前清扫上一次导入（含进程崩溃 / 回滚失败）遗留在 special_slots 根下的孤儿临时
    /// 目录，避免其无限累积占用磁盘。两类前缀分别处理，且绝不删除数据的唯一副本：
    ///   - `.rollback_discard_*`：回滚时把「半写入新内容」挪走待丢弃的目录，纯废弃物 → 直接删除。
    ///   - `.import_backup_<groupId>_<uuid>`：覆盖导入前对被覆盖组做的磁盘级 rename 备份。
    ///       · 实况组目录存在且非空 → 组已完好（导入成功或已回滚），备份冗余 → 删除释放空间；
    ///       · 实况组目录缺失 / 为空 → 崩溃发生在「备份已挪走、新内容尚未写就」窗口，备份是原数据唯一副本
    ///         → rename 回原位恢复数据，绝不删除。
    private func sweepStaleImportTempDirs() {
        let fm = FileManager.default
        let root = ClipSlotsPaths.specialSlots
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for url in entries {
            let name = url.lastPathComponent
            if name.hasPrefix(".rollback_discard_") {
                try? fm.removeItem(at: url)
                continue
            }
            guard name.hasPrefix(".import_backup_") else { continue }
            // P2-2 (v2.10.54): 并发导入安全阈值。本清扫在启动时运行，若此刻【另一进程/实例】正有一场
            // 导入进行中——backupGroupDirForOverwrite 已把旧组 rename 成 .import_backup_ 并重建了空的原组
            // 目录，但 writeSlots 尚未把新内容写进去——原组目录会短暂为空，误触发下面「实况组为空 → 恢复
            // 备份」分支，把进行中导入的备份错误地覆盖回去，毁掉那场导入。故只清扫「足够老」（mtime 超过
            // 1 小时）的备份：进行中的导入其备份 mtime 必然很新，跳过它；只有确属上次崩溃/中断遗留的陈旧
            // 备份才参与恢复/删除。
            let backupAge: TimeInterval = {
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
                return Date().timeIntervalSince(mtime)
            }()
            if backupAge < 3600 {
                NSLog("[ClipSlots] PackImporter 启动清扫：跳过较新的备份 \(name)（\(Int(backupAge))s，疑似进行中的并发导入）")
                continue
            }
            // 解析 groupId：形如 .import_backup_<groupId>_<uuid>。groupId（UUID 或 "default"）与末段 uuid 均
            // 不含下划线，故 groupId = 去掉前缀后、最后一个 "_" 之前的部分。
            let rest = String(name.dropFirst(".import_backup_".count))
            guard let lastUnderscore = rest.lastIndex(of: "_") else { continue } // 命名异常，保守不动
            let groupId = String(rest[rest.startIndex..<lastUnderscore])
            guard !groupId.isEmpty else { continue }
            let groupDir = root.appendingPathComponent(groupId, isDirectory: true)
            let liveContents = (try? fm.contentsOfDirectory(atPath: groupDir.path)) ?? []
            if liveContents.isEmpty {
                // 实况组缺失 / 为空 → 备份是唯一副本，恢复它（绝不删除）。
                if fm.fileExists(atPath: groupDir.path) { try? fm.removeItem(at: groupDir) }
                do {
                    try fm.moveItem(at: url, to: groupDir)
                    storage.invalidateContentCaches()
                    NSLog("[ClipSlots] PackImporter 启动清扫：从孤儿备份恢复组 \(groupId)（上次导入未完成）")
                } catch {
                    NSLog("[ClipSlots] PackImporter 启动清扫：恢复孤儿备份失败 \(url.path)：\(error)（备份原样保留）")
                }
            } else {
                // 实况组已有内容 → 备份冗余 → 删除释放空间。
                try? fm.removeItem(at: url)
            }
        }
    }

    /// PK-3 (v2.10.30): 覆盖导入前，用磁盘级 moveItem（rename，不占用新磁盘空间）把被覆盖组目录整体
    /// 移到「同卷」备份路径。返回句柄供导入成功后删除、或失败时把备份原样 rename 回原位。
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

    /// P0-1 (v2.10.34): 把 `url` 的软链【每一级路径组件】全部解析成真实路径后，判断其是否仍位于
    /// `root` 之内。`safeChildURL` 的 standardizedFileURL 只解析 `..`/`.`，`.isSymbolicLinkKey` 只查
    /// leaf——都无法拦截「中间目录组件是软链」的穿越。`resolvingSymlinksInPath()` 会逐级解析软链，
    /// 因此这里对 url 与 root 双方都解析后再做前缀比较，可堵住任意读侧软链穿越（读到解压目录外文件）。
    private func resolvedURLStaysWithin(_ url: URL, root: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = rootResolved.path.hasSuffix("/") ? rootResolved.path : rootResolved.path + "/"
        return resolved.path == rootResolved.path || resolved.path.hasPrefix(rootPrefix)
    }

    /// P0-1 (v2.10.34, 纵深防御): 在解压前拒绝任何含符号链接条目的包。/usr/bin/unzip 会原样恢复
    /// symlink 条目，恶意包借此放一个指向系统目录的软链目录，再让 slot.json 的附件 file 走该软链
    /// 读到包外任意文件（读侧路径穿越，读侧 `resolvedURLStaysWithin` 已能拦下）。这里用 `zipinfo`
    /// 的长列表格式（首列为 Unix 权限位，符号链接以 'l' 开头）在源头识别并整包拒绝，作为第二道防线。
    private func assertNoSymlinkEntries(_ packURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = [packURL.path]   // 默认长列表：每条目一行，首列为权限位如 `lrwxrwxrwx`
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw PackImportError.unzipFailed("无法预检包内符号链接：\(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "zipinfo exit \(process.terminationStatus)"
            throw PackImportError.unzipFailed("包内符号链接预检失败：\(msg)")
        }
        let listing = String(data: outData, encoding: .utf8) ?? ""
        for rawLine in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let first = line.split(separator: " ", omittingEmptySubsequences: true).first else { continue }
            // Unix 权限位固定 10 字符（如 `lrwxrwxrwx` / `-rw-r--r--`），首字符 'l' 即符号链接条目。
            // 头部（Archive:/Zip file size:）与尾部（"N files, ..."）不满足该形态，不会误判。
            if first.count == 10, first.hasPrefix("l") {
                throw PackImportError.unzipFailed("包内含符号链接条目，疑似路径穿越攻击，已拒绝导入：\(line)")
            }
        }
    }

    /// D-6 (v2.10.31): Zip Slip 防护。/usr/bin/unzip 会原样解出条目路径（含 `../` 或绝对路径），
    /// 恶意 .clipslotspack 可借此写到目标解压根目录之外覆盖任意文件。这里在真正解压前用 `zipinfo -1`
    /// 列出包内所有条目，逐个校验：拒绝绝对路径，以及经 standardizedFileURL 解析 `..`/`.` 后仍逃逸出
    /// dest 根目录的条目（前缀匹配）。一旦发现越界即抛错使整个导入失败，绝不解压。
    private func assertNoZipSlip(_ packURL: URL, extractingInto dest: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", packURL.path]   // -1：每行仅输出一个条目路径
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw PackImportError.unzipFailed("无法预检包内条目：\(error.localizedDescription)")
        }
        // 先读干管道再 wait，避免大列表撑满管道缓冲导致死锁。
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "zipinfo exit \(process.terminationStatus)"
            throw PackImportError.unzipFailed("包内条目预检失败：\(msg)")
        }

        let listing = String(data: outData, encoding: .utf8) ?? ""
        let destRoot = dest.standardizedFileURL
        let rootPrefix = destRoot.path.hasSuffix("/") ? destRoot.path : destRoot.path + "/"
        for rawLine in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            let entry = String(rawLine)
            if entry.isEmpty { continue }
            // 绝对路径条目直接拒绝（zipinfo 会原样打印前导 `/`）。
            if entry.hasPrefix("/") {
                throw PackImportError.unzipFailed("包内条目为绝对路径，疑似恶意路径穿越，已拒绝导入：\(entry)")
            }
            let resolved = dest.appendingPathComponent(entry).standardizedFileURL
            guard resolved.path == destRoot.path || resolved.path.hasPrefix(rootPrefix) else {
                throw PackImportError.unzipFailed("包内条目路径越界（Zip Slip），已拒绝导入：\(entry)")
            }
        }
    }

    private func unzip(_ packURL: URL, to dest: URL, members: [String] = []) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            throw PackImportError.unzipFailed(error.localizedDescription)
        }

        // D-6 (v2.10.31): 解压前先做 Zip Slip 预检；发现越界条目直接抛错，绝不落盘。
        try assertNoZipSlip(packURL, extractingInto: dest)
        // P0-1 (v2.10.34): 再拒绝任何符号链接条目（纵深防御，配合读侧 resolvedURLStaysWithin）。
        try assertNoSymlinkEntries(packURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -q 静默，-o 覆盖；members 非空时仅解出指定成员。
        var args = ["-q", "-o", packURL.path]
        args.append(contentsOf: members)
        args.append(contentsOf: ["-d", dest.path])
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        // P2-2 (v2.10.53): 在 waitUntilExit 之前就开始抽干 stderr。unzip 遇坏包/大量警告可能向 stderr 写出
        // 超过管道缓冲（~64KB）的内容；若不提前读取，写端会阻塞在 write()，进程永不退出，waitUntilExit 随之
        // 永久挂起（导入卡死）。用后台线程 readDataToEndOfFile 持续抽干（进程退出关闭写端后读到 EOF 返回），
        // 主线程先等进程退出、再等抽干完成——drainGroup.wait() 建立 happens-before，errData 读取安全。
        var errData = Data()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // run() 抛错时进程从未启动，Foundation 不会关闭父进程侧的写端，后台 readDataToEndOfFile 会一直
            // 阻塞——手动关掉写端制造 EOF，让抽干线程退出后再 wait，避免死锁。
            try? errPipe.fileHandleForWriting.close()
            drainGroup.wait()
            throw PackImportError.unzipFailed(error.localizedDescription)
        }
        drainGroup.wait()
        guard process.terminationStatus == 0 else {
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
        // PACK-2 (v2.10.32): 读取前先探测文件大小，超过 10MB 直接拒绝，避免超大/高压缩比 JSON
        // 元数据整块读入内存触发 OOM。
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > Self.maxJSONBytes {
            throw PackImportError.manifestCorrupt(
                "JSON 文件过大（\(size) 字节，上限 \(Self.maxJSONBytes)），疑似恶意包，已拒绝读取：\(url.lastPathComponent)")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
