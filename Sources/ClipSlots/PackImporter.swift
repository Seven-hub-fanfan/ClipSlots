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

    var errorDescription: String? {
        switch self {
        case .unzipFailed(let s): return "解压失败：\(s)"
        case .manifestMissing: return "包内缺少 manifest.json，不是有效的槽位包"
        case .manifestCorrupt(let s): return "manifest.json 解析失败：\(s)"
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

        for manifestPage in manifest.pages {
            let pageDir = pagesRoot.appendingPathComponent(manifestPage.id, isDirectory: true)
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
                        result.errors.append("创建页面「\(packPage.name)」失败")
                        continue
                    }
                    targetPageId = newId
                case .overwrite:
                    targetPageId = existingPage!.id
                    overwritingExistingPage = true
                }
            } else {
                guard let newId = createPageDirectly(name: packPage.name) else {
                    result.errors.append("创建页面「\(packPage.name)」失败")
                    continue
                }
                targetPageId = newId
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
                            result.errors.append("创建槽位组「\(packGroup.name)」失败")
                            result.skippedGroups += 1
                            continue
                        }
                        targetGroupId = newId
                    case .overwrite:
                        targetGroupId = existingGroup.id
                        try? storage.clearAllSlots(in: targetGroupId)
                    }
                } else {
                    // 无冲突或新页：始终新建组（新 UUID），绝不覆盖本地已有组。
                    guard let newId = createUniqueGroup(baseName: packGroup.name, inPage: targetPageId) else {
                        result.errors.append("创建槽位组「\(packGroup.name)」失败（可能已达每页上限）")
                        result.skippedGroups += 1
                        continue
                    }
                    targetGroupId = newId
                }

                let slotCount = writeSlots(from: slotsRoot, declaredSlots: packGroup.slots, into: targetGroupId)
                result.importedGroups += 1
                result.importedSlots += slotCount
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
                    data = try? Data(contentsOf: attachmentsDir.appendingPathComponent(file))
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
            if let label = packSlot.label, !label.isEmpty {
                storage.setLabel(slot, label: label, in: groupId)
            }
            written += 1
        }
        return written
    }

    // MARK: - 页/组创建（含去重与容错）

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
