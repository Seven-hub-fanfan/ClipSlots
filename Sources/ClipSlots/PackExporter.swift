import Foundation
import ClipSlotsKit

// MARK: - .clipslotspack 包格式 (v2.10.14)
//
// 「槽位包」本质是一个 ZIP，后缀改为 .clipslotspack，用于把若干页面/槽位组连同
// 附件原始文件一起导出成单个可分享文件。包内结构：
//
//   manifest.json                         ← 元信息（包版本、App 版本、导出时间、页/组摘要）
//   pages/{pageId}/page.json              ← 页面元信息（名称、顺序）
//   pages/{pageId}/groups/{groupId}/group.json     ← 组元信息（名称、图标、槽位顺序）
//   pages/{pageId}/groups/{groupId}/slots/{slot}/slot.json        ← 槽位主体内容
//   pages/{pageId}/groups/{groupId}/slots/{slot}/attachments/*    ← 附件原始文件
//
// 说明：本项目里子槽位由 (groupId, slot 1..N) 唯一确定，没有独立 UUID，因此
// slots/ 下用「槽位序号」作为目录名（slots/1、slots/2…）。附件原始字节被抽取到
// attachments/ 目录，slot.json 里仅保留引用文件名，避免 JSON 体积膨胀。

/// pack 顶层清单。
struct PackManifest: Codable {
    var version: String            // 包格式版本
    var appVersion: String         // 导出时的 App 版本
    var exportedAt: String         // ISO8601 时间戳
    var pages: [Page]

    struct Page: Codable {
        var id: String
        var name: String
        var groupCount: Int
        var slotCount: Int
    }
}

/// 页面元信息。
struct PackPage: Codable {
    var id: String
    var name: String
    var order: Int
}

/// 槽位组元信息。
struct PackGroup: Codable {
    var id: String
    var name: String
    var icon: String
    var colorHex: String?
    var order: Int
    var slots: [Int]               // 有内容的槽位序号（导入时据此扫描 slots/ 目录）
}

/// 单个槽位主体内容。附件字节外置到 attachments/，此处仅存元信息与文件引用。
struct PackSlot: Codable {
    var slot: Int
    var label: String?
    var htmlSource: String?
    var contentId: String
    var items: [[PasteboardItem]]
    var attachments: [PackAttachment]
}

/// 附件元信息。`file` 指向 attachments/ 目录内的原始文件名（若字节被外置）。
struct PackAttachment: Codable {
    var id: String
    var name: String
    var type: String               // SlotContent.AttachmentType 的 rawValue
    var url: String?
    var file: String?              // attachments/ 内的相对文件名
}

// MARK: - 导出选择范围

/// 导出选择：按页面组织，每个页面携带被选中的槽位组列表。
struct PackExportSelection {
    struct PageSelection {
        let page: SlotPage
        let groups: [SpecialSlot]
    }
    var pages: [PageSelection]

    var isEmpty: Bool { pages.allSatisfy { $0.groups.isEmpty } }

    var totalGroupCount: Int { pages.reduce(0) { $0 + $1.groups.count } }
}

// MARK: - PackExporter

enum PackExportError: Error, LocalizedError {
    case nothingSelected
    case zipFailed(String)
    case ioFailed(String)

    var errorDescription: String? {
        switch self {
        case .nothingSelected: return "未选择任何页面或槽位组"
        case .zipFailed(let s): return "打包失败：\(s)"
        case .ioFailed(let s): return "写入临时文件失败：\(s)"
        }
    }
}

/// 导出结果。P2-2 (v2.10.16): 承载导出过程中因源文件不可读/为空而未能打包的附件清单。
///
/// 背景：附件若无内联 data，会回退去读其引用的本地源文件；此前读取失败被 `try?` 静默吞掉，
/// 附件名仍写进 manifest 但字节为空，导入后成为「有名无实」的空附件且无人知晓。现在这类
/// 附件不再写入包，而是登记到 `failedAttachments`，导出照常完成并把清单返回给上层提示用户
/// （例如「X 个附件因源文件不可读未能打包」）。`failedAttachments` 为空即表示全部附件完整导出。
struct PackExportResult {
    // P2-2 (v2.10.16): 源文件已移动/删除/不可读/为空、未能写入包的附件描述清单。
    var failedAttachments: [String] = []
}

/// 负责把选中的页面/槽位组构建成目录树并压缩为 .clipslotspack。
struct PackExporter {
    static let packFormatVersion = "1.0"

    private let storage = SpecialSlotStorage.shared
    private let maxChildSlots: Int
    private let appVersion: String

    init(maxChildSlots: Int, appVersion: String) {
        self.maxChildSlots = max(1, maxChildSlots)
        self.appVersion = appVersion
    }

    // MARK: 体积预估

    /// 估算选中范围内所有槽位主体 + 附件的总字节数（用于导出前的大小提示）。
    ///
    /// PK-2 (v2.10.30): 旧实现对每个槽位调用 `storage.get`，其 `readSlotContent` 会把该槽位所有
    /// item `.bin` 以及 attachments.json（含内联附件字节）全部读进内存缓存——预估一个多 GB 的页面
    /// 会在「保存对话框弹出之前」就耗尽内存崩溃。改为「只走磁盘元数据」：直接遍历每个组的槽位目录，
    /// 用文件大小属性（resourceValues/.fileSizeKey）累加各常规文件字节数，全程不加载任何文件 Data。
    ///
    /// 说明：此估算基于「落盘字节」（内联附件在 attachments.json 中以 base64 存储，略大于原始字节），
    /// 且不包含「仅以外部路径引用、字节尚未内联落盘」的附件（若为拿到 path 而解码 attachments.json，
    /// 反而会把内联大字节读进内存，违背防 OOM 初衷）。作为导出前的体积提示，此近似值足够且绝不 OOM。
    func estimateBytes(for selection: PackExportSelection) -> Int {
        var total = 0
        // 特殊槽位在磁盘上的布局：special_slots/<groupId>/<slot>/（整数名的槽位子目录，含主体 item_*
        // /*.bin、content.json、attachments.json、label.txt）。ClipSlotsPaths.specialSlots 为公开常量。
        let groupsRoot = ClipSlotsPaths.specialSlots
        for pageSel in selection.pages {
            for group in pageSel.groups {
                let groupDir = groupsRoot.appendingPathComponent(group.id, isDirectory: true)
                for slot in 1...maxChildSlots {
                    let slotDir = groupDir.appendingPathComponent("\(slot)", isDirectory: true)
                    total += directorySizeOnDisk(slotDir)
                }
            }
        }
        return total
    }

    // MARK: 导出

    /// 构建目录树并压缩到 `destURL`（后缀 .clipslotspack）。
    /// P2-2 (v2.10.16): 返回 `PackExportResult`，其 `failedAttachments` 收集了因源文件不可读/为空
    /// 而未能打包的附件；导出仍会完成，上层可据此提示用户「X 个附件未能打包」。加 @discardableResult
    /// 以兼容忽略返回值的既有调用方。
    @discardableResult
    func export(_ selection: PackExportSelection, to destURL: URL) throws -> PackExportResult {
        guard !selection.isEmpty else { throw PackExportError.nothingSelected }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("clipslotspack_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw PackExportError.ioFailed(error.localizedDescription)
        }

        var manifestPages: [PackManifest.Page] = []
        // P2-2 (v2.10.16): 累积「有名无字节」而被跳过的附件描述，导出结束后随结果返回。
        var failedAttachments: [String] = []
        let pagesRoot = root.appendingPathComponent("pages", isDirectory: true)

        for pageSel in selection.pages where !pageSel.groups.isEmpty {
            let page = pageSel.page
            let pageDir = pagesRoot.appendingPathComponent(page.id, isDirectory: true)
            let groupsDir = pageDir.appendingPathComponent("groups", isDirectory: true)
            try createDir(groupsDir)

            try writeJSON(PackPage(id: page.id, name: page.name, order: page.order),
                          to: pageDir.appendingPathComponent("page.json"))

            var pageSlotCount = 0
            for group in pageSel.groups {
                let groupDir = groupsDir.appendingPathComponent(group.id, isDirectory: true)
                let slotsDir = groupDir.appendingPathComponent("slots", isDirectory: true)
                try createDir(slotsDir)

                var writtenSlots: [Int] = []
                for slot in 1...maxChildSlots {
                    // D-2 (v2.10.31): 旧实现调用 storage.get(slot,in:)——其 readSlotContent 会把该槽位所有
                    // item 的 .bin 以及 attachments.json（含内联附件字节）整块读进内存，并常驻 SlotStorage
                    // 的 in-memory cache；导出一个含大量/超大槽位的页面时，缓存随槽位不断累积直至 OOM。
                    // 改为直接从磁盘按需读取该槽位目录（special_slots/<groupId>/<slot>/），读完即释放、不污染
                    // 也不常驻任何缓存；大附件（D-1 起以 path 引用落盘、不再内联）经下方 att.path 分支流式
                    // copyItem 写出，全程不进内存。
                    let disk = readSlotFromDisk(groupId: group.id, slot: slot)
                    let label = storage.getLabel(slot, in: group.id)
                    let hasLabel = !(label?.isEmpty ?? true)
                    if disk.isEmpty && !hasLabel { continue }

                    let slotDir = slotsDir.appendingPathComponent("\(slot)", isDirectory: true)
                    try createDir(slotDir)

                    // 附件原始字节外置到 attachments/，slot.json 内仅存文件引用。
                    var packAttachments: [PackAttachment] = []
                    var attachmentsDirCreated = false
                    let attachmentsDir = slotDir.appendingPathComponent("attachments", isDirectory: true)

                    for (attIndex, att) in disk.attachments.enumerated() {
                        var packAtt = PackAttachment(
                            id: att.id.uuidString,
                            name: att.name,
                            type: att.type.rawValue,
                            url: att.url,
                            file: nil
                        )
                        // 取字节：优先内联 data（已在内存），其次回退到其引用的本地源文件路径。
                        // P2-2 (v2.10.16): 区分「本无字节的附件（纯 url/reference 型）」与「本应有字节但
                        // 源文件不可读/为空的附件」，后者登记到 failedAttachments 而非写入空壳条目。
                        // PK-3 (v2.10.30): 外置源文件不再用 `Data(contentsOf:)` 整体读入内存再写出（单个
                        // 2GB 视频即可 OOM），改为先用元数据做存在性/非空探测，再用 `FileManager.copyItem`
                        // 流式拷贝到 attachments/ 暂存目录——全程不把文件内容加载进内存。
                        if let data = att.data {
                            // 内联字节：已在内存中，直接写出（不引入额外内存放大）。
                            if !attachmentsDirCreated {
                                try createDir(attachmentsDir)
                                attachmentsDirCreated = true
                            }
                            let fileName = attachmentFileName(index: attIndex, id: att.id.uuidString, name: att.name)
                            do {
                                try data.write(to: attachmentsDir.appendingPathComponent(fileName))
                            } catch {
                                throw PackExportError.ioFailed(error.localizedDescription)
                            }
                            packAtt.file = fileName
                            packAttachments.append(packAtt)
                        } else if let path = att.path {
                            // 无内联字节但声明了源文件路径——本应携带字节，须回源。用元数据探测：文件
                            // 缺失/为目录/不可 stat/为空（size == 0）均视为「源读取失败」，与旧 readFile 语义一致。
                            if let size = regularFileSize(path), size > 0 {
                                if !attachmentsDirCreated {
                                    try createDir(attachmentsDir)
                                    attachmentsDirCreated = true
                                }
                                let fileName = attachmentFileName(index: attIndex, id: att.id.uuidString, name: att.name)
                                let destURL = attachmentsDir.appendingPathComponent(fileName)
                                do {
                                    // copyItem 目标已存在会报错；文件名前缀含唯一附件 id，碰撞极罕见，仍稳妥清理。
                                    if FileManager.default.fileExists(atPath: destURL.path) {
                                        try FileManager.default.removeItem(at: destURL)
                                    }
                                    // 流式拷贝：不把文件读进内存，从根本上规避大文件 OOM。
                                    try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destURL)
                                } catch {
                                    throw PackExportError.ioFailed(error.localizedDescription)
                                }
                                packAtt.file = fileName
                                packAttachments.append(packAtt)
                            } else {
                                // P2-2 (v2.10.16): 源文件不可读/为空——不写入「有名无实」的空壳附件，
                                // 改为登记失败清单（不 append 到 packAttachments，附件条目也不进 slot.json）。
                                let attName = att.name.isEmpty ? path : att.name
                                failedAttachments.append("\(group.name) / 槽位 \(slot)：\(attName)")
                            }
                        } else {
                            // 本就无 data 且无 path（例如纯 url / reference 型附件）——属正常无字节附件，
                            // 保留其元信息引用（file 仍为 nil），不视为失败。
                            packAttachments.append(packAtt)
                        }
                    }

                    let packSlot = PackSlot(
                        slot: slot,
                        // 特殊槽位的 label 仅落盘在 label.txt（经 getLabel 读取），其余分支无内联 label；
                        // htmlSource 从未持久化到特殊槽位磁盘（与 storage.get 的返回一致），故为 nil。
                        label: hasLabel ? label : nil,
                        htmlSource: nil,
                        contentId: disk.contentId,
                        items: disk.items,
                        attachments: packAttachments
                    )
                    try writeJSON(packSlot, to: slotDir.appendingPathComponent("slot.json"))
                    writtenSlots.append(slot)
                }

                let packGroup = PackGroup(
                    id: group.id,
                    name: group.name,
                    icon: group.icon,
                    colorHex: group.colorHex,
                    order: group.order,
                    slots: writtenSlots
                )
                try writeJSON(packGroup, to: groupDir.appendingPathComponent("group.json"))
                pageSlotCount += writtenSlots.count
            }

            manifestPages.append(PackManifest.Page(
                id: page.id,
                name: page.name,
                groupCount: pageSel.groups.count,
                slotCount: pageSlotCount
            ))
        }

        let manifest = PackManifest(
            version: Self.packFormatVersion,
            appVersion: appVersion,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            pages: manifestPages
        )
        try writeJSON(manifest, to: root.appendingPathComponent("manifest.json"))

        try zipDirectory(contentsOf: root, to: destURL)

        // P2-2 (v2.10.16): 返回失败清单（可能为空），让上层能提示「X 个附件因源文件不可读未能打包」。
        return PackExportResult(failedAttachments: failedAttachments)
    }

    // MARK: - Helpers

    private func createDir(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw PackExportError.ioFailed(error.localizedDescription)
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            try data.write(to: url)
        } catch {
            throw PackExportError.ioFailed(error.localizedDescription)
        }
    }

    /// PK-2 (v2.10.30): 递归累加某目录下所有「常规文件」的字节数，仅读取文件大小元数据
    /// （resourceValues(.fileSizeKey)），绝不把任何文件内容读进内存——用于大页面的体积预估防 OOM。
    private func directorySizeOnDisk(_ url: URL) -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true, let size = values.fileSize else { continue }
            total += size
        }
        return total
    }

    /// PK-3 (v2.10.30): 仅通过元数据探测源文件是否为「可 stat 的常规文件」并返回其字节数，绝不把
    /// 文件内容读进内存（避免大文件 OOM）。返回 nil 表示文件缺失/为目录/无法读取资源属性。
    private func regularFileSize(_ path: String) -> Int? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize else { return nil }
        return size
    }

    // D-2 (v2.10.31): 直接从磁盘读出的槽位内容（绕过 storage.get 的整块内存载入与缓存常驻）。
    private struct DiskSlot {
        var items: [[PasteboardItem]] = []
        var attachments: [SlotContent.SlotAttachment] = []
        var contentId: String = UUID().uuidString
        var isEmpty: Bool { items.isEmpty && attachments.isEmpty }
    }

    /// D-2 (v2.10.31): 直接读取磁盘上的槽位目录（special_slots/<groupId>/<slot>/），复刻
    /// SlotStorage.readSlotContent 的落盘格式，构造导出所需内容——绕过 storage.get()：既不把内容常驻
    /// 进 SlotStorage 的 in-memory cache（导出大页面时缓存累积是主要 OOM 诱因），也让大附件（D-1 起以
    /// path 引用落盘、不再内联进 attachments.json）保持「仅有路径、无内联字节」，由导出主流程的 att.path
    /// 分支 copyItem 流式写出。返回结构读完即随作用域释放。
    private func readSlotFromDisk(groupId: String, slot: Int) -> DiskSlot {
        let fm = FileManager.default
        var result = DiskSlot()
        let slotDir = ClipSlotsPaths.specialSlots
            .appendingPathComponent(groupId, isDirectory: true)
            .appendingPathComponent("\(slot)", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: slotDir.path, isDirectory: &isDir), isDir.boolValue else { return result }

        // item_N/*.bin —— 与 SlotStorage 落盘格式一致：item_N 目录按名排序，文件名为
        // encodeSafeFileName(type)+".bin"（"/" 被替换为 "$slash$"），此处逆向解码类型。
        let itemDirs = ((try? fm.contentsOfDirectory(at: slotDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("item_") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for itemDir in itemDirs {
            let files = (try? fm.contentsOfDirectory(at: itemDir, includingPropertiesForKeys: nil)) ?? []
            var items: [PasteboardItem] = []
            for file in files where file.pathExtension == "bin" {
                let type = file.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "$slash$", with: "/")
                if let data = try? Data(contentsOf: file) {
                    items.append(PasteboardItem(type: type, data: data))
                }
            }
            if !items.isEmpty { result.items.append(items) }
        }

        // content.json → contentId（仅取字符串字段，用 JSONSerialization 避免依赖私有 Meta 类型）。
        let metaURL = slotDir.appendingPathComponent("content.json")
        if let metaData = try? Data(contentsOf: metaURL),
           let obj = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
           let cid = obj["contentId"] as? String, !cid.isEmpty {
            result.contentId = cid
        }

        // attachments.json → [SlotAttachment]。大附件此处仅携带 path（无内联 data），不占内存。
        let attURL = slotDir.appendingPathComponent("attachments.json")
        if fm.fileExists(atPath: attURL.path),
           let attData = try? Data(contentsOf: attURL),
           let atts = try? JSONDecoder().decode([SlotContent.SlotAttachment].self, from: attData) {
            result.attachments = atts
        }
        return result
    }

    /// 生成安全且唯一的附件文件名：`<attachmentId>_<sanitizedName>`。
    // P1-2 (v2.10.36): 文件名加上槽位内下标前缀，保证「同一槽位内」附件文件名绝不碰撞。
    // 旧实现只用 `<id>_<name>`，声称 id 唯一故碰撞极罕见；但附件 id 在「复制槽位 / 包导入重建」等
    // 路径下可能出现重复，一旦同槽内两条附件 id 相同，导出时后者会覆盖前者（copyItem 分支先删同名目标、
    // 内联 data.write 直接覆盖）→ 静默丢附件/损坏。加下标前缀后，同槽内下标天然唯一，彻底杜绝该覆盖。
    private func attachmentFileName(index: Int, id: String, name: String) -> String {
        let base = name.isEmpty ? "attachment" : name
        let sanitized = base.map { ch -> Character in
            if ch == "/" || ch == "\\" || ch == ":" || ch == "\n" || ch == "\r" || ch == "\0" { return "_" }
            return ch
        }
        let clean = String(sanitized).trimmingCharacters(in: .whitespaces)
        return "\(index)_\(id)_\(clean.isEmpty ? "attachment" : clean)"
    }

    /// 用系统 /usr/bin/zip 压缩目录内容（不依赖第三方库）。
    private func zipDirectory(contentsOf dir: URL, to destURL: URL) throws {
        let fm = FileManager.default
        // 先压到临时 .zip，再移动到最终目标（.clipslotspack）。
        let tmpZip = fm.temporaryDirectory.appendingPathComponent("clipslotspack_out_\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: tmpZip) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -r 递归，-q 静默，-X 不存额外文件属性；从 dir 内执行，压缩当前目录所有内容。
        process.arguments = ["-r", "-q", "-X", tmpZip.path, "."]
        process.currentDirectoryURL = dir

        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw PackExportError.zipFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "zip exit \(process.terminationStatus)"
            throw PackExportError.zipFailed(msg)
        }

        do {
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: tmpZip, to: destURL)
        } catch {
            throw PackExportError.ioFailed(error.localizedDescription)
        }
    }
}
