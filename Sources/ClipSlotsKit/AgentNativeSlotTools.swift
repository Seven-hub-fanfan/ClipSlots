import AppKit
import Foundation

/// Typed data-layer tools. No executable lookup, argv dispatch, shell or subprocess.
/// The legacy CLI adapter shares the schemas, but is not used to execute these tools.
public actor AgentNativeSlotTools: AgentToolExecuting {
    public nonisolated static let readers: Set<String> = [
        "list_slots", "read_slot", "search_slots", "list_groups", "list_pages"
    ]
    private let storage: SpecialSlotStorage
    private let lock: StorageLock

    public init(storage: SpecialSlotStorage = .shared, lock: StorageLock = .shared) {
        self.storage = storage
        self.lock = lock
    }

    public nonisolated func specs() -> [AgentToolSpec] {
        AgentBuiltinTools().specs().map { spec in
            var parameters = spec.parameters.objectValue ?? [:]
            if var properties = parameters["properties"]?.objectValue {
                if properties["slot"] != nil {
                    properties["slot"] = ["type": "integer", "minimum": 1, "maximum": 99]
                }
                if !Self.readers.contains(spec.name), properties["slot"] != nil {
                    properties["expected_revision"] = ["type": "string",
                        "description": "可选：read_slot 返回的 revision；不一致则拒绝写入。"]
                }
                parameters["properties"] = .object(properties)
                parameters["additionalProperties"] = false
            }
            return AgentToolSpec(name: spec.name,
                description: spec.description.replacingOccurrences(of: "CLI 会", with: "数据层会"),
                parameters: .object(parameters), originLabel: "本地数据")
        }
    }

    public func execute(call: AgentToolCall) async -> AgentToolResult {
        do {
            try Task.checkCancellation()
            guard let spec = specs().first(where: { $0.name == call.name }) else {
                return .failure("未启用此数据工具。", code: "TOOL_NOT_ENABLED")
            }
            let args = try call.arguments()
            try GenerationSchema.validate(args, schema: spec.parameters)
            if call.name == "paste_slot" {
                let content = try lock.withLock(timeout: 0.5) { () throws -> SlotContent in
                    guard !lock.isDegraded else { throw NativeSlotFailure("LOCK_UNAVAILABLE", "存储锁不可用。") }
                    let target = try group(args, index: storage.loadIndex())
                    guard let slot = args["slot"]?.intValue, (1...slotCount).contains(slot),
                          let content = storage.getOrUnknown(slot, in: target.id), !content.isEmpty else {
                        throw NativeSlotFailure("SLOT_EMPTY", "槽位为空或不可读取。")
                    }
                    if let expected = args["expected_revision"]?.stringValue, expected != content.contentId {
                        throw NativeSlotFailure("REVISION_CONFLICT", "槽位已改变，请重新读取。")
                    }
                    return content
                }
                // A stdio process may service the main dispatch queue on a worker
                // thread. Avoid ClipboardManager's Thread.isMainThread recursion.
                let copied = await Self.copyToPasteboard(content)
                guard copied else { throw NativeSlotFailure("PASTE_FAILED", "复制失败。") }
                return .init(content: try JSONValue.object(["ok": true, "copied": true,
                    "backend": "native_data_layer", "cli_required": false,
                    "summary": "已复制到剪贴板，可按 Command+V 粘贴"]).encodedText(), summary: "已复制到剪贴板")
            }
            // File decoding precedes the storage lock; large image IO never holds it.
            var attachments: [SlotContent.SlotAttachment]?
            var thumbnail: Data?
            if call.name == "write_attachment" {
                guard let files = args["files"]?.arrayValue, !files.isEmpty, files.count <= 100 else {
                    throw NativeSlotFailure("MISSING_FILES", "需要 1–100 个真实文件。")
                }
                attachments = try files.map { value in
                    guard let path = value.stringValue else { throw NativeSlotFailure("BAD_ARGUMENTS", "文件路径无效。") }
                    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
                    let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
                    guard attrs.isRegularFile == true, attrs.isReadable == true else {
                        throw NativeSlotFailure("FILE_NOT_FOUND", "文件不存在或不可读取：\(url.lastPathComponent)")
                    }
                    return .init(name: url.lastPathComponent,
                        type: SlotContent.imageFileExtensions.contains(url.pathExtension.lowercased()) ? .image : .file,
                        path: url.path, originalPath: url.path)
                }
            }
            if call.name == "set_thumbnail" {
                let url = URL(fileURLWithPath: (try text(args, "image") as NSString).expandingTildeInPath)
                guard let image = NSImage(contentsOf: url),
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw NativeSlotFailure("INVALID_IMAGE", "无法读取缩略图。")
                }
                let scale = min(1, 1024 / Double(max(cg.width, cg.height)))
                let width = max(1, Int(Double(cg.width) * scale)), height = max(1, Int(Double(cg.height) * scale))
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                    throw NativeSlotFailure("INVALID_IMAGE", "缩略图解码失败。")
                }
                context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                guard let resized = context.makeImage(),
                      let data = NSBitmapImageRep(cgImage: resized).representation(using: .jpeg,
                          properties: [.compressionFactor: 0.85]) else {
                    throw NativeSlotFailure("INVALID_IMAGE", "缩略图编码失败。")
                }
                thumbnail = data
            }
            let value = try lock.withLock(timeout: 0.5) {
                guard !lock.isDegraded else { throw NativeSlotFailure("LOCK_UNAVAILABLE", "存储锁不可用，未执行操作。") }
                return try perform(call.name, args: args, attachments: attachments, thumbnail: thumbnail)
            }
            return .init(content: try value.encodedText(), summary: value["summary"]?.stringValue ?? "本地数据操作完成")
        } catch let error as NativeSlotFailure {
            return .failure(error.message, code: error.code)
        } catch is CancellationError {
            return .failure("操作已取消。", code: "CANCELLED")
        } catch let error as StorageLockError {
            return .failure(error.localizedDescription, code: "LOCK_TIMEOUT")
        } catch let error as PageError {
            let code: String
            switch error {
            case .duplicateName: code = "DUPLICATE_NAME"
            case .pageNotFound: code = "PAGE_NOT_FOUND"
            case .defaultPageProtected: code = "DEFAULT_PAGE_PROTECTED"
            case .cannotDeleteLastPage: code = "CANNOT_DELETE_LAST_PAGE"
            case .emptyName: code = "BAD_ARGUMENTS"
            }
            return .failure(error.localizedDescription, code: code)
        } catch let error as SpecialSlotError {
            let code: String
            switch error {
            case .duplicateName: code = "DUPLICATE_NAME"
            case .maxSpecialSlotsReached: code = "PAGE_GROUP_LIMIT_REACHED"
            case .specialSlotNotFound: code = "GROUP_NOT_FOUND"
            case .defaultGroupProtected: code = "DEFAULT_GROUP_PROTECTED"
            case .cannotDeleteLastSpecialSlot: code = "CANNOT_DELETE_LAST_GROUP"
            case .indexCorrupted: code = "INDEX_CORRUPTED"
            case .invalidSpecialSlotName, .invalidGroupId: code = "BAD_ARGUMENTS"
            }
            return .failure(error.localizedDescription, code: code)
        } catch {
            return .failure(error.localizedDescription, code: "NATIVE_DATA_ERROR")
        }
    }

    private func perform(_ name: String, args: JSONValue,
                         attachments: [SlotContent.SlotAttachment]?, thumbnail: Data?) throws -> JSONValue {
        let index = storage.loadIndex()
        func ok(_ values: [String: JSONValue]) -> JSONValue {
            var result = values
            result["ok"] = true; result["backend"] = "native_data_layer"; result["cli_required"] = false
            return .object(result)
        }
        if name == "list_pages" { return ok(["pages": try json(index.pages)]) }
        if name == "create_page" {
            let result = try storage.createPage(name: text(args, "name"),
                defaultGroupName: args["first_group_name"]?.stringValue)
            return ok(["page": try json(result.page),
                       "defaultGroup": try result.defaultGroup.map(json) ?? .null])
        }
        if name == "repair_index" { return ok(["action": .string(storage.forceRepair())]) }
        if name == "delete_page" {
            let id = try page(args, index: index, required: true)
            try storage.deletePage(id: id)
            return ok(["page_id": .string(id), "deleted": true])
        }
        if name == "create_group" {
            let group = try storage.createSpecialSlot(name: text(args, "name"),
                pageId: page(args, index: index))
            return ok(["group": try json(group), "id": .string(group.id)])
        }
        if name == "list_groups" {
            let pageID = args["page"] == nil ? nil : try page(args, index: index)
            return ok(["groups": try json(index.specialSlots.filter { pageID == nil || $0.pageId == pageID })])
        }
        if name == "rename_group" || name == "delete_group" {
            let group = try group(args, index: index, requireExplicit: true)
            if name == "rename_group" { try storage.renameSpecialSlot(id: group.id, name: text(args, "new_name")) }
            else { try storage.deleteSpecialSlot(id: group.id) }
            return ok(["group_id": .string(group.id), "deleted": .bool(name == "delete_group")])
        }
        if name == "list_slots" || name == "search_slots" {
            let groups: [SpecialSlot]
            if name == "search_slots", args["all_groups"] == true { groups = index.specialSlots }
            else if args["page"] != nil, args["group"] == nil {
                let id = try page(args, index: index)
                groups = index.specialSlots.filter { $0.pageId == id }
            } else { groups = [try group(args, index: index)] }
            let query = name == "search_slots" ? try text(args, "query").lowercased() : ""
            let limit = min(200, max(1, args["limit"]?.intValue ?? (name == "list_slots" ? 200 : 50)))
            var matches: [JSONValue] = []
            var total = 0
            for group in groups {
                let contents = storage.slotStorage(for: group.id).searchScanSnapshot(slotCount: slotCount)
                for slot in 1...slotCount {
                    guard let content = contents[slot] else { continue }
                    let label = storage.getLabel(slot, in: group.id) ?? ""
                    let haystack = [content.plainText ?? "", content.preview, label,
                                    content.attachments.map(\.name).joined(separator: "\n")].joined(separator: "\n")
                    guard query.isEmpty || haystack.lowercased().contains(query) else { continue }
                    total += 1
                    if matches.count < limit {
                        matches.append(["group": .string(group.id), "group_name": .string(group.name),
                            "page": .string(group.pageId), "slot": .number(Double(slot)),
                            "empty": .bool(content.isEmpty), "preview": .string(String(content.preview.prefix(240))),
                            "label": .string(label), "attachment_count": .number(Double(content.attachments.count))])
                    }
                }
            }
            return ok([name == "search_slots" ? "matches" : "slots": .array(matches),
                       "total": .number(Double(total)), "truncated": .bool(total > matches.count)])
        }
        let target = try group(args, index: index)
        guard let slot = args["slot"]?.intValue, (1...slotCount).contains(slot),
              var content = storage.getOrUnknown(slot, in: target.id) else {
            throw NativeSlotFailure("SLOT_OUT_OF_RANGE", "槽位不可读取或超出 1–\(slotCount)。")
        }
        if name == "read_slot" { return ok(try read(content, group: target.id, slot: slot)) }
        if let revision = args["expected_revision"]?.stringValue, revision != content.contentId {
            throw NativeSlotFailure("REVISION_CONFLICT", "槽位内容已改变，请重新读取后再写入。")
        }
        if name == "clear_slot" {
            guard storage.clear(slot, in: target.id),
                  storage.getOrUnknown(slot, in: target.id)?.isEmpty == true else {
                throw NativeSlotFailure("WRITE_FAILED", "清空失败。")
            }
            return ok(["cleared": true, "group": .string(target.id), "slot": .number(Double(slot))])
        }
        switch name {
        case "write_slot":
            if args["if_empty"] == true, !content.isEmpty { throw NativeSlotFailure("SLOT_NOT_EMPTY", "槽位非空。") }
            let body = AgentSlotBody(text: try text(args, "text", allowEmpty: true))
            content.items = body.items; content.htmlSource = body.htmlSource
        case "write_attachment":
            if args["replace"] == true { content.attachments = [] }
            content.attachments += attachments ?? []
        case "set_thumbnail":
            if args["if_absent"] == true, content.hasManualThumbnail {
                throw NativeSlotFailure("THUMBNAIL_ALREADY_SET", "已有手动缩略图。")
            }
            content.manualThumbnailId = UUID().uuidString
            content.pendingManualThumbnailData = thumbnail
        case "clear_thumbnail":
            guard content.hasManualThumbnail else { throw NativeSlotFailure("NO_MANUAL_THUMBNAIL", "没有手动缩略图。") }
            content.manualThumbnailId = nil; content.pendingManualThumbnailData = nil
        default: throw NativeSlotFailure("TOOL_NOT_ENABLED", "未启用此工具。")
        }
        if let label = args["label"]?.stringValue { content.label = label }
        content.contentId = UUID().uuidString; content.updatedAt = Date().timeIntervalSince1970
        guard storage.set(slot, content: content, in: target.id, replacingLabel: args["label"] != nil),
              let saved = storage.getOrUnknown(slot, in: target.id), saved.contentId == content.contentId else {
            throw NativeSlotFailure("WRITE_FAILED", "保存未通过回读校验。")
        }
        return ok(try read(saved, group: target.id, slot: slot))
    }

    private var slotCount: Int { min(99, max(1, AppConfig.load().slots)) }
    private func text(_ args: JSONValue, _ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = args[key]?.stringValue, allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeSlotFailure("BAD_ARGUMENTS", "缺少参数：\(key)")
        }
        return value
    }
    private func page(_ args: JSONValue, index: SpecialSlotIndex, required: Bool = false) throws -> String {
        guard let value = args["page"]?.stringValue else {
            if required { throw NativeSlotFailure("MISSING_PAGE", "需要明确指定页面。") }
            return index.currentPageId
        }
        if let exact = index.pages.first(where: { $0.id == value }) { return exact.id }
        let matches = index.pages.filter { $0.name == value }
        guard matches.count == 1 else { throw NativeSlotFailure("PAGE_NOT_FOUND", "页面不存在或名称不唯一。") }
        return matches[0].id
    }
    private func group(_ args: JSONValue, index: SpecialSlotIndex, requireExplicit: Bool = false) throws -> SpecialSlot {
        let pageID = args["page"] == nil ? nil : try page(args, index: index)
        let candidates = index.specialSlots.filter { pageID == nil || $0.pageId == pageID }
        if let value = args["group"]?.stringValue {
            if let exact = candidates.first(where: { $0.id == value }) { return exact }
            let matches = candidates.filter { $0.name == value }
            guard matches.count == 1 else {
                throw NativeSlotFailure(matches.isEmpty ? "GROUP_NOT_FOUND" : "AMBIGUOUS_GROUP", "组不存在或名称不唯一，请指定页面和组 ID。")
            }
            return matches[0]
        }
        guard !requireExplicit, let target = candidates.first(where: { $0.id == index.currentSpecialSlotId })
                ?? candidates.first else { throw NativeSlotFailure("GROUP_NOT_FOUND", "没有目标槽位组。") }
        return target
    }
    private func read(_ content: SlotContent, group: String, slot: Int) throws -> [String: JSONValue] {
        let body = content.plainText ?? ""
        return ["group": .string(group), "slot": .number(Double(slot)), "revision": .string(content.contentId),
            "text": .string(String(body.prefix(96000))), "text_truncated": .bool(body.count > 96000),
            "label": storage.getLabel(slot, in: group).map(JSONValue.string) ?? .null,
            "empty": .bool(content.isEmpty), "attachments": .array(content.attachments.map {
                ["id": .string($0.id.uuidString), "name": .string($0.name), "type": .string($0.type.rawValue)]
            }), "manual_thumbnail": .bool(content.hasManualThumbnail)]
    }
    private func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    @MainActor private static func copyToPasteboard(_ content: SlotContent) -> Bool {
        if content.items.isEmpty {
            let urls = content.attachments.compactMap { $0.materializedFileURL().map { $0 as NSURL } }
            guard !urls.isEmpty else { return false }
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.writeObjects(urls)
        }
        let items = content.items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for value in values { item.setData(value.data, forType: .init(value.type)) }
            return item
        }
        guard !items.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects(items)
    }
}

private struct NativeSlotFailure: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}
