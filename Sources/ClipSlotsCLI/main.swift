import Foundation
import ClipSlotsKit

// clipslots — standalone command-line interface for the ClipSlots data layer.
//
// This binary reuses the SAME on-disk storage as the ClipSlots GUI app by
// depending on ClipSlotsKit (SpecialSlotStorage / SlotStorage / SlotContent /
// AppConfig). It does NOT reimplement or fork the storage format.
//
// All output is a single pretty-printed JSON object with sorted keys.
//   success: {"ok": true, ...}
//   error:   {"ok": false, "error": "message"}  (exit code 1)

let CLI_VERSION = "2.9.0"
let DEFAULT_GROUP = "default"
let DEFAULT_PAGE = "default_page"

// MARK: - JSON output helpers

func emit(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
          let str = String(data: data, encoding: .utf8) else {
        // Last-ditch fallback that is still valid JSON.
        print("{\"ok\":false,\"error\":\"failed to serialize response\"}")
        return
    }
    print(str)
}

func success(_ dict: [String: Any]) -> Never {
    var d = dict
    d["ok"] = true
    emit(d)
    exit(0)
}

func fail(_ message: String) -> Never {
    emit(["ok": false, "error": message])
    exit(1)
}

// A String? -> Any that JSONSerialization accepts (nil becomes NSNull).
func jsonValue(_ value: String?) -> Any { value ?? NSNull() }

// MARK: - Argument parsing (dependency-free)

struct ParsedArgs {
    var command: String
    var positionals: [String]
    var flags: [String: String]
    var boolFlags: Set<String>

    func flag(_ name: String) -> String? { flags[name] }
    func hasFlag(_ name: String) -> Bool { boolFlags.contains(name) || flags[name] != nil }
}

func parseArgs(_ raw: [String]) -> ParsedArgs {
    var positionals: [String] = []
    var flags: [String: String] = [:]
    var boolFlags: Set<String> = []
    let command = raw.first ?? "help"
    var i = 1
    while i < raw.count {
        let token = raw[i]
        if token.hasPrefix("--") {
            let key = String(token.dropFirst(2))
            let next = (i + 1 < raw.count) ? raw[i + 1] : nil
            if let next, !next.hasPrefix("--") {
                flags[key] = next
                i += 2
            } else {
                boolFlags.insert(key)
                i += 1
            }
        } else {
            positionals.append(token)
            i += 1
        }
    }
    return ParsedArgs(command: command, positionals: positionals, flags: flags, boolFlags: boolFlags)
}

// MARK: - Domain helpers

let storage = SpecialSlotStorage.shared
let appConfig = AppConfig.load()
let slotCount = max(1, min(10, appConfig.slots))

/// Resolve the page id that owns a given group id (falls back to DEFAULT_PAGE).
func pageId(forGroup groupId: String, in index: SpecialSlotIndex) -> String {
    index.specialSlots.first(where: { $0.id == groupId })?.pageId ?? DEFAULT_PAGE
}

/// Classify a slot's content into a coarse, agent-friendly type string.
func classify(_ c: SlotContent) -> String {
    if c.isEmpty {
        return c.attachments.isEmpty ? "empty" : "attachment"
    }
    let types = c.items.flatMap { $0.map { $0.type } }
    if types.contains(where: { $0.lowercased().contains("image") }) { return "image" }
    if types.contains("public.file-url") {
        if let url = c.primaryFileURL {
            let ext = url.pathExtension.lowercased()
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "heic", "heif", "tiff", "tif", "ico", "icns", "avif"]
            let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "wmv"]
            if imageExts.contains(ext) { return "image-file" }
            if videoExts.contains(ext) { return "video-file" }
        }
        return "file"
    }
    if let html = c.htmlSource, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "html" }
    if types.contains("public.html") { return "html" }
    if c.plainText != nil { return "text" }
    if types.contains("public.rtf") { return "rtf" }
    return "other"
}

func uniqueTypes(_ c: SlotContent) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for group in c.items {
        for item in group where !seen.contains(item.type) {
            seen.insert(item.type)
            result.append(item.type)
        }
    }
    return result
}

/// Resolve a group id from flags, honoring the documented default.
func resolveGroup(_ args: ParsedArgs) -> String {
    args.flag("group") ?? DEFAULT_GROUP
}

func parseSlot(_ raw: String?) -> Int {
    guard let raw, let n = Int(raw) else {
        fail("missing or invalid slot number (expected 1...\(slotCount))")
    }
    guard (1...slotCount).contains(n) else {
        fail("slot out of range: \(n) (valid 1...\(slotCount))")
    }
    return n
}

// MARK: - Commands

func cmdVersion() -> Never {
    success(["version": CLI_VERSION])
}

func cmdHelp() -> Never {
    let commands: [[String: Any]] = [
        ["name": "version", "description": "打印 CLI 版本号。", "flags": [] as [String]],
        ["name": "help", "description": "列出所有命令、说明与参数（无参数时也返回此内容）。", "flags": [] as [String]],
        ["name": "groups", "description": "列出所有槽位组（SpecialSlot）。", "flags": [] as [String]],
        ["name": "pages", "description": "列出所有页面（SlotPage）。", "flags": ["--group <id> (可选,当前实现忽略,页面为全局)"]],
        ["name": "list", "description": "列出某个槽位组内 1..N 号槽位的摘要。", "flags": ["--group <id> (默认 default)", "--page <id> (可选,仅回显)"]],
        ["name": "read", "description": "读取单个槽位的完整内容（纯文本、HTML源、类型、附件数等）。", "flags": ["<slot> (位置参数,1..N)", "--group <id> (默认 default)", "--page <id> (可选,仅回显)"]],
        ["name": "write", "description": "向槽位写入纯文本内容（保留已有附件），可选设置标签。", "flags": ["<slot> (位置参数,1..N)", "--text <string> (必填, 传 - 表示从 stdin 读取)", "--group <id> (默认 default)", "--page <id> (可选,仅回显)", "--label <string> (可选)"]],
        ["name": "search", "description": "在槽位预览/文本/标签中做大小写不敏感子串搜索。", "flags": ["<query> (位置参数)", "--group <id> (默认 default)", "--all-groups (在所有槽位组内搜索)", "--limit <N> (默认 50)"]],
        ["name": "paste", "description": "把某槽位的内容加载到系统剪贴板(NSPasteboard)，不模拟按键。", "flags": ["<slot> (位置参数,1..N)", "--group <id> (默认 default)", "--page <id> (可选,仅回显)"]]
    ]
    success([
        "version": CLI_VERSION,
        "defaultGroup": DEFAULT_GROUP,
        "defaultPage": DEFAULT_PAGE,
        "slotCount": slotCount,
        "commands": commands
    ])
}

func cmdGroups() -> Never {
    let index = storage.loadIndex()
    let pageNames = Dictionary(uniqueKeysWithValues: index.pages.map { ($0.id, $0.name) })
    var groups: [[String: Any]] = []
    for g in index.specialSlots {
        groups.append([
            "id": g.id,
            "name": g.name,
            "pageId": g.pageId,
            "pageName": jsonValue(pageNames[g.pageId]),
            "pageCount": index.pages.count,
            "slotCount": slotCount,
            "current": g.id == index.currentSpecialSlotId
        ])
    }
    success(["groups": groups])
}

func cmdPages(_ args: ParsedArgs) -> Never {
    let index = storage.loadIndex()
    var pages: [[String: Any]] = []
    for p in index.pages.sorted(by: { $0.order < $1.order }) {
        pages.append([
            "id": p.id,
            "name": p.name,
            "current": p.id == index.currentPageId
        ])
    }
    success(["pages": pages])
}

func cmdList(_ args: ParsedArgs) -> Never {
    let group = resolveGroup(args)
    let index = storage.loadIndex()
    let page = args.flag("page") ?? pageId(forGroup: group, in: index)
    var slots: [[String: Any]] = []
    for n in 1...slotCount {
        let content = storage.get(n, in: group)
        let label = storage.getLabel(n, in: group) ?? content.label
        slots.append([
            "slot": n,
            "label": jsonValue(label),
            "preview": content.preview,
            "type": classify(content),
            "empty": content.isEmpty
        ])
    }
    success(["group": group, "page": page, "slots": slots])
}

func cmdRead(_ args: ParsedArgs) -> Never {
    let group = resolveGroup(args)
    let n = parseSlot(args.positionals.first)
    let content = storage.get(n, in: group)
    let label = storage.getLabel(n, in: group) ?? content.label
    success([
        "slot": n,
        "label": jsonValue(label),
        "preview": content.preview,
        "text": jsonValue(content.plainText),
        "htmlSource": jsonValue(content.htmlSource),
        "types": uniqueTypes(content),
        "attachmentCount": content.attachments.count,
        "empty": content.isEmpty
    ])
}

func cmdWrite(_ args: ParsedArgs) -> Never {
    let group = resolveGroup(args)
    let n = parseSlot(args.positionals.first)
    guard var text = args.flag("text") else {
        fail("missing --text <string> (use --text - to read from stdin)")
    }
    if text == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        text = String(data: data, encoding: .utf8) ?? ""
    }

    // Mirror the GUI's updateTextSlot: build a public.utf8-plain-text item and
    // PRESERVE any existing attachments on the slot (v2.8.7 fix).
    let existing = storage.get(n, in: group)
    let data = text.data(using: .utf8) ?? Data()
    let item = PasteboardItem(type: "public.utf8-plain-text", data: data)
    var content = SlotContent()
    content.items = [[item]]
    content.timestamp = Date()
    content.attachments = existing.attachments

    let ok = storage.set(n, content: content, in: group)
    guard ok else { fail("failed to write slot \(n) in group \(group)") }

    if let label = args.flag("label") {
        storage.setLabel(n, label: label, in: group)
    }
    success(["slot": n, "group": group])
}

func cmdSearch(_ args: ParsedArgs) -> Never {
    guard let query = args.positionals.first, !query.isEmpty else {
        fail("missing search query")
    }
    let needle = query.lowercased()
    let limit = Int(args.flag("limit") ?? "") ?? 50
    let index = storage.loadIndex()
    let pageNames = Dictionary(uniqueKeysWithValues: index.pages.map { ($0.id, $0.name) })

    let targetGroups: [SpecialSlot]
    if args.hasFlag("all-groups") {
        targetGroups = index.specialSlots
    } else {
        let group = resolveGroup(args)
        if let g = index.specialSlots.first(where: { $0.id == group }) {
            targetGroups = [g]
        } else {
            // Group not present in index but may still have on-disk data.
            targetGroups = [SpecialSlot(id: group, name: group, sourceType: .manual,
                                        pageId: DEFAULT_PAGE, createdAt: Date(), updatedAt: Date())]
        }
    }

    var results: [[String: Any]] = []
    outer: for g in targetGroups {
        for n in 1...slotCount {
            let content = storage.get(n, in: g.id)
            if content.isEmpty && content.attachments.isEmpty { continue }
            let label = storage.getLabel(n, in: g.id) ?? content.label ?? ""
            let haystack = [content.preview, content.plainText ?? "", label].joined(separator: "\n").lowercased()
            if haystack.contains(needle) {
                results.append([
                    "group": g.id,
                    "page": g.pageId.isEmpty ? DEFAULT_PAGE : g.pageId,
                    "pageName": jsonValue(pageNames[g.pageId]),
                    "slot": n,
                    "label": jsonValue(storage.getLabel(n, in: g.id) ?? content.label),
                    "preview": content.preview
                ])
                if results.count >= limit { break outer }
            }
        }
    }
    success(["query": query, "results": results])
}

func cmdPaste(_ args: ParsedArgs) -> Never {
    let group = resolveGroup(args)
    let n = parseSlot(args.positionals.first)
    let content = storage.get(n, in: group)
    guard !content.isEmpty else {
        fail("slot \(n) in group \(group) is empty; nothing to copy")
    }
    let ok = ClipboardManager.shared.restore(content)
    guard ok else { fail("failed to load slot \(n) onto the clipboard") }
    success(["slot": n, "action": "copied-to-clipboard"])
}

// MARK: - Entry point

let parsed = parseArgs(CommandLine.arguments.dropFirst().map { $0 })

switch parsed.command {
case "version", "--version", "-v":
    cmdVersion()
case "help", "--help", "-h":
    cmdHelp()
case "groups":
    cmdGroups()
case "pages":
    cmdPages(parsed)
case "list":
    cmdList(parsed)
case "read":
    cmdRead(parsed)
case "write":
    cmdWrite(parsed)
case "search":
    cmdSearch(parsed)
case "paste":
    cmdPaste(parsed)
default:
    fail("unknown command: \(parsed.command) (run 'clipslots help')")
}
