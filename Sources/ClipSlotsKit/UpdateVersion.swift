import Foundation

// UPD-LOOP (v2.10.92): 自动更新的「版本语义」与「幂等护栏」纯逻辑层。
//
// 背景 / 为什么要放到 ClipSlotsKit：
//   线上出现过「反复重装同一个版本」的投诉。排查这类问题时最需要的是能被单测直接调用、
//   与 UI / 网络 / UserDefaults 完全解耦的判定函数。此前版本比对逻辑写在 App target 的
//   `UpdateChecker`（@MainActor class）里，而 App 是 executableTarget，测试 target
//   （ClipSlotsKitSmokeTests）只能依赖 ClipSlotsKit，导致**这条最容易出错的逻辑恰恰无法被
//   测试覆盖**。故把它下沉到 Kit，成为零依赖纯函数，由 `UpdateChecker` / `UpdateInstaller`
//   薄封装复用，两处规范化就此收敛到同一实现，避免再次漂移。
//
// 设计要点：
//   1. 规范化：剥掉 `v` / `V` 前缀、去首尾空白、丢弃 `+build` 元数据、单独解析 `-pre` 预发布段；
//   2. 比较：按 `major.minor.patch…` **逐段按整数**比较（绝不做字符串字典序），位数不同补 0；
//   3. 判定：只有「线上严格大于本地」才更新，**相等或更低一律不更新**；
//   4. 幂等护栏：即便比较逻辑将来又出错，也用「目标版本 == 当前运行版本」「同一目标版本不重复
//      安装」两道纯判定把无限重装循环掐断（见 `installGuard`）。
public enum UpdateVersion {

    // MARK: - 解析

    /// 规范化后的语义版本：数字核心 + 可选预发布标识。
    ///
    /// `pre` 为 nil 表示正式版；非 nil 为预发布标识（如 `"beta.1"`）。按 SemVer，
    /// 数字核心相同时正式版 > 预发布版。
    public struct Semantic: Equatable {
        public let core: [Int]
        public let pre: String?

        public init(core: [Int], pre: String?) {
            self.core = core.isEmpty ? [0] : core
            self.pre = pre
        }

        /// 便于日志 / 文案展示的数字核心串（如 `[2, 10, 91]` → `"2.10.91"`）。
        public var coreString: String { core.map(String.init).joined(separator: ".") }

        /// 完整展示串（含预发布段）。
        public var displayString: String { pre.map { "\(coreString)-\($0)" } ?? coreString }
    }

    /// 把任意来源的版本串（GitHub `tag_name`、`CFBundleShortVersionString`）规范化为 `Semantic`。
    ///
    /// 处理顺序：去首尾空白 → 剥 `v`/`V` 前缀 → 丢弃 `+` 之后的构建元数据 → 拆出 `-` 之后的预发布段
    /// → 数字核心按 `.` 分段并**逐段转整数**（非数字段按 0 处理，绝不退化成字符串比较）。
    ///
    /// - Note: `"v2.10.91"`、`" 2.10.91 "`、`"2.10.91+build7"` 规范化后都等于 `"2.10.91"`。
    public static func parse(_ raw: String) -> Semantic {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // 再去一次空白，兼容 "v 2.10.91" 这类脏数据。
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 构建元数据（`+` 之后）不参与比较。
        if let plus = s.firstIndex(of: "+") { s = String(s[s.startIndex..<plus]) }
        var pre: String? = nil
        if let dash = s.firstIndex(of: "-") {
            let p = String(s[s.index(after: dash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            pre = p.isEmpty ? nil : p
            s = String(s[s.startIndex..<dash])
        }
        let core = s.split(separator: ".").map { seg -> Int in
            Int(seg.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        return Semantic(core: core, pre: pre)
    }

    // MARK: - 比较

    /// `a` 是否严格新于 `b`。逐段按整数比较，位数不同的一方补 0；
    /// 数字核心完全相等时按 SemVer 规则处理预发布段（正式版 > 预发布版）。
    ///
    /// 关键契约：**相等返回 false**（相等绝不视为「有更新」）。
    public static func isNewer(_ a: Semantic, than b: Semantic) -> Bool {
        let count = max(a.core.count, b.core.count)
        for i in 0..<count {
            let av = i < a.core.count ? a.core[i] : 0
            let bv = i < b.core.count ? b.core[i] : 0
            if av != bv { return av > bv }
        }
        switch (a.pre, b.pre) {
        case (nil, nil): return false            // 完全相等 → 不更新
        case (nil, .some): return true           // a 正式版、b 预发布 → a 更新
        case (.some, nil): return false          // a 预发布、b 正式版 → 不更新
        case let (.some(ap), .some(bp)):
            return ap.compare(bp, options: .numeric) == .orderedDescending
        }
    }

    /// 两个版本串规范化后是否表示同一个版本（`"v2.10.91"` 与 `"2.10.91"` 视为相同；
    /// `"2.10"` 与 `"2.10.0"` 亦相同）。
    public static func isSameVersion(_ a: String, _ b: String) -> Bool {
        let x = parse(a), y = parse(b)
        return !isNewer(x, than: y) && !isNewer(y, than: x)
    }

    // MARK: - 更新判定

    /// 线上版本相对本地版本的判定结论。
    public enum Decision: String, Equatable {
        /// 线上严格更新 → 可提示 / 下载 / 安装。
        case update
        /// 线上与本地相同 → **不更新**（这是「循环重装同版本」的关键闸门）。
        case upToDate
        /// 线上比本地旧（用户装了更新的本地构建）→ 不更新。
        case remoteOlder
    }

    /// 依据「线上 tag」与「本地运行版本」给出更新判定。
    /// 只有 `.update` 才允许进入下载 / 安装流程。
    public static func decide(remoteTag: String, localVersion: String) -> Decision {
        let remote = parse(remoteTag)
        let local = parse(localVersion)
        if isNewer(remote, than: local) { return .update }
        if isNewer(local, than: remote) { return .remoteOlder }
        return .upToDate
    }

    // MARK: - 幂等护栏

    /// 安装前置护栏的结论。
    public enum InstallGuard: Equatable {
        /// 允许安装。
        case proceed
        /// 目标版本 == 当前运行版本 → 跳过（同版本重装无意义，且是重装循环的直接成因）。
        case skipSameAsRunning
        /// 同一目标版本在本机已尝试安装过 → 跳过（防「装完重启又立刻重装」的死循环）。
        case skipAlreadyAttempted
        /// 用户/运维通过开关显式关掉了自动安装 → 跳过（止血用的总闸）。
        case skipDisabled
    }

    /// 安装前的幂等护栏（纯函数，便于测试）。判定优先级：
    ///   ① 总闸关闭 → `.skipDisabled`；
    ///   ② 目标版本与当前运行版本相同 → `.skipSameAsRunning`；
    ///   ③ 目标版本与「最近一次已尝试安装的版本」相同 → `.skipAlreadyAttempted`；
    ///   ④ 否则 `.proceed`。
    ///
    /// - Parameters:
    ///   - targetTag: 待安装的目标版本（可带 `v` 前缀）。
    ///   - runningVersion: 当前正在运行的版本（`CFBundleShortVersionString`）。
    ///   - lastAttemptedTag: 本机最近一次已尝试安装的目标版本；nil 表示没有记录。
    ///   - autoInstallDisabled: 自动安装总闸是否被关闭。
    public static func installGuard(targetTag: String,
                                    runningVersion: String,
                                    lastAttemptedTag: String?,
                                    autoInstallDisabled: Bool) -> InstallGuard {
        if autoInstallDisabled { return .skipDisabled }
        if isSameVersion(targetTag, runningVersion) { return .skipSameAsRunning }
        if let last = lastAttemptedTag, !last.isEmpty, isSameVersion(targetTag, last) {
            return .skipAlreadyAttempted
        }
        return .proceed
    }
}
