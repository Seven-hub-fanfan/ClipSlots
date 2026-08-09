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

// UP-1 (v2.10.30): bump the hardcoded CLI version from the stale "2.10.16" to the
// current release. This is the single source of truth surfaced by `version`,
// `help` and per-command help (all reference CLI_VERSION), so no other literal
// needs bumping.
// v2.10.66: keep in lockstep with the app's CFBundleShortVersionString on every
// release — this constant had drifted (2.10.58) behind the app (2.10.65).
let CLI_VERSION = "2.10.67"
let DEFAULT_GROUP = "default"
let DEFAULT_PAGE = "default_page"

// UP-3 (v2.10.30): hard cap on how much stdin the `write --batch` path will read
// before erroring. A malicious/oversized JSON payload must not be buffered wholesale
// into memory (OOM risk); we read incrementally and abort once this many bytes have
// been accumulated. 64 MiB is far above any legitimate batch while bounding memory.
let MAX_BATCH_STDIN_BYTES = 64 * 1024 * 1024

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
        // P2-21 (v2.10.9): this fallback is itself a failure (ok:false) → exit non-zero.
        exit(1)
    }
    print(str)
    // P2-21 (v2.10.9): any failure response (ok == false) MUST exit with a non-zero
    // status so callers can rely on the process exit code, not just the JSON body.
    // Success responses fall through (callers exit(0) as before). This does not alter
    // the JSON stdout contract — the response is already printed above.
    if let ok = dict["ok"] as? Bool, !ok { exit(1) }
}

func success(_ dict: [String: Any]) -> Never {
    var d = dict
    d["ok"] = true
    // F7 (契约5): every success response carries the default-page/group repair
    // status. `repaired` is ALWAYS present (false when nothing was repaired); when
    // a repair happened `repair_actions` lists what was done. Callers that already
    // set `repaired` (e.g. batch builds it itself) are left untouched.
    if d["repaired"] == nil {
        d["repaired"] = storage.didRepairDefaults
        if storage.didRepairDefaults { d["repair_actions"] = storage.lastRepairActions }
    }
    emit(d)
    exit(0)
}

// F7 (契约7): failures now carry a stable, all-caps `error_code` for reliable
// agent branching, plus optional structured `extra` fields (e.g. candidate lists).
// The default code "ERROR" keeps every existing `fail("...")` call compiling.
func fail(_ message: String, code: String = "ERROR", extra: [String: Any] = [:]) -> Never {
    var d: [String: Any] = ["ok": false, "error": message, "error_code": code]
    for (k, v) in extra { d[k] = v }
    emit(d)
    exit(1)
}

// A String? -> Any that JSONSerialization accepts (nil becomes NSNull).
func jsonValue(_ value: String?) -> Any { value ?? NSNull() }

// P2-14: map low-level storage errors to stable, specific error codes so callers
// don't get the generic "ERROR" for well-known failure kinds. Exhaustive switches
// (no default) keep them in sync with the Kit enum definitions.
func codeForSpecialSlotError(_ e: SpecialSlotError) -> String {
    switch e {
    case .duplicateName: return "DUPLICATE_NAME"
    case .maxSpecialSlotsReached: return "PAGE_GROUP_LIMIT_REACHED"
    case .specialSlotNotFound: return "GROUP_NOT_FOUND"
    case .defaultGroupProtected: return "DEFAULT_GROUP_PROTECTED"
    case .cannotDeleteLastSpecialSlot: return "CANNOT_DELETE_LAST_GROUP"
    case .invalidSpecialSlotName: return "INVALID_INPUT_FORMAT"
    case .indexCorrupted: return "INDEX_CORRUPTED"
    }
}
func codeForPageError(_ e: PageError) -> String {
    switch e {
    case .duplicateName: return "DUPLICATE_NAME"
    case .pageNotFound: return "PAGE_NOT_FOUND"
    case .defaultPageProtected: return "DEFAULT_PAGE_PROTECTED"
    case .cannotDeleteLastPage: return "CANNOT_DELETE_LAST_PAGE"
    case .emptyName: return "INVALID_INPUT_FORMAT"
    }
}

// MARK: - Argument parsing (dependency-free)

struct ParsedArgs {
    var command: String
    var positionals: [String]
    var flags: [String: String]
    var boolFlags: Set<String>

    func flag(_ name: String) -> String? { flags[name] }
    func hasFlag(_ name: String) -> Bool { boolFlags.contains(name) || flags[name] != nil }
}

// P1-7 (v2.10.9): known value-less BOOLEAN flags. The old parser greedily treated
// the token after ANY `--xxx` as its value (only treating `--xxx` as boolean when the
// NEXT token also started with `--`), so `write-attachment 1 --replace photo.png`,
// `delete-group --force <id>` and `search --all-groups <query>` wrongly let the boolean
// flag swallow the following positional. Flags listed here NEVER consume the next token;
// every other `--xxx` keeps value-taking behaviour. Verified against the command handlers
// (e.g. --page-name is value-taking via args.flag("page-name"), so it is intentionally
// NOT in this set).
let BOOLEAN_FLAGS: Set<String> = [
    "force", "replace", "if-empty", "overwrite-text", "all-groups", "batch",
    "stop-on-error", "help"
]

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
            // P1-7 (v2.10.9): a known boolean flag is value-less — record it as true and
            // do NOT consume the following token (so the next positional survives).
            if BOOLEAN_FLAGS.contains(key) {
                boolFlags.insert(key)
                i += 1
                continue
            }
            // CLI-1 (v2.10.15): value-taking (non-boolean) flags MUST consume the next
            // token as their value even when it starts with "--" (e.g. `--text --hello`
            // or a `---` markdown divider). The old `!next.hasPrefix("--")` guard
            // misclassified such values as flags, losing them and raising
            // INVALID_ARGUMENT_COMBINATION, making such text impossible to write. Boolean
            // flags are already handled above and never reach here, so `--flag1 --flag2`
            // (flag1 boolean) is unaffected.
            if let next = (i + 1 < raw.count) ? raw[i + 1] : nil {
                flags[key] = next
                i += 2
            } else {
                // No next token at all → record the flag as a value-less boolean.
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
    let hasGroupFlag = args.flag("group") != nil || args.flag("group-name") != nil

    // F2 (契约3): single-slot ops (read/write/paste/clear/write-attachment) must name a
    // group. When a page is given but NO group flag, refuse instead of falling back to
    // the global default group. `list` handles the page-only case in its own branch
    // BEFORE calling resolveGroup, so it is never affected by this guard.
    if pageId != nil, !hasGroupFlag {
        fail("a group is required: pass --group or --group-name (page-only single-slot operation rejected)", code: "GROUP_REQUIRED")
    }

    // Candidate scope: page-constrained when a page was requested, else global.
    let scope = pageId.map { pid in index.specialSlots.filter { $0.pageId == pid } }
                      ?? index.specialSlots
    // Human-friendly label for the requested page (name if known, else the id).
    let pageLabel: String? = pageId.map { pid in
        index.pages.first(where: { $0.id == pid })?.name ?? pid
    }

    if let name = args.flag("group-name") {
        let matches = scope.filter { $0.name == name }
        // F1 (契约7): without a page constraint an ambiguous name must not silently
        // pick the first match.
        if matches.count > 1 { failAmbiguousGroup(name: name, matches: matches, index: index) }
        if let g = matches.first { return g.id }
        if let label = pageLabel {
            // A2 guardrail: named group is not on the requested page → refuse.
            fail("group '\(name)' not found in page '\(label)'", code: "GROUP_NOT_FOUND")
        }
        fail("no group found with name '\(name)' (run 'clipslots groups' to list names)", code: "GROUP_NOT_FOUND")
    }

    if let explicit = args.flag("group") {
        if scope.contains(where: { $0.id == explicit }) { return explicit }
        let nameMatches = scope.filter { $0.name == explicit }
        if nameMatches.count > 1 { failAmbiguousGroup(name: explicit, matches: nameMatches, index: index) }
        if let g = nameMatches.first { return g.id }
        // CLI-2 (v2.10.15): an explicit `--group default` must behave the same as
        // OMITTING --group (which falls through to the DEFAULT_GROUP literal below),
        // instead of erroring GROUP_NOT_FOUND just because that group hasn't been
        // materialised in the index yet. Mirror the omitted-group fallback for the
        // default group id specifically.
        if explicit == DEFAULT_GROUP { return explicit }
        if let label = pageLabel {
            // A2 guardrail: an explicit --group (id or name) that resolves to nothing
            // on the requested page is a page/group mismatch → refuse.
            fail("group '\(explicit)' not found in page '\(label)'", code: "GROUP_NOT_FOUND")
        }
        // F1/契约7: do NOT silently pass an unknown literal through.
        fail("group '\(explicit)' not found", code: "GROUP_NOT_FOUND")
    }

    // No group flag, no page → documented default group.
    let raw = DEFAULT_GROUP
    if scope.contains(where: { $0.id == raw }) { return raw }
    if let g = scope.first(where: { $0.name == raw }) { return g.id }
    return raw
}

// F1 (契约7): ambiguous group name across pages → AMBIGUOUS_GROUP with candidate list.
func failAmbiguousGroup(name: String, matches: [SpecialSlot], index: SpecialSlotIndex) -> Never {
    let pageNames = Dictionary(uniqueKeysWithValues: index.pages.map { ($0.id, $0.name) })
    let candidates: [[String: Any]] = matches.map { g in
        ["group": g.id, "page": g.pageId, "pageName": jsonValue(pageNames[g.pageId])]
    }
    fail("group name '\(name)' is ambiguous across \(matches.count) groups; pass --page/--page-name to disambiguate",
         code: "AMBIGUOUS_GROUP", extra: ["candidates": candidates])
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
        fail("specify only one of --page or --page-name", code: "INVALID_ARGUMENT_COMBINATION")
    }
    let index = storage.loadIndex()
    if let name = args.flag("page-name") {
        if let p = index.pages.first(where: { $0.name == name }) { return p.id }
        fail("no page named '\(name)'", code: "PAGE_NOT_FOUND")
    }
    if let page = args.flag("page") {
        if let p = index.pages.first(where: { $0.id == page || $0.name == page }) { return p.id }
        // v2.9.29: an explicitly requested page that matches nothing is an error
        // for placement commands (was previously a silent fallback to currentPage).
        if strict {
            fail("no page with id or name '\(page)'", code: "PAGE_NOT_FOUND")
        }
        return page
    }
    return nil
}

func parseSlot(_ raw: String?) -> Int {
    // P2-20 (v2.10.9): an unparseable / out-of-range slot now returns a dedicated
    // INVALID_SLOT code (was INVALID_LIMIT, which conflated it with search/pagination
    // limits). The batch path emits the same INVALID_SLOT so both paths are unified.
    guard let raw, let n = Int(raw) else {
        fail("missing or invalid slot number (expected 1...\(slotCount))", code: "INVALID_SLOT")
    }
    guard (1...slotCount).contains(n) else {
        fail("slot out of range: \(n) (valid 1...\(slotCount))", code: "INVALID_SLOT")
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

// P2-2 (v2.10.5): the Kit raises `SpecialSlotStorageError.refusingToOverwriteWithEmptyIndex`
// from saveIndex when a write would clobber a non-empty on-disk index with the empty
// fallback (a data-loss guard). Previously every write/create/rename/delete command let
// it fall through to the generic `catch` → `describeWriteError`, surfacing the useless
// `error_code: "ERROR"`. This helper maps it to a stable, specific code so agents can
// distinguish index-protection (retry / inspect data dir) from ordinary IO failures,
// and defers everything else to `describeWriteError`.
func failWriteError(_ error: Error, context: String) -> Never {
    if let e = error as? SpecialSlotStorageError {
        switch e {
        case .refusingToOverwriteWithEmptyIndex:
            fail("refusing to overwrite existing slot data with an empty index while \(context); "
                    + "the on-disk index may be temporarily unreadable — retry, and if it persists "
                    + "inspect \(ClipSlotsPaths.dataRoot.path)",
                 code: "INDEX_WRITE_REFUSED")
        }
    }
    // P2-10 (v2.10.6): 泛化写入失败映射为 WRITE_FAILED，与批量路径（error_code:
    // "WRITE_FAILED"）保持一致。此前单写路径沿用 fail 默认码 "ERROR"，同一类 I/O 失败
    // 在单写/批量两条路径返回不同错误码，增加调用方适配成本。
    fail(describeWriteError(error, context: context), code: "WRITE_FAILED")
}

// Same mapping as `failWriteError` but returns (code, message) for the batch path,
// which aggregates per-item results instead of exiting.
func writeErrorCodeAndMessage(_ error: Error, context: String) -> (code: String, message: String) {
    if let e = error as? SpecialSlotStorageError {
        switch e {
        case .refusingToOverwriteWithEmptyIndex:
            return ("INDEX_WRITE_REFUSED",
                    "refusing to overwrite existing slot data with an empty index while \(context)")
        }
    }
    // P2-12 (v2.10.7): 与单写路径 failWriteError 的 WRITE_FAILED 对齐，避免批量辅助函数返回旧的 ERROR。
    return ("WRITE_FAILED", describeWriteError(error, context: context))
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
    // F7: `version` stays a minimal, stable probe ({"ok":true,"version":"..."}),
    // bypassing success()'s repaired-status injection so callers can parse it raw.
    emit(["ok": true, "version": CLI_VERSION])
    exit(0)
}

// A-6 (v2.10.31): CLI 自愈入口。当索引 index.json 解码失败进入「写禁态」后，调用 Kit 的
// SpecialSlotStorage.forceRepair() 清除毒化标志并从备份/默认重建索引，返回执行的动作字符串
// （如 "restored_from_corrupt_backup" / "recreated_default_index"）。仿照 `version` 的最简
// 只读模式：直接 emit 稳定 JSON（{"ok":true,"action":"<返回值>"}），不经 success() 注入
// repaired 状态，便于调用方原样解析。`storage` 即 SpecialSlotStorage.shared。
func cmdRepairIndex() -> Never {
    let action = storage.forceRepair()
    // P0-1 (v2.10.32): forceRepair() now refuses to touch a HEALTHY index and returns
    // "index_healthy_no_action". Surface that clearly so callers/AI never mistake a no-op
    // for a successful repair, and never assume data was rebuilt when nothing was wrong.
    if action == "index_healthy_no_action" {
        emit([
            "ok": true,
            "action": "none",
            "repaired": false,
            "note": "index is healthy — no repair needed; no data was modified"
        ])
        exit(0)
    }
    emit(["ok": true, "action": action, "repaired": true])
    exit(0)
}

// v2.9.5 (Feature #2): single source of truth for command metadata. Both the
// top-level `help` command and per-subcommand `--help`/`-h` render from this.
let COMMANDS: [[String: Any]] = [
    ["name": "version", "description": "打印 CLI 版本号。", "flags": [] as [String]],
    ["name": "help", "description": "列出所有命令、说明与参数（无参数时也返回此内容）。", "flags": [] as [String]],
    // A-6 (v2.10.31): 索引自愈入口。
    ["name": "repair-index", "description": "仅当索引(index.json)确实损坏时才修复：清除写禁态并从备份/默认恢复；索引健康则不做任何改动并返回 action:none。返回执行的动作。", "flags": [] as [String]],
    ["name": "groups", "description": "列出槽位组（SpecialSlot）。可用 --page/--page-name 只列出指定页面下的组，是判断某页面是否有（空）组的标准入口。", "flags": ["--page <id> (可选,只列出该页面下的组)", "--page-name <name> (可选,按页面名精确匹配;找不到会报错,与 --page 互斥)"]],
    ["name": "pages", "description": "列出所有页面（SlotPage）。", "flags": ["--group <id> (可选,当前实现忽略,页面为全局)"]],
    ["name": "list", "description": "列出槽位摘要。指定 --group/--group-name 时列出该组 1..N 号槽位；只给 --page/--page-name 而不给组时，列出该页面下所有组各自的槽位并附 groupCount（页面无组则 groupCount=0，不再回落全局 default 组）。同时给页面和组时，组匹配被约束在该页面内。支持分页：传 --page-size 后按页返回并附带 pagination 元信息。", "flags": ["--group <id|name> (默认 default;可传 id 或组名)", "--group-name <name> (按组名精确匹配,优先于 --group)", "--page <id> (可选,约束 group 匹配到该页面;单独使用时列出该页所有组)", "--page-name <name> (按页面名精确匹配;找不到会报错,与 --page 互斥;单独使用时列出该页所有组)", "--page-size <N> (可选,每页槽位数,>0 时启用分页)", "--page-num <N> (可选,第几页,从 1 开始,默认 1,需配合 --page-size)"]],
    ["name": "read", "description": "读取单个槽位的完整内容（纯文本、HTML源、类型、附件数等）。", "flags": ["<slot> (位置参数,1..N)", "--group <id|name> (默认 default;可传 id 或组名)", "--group-name <name> (按组名精确匹配)", "--page <id> (可选,约束 --group/--group-name 匹配到该页面)", "--page-name <name> (按页面名精确匹配;找不到会报错,与 --page 互斥;约束 group 匹配范围)"]],
    ["name": "write", "description": "向槽位写入纯文本内容（保留已有附件），可选设置标签。成功返回里含 preview 字段(前100字符)，无需再 read 确认。支持 --batch 从 stdin 传入 JSON 数组一次写多条。", "flags": ["<slot> (位置参数,1..N;--batch 时省略)", "--text <string> (必填, 传 - 表示从 stdin 读取;--batch 时省略)", "--batch (从 stdin 读取 JSON 数组批量写入,见下)", "--group <id|name> (默认 default;可传 id 或组名)", "--group-name <name> (按组名精确匹配)", "--page <id> (可选,约束 --group/--group-name 匹配到该页面,防止写到同名他页组)", "--page-name <name> (按页面名精确匹配;找不到会报错,与 --page 互斥;约束 group 匹配范围)", "--label <string> (可选)", "--if-empty (仅写入空槽,非空返回 SLOT_NOT_EMPTY)", "--overwrite-text (明确覆盖文本,保留附件与标签)", "--stop-on-error (批量遇错停止,默认 false)", "--force (跳过跨进程锁,风险自负)"]],
    ["name": "search", "description": "在槽位预览/文本/标签/附件名中做大小写不敏感子串搜索。", "flags": ["<query> (位置参数)", "--group <id|name> (默认 default;可传 id 或组名)", "--group-name <name> (按组名精确匹配)", "--page <uuid> / --page-name <name> (限定页面;仅传页面不传组则搜该页所有组)", "--all-groups (在所有槽位组内搜索)", "--limit <N> (默认 50)"]],
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
    // A-6 (v2.10.31): repair-index 是无参只读式自愈命令，不接受任何 flag。
    "repair-index": [],
    "groups": ["page", "page-name"],
    "pages": ["group", "group-name"],
    "list": ["group", "group-name", "page", "page-name", "page-size", "page-num"],
    "read": ["group", "group-name", "page", "page-name", "slot"],
    "write": ["group", "group-name", "page", "page-name", "text", "label", "batch", "force", "if-empty", "overwrite-text", "stop-on-error", "slot"],
    "search": ["group", "group-name", "all-groups", "limit", "page", "page-name"],
    "paste": ["group", "group-name", "page", "page-name", "slot"],
    "clear": ["group", "group-name", "page", "page-name", "force", "slot"],
    "create-group": ["page", "page-name", "force"],
    "create-page": ["group-name", "force"],
    "rename-group": ["name", "page-name", "force"],
    "delete-group": ["force"],
    "delete-page": ["force"],
    "write-attachment": ["group", "group-name", "page", "page-name", "replace", "label", "force", "slot"]
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
        fail("unknown flag: --\(key) for command '\(args.command)' (\(hint); run 'clipslots \(args.command) --help')", code: "INVALID_ARGUMENT_COMBINATION")
    }
}

// F9 (契约7 附): argument-combination validation. Runs AFTER validateFlags (so unknown
// flags are already rejected). Emits INVALID_ARGUMENT_COMBINATION / INVALID_LIMIT.
func validateArgCombinations(_ args: ParsedArgs) {
    if args.flag("group") != nil && args.flag("group-name") != nil {
        fail("--group and --group-name are mutually exclusive", code: "INVALID_ARGUMENT_COMBINATION")
    }
    if args.flag("page") != nil && args.flag("page-name") != nil {
        fail("--page and --page-name are mutually exclusive", code: "INVALID_ARGUMENT_COMBINATION")
    }
    if args.hasFlag("if-empty") && args.hasFlag("overwrite-text") {
        fail("--if-empty and --overwrite-text are mutually exclusive", code: "INVALID_ARGUMENT_COMBINATION")
    }
    if args.hasFlag("all-groups") &&
        (args.flag("page") != nil || args.flag("page-name") != nil ||
         args.flag("group") != nil || args.flag("group-name") != nil) {
        fail("--all-groups cannot be combined with --page/--page-name/--group/--group-name", code: "INVALID_ARGUMENT_COMBINATION")
    }
    if let lim = args.flag("limit") {
        guard let n = Int(lim), n > 0 else {
            fail("--limit must be a positive integer (got '\(lim)')", code: "INVALID_LIMIT")
        }
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
        // P2-7 (v2.10.8): carry a stable error_code like every other failure.
        fail("unknown command: \(name) (run 'clipslots help')", code: "UNKNOWN_COMMAND")
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
        // P2-11 (v2.10.6): order 相同时补 .id 次级键，保证输出顺序稳定（与 list --page / Kit 口径一致）。
        return a.order != b.order ? a.order < b.order : a.id < b.id
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
    // P2-11 (v2.10.6): order 相同时补 .id 次级键，保证页面输出顺序稳定（与 groups / Kit 口径一致）。
    for p in index.pages.sorted(by: { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }) {
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
        // P2-9 (v2.10.6): 整页列出（只给 --page/--page-name 不给组）会一次性返回该页所有组×槽位，
        // 与单组路径不同，它并不支持 --page-size/--page-num 分页。此前分页参数会被静默忽略，
        // 误导调用方以为拿到的是分页结果。这里改为显式报错（而非静默忽略），因为跨多个组的
        // 分页语义本身不明确；需要分页时应指定单个组。
        if args.flag("page-size") != nil || args.flag("page-num") != nil {
            fail("--page-size/--page-num are not supported for whole-page listing "
                    + "(--page/--page-name without a group); specify --group/--group-name to page a single group",
                 code: "INVALID_ARGUMENT_COMBINATION")
        }
        let pageName = index.pages.first(where: { $0.id == pageId })?.name
        let groupsInPage = index.specialSlots
            .filter { $0.pageId == pageId }
            // P2-5 (v2.10.5): 补 .id 次级键，order 相同时输出顺序稳定（与 GUI / Kit 一致）。
            .sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
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
            fail("--page-size must be a positive integer (got '\(psRaw)')", code: "INVALID_LIMIT")
        }
        // P2-6 (v2.10.5): --page-num 与 --page-size 一样做显式数值校验。此前用
        // `Int(...) ?? 1`，非数字（如 --page-num abc）会被静默当成 1，与 --page-size
        // 的报错行为不一致，掩盖了调用方的参数错误。
        let pageNumRaw = args.flag("page-num") ?? "1"
        guard let pageNum = Int(pageNumRaw), pageNum >= 1 else {
            fail("--page-num must be a positive integer (got '\(pageNumRaw)')", code: "INVALID_LIMIT")
        }
        let total = slots.count
        // P0-3: compute totalPages without overflow (avoid `total + pageSize - 1`).
        let totalPages = total == 0 ? 1 : (total - 1) / pageSize + 1
        // P0-3: guard against integer overflow on huge page numbers.
        let (start, overflowed) = (pageNum - 1).multipliedReportingOverflow(by: pageSize)
        let pageSlots: [[String: Any]]
        if overflowed || start >= total {
            // out of range → return an empty page instead of crashing
            pageSlots = []
        } else {
            // start < total here, so this end computation cannot overflow.
            let end = (total - start) <= pageSize ? total : start + pageSize
            pageSlots = Array(slots[start..<end])
        }
        success([
            "group": group,
            "page": page,
            "slots": pageSlots,
            "pagination": [
                "pageNum": pageNum,
                "pageSize": pageSize,
                "total": total,
                "totalPages": totalPages,
                "hasMore": !overflowed && pageNum < totalPages
            ]
        ])
    }

    success(["group": group, "page": page, "slots": slots])
}

func cmdRead(_ args: ParsedArgs) -> Never {
    // v2.9.32 (A1): resolve the page first, then scope group matching to it.
    let requestedPage = resolvePageFlag(args)
    let group = resolveGroup(args, inPage: requestedPage)
    let n = parseSlot(args.positionals.first ?? args.flag("slot"))
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

// v2.9.58 (P0-2): strict, throwing group resolution for the BATCH path. Mirrors the
// single-write resolveGroup (F1) semantics so batch and single write behave identically:
//   • unknown group name/id                    → GROUP_NOT_FOUND
//   • same name on multiple pages (no page ctx) → AMBIGUOUS_GROUP (with candidates)
// It replaces resolveGroupLiteral in the batch path, which silently passed an unknown
// literal through when no page was constrained — writing to a phantom/wrong group.
enum GroupResolveFailure: Error {
    case notFound(raw: String, pageLabel: String?)
    case ambiguous(name: String, candidates: [[String: Any]])
}

func resolveGroupLiteralStrict(_ raw: String, inPage pageId: String?) throws -> String {
    let index = storage.loadIndex()
    let scope = pageId.map { pid in index.specialSlots.filter { $0.pageId == pid } }
                      ?? index.specialSlots
    // id match first (backward compatible with bare `default` etc.)
    if scope.contains(where: { $0.id == raw }) { return raw }
    // name match with ambiguity detection (F1)
    let nameMatches = scope.filter { $0.name == raw }
    if nameMatches.count > 1 {
        let pageNames = Dictionary(uniqueKeysWithValues: index.pages.map { ($0.id, $0.name) })
        let candidates: [[String: Any]] = nameMatches.map { g in
            ["group": g.id, "page": g.pageId, "pageName": jsonValue(pageNames[g.pageId])]
        }
        throw GroupResolveFailure.ambiguous(name: raw, candidates: candidates)
    }
    if let g = nameMatches.first { return g.id }
    // CLI-2 (v2.10.15): mirror resolveGroup — an explicit "default" literal resolves to
    // the DEFAULT_GROUP even before that group has been materialised in the index, so
    // batch items with group:"default" behave like the omitted-group fallback rather
    // than failing GROUP_NOT_FOUND.
    if raw == DEFAULT_GROUP { return raw }
    let pageLabel: String? = pageId.map { pid in
        index.pages.first(where: { $0.id == pid })?.name ?? pid
    }
    throw GroupResolveFailure.notFound(raw: raw, pageLabel: pageLabel)
}

// F3 (契约2): thrown when --if-empty is set but the target slot is not empty.
struct SlotNotEmpty: Error {}

// P2 (v2.10.13): 统一 --label 归一化，供 `write`(performTextWrite) 与 `write-attachment`
// 复用。此前两处口径不一致：performTextWrite 用 `label.isEmpty`（不去空白），write-attachment
// 用 `trimmingCharacters(...).isEmpty`（去空白后判空），导致「仅空白的 label」在两命令下结果
// 不同。统一规则：去首尾空白后为空 → nil（清除 label）；否则保留原始 label 值（verbatim，
// 不改动其内部空白）。
func normalizeLabelArg(_ label: String?) -> String? {
    guard let label else { return nil }
    return label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : label
}

// v2.9.16 (#5): shared text-write core used by both `write` and `write --batch`.
// Returns a short preview of the written text; throws StorageLockError on lock
// contention or WriteFailure with a diagnosed reason on IO failure.
// F3 (契约2): supports `ifEmpty` (reject non-empty slots, atomically re-checked
// INSIDE the lock) and `overwriteText`/label three-state semantics.
func performTextWrite(slot n: Int, text: String, group: String, label: String?,
                      ifEmpty: Bool, overwriteText: Bool) throws -> String {
    // Mirror the GUI's updateTextSlot: build a public.utf8-plain-text item and
    // PRESERVE any existing attachments on the slot (v2.8.7 fix). Read-modify-write
    // runs as ONE cross-process critical section (v2.9.4 #4). The emptiness check
    // (契约2 原子性要求) happens in the SAME critical section as the write.
    let wrote = try StorageLock.shared.withLock { () -> Bool in
        let existing = storage.get(n, in: group)
        let existingLabel = storage.getLabel(n, in: group) ?? existing.label
        // v2.9.58 (P0-1): --if-empty emptiness口径统一为「主体为空 AND 附件列表为空」，
        // 与 list/read 返回的 `empty` 字段（SlotContent.isEmpty）完全对齐。label 不再纳入
        // 冲突判定——此前把 label 计入会导致 empty:true 的槽被 --if-empty 拒绝写入，自相矛盾。
        if ifEmpty {
            if !existing.isEmpty { throw SlotNotEmpty() }
        }
        let data = text.data(using: .utf8) ?? Data()
        let item = PasteboardItem(type: "public.utf8-plain-text", data: data)
        var content = SlotContent()
        content.items = [[item]]
        content.timestamp = Date()
        content.attachments = existing.attachments   // preserve attachments
        let ok = storage.set(n, content: content, in: group)
        if ok {
            if let label {
                // explicit --label provided → set it (empty/whitespace clears).
                // P2 (v2.10.13): 走统一归一化，与 write-attachment 口径一致。
                storage.setLabel(n, label: normalizeLabelArg(label), in: group)
            } else if overwriteText {
                // --overwrite-text without --label → keep existing label.
                storage.setLabel(n, label: existingLabel, in: group)
            }
            // plain write without --label: legacy behavior (do not touch label).
        }
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
    // v2.9.57: accept slot from a positional OR a --slot flag (agent convenience).
    let n = parseSlot(args.positionals.first ?? args.flag("slot"))
    guard var text = args.flag("text") else {
        fail("missing --text <string> (use --text - to read from stdin, or --batch for bulk)", code: "INVALID_ARGUMENT_COMBINATION")
    }
    if text == "-" {
        // CLI-2 (v2.10.32): single-write stdin previously used readDataToEndOfFile() with NO cap
        // (then an O(n) data.contains(0) scan over the whole buffer), so `head -c 2G /dev/zero |
        // clipslots write 1 --text -` buffered the entire input into memory → OOM. Batch write
        // already guards with readStdinCapped(); reuse it here so both stdin entry points share
        // the same bound and abort during read once the cap is exceeded.
        guard let data = readStdinCapped(limit: MAX_BATCH_STDIN_BYTES) else {
            fail("stdin exceeds the \(MAX_BATCH_STDIN_BYTES / (1024 * 1024))MiB text limit; aborted before buffering", code: "INVALID_INPUT_FORMAT")
        }
        // v2.9.3 (Fix #5): reject non-UTF8 / binary stdin instead of silently
        // decoding to "" and CLEARING the slot. `write` only accepts text.
        guard let decoded = String(data: data, encoding: .utf8), !data.contains(0) else {
            fail("stdin is not valid UTF-8 text; write only accepts text (got \(data.count) bytes of binary)", code: "INVALID_INPUT_FORMAT")
        }
        text = decoded
    }

    // F3 (契约2): opt-in safety/overwrite semantics. Bare `write` (neither flag)
    // keeps the v2.9.56 legacy overwrite behavior.
    let ifEmpty = args.hasFlag("if-empty")
    let overwriteText = args.hasFlag("overwrite-text")
    let label = args.flag("label")

    do {
        // v2.9.16 (#5): return `preview` so the agent needn't re-read to confirm.
        let preview = try performTextWrite(slot: n, text: text, group: group, label: label,
                                           ifEmpty: ifEmpty, overwriteText: overwriteText)
        success(["slot": n, "group": group, "preview": preview])
    } catch is SlotNotEmpty {
        // F3 (契约2): --if-empty target was not empty.
        fail("slot \(n) in group \(group) is not empty (use --overwrite-text to replace)", code: "SLOT_NOT_EMPTY")
    } catch let e as StorageLockError {
        // v2.9.16 (#4): lock contention — accurate, retryable message.
        fail(e.errorDescription ?? "storage is busy (lock timeout)", code: "LOCK_TIMEOUT")
    } catch let e as WriteFailure {
        // P2-10 (v2.10.7): 与泛化分支 failWriteError 的 WRITE_FAILED 对齐，不再返回默认 ERROR。
        fail(e.message, code: "WRITE_FAILED")
    } catch {
        // v2.9.16 (#4): genuine IO/permission error, NOT a lock conflict.
        failWriteError(error, context: "writing slot \(n) in group \(group)")
    }
}

// v2.9.57 (F4/F5/F6/F8): batch write with a full preflight + execution state
// machine (契约1). Reads a JSON array from stdin, each element an object
// {"slot":Int(required), "text":String?, "label":String?, "if_empty":Bool?,
// "overwrite_text":Bool?}. `page`/`group` are command-level (shared by all items).
//
// Two failure classes (契约1):
//   • Type A — preflight (static): invalid args, bad slot, duplicate targets,
//     static conflicts (--if-empty target not empty). ZERO writes, disk unchanged.
//   • Type B — execution (runtime): lock timeout / write failure while writing.
//     Earlier items may have been written; --stop-on-error stops the rest.
// UP-3 (v2.10.30): read stdin incrementally and abort as soon as the cumulative
// size exceeds `limit`, so an oversized payload can never be buffered whole into
// memory. Returns nil when the cap is exceeded; the caller reports an error and
// exits WITHOUT writing anything.
func readStdinCapped(limit: Int) -> Data? {
    let handle = FileHandle.standardInput
    var data = Data()
    while true {
        let chunk = handle.readData(ofLength: 1024 * 1024) // 1 MiB per read
        if chunk.isEmpty { break }                          // EOF
        data.append(chunk)
        if data.count > limit { return nil }                // cap exceeded → stop early
    }
    return data
}

func cmdWriteBatch(_ args: ParsedArgs) -> Never {
    // UP-3 (v2.10.30): enforce a stdin size cap while reading (incremental, no
    // unbounded buffering). Over the cap → error out BEFORE any write happens.
    guard let data = readStdinCapped(limit: MAX_BATCH_STDIN_BYTES) else {
        fail("stdin too large (limit \(MAX_BATCH_STDIN_BYTES) bytes)", code: "INVALID_INPUT_FORMAT")
    }
    guard !data.isEmpty else {
        fail("--batch expects a JSON array on stdin, got empty input "
            + "(e.g. echo '[{\"slot\":1,\"text\":\"a\"}]' | clipslots write --batch)", code: "INVALID_INPUT_FORMAT")
    }
    let json: Any
    do {
        json = try JSONSerialization.jsonObject(with: data)
    } catch {
        fail("--batch stdin is not valid JSON: \(error.localizedDescription)", code: "INVALID_INPUT_FORMAT")
    }
    guard let arr = json as? [[String: Any]] else {
        fail("--batch expects a JSON ARRAY of objects, e.g. [{\"slot\":1,\"text\":\"...\"}]", code: "INVALID_INPUT_FORMAT")
    }
    guard !arr.isEmpty else { fail("--batch array is empty; nothing to write", code: "INVALID_INPUT_FORMAT") }

    // Command-level scope + defaults. v2.9.40 (P0): resolve the page ONCE and scope
    // every group lookup to it. resolveGroup enforces F1/F2/F9 for the command.
    let requestedPage = resolvePageFlag(args)
    let commandGroup = resolveGroup(args, inPage: requestedPage)
    let defaultLabel = args.flag("label")
    let cmdIfEmpty = args.hasFlag("if-empty")
    let cmdOverwrite = args.hasFlag("overwrite-text")
    let stopOnError = args.hasFlag("stop-on-error")
    let total = arr.count

    // Parsed, validated representation of one batch item.
    struct BatchItem {
        let index: Int
        let slot: Int
        let text: String
        let group: String
        let label: String?
        let ifEmpty: Bool
        let overwriteText: Bool
    }

    // Best-effort slot number for display in results (before full validation).
    func rawSlot(_ entry: [String: Any]) -> Int? {
        if let s = entry["slot"] as? Int { return s }
        if let s = entry["slot"] as? NSNumber { return s.intValue }
        if let s = entry["slot"] as? String { return Int(s) }
        return nil
    }

    // Emit a type-A (preflight) failure: zero writes, all counters 0, exit 1.
    func emitPreflightFailure(offending: Set<Int>, code: String, message: String,
                              extra: [String: Any] = [:],
                              details: [Int: [String: Any]] = [:]) -> Never {
        var results: [[String: Any]] = []
        for i in 0..<total {
            var r: [String: Any] = ["index": i]
            if let s = rawSlot(arr[i]) { r["slot"] = s }
            // CLI-4 (v2.10.15): include `group` so preflight per-item output is
            // structurally consistent with the execution-phase items (which always carry
            // `group`), giving agents an even field set across both phases. Best-effort:
            // the item's own `group` override if present, else the command-level group.
            r["group"] = (arr[i]["group"] as? String) ?? commandGroup
            if offending.contains(i) {
                r["ok"] = false
                r["status"] = "failed"
                r["error_code"] = code
                if let d = details[i] { for (k, v) in d { r[k] = v } }
            } else {
                r["ok"] = false
                r["status"] = "not_executed"
            }
            results.append(r)
        }
        var d: [String: Any] = [
            "ok": false, "batch": true, "preflight_passed": false,
            "error_code": code, "error": message,
            "total": total, "written": 0, "failed": 0, "skipped": 0, "not_executed": 0,
            "results": results
        ]
        for (k, v) in extra { d[k] = v }
        d["repaired"] = storage.didRepairDefaults
        if storage.didRepairDefaults { d["repair_actions"] = storage.lastRepairActions }
        emit(d)
        exit(1)
    }

    // ---- PREFLIGHT phase 1: per-item static validation + parse ----
    var parsed: [BatchItem] = []
    for (idx, entry) in arr.enumerated() {
        guard let n = rawSlot(entry) else {
            // P2-20 (v2.10.9): unify with parseSlot's single-slot path → INVALID_SLOT.
            emitPreflightFailure(offending: [idx], code: "INVALID_SLOT",
                                 message: "item \(idx): missing or invalid 'slot'")
        }
        guard (1...slotCount).contains(n) else {
            // P2-20 (v2.10.9): unify with parseSlot's single-slot path → INVALID_SLOT.
            emitPreflightFailure(offending: [idx], code: "INVALID_SLOT",
                                 message: "item \(idx): slot out of range (valid 1...\(slotCount))")
        }
        guard let text = entry["text"] as? String else {
            emitPreflightFailure(offending: [idx], code: "INVALID_ARGUMENT_COMBINATION",
                                 message: "item \(idx): missing or invalid 'text' (must be a string)")
        }
        // Per-item if_empty / overwrite_text override command-level (契约1 附).
        let itemIfEmpty = (entry["if_empty"] as? Bool) ?? cmdIfEmpty
        let itemOverwrite = (entry["overwrite_text"] as? Bool) ?? cmdOverwrite
        if itemIfEmpty && itemOverwrite {
            emitPreflightFailure(offending: [idx], code: "INVALID_ARGUMENT_COMBINATION",
                                 message: "item \(idx): if_empty and overwrite_text are mutually exclusive")
        }
        // v2.9.58 (P0-2): per-item group resolution now uses the same F1 logic as the
        // single-write path. Unknown group → GROUP_NOT_FOUND; cross-page same name →
        // AMBIGUOUS_GROUP. Any failure fails the WHOLE batch at preflight (zero writes,
        // preflight_passed:false), matching single-write behaviour instead of silently
        // writing to a phantom/wrong group.
        let group: String
        // D-5 (v2.10.31): batch item 'group' 字段的多类型解析。此前用 `entry["group"] as? String`
        // 只接受字符串，若调用方把 group 传成 JSON 数字（或其它非字符串类型）会被静默当作「未提供
        // group」回落到 commandGroup，从而写到非预期的组。这里与上方 rawSlot 的多类型解析风格保持
        // 一致：String / 数字均转成字符串；仅当 'group' 键存在但类型无法转成字符串（如 null / 数组 /
        // 对象）时明确抛错（preflight 失败，返回 ok:false + 可读 error），绝不静默忽略。
        // 注意区分「未提供 group 键」(走 else 回落 commandGroup) 与「提供了但类型非法」(明确报错)。
        if let rawGroupValue = entry["group"] {
            let rawGroup: String
            if let s = rawGroupValue as? String {
                rawGroup = s
            } else if let n = rawGroupValue as? NSNumber {
                rawGroup = n.stringValue
            } else {
                emitPreflightFailure(offending: [idx], code: "INVALID_ARGUMENT_COMBINATION",
                                     message: "item \(idx): invalid 'group' (must be a string or number)")
            }
            do {
                group = try resolveGroupLiteralStrict(rawGroup, inPage: requestedPage)
            } catch let GroupResolveFailure.ambiguous(name, candidates) {
                emitPreflightFailure(offending: [idx], code: "AMBIGUOUS_GROUP",
                                     message: "item \(idx): group name '\(name)' is ambiguous across \(candidates.count) groups; pass 'page'/'page_name' or a group id to disambiguate",
                                     details: [idx: ["candidates": candidates]])
            } catch let GroupResolveFailure.notFound(name, pageLabel) {
                let msg = pageLabel.map { "item \(idx): group '\(name)' not found in page '\($0)'" }
                    ?? "item \(idx): group '\(name)' not found"
                emitPreflightFailure(offending: [idx], code: "GROUP_NOT_FOUND", message: msg)
            } catch {
                // P2-14 (v2.10.7): 该兜底仅在 group 解析异常时触发，语义等同组解析失败，
                // 统一为 GROUP_NOT_FOUND，避免返回旧的通用 ERROR。
                emitPreflightFailure(offending: [idx], code: "GROUP_NOT_FOUND",
                                     message: "item \(idx): failed to resolve group: \(error)")
            }
        } else {
            group = commandGroup
        }
        let label = (entry["label"] as? String) ?? defaultLabel
        parsed.append(BatchItem(index: idx, slot: n, text: text, group: group,
                                label: label, ifEmpty: itemIfEmpty, overwriteText: itemOverwrite))
    }

    // ---- PREFLIGHT phase 2: duplicate (group, slot) targets ----
    var seen: [String: Int] = [:]
    var duplicateIdx: Set<Int> = []
    for item in parsed {
        let key = "\(item.group)#\(item.slot)"
        if let first = seen[key] {
            duplicateIdx.insert(first)
            duplicateIdx.insert(item.index)
        } else {
            seen[key] = item.index
        }
    }
    if !duplicateIdx.isEmpty {
        emitPreflightFailure(offending: duplicateIdx, code: "BATCH_DUPLICATE_TARGET",
                             message: "duplicate target slot(s) resolved to the same (group, slot); the whole batch is rejected",
                             extra: ["duplicates": duplicateIdx.sorted()])
    }

    // ---- PREFLIGHT phase 3: static conflict for if_empty items ----
    // v2.9.58 (P0-1): emptiness口径统一为「主体为空 AND 附件列表为空」(SlotContent.isEmpty)，
    // 与 list/read 的 `empty` 字段完全对齐；label 不再纳入 --if-empty 冲突判定。
    var conflictIdx: Set<Int> = []
    for item in parsed where item.ifEmpty {
        let existing = storage.get(item.slot, in: item.group)
        if !existing.isEmpty { conflictIdx.insert(item.index) }
    }
    if !conflictIdx.isEmpty {
        emitPreflightFailure(offending: conflictIdx, code: "SLOT_NOT_EMPTY",
                             message: "one or more --if-empty target slots are not empty; the whole batch is rejected")
    }

    // ---- EXECUTION phase (type B): preflight passed ----
    var results: [[String: Any]] = []
    var written = 0
    var failed = 0
    var notExecuted = 0
    var stopped = false
    // UP-3 (v2.10.30): hold ONE storage lock across the ENTIRE execution loop so the
    // whole batch is atomic w.r.t. other processes — no per-item lock/unlock and no
    // interleaving. `StorageLock.withLock` is reentrant (depth-counted flock), so the
    // inner `withLock` inside `performTextWrite` reuses this same OS lock instead of
    // re-acquiring it. Preflight semantics are unchanged (pre-check failure → zero
    // writes above); within this loop earlier items succeed and later ones may fail /
    // be not_executed exactly as before. Failure to acquire the outer lock is itself an
    // execution-phase failure with zero writes → every item is not_executed + LOCK_TIMEOUT.
    do {
        try StorageLock.shared.withLock { () -> Void in
            for item in parsed {
                if stopped {
                    // v2.10.66: include `group` for parity with the written / failed result
                    // shapes below (all other batch result entries carry it). Consumers that
                    // key off `group` no longer see it missing on not_executed items.
                    results.append(["index": item.index, "slot": item.slot, "group": item.group, "ok": false, "status": "not_executed"])
                    notExecuted += 1
                    continue
                }
                do {
                    let preview = try performTextWrite(slot: item.slot, text: item.text, group: item.group,
                                                       label: item.label, ifEmpty: item.ifEmpty,
                                                       overwriteText: item.overwriteText)
                    results.append(["index": item.index, "slot": item.slot, "group": item.group,
                                    "ok": true, "status": "written", "preview": preview])
                    written += 1
                } catch is SlotNotEmpty {
                    // Atomic re-check (契约2) failed at execution time (concurrent modification).
                    results.append(["index": item.index, "slot": item.slot, "group": item.group,
                                    "ok": false, "status": "failed", "error_code": "SLOT_NOT_EMPTY",
                                    "error": "slot \(item.slot) in group \(item.group) is not empty"])
                    failed += 1
                    if stopOnError { stopped = true }
                } catch let e as StorageLockError {
                    results.append(["index": item.index, "slot": item.slot, "group": item.group,
                                    "ok": false, "status": "failed", "error_code": "LOCK_TIMEOUT",
                                    "error": e.errorDescription ?? "storage is busy (lock timeout)"])
                    failed += 1
                    if stopOnError { stopped = true }
                } catch let e as WriteFailure {
                    results.append(["index": item.index, "slot": item.slot, "group": item.group,
                                    "ok": false, "status": "failed", "error_code": "WRITE_FAILED",
                                    "error": e.message])
                    failed += 1
                    if stopOnError { stopped = true }
                } catch {
                    // P2-2 (v2.10.5): surface refusingToOverwriteWithEmptyIndex as INDEX_WRITE_REFUSED
                    // here too, instead of the generic WRITE_FAILED, so batch callers get the same
                    // specific code as the single-write path.
                    let (code, message) = writeErrorCodeAndMessage(error, context: "writing slot \(item.slot)")
                    results.append(["index": item.index, "slot": item.slot, "group": item.group,
                                    "ok": false, "status": "failed",
                                    "error_code": code == "ERROR" ? "WRITE_FAILED" : code,
                                    "error": message])
                    failed += 1
                    if stopOnError { stopped = true }
                }
            }
        }
    } catch {
        // UP-3 (v2.10.30): could not acquire the batch-wide lock (e.g. StorageLockError
        // timeout). Nothing was written — report every item as not_executed and surface
        // LOCK_TIMEOUT so callers can retry the whole batch.
        let lockMsg = (error as? StorageLockError)?.errorDescription ?? "storage is busy (lock timeout)"
        var lockResults: [[String: Any]] = []
        for item in parsed {
            lockResults.append(["index": item.index, "slot": item.slot, "group": item.group,
                                "ok": false, "status": "not_executed"])
        }
        var d: [String: Any] = [
            "ok": false, "batch": true, "preflight_passed": true,
            "error_code": "LOCK_TIMEOUT", "error": lockMsg,
            "total": total, "written": 0, "failed": 0, "skipped": 0,
            "not_executed": total, "results": lockResults
        ]
        d["repaired"] = storage.didRepairDefaults
        if storage.didRepairDefaults { d["repair_actions"] = storage.lastRepairActions }
        emit(d)
        exit(1)
    }

    // Counters & top-level ok (契约1 附). skipped is always 0 in v2.9.57.
    let ok = failed == 0 && notExecuted == 0
    var out: [String: Any] = [
        "ok": ok, "batch": true, "preflight_passed": true,
        "total": total, "written": written, "failed": failed,
        "skipped": 0, "not_executed": notExecuted, "results": results
    ]
    if failed > 0 { out["error_code"] = "BATCH_PARTIAL_FAILURE" }
    out["repaired"] = storage.didRepairDefaults
    if storage.didRepairDefaults { out["repair_actions"] = storage.lastRepairActions }
    emit(out)
    exit(ok ? 0 : 1)
}

func cmdSearch(_ args: ParsedArgs) -> Never {
    guard let query = args.positionals.first, !query.isEmpty else {
        fail("missing search query", code: "INVALID_ARGUMENT_COMBINATION")
    }
    let needle = query.lowercased()
    // P2-23 (v2.10.9): explicitly validate --limit (must be a positive Int) instead of
    // silently defaulting to 50 on garbage input; emit a structured INVALID_LIMIT.
    let limit: Int
    if let limRaw = args.flag("limit") {
        guard let n = Int(limRaw), n > 0 else {
            fail("--limit must be a positive integer (got '\(limRaw)')", code: "INVALID_LIMIT")
        }
        limit = n
    } else {
        limit = 50
    }
    let index = storage.loadIndex()
    let pageNames = Dictionary(uniqueKeysWithValues: index.pages.map { ($0.id, $0.name) })

    // v2.9.58 (P1): search now supports --page/--page-name and uses the same
    // page-scoped group resolution as list/read/write, so `search --group <UUID>`
    // (and cross-page same-named groups) filter correctly.
    let requestedPage = resolvePageFlag(args)
    let hasGroupFlag = args.flag("group") != nil || args.flag("group-name") != nil

    let targetGroups: [SpecialSlot]
    if args.hasFlag("all-groups") {
        targetGroups = index.specialSlots
    } else if let pid = requestedPage, !hasGroupFlag {
        // Page given but no group flag → search every group on that page (parity with
        // `list --page`), instead of falling back to the global default group.
        targetGroups = index.specialSlots.filter { $0.pageId == pid }
    } else {
        let group = resolveGroup(args, inPage: requestedPage)
        if let g = index.specialSlots.first(where: { $0.id == group }) {
            targetGroups = [g]
        } else {
            // Group not present in index but may still have on-disk data.
            targetGroups = [SpecialSlot(id: group, name: group, sourceType: .manual,
                                        pageId: requestedPage ?? DEFAULT_PAGE, createdAt: Date(), updatedAt: Date())]
        }
    }

    // P2-8 (v2.10.8): sort by (page.order, group.order, slot) with id as a stable
    // secondary key, matching list / groups / pages ordering (UI tab order) instead
    // of raw page-id/group-id string order.
    let pageOrderMap = Dictionary(uniqueKeysWithValues: index.pages.map { ($0.id, $0.order) })
    let groupOrderMap = Dictionary(uniqueKeysWithValues: index.specialSlots.map { ($0.id, $0.order) })

    // P2 (v2.10.13): 先按显示顺序（page.order → group.order → id）排序 targetGroups，再遍历
    // 截断。此前按 index.specialSlots 的数组序遍历、命中 --limit 即 break，之后才对已截断的
    // 子集排序；当匹配数超过 limit 且用户在 GUI 拖动重排过组/页（数组序 ≠ order 序）时，
    // 显示顺序靠前的匹配反而被丢弃，返回错误子集。改为在截断前就以显示序遍历。
    let orderedTargetGroups = targetGroups.sorted { a, b in
        let poa = pageOrderMap[a.pageId] ?? Int.max, pob = pageOrderMap[b.pageId] ?? Int.max
        if poa != pob { return poa < pob }
        if a.pageId != b.pageId { return a.pageId < b.pageId }
        let goa = groupOrderMap[a.id] ?? Int.max, gob = groupOrderMap[b.id] ?? Int.max
        if goa != gob { return goa < gob }
        return a.id < b.id
    }

    var results: [[String: Any]] = []
    outer: for g in orderedTargetGroups {
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
    // P2-8 (v2.10.8): sort by (page.order, group.order, slot) with id as a stable
    // secondary key, matching list / groups / pages ordering (UI tab order) instead
    // of raw page-id/group-id string order. (pageOrderMap/groupOrderMap 已在遍历前构建。)
    results.sort { a, b in
        let pa = (a["page"] as? String) ?? "", pb = (b["page"] as? String) ?? ""
        let poa = pageOrderMap[pa] ?? Int.max, pob = pageOrderMap[pb] ?? Int.max
        if poa != pob { return poa < pob }
        if pa != pb { return pa < pb }
        let ga = (a["group"] as? String) ?? "", gb = (b["group"] as? String) ?? ""
        let goa = groupOrderMap[ga] ?? Int.max, gob = groupOrderMap[gb] ?? Int.max
        if goa != gob { return goa < gob }
        if ga != gb { return ga < gb }
        let sa = (a["slot"] as? Int) ?? 0, sb = (b["slot"] as? Int) ?? 0
        return sa < sb
    }
    success(["query": query, "results": results])
}

func cmdPaste(_ args: ParsedArgs) -> Never {
    let group = resolveGroup(args, inPage: resolvePageFlag(args)) // v2.9.32 (A1): page-scoped
    let n = parseSlot(args.positionals.first ?? args.flag("slot"))
    let content = storage.get(n, in: group)
    guard !content.isEmpty else {
        fail("slot \(n) in group \(group) is empty; nothing to copy", code: "SLOT_EMPTY")
    }

    // v2.9.3 (Fix #2): if the slot has body items, restore them to the pasteboard as
    // before. Otherwise it is an attachment-only slot — restore() would fail because
    // it only writes items — so place the attachment file URLs on the clipboard
    // directly (mirroring the GUI's SlotAttachment.path resolution in
    // slotContentPayloads / payloadForAttachment).
    if !content.items.isEmpty {
        let ok = ClipboardManager.shared.restore(content)
        guard ok else { fail("failed to load slot \(n) onto the clipboard", code: "PASTE_FAILED") } // P2-16 (v2.10.7)
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
            fail("slot \(n) in group \(group) has \(content.attachments.count) attachment(s) but none resolve to an existing file path", code: "PASTE_FAILED") // P2-16 (v2.10.7)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.writeObjects(urls)
        guard ok else { fail("failed to write attachment file URLs to the clipboard", code: "PASTE_FAILED") } // P2-16 (v2.10.7)
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
        fail("missing group name (usage: create-group <name> [--page <id>])", code: "INVALID_ARGUMENT_COMBINATION")
    }
    let page = resolvePageFlag(args, strict: true)
    // CLI-5 (v2.10.15): removed the CLI-layer per-page group-count preflight. It read the
    // count OUTSIDE the Kit storage lock, so it had a TOCTOU race with concurrent
    // create-group processes and could emit a misleading PAGE_GROUP_LIMIT_REACHED
    // preflight error. The authoritative capacity guarantee lives in
    // SpecialSlotStorage.createSpecialSlot, which re-checks the limit INSIDE its own
    // storageLock.withLock and throws .maxSpecialSlotsReached — caught below and mapped
    // to PAGE_GROUP_LIMIT_REACHED via codeForSpecialSlotError. Relying solely on the Kit
    // closes the race.
    do {
        let slot = try storage.createSpecialSlot(name: name, pageId: page, requestedAt: CLI_REQUEST_RECEIVED_AT)
        success(["group": ["id": slot.id, "name": slot.name, "pageId": slot.pageId]])
    } catch SpecialSlotError.duplicateName {
        // v2.9.4 (Feature #4): same-page duplicate name is rejected. Agents should
        // rename or add a `-2` suffix on conflict (see skill doc).
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        fail("a group named '\(trimmed)' already exists on this page", code: "DUPLICATE_NAME")
    } catch let e as StorageLockError {
        // v2.9.4 (#4): cross-process lock contention timeout.
        fail(e.errorDescription ?? "storage is busy (lock timeout)", code: "LOCK_TIMEOUT")
    } catch let e as SpecialSlotError {
        // P2-14: map to a specific code (e.g. maxSpecialSlotsReached → PAGE_GROUP_LIMIT_REACHED).
        fail(e.errorDescription ?? "failed to create group", code: codeForSpecialSlotError(e))
    } catch {
        failWriteError(error, context: "creating group")
    }
}

func cmdCreatePage(_ args: ParsedArgs) -> Never {
    guard let name = args.positionals.first, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
        fail("missing page name (usage: create-page <name>)", code: "INVALID_ARGUMENT_COMBINATION")
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
        fail(e.errorDescription ?? "storage is busy (lock timeout)", code: "LOCK_TIMEOUT")
    } catch let e as PageError {
        fail(e.errorDescription ?? "failed to create page", code: codeForPageError(e))
    } catch {
        failWriteError(error, context: "creating page")
    }
}

// v2.9.42 (Feature A): rename an existing slot group by id. Primary use case is
// renaming the auto-created default group after `create-page` so no wasted empty
// group is left behind. Same-page duplicate names are rejected by the Kit layer
// (renameSpecialSlot throws SpecialSlotError.duplicateName), surfaced here with
// the documented message.
func cmdRenameGroup(_ args: ParsedArgs) -> Never {
    guard let id = args.positionals.first, !id.trimmingCharacters(in: .whitespaces).isEmpty else {
        fail("missing group id (usage: rename-group <group-id> --name <新名称> [--page-name <页面名>])", code: "INVALID_ARGUMENT_COMBINATION")
    }
    guard let newName = args.flag("name"), !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fail("missing new name (usage: rename-group <group-id> --name <新名称>)", code: "INVALID_ARGUMENT_COMBINATION")
    }
    let index = storage.loadIndex()
    guard let group = index.specialSlots.first(where: { $0.id == id }) else {
        fail("group \(id) not found", code: "GROUP_NOT_FOUND")
    }
    // --page-name is advisory only: when provided, validate it matches the group's
    // owning page so a caller cannot silently rename a group on the wrong page.
    if let pageName = args.flag("page-name") {
        let ownerPageName = index.pages.first(where: { $0.id == group.pageId })?.name
        if ownerPageName != pageName {
            // P2-15 (v2.10.7): 与 resolveGroup 同类场景对齐，归属校验失败返回 GROUP_NOT_FOUND。
            fail("group '\(id)' is not on page '\(pageName)'", code: "GROUP_NOT_FOUND")
        }
    }
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
        try storage.renameSpecialSlot(id: id, name: trimmed)
        // P2 (v2.10.13): 回显存储层写回后的真实组名（read-back），不在 CLI 侧二次 prefix(30)
        // 截断。renameSpecialSlot 成功后组必然存在，read-back 一定命中；兜底也用未截断的
        // trimmed（而非 prefix(30)），确保返回值不再出现 CLI 侧的二次截断口径。
        let finalName = storage.loadIndex().specialSlots.first(where: { $0.id == id })?.name ?? trimmed
        success(["group": ["id": id, "name": finalName]])
    } catch SpecialSlotError.duplicateName {
        fail("a group named '\(String(trimmed.prefix(30)))' already exists on this page", code: "DUPLICATE_NAME")
    } catch SpecialSlotError.specialSlotNotFound {
        fail("group \(id) not found", code: "GROUP_NOT_FOUND")
    } catch SpecialSlotError.invalidSpecialSlotName {
        fail("invalid group name", code: "INVALID_INPUT_FORMAT")
    } catch let e as StorageLockError {
        fail(e.errorDescription ?? "storage is busy (lock timeout)", code: "LOCK_TIMEOUT")
    } catch let e as SpecialSlotError {
        fail(e.errorDescription ?? "failed to rename group", code: codeForSpecialSlotError(e))
    } catch {
        failWriteError(error, context: "renaming group \(id)")
    }
}

func cmdWriteAttachment(_ args: ParsedArgs) -> Never {
    let group = resolveGroup(args, inPage: resolvePageFlag(args)) // v2.9.35: page-scoped (flag parity with write)
    // CLI-3 (v2.10.15): accept `--slot` in addition to the positional <slot>, for flag
    // parity with read/write/paste/clear. When `--slot` is given, EVERY positional is a
    // file path (the slot no longer occupies the first positional); otherwise the first
    // positional is the slot and the rest are files (original behaviour).
    let slotRaw: String
    let fileArgs: [String]
    if let slotFlag = args.flag("slot") {
        slotRaw = slotFlag
        fileArgs = args.positionals
    } else {
        guard let first = args.positionals.first else {
            fail("missing slot number (usage: write-attachment <slot> <file> [file ...] [--group <id>] [--page <id>] [--replace])", code: "INVALID_ARGUMENT_COMBINATION")
        }
        slotRaw = first
        fileArgs = Array(args.positionals.dropFirst())
    }
    let n = parseSlot(slotRaw)
    guard !fileArgs.isEmpty else {
        fail("no files given (usage: write-attachment <slot> <file> [file ...])", code: "INVALID_ARGUMENT_COMBINATION")
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
        // v2.9.58 (P2): return a specific FILE_NOT_FOUND code (was the generic ERROR)
        // when the attachment file is missing or is a directory, so agents can branch.
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            fail("file not found: \(url.path)", code: "FILE_NOT_FOUND")
        }
        guard !isDir.boolValue else {
            fail("path is a directory, not a file: \(url.path)", code: "FILE_NOT_FOUND")
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
                // P2-22 (v2.10.9): an explicitly empty/whitespace-only --label "" means
                // NO label (nil), not an empty-string label. Non-empty labels pass
                // through unchanged (preserved verbatim).
                // P2 (v2.10.13): 复用统一归一化函数，与 write 命令口径一致。
                storage.setLabel(n, label: normalizeLabelArg(label), in: group)
            }
            return (wrote, content.attachments.count, content.items.isEmpty)
        }
    } catch let e as StorageLockError {
        fail(e.errorDescription ?? "storage is busy (lock timeout)", code: "LOCK_TIMEOUT")
    } catch {
        failWriteError(error, context: "writing attachments to slot \(n) in group \(group)")
    }
    // P2-11 (v2.10.7): 写附件失败的兜底改用具体错误码 WRITE_FAILED，不再返回默认 ERROR。
    guard result.ok else { fail(writeFailureDiagnostic(context: "to write attachments to slot \(n) in group \(group)"), code: "WRITE_FAILED") }

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
    let n = parseSlot(args.positionals.first ?? args.flag("slot"))
    // v2.9.4 (#4): cross-process lock around the clear write.
    var cleared = false
    do {
        try StorageLock.shared.withLock {
            cleared = storage.clear(n, in: group)
        }
    } catch let e as StorageLockError {
        fail(e.errorDescription ?? "storage is busy (lock timeout)", code: "LOCK_TIMEOUT")
    } catch {
        failWriteError(error, context: "clearing slot \(n) in group \(group)")
    }
    // P1-5 (v2.10.34): storage.clear() 命中已删除 / 幽灵组时返回 false（内存与索引都无此组，实际什么
    // 都没清）。此前无视返回值恒回报 "cleared" 成功，属静默误报，会让 AI/脚本误以为已清空。现如实
    // 返回 GROUP_NOT_FOUND 错误（对齐 resolveGroup 的组缺失语义），让调用方能感知清空未生效。
    guard cleared else {
        fail("group '\(group)' not found or already removed; nothing cleared", code: "GROUP_NOT_FOUND")
    }
    success(["slot": n, "group": group, "action": "cleared"])
}

// v2.9.4 (Feature #3): delete a whole slot group. The data layer moves the
// group's directory to `.trash` (recoverable), so this is a soft delete.
func cmdDeleteGroup(_ args: ParsedArgs) -> Never {
    guard let id = args.positionals.first, !id.trimmingCharacters(in: .whitespaces).isEmpty else {
        fail("missing group id (usage: delete-group <id>)", code: "INVALID_ARGUMENT_COMBINATION")
    }
    // F6 (契约5): the default group is protected (CLI-layer guard; Kit layer also
    // rejects it as a defense-in-depth double check).
    if id == DEFAULT_GROUP {
        fail("the default group '\(DEFAULT_GROUP)' is protected and cannot be deleted", code: "DEFAULT_GROUP_PROTECTED")
    }
    // Validate existence first for a clear, agent-friendly error.
    let index = storage.loadIndex()
    guard index.specialSlots.contains(where: { $0.id == id }) else {
        fail("group \(id) not found", code: "GROUP_NOT_FOUND")
    }
    do {
        try storage.deleteSpecialSlot(id: id)
        success(["deleted": id, "movedToTrash": true])
    } catch SpecialSlotError.defaultGroupProtected {
        fail("the default group '\(DEFAULT_GROUP)' is protected and cannot be deleted", code: "DEFAULT_GROUP_PROTECTED")
    } catch let e as StorageLockError {
        fail(e.errorDescription ?? "storage is busy (lock timeout)", code: "LOCK_TIMEOUT")
    } catch let e as SpecialSlotError {
        fail(e.errorDescription ?? "failed to delete group", code: codeForSpecialSlotError(e))
    } catch {
        failWriteError(error, context: "deleting group")
    }
}

// v2.9.4 (Feature #3): delete a whole page (and its slot groups). The data layer
// moves the affected group directories to `.trash` (recoverable).
func cmdDeletePage(_ args: ParsedArgs) -> Never {
    guard let id = args.positionals.first, !id.trimmingCharacters(in: .whitespaces).isEmpty else {
        fail("missing page id (usage: delete-page <id>)", code: "INVALID_ARGUMENT_COMBINATION")
    }
    // F6 (契约5): the default page is protected (CLI-layer guard; Kit layer also
    // rejects it as a defense-in-depth double check).
    if id == DEFAULT_PAGE {
        fail("the default page '\(DEFAULT_PAGE)' is protected and cannot be deleted", code: "DEFAULT_PAGE_PROTECTED")
    }
    let index = storage.loadIndex()
    guard index.pages.contains(where: { $0.id == id }) else {
        fail("page \(id) not found", code: "PAGE_NOT_FOUND")
    }
    do {
        try storage.deletePage(id: id)
        success(["deleted": id, "movedToTrash": true])
    } catch PageError.defaultPageProtected {
        fail("the default page '\(DEFAULT_PAGE)' is protected and cannot be deleted", code: "DEFAULT_PAGE_PROTECTED")
    } catch let e as StorageLockError {
        fail(e.errorDescription ?? "storage is busy (lock timeout)", code: "LOCK_TIMEOUT")
    } catch let e as PageError {
        fail(e.errorDescription ?? "failed to delete page", code: codeForPageError(e))
    } catch {
        failWriteError(error, context: "deleting page")
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

// F9 (契约7 附): validate argument combinations (mutex flags, --limit) after the
// unknown-flag check so error messages are accurate.
validateArgCombinations(parsed)

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
// A-6 (v2.10.31): 索引自愈命令，仿 version 的最简只读接入。
case "repair-index":
    cmdRepairIndex()
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
    fail("unknown command: \(parsed.command) (run 'clipslots help')", code: "UNKNOWN_COMMAND")
}
