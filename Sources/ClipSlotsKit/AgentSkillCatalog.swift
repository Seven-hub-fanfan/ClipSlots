import Foundation

// MARK: - Skill 目录扫描与解析
//
// 目标：把"已安装的 Skill"变成 Agent 能用的东西，且**不撒谎**。
//
// 现实约束：SKILL.md 是给大模型读的自然语言文档，绝大多数 Skill（包括本项目自带的
// clipslots-manager）并不声明机器可读的工具 schema。想从散文里"猜"出
// name/description/parameters 只会产出幻觉工具——模型照着调，参数对不上，
// 然后把失败归咎于用户。所以这里走两条路，泾渭分明：
//
//   路线 A（有结构声明就用结构）：SKILL.md 里可以放一个围栏代码块
//       ```json clipslots-tools
//       [ { "name": ..., "description": ..., "parameters": {...}, "command": [...] } ]
//       ```
//     每一项直接变成一个真正的 Function Calling 工具，`command` 定义如何执行
//     （相对 Skill 目录，`{{参数名}}` 占位符按模型传入的实参替换）。
//
//   路线 B（没有结构声明，也就是绝大多数情况）：不伪造 schema。
//     Skill 通过三个通用工具暴露给模型：`list_skills` / `read_skill` /
//     `run_skill_script`。模型先读 SKILL.md（渐进披露），再用已有的 CLI 工具
//     或 Skill 自带脚本去干活。这正是 Skill 这套东西本来的用法。
//
// 安全边界（重要）：`run_skill_script` 等于允许模型在本机跑代码。因此
//   1. 只有用户在 UI 里**显式勾选启用**的 Skill 才会进入工具集；
//   2. 脚本路径必须解析后仍位于该 Skill 目录内（防 `../` 逃逸、防绝对路径）；
//   3. 只允许白名单扩展名，且不经过 shell（无字符串拼接 → 无注入面）；
//   4. 有超时与输出截断。
// 这些约束写在 AgentToolRegistry 里执行，本文件只负责"看见了什么"。

public struct AgentSkillDeclaredTool: Equatable, Sendable {
    public let name: String
    public let description: String
    public let parameters: JSONValue
    /// 执行命令，元素 0 是可执行文件（相对 Skill 目录或系统命令名），
    /// 其余为参数，支持 `{{argName}}` 占位符。
    public let command: [String]

    public init(name: String, description: String, parameters: JSONValue, command: [String]) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.command = command
    }
}

public struct AgentSkill: Identifiable, Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        /// App bundle 内自带（Contents/Resources/skills）。
        case bundled
        /// 插件市场上传的社区 Skill（~/Library/Application Support/ClipSlots/community-skills）。
        case community
        /// 各 Agent 的 skills 目录（~/.codex/skills 等）。
        case agentDirectory

        public var displayName: String {
            switch self {
            case .bundled: return "内置"
            case .community: return "插件市场"
            case .agentDirectory: return "Agent 目录"
            }
        }
    }

    public var id: String { slug }
    public let slug: String
    public let name: String
    public let description: String
    public let version: String?
    /// Skill 根目录。单文件 .md 形态时为其所在目录。
    public let directory: String
    public let markdownPath: String
    public let source: Source
    public let declaredTools: [AgentSkillDeclaredTool]
    /// 目录里发现的可执行脚本（相对路径），供 `run_skill_script` 使用与 UI 展示。
    public let scripts: [String]

    public init(slug: String,
                name: String,
                description: String,
                version: String?,
                directory: String,
                markdownPath: String,
                source: Source,
                declaredTools: [AgentSkillDeclaredTool],
                scripts: [String]) {
        self.slug = slug
        self.name = name
        self.description = description
        self.version = version
        self.directory = directory
        self.markdownPath = markdownPath
        self.source = source
        self.declaredTools = declaredTools
        self.scripts = scripts
    }
}

// MARK: - 扫描器

public struct AgentSkillCatalog {
    /// 扫描顺序即优先级：bundle > 插件市场 > Agent 目录。
    /// 后两者常常是指向前者的软链（AgentSkillInstallManager 就是这么装的），
    /// 所以必须同时按 slug 和"解析后的真实路径"去重，否则同一个 Skill 会出现三遍。
    public static func discover(bundlePath: String? = Bundle.main.bundlePath,
                               homeDirectory: String = NSHomeDirectory(),
                               fileManager: FileManager = .default) -> [AgentSkill] {
        var roots: [(path: String, source: AgentSkill.Source)] = []
        if let bundlePath {
            roots.append(((bundlePath as NSString).appendingPathComponent("Contents/Resources/skills"), .bundled))
        }
        roots.append(((homeDirectory as NSString)
            .appendingPathComponent("Library/Application Support/ClipSlots/community-skills"), .community))
        for agentDir in ["\(homeDirectory)/.codex/skills",
                         "\(homeDirectory)/.claude/skills",
                         "\(homeDirectory)/.cursor/skills",
                         "\(homeDirectory)/.gemini/skills"] {
            roots.append((agentDir, .agentDirectory))
        }

        var result: [AgentSkill] = []
        var seenSlugs = Set<String>()
        var seenRealPaths = Set<String>()

        for root in roots {
            for skill in scanRoot(root.path, source: root.source, fileManager: fileManager) {
                let real = (skill.markdownPath as NSString).resolvingSymlinksInPath
                if seenSlugs.contains(skill.slug) || seenRealPaths.contains(real) { continue }
                seenSlugs.insert(skill.slug)
                seenRealPaths.insert(real)
                result.append(skill)
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func scanRoot(_ root: String, source: AgentSkill.Source, fileManager: FileManager) -> [AgentSkill] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }

        var skills: [AgentSkill] = []
        for entry in entries.sorted() {
            if entry.hasPrefix(".") { continue }
            let full = (root as NSString).appendingPathComponent(entry)
            var entryIsDir: ObjCBool = false
            // fileExists 会跟随软链，这正是我们要的（Agent 目录里全是软链）。
            guard fileManager.fileExists(atPath: full, isDirectory: &entryIsDir) else { continue }

            if entryIsDir.boolValue {
                let md = (full as NSString).appendingPathComponent("SKILL.md")
                guard fileManager.fileExists(atPath: md) else { continue }
                if let skill = load(markdownPath: md, directory: full, fallbackSlug: entry,
                                    source: source, fileManager: fileManager) {
                    skills.append(skill)
                }
            } else if entry.lowercased().hasSuffix(".md") {
                // 单文件 Skill：插件市场支持上传裸 .md。
                let fallback = String(entry.dropLast(3))
                if let skill = load(markdownPath: full, directory: root, fallbackSlug: fallback,
                                    source: source, fileManager: fileManager) {
                    skills.append(skill)
                }
            }
        }
        return skills
    }

    static func load(markdownPath: String,
                     directory: String,
                     fallbackSlug: String,
                     source: AgentSkill.Source,
                     fileManager: FileManager) -> AgentSkill? {
        guard let raw = try? String(contentsOfFile: markdownPath, encoding: .utf8) else { return nil }
        let parsed = parse(markdown: raw, fallbackName: fallbackSlug)
        // slug 只保留 ASCII（工具名有字符集约束），所以中文名 Skill 会退到目录名，
        // 目录名也全中文时退到路径哈希——宁可名字丑，也不能让 Skill 凭空消失。
        var slug = slugify(parsed.name)
        if slug.isEmpty { slug = slugify(fallbackSlug) }
        if slug.isEmpty { slug = "skill_\(abs(markdownPath.hashValue) % 100_000)" }
        return AgentSkill(slug: slug,
                          name: parsed.name.isEmpty ? fallbackSlug : parsed.name,
                          description: parsed.description,
                          version: parsed.version,
                          directory: directory,
                          markdownPath: markdownPath,
                          source: source,
                          declaredTools: parsed.tools,
                          scripts: discoverScripts(in: directory, fileManager: fileManager))
    }

    // MARK: SKILL.md 解析

    public struct ParsedSkill: Equatable {
        public var name: String
        public var description: String
        public var version: String?
        public var tools: [AgentSkillDeclaredTool]
    }

    /// 纯函数，便于测试：给一段 markdown 文本，得出名称/简介/版本/结构化工具声明。
    public static func parse(markdown: String, fallbackName: String = "") -> ParsedSkill {
        let front = parseFrontmatter(markdown)
        var name = front["name"] ?? ""
        if name.isEmpty { name = fallbackName }
        var description = front["description"] ?? ""
        if description.isEmpty { description = firstParagraph(of: markdown) }
        // 简介过长会把工具列表撑爆（每个 Skill 的 description 都要进请求体），截断。
        if description.count > 400 { description = String(description.prefix(400)) + "…" }
        return ParsedSkill(name: name,
                           description: description,
                           version: front["version"],
                           tools: parseDeclaredTools(markdown))
    }

    /// 极简 YAML frontmatter：只认顶层 `key: value`。
    /// 刻意不实现嵌套/列表——工具声明走 JSON 围栏块，正是为了不在这里手搓 YAML。
    public static func parseFrontmatter(_ content: String) -> [String: String] {
        let lines = content.components(separatedBy: .newlines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // 缩进行视为上一键的续行，直接忽略（我们只要顶层标量）。
            if line.hasPrefix(" ") || line.hasPrefix("\t") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2)
                || (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
            }
            if key.isEmpty { continue }
            result[key.lowercased()] = value
        }
        return result
    }

    static func firstParagraph(of markdown: String) -> String {
        var lines = markdown.components(separatedBy: .newlines)
        // 跳过 frontmatter
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                lines = Array(lines[(end + 1)...])
            }
        }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("```") { continue }
            return t
        }
        return ""
    }

    /// 支持的围栏标记（大小写不敏感）：clipslots-tools / agent-tools，
    /// 可带 json 前缀（`json clipslots-tools`）以便编辑器高亮。
    static let toolFenceMarkers = ["clipslots-tools", "agent-tools"]

    public static func parseDeclaredTools(_ markdown: String) -> [AgentSkillDeclaredTool] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [String] = []
        var collecting = false
        var buffer: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if collecting {
                if trimmed.hasPrefix("```") {
                    blocks.append(buffer.joined(separator: "\n"))
                    buffer = []
                    collecting = false
                } else {
                    buffer.append(line)
                }
                continue
            }
            guard trimmed.hasPrefix("```") else { continue }
            let info = String(trimmed.dropFirst(3)).lowercased()
            if toolFenceMarkers.contains(where: { info.contains($0) }) { collecting = true }
        }

        var tools: [AgentSkillDeclaredTool] = []
        for block in blocks {
            guard let value = try? JSONValue.decode(jsonText: block) else { continue }
            // 允许单个对象或数组两种写法——第三方文档里两种都常见。
            let items: [JSONValue] = value.arrayValue ?? [value]
            for item in items {
                guard let name = item["name"]?.stringValue, !name.isEmpty else { continue }
                let description = item["description"]?.stringValue ?? ""
                let parameters = item["parameters"] ?? .object(["type": .string("object"),
                                                               "properties": .object([:])])
                var command: [String] = []
                if let array = item["command"]?.arrayValue {
                    command = array.compactMap(\.stringValue)
                } else if let single = item["command"]?.stringValue, !single.isEmpty {
                    // 字符串形态按空格切：便利写法，但不过 shell，所以不支持引号嵌套。
                    command = single.split(separator: " ").map(String.init)
                }
                guard !command.isEmpty else { continue } // 没有执行方式的声明是死条目，丢弃
                tools.append(AgentSkillDeclaredTool(name: name,
                                                    description: description,
                                                    parameters: parameters,
                                                    command: command))
            }
        }
        return tools
    }

    // MARK: 脚本发现

    static let scriptExtensions: Set<String> = ["sh", "py", "js", "rb", "swift", "pl", "zsh", "bash"]

    static func discoverScripts(in directory: String, fileManager: FileManager) -> [String] {
        guard let enumerator = fileManager.enumerator(atPath: directory) else { return [] }
        var found: [String] = []
        for case let rel as String in enumerator {
            // 只看两层，避免把 node_modules 之类的深目录整棵走完。
            if rel.components(separatedBy: "/").count > 3 { enumerator.skipDescendants(); continue }
            let ext = (rel as NSString).pathExtension.lowercased()
            guard scriptExtensions.contains(ext) else { continue }
            found.append(rel)
            if found.count >= 40 { break }
        }
        return found.sorted()
    }

    // MARK: 命名

    /// 生成稳定 slug，同时也是工具名的组成部分，因此必须符合
    /// Function Calling 的名称约束（^[a-zA-Z0-9_-]+$）。
    public static func slugify(_ input: String) -> String {
        var out = ""
        var lastWasDash = false
        for ch in input.lowercased() {
            if ch.isLetter && ch.isASCII || ch.isNumber && ch.isASCII {
                out.append(ch); lastWasDash = false
            } else if ch == "-" || ch == "_" {
                if !lastWasDash && !out.isEmpty { out.append("_"); lastWasDash = true }
            } else if ch == " " || ch == "." || ch == "/" {
                if !lastWasDash && !out.isEmpty { out.append("_"); lastWasDash = true }
            }
            // 非 ASCII（中文名很常见）直接丢弃——保留会让工具名非法。
            if out.count >= 40 { break }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return out
    }
}
