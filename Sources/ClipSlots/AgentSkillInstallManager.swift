import Foundation
import SwiftUI

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
        // 是否为软链接
        if let dest = try? fm.destinationOfSymbolicLink(atPath: target) {
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
