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

        // P2-9 (v2.10.16): 覆盖模式下对「已有组」会先 clearAllSlots 清空原内容，而 PK-3 回滚只删除
        // 本次新建的页/组，被清空的已有组既不在 createdGroupIds 范围内又已丢失原内容，回滚无法恢复。
        // 改为采用「快照恢复」（方案 B）：覆盖前先把被覆盖组的原槽位内容+标签快照到内存并登记到此清单，
        // catch 回滚时先删新建页/组，再把每个被覆盖组从快照原样写回，确保中途失败不丢原数据。
        var overwrittenSnapshots: [GroupSnapshot] = []

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
                        // P2-9 (v2.10.16): 覆盖前先把被覆盖组的原槽位内容+标签快照到内存并登记待恢复
                        // 清单，再清空。此前直接 clearAllSlots，一旦清空后、写入过程中抛错触发回滚，
                        // 原内容既不在 createdGroupIds 范围内又已被清空，将永久丢失。
                        overwrittenSnapshots.append(snapshotGroup(targetGroupId))
                        try storage.clearAllSlots(in: targetGroupId)
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

            // P2-9 (v2.10.16): 恢复被覆盖组的原内容（方案 B）。被覆盖组在清空后可能已写入了部分
            // 新槽位，故恢复前先再次 clearAllSlots 抹掉半成品，再从快照逐槽写回内容与标签，使其回到
            // 导入前的状态。注意：被覆盖组均为「已有组」，与上面删除的 createdGroupIds 互不相交，
            // 故两段回滚互不影响；标签需经 setLabel 单独写回（PK-5：set 不落盘 content.label）。
            for snap in overwrittenSnapshots {
                try? storage.clearAllSlots(in: snap.groupId)
                for (slot, content) in snap.contents {
                    _ = storage.set(slot, content: content, in: snap.groupId)
                }
                for (slot, label) in snap.labels {
                    storage.setLabel(slot, label: label, in: snap.groupId)
                }
            }
            throw error
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

    // P2-9 (v2.10.16): 覆盖模式下被清空组的内存快照，用于导入失败时回滚恢复原内容。
    private struct GroupSnapshot {
        let groupId: String
        let contents: [Int: SlotContent]   // 原槽位内容（snapshot 返回，仅含有内容的槽位）
        let labels: [Int: String]          // 原槽位标签（getLabel 逐槽读取，仅含非空标签）
    }

    /// P2-9 (v2.10.16): 快照某组当前所有槽位的内容与标签，供覆盖失败时回滚恢复。
    /// 注意：不直接用 storage.snapshot(in:)，因为它只返回内存缓存（cache 由 get 惰性填充），
    /// 若被覆盖组的某些槽位从未被读取过，缓存缺失会导致快照不完整、恢复时丢内容。改为对
    /// 1...maxChildSlots 逐槽 get（get 会按磁盘指纹在必要时重读磁盘）以拿到真实的落盘内容；
    /// 标签同样逐槽 getLabel（PK-5：标签独立于内容存于 label.txt，需单独快照并经 setLabel 写回）。
    private func snapshotGroup(_ groupId: String) -> GroupSnapshot {
        var contents: [Int: SlotContent] = [:]
        var labels: [Int: String] = [:]
        for slot in 1...maxChildSlots {
            let content = storage.get(slot, in: groupId)
            if !content.isEmpty {
                contents[slot] = content
            }
            if let label = storage.getLabel(slot, in: groupId), !label.isEmpty {
                labels[slot] = label
            }
        }
        return GroupSnapshot(groupId: groupId, contents: contents, labels: labels)
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
