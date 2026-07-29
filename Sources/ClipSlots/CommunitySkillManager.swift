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

    // B-8 (v2.10.31): nonisolated（纯字符串运算）以便后台 refresh 扫描调用。
    nonisolated private func skillTargetPath(agent: Agent, slug: String) -> String {
        (agent.skillsDir as NSString).appendingPathComponent(slug)
    }

    // MARK: - 扫描 & 刷新

    /// 重新扫描：读取落盘目录下所有已上传的 Skill + 检测本机 Agent + 计算安装状态。
    func refresh(completion: (() -> Void)? = nil) {
        // B-8 (v2.10.31): 之前 refresh() 完全跑在主线程（@MainActor）：loadCommunitySkills 会对每个
        // 社区 Skill 目录 String(contentsOfFile: SKILL.md) 全量读盘，computeState 对每个 (skill×agent)
        // 组合做 lstat/readlink。落盘在 FUSE / 网络盘 / 机械盘或 Skill 数量多时，会阻塞主线程造成插件
        // 市场刷新卡顿。改为：主线程只做轻量的 Agent 目录探测拿到 detectedAgents，然后把全部读盘扫描
        // 挪到后台队列（下列 helper 均已 nonisolated、只用 FileManager.default），算完回主线程一次性赋值
        // @Published。fm.fileExists 探测很轻，保留在主线程以拿到与旧行为一致的 detectedAgents。
        let agents = allAgents.filter { agent in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: agent.detectPath, isDirectory: &isDir) && isDir.boolValue
        }
        let root = communitySkillsRoot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let skills = self.loadCommunitySkills(root: root)
            var newStates: [String: [String: InstallState]] = [:]
            for skill in skills {
                var perAgent: [String: InstallState] = [:]
                for agent in agents {
                    perAgent[agent.id] = self.computeState(skill: skill, agent: agent)
                }
                newStates[skill.id] = perAgent
            }
            DispatchQueue.main.async {
                self.detectedAgents = agents
                self.skills = skills
                self.states = newStates
                completion?()
            }
        }
    }

    /// 扫描落盘根目录下的所有一级子目录，解析每个目录内的 SKILL.md。
    // B-8 (v2.10.31): nonisolated（只用 FileManager.default + nonisolated parseFrontmatter，不触碰
    // @Published 状态）以便在后台队列执行全量读盘扫描。root 由主线程读取后传入。
    nonisolated private func loadCommunitySkills(root: String) -> [CommunitySkill] {
        let fm = FileManager.default
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

    // B-8 (v2.10.31): nonisolated（只用 FileManager.default）以便后台 refresh 扫描调用。
    nonisolated private func computeState(skill: CommunitySkill, agent: Agent) -> InstallState {
        let fm = FileManager.default
        let target = skillTargetPath(agent: agent, slug: skill.id)
        if let dest = try? fm.destinationOfSymbolicLink(atPath: target) {
            // 校验软链指向的真实目录是否仍存在（悬空软链视为需更新/待修复）。
            var isDir: ObjCBool = false
            let targetExists = fm.fileExists(atPath: target, isDirectory: &isDir) && isDir.boolValue
            // P2 (v2.10.13): 悬空软链（指向已删除的旧 bundle）此前返回 .notInstalled，卡片
            // 显示「未安装」，与 CLIInstallManager / AgentSkillInstallManager 的「已损坏/待修复」
            // 表现不一致。改为返回 .needsUpdate（枚举注释已含「悬空」语义），提示用户重装修复。
            guard targetExists else { return .needsUpdate }
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

    nonisolated private func resolveSymlink(_ dest: String, base: String) -> String {
        if (dest as NSString).isAbsolutePath { return dest }
        return (base as NSString).appendingPathComponent(dest)
    }

    nonisolated private func standardized(_ path: String) -> String {
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
        // B-2 (v2.10.31): 入口串行化拦截。importZip 把落盘 I/O 派发到 global 队列，`isBusy` 直到主线程
        // 收尾才复位。若无此拦截，快速连点 / 并发导入「同名 Skill」会有多个后台线程对同一目标 dest 并发
        // removeItem(dest)+moveItem——线程 A 可能在线程 B 刚 move 完之后又 remove，最终目录缺失或残缺。
        // dest 由 Skill 名 slug 唯一确定，故用 @MainActor 的 isBusy 做全局单飞闸门即可覆盖同名冲突。
        guard !isBusy else {
            report("正在导入其它 Skill，请稍候…", isError: true)
            return
        }
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
        // 落盘根目录在主线程上读取（@MainActor 计算属性），随后传入后台。
        let root = communitySkillsRoot
        // MT-4 (v2.10.30): 解压(unzip 的 waitUntilExit)与逐文件拷贝原先在主线程同步执行，大包 / 大量
        // 小文件会冻结界面。改为在后台队列完成全部文件 I/O（performZipImport 为 nonisolated，仅用
        // FileManager.default 与其它 nonisolated helper，不触碰 @MainActor 状态），再回主线程复位 isBusy、
        // 刷新 @Published 状态并收尾（report / finishImport）。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = self.performZipImport(at: url, root: root)
            DispatchQueue.main.async {
                self.isBusy = false
                switch outcome {
                case .failure(let message):
                    self.report(message, isError: true)
                case .success(let name, let slug):
                    self.finishImport(name: name, slug: slug)
                }
            }
        }
    }

    /// MT-4 (v2.10.30): ZIP 导入的后台执行结果——成功携带解析出的 name/slug，失败携带用户可读错误文案。
    private enum ZipImportOutcome {
        case success(name: String, slug: String)
        case failure(String)
    }

    /// MT-4 (v2.10.30): 在后台线程完成 ZIP 导入的全部文件 I/O：解压 → 定位 SKILL.md → 解析并校验
    /// frontmatter → 同卷暂存目录构建并校验完整性 → 原子落盘。全程仅用 FileManager.default 与
    /// nonisolated helper，绝不触碰 @MainActor 的 @Published 状态或 report（校验失败以返回值携带文案，
    /// 由主线程统一反馈），因此可安全在 DispatchQueue.global 上运行而不阻塞主线程。
    nonisolated private func performZipImport(at url: URL, root: String) -> ZipImportOutcome {
        let fm = FileManager.default

        // 1. 解压到临时目录。
        let tmp = fm.temporaryDirectory.appendingPathComponent("clipslots-skill-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        } catch {
            return .failure("创建临时目录失败：\(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: tmp) }

        guard unzip(url.path, to: tmp.path) else {
            return .failure("解压失败，请确认这是一个有效的 .zip 文件。")
        }

        // 2. 定位含 SKILL.md 的目录（根目录或一级子目录）。
        guard let skillDir = findSkillRoot(in: tmp.path) else {
            return .failure("压缩包内未找到 SKILL.md（应位于根目录或一级子目录下）。")
        }

        // 3. 解析并校验 frontmatter（后台执行，故内联校验并以返回值携带错误文案，不调用 @MainActor 的 report）。
        let skillMd = (skillDir as NSString).appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOfFile: skillMd, encoding: .utf8) else {
            return .failure("无法读取 SKILL.md 内容。")
        }
        let front = parseFrontmatter(content)
        let name = front["name"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let desc = front["description"]?.trimmingCharacters(in: .whitespaces) ?? ""
        var missing: [String] = []
        if name.isEmpty { missing.append("name") }
        if desc.isEmpty { missing.append("description") }
        guard missing.isEmpty else {
            return .failure("SKILL.md 的 frontmatter 缺少必填字段：\(missing.joined(separator: "、"))。请补全后重试。")
        }
        let slugValue = slug(from: name)

        // 4. AU-4 (v2.10.15): 先在同卷暂存目录内构建完整 Skill 并校验完整性，通过后再整体
        //    原子移动到目标目录；任一步失败即清理暂存目录，绝不在目标目录留下半成品。
        //    （旧实现逐个 copyItem 到目标目录，非原子：中途失败会残留不完整的 Skill，
        //    后续校验/软链可能指向不完整内容。）
        do {
            // 暂存目录放在 community-skills 根下，确保与最终目标同卷 → moveItem 为原子 rename。
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch {
            return .failure("准备落盘目录失败：\(error.localizedDescription)")
        }
        let staging = (root as NSString).appendingPathComponent(".staging-\(UUID().uuidString)")
        do {
            try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        } catch {
            return .failure("创建暂存目录失败：\(error.localizedDescription)")
        }
        // 成功时暂存目录已被 move 走，remove 变为无害的 no-op；失败时确保清理。
        defer { try? fm.removeItem(atPath: staging) }

        do {
            let items = try fm.contentsOfDirectory(atPath: skillDir)
            for item in items {
                if item == "__MACOSX" || item == ".DS_Store" { continue }
                let src = (skillDir as NSString).appendingPathComponent(item)
                let dst = (staging as NSString).appendingPathComponent(item)
                try fm.copyItem(atPath: src, toPath: dst)
            }
        } catch {
            return .failure("写入落盘目录失败：\(error.localizedDescription)")
        }

        // 完整性校验：暂存目录内必须含 SKILL.md，否则视为不完整，放弃导入。
        let stagedSkill = (staging as NSString).appendingPathComponent("SKILL.md")
        guard fm.fileExists(atPath: stagedSkill) else {
            return .failure("Skill 内容不完整（缺少 SKILL.md），已取消导入。")
        }

        // 原子落盘：目标已存在则先移除（覆盖同名 Skill），再把整个暂存目录 rename 过去。
        let dest = (root as NSString).appendingPathComponent(slugValue)
        do {
            if fileExistsNoFollow(dest) {
                try fm.removeItem(atPath: dest)   // 覆盖同名 Skill
            }
            try fm.moveItem(atPath: staging, toPath: dest)
        } catch {
            return .failure("写入落盘目录失败：\(error.localizedDescription)")
        }

        return .success(name: name, slug: slugValue)
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
        // INST-2 (v2.10.32): B-8 made refresh() async (self.skills is only assigned after a
        // background scan), but finishImport still read `skills.first(where: id==slug)` in the
        // SAME main-thread turn right after calling refresh() — i.e. against the STALE pre-refresh
        // array. For a brand-new upload the slug is not in the old array, so the guard always
        // failed → "已上传但刷新列表失败" and install(silent:) never ran (new community skills were
        // never auto-symlinked). Fix: run the lookup + install inside refresh()'s completion, after
        // the background scan has populated skills/detectedAgents on the main thread.
        refresh { [weak self] in
            guard let self = self else { return }
            guard let skill = self.skills.first(where: { $0.id == slug }) else {
                self.report("已上传「\(name)」，但刷新列表失败，请重新打开插件市场。", isError: true)
                return
            }
            if self.detectedAgents.isEmpty {
                self.report("已上传 Skill「\(name)」。未检测到 Agent，稍后可在卡片上点击「安装到 Agent」。", isError: false)
            } else {
                self.install(skill, silent: true)
                let names = self.detectedAgents.map(\.displayName).joined(separator: "、")
                self.report("已上传并安装 Skill「\(name)」到 \(self.detectedAgents.count) 个 Agent：\(names)", isError: false)
            }
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
        // P1 (v2.10.13): 目标为真实目录/文件（非软链）时不再强制覆盖删除，改为安全跳过，
        // 避免误删用户手动放置的同名 Skill 目录（与官方 install() 一致）。
        var skipped: [String] = []
        var needPrivilege: [Agent] = []

        for agent in agents {
            let target = skillTargetPath(agent: agent, slug: skill.id)
            // 安全护栏：真实目录/文件（非软链）跳过，绝不递归删除。
            if fileExistsNoFollow(target) && !isSymlink(target) {
                skipped.append(agent.displayName)
                continue
            }
            // 安装动作 = 重建软链（软链、悬空软链或不存在时安全）。社区 Skill 的落盘源目录
            // （~/Library/Application Support/ClipSlots/community-skills/<slug>）与 Agent 侧目标独立，
            // 删除软链目标不影响源文件。
            if trySymlinkWithoutPrivilege(source: source, target: target, skillsDir: agent.skillsDir) {
                installed.append(agent.displayName)
            } else {
                needPrivilege.append(agent)
            }
        }

        if !needPrivilege.isEmpty {
            // needPrivilege 中的目标只可能是软链或不存在（真实目录已进 skipped），rm -rf 安全。
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
    // MT-4 (v2.10.30): nonisolated（纯函数，不触碰 self 状态）以便后台 performZipImport 调用。
    nonisolated func parseFrontmatter(_ content: String) -> [String: String] {
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
    // MT-4 (v2.10.30): nonisolated（纯函数）以便后台 performZipImport 调用。
    nonisolated func slug(from name: String) -> String {
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
    // MT-4 (v2.10.30): nonisolated（用 FileManager.default）以便后台 performZipImport 调用。
    nonisolated private func findSkillRoot(in root: String) -> String? {
        let fm = FileManager.default
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

    // MT-4 (v2.10.30): nonisolated 以便在后台 performZipImport 中调用；本方法只用局部 Process，不触碰 self 状态。
    nonisolated private func unzip(_ zipPath: String, to dest: String) -> Bool {
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
            // P1 (v2.10.13) 安全护栏：仅删除软链本身；真实目录/文件绝不递归删除，避免误删
            // 用户手动放置在 ~/.codex/skills/<slug> 的同名 Skill。真实目录由调用方拦截进 skipped，
            // 此处 return false 作为纵深防御（不会误删也不会安装）。
            if isSymlink(target) {
                try fm.removeItem(atPath: target)
            } else if fileExistsNoFollow(target) {
                return false
            }
            try fm.createSymbolicLink(atPath: target, withDestinationPath: source)
            return true
        } catch {
            return false
        }
    }

    /// 使用 lstat 语义判断路径是否为软链接（不跟随软链接）。
    // MT-4 (v2.10.30): nonisolated（用 FileManager.default，不读 @MainActor 的 self.fm）以便后台调用。
    nonisolated private func isSymlink(_ path: String) -> Bool {
        guard let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
    }

    /// 判断路径本身是否存在（不跟随软链接，坏软链接也算存在）。
    // MT-4 (v2.10.30): nonisolated（用 FileManager.default）以便后台 performZipImport 调用。
    nonisolated private func fileExistsNoFollow(_ path: String) -> Bool {
        if isSymlink(path) { return true }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - 特权执行（macOS 鉴权弹窗）

    private func runPrivileged(_ shellCommand: String, successMessage: String) {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        isBusy = true
        // P0-2 (v2.10.30): 改用后台 Process 启动 /usr/bin/osascript 执行授权脚本，替代旧的主线程同步
        // NSAppleScript。NSAppleScript 非线程安全且要求主线程执行，授权弹窗（密码 / 触控 ID）期间会把主
        // run loop 完全冻住，整个 App 模态假死（无法移动窗口 / 点菜单）。osascript 是独立进程，没有
        // NSAppleScript 的主线程限制：后台 run + waitUntilExit，弹窗照常出现但主线程保持响应；结束后再
        // DispatchQueue.main.async 回主线程复位 isBusy、更新 @Published 状态并刷新。isBusy 在授权完成前
        // 保持为 true，UI 据此禁用按钮，避免重复触发（不再依赖主线程被同步阻塞来拦截点击）。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var status: Int32 = -1
            var errText = ""
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", appleScript]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            // B-4 (v2.10.31): drain both pipes concurrently before waitUntilExit (see helper in
            // CLIInstallManager.swift). Old sequential "read stderr → read stdout" ordering
            // deadlocks if the child ever writes > ~64KB to stdout.
            let result = runProcessDrainingBothPipes(proc, outPipe: outPipe, errPipe: errPipe)
            status = result.status
            errText = String(data: result.err, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                if status == 0 {
                    self.report(successMessage, isError: false)
                } else if errText.contains("-128") || errText.contains("User canceled") {
                    self.report("已取消操作。", isError: false)
                } else {
                    let msg = errText.isEmpty ? "未知错误（退出码 \(status)）" : errText
                    self.report("操作失败：\(msg)", isError: true)
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
