import Foundation
import AppKit
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

let CLI_VERSION = "2.9.53"
let DEFAULT_GROUP = "default"
let DEFAULT_PAGE = "default_page"

// v2.9.41 (Problem A): capture the "request received" instant as early and as
// robustly as possible so that parallel `create-group` processes keep the order in
// which they were LAUNCHED, not the order in which they happen to win the storage
// lock. Capturing `Date()` at the top of top-level code is NOT enough: the Swift
// runtime + dyld startup jitter (tens of ms) is larger than the shell's fork
// spacing (sub-ms), so per-process wall-clock reads get reordered. Instead we read
// the kernel's process-CREATION time (`kp_proc.p_starttime`) via sysctl — the shell
// forks background jobs sequentially, so this timestamp is monotonic with launch
// order and free of runtime-startup jitter. Falls back to `Date()` if sysctl fails.
func clipslotsProcessStartTime() -> Date {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let rc = mib.withUnsafeMutableBufferPointer { buf in
        sysctl(buf.baseAddress, UInt32(buf.count), &kp, &size, nil, 0)
    }
    if rc == 0 {
        let tv = kp.kp_proc.p_starttime
        let secs = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000.0
        if secs > 0 { return Date(timeIntervalSince1970: secs) }
    }
    return Date()
}
let CLI_REQUEST_RECEIVED_AT = clipslotsProcessStartTime()

// Extensions treated as images (attachment typing + content classification).
// v2.9.7 (R2): single source of truth now lives in ClipSlotsKit
// (`SlotContent.imageFileExtensions`); both GUI and CLI reference it so the two
// lists can no longer drift out of sync.
let IMAGE_EXTS: Set<String> = SlotContent.imageFileExtensions

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
        if token == "-h" {
            // v2.9.5 (Feature #2): recognize the short help flag as a bool flag so
            // `clipslots <cmd> -h` works the same as `--help`. (A bare "-" is left
            // as a positional/value so `write --text -` stdin marker still works.)
            boolFlags.insert("h")
            i += 1
        } else if token.hasPrefix("--") {
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
// A slot is truly empty ONLY when its main body (items) AND its attachment
// list are both empty. Body content OR attachments => not empty. This is the
// canonical "empty slot" definition agents rely on when scanning for a free slot.
// v2.9.3: SlotContent.isEmpty now already means `items.isEmpty && attachments.isEmpty`,
// so this simply forwards to it. Kept for readability at call sites.
func isTrulyEmpty(_ c: SlotContent) -> Bool {
    c.isEmpty
}

func classify(_ c: SlotContent) -> String {
    // v2.9.3: distinguish body-empty from fully-empty using items.isEmpty directly.
    // (content.isEmpty now also considers attachments, so it can no longer be used
    // to detect "body empty but has attachments" == the "attachment" type.)
    if c.items.isEmpty {
        return c.attachments.isEmpty ? "empty" : "attachment"
    }
    let types = c.items.flatMap { $0.map { $0.type } }
    if types.contains(where: { $0.lowercased().contains("image") }) { return "image" }
    if types.contains("public.file-url") {
        if let url = c.primaryFileURL {
            let ext = url.pathExtension.lowercased()
            let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "wmv"]
            if IMAGE_EXTS.contains(ext) { return "image-file" }
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
/// v2.9.16 (#2): supports referencing a group by NAME, not just id:
///   • `--group-name "导入1"` → matches SpecialSlot.name exactly (errors if none).
///   • `--group <val>` → tries id match first (backward compatible); if no id
///     matches, falls back to a name match; otherwise passes the literal value
///     through (e.g. the bare `default` group that may only exist on disk).
///
/// v2.9.32 (A1/A2): group resolution is now PAGE-SCOPED. When the caller passes a
/// resolved `pageId` (from --page / --page-name), the candidate set is restricted
/// to groups on that page, so a group NAME or ID can never silently resolve to a
/// same-named group on a DIFFERENT page (the root cause of the "write到错误页面"
/// P0). If a page is constrained and the requested group is not on it, we FAIL with
/// a clear mismatch error (A2) instead of falling back to another page. Without a
/// page constraint (`inPage == nil`) behaviour is unchanged (global, backward
/// compatible) — used by commands that have no page flags (search/clear/…).
func resolveGroup(_ args: ParsedArgs, inPage pageId: String? = nil) -> String {
    let index = storage.loadIndex()
    // Candidate scope: page-constrained when a page was requested, else global.
    let scope = pageId.map { pid in index.specialSlots.filter { $0.pageId == pid } }
                      ?? index.specialSlots
    // Human-friendly label for the requested page (name if known, else the id).
    let pageLabel: String? = pageId.map { pid in
        index.pages.first(where: { $0.id == pid })?.name ?? pid
    }

    if let name = args.flag("group-name") {
        if let g = scope.first(where: { $0.name == name }) { return g.id }
        if let label = pageLabel {
            // A2 guardrail: named group is not on the requested page → refuse.
            fail("group '\(name)' not found in page '\(label)'")
        }
        fail("no group found with name '\(name)' (run 'clipslots groups' to list names)")
    }

    if let explicit = args.flag("group") {
        if scope.contains(where: { $0.id == explicit }) { return explicit }
        if let g = scope.first(where: { $0.name == explicit }) { return g.id }
        if let label = pageLabel {
            // A2 guardrail: an explicit --group (id or name) that resolves to nothing
            // on the requested page is a page/group mismatch → refuse.
            fail("group '\(explicit)' not found in page '\(label)'")
        }
        // No page constraint: keep literal passthrough (e.g. bare on-disk group id).
        return explicit
    }

    // No explicit group flag → the documented default group, still page-scoped for
    // matching but with a backward-compatible literal fallback. Note: `list` handles
    // the page-without-group case via its own page-scoped logic (A3) before reaching
    // here, so this default is only hit by read/write/paste when no group is given.
    let raw = DEFAULT_GROUP
    if scope.contains(where: { $0.id == raw }) { return raw }
    if let g = scope.first(where: { $0.name == raw }) { return g.id }
    return raw
}

// v2.9.29 (#1): resolve an explicitly-requested page from --page / --page-name.
// Symmetric to `resolveGroup` / `--group-name`.
//   • Returns the resolved page id, or nil when NEITHER flag was given (caller
//     then falls back to its own default, e.g. the group's owning page).
//   • --page and --page-name are MUTUALLY EXCLUSIVE.
//   • --page-name matches SlotPage.name exactly; NO match => hard error
//     (never silently falls back to a default page).
//   • --page: matched against page id first, then name. When `strict` and the
//     value matches no page, errors out (used by create-group where the page is
//     an actual placement target, not a mere echo).
func resolvePageFlag(_ args: ParsedArgs, strict: Bool = false) -> String? {
    let hasPage = args.flag("page") != nil
    let hasName = args.flag("page-name") != nil
    if hasPage && hasName {
        fail("只能指定 --page 或 --page-name 其中一个")
    }
    let index = storage.loadIndex()
    if let name = args.flag("page-name") {
        if let p = index.pages.first(where: { $0.name == name }) { return p.id }
        fail("找不到名为 '\(name)' 的页面")
    }
    if let page = args.flag("page") {
        if let p = index.pages.first(where: { $0.id == page || $0.name == page }) { return p.id }
        // v2.9.29: an explicitly requested page that matches nothing is an error
        // for placement commands (was previously a silent fallback to currentPage).
        if strict {
            fail("找不到 id 或名称为 '\(page)' 的页面")
        }
        return page
    }
    return nil
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

// v2.9.16 (#5): a short, agent-friendly preview of what was written (first 100
// chars) so callers don't need a follow-up `read` to confirm the content.
func previewText(_ s: String) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: " ")
    return flat.count > 100 ? String(flat.prefix(100)) + "…" : flat
}

// v2.9.16 (#4): classify a caught write error into an ACCURATE message.
// The old code funnelled everything through `error.localizedDescription`, which
// for a Cocoa write-permission failure reads "You don't have permission to save
// index.json" — misleading when the true root cause is a lock timeout. We now
// separate the two:
//   • StorageLockError  → "storage is busy …" (lock contention, retry works)
//   • Cocoa write/permission errors → clear filesystem message naming the dir
//   • anything else → generic, still tagged as an IO error not a lock error
func describeWriteError(_ error: Error, context: String) -> String {
    if let lockErr = error as? StorageLockError {
        return lockErr.errorDescription ?? "storage is busy (lock timeout)"
    }
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain {
        // 513 = NSFileWriteNoPermissionError, 640 = NSFileWriteOutOfSpaceError,
        // 642 = NSFileWriteVolumeReadOnlyError.
        switch ns.code {
        case 513:
            return "filesystem permission error while \(context): the ClipSlots data "
                + "directory (\(ClipSlotsPaths.dataRoot.path)) is not writable by this user. "
                + "This is NOT a lock conflict. Check directory ownership/permissions."
        case 640:
            return "no space left on device while \(context)"
        case 642:
            return "read-only filesystem while \(context)"
        default:
            break
        }
    }
    return "I/O error while \(context): \(error.localizedDescription) "
        + "(not a lock conflict; check disk/permissions)"
}

// v2.9.16 (#4): when `storage.set` returns false it has already swallowed the
// underlying error. Probe the data directory writability so we can still tell a
// genuine permission problem apart from a transient failure.
func writeFailureDiagnostic(context: String) -> String {
    let dir = ClipSlotsPaths.dataRoot.path
    if !FileManager.default.isWritableFile(atPath: dir) {
        return "failed \(context): the ClipSlots data directory (\(dir)) is not "
            + "writable. This is a filesystem permission issue, not a lock conflict."
    }
    return "failed \(context) (data directory is writable; the write was rejected "
        + "by the storage layer — check logs / disk space)"
}

// MARK: - Commands

func cmdVersion() -> Never {
    success(["version": CLI_VERSION])
}

// v2.9.5 (Feature #2): single source of truth for command metadata. Both the
// top-level `help` command and per-subcommand `--help`/`-h` render from this.
let COMMANDS: [[String: Any]] = [
    ["name": "version", "description": "打印 CLI 版本号。", "flags": [] as [String]],
    ["name": "help", "description": "列出所有命令、说明与参数（无参数时也返回此内容）。", "flags": [] as [String]],
    ["name": "groups", "description": "列出槽位组（SpecialSlot）。可用 --page/--page-name 只列出指定页面下的组，是判断某页面是否有（空）组的标准入口。", "flags": ["--page <id> (可选,只列出该页面下的组)", "--page-name <name> (可选,按页面名精确匹配;找不到会报错,与 --page 互斥)"]],
    ["name": "pages", "description": "列出所有页面（SlotPage）。", "flags": ["--group <id> (可选,当前实现忽略,页面为全局)"]],
    ["name": "list", "description": "列出槽位摘要。指定 --group/--group-name 时列出该组 1..N 号槽位；只给 --page/--page-name 而不给组时，列出该页面下所有组各自的槽位并附 groupCount（页面无组则 groupCount=0，不再回落全局 default 组）。同时给页面和组时，组匹配被约束在该页面内。支持分页：传 --page-size 后按页返回并附带 pagination 元信息。", "flags": ["--group <id|name> (默认 default;可传 id 或组名)", "--group-name <name> (按组名精确匹配,优先于 --group)", "--page <id> (可选,约束 group 匹配到该页面;单独使用时列出该页所有组)", "--page-name <name> (按页面名精确匹配;找不到会报错,与 --page 互斥;单独使用时列出该页所有组)", "--page-size <N> (可选,每页槽位数,>0 时启用分页)", "--page-num <N> (可选,第几页,从 1 开始,默认 1,需配合 --page-size)"]],
    ["name": "read", "description": "读取单个槽位的完整内容（纯文本、HTML源、类型、附件数等）。", "flags": ["<slot> (位置参数,1..N)", "--group <id|name> (默认 default;可传 id 或组名)", "--group-name <name> (按组名精确匹配)", "--page <id> (可选,约束 --group/--group-name 匹配到该页面)", "--page-name <name> (按页面名精确匹配;找不到会报错,与 --page 互斥;约束 group 匹配范围)"]],
    ["name": "write", "description": "向槽位写入纯文本内容（保留已有附件），可选设置标签。成功返回里含 preview 字段(前100字符)，无需再 read 确认。支持 --batch 从 stdin 传入 JSON 数组一次写多条。", "flags": ["<slot> (位置参数,1..N;--batch 时省略)", "--text <string> (必填, 传 - 表示从 stdin 读取;--batch 时省略)", "--batch (从 stdin 读取 JSON 数组批量写入,见下)", "--group <id|name> (默认 default;可传 id 或组名)", "--group-name <name> (按组名精确匹配)", "--page <id> (可选,约束 --group/--group-name 匹配到该页面,防止写到同名他页组)", "--page-name <name> (按页面名精确匹配;找不到会报错,与 --page 互斥;约束 group 匹配范围)", "--label <string> (可选)", "--force (跳过跨进程锁,风险自负)"]],
    ["name": "search", "description": "在槽位预览/文本/标签中做大小写不敏感子串搜索。", "flags": ["<query> (位置参数)", "--group <id|name> (默认 default;可传 id 或组名)", "--group-name <name> (按组名精确匹配)", "--all-groups (在所有槽位组内搜索)", "--limit <N> (默认 50)"]],
    ["name": "paste", "description": "把某槽位的内容加载到系统剪贴板(NSPasteboard)，不模拟按键。", "flags": ["<slot> (位置参数,1..N)", "--group <id|name> (默认 default;可传 id 或组名)", "--group-name <name> (按组名精确匹配)", "--page <id> (可选,约束 --group/--group-name 匹配到该页面)", "--page-name <name> (按页面名精确匹配;找不到会报错,与 --page 互斥;约束 group 匹配范围)"]],
    ["name": "clear", "description": "清空某个槽位（内容、标签、附件全部移除）。", "flags": ["<slot> (位置参数,1..N)", "--group <id|name> (默认 default;可传 id 或组名)", "--group-name <name> (按组名精确匹配)", "--page <id> (可选,约束 --group/--group-name 匹配到该页面)", "--page-name <name> (按页面名精确匹配;找不到会报错,与 --page 互斥;约束 group 匹配范围)", "--force (跳过跨进程锁,风险自负)"]],
    ["name": "create-group", "description": "在指定页面新建一个槽位组，返回其 id。页面已满(10组)会返回错误，此时应先 create-page。v2.9.4: 同页面内不允许重名(会返回错误)，冲突时请改名或加 -2 后缀。", "flags": ["<name> (位置参数,组名)", "--page <id> (可选,默认当前页面)", "--page-name <name> (按页面名精确匹配指定目标页;找不到会报错,与 --page 互斥)"]],
    ["name": "create-page", "description": "新建一个页面，返回其 id。页面名不可重复。v2.9.33: 同步创建默认槽位组并在返回值中附带 defaultGroup {id,name}，可直接用其 id 写入，无需再跑 groups 查询。v2.9.42: 可选 --group-name，建页后立即把默认槽位组重命名为该名称，避免多出一个无用的默认组。", "flags": ["<name> (位置参数,页面名)", "--group-name <name> (可选,第一个槽位组的名称;不传则保留默认名)"]],
    ["name": "rename-group", "description": "重命名一个槽位组。v2.9.42: 常用于 create-page 之后把自动生成的默认组改成想要的第一个组名，避免浪费。同页面内组名不可重复(会返回错误)。", "flags": ["<group-id> (位置参数,要重命名的槽位组 id)", "--name <name> (必填,新名称)", "--page-name <name> (可选,仅用于日志/校验,不影响核心逻辑)"]],
    ["name": "delete-group", "description": "删除一个槽位组(软删除)。其数据目录会被移动到 .trash，可恢复；.trash 会自动清理(默认保留最近 30 天/最多 50 条)。id 不存在会返回错误。", "flags": ["<id> (位置参数,槽位组 id)"]],
    ["name": "delete-page", "description": "删除一个页面及其下所有槽位组(软删除)。相关数据目录会被移动到 .trash，可恢复；.trash 会自动清理(默认保留最近 30 天/最多 50 条)。id 不存在会返回错误。", "flags": ["<id> (位置参数,页面 id)"]],
    ["name": "write-attachment", "description": "向某槽位追加一个或多个文件作为附件（按顺序），不改动槽位主体内容。图片扩展名归为 image 类型，其余为 file。", "flags": ["<slot> (位置参数,1..N)", "<file> [file ...] (位置参数,一个或多个文件路径,支持 ~ 与相对路径)", "--group <id|name> (默认 default;可传 id 或组名)", "--group-name <name> (按组名精确匹配)", "--page <id> (可选,约束 --group/--group-name 匹配到该页面)", "--page-name <name> (按页面名精确匹配;找不到会报错,与 --page 互斥;约束 group 匹配范围)", "--replace (先清空该槽位已有附件再写入)", "--label <string> (可选)", "--force (跳过跨进程锁,风险自负)"]]
]

// v2.9.7 (R1): allowed flag names per command. Any flag not in this set is
// rejected with a clear error instead of being silently ignored, so agents
// catch typos (e.g. `--lable` instead of `--label`). `help`/`h` are always
// allowed (handled separately as per-command help). Positional args are not
// validated here — only `--flags`.
let COMMAND_ALLOWED_FLAGS: [String: Set<String>] = [
    "version": [],
    "help": [],
    "groups": ["page", "page-name"],
    "pages": ["group", "group-name"],
    "list": ["group", "group-name", "page", "page-name", "page-size", "page-num"],
    "read": ["group", "group-name", "page", "page-name"],
    "write": ["group", "group-name", "page", "page-name", "text", "label", "batch", "force"],
    "search": ["group", "group-name", "all-groups", "limit"],
    "paste": ["group", "group-name", "page", "page-name"],
    "clear": ["group", "group-name", "page", "page-name", "force"],
    "create-group": ["page", "page-name", "force"],
    "create-page": ["group-name", "force"],
    "rename-group": ["name", "page-name", "force"],
    "delete-group": ["force"],
    "delete-page": ["force"],
    "write-attachment": ["group", "group-name", "page", "page-name", "replace", "label", "force"]
]

// v2.9.7 (R1): validate that every --flag passed to a known command is
// recognized. Called once from the entry point before dispatch.
func validateFlags(_ args: ParsedArgs) {
    guard let allowed = COMMAND_ALLOWED_FLAGS[args.command] else { return }
    let alwaysOK: Set<String> = ["help", "h"]
    var keys = Set(args.flags.keys)
    keys.formUnion(args.boolFlags)
    for key in keys.sorted() where !allowed.contains(key) && !alwaysOK.contains(key) {
        let hint = allowed.isEmpty
            ? "command '\(args.command)' takes no flags"
            : "allowed flags: \(allowed.sorted().map { "--\($0)" }.joined(separator: ", "))"
        fail("unknown flag: --\(key) for command '\(args.command)' (\(hint); run 'clipslots \(args.command) --help')")
    }
}

func cmdHelp() -> Never {
    success([
        "version": CLI_VERSION,
        "defaultGroup": DEFAULT_GROUP,
        "defaultPage": DEFAULT_PAGE,
        "slotCount": slotCount,
        // v2.9.29: document the env var that overrides the data directory.
        "env": [
            "CLIPSLOTS_DATA_DIR": "覆盖数据目录，默认 ~/.local/share/clipslots；锁文件随之移动（当前生效值：\(ClipSlotsPaths.dataRoot.path)）"
        ],
        "commands": COMMANDS
    ])
}

// v2.9.5 (Feature #2): per-subcommand help. Triggered when a known command is
// invoked with `--help` or `-h` (e.g. `clipslots write --help`). Outputs that
// single command's usage + parameter descriptions.
func cmdCommandHelp(_ name: String) -> Never {
    guard let entry = COMMANDS.first(where: { ($0["name"] as? String) == name }) else {
        fail("unknown command: \(name) (run 'clipslots help')")
    }
    let flags = (entry["flags"] as? [String]) ?? []
    // Build a compact usage line from the flag descriptions.
    let usage = "clipslots \(name)" + (flags.isEmpty ? "" : " " + flags.joined(separator: " "))
    success([
        "command": name,
        "description": entry["description"] ?? NSNull(),
        "flags": flags,
        "usage": usage
    ])
}

func cmdGroups(_ args: ParsedArgs) -> Never {
    let index = storage.loadIndex()
    let pageNames = Dictionary(uniqueKeysWithValues: index.pages.map { ($0.id, $0.name) })
    // v2.9.32 (A4): optional page filter. `groups --page/--page-name X` returns only
    // the groups that live on page X. This is the first-class primitive an agent uses
    // to decide whether a page has any (empty) group before writing — replacing the
    // misleading `list --page-name` path. Without a page flag behaviour is unchanged
    // (all groups, every page). --page / --page-name validity + exclusivity is
    // enforced by resolvePageFlag (page-name errors if unknown).
    let filterPage = resolvePageFlag(args)
    // v2.9.41 (Problem A): emit groups sorted by (page order, group order) instead
    // of raw storage-array order. `order` is now assigned by request-receipt time,
    // so this makes `groups` output reflect the user's create-group issue sequence
    // even when the groups were created by parallel processes. Matches the ordering
    // `list --page` already uses.
    let pageOrder = Dictionary(uniqueKeysWithValues: index.pages.map { ($0.id, $0.order) })
    let sortedSlots = index.specialSlots.sorted { a, b in
        let pa = pageOrder[a.pageId] ?? Int.max
        let pb = pageOrder[b.pageId] ?? Int.max
        if pa != pb { return pa < pb }
        return a.order < b.order
    }
    var groups: [[String: Any]] = []
    for g in sortedSlots where filterPage == nil || g.pageId == filterPage {
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

// v2.9.32: shared per-slot summary builder, reused by both the single-group and
// the whole-page (A3) listing paths.
func slotSummaries(in group: String) -> [[String: Any]] {
    var slots: [[String: Any]] = []
    for n in 1...slotCount {
        let content = storage.get(n, in: group)
        let label = storage.getLabel(n, in: group) ?? content.label
        slots.append([
            "slot": n,
            "label": jsonValue(label),
            "preview": content.preview,
            "type": classify(content),
            "attachmentCount": content.attachments.count,
            "empty": isTrulyEmpty(content)
        ])
    }
    return slots
}

func cmdList(_ args: ParsedArgs) -> Never {
    let index = storage.loadIndex()
    let requestedPage = resolvePageFlag(args)
    let hasGroupFlag = args.flag("group") != nil || args.flag("group-name") != nil

    // v2.9.32 (A3): a page was given WITHOUT a group → list EVERY group on that page
    // instead of silently falling back to the global "default" group. The old
    // behaviour returned the (non-empty) global default group's slots, so an agent
    // that had just created a fresh page saw "full" slots and wrongly created extra
    // groups. `groupCount` makes the page's real state explicit: 0 means the page has
    // no group yet (create-page does NOT auto-create one — use create-group).
    if let pageId = requestedPage, !hasGroupFlag {
        let pageName = index.pages.first(where: { $0.id == pageId })?.name
        let groupsInPage = index.specialSlots
            .filter { $0.pageId == pageId }
            .sorted { $0.order < $1.order }
        let groupsOut: [[String: Any]] = groupsInPage.map { g in
            ["group": g.id, "name": g.name, "slots": slotSummaries(in: g.id)]
        }
        success([
            "page": pageId,
            "pageName": jsonValue(pageName),
            "groupCount": groupsInPage.count,
            "groups": groupsOut
        ])
    }

    // Single-group listing (v2.9.32: now page-scoped when a page is also given, so a
    // --group-name never resolves to a same-named group on another page).
    let group = resolveGroup(args, inPage: requestedPage)
    let page = requestedPage ?? pageId(forGroup: group, in: index)
    let slots = slotSummaries(in: group)

    // v2.9.7 (S2): optional pagination. When --page-size is provided we return
    // only that slice plus a `pagination` object so agents can page through long
    // output instead of parsing the whole array. Without --page-size behaviour is
    // unchanged (full list, no pagination field) for backward compatibility.
    if let psRaw = args.flag("page-size") {
        guard let pageSize = Int(psRaw), pageSize > 0 else {
            fail("--page-size must be a positive integer (got '\(psRaw)')")
        }
        let pageNum = Int(args.flag("page-num") ?? "1") ?? 1
        guard pageNum >= 1 else {
            fail("--page-num must be >= 1 (got '\(args.flag("page-num") ?? "")')")
        }
        let total = slots.count
        let totalPages = max(1, (total + pageSize - 1) / pageSize)
        let start = (pageNum - 1) * pageSize
        let pageSlots = start < total ? Array(slots[start..<min(start + pageSize, total)]) : []
        success([
            "group": group,
            "page": page,
            "slots": pageSlots,
            "pagination": [
                "pageNum": pageNum,
                "pageSize": pageSize,
                "total": total,
                "totalPages": totalPages,
                "hasMore": pageNum < totalPages
            ]
        ])
    }

    success(["group": group, "page": page, "slots": slots])
}

func cmdRead(_ args: ParsedArgs) -> Never {
    // v2.9.32 (A1): resolve the page first, then scope group matching to it.
    let requestedPage = resolvePageFlag(args)
    let group = resolveGroup(args, inPage: requestedPage)
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
        "empty": isTrulyEmpty(content)
    ])
}

// v2.9.16: a plain error carrying an already-formatted, agent-friendly message
// (used when `storage.set` returns false and we've probed the reason).
struct WriteFailure: Error { let message: String }

// v2.9.16 (#2, batch): resolve a group literal (id OR name) to a group id.
// v2.9.40 (P0): page-scoped resolution. When `inPage` is supplied (from a
// top-level --page / --page-name), the id/name lookup is RESTRICTED to groups on
// that page, and a literal that resolves to nothing on that page is a hard error
// (never silently falls back to a same-named group on ANOTHER page). Without a
// page constraint behaviour is unchanged (global, backward compatible).
func resolveGroupLiteral(_ raw: String, inPage pageId: String? = nil) -> String {
    let index = storage.loadIndex()
    let scope = pageId.map { pid in index.specialSlots.filter { $0.pageId == pid } }
                      ?? index.specialSlots
    if scope.contains(where: { $0.id == raw }) { return raw }
    if let g = scope.first(where: { $0.name == raw }) { return g.id }
    if let pid = pageId {
        let label = index.pages.first(where: { $0.id == pid })?.name ?? pid
        // P0 guardrail: refuse to write to a same-named group on another page.
        fail("group '\(raw)' not found in page '\(label)'")
    }
    return raw
}

// v2.9.16 (#5): shared text-write core used by both `write` and `write --batch`.
// Returns a short preview of the written text; throws StorageLockError on lock
// contention or WriteFailure with a diagnosed reason on IO failure.
func performTextWrite(slot n: Int, text: String, group: String, label: String?) throws -> String {
    // Mirror the GUI's updateTextSlot: build a public.utf8-plain-text item and
    // PRESERVE any existing attachments on the slot (v2.8.7 fix). Read-modify-write
    // runs as ONE cross-process critical section (v2.9.4 #4).
    let wrote = try StorageLock.shared.withLock { () -> Bool in
        let existing = storage.get(n, in: group)
        let data = text.data(using: .utf8) ?? Data()
        let item = PasteboardItem(type: "public.utf8-plain-text", data: data)
        var content = SlotContent()
        content.items = [[item]]
        content.timestamp = Date()
        content.attachments = existing.attachments
        let ok = storage.set(n, content: content, in: group)
        if ok, let label { storage.setLabel(n, label: label, in: group) }
        return ok
    }
    guard wrote else {
        throw WriteFailure(message: writeFailureDiagnostic(context: "to write slot \(n) in group \(group)"))
    }
    return previewText(text)
}

func cmdWrite(_ args: ParsedArgs) -> Never {
    // v2.9.16 (#3): batch mode dispatches to a separate handler.
    if args.hasFlag("batch") { cmdWriteBatch(args) }

    let group = resolveGroup(args, inPage: resolvePageFlag(args)) // v2.9.32 (A1): page-scoped
    let n = parseSlot(args.positionals.first)
    guard var text = args.flag("text") else {
        fail("missing --text <string> (use --text - to read from stdin, or --batch for bulk)")
    }
    if text == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        // v2.9.3 (Fix #5): reject non-UTF8 / binary stdin instead of silently
        // decoding to "" and CLEARING the slot. `write` only accepts text.
        guard let decoded = String(data: data, encoding: .utf8), !data.contains(0) else {
            fail("stdin is not valid UTF-8 text; write only accepts text (got \(data.count) bytes of binary)")
        }
        text = decoded
    }

    do {
        // v2.9.16 (#5): return `preview` so the agent needn't re-read to confirm.
        let preview = try performTextWrite(slot: n, text: text, group: group, label: args.flag("label"))
        success(["slot": n, "group": group, "preview": preview])
    } catch let e as StorageLockError {
        // v2.9.16 (#4): lock contention — accurate, retryable message.
        fail(e.errorDescription ?? "storage is busy (lock timeout)")
    } catch let e as WriteFailure {
        fail(e.message)
    } catch {
        // v2.9.16 (#4): genuine IO/permission error, NOT a lock conflict.
        fail(describeWriteError(error, context: "writing slot \(n) in group \(group)"))
    }
}

// v2.9.16 (#3): batch write. Reads a JSON array from stdin, each element an
// object {"slot":Int, "text":String, "group"?:String(id|name), "label"?:String}.
// Writes are attempted per-entry; a failure on one entry does NOT abort the rest.
// Returns {"ok":true,"batch":true,"total","written","failed","results":[...]}.
func cmdWriteBatch(_ args: ParsedArgs) -> Never {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else {
        fail("--batch expects a JSON array on stdin, got empty input "
            + "(e.g. echo '[{\"slot\":1,\"text\":\"a\"}]' | clipslots write --batch)")
    }
    let json: Any
    do {
        json = try JSONSerialization.jsonObject(with: data)
    } catch {
        fail("--batch stdin is not valid JSON: \(error.localizedDescription)")
    }
    guard let arr = json as? [[String: Any]] else {
        fail("--batch expects a JSON ARRAY of objects, e.g. [{\"slot\":1,\"text\":\"...\"}]")
    }
    guard !arr.isEmpty else { fail("--batch array is empty; nothing to write") }

    // Group/label from top-level flags act as defaults for entries that omit them.
    // v2.9.40 (P0): resolve the page ONCE and scope every group lookup to it, so
    // `write --batch --group-name X --page-name Y` writes to group X on page Y (or
    // errors), never to a same-named group on a different page.
    let requestedPage = resolvePageFlag(args)
    let defaultGroup = resolveGroup(args, inPage: requestedPage)
    let defaultLabel = args.flag("label")

    var results: [[String: Any]] = []
    var written = 0
    for (idx, entry) in arr.enumerated() {
        // slot (accept Int or numeric string).
        let slotNum: Int?
        if let s = entry["slot"] as? Int { slotNum = s }
        else if let s = entry["slot"] as? String { slotNum = Int(s) }
        else if let s = entry["slot"] as? NSNumber { slotNum = s.intValue }
        else { slotNum = nil }
        guard let n = slotNum else {
            results.append(["index": idx, "ok": false, "error": "missing or invalid 'slot'"])
            continue
        }
        guard (1...slotCount).contains(n) else {
            results.append(["index": idx, "slot": n, "ok": false,
                            "error": "slot out of range (valid 1...\(slotCount))"])
            continue
        }
        guard let text = entry["text"] as? String else {
            results.append(["index": idx, "slot": n, "ok": false,
                            "error": "missing or invalid 'text' (must be a string)"])
            continue
        }
        let group = (entry["group"] as? String).map { resolveGroupLiteral($0, inPage: requestedPage) } ?? defaultGroup
        let label = (entry["label"] as? String) ?? defaultLabel
        do {
            let preview = try performTextWrite(slot: n, text: text, group: group, label: label)
            results.append(["index": idx, "slot": n, "group": group, "ok": true, "preview": preview])
            written += 1
        } catch let e as StorageLockError {
            results.append(["index": idx, "slot": n, "group": group, "ok": false,
                            "error": e.errorDescription ?? "storage is busy (lock timeout)"])
        } catch let e as WriteFailure {
            results.append(["index": idx, "slot": n, "group": group, "ok": false, "error": e.message])
        } catch {
            results.append(["index": idx, "slot": n, "group": group, "ok": false,
                            "error": describeWriteError(error, context: "writing slot \(n)")])
        }
    }
    success([
        "batch": true,
        "total": arr.count,
        "written": written,
        "failed": arr.count - written,
        "results": results
    ])
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
            // v2.9.3: SlotContent.isEmpty already covers `items && attachments`, so the
            // old `content.isEmpty && content.attachments.isEmpty` is redundant.
            if content.isEmpty { continue }
            let label = storage.getLabel(n, in: g.id) ?? content.label ?? ""
            // v2.9.3: also search attachment file names so mode-C (attachment-only)
            // slots become findable by filename.
            let attachmentNames = content.attachments.map { $0.name }.joined(separator: "\n")
            let haystack = [content.preview, content.plainText ?? "", label, attachmentNames]
                .joined(separator: "\n").lowercased()
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
    let group = resolveGroup(args, inPage: resolvePageFlag(args)) // v2.9.32 (A1): page-scoped
    let n = parseSlot(args.positionals.first)
    let content = storage.get(n, in: group)
    guard !content.isEmpty else {
        fail("slot \(n) in group \(group) is empty; nothing to copy")
    }

    // v2.9.3 (Fix #2): if the slot has body items, restore them to the pasteboard as
    // before. Otherwise it is an attachment-only slot — restore() would fail because
    // it only writes items — so place the attachment file URLs on the clipboard
    // directly (mirroring the GUI's SlotAttachment.path resolution in
    // slotContentPayloads / payloadForAttachment).
    if !content.items.isEmpty {
        let ok = ClipboardManager.shared.restore(content)
        guard ok else { fail("failed to load slot \(n) onto the clipboard") }
        success(["slot": n, "action": "copied-to-clipboard"])
    } else {
        var urls: [NSURL] = []
        var skipped = 0
        for att in content.attachments {
            // Only .file / .image attachments resolve to an on-disk file path; other
            // types (text/url/reference) or path-less attachments are skipped.
            if let path = att.path, !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                urls.append(URL(fileURLWithPath: path) as NSURL)
            } else {
                skipped += 1
            }
        }
        guard !urls.isEmpty else {
            fail("slot \(n) in group \(group) has \(content.attachments.count) attachment(s) but none resolve to an existing file path")
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.writeObjects(urls)
        guard ok else { fail("failed to write attachment file URLs to the clipboard") }
        var out: [String: Any] = [
            "slot": n,
            "action": "copied-to-clipboard",
            "attachmentsCopied": urls.count
        ]
        if skipped > 0 { out["attachmentsSkipped"] = skipped }
        success(out)
    }
}

func cmdCreateGroup(_ args: ParsedArgs) -> Never {
    guard let name = args.positionals.first, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
        fail("missing group name (usage: create-group <name> [--page <id>])")
    }
    let page = resolvePageFlag(args, strict: true)
    do {
        let slot = try storage.createSpecialSlot(name: name, pageId: page, requestedAt: CLI_REQUEST_RECEIVED_AT)
        success(["group": ["id": slot.id, "name": slot.name, "pageId": slot.pageId]])
    } catch SpecialSlotError.duplicateName {
        // v2.9.4 (Feature #4): same-page duplicate name is rejected. Agents should
        // rename or add a `-2` suffix on conflict (see skill doc).
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        fail("a group named '\(trimmed)' already exists on this page")
    } catch let e as StorageLockError {
        // v2.9.4 (#4): cross-process lock contention timeout.
        fail(e.errorDescription ?? "storage is busy (lock timeout)")
    } catch let e as SpecialSlotError {
        // maxSpecialSlotsReached → the caller should create a new page (see skill rules).
        fail(e.errorDescription ?? "failed to create group")
    } catch {
        fail(describeWriteError(error, context: "creating group"))
    }
}

func cmdCreatePage(_ args: ParsedArgs) -> Never {
    guard let name = args.positionals.first, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
        fail("missing page name (usage: create-page <name>)")
    }
    // v2.9.42 (Feature B): optional --group-name renames the synchronously-created
    // default group right after the page is built, so callers who already know the
    // first group's name don't end up with an extra unused "默认槽位组".
    let desiredGroupName = args.flag("group-name")?.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
        // v2.9.43: name the default group atomically inside createPage instead of
        // doing a second `renameSpecialSlot` write afterwards. The old two-write
        // sequence left a brief window where the group was named "默认槽位组",
        // which the concurrently-running GUI (separate process, in-process lock
        // only) could observe and race with — occasionally producing BOTH the
        // intended group and a lingering "默认槽位组" on the page. Passing the
        // final name up front guarantees exactly one group with the correct name.
        let effectiveGroupName = (desiredGroupName?.isEmpty == false) ? desiredGroupName : nil
        let result = try storage.createPage(name: name, defaultGroupName: effectiveGroupName)
        var payload: [String: Any] = [
            "page": ["id": result.page.id, "name": result.page.name, "order": result.page.order]
        ]
        if let g = result.defaultGroup {
            payload["defaultGroup"] = ["id": g.id, "name": g.name]
        }
        success(payload)
    } catch let e as StorageLockError {
        fail(e.errorDescription ?? "storage is busy (lock timeout)")
    } catch let e as PageError {
        fail(e.errorDescription ?? "failed to create page")
    } catch {
        fail(describeWriteError(error, context: "creating page"))
    }
}

// v2.9.42 (Feature A): rename an existing slot group by id. Primary use case is
// renaming the auto-created default group after `create-page` so no wasted empty
// group is left behind. Same-page duplicate names are rejected by the Kit layer
// (renameSpecialSlot throws SpecialSlotError.duplicateName), surfaced here with
// the documented message.
func cmdRenameGroup(_ args: ParsedArgs) -> Never {
    guard let id = args.positionals.first, !id.trimmingCharacters(in: .whitespaces).isEmpty else {
        fail("missing group id (usage: rename-group <group-id> --name <新名称> [--page-name <页面名>])")
    }
    guard let newName = args.flag("name"), !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fail("missing new name (usage: rename-group <group-id> --name <新名称>)")
    }
    let index = storage.loadIndex()
    guard let group = index.specialSlots.first(where: { $0.id == id }) else {
        fail("group \(id) not found")
    }
    // --page-name is advisory only: when provided, validate it matches the group's
    // owning page so a caller cannot silently rename a group on the wrong page.
    if let pageName = args.flag("page-name") {
        let ownerPageName = index.pages.first(where: { $0.id == group.pageId })?.name
        if ownerPageName != pageName {
            fail("group '\(id)' is not on page '\(pageName)'")
        }
    }
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
        try storage.renameSpecialSlot(id: id, name: trimmed)
        let finalName = storage.loadIndex().specialSlots.first(where: { $0.id == id })?.name ?? String(trimmed.prefix(30))
        success(["group": ["id": id, "name": finalName]])
    } catch SpecialSlotError.duplicateName {
        fail("a group named '\(String(trimmed.prefix(30)))' already exists on this page")
    } catch SpecialSlotError.specialSlotNotFound {
        fail("group \(id) not found")
    } catch SpecialSlotError.invalidSpecialSlotName {
        fail("invalid group name")
    } catch let e as StorageLockError {
        fail(e.errorDescription ?? "storage is busy (lock timeout)")
    } catch let e as SpecialSlotError {
        fail(e.errorDescription ?? "failed to rename group")
    } catch {
        fail(describeWriteError(error, context: "renaming group \(id)"))
    }
}

func cmdWriteAttachment(_ args: ParsedArgs) -> Never {
    let group = resolveGroup(args, inPage: resolvePageFlag(args)) // v2.9.35: page-scoped (flag parity with write)
    guard let slotRaw = args.positionals.first else {
        fail("missing slot number (usage: write-attachment <slot> <file> [file ...] [--group <id>] [--page <id>] [--replace])")
    }
    let n = parseSlot(slotRaw)
    let fileArgs = Array(args.positionals.dropFirst())
    guard !fileArgs.isEmpty else {
        fail("no files given (usage: write-attachment <slot> <file> [file ...])")
    }

    // Resolve + validate each path, build SlotAttachment mirroring the GUI
    // (name = last path component, type by extension, path = absolute path).
    let cwd = FileManager.default.currentDirectoryPath
    var newAtts: [SlotContent.SlotAttachment] = []
    var added: [String] = []
    for raw in fileArgs {
        let expanded = (raw as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: cwd).appendingPathComponent(expanded)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            fail("file not found or is a directory: \(url.path)")
        }
        let ext = url.pathExtension.lowercased()
        let type: SlotContent.AttachmentType = IMAGE_EXTS.contains(ext) ? .image : .file
        newAtts.append(SlotContent.SlotAttachment(name: url.lastPathComponent, type: type, path: url.path))
        added.append(url.lastPathComponent)
    }

    // v2.9.4 (#4): perform read-modify-write under the cross-process lock.
    let result: (ok: Bool, attachmentCount: Int, bodyEmpty: Bool)
    do {
        result = try StorageLock.shared.withLock { () -> (Bool, Int, Bool) in
            var content = storage.get(n, in: group)
            if args.hasFlag("replace") {
                content.attachments = newAtts
            } else {
                content.attachments.append(contentsOf: newAtts)
            }
            let wrote = storage.set(n, content: content, in: group)
            if wrote, let label = args.flag("label") {
                storage.setLabel(n, label: label, in: group)
            }
            return (wrote, content.attachments.count, content.items.isEmpty)
        }
    } catch let e as StorageLockError {
        fail(e.errorDescription ?? "storage is busy (lock timeout)")
    } catch {
        fail(describeWriteError(error, context: "writing attachments to slot \(n) in group \(group)"))
    }
    guard result.ok else { fail(writeFailureDiagnostic(context: "to write attachments to slot \(n) in group \(group)")) }

    success([
        "slot": n,
        "group": group,
        "added": added,
        "attachmentCount": result.attachmentCount,
        // v2.9.3: report whether the slot BODY (items) is empty. content.isEmpty now
        // also considers attachments (which we just wrote), so use items.isEmpty here.
        "slotBodyEmpty": result.bodyEmpty
    ])
}

func cmdClear(_ args: ParsedArgs) -> Never {
    let group = resolveGroup(args, inPage: resolvePageFlag(args)) // v2.9.35: page-scoped (flag parity with write)
    let n = parseSlot(args.positionals.first)
    // v2.9.4 (#4): cross-process lock around the clear write.
    do {
        try StorageLock.shared.withLock {
            storage.clear(n, in: group)
        }
    } catch let e as StorageLockError {
        fail(e.errorDescription ?? "storage is busy (lock timeout)")
    } catch {
        fail(describeWriteError(error, context: "clearing slot \(n) in group \(group)"))
    }
    success(["slot": n, "group": group, "action": "cleared"])
}

// v2.9.4 (Feature #3): delete a whole slot group. The data layer moves the
// group's directory to `.trash` (recoverable), so this is a soft delete.
func cmdDeleteGroup(_ args: ParsedArgs) -> Never {
    guard let id = args.positionals.first, !id.trimmingCharacters(in: .whitespaces).isEmpty else {
        fail("missing group id (usage: delete-group <id>)")
    }
    // Validate existence first for a clear, agent-friendly error.
    let index = storage.loadIndex()
    guard index.specialSlots.contains(where: { $0.id == id }) else {
        fail("group \(id) not found")
    }
    do {
        try storage.deleteSpecialSlot(id: id)
        success(["deleted": id, "movedToTrash": true])
    } catch let e as StorageLockError {
        fail(e.errorDescription ?? "storage is busy (lock timeout)")
    } catch let e as SpecialSlotError {
        fail(e.errorDescription ?? "failed to delete group")
    } catch {
        fail(describeWriteError(error, context: "deleting group"))
    }
}

// v2.9.4 (Feature #3): delete a whole page (and its slot groups). The data layer
// moves the affected group directories to `.trash` (recoverable).
func cmdDeletePage(_ args: ParsedArgs) -> Never {
    guard let id = args.positionals.first, !id.trimmingCharacters(in: .whitespaces).isEmpty else {
        fail("missing page id (usage: delete-page <id>)")
    }
    let index = storage.loadIndex()
    guard index.pages.contains(where: { $0.id == id }) else {
        fail("page \(id) not found")
    }
    do {
        try storage.deletePage(id: id)
        success(["deleted": id, "movedToTrash": true])
    } catch let e as StorageLockError {
        fail(e.errorDescription ?? "storage is busy (lock timeout)")
    } catch let e as PageError {
        fail(e.errorDescription ?? "failed to delete page")
    } catch {
        fail(describeWriteError(error, context: "deleting page"))
    }
}

// MARK: - Entry point

let parsed = parseArgs(CommandLine.arguments.dropFirst().map { $0 })

// v2.9.5 (Feature #2): if a known subcommand is invoked with --help/-h, show
// that command's own usage instead of running it. The bare `help`/`version`
// commands are handled by the switch below.
if parsed.command != "help", parsed.command != "version",
   parsed.boolFlags.contains("help") || parsed.boolFlags.contains("h") {
    cmdCommandHelp(parsed.command)
}

// v2.9.7 (R1): reject unknown flags for known commands (typo protection) before
// dispatch, so `--lable`/`--pagesize` etc. surface a clear error instead of being
// silently ignored.
validateFlags(parsed)

// v2.9.16 (#6): global `--force` bypasses the cross-process lock for this run.
// Only allowed on mutating commands (validated above). A one-time warning is
// emitted to stderr from StorageLock when the bypass actually takes effect.
if parsed.hasFlag("force") {
    StorageLock.forceUnlocked = true
}

switch parsed.command {
case "version", "--version", "-v":
    cmdVersion()
case "help", "--help", "-h":
    cmdHelp()
case "groups":
    cmdGroups(parsed)
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
case "clear":
    cmdClear(parsed)
case "create-group":
    cmdCreateGroup(parsed)
case "create-page":
    cmdCreatePage(parsed)
case "rename-group":
    cmdRenameGroup(parsed)
case "delete-group":
    cmdDeleteGroup(parsed)
case "delete-page":
    cmdDeletePage(parsed)
case "write-attachment":
    cmdWriteAttachment(parsed)
default:
    fail("unknown command: \(parsed.command) (run 'clipslots help')")
}
