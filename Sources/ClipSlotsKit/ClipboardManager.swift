import AppKit

public struct PasteboardItem: Codable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

public struct SlotContent: Codable {
    public var items: [[PasteboardItem]] = []
    public var timestamp: Date = Date()
    public var label: String? = nil
    public var htmlSource: String? = nil
    // v2.7.61: Slot attachments - only visible and editable in node canvas
    // Empty array = disabled, no change to existing behavior
    public var attachments: [SlotAttachment] = []
    
    // 向后兼容：旧模板没有 attachments 字段时自动填充空数组
    enum CodingKeys: String, CodingKey {
        case items, timestamp, label, htmlSource, attachments, contentId, updatedAt
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // v2.8.2 (P1-B): decode leniently so a corrupt / partial / legacy payload
        // (e.g. missing items or timestamp) still loads with sensible defaults
        // instead of throwing and dropping the whole slot.
        items = try container.decodeIfPresent([[PasteboardItem]].self, forKey: .items) ?? []
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        label = try container.decodeIfPresent(String.self, forKey: .label)
        htmlSource = try container.decodeIfPresent(String.self, forKey: .htmlSource)
        attachments = try container.decodeIfPresent([SlotAttachment].self, forKey: .attachments) ?? []
        // v2.8.1 (P1-1): older persisted payloads predate contentId/updatedAt.
        // Decode leniently with sensible defaults so legacy data still loads.
        contentId = try container.decodeIfPresent(String.self, forKey: .contentId) ?? UUID().uuidString
        updatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? timestamp.timeIntervalSince1970
    }

    public init() {}

    public init(items: [[PasteboardItem]] = [], timestamp: Date = Date(), label: String? = nil, htmlSource: String? = nil, attachments: [SlotAttachment] = [], contentId: String = UUID().uuidString, updatedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.items = items
        self.timestamp = timestamp
        self.label = label
        self.htmlSource = htmlSource
        self.attachments = attachments
        self.contentId = contentId
        self.updatedAt = updatedAt
    }

    // MARK: - Slot Attachment

    public struct SlotAttachment: Codable, Identifiable {
        public var id: UUID = UUID()
        public var name: String
        public var type: AttachmentType
        public var path: String?
        public var url: String?
        public var data: Data?
        /// v2.10.37: 本地文件引用的「原始绝对路径」。仅对 image/file 类本地文件引用有意义：
        /// 记录该附件最初引用的本地源文件位置。用于 .clipslotspack 导入后——当包内未内嵌字节
        /// （只保留了路径引用）且 `path` 不可用时，据此做断链检测与提示，避免粘贴静默失败/破损缩略图。
        /// 可选字段，历史数据缺失即为 nil（Codable 向后兼容）。
        public var originalPath: String?
        /// v2.10.42（方案 B / 附件字节外置架构 Step 2）：外置字节文件的绝对路径，
        /// 指向 `{slotDir}/attachments/{id}.bin`。当附件字节已从 attachments.json 外置到
        /// 独立文件时，`data` 置 nil、本字段记录字节所在磁盘路径；`resolveData()` 在内存
        /// `data` 为空时据此懒加载。可选字段，历史数据缺失即为 nil（Codable 向后兼容）：
        ///   • 老数据（inline base64 `data`，无 storagePath）：首次读时懒迁移落盘并回填本字段。
        ///   • 纯路径引用 / url / reference 型附件：本字段始终为 nil（字节不由本机存储层管理）。
        public var storagePath: String?
        public var createdAt: Date = Date()

        public init(id: UUID = UUID(), name: String, type: AttachmentType, path: String? = nil, url: String? = nil, data: Data? = nil, originalPath: String? = nil, storagePath: String? = nil, createdAt: Date = Date()) {
            self.id = id
            self.name = name
            self.type = type
            self.path = path
            self.url = url
            self.data = data
            self.originalPath = originalPath
            self.storagePath = storagePath
            self.createdAt = createdAt
        }
    }

    public enum AttachmentType: String, Codable {
        case image
        case file
        case text
        case url
        case reference
    }

    /// Unique content identity. Regenerated on every save/overwrite. Used as the
    /// primary cache-breaker for thumbnails, SwiftUI View identity, and file paths.
    public var contentId: String = UUID().uuidString
    /// Monotonic timestamp updated on every save/overwrite. Combined with contentId
    /// to form the thumbnail cache key so that even same-contentId overwrites
    /// (impossible in practice but defensive) still miss the cache.
    public var updatedAt: TimeInterval = Date().timeIntervalSince1970

    /// v2.8.1 (P1-2): true when this snapshot was produced by `capture()` from an
    /// actually empty system pasteboard (vs. a default/never-captured value). Lets
    /// `restore()` know it should clear the pasteboard rather than no-op, so an
    /// injected paste payload is not left behind when the original clipboard was empty.
    /// Not persisted (absent from CodingKeys).
    public var capturedEmpty: Bool = false

    /// v2.9.3: unified empty-slot semantics. A slot is only empty when it has
    /// neither body items NOR attachments. Previously this was `items.isEmpty`,
    /// which made attachment-only slots (mode-C) look "empty" in GUI stats /
    /// thumbnails (ghost slots) and blocked CLI `paste`. Note `restore(_:)` still
    /// guards on `content.items.isEmpty` directly, so it is unaffected by this.
    public var isEmpty: Bool { items.isEmpty && attachments.isEmpty }

    /// Legacy hash — still available for diagnostics but no longer the primary
    /// cache key. The new key is `thumbnailKey(specialSlotId:slot:)`.
    public var contentHash: String {
        let totalBytes = items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } }
        return "\(timestamp.timeIntervalSince1970)-\(totalBytes)"
    }

    /// Composite cache key that scopes a thumbnail by special-slot, slot number,
    /// content identity, and save timestamp. Changing any dimension invalidates
    /// the cached thumbnail.
    /// Canonical set of pasteboard types that denote image data. v2.10.33 (bug #2):
    /// this is the single source of truth shared by `preview` (Kit), `hasImage`,
    /// `imageTypes`, `decodedInlineImage`, `decodedInlineThumbnail` and
    /// `inlineImagePointSize` (all in the app's SlotContent+Thumbnail extension). It
    /// covers standard UTIs (public.png/jpeg/tiff/heic/heif/gif/webp/bmp/…) AND the
    /// bare file-extension strings ("png"/"jpeg"/"heic"/…) that some legacy or imported
    /// slots stored instead of a full UTI. Before this, `hasImage` matched a broad UTI
    /// list while the decode paths only matched png/tiff/jpeg + `contains("image")`, so
    /// a heic/gif/webp/bare-extension image took the image branch yet decoded to nil and
    /// fell back to a "[png]"/"[heic]" TEXT preview instead of a thumbnail.
    public static let imagePasteboardTypes: Set<String> = [
        // Standard UTIs
        "public.png", "public.jpeg", "public.jpeg-2000", "public.tiff",
        "public.heic", "public.heif", "public.heics", "public.avci",
        "public.camera-raw-image", "com.compuserve.gif", "com.apple.icns",
        "com.microsoft.bmp", "public.webp", "org.webmproject.webp",
        // Bare file extensions (legacy / imported slots)
        "png", "jpg", "jpeg", "jpeg2000", "jp2", "tif", "tiff", "gif",
        "heic", "heif", "webp", "bmp", "icns"
    ]

    /// True when `type` denotes image data. Matches any type containing the substring
    /// "image" (covers `public.image` and vendor image UTIs) or any member of
    /// `imagePasteboardTypes`. Case-insensitive. v2.10.33 (bug #2).
    public static func isImagePasteboardType(_ type: String) -> Bool {
        let lower = type.lowercased()
        if lower.contains("image") { return true }
        return imagePasteboardTypes.contains(lower)
    }

    /// v2.10.85（预览显示文件图标而非真实内容）: pasteboard types that carry a
    /// **file ICON** rather than the file's real pixels. Copying a file in Finder
    /// puts `public.file-url` + `com.apple.icns` (the 1024px generic document icon)
    /// on the pasteboard. `com.apple.icns` is legitimately an image type (a real
    /// `.icns` pasted as data must still render), so it stays in
    /// `imagePasteboardTypes` — but when it is the ONLY image item AND a file URL
    /// exists, rendering it shows a PNG/PDF document icon instead of the file the
    /// user actually stored. Call sites use `prefersFileContentOverInlineIcon`.
    public static let iconOnlyPasteboardTypes: Set<String> = [
        "com.apple.icns", "icns", "com.apple.iconfamily", "apple icns format"
    ]

    /// True when `type` only ever carries a file icon (see `iconOnlyPasteboardTypes`).
    public static func isIconOnlyPasteboardType(_ type: String) -> Bool {
        iconOnlyPasteboardTypes.contains(type.lowercased())
    }

    public func thumbnailKey(specialSlotId: String, slot: Int) -> String {
        // v2.10.28 (fix 空槽位附件面板打开即关闭): an empty slot has no persisted
        // content.json, so `readSlotContent` mints a BRAND-NEW random `contentId`
        // on every disk read (see SlotStorage.readSlotContent legacy branch). Because
        // `contentForSlot` never trusts the in-memory copy for empty slots and always
        // falls back to `storage.get()`, each grid body re-evaluation produced a
        // different `contentId` → a different `thumbnailKey` → a changed SlotCardView
        // `.id()`. SwiftUI then destroyed and recreated the card (and with it the
        // NodeAttachmentButton's backing anchor NSView), tearing the anchor out of the
        // window hierarchy. The .semitransient attachment NSPopover, anchored to that
        // view, immediately lost its anchor and auto-closed — the "打开即关闭" bug that
        // only ever hit empty slots. A non-empty slot persists a stable contentId, so
        // its key was stable and its popover stayed open.
        //
        // Empty content is visually identical no matter what the ephemeral contentId
        // is, so pin empty slots to a stable, identity-only key. This keeps the card
        // (and its anchor NSView) alive across re-renders, so the popover stays open.
        if isEmpty {
            return "\(specialSlotId)::\(slot)::empty"
        }
        return "\(specialSlotId)::\(slot)::\(contentId)::\(updatedAt)"
    }

    public var preview: String {
        let key = "\(contentId)::\(updatedAt)::preview" as NSString
        if let cached = SlotContentPreviewCache.preview.object(forKey: key) {
            return cached as String
        }
        let result = computedPreview
        SlotContentPreviewCache.preview.setObject(result as NSString, forKey: key)
        return result
    }

    private var computedPreview: String {
        for itemList in items {
            for item in itemList {
                if item.type == "public.utf8-plain-text" || item.type == "NSStringPboardType" {
                    // v2.8.7 (B): legacy NSStringPboardType is often UTF-16, so fall
                    // back to utf16 when utf8 decode fails, otherwise preview is empty.
                    if let str = String(data: item.data, encoding: .utf8) ?? String(data: item.data, encoding: .utf16) {
                        let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.count > 30 ? String(t.prefix(30)) + "…" : t
                    }
                }
                if item.type == "public.rtf" { return "[RTF]" }
                if item.type == "public.html" {
                    // v2.8.6: show the real readable text (HTML tags stripped) so an
                    // HTML slot looks exactly like a plain-text slot, instead of the
                    // bare "[HTML]" placeholder. A plain-text item, when present, is
                    // matched earlier in this loop and takes priority.
                    if let str = String(data: item.data, encoding: .utf8) ?? String(data: item.data, encoding: .utf16) {
                        let stripped = str
                            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                            .replacingOccurrences(of: "&nbsp;", with: " ")
                            .replacingOccurrences(of: "&lt;", with: "<")
                            .replacingOccurrences(of: "&gt;", with: ">")
                            .replacingOccurrences(of: "&amp;", with: "&")
                            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !stripped.isEmpty {
                            return stripped.count > 30 ? String(stripped.prefix(30)) + "…" : stripped
                        }
                    }
                    return "[HTML]"
                }
                if item.type == "public.file-url" {
                    if let urlStr = String(data: item.data, encoding: .utf8), let url = URL(string: urlStr) {
                        return "[文件]" + url.lastPathComponent
                    }
                    return "[文件]"
                }
                // v2.10.33 (bug #2): use the canonical image predicate instead of the
                // old `hasPrefix("public.") && contains("image")` test. That test MISSED
                // every real image UTI — `public.png` / `public.jpeg` / `public.heic` /
                // `com.compuserve.gif` etc. do NOT contain the substring "image" — so an
                // image slot fell through to the "[<type>]" fallback below and the card
                // rendered a "[png]" text preview instead of the thumbnail. Centralizing
                // detection keeps preview, `hasImage` and the decode paths in lockstep.
                if SlotContent.isImagePasteboardType(item.type) {
                    return "[图片 \(item.data.count / 1024)KB]"
                }
            }
        }
        // Fallback: show first type name
        if let firstType = items.first?.first?.type {
            let short = firstType.replacingOccurrences(of: "public.", with: "")
            return "[\(short)]"
        }
        return "(空)"
    }

    public var plainText: String? {
        let key = "\(contentId)::\(updatedAt)::plainText" as NSString
        if let cached = SlotContentPreviewCache.plainText.object(forKey: key) {
            return cached === SlotContentPreviewCache.missing ? nil : cached as String
        }
        let result = computedPlainText
        SlotContentPreviewCache.plainText.setObject((result as NSString?) ?? SlotContentPreviewCache.missing, forKey: key)
        return result
    }

    private var computedPlainText: String? {
        for itemList in items {
            for item in itemList {
                if item.type == "public.utf8-plain-text" || item.type == "NSStringPboardType" {
                    // v2.8.7 (B): legacy NSStringPboardType is often UTF-16.
                    return String(data: item.data, encoding: .utf8) ?? String(data: item.data, encoding: .utf16)
                }
            }
        }
        return nil
    }
}

private enum SlotContentPreviewCache {
    static let preview: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        return cache
    }()
    static let plainText: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        return cache
    }()
    static let missing = NSString(string: "\u{0}")
}

public final class ClipboardManager {
    public static let shared = ClipboardManager()
    private let pasteboard = NSPasteboard.general

    public init() {}

    public func capture() -> SlotContent {
        // v2.10.3 (P2): NSPasteboard is not thread-safe; force pasteboard access onto
        // the main thread. Only hop when off-main to avoid a same-thread sync deadlock.
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { self.capture() }
        }
        var content = SlotContent()
        content.timestamp = Date()

        guard let pbItems = pasteboard.pasteboardItems, !pbItems.isEmpty else {
            content.capturedEmpty = true
            return content
        }

        var allItems: [[PasteboardItem]] = []
        for pbItem in pbItems {
            var items: [PasteboardItem] = []
            for type in pbItem.types {
                if let data = pbItem.data(forType: type) {
                    items.append(PasteboardItem(type: type.rawValue, data: data))
                }
            }
            if !items.isEmpty { allItems.append(items) }
        }
        content.items = allItems
        let types = allItems.flatMap { $0.map { $0.type } }
        NSLog("[ClipSlots] CLIPBOARD capture: changeCount=\(pasteboard.changeCount) items=\(pbItems.count), types: \(types), preview=\(content.preview)")
        return content
    }

    public func restore(_ content: SlotContent) -> Bool {
        // v2.10.3 (P2): keep NSPasteboard mutation on the main thread.
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { self.restore(content) }
        }
        guard !content.items.isEmpty else {
            // v2.8.1 (P1-2): the original clipboard was genuinely empty — clear the
            // pasteboard so an injected paste payload isn't left behind. A non-empty
            // capturedEmpty=false snapshot means "never captured / unknown", so we
            // leave the pasteboard untouched to avoid wiping real user content.
            if content.capturedEmpty {
                pasteboard.clearContents()
                NSLog("[ClipSlots] CLIPBOARD restore: original was empty, cleared pasteboard")
                return true
            }
            return false
        }
        pasteboard.clearContents()
        var pbItems: [NSPasteboardItem] = []
        for itemList in content.items {
            let pbItem = NSPasteboardItem()
            for item in itemList {
                let type = NSPasteboard.PasteboardType(item.type)
                let ok = pbItem.setData(item.data, forType: type)
                if !ok {
                    NSLog("[ClipSlots] WARNING: setData failed for type \(item.type) (\(item.data.count) bytes)")
                }
            }
            pbItems.append(pbItem)
        }
        guard !pbItems.isEmpty else { return false }
        let result = pasteboard.writeObjects(pbItems)
        let types = content.items.flatMap { $0.map { $0.type } }
        NSLog("[ClipSlots] CLIPBOARD restore: \(content.items.count) groups, types: \(types), result: \(result)")
        return result
    }

    public func restorePlainText(_ content: SlotContent) -> Bool {
        if let text = content.plainText {
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
        return restore(content)
    }

    /// Poll pasteboard changeCount to detect when the target app has consumed content after Cmd+V.
    /// Calls completion after consumption or timeout (5s).
    public func waitForPasteCompletion(timeout: TimeInterval = 5.0, completion: @escaping () -> Void) {
        let startCount = pasteboard.changeCount
        let deadline = DispatchTime.now() + timeout
        let checkInterval: TimeInterval = 0.05

        func check() {
            guard DispatchTime.now() < deadline else {
                NSLog("[ClipSlots] Paste completion timed out after \(timeout)s")
                completion()
                return
            }
            if pasteboard.changeCount != startCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { completion() }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + checkInterval) { check() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
    }

    public var changeCount: Int { pasteboard.changeCount }
}

// MARK: - v2.7.33 SlotContent Convenience Init

extension SlotContent {
    public init(text: String) {
        let data = text.data(using: .utf8) ?? Data()
        let item = PasteboardItem(type: "public.utf8-plain-text", data: data)
        self.items = [[item]]
        self.timestamp = Date()
    }
}

// MARK: - v2.7.32 HTML Detection

extension SlotContent {
    public var isHTMLFileURL: Bool {
        guard let url = primaryFileURL else { return false }
        return ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    /// v2.8.6: HTML captured to a slot is now presented as plain text everywhere
    /// (see `preview`), so we no longer surface the raw `public.html` bytes as a
    /// render source. Only genuine rich-paste (`htmlSource`) or `.html` files are
    /// treated as HTML documents.
    public var isHTMLDocument: Bool {
        if isHTMLFileURL { return true }
        if let htmlSource, !htmlSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    public var htmlDocumentSource: String? {
        if let url = primaryFileURL, isHTMLFileURL {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
            if let text = try? String(contentsOf: url) { return text }
        }
        if let htmlSource, !htmlSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return htmlSource }
        return nil
    }
}

// MARK: - SlotAttachment 断链检测 (v2.10.37)
//
// 背景：`.clipslotspack` 导入后，「本地文件」类附件若在包内未内嵌字节（只保留了路径引用），
// 换机器或源文件被移动/删除后引用即失效。此前粘贴路径直接 `URL(fileURLWithPath:)` 不做存在性
// 校验，导致粘贴静默失败；附件面板则渲染出破损缩略图。这里提供统一的断链判定入口，供粘贴前
// 跳过 + UI 提示，以及附件面板断链角标共用（此前解析逻辑散落多处、无统一入口）。
extension SlotContent.SlotAttachment {
    /// 该附件是否携带可直接使用的内联字节（无需依赖磁盘源文件即可粘贴/渲染，如内存图片）。
    public var hasUsableInlineData: Bool {
        if let d = data, !d.isEmpty { return true }
        return false
    }

    /// 统一的附件字节懒加载入口（方案 B / 附件字节外置架构）。
    ///
    /// 设计目标：把散落各处「直接读 `att.data`」的代码统一收敛到这一个函数，
    /// 使后续两步能安全落地——
    ///   • Step 1（v2.10.41，当前）：字节仍内联在 JSON 里，本函数直接返回 `self.data`，
    ///     行为与旧代码逐字节一致，纯重构、零行为变化。
    ///   • Step 2（v2.10.42，后续）：写盘时把字节外置到独立文件，本函数将扩展为
    ///     「先看内联 `self.data`，为空则按内容寻址从磁盘懒加载字节」，同时对老数据懒迁移。
    ///   • Step 3（v2.10.43，后续）：pack 导入/导出与 CLI 适配外置字节。
    ///
    /// 因此所有需要「拿到附件原始字节」的读取路径都应调用 `resolveData()`，
    /// 而不再直接访问 `self.data`；这样 Step 2 落地时无需再逐处修改调用点。
    ///
    /// 返回 nil 表示该附件没有可用字节（例如纯路径引用 / url / reference 型）。
    public func resolveData() -> Data? {
        // Step 2（v2.10.42）：字节懒加载入口。
        // 1) 内联字节优先——覆盖两种情形：
        //    • 新写入尚未落盘前的内存态附件（setAttachments 拿到的 in-memory data）；
        //    • 老数据尚未触发懒迁移时（attachments.json 里仍内联着 base64 data）。
        if let d = self.data { return d }
        // 2) 外置字节——内存无 data 时，按 storagePath 从磁盘懒加载 `{slotDir}/attachments/{id}.bin`。
        //    读失败 / 文件缺失（断链）返回 nil，与旧「无字节」语义一致，调用方据此回退。
        guard let sp = self.storagePath, !sp.isEmpty else { return nil }
        let url = URL(fileURLWithPath: sp)
        // P2-F (v2.10.44): 读 .bin 不持 StorageLock，与另一进程（CLI / 自动存储）的 `replaceItemAt`
        // 整槽目录原子 swap 可能交叠——`fileExists` 通过后文件恰被换走 → 偶发瞬时 nil（把真有字节的
        // 附件误判为断链，缩略图/粘贴瞬时失败）。swap 是原子的，加一次轻量重试即可越过换盘瞬间读到
        // swap 后的新文件（内容一致）。仍失败才当断链返回 nil，不改变最终语义。
        for attempt in 0..<2 {
            if let d = try? Data(contentsOf: url) { return d }
            if attempt == 0 && FileManager.default.fileExists(atPath: sp) == false {
                // 换盘瞬间：极短退避后重试一次。
                // P2-02 (v2.10.45): 仅在【非主线程】做 sleep 退避重试。resolveData 被大量 SwiftUI 主线程
                // 计算属性调用（缩略图回退、文本预览、粘贴构造等）。对真断链外置附件（storagePath 有、文件
                // 确实缺失），旧实现每次都在主线程 Thread.sleep(15ms)，快速滑过含断链附件的列表时主线程掉帧
                // 会累加。主线程直接判 nil 回退（TOCTOU 重试仅是锦上添花、非正确性所需），把退避重试留给后台。
                if Thread.isMainThread { break }
                Thread.sleep(forTimeInterval: 0.015)
            } else if attempt == 0 {
                // 文件在但读失败（同样可能是 swap 中途）：立即重试一次（无 sleep，主线程亦廉价）。
                continue
            } else {
                break
            }
        }
        return nil
    }

    /// P2-D / P2-F (v2.10.44): 外置字节文件的磁盘 URL（若存在）。`resolveData()` 会把整份字节读进
    /// 内存；对「图片缩略图 / 大图下采样」等只需按 URL 流式读取的场景，优先用本 URL 交给 ImageIO
    /// （`CGImageSourceCreateWithURL`）按需下采样，避免先整图 materialize 到内存再解码。纯内联 /
    /// 纯路径引用 / url / reference 型附件返回 nil（无外置字节文件）。
    public var storageFileURL: URL? {
        guard let sp = storagePath, !sp.isEmpty,
              FileManager.default.fileExists(atPath: sp) else { return nil }
        return URL(fileURLWithPath: sp)
    }

    /// P2-E (v2.10.44): 文本附件的解码字符串，带进程内缓存。文本附件的预览（附件面板 subtitle /
    /// 正文卡片）是 SwiftUI 计算属性，每次重绘都会调 `resolveData()` 同步读盘 + UTF-8 解码；外置后
    /// 这条路径变成主线程磁盘 I/O。这里按「id + storagePath」缓存解码结果（外置 `.bin` 一经写入内容
    /// 不变，缓存安全），重绘命中缓存不再读盘。仅对 `.text` 类型有意义；解不出 UTF-8 返回 nil。
    public func resolveTextString() -> String? {
        guard type == .text else {
            return resolveData().flatMap { String(data: $0, encoding: .utf8) }
        }
        let key = id.uuidString + "|" + (storagePath ?? "")
        if let cached = AttachmentTextCache.shared.string(forKey: key) { return cached }
        guard let s = resolveData().flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        AttachmentTextCache.shared.set(s, forKey: key)
        return s
    }


    /// 本地文件引用实际应指向的磁盘路径：优先 `path`，其次导入时保留的 `originalPath`。
    /// 仅对 image/file 类型有意义；其余类型返回 nil。
    public var localFileReferencePath: String? {
        guard type == .image || type == .file else { return nil }
        if let p = path, !p.isEmpty { return p }
        if let op = originalPath, !op.isEmpty { return op }
        return nil
    }

    /// 是否为「断链的本地文件引用」——期望指向本地文件、但源文件已被移动/删除，且没有可回退的
    /// 内联字节。用于粘贴前跳过并给出明确提示、以及附件面板断链角标；避免静默失败/破损缩略图。
    public var isBrokenLocalFileRef: Bool {
        guard type == .image || type == .file else { return false }
        // 图片等有内联字节仍可粘贴/渲染，不算断链。
        if hasUsableInlineData { return false }
        // 没有任何本地路径引用（例如纯 url / 内联型），不属于本地文件断链范畴。
        guard let p = localFileReferencePath else { return false }
        return !FileManager.default.fileExists(atPath: p)
    }
}

/// P2-E (v2.10.44): 进程内的文本附件解码缓存。文本附件外置后，附件面板的文本预览计算属性会在
/// 每次 SwiftUI 重绘时同步读盘 + UTF-8 解码；本缓存按「id + storagePath」键缓存解码字符串，重绘直接
/// 命中内存。外置 `.bin` 一经写入其内容不再变化（内容变更会生成新附件 / 新路径），故缓存无失效风险。
/// 用 `NSCache` 承载（自动内存压力回收 + 容量上限），线程安全。
final class AttachmentTextCache {
    static let shared = AttachmentTextCache()
    private let cache = NSCache<NSString, NSString>()

    private init() {
        // 文本附件通常很小；限制条数与总字符数，避免异常大文本堆积。
        cache.countLimit = 512
        cache.totalCostLimit = 16 * 1024 * 1024 // 约 16MB 字符
    }

    func string(forKey key: String) -> String? {
        cache.object(forKey: key as NSString) as String?
    }

    func set(_ value: String, forKey key: String) {
        cache.setObject(value as NSString, forKey: key as NSString, cost: value.utf8.count)
    }
}
