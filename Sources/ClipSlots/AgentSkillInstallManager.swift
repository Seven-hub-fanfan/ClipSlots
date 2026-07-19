import Foundation
import SwiftUI
import AppKit

// v2.9.14: 一键把 ClipSlots Skill 安装到本机已安装的 Agent 环境。
//
// 思路：App bundle 内自带 skill 目录
//   ClipSlots.app/Contents/Resources/skills/clipslots-manager/
// 安装动作 = 在目标 Agent 的 skills 目录下创建一个软链接（symlink）
//   <agent skills dir>/clipslots-manager  ->  <bundled skill dir>
// 这样 App 升级 SKILL.md 时，Agent 侧通过软链接自动同步，无需重复安装。
//
// 家目录一般可写，创建软链无需管理员权限；仅当遇到权限错误时，回退到
// macOS 系统鉴权弹窗（do shell script ... with administrator privileges）。
@MainActor
final class AgentSkillInstallManager: ObservableObject {

    /// skill 目录名（软链接名 & bundle 内目录名）。
    static let skillDirName = "clipslots-manager"

    /// 单个 Agent 环境定义。
    struct Agent: Identifiable, Equatable {
        let id: String
        let displayName: String
        let iconSystemName: String
        /// 该目录存在 => 认为此 Agent 已安装在本机。
        let detectPath: String
        /// skill 应安装到的父目录（软链接放在这里）。
        let skillsDir: String

        /// 软链接最终落点。
        var skillTargetPath: String {
            (skillsDir as NSString).appendingPathComponent(skillDirName)
        }

        static func == (lhs: Agent, rhs: Agent) -> Bool { lhs.id == rhs.id }
    }

    enum InstallState: Equatable {
        case notInstalled                 // 目标不存在
        case installed                    // 已是指向内置 skill 的软链接
        case needsUpdate                  // 目标存在但不是正确软链接（旧目录/指向别处）
    }

    @Published private(set) var detectedAgents: [Agent] = []
    @Published private(set) var states: [String: InstallState] = [:]
    @Published private(set) var busyAgentID: String?
    @Published var lastMessage: String?
    @Published var lastMessageIsError = false

    private let fm = FileManager.default

    // MARK: - Agent 目录清单

    private static func home(_ rel: String) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(rel)
    }

    /// 所有受支持的 Agent 环境（无论是否安装）。
    private let allAgents: [Agent] = [
        Agent(id: "claude",
              displayName: "Claude Code",
              iconSystemName: "sparkle",
              detectPath: home(".claude"),
              skillsDir: home(".claude/skills")),
        Agent(id: "cursor",
              displayName: "Cursor",
              iconSystemName: "cursorarrow.rays",
              detectPath: home(".cursor"),
              skillsDir: home(".cursor/skills")),
        Agent(id: "codex",
              displayName: "Codex",
              iconSystemName: "chevron.left.forwardslash.chevron.right",
              detectPath: home(".codex"),
              skillsDir: home(".codex/skills")),
        Agent(id: "gemini",
              displayName: "Gemini CLI",
              iconSystemName: "diamond",
              detectPath: home(".gemini"),
              skillsDir: home(".gemini/skills")),
    ]

    // MARK: - 内置 skill 源目录

    /// App bundle 内自带的 skill 目录绝对路径。
    var bundledSkillDir: String? {
        let resources = (Bundle.main.bundlePath as NSString)
            .appendingPathComponent("Contents/Resources/skills")
        let candidate = (resources as NSString).appendingPathComponent(Self.skillDirName)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
            return candidate
        }
        return nil
    }

    /// bundle 内 SKILL.md 的绝对路径（存在才返回）。
    var bundledSkillFile: String? {
        guard let dir = bundledSkillDir else { return nil }
        let file = (dir as NSString).appendingPathComponent("SKILL.md")
        return fm.fileExists(atPath: file) ? file : nil
    }

    /// 当前 bundle 内 SKILL.md 的版本信息，用于插件市场详情页展示。
    ///
    /// 优先从 frontmatter（首个 `---` 块）读取 `version` 字段；若无该字段，
    /// 则回退为文件最后修改时间。读取失败返回 nil（UI 侧不展示）。
    var bundledSkillVersionInfo: String? {
        guard let file = bundledSkillFile else { return nil }
        if let version = frontmatterVersion(atPath: file) {
            return "v\(version)"
        }
        // 回退：文件最后修改时间。
        if let mtime = (try? fm.attributesOfItem(atPath: file)[.modificationDate]) as? Date {
            let df = DateFormatter()
            df.locale = Locale(identifier: "zh_CN")
            df.dateFormat = "yyyy-MM-dd HH:mm"
            return "更新于 \(df.string(from: mtime))"
        }
        return nil
    }

    /// 解析 SKILL.md 头部 frontmatter 中的 `version` 字段。
    private func frontmatterVersion(atPath path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: .newlines)
        // frontmatter 必须以第一行的 `---` 开始。
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" else {
            return nil
        }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break } // frontmatter 结束
            if let range = trimmed.range(of: "version:", options: [.anchored, .caseInsensitive]) {
                let value = trimmed[range.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    // MARK: - 扫描 & 状态刷新

    func refresh() {
        detectedAgents = allAgents.filter { agent in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: agent.detectPath, isDirectory: &isDir) && isDir.boolValue
        }
        var newStates: [String: InstallState] = [:]
        for agent in detectedAgents {
            newStates[agent.id] = computeState(for: agent)
        }
        states = newStates
    }

    private func computeState(for agent: Agent) -> InstallState {
        let target = agent.skillTargetPath
        // 是否为软链接（destinationOfSymbolicLink 只读链接自身，即使目标已被删除也会成功返回）
        if let dest = try? fm.destinationOfSymbolicLink(atPath: target) {
            // v2.9.39 修复：仅凭「链接存在 + 记录路径匹配」判定「已安装」会漏判悬空软链接
            // （目标目录/App bundle 已删除时链接仍在）。必须校验软链接指向的真实目录是否
            // 仍存在于文件系统上。fileExists(atPath:) 会跟随软链接，悬空链接返回 false。
            var isDir: ObjCBool = false
            let targetExists = fm.fileExists(atPath: target, isDirectory: &isDir) && isDir.boolValue
            guard targetExists else {
                // 悬空 / 失效软链接：真实文件系统上并没有可用的 Skill，视为未安装。
                return .notInstalled
            }
            let resolved = resolveSymlink(dest, base: agent.skillsDir)
            if let source = bundledSkillDir,
               standardized(resolved) == standardized(source) {
                return .installed
            }
            return .needsUpdate
        }
        // 目标存在但不是软链接（可能是旧的真实目录）
        if fm.fileExists(atPath: target) {
            return .needsUpdate
        }
        return .notInstalled
    }

    private func resolveSymlink(_ dest: String, base: String) -> String {
        if (dest as NSString).isAbsolutePath { return dest }
        return (base as NSString).appendingPathComponent(dest)
    }

    // MARK: - Aggregate state (v2.9.17)

    /// Card-level rollup across all detected agents, used by the marketplace badge.
    /// - installed:    at least one agent has an up-to-date symlink and none pending.
    /// - needsUpdate:  at least one agent has a stale/foreign install.
    /// - notInstalled: no agent has it (or no agents detected).
    var aggregateState: InstallState {
        let values = detectedAgents.compactMap { states[$0.id] }
        if values.contains(.needsUpdate) { return .needsUpdate }
        if values.contains(.installed) { return .installed }
        return .notInstalled
    }

    /// Count of agents where this Skill is currently installed (up-to-date).
    var installedAgentCount: Int {
        detectedAgents.reduce(0) { $0 + ((states[$1.id] == .installed) ? 1 : 0) }
    }

    private func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    // MARK: - 安装动作

    func install(_ agent: Agent) {
        guard let source = bundledSkillDir else {
            report("找不到内置 Skill 目录，请重新安装 App。", isError: true)
            return
        }
        busyAgentID = agent.id
        lastMessage = nil

        let target = agent.skillTargetPath
        let skillsDir = agent.skillsDir

        // v2.9.26 安全防护：目标存在且不是软链接（可能是用户的真实目录/文件）时，
        // 绝不执行 rm -rf 删除，避免误删用户数据。仅当目标为软链接或不存在时才继续。
        if fileExistsNoFollow(target) && !isSymlink(target) {
            busyAgentID = nil
            report("目标已存在且不是软链接，为安全起见未做任何删除：\(target)。请手动检查后再安装。", isError: true)
            return
        }

        // 先尝试非特权方式（家目录通常可写）。
        if trySymlinkWithoutPrivilege(source: source, target: target, skillsDir: skillsDir) {
            busyAgentID = nil
            report("已安装到 \(agent.displayName)：\(target)", isError: false)
            refresh()
            return
        }

        // 回退：macOS 系统鉴权弹窗。仅在目标为软链接或不存在时才会执行到这里，rm -rf 安全。
        let script = "mkdir -p \(shellQuote(skillsDir)) && rm -rf \(shellQuote(target)) && ln -sfn \(shellQuote(source)) \(shellQuote(target))"
        runPrivileged(script,
                      successMessage: "已安装到 \(agent.displayName)：\(target)",
                      agentID: agent.id)
    }

    // MARK: - 已安装状态下的操作菜单（v2.9.45）

    /// 「更新」：把 App bundle 里最新的 Skill 重新覆盖到软链目标。
    ///
    /// 当前安装形态是软链接（`<agent skills>/clipslots-manager` -> bundle 内 skill 目录），
    /// 因此「更新」= 重新把软链指向当前 bundle 的 skill 目录（App 升级后 bundle 路径可能变化，
    /// 旧软链会指向已失效的旧 bundle）。重建后软链目录里的 SKILL.md 即为最新版本。
    ///
    /// 若目标是旧版拷贝式安装（真实目录，非软链），则就地覆盖其中的 SKILL.md 文件，
    /// 绝不删除用户目录。
    func update(_ agent: Agent) {
        guard let source = bundledSkillDir else {
            report("找不到内置 Skill 目录，请重新安装 App。", isError: true)
            return
        }
        busyAgentID = agent.id
        lastMessage = nil

        let target = agent.skillTargetPath

        if isSymlink(target) || !fileExistsNoFollow(target) {
            // 软链接（或已不存在）→ 重建软链，指向当前 bundle，使 SKILL.md 恢复最新。
            if trySymlinkWithoutPrivilege(source: source, target: target, skillsDir: agent.skillsDir) {
                busyAgentID = nil
                report("已更新 \(agent.displayName) 的 Skill 到最新版本：\(target)", isError: false)
                refresh()
                return
            }
            // 家目录不可写时回退系统鉴权（目标为软链或不存在，rm -rf 安全）。
            let script = "mkdir -p \(shellQuote(agent.skillsDir)) && rm -rf \(shellQuote(target)) && ln -sfn \(shellQuote(source)) \(shellQuote(target))"
            runPrivileged(script,
                          successMessage: "已更新 \(agent.displayName) 的 Skill 到最新版本：\(target)",
                          agentID: agent.id)
            return
        }

        // 真实目录（旧版拷贝式安装）→ 仅就地覆盖 SKILL.md，不动目录本身。
        busyAgentID = nil
        if refreshLegacyCopyIfOutdated(source: source, targetDir: target) {
            report("已更新 \(agent.displayName) 的 SKILL.md 到最新版本：\(target)", isError: false)
        } else {
            report("\(agent.displayName) 的 Skill 已是最新版本。", isError: false)
        }
        refresh()
    }

    /// 「打开目录」：在 Finder 中打开该 Agent 的 skill 安装目录。
    func openInstallDirectory(_ agent: Agent) {
        let target = agent.skillTargetPath
        let path: String
        if fileExistsNoFollow(target) {
            path = target
        } else {
            // 目标不存在时退而打开其父级 skills 目录。
            path = agent.skillsDir
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 「卸载」：删除软链目录，卸载后该 Agent 状态回到「未安装」。
    ///
    /// 安全策略与安装一致：仅当目标为软链接时才删除（`removeItem` 只删软链本身，
    /// 不影响 bundle 内的真实 skill 目录）。若目标是用户的真实目录/文件，为避免误删数据不做删除。
    func uninstall(_ agent: Agent) {
        busyAgentID = agent.id
        lastMessage = nil
        let target = agent.skillTargetPath

        guard fileExistsNoFollow(target) else {
            busyAgentID = nil
            report("\(agent.displayName) 未安装本 Skill，无需卸载。", isError: false)
            refresh()
            return
        }

        // 真实目录/文件（非软链）不删除，避免误伤用户数据。
        if !isSymlink(target) {
            busyAgentID = nil
            report("目标不是软链接，为安全起见未删除：\(target)。请手动检查后再卸载。", isError: true)
            refresh()
            return
        }

        do {
            try fm.removeItem(atPath: target)
            busyAgentID = nil
            report("已从 \(agent.displayName) 卸载本 Skill。", isError: false)
            refresh()
        } catch {
            // 家目录不可写时回退系统鉴权（目标已确认为软链，rm 安全）。
            let script = "rm -rf \(shellQuote(target))"
            runPrivileged(script,
                          successMessage: "已从 \(agent.displayName) 卸载本 Skill。",
                          agentID: agent.id)
        }
    }

    // MARK: - 聚合动作（v2.9.28）

    /// 重新扫描本机 Agent，并给出可见反馈（修复刷新按钮点击"无反应"的观感问题）。
    func rescan() {
        refresh()
        if detectedAgents.isEmpty {
            report("已重新扫描：未检测到已安装的 Agent（Claude Code / Cursor / Codex / Gemini CLI）", isError: false)
        } else {
            let names = detectedAgents.map(\.displayName).joined(separator: "、")
            report("已重新扫描，检测到 \(detectedAgents.count) 个 Agent：\(names)", isError: false)
        }
    }

    /// 一键把本 Skill 安装到所有已检测到的 Agent。
    /// 复用单 Agent 的安全软链逻辑，保留 lstat 软链接安全防护（绝不删除真实目录/文件）。
    func installToAllDetectedAgents() {
        guard let source = bundledSkillDir else {
            report("找不到内置 Skill 目录，请重新安装 App。", isError: true)
            return
        }
        let agents = detectedAgents
        guard !agents.isEmpty else {
            report("未检测到已安装的 Agent，请先安装 Claude Code / Cursor / Codex / Gemini CLI。", isError: true)
            return
        }

        var installed: [String] = []
        var skipped: [String] = []
        var needPrivilege: [Agent] = []

        for agent in agents {
            let target = agent.skillTargetPath
            // 安全防护：目标存在且不是软链接（可能是用户真实目录/文件）时，绝不删除，直接跳过。
            if fileExistsNoFollow(target) && !isSymlink(target) {
                skipped.append(agent.displayName)
                continue
            }
            if trySymlinkWithoutPrivilege(source: source, target: target, skillsDir: agent.skillsDir) {
                installed.append(agent.displayName)
            } else {
                needPrivilege.append(agent)
            }
        }

        // 对家目录不可写的 Agent，回退到系统鉴权弹窗。
        // 注意：needPrivilege 中的目标只可能是软链接或不存在（真实目录已被拦截进 skipped），rm -rf 安全。
        if !needPrivilege.isEmpty {
            let cmds = needPrivilege.map { agent in
                "mkdir -p \(shellQuote(agent.skillsDir)) && rm -rf \(shellQuote(agent.skillTargetPath)) && ln -sfn \(shellQuote(source)) \(shellQuote(agent.skillTargetPath))"
            }.joined(separator: " && ")
            let allInstalled = installed + needPrivilege.map(\.displayName)
            runPrivileged(cmds,
                          successMessage: aggregateMessage(installed: allInstalled, skipped: skipped),
                          agentID: needPrivilege[0].id)
            return
        }

        refresh()
        report(aggregateMessage(installed: installed, skipped: skipped),
               isError: installed.isEmpty && !skipped.isEmpty)
    }

    // MARK: - 设置页「Agent Skill」卡片：拷贝式安装 / 卸载（v2.9.46）

    /// 已安装本 Skill 的 Agent（skillTargetPath 真实存在，软链或真实目录皆算）。
    /// 设置页卡片据此展示绿点与安装路径。
    var agentsWithSkillInstalled: [Agent] {
        detectedAgents.filter { fileExistsNoFollow($0.skillTargetPath) }
    }

    /// 「重新安装 Skill」：删除所有已检测 Agent 的旧 skill 目标（软链**或**遗留真实目录），
    /// 再重建软链指向 App bundle 内的最新 skill 目录（与插件市场的安装逻辑完全一致）。
    ///
    /// v2.9.47 修复：旧实现把 SKILL.md 拷贝进真实目录，导致 skill 目标变成真实目录；此后
    /// 安装逻辑的安全护栏（「目标非软链接，为安全起见未删除」）会拦截重装。现在统一为
    /// 「删旧路径 → 重建软链」，彻底避免遗留真实目录导致下次安装被拦截。
    func reinstallSkillByOverwrite() {
        guard let source = bundledSkillDir else {
            report("找不到内置 Skill 目录，请重新安装 App。", isError: true)
            return
        }
        refresh()
        let agents = detectedAgents
        guard !agents.isEmpty else {
            report("未检测到已安装的 Agent，请先安装 Claude Code / Cursor / Codex / Gemini CLI。", isError: true)
            return
        }

        var done: [String] = []
        var needPrivilege: [Agent] = []
        for agent in agents {
            if relinkSkill(to: agent, source: source) {
                done.append(agent.displayName)
            } else {
                needPrivilege.append(agent)
            }
        }

        // 家目录不可写的 Agent 回退到系统鉴权弹窗，删旧路径后重建软链。
        if !needPrivilege.isEmpty {
            let cmds = needPrivilege.map { agent in
                "mkdir -p \(shellQuote(agent.skillsDir)) && rm -rf \(shellQuote(agent.skillTargetPath)) && ln -sfn \(shellQuote(source)) \(shellQuote(agent.skillTargetPath))"
            }.joined(separator: " && ")
            let allDone = done + needPrivilege.map(\.displayName)
            runPrivileged(cmds,
                          successMessage: "已重新安装最新 Skill 到 \(allDone.count) 个 Agent：\(allDone.joined(separator: "、"))",
                          agentID: needPrivilege[0].id)
            return
        }

        refresh()
        report("已重新安装最新 Skill 到 \(done.count) 个 Agent：\(done.joined(separator: "、"))", isError: false)
    }

    /// 删除单个 Agent 的旧 skill 目标（软链或遗留真实目录），再重建软链指向 bundle 内 skill 目录。
    /// - Returns: 非特权方式是否成功（失败通常是家目录不可写，需回退系统鉴权）。
    private func relinkSkill(to agent: Agent, source: String) -> Bool {
        let target = agent.skillTargetPath
        do {
            try fm.createDirectory(atPath: agent.skillsDir, withIntermediateDirectories: true)
            // 目标存在即删除，无论软链还是真实目录（removeItem 只删软链本身，不影响 bundle 源目录）。
            if fileExistsNoFollow(target) {
                try fm.removeItem(atPath: target)
            }
            try fm.createSymbolicLink(atPath: target, withDestinationPath: source)
            return true
        } catch {
            NSLog("[ClipSlots][Skill] relink failed for \(agent.displayName) at \(target): \(error)")
            return false
        }
    }

    /// 「卸载 Skill」：删除所有已安装 Agent 的 skill 目录（软链或真实目录皆删除），
    /// 卸载后卡片状态刷新为「未安装」。
    func uninstallSkillFromAllAgents() {
        refresh()
        let agents = agentsWithSkillInstalled
        guard !agents.isEmpty else {
            report("未检测到已安装本 Skill 的 Agent，无需卸载。", isError: false)
            refresh()
            return
        }

        var removed: [String] = []
        var failed: [String] = []
        for agent in agents {
            do {
                try fm.removeItem(atPath: agent.skillTargetPath)
                removed.append(agent.displayName)
            } catch {
                failed.append(agent.displayName)
            }
        }
        refresh()

        if failed.isEmpty {
            report("已从 \(removed.count) 个 Agent 卸载本 Skill：\(removed.joined(separator: "、"))", isError: false)
        } else if removed.isEmpty {
            report("卸载失败：\(failed.joined(separator: "、"))", isError: true)
        } else {
            report("已卸载：\(removed.joined(separator: "、"))；失败：\(failed.joined(separator: "、"))", isError: false)
        }
    }

    /// 卸载 App 时的静默清理：删除所有已安装 Agent 的 skill 目录，不产生 UI 反馈。
    func removeAllSkillDirectoriesSilently() {
        refresh()
        for agent in detectedAgents {
            let target = agent.skillTargetPath
            guard fileExistsNoFollow(target) else { continue }
            try? fm.removeItem(atPath: target)
        }
    }

    // MARK: - 启动时静默自动同步（v2.9.30）

    /// App 启动 / 进入设置页时调用：静默检测各 Agent 已安装的 Skill 是否落后于 App bundle
    /// 内的最新版本，若落后则自动更新，不弹窗、不打扰用户。
    ///
    /// 覆盖范围与手动「安装 Skill」完全一致（同一份 `allAgents` 目标目录清单）。
    /// 安全策略沿用手动安装：
    ///   - 软链接目标（含指向旧 bundle 的失效软链）→ 直接重建软链，使其指向当前 bundle；
    ///   - 真实目录/文件：绝不 `rm -rf`。仅当其确实是本 App 旧版拷贝式安装（目录内含
    ///     `SKILL.md`）且内容与最新 bundle 不一致时，就地覆盖该 `SKILL.md` 文件；
    ///     其余情况（用户自建目录等）一律跳过，避免误伤用户数据；
    ///   - 未安装的 Agent 不做自动安装（尊重用户从未安装过的选择）。
    func syncInstalledSkillsOnLaunch() {
        guard let source = bundledSkillDir else {
            NSLog("[ClipSlots][SkillSync] bundled skill dir not found, skip auto-sync")
            return
        }

        refresh()

        var relinked: [String] = []
        var refreshedCopy: [String] = []

        for agent in detectedAgents {
            let target = agent.skillTargetPath

            switch computeState(for: agent) {
            case .installed:
                // 已是指向当前 bundle 的软链，内容随 bundle 实时同步，无需处理。
                continue

            case .notInstalled:
                // 用户从未安装到该 Agent，启动时不主动安装。
                continue

            case .needsUpdate:
                if isSymlink(target) {
                    // 失效软链（指向旧 bundle / 别处）→ 安全重建（removeItem 只删软链本身）。
                    if trySymlinkWithoutPrivilege(source: source, target: target, skillsDir: agent.skillsDir) {
                        relinked.append(agent.displayName)
                        NSLog("[ClipSlots][SkillSync] re-linked stale symlink for \(agent.displayName): \(target) -> \(source)")
                    } else {
                        NSLog("[ClipSlots][SkillSync] failed to re-link \(agent.displayName) at \(target) (need privilege), skip silently")
                    }
                } else {
                    // 真实目录/文件：仅当是本 App 旧版拷贝安装（含 SKILL.md）且内容过期时，就地刷新文件。
                    if refreshLegacyCopyIfOutdated(source: source, targetDir: target) {
                        refreshedCopy.append(agent.displayName)
                        NSLog("[ClipSlots][SkillSync] refreshed outdated SKILL.md copy for \(agent.displayName): \(target)")
                    }
                }
            }
        }

        if relinked.isEmpty && refreshedCopy.isEmpty {
            NSLog("[ClipSlots][SkillSync] all installed skills up-to-date, nothing to sync")
        } else {
            NSLog("[ClipSlots][SkillSync] auto-sync done. relinked=\(relinked) refreshedCopy=\(refreshedCopy)")
            refresh()
        }
    }

    /// 旧版拷贝式安装的兼容处理：`targetDir` 是真实目录，若其中的 `SKILL.md` 与最新 bundle
    /// 内容不一致，则就地覆盖该文件（绝不删除目录本身），保证 Agent 拿到最新决策流。
    /// - Returns: 是否实际执行了覆盖更新。
    private func refreshLegacyCopyIfOutdated(source: String, targetDir: String) -> Bool {
        var isDir: ObjCBool = false
        // 必须是真实目录（非软链），且内部含 SKILL.md，才认定为本 App 的拷贝式安装。
        guard fm.fileExists(atPath: targetDir, isDirectory: &isDir), isDir.boolValue else { return false }

        let targetSkill = (targetDir as NSString).appendingPathComponent("SKILL.md")
        let sourceSkill = (source as NSString).appendingPathComponent("SKILL.md")

        guard fm.fileExists(atPath: targetSkill),
              fm.fileExists(atPath: sourceSkill),
              let sourceData = fm.contents(atPath: sourceSkill) else {
            return false
        }

        let targetData = fm.contents(atPath: targetSkill)
        if targetData == sourceData {
            return false // 已是最新，跳过。
        }

        do {
            try sourceData.write(to: URL(fileURLWithPath: targetSkill), options: .atomic)
            return true
        } catch {
            NSLog("[ClipSlots][SkillSync] failed to overwrite legacy SKILL.md at \(targetSkill): \(error)")
            return false
        }
    }

    private func aggregateMessage(installed: [String], skipped: [String]) -> String {
        var parts: [String] = []
        if !installed.isEmpty {
            parts.append("已安装到 \(installed.count) 个 Agent：\(installed.joined(separator: "、"))")
        }
        if !skipped.isEmpty {
            parts.append("已跳过（目标非软链接，为安全起见未删除）：\(skipped.joined(separator: "、"))")
        }
        return parts.isEmpty ? "没有可安装的 Agent。" : parts.joined(separator: "；")
    }

    private func trySymlinkWithoutPrivilege(source: String, target: String, skillsDir: String) -> Bool {
        do {
            try fm.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)
            // v2.9.26 安全防护：仅移除软链接，绝不删除真实目录/文件（真实目标已在 install() 中拦截）。
            if isSymlink(target) {
                try fm.removeItem(atPath: target)
            } else if fileExistsNoFollow(target) {
                // 真实目录/文件不应被删除，直接失败。
                return false
            }
            try fm.createSymbolicLink(atPath: target, withDestinationPath: source)
            return true
        } catch {
            return false
        }
    }

    /// 使用 lstat 语义判断路径是否为软链接（不跟随软链接）。
    private func isSymlink(_ path: String) -> Bool {
        guard let type = try? fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
    }

    /// 判断路径本身是否存在（不跟随软链接，坏软链接也算存在）。
    private func fileExistsNoFollow(_ path: String) -> Bool {
        if isSymlink(path) { return true }
        return fm.fileExists(atPath: path)
    }

    // MARK: - 特权执行（macOS 鉴权弹窗）

    private func runPrivileged(_ shellCommand: String, successMessage: String, agentID: String) {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: appleScript)
            _ = script?.executeAndReturnError(&errorInfo)

            DispatchQueue.main.async {
                self.busyAgentID = nil
                if let errorInfo {
                    let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                    if code == -128 {
                        self.report("已取消操作。", isError: false)
                    } else {
                        let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "未知错误"
                        self.report("安装失败：\(msg)", isError: true)
                    }
                } else {
                    self.report(successMessage, isError: false)
                }
                self.refresh()
            }
        }
    }

    // MARK: - 工具

    private func report(_ message: String, isError: Bool) {
        lastMessage = message
        lastMessageIsError = isError
    }

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
