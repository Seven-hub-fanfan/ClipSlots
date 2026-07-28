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
    func estimateBytes(for selection: PackExportSelection) -> Int {
        var total = 0
        for pageSel in selection.pages {
            for group in pageSel.groups {
                for slot in 1...maxChildSlots {
                    let content = storage.get(slot, in: group.id)
                    if content.isEmpty && (storage.getLabel(slot, in: group.id)?.isEmpty ?? true) { continue }
                    for itemList in content.items {
                        for item in itemList { total += item.data.count }
                    }
                    for att in content.attachments {
                        if let data = att.data {
                            total += data.count
                        } else if let path = att.path, let size = fileSize(path) {
                            total += size
                        }
                    }
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
                    let content = storage.get(slot, in: group.id)
                    let label = storage.getLabel(slot, in: group.id)
                    let hasLabel = !(label?.isEmpty ?? true)
                    if content.isEmpty && !hasLabel { continue }

                    let slotDir = slotsDir.appendingPathComponent("\(slot)", isDirectory: true)
                    try createDir(slotDir)

                    // 附件原始字节外置到 attachments/，slot.json 内仅存文件引用。
                    var packAttachments: [PackAttachment] = []
                    var attachmentsDirCreated = false
                    let attachmentsDir = slotDir.appendingPathComponent("attachments", isDirectory: true)

                    for att in content.attachments {
                        var packAtt = PackAttachment(
                            id: att.id.uuidString,
                            name: att.name,
                            type: att.type.rawValue,
                            url: att.url,
                            file: nil
                        )
                        // 取字节：优先内联 data，其次回退去读其引用的本地源文件路径。
                        // P2-2 (v2.10.16): 此前用 `att.data ?? readFile(path)`，回源读取失败（源文件
                        // 已移动/删除/不可读/读到空）时结果为 nil，被静默跳过——附件名照写进 manifest
                        // 但 file 为空，导入后成为「有名无实」的空附件且无人察觉，造成字节静默丢失。
                        // 现改为：区分「本无字节的附件（纯 url/reference 型，无 data 也无 path）」与
                        // 「本应有字节但源文件读取失败的附件」，后者不再写入空壳条目，而是登记到
                        // failedAttachments 供上层提示用户，杜绝「名进 manifest、字节为空且无人知晓」。
                        var bytes: Data? = att.data
                        var sourceReadFailed = false
                        if bytes == nil, let path = att.path {
                            // 该附件无内联字节、声明了源文件路径，说明它本应携带字节——必须回源读取。
                            if let read = readFile(path), !read.isEmpty {
                                bytes = read
                            } else {
                                sourceReadFailed = true
                            }
                        }

                        if let bytes = bytes {
                            if !attachmentsDirCreated {
                                try createDir(attachmentsDir)
                                attachmentsDirCreated = true
                            }
                            let fileName = attachmentFileName(id: att.id.uuidString, name: att.name)
                            do {
                                try bytes.write(to: attachmentsDir.appendingPathComponent(fileName))
                            } catch {
                                throw PackExportError.ioFailed(error.localizedDescription)
                            }
                            packAtt.file = fileName
                            packAttachments.append(packAtt)
                        } else if sourceReadFailed {
                            // P2-2 (v2.10.16): 源文件不可读/为空——不写入「有名无实」的空壳附件，
                            // 改为登记失败清单（不 append 到 packAttachments，附件条目也不进 slot.json）。
                            let attName = att.name.isEmpty ? att.path! : att.name
                            failedAttachments.append("\(group.name) / 槽位 \(slot)：\(attName)")
                        } else {
                            // 本就无 data 且无 path（例如纯 url / reference 型附件）——属正常无字节附件，
                            // 保留其元信息引用（file 仍为 nil），不视为失败。
                            packAttachments.append(packAtt)
                        }
                    }

                    let packSlot = PackSlot(
                        slot: slot,
                        label: hasLabel ? label : content.label,
                        htmlSource: content.htmlSource,
                        contentId: content.contentId,
                        items: content.items,
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

    private func readFile(_ path: String) -> Data? {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return try? Data(contentsOf: url)
    }

    private func fileSize(_ path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return nil }
        return size
    }

    /// 生成安全且唯一的附件文件名：`<attachmentId>_<sanitizedName>`。
    private func attachmentFileName(id: String, name: String) -> String {
        let base = name.isEmpty ? "attachment" : name
        let sanitized = base.map { ch -> Character in
            if ch == "/" || ch == "\\" || ch == ":" || ch == "\n" || ch == "\r" || ch == "\0" { return "_" }
            return ch
        }
        let clean = String(sanitized).trimmingCharacters(in: .whitespaces)
        return "\(id)_\(clean.isEmpty ? "attachment" : clean)"
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
