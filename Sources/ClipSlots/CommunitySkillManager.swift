import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// v2.9.53: 「社区 Skill」——用户自定义上传 Skill 并像官方 Skill 一样软链安装到各 Agent。
//
// 与官方 `AgentSkillInstallManager`（只管理 bundle 内置的单个 clipslots-manager）不同，
// 本 Manager 负责「用户上传的任意 Skill」：
//   1. 通过 NSOpenPanel 选择 .zip（Skill 打包包）或单个 .md（SKILL.md）
//   2. 校验 SKILL.md frontmatter 必含 name / description
//   3. 落盘到 ~/Library/Application Support/ClipSlots/community-skills/<slug>/
//   4. 在各 Agent 的 skills 目录下创建软链接指向落盘目录（复用官方安装的安全软链逻辑）
//
// 安全策略与 AgentSkillInstallManager 完全一致：
//   - 仅当软链目标为软链接或不存在时才创建/删除，绝不 rm -rf 用户的真实目录/文件；
//   - 家目录不可写时回退 macOS 系统鉴权弹窗。
@MainActor
final class CommunitySkillManager: ObservableObject {

    // MARK: - 数据模型

    /// 一个已上传的社区 Skill（由落盘目录内的 SKILL.md frontmatter 解析而来）。
    struct CommunitySkill: Identifiable, Equatable {
        /// slug（同时是落盘目录名 & 各 Agent 下的软链接名）。
        let id: String
        /// frontmatter `name`。
        let name: String
        /// frontmatter `description`，作为卡片一句话描述。
        let summary: String
        /// 落盘目录绝对路径：~/Library/Application Support/ClipSlots/community-skills/<slug>。
        let storagePath: String
        /// frontmatter `version`（可选）。
        let version: String?

        static func == (lhs: CommunitySkill, rhs: CommunitySkill) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.summary == rhs.summary && lhs.version == rhs.version
        }
    }

    /// 单个 Agent 环境定义（与 AgentSkillInstallManager 的目录清单保持一致）。
    struct Agent: Identifiable, Equatable {
        let id: String
        let displayName: String
        let detectPath: String
        let skillsDir: String

        static func == (lhs: Agent, rhs: Agent) -> Bool { lhs.id == rhs.id }
    }

    enum InstallState: Equatable {
        case notInstalled     // 目标不存在
        case installed        // 已是指向落盘目录的有效软链接
        case needsUpdate      // 目标存在但不是正确软链接（旧目录 / 指向别处 / 悬空）
    }

    // MARK: - 发布状态

    @Published private(set) var skills: [CommunitySkill] = []
    @Published private(set) var detectedAgents: [Agent] = []
    /// states[skillID][agentID] = 安装状态。
    @Published private(set) var states: [String: [String: InstallState]] = [:]
    @Published var lastMessage: String?
    @Published var lastMessageIsError = false
    @Published var isBusy = false

    private let fm = FileManager.default

    // MARK: - 路径

    private static func home(_ rel: String) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(rel)
    }

    /// 社区 Skill 落盘根目录。
    var communitySkillsRoot: String {
        Self.home("Library/Application Support/ClipSlots/community-skills")
    }

    /// 所有受支持的 Agent 环境（无论是否安装）。
    private let allAgents: [Agent] = [
        Agent(id: "claude", displayName: "Claude Code",
              detectPath: home(".claude"), skillsDir: home(".claude/skills")),
        Agent(id: "cursor", displayName: "Cursor",
              detectPath: home(".cursor"), skillsDir: home(".cursor/skills")),
        Agent(id: "codex", displayName: "Codex",
              detectPath: home(".codex"), skillsDir: home(".codex/skills")),
        Agent(id: "gemini", displayName: "Gemini CLI",
              detectPath: home(".gemini"), skillsDir: home(".gemini/skills")),
    ]

    private func skillTargetPath(agent: Agent, slug: String) -> String {
        (agent.skillsDir as NSString).appendingPathComponent(slug)
    }

    // MARK: - 扫描 & 刷新

    /// 重新扫描：读取落盘目录下所有已上传的 Skill + 检测本机 Agent + 计算安装状态。
    func refresh() {
        detectedAgents = allAgents.filter { agent in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: agent.detectPath, isDirectory: &isDir) && isDir.boolValue
        }

        skills = loadCommunitySkills()

        var newStates: [String: [String: InstallState]] = [:]
        for skill in skills {
            var perAgent: [String: InstallState] = [:]
            for agent in detectedAgents {
                perAgent[agent.id] = computeState(skill: skill, agent: agent)
            }
            newStates[skill.id] = perAgent
        }
        states = newStates
    }

    /// 扫描落盘根目录下的所有一级子目录，解析每个目录内的 SKILL.md。
    private func loadCommunitySkills() -> [CommunitySkill] {
        let root = communitySkillsRoot
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var result: [CommunitySkill] = []
        for entry in entries.sorted() {
            if entry.hasPrefix(".") { continue }
            let dir = (root as NSString).appendingPathComponent(entry)
            var entryIsDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &entryIsDir), entryIsDir.boolValue else { continue }

            let skillMd = (dir as NSString).appendingPathComponent("SKILL.md")
            guard let content = try? String(contentsOfFile: skillMd, encoding: .utf8) else { continue }
            let front = parseFrontmatter(content)
            // 落盘目录一定是通过校验流程写入的，name / description 必然存在；
            // 兜底：name 缺失时用目录名，description 缺失时留空。
            let name = front["name"]?.isEmpty == false ? front["name"]! : entry
            let summary = front["description"] ?? ""
            result.append(CommunitySkill(
                id: entry,
                name: name,
                summary: summary,
                storagePath: dir,
                version: (front["version"]?.isEmpty == false) ? front["version"] : nil
            ))
        }
        return result
    }

    private func computeState(skill: CommunitySkill, agent: Agent) -> InstallState {
        let target = skillTargetPath(agent: agent, slug: skill.id)
        if let dest = try? fm.destinationOfSymbolicLink(atPath: target) {
            // 校验软链指向的真实目录是否仍存在（悬空软链视为需更新/未安装）。
            var isDir: ObjCBool = false
            let targetExists = fm.fileExists(atPath: target, isDirectory: &isDir) && isDir.boolValue
            guard targetExists else { return .notInstalled }
            let resolved = resolveSymlink(dest, base: agent.skillsDir)
            if standardized(resolved) == standardized(skill.storagePath) {
                return .installed
            }
            return .needsUpdate
        }
        if fm.fileExists(atPath: target) {
            return .needsUpdate   // 存在但不是软链接（旧目录）
        }
        return .notInstalled
    }

    private func resolveSymlink(_ dest: String, base: String) -> String {
        if (dest as NSString).isAbsolutePath { return dest }
        return (base as NSString).appendingPathComponent(dest)
    }

    private func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    // MARK: - 聚合状态（卡片用）

    /// 某个 Skill 跨所有已检测 Agent 的聚合状态。
    func aggregateState(for skill: CommunitySkill) -> InstallState {
        let values = detectedAgents.compactMap { states[skill.id]?[$0.id] }
        if values.contains(.needsUpdate) { return .needsUpdate }
        if values.contains(.installed) { return .installed }
        return .notInstalled
    }

    /// 已安装（有效软链）该 Skill 的 Agent 数量。
    func installedAgentCount(for skill: CommunitySkill) -> Int {
        detectedAgents.reduce(0) { $0 + ((states[skill.id]?[$1.id] == .installed) ? 1 : 0) }
    }

    // MARK: - 上传入口

    /// 弹出 NSOpenPanel 选择 .zip 或 .md，然后校验并安装。
    func presentUploadPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 Skill 压缩包（.zip）或单个 SKILL.md 文件"
        panel.prompt = "上传"
        if #available(macOS 12.0, *) {
            var types: [UTType] = [.zip]
            if let md = UTType(filenameExtension: "md") { types.append(md) }
            if let markdown = UTType(filenameExtension: "markdown") { types.append(markdown) }
            panel.allowedContentTypes = types
        } else {
            panel.allowedFileTypes = ["zip", "md", "markdown"]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSkill(at: url)
    }

    /// 根据扩展名分发到 zip / md 导入逻辑。
    func importSkill(at url: URL) {
        lastMessage = nil
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "zip":
            importZip(at: url)
        case "md", "markdown":
            importMarkdown(at: url)
        default:
            report("不支持的文件类型：.\(ext)。请选择 .zip 或 .md 文件。", isError: true)
        }
    }

    // MARK: - ZIP 导入

    private func importZip(at url: URL) {
        isBusy = true
        defer { isBusy = false }

        // 1. 解压到临时目录。
        let tmp = fm.temporaryDirectory.appendingPathComponent("clipslots-skill-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        } catch {
            report("创建临时目录失败：\(error.localizedDescription)", isError: true)
            return
        }
        defer { try? fm.removeItem(at: tmp) }

        guard unzip(url.path, to: tmp.path) else {
            report("解压失败，请确认这是一个有效的 .zip 文件。", isError: true)
            return
        }

        // 2. 定位含 SKILL.md 的目录（根目录或一级子目录）。
        guard let skillDir = findSkillRoot(in: tmp.path) else {
            report("压缩包内未找到 SKILL.md（应位于根目录或一级子目录下）。", isError: true)
            return
        }

        // 3. 解析并校验 frontmatter。
        let skillMd = (skillDir as NSString).appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOfFile: skillMd, encoding: .utf8) else {
            report("无法读取 SKILL.md 内容。", isError: true)
            return
        }
        let front = parseFrontmatter(content)
        guard let validation = validateFrontmatter(front) else { return }

        // 4. 落盘：把整个 skillDir 的内容拷进 community-skills/<slug>/。
        let slug = validation.slug
        guard let dest = prepareStorageDir(slug: slug) else { return }
        do {
            let items = try fm.contentsOfDirectory(atPath: skillDir)
            for item in items {
                if item == "__MACOSX" || item == ".DS_Store" { continue }
                let src = (skillDir as NSString).appendingPathComponent(item)
                let dst = (dest as NSString).appendingPathComponent(item)
                try fm.copyItem(atPath: src, toPath: dst)
            }
        } catch {
            report("写入落盘目录失败：\(error.localizedDescription)", isError: true)
            return
        }

        finishImport(name: validation.name, slug: slug)
    }

    // MARK: - 单个 SKILL.md 导入

    private func importMarkdown(at url: URL) {
        isBusy = true
        defer { isBusy = false }

        guard let content = try? String(contentsOfFile: url.path, encoding: .utf8) else {
            report("无法读取所选 Markdown 文件。", isError: true)
            return
        }
        let front = parseFrontmatter(content)
        guard let validation = validateFrontmatter(front) else { return }

        let slug = validation.slug
        guard let dest = prepareStorageDir(slug: slug) else { return }

        // 单文件统一落盘为 SKILL.md，保证各 Agent 能识别。
        let destFile = (dest as NSString).appendingPathComponent("SKILL.md")
        do {
            try content.write(toFile: destFile, atomically: true, encoding: .utf8)
        } catch {
            report("写入 SKILL.md 失败：\(error.localizedDescription)", isError: true)
            return
        }

        finishImport(name: validation.name, slug: slug)
    }

    /// 导入成功后的收尾：刷新列表 + 自动安装到已检测 Agent + 反馈。
    private func finishImport(name: String, slug: String) {
        refresh()
        guard let skill = skills.first(where: { $0.id == slug }) else {
            report("已上传「\(name)」，但刷新列表失败，请重新打开插件市场。", isError: true)
            return
        }
        if detectedAgents.isEmpty {
            report("已上传 Skill「\(name)」。未检测到 Agent，稍后可在卡片上点击「安装到 Agent」。", isError: false)
        } else {
            install(skill, silent: true)
            let names = detectedAgents.map(\.displayName).joined(separator: "、")
            report("已上传并安装 Skill「\(name)」到 \(detectedAgents.count) 个 Agent：\(names)", isError: false)
        }
    }

    // MARK: - 安装 / 卸载 / 删除

    /// 把某个社区 Skill 以软链接方式安装到所有已检测 Agent。
    /// - Parameter silent: 为 true 时不覆盖 `lastMessage`（由上层统一反馈）。
    func install(_ skill: CommunitySkill, silent: Bool = false) {
        let agents = detectedAgents
        guard !agents.isEmpty else {
            if !silent {
                report("未检测到已安装的 Agent，请先安装 Claude Code / Cursor / Codex / Gemini CLI。", isError: true)
            }
            return
        }
        let source = skill.storagePath

        var installed: [String] = []
        // v2.9.54: 安装即「强制重建软链」，不再因目标是真实目录而跳过（详见下方注释与
        // trySymlinkWithoutPrivilege），因此 skipped 恒为空，保留仅为兼容 aggregateMessage 的签名。
        let skipped: [String] = []
        var needPrivilege: [Agent] = []

        for agent in agents {
            let target = skillTargetPath(agent: agent, slug: skill.id)
            // v2.9.54: 安装动作 = 强制重建软链，与官方 Skill 的重装/更新逻辑保持一致。
            // 目标可能是旧软链、悬空软链，或历史遗留的真实目录（例如用户此前手动放进
            // ~/.codex/skills/<slug> 的同名 Skill）。旧逻辑对真实目录直接跳过，导致 Codex
            // 不出现在「已安装到」列表。由于社区 Skill 的落盘源目录
            // （~/Library/Application Support/ClipSlots/community-skills/<slug>）与 Agent 侧目标
            // 完全独立，删除目标不会影响源文件，可安全覆盖 —— 与提权兜底命令
            // （rm -rf target && ln -sfn source target）以及官方 relinkSkill 行为一致。
            if trySymlinkWithoutPrivilege(source: source, target: target, skillsDir: agent.skillsDir) {
                installed.append(agent.displayName)
            } else {
                needPrivilege.append(agent)
            }
        }

        if !needPrivilege.isEmpty {
            let cmds = needPrivilege.map { agent in
                let target = skillTargetPath(agent: agent, slug: skill.id)
                return "mkdir -p \(shellQuote(agent.skillsDir)) && rm -rf \(shellQuote(target)) && ln -sfn \(shellQuote(source)) \(shellQuote(target))"
            }.joined(separator: " && ")
            let allInstalled = installed + needPrivilege.map(\.displayName)
            runPrivileged(cmds,
                          successMessage: aggregateMessage(action: "安装", ok: allInstalled, skipped: skipped))
            return
        }

        refresh()
        if !silent {
            report(aggregateMessage(action: "安装", ok: installed, skipped: skipped),
                   isError: installed.isEmpty && !skipped.isEmpty)
        }
    }

    /// 卸载：删除各 Agent 下指向该 Skill 的软链接（不删本地落盘文件）。
    func uninstall(_ skill: CommunitySkill) {
        var removed: [String] = []
        var skipped: [String] = []
        var needPrivilege: [Agent] = []

        for agent in detectedAgents {
            let target = skillTargetPath(agent: agent, slug: skill.id)
            guard fileExistsNoFollow(target) else { continue }
            // 真实目录/文件（非软链）不删除，避免误伤用户数据。
            if !isSymlink(target) {
                skipped.append(agent.displayName)
                continue
            }
            do {
                try fm.removeItem(atPath: target)
                removed.append(agent.displayName)
            } catch {
                needPrivilege.append(agent)
            }
        }

        if !needPrivilege.isEmpty {
            let cmds = needPrivilege.map { agent in
                "rm -rf \(shellQuote(skillTargetPath(agent: agent, slug: skill.id)))"
            }.joined(separator: " && ")
            let allRemoved = removed + needPrivilege.map(\.displayName)
            runPrivileged(cmds,
                          successMessage: aggregateMessage(action: "卸载", ok: allRemoved, skipped: skipped))
            return
        }

        refresh()
        if removed.isEmpty && skipped.isEmpty {
            report("「\(skill.name)」未安装到任何 Agent，无需卸载。", isError: false)
        } else {
            report(aggregateMessage(action: "卸载", ok: removed, skipped: skipped), isError: false)
        }
    }

    /// 删除：先卸载所有软链，再删除本地落盘目录。
    func delete(_ skill: CommunitySkill) {
        // 先删各 Agent 软链（仅软链，安全）。
        for agent in detectedAgents {
            let target = skillTargetPath(agent: agent, slug: skill.id)
            if isSymlink(target) {
                try? fm.removeItem(atPath: target)
            }
        }
        // 再删落盘目录。
        do {
            try fm.removeItem(atPath: skill.storagePath)
            refresh()
            report("已删除 Skill「\(skill.name)」（含本地文件与各 Agent 软链）。", isError: false)
        } catch {
            refresh()
            report("删除本地文件失败：\(error.localizedDescription)", isError: true)
        }
    }

    /// 在 Finder 中打开该 Skill 的落盘目录。
    func openStorageDirectory(_ skill: CommunitySkill) {
        NSWorkspace.shared.open(URL(fileURLWithPath: skill.storagePath))
    }

    // MARK: - Frontmatter 解析 & 校验

    /// 解析 SKILL.md 头部 frontmatter（首个 `---` 块）为 key -> value 字典（key 小写）。
    func parseFrontmatter(_ content: String) -> [String: String] {
        let lines = content.components(separatedBy: .newlines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" else {
            return [:]
        }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }   // frontmatter 结束
            if trimmed.isEmpty { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            if key.isEmpty { continue }
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if result[key] == nil { result[key] = value }  // 保留首次出现的键
        }
        return result
    }

    private struct FrontmatterValidation { let name: String; let slug: String }

    /// 校验必含 name / description；不合格时弹错误并返回 nil。
    private func validateFrontmatter(_ front: [String: String]) -> FrontmatterValidation? {
        let name = front["name"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let desc = front["description"]?.trimmingCharacters(in: .whitespaces) ?? ""
        var missing: [String] = []
        if name.isEmpty { missing.append("name") }
        if desc.isEmpty { missing.append("description") }
        guard missing.isEmpty else {
            report("SKILL.md 的 frontmatter 缺少必填字段：\(missing.joined(separator: "、"))。请补全后重试。", isError: true)
            return nil
        }
        return FrontmatterValidation(name: name, slug: slug(from: name))
    }

    /// name -> slug：小写、空白转 `-`、仅保留字母/数字/CJK/`-`/`_`，去除其他特殊字符。
    func slug(from name: String) -> String {
        var out = ""
        var lastDash = false
        for ch in name.lowercased() {
            if ch.isWhitespace {
                if !out.isEmpty && !lastDash { out.append("-"); lastDash = true }
            } else if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                out.append(ch)
                lastDash = (ch == "-")
            }
            // 其他字符（标点/符号等）直接丢弃
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        if out.isEmpty {
            out = "skill-\(Int(Date().timeIntervalSince1970))"
        }
        return out
    }

    /// 准备落盘目录：若已存在同名 slug 目录则先移除（覆盖上传），再新建空目录。
    private func prepareStorageDir(slug: String) -> String? {
        let root = communitySkillsRoot
        let dest = (root as NSString).appendingPathComponent(slug)
        do {
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            if fileExistsNoFollow(dest) {
                try fm.removeItem(atPath: dest)   // 覆盖同名 Skill
            }
            try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
            return dest
        } catch {
            report("准备落盘目录失败：\(error.localizedDescription)", isError: true)
            return nil
        }
    }

    /// 在解压目录中定位含 SKILL.md 的目录：优先根目录，其次任一一级子目录。
    private func findSkillRoot(in root: String) -> String? {
        let rootSkill = (root as NSString).appendingPathComponent("SKILL.md")
        if fm.fileExists(atPath: rootSkill) { return root }

        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        for entry in entries {
            if entry == "__MACOSX" || entry.hasPrefix(".") { continue }
            let sub = (root as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub, isDirectory: &isDir), isDir.boolValue else { continue }
            let subSkill = (sub as NSString).appendingPathComponent("SKILL.md")
            if fm.fileExists(atPath: subSkill) { return sub }
        }
        return nil
    }

    // MARK: - 解压

    private func unzip(_ zipPath: String, to dest: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-q", zipPath, "-d", dest]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            NSLog("[ClipSlots][CommunitySkill] unzip failed: \(error)")
            return false
        }
    }

    // MARK: - 软链底层（与 AgentSkillInstallManager 保持一致的安全策略）

    private func trySymlinkWithoutPrivilege(source: String, target: String, skillsDir: String) -> Bool {
        do {
            // v2.9.54: 确保父目录存在（如 ~/.codex/skills/ 首次安装时可能不存在）。
            try fm.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)
            // 覆盖旧目标——软链、悬空软链或历史真实目录都先移除再重建软链。
            // 源目录是独立的社区 Skill 落盘目录，删除 Agent 侧同名目标不影响源文件；
            // 与官方 relinkSkill / 提权兜底命令（rm -rf target && ln -sfn）保持一致。
            if fileExistsNoFollow(target) {
                try fm.removeItem(atPath: target)
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

    private func runPrivileged(_ shellCommand: String, successMessage: String) {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: appleScript)
            _ = script?.executeAndReturnError(&errorInfo)

            DispatchQueue.main.async {
                self.isBusy = false
                if let errorInfo {
                    let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                    if code == -128 {
                        self.report("已取消操作。", isError: false)
                    } else {
                        let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "未知错误"
                        self.report("操作失败：\(msg)", isError: true)
                    }
                } else {
                    self.report(successMessage, isError: false)
                }
                self.refresh()
            }
        }
    }

    // MARK: - 工具

    private func aggregateMessage(action: String, ok: [String], skipped: [String]) -> String {
        var parts: [String] = []
        if !ok.isEmpty {
            parts.append("已\(action)到 \(ok.count) 个 Agent：\(ok.joined(separator: "、"))")
        }
        if !skipped.isEmpty {
            parts.append("已跳过（目标非软链接，为安全起见未处理）：\(skipped.joined(separator: "、"))")
        }
        return parts.isEmpty ? "没有可\(action)的 Agent。" : parts.joined(separator: "；")
    }

    private func report(_ message: String, isError: Bool) {
        lastMessage = message
        lastMessageIsError = isError
    }

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
