import Foundation

// MARK: - 工具注册表与执行
//
// 分三块：
//   1. `AgentProcessRunner`：跑外部进程的唯一入口（超时、输出截断、无 shell）。
//   2. `AgentBuiltinTools`：内置 ClipSlots CLI 工具，直连 /usr/local/bin/clipslots。
//   3. `AgentSkillTools` + `AgentToolRegistry`：把用户勾选的 Skill 变成工具并汇总。
//
// ## 为什么不经过 shell
// 所有执行都用 `Process` 传 argv 数组，绝不拼字符串交给 `/bin/sh -c`。
// 模型产出的参数是不可信输入，一旦进 shell，`; rm -rf ~` 就是一次工具调用的距离。
// argv 直传时参数永远只是参数，没有注入面。
//
// ## 失败也要有结构
// 工具失败不抛异常、不中断对话，而是回一段 `{"ok":false,"error_code":...}` 给模型。
// 模型看到 `SLOT_NOT_EMPTY` 能自己改用覆盖写；看到一个 Swift error 只会瞎猜。

// MARK: - 进程执行

public struct AgentProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public var succeeded: Bool { exitCode == 0 && !timedOut }

    /// 显式 public init：smoke 测试要注入假 runner 来断言 argv，
    /// 而结构体的隐式 memberwise init 是 internal，跨模块用不了。
    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public enum AgentProcessRunner {
    /// 同步执行（在调用方线程阻塞），异步入口见下面的 `run`。
    ///
    /// 输出读取用后台线程边跑边收，不是"等进程退出再 readToEnd"——
    /// 后者在输出超过管道缓冲（约 64KB）时会双向死锁：子进程等我们读，我们等它退出。
    static func runSync(executable: String,
                        arguments: [String],
                        currentDirectory: String?,
                        standardInput: String?,
                        timeout: TimeInterval,
                        maxOutputBytes: Int) -> AgentProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        do { try process.run() } catch {
            return AgentProcessResult(exitCode: -1, stdout: "",
                                      stderr: "无法启动 \(executable)：\(error.localizedDescription)",
                                      timedOut: false)
        }

        // stdin：写完立刻关，否则读 stdin 的脚本会一直等。
        if let standardInput, let data = standardInput.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()

        let lock = NSLock()
        var outData = Data(), errData = Data()
        let group = DispatchGroup()

        func drain(_ handle: FileHandle, into sink: @escaping (Data) -> Void) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    sink(chunk)
                }
                group.leave()
            }
        }
        drain(outPipe.fileHandleForReading) { chunk in
            lock.lock()
            if outData.count < maxOutputBytes { outData.append(chunk) }
            lock.unlock()
        }
        drain(errPipe.fileHandleForReading) { chunk in
            lock.lock()
            if errData.count < maxOutputBytes { errData.append(chunk) }
            lock.unlock()
        }

        // 超时看门狗：先 SIGTERM 给个体面退出的机会，2s 后 SIGKILL。
        var timedOut = false
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut = true
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        group.wait()

        lock.lock()
        let out = String(decoding: outData.prefix(maxOutputBytes), as: UTF8.self)
        let err = String(decoding: errData.prefix(maxOutputBytes), as: UTF8.self)
        lock.unlock()

        return AgentProcessResult(exitCode: process.terminationStatus,
                                  stdout: out, stderr: err, timedOut: timedOut)
    }

    public static func run(executable: String,
                          arguments: [String],
                          currentDirectory: String? = nil,
                          standardInput: String? = nil,
                          timeout: TimeInterval = 45,
                          maxOutputBytes: Int = 200_000) async -> AgentProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runSync(executable: executable,
                                     arguments: arguments,
                                     currentDirectory: currentDirectory,
                                     standardInput: standardInput,
                                     timeout: timeout,
                                     maxOutputBytes: maxOutputBytes)
                continuation.resume(returning: result)
            }
        }
    }
}

// MARK: - 参数与输出的公共辅助

enum AgentToolText {
    /// 回给模型的内容上限。工具输出（尤其 list/search）能轻松几十 KB，
    /// 原样回传等于把上下文烧光还拖慢下一轮。
    static let maxToolOutput = 8_000

    static func truncated(_ text: String, limit: Int = maxToolOutput) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…（输出已截断，共 \(text.count) 字符）"
    }
}

// MARK: - 内置 CLI 工具

public final class AgentBuiltinTools {
    /// CLI 的正式安装路径（软链指向 App bundle 内的 clipslots-cli）。
    public static let defaultCLIPath = "/usr/local/bin/clipslots"

    private let cliPath: String
    private let runner: (String, [String]) async -> AgentProcessResult

    public init(cliPath: String = AgentBuiltinTools.defaultCLIPath,
                runner: ((String, [String]) async -> AgentProcessResult)? = nil) {
        self.cliPath = cliPath
        self.runner = runner ?? { path, args in
            await AgentProcessRunner.run(executable: path, arguments: args, timeout: 30)
        }
    }

    public var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: cliPath) }

    // MARK: Schema

    private static let pageProperty: JSONValue = .object([
        "type": .string("string"),
        "description": .string("页面名称或页面 ID，可省略（省略则用当前默认页面）。"),
    ])
    private static let groupProperty: JSONValue = .object([
        "type": .string("string"),
        "description": .string("槽位组名称或组 ID，可省略（省略则用 default 组）。"),
    ])
    private static let slotProperty: JSONValue = .object([
        "type": .string("integer"),
        "description": .string("槽位序号，从 1 开始（通常 1..10）。"),
    ])

    public func specs() -> [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "list_slots",
                description: "列出槽位摘要（序号、是否为空、内容预览、类型、附件数）。只给 page 不给 group 时，列出该页面下所有组。",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["page": Self.pageProperty, "group": Self.groupProperty]),
                ]),
                originLabel: "内置"),
            AgentToolSpec(
                name: "read_slot",
                description: "读取单个槽位的完整内容（纯文本、类型、标签、附件数）。",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["page": Self.pageProperty,
                                           "group": Self.groupProperty,
                                           "slot": Self.slotProperty]),
                    "required": .array([.string("slot")]),
                ]),
                originLabel: "内置"),
            AgentToolSpec(
                name: "write_slot",
                description: "向槽位写入纯文本（保留已有附件）。默认覆盖原文本；if_empty=true 时只写空槽，槽位非空会返回 SLOT_NOT_EMPTY。",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "page": Self.pageProperty,
                        "group": Self.groupProperty,
                        "slot": Self.slotProperty,
                        "text": .object(["type": .string("string"),
                                         "description": .string("要写入的纯文本内容。")]),
                        "label": .object(["type": .string("string"),
                                          "description": .string("可选标签，建议不超过 6 个字。")]),
                        "if_empty": .object(["type": .string("boolean"),
                                             "description": .string("仅当槽位为空时写入，默认 false（覆盖）。")]),
                    ]),
                    "required": .array([.string("slot"), .string("text")]),
                ]),
                originLabel: "内置"),
            AgentToolSpec(
                name: "search_slots",
                description: "在槽位预览/正文/标签/附件名里做大小写不敏感子串搜索。默认搜当前组，all_groups=true 时搜所有组。",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string"),
                                          "description": .string("搜索关键词。")]),
                        "page": Self.pageProperty,
                        "group": Self.groupProperty,
                        "all_groups": .object(["type": .string("boolean"),
                                               "description": .string("是否跨所有组搜索，默认 false。")]),
                        "limit": .object(["type": .string("integer"),
                                          "description": .string("返回条数上限，默认 50。")]),
                    ]),
                    "required": .array([.string("query")]),
                ]),
                originLabel: "内置"),
            // 下面两个不在最初需求里，但没有它们模型根本不知道页面/组叫什么，
            // 只能瞎猜名字然后连环报错。属于"让前四个工具真正可用"的前提。
            AgentToolSpec(
                name: "list_groups",
                description: "列出槽位组。可用 page 限定某个页面下的组。想知道有哪些组名时先调它。",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["page": Self.pageProperty]),
                ]),
                originLabel: "内置"),
            AgentToolSpec(
                name: "list_pages",
                description: "列出所有页面。想知道有哪些页面名时先调它。",
                parameters: .object([
                    "type": .string("object"), "properties": .object([:]),
                ]),
                originLabel: "内置"),
        ]
    }

    public var toolNames: Set<String> { Set(specs().map(\.name)) }

    // MARK: 执行

    public func execute(call: AgentToolCall) async -> AgentToolResult {
        guard isAvailable else {
            return .failure("找不到可执行的 ClipSlots CLI（\(cliPath)）。请重新安装 App 以恢复命令行工具。",
                            code: "CLI_MISSING")
        }
        let args: JSONValue
        do { args = try call.arguments() } catch {
            return .failure("工具参数不是合法 JSON：\(call.argumentsJSON.prefix(200))", code: "BAD_ARGUMENTS")
        }

        var argv: [String]
        switch call.name {
        case "list_slots":
            argv = ["list"] + scopeArgs(args, includeGroup: true)
        case "list_groups":
            argv = ["groups"] + scopeArgs(args, includeGroup: false)
        case "list_pages":
            argv = ["pages"]
        case "read_slot":
            guard let slot = args["slot"]?.intValue else {
                return .failure("缺少 slot 参数（1 起的整数）。", code: "MISSING_SLOT")
            }
            guard slot >= 1, slot <= 99 else {
                return .failure("slot 超出范围：\(slot)（应为 1 起的正整数）。", code: "SLOT_OUT_OF_RANGE")
            }
            argv = ["read", String(slot)] + scopeArgs(args, includeGroup: true)
        case "write_slot":
            guard let slot = args["slot"]?.intValue else {
                return .failure("缺少 slot 参数（1 起的整数）。", code: "MISSING_SLOT")
            }
            // 这里只做形状上的兜底（1 起的正整数）。真正的上界是每组槽位数（config.slots，
            // 可配置），由 CLI 按实际配置校验并回结构化错误——本地写死 10 会把合法的
            // 大槽位号误判掉，反而误导模型去"修正"一个正确的参数。
            guard slot >= 1, slot <= 99 else {
                return .failure("slot 超出范围：\(slot)（应为 1 起的正整数）。", code: "SLOT_OUT_OF_RANGE")
            }
            guard let text = args["text"]?.stringValue else {
                return .failure("缺少 text 参数（要写入的纯文本）。", code: "MISSING_TEXT")
            }
            argv = ["write", String(slot), "--text", text] + scopeArgs(args, includeGroup: true)
            if let label = args["label"]?.stringValue, !label.isEmpty {
                argv += ["--label", label]
            }
            // --if-empty 与 --overwrite-text 互斥（CLI 层会拒绝同传），
            // 所以这里二选一：模型显式要求只写空槽 → --if-empty；
            // 否则用裸 write 走历史覆盖语义（用户明确说"直接改，不要反复确认"）。
            if args["if_empty"]?.boolValue == true { argv.append("--if-empty") }
        case "search_slots":
            // 空白查询要按"没传"处理：`isEmpty` 拦不住 "  "，而空格查询会把整库捞回来，
            // 输出被截断后模型还以为自己拿到了完整结果。
            let rawQuery = args["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let query = rawQuery, !query.isEmpty else {
                return .failure("缺少 query 参数。", code: "MISSING_QUERY")
            }
            argv = ["search", query] + scopeArgs(args, includeGroup: true)
            if args["all_groups"]?.boolValue == true { argv.append("--all-groups") }
            if let limit = args["limit"]?.intValue, limit > 0 { argv += ["--limit", String(limit)] }
        default:
            return .failure("未知的内置工具：\(call.name)", code: "UNKNOWN_TOOL")
        }

        let result = await runner(cliPath, argv)
        return Self.interpret(result: result, toolName: call.name)
    }

    /// page/group 作用域参数。
    /// `--page` 只吃 UUID，页面名要走 `--page-name`；模型给的多半是名字，
    /// 所以这里按形状自动分流，而不是要求模型先去查 ID。
    private func scopeArgs(_ args: JSONValue, includeGroup: Bool) -> [String] {
        var out: [String] = []
        if let page = args["page"]?.stringValue, !page.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmed = page.trimmingCharacters(in: .whitespaces)
            if UUID(uuidString: trimmed) != nil {
                out += ["--page", trimmed]
            } else {
                out += ["--page-name", trimmed]
            }
        }
        if includeGroup, let group = args["group"]?.stringValue,
           !group.trimmingCharacters(in: .whitespaces).isEmpty {
            // CLI 的 --group 本身就同时接受 id 与组名，不必分流。
            out += ["--group", group.trimmingCharacters(in: .whitespaces)]
        }
        return out
    }

    static func interpret(result: AgentProcessResult, toolName: String) -> AgentToolResult {
        if result.timedOut {
            return .failure("\(toolName) 执行超时（30s）。数据可能被其它写入占用，稍后重试。", code: "TIMEOUT")
        }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if stdout.isEmpty {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure("\(toolName) 没有输出（exit \(result.exitCode)）\(err.isEmpty ? "" : "：\(err)")",
                            code: "EMPTY_OUTPUT")
        }
        // CLI 恒定输出 JSON，且失败时 ok:false + exit 1。原样回传（截断后）：
        // 里面的 error_code 对模型比我们的转述有用得多。
        let content = AgentToolText.truncated(stdout)
        let failed = result.exitCode != 0
        let summary: String
        if failed {
            let code = (try? JSONValue.decode(jsonText: stdout))?["error_code"]?.stringValue
            summary = "失败\(code.map { "（\($0)）" } ?? "")"
        } else {
            summary = "完成"
        }
        return AgentToolResult(content: content, isFailure: failed, summary: summary)
    }
}

// MARK: - Skill 工具

public final class AgentSkillTools {
    /// 用户在 UI 里勾选启用的 Skill（未勾选的完全不可见、不可执行）。
    public private(set) var enabledSkills: [AgentSkill]

    public init(enabledSkills: [AgentSkill] = []) {
        self.enabledSkills = enabledSkills
    }

    public func update(enabledSkills: [AgentSkill]) {
        self.enabledSkills = enabledSkills
    }

    /// 结构化声明工具的名字前缀。加前缀是为了和内置工具、和别的 Skill 隔离命名空间。
    /// public 是为了让 smoke 能直接断言命名规则（它决定模型看到的工具名，改坏了很难察觉）。
    public static func declaredToolName(skillSlug: String, toolName: String) -> String {
        let safeTool = AgentSkillCatalog.slugify(toolName)
        let base = "skill_\(skillSlug)_\(safeTool.isEmpty ? "tool" : safeTool)"
        return String(base.prefix(64))
    }

    public func specs() -> [AgentToolSpec] {
        guard !enabledSkills.isEmpty else { return [] }

        var specs: [AgentToolSpec] = [
            AgentToolSpec(
                name: "list_skills",
                description: "列出当前已启用的 Skill（名称、简介、可执行脚本）。需要用某个 Skill 的能力时先调它，再用 read_skill 读取详细说明。",
                parameters: .object(["type": .string("object"), "properties": .object([:])]),
                originLabel: "Skill"),
            AgentToolSpec(
                name: "read_skill",
                description: "读取指定 Skill 的 SKILL.md 全文说明，里面写了它能做什么、怎么用命令完成。",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "skill": .object(["type": .string("string"),
                                          "description": .string("Skill 名称或 slug，取自 list_skills。")]),
                    ]),
                    "required": .array([.string("skill")]),
                ]),
                originLabel: "Skill"),
        ]

        // 只有确实存在脚本的时候才暴露执行工具——否则等于给模型一把没有锁孔的钥匙。
        if enabledSkills.contains(where: { !$0.scripts.isEmpty }) {
            specs.append(AgentToolSpec(
                name: "run_skill_script",
                description: "执行某个已启用 Skill 目录内的脚本。script 必须是 list_skills 返回的相对路径之一。",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "skill": .object(["type": .string("string"),
                                          "description": .string("Skill 名称或 slug。")]),
                        "script": .object(["type": .string("string"),
                                           "description": .string("Skill 目录内的脚本相对路径，如 scripts/foo.py。")]),
                        "args": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("命令行参数列表，可省略。"),
                        ]),
                        "stdin": .object(["type": .string("string"),
                                          "description": .string("可选，写给脚本标准输入的文本。")]),
                    ]),
                    "required": .array([.string("skill"), .string("script")]),
                ]),
                originLabel: "Skill"))
        }

        for skill in enabledSkills {
            for tool in skill.declaredTools {
                specs.append(AgentToolSpec(
                    name: Self.declaredToolName(skillSlug: skill.slug, toolName: tool.name),
                    description: tool.description.isEmpty
                        ? "来自 Skill「\(skill.name)」的工具 \(tool.name)。"
                        : "[\(skill.name)] \(tool.description)",
                    parameters: tool.parameters,
                    originLabel: skill.name))
            }
        }
        return specs
    }

    public var toolNames: Set<String> { Set(specs().map(\.name)) }

    // MARK: 执行

    public func execute(call: AgentToolCall) async -> AgentToolResult {
        let args = (try? call.arguments()) ?? .object([:])

        switch call.name {
        case "list_skills":
            let payload = JSONValue.object([
                "ok": .bool(true),
                "skills": .array(enabledSkills.map { skill in
                    .object([
                        "slug": .string(skill.slug),
                        "name": .string(skill.name),
                        "description": .string(skill.description),
                        "source": .string(skill.source.displayName),
                        "version": skill.version.map { JSONValue.string($0) } ?? .null,
                        "scripts": .array(skill.scripts.map { .string($0) }),
                        "declared_tools": .array(skill.declaredTools.map {
                            .string(Self.declaredToolName(skillSlug: skill.slug, toolName: $0.name))
                        }),
                    ])
                }),
            ])
            let text = (try? payload.encodedText(pretty: true)) ?? "{\"ok\":true,\"skills\":[]}"
            return AgentToolResult(content: AgentToolText.truncated(text),
                                   summary: "\(enabledSkills.count) 个 Skill")

        case "read_skill":
            guard let key = args["skill"]?.stringValue, let skill = resolve(key) else {
                return .failure("找不到已启用的 Skill：\(args["skill"]?.stringValue ?? "(空)")。先调 list_skills 看可用项。",
                                code: "SKILL_NOT_FOUND")
            }
            guard let raw = try? String(contentsOfFile: skill.markdownPath, encoding: .utf8) else {
                return .failure("无法读取 \(skill.markdownPath)", code: "SKILL_READ_FAILED")
            }
            // SKILL.md 常有几千字，给一个比普通工具输出更宽的额度，但仍要有上限。
            return AgentToolResult(content: AgentToolText.truncated(raw, limit: 16_000),
                                   summary: "已读取 \(skill.name)")

        case "run_skill_script":
            guard let key = args["skill"]?.stringValue, let skill = resolve(key) else {
                return .failure("找不到已启用的 Skill：\(args["skill"]?.stringValue ?? "(空)")", code: "SKILL_NOT_FOUND")
            }
            guard let script = args["script"]?.stringValue, !script.isEmpty else {
                return .failure("缺少 script 参数。", code: "MISSING_SCRIPT")
            }
            let extraArgs = args["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return await runScript(skill: skill,
                                   script: script,
                                   arguments: extraArgs,
                                   stdin: args["stdin"]?.stringValue)

        default:
            // 结构化声明的工具
            for skill in enabledSkills {
                for tool in skill.declaredTools
                where Self.declaredToolName(skillSlug: skill.slug, toolName: tool.name) == call.name {
                    return await runDeclared(tool: tool, in: skill, arguments: args)
                }
            }
            return .failure("未知的 Skill 工具：\(call.name)", code: "UNKNOWN_TOOL")
        }
    }

    func resolve(_ key: String) -> AgentSkill? {
        let needle = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return enabledSkills.first { $0.slug.lowercased() == needle }
            ?? enabledSkills.first { $0.name.lowercased() == needle }
            ?? enabledSkills.first { AgentSkillCatalog.slugify($0.name) == AgentSkillCatalog.slugify(needle) }
    }

    // MARK: 脚本执行（安全边界都在这儿）

    /// 允许直接执行的扩展名 → 解释器。没有 +x 位时用它启动；
    /// 白名单之外一律拒绝（避免被诱导执行二进制或 .command 之类）。
    static let interpreters: [String: String] = [
        "sh": "/bin/bash", "bash": "/bin/bash", "zsh": "/bin/zsh",
        "py": "/usr/bin/env", "js": "/usr/bin/env", "rb": "/usr/bin/env",
        "pl": "/usr/bin/env", "swift": "/usr/bin/env",
    ]
    static let envInterpreterArg: [String: String] = [
        "py": "python3", "js": "node", "rb": "ruby", "pl": "perl", "swift": "swift",
    ]

    /// 把"Skill 目录 + 相对路径"解析成一个**确定位于该目录内**的绝对路径。
    /// 这是防逃逸的唯一关口：先 standardize（吃掉 `..`），再做前缀比对。
    /// 注意用 resolvingSymlinksInPath 后的目录做基准——Agent 目录里的 Skill 本身就是软链，
    /// 不解析的话正常路径也会被误判成越界。
    /// public 是刻意的：这是"允许模型跑本机代码"唯一的闸门，
    /// 必须能在 smoke 里被直接、密集地打（`../` / 绝对路径 / `~` / 软链目录）。
    public static func resolveScriptPath(skillDirectory: String, script: String) -> String? {
        if script.hasPrefix("/") || script.hasPrefix("~") { return nil }
        let base = (skillDirectory as NSString).resolvingSymlinksInPath
        let candidate = ((base as NSString).appendingPathComponent(script) as NSString)
            .standardizingPath
        let resolved = (candidate as NSString).resolvingSymlinksInPath
        let root = base.hasSuffix("/") ? base : base + "/"
        guard resolved.hasPrefix(root) else { return nil }
        return resolved
    }

    private func runScript(skill: AgentSkill,
                           script: String,
                           arguments: [String],
                           stdin: String?) async -> AgentToolResult {
        guard let path = Self.resolveScriptPath(skillDirectory: skill.directory, script: script) else {
            return .failure("脚本路径越界或非法：\(script)。只能执行 Skill 目录内的相对路径。",
                            code: "SCRIPT_PATH_REJECTED")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return .failure("脚本不存在：\(script)", code: "SCRIPT_NOT_FOUND")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard Self.interpreters[ext] != nil else {
            return .failure("不允许执行 .\(ext) 文件（仅支持 \(Self.interpreters.keys.sorted().joined(separator: "/"))）。",
                            code: "SCRIPT_TYPE_REJECTED")
        }

        var executable: String
        var argv: [String]
        if fm.isExecutableFile(atPath: path) {
            executable = path
            argv = arguments
        } else if let envArg = Self.envInterpreterArg[ext] {
            executable = "/usr/bin/env"
            argv = [envArg, path] + arguments
        } else {
            executable = Self.interpreters[ext] ?? "/bin/bash"
            argv = [path] + arguments
        }

        let result = await AgentProcessRunner.run(executable: executable,
                                                 arguments: argv,
                                                 currentDirectory: skill.directory,
                                                 standardInput: stdin,
                                                 timeout: 60)
        return Self.wrap(result: result, label: "\(skill.name)/\(script)")
    }

    private func runDeclared(tool: AgentSkillDeclaredTool,
                             in skill: AgentSkill,
                             arguments: JSONValue) async -> AgentToolResult {
        // 占位符替换：{{key}} → 实参字符串。缺参不静默留 {{key}}（那会把字面量传进脚本），
        // 直接报错让模型补齐。
        var resolvedCommand: [String] = []
        for token in tool.command {
            var out = token
            while let range = out.range(of: "\\{\\{[A-Za-z0-9_\\-]+\\}\\}", options: .regularExpression) {
                let key = String(out[range]).dropFirst(2).dropLast(2)
                guard let value = arguments[String(key)], !value.isBlank else {
                    return .failure("缺少参数 \(key)（\(tool.name) 需要它）。", code: "MISSING_ARGUMENT")
                }
                let text = value.stringValue ?? (try? value.encodedText()) ?? ""
                out.replaceSubrange(range, with: text)
            }
            resolvedCommand.append(out)
        }

        guard let head = resolvedCommand.first else {
            return .failure("Skill 工具没有声明可执行命令。", code: "BAD_DECLARATION")
        }
        let rest = Array(resolvedCommand.dropFirst())

        var executable: String
        var argv: [String]
        if head.contains("/") {
            // 相对路径 → 必须在 Skill 目录内，和 run_skill_script 同一把关口。
            guard let path = Self.resolveScriptPath(skillDirectory: skill.directory, script: head) else {
                return .failure("命令路径越界：\(head)", code: "SCRIPT_PATH_REJECTED")
            }
            if FileManager.default.isExecutableFile(atPath: path) {
                executable = path; argv = rest
            } else {
                let ext = (path as NSString).pathExtension.lowercased()
                guard let envArg = Self.envInterpreterArg[ext] else {
                    return .failure("无法执行 \(head)：既没有可执行位，也不是支持的脚本类型。",
                                    code: "SCRIPT_TYPE_REJECTED")
                }
                executable = "/usr/bin/env"; argv = [envArg, path] + rest
            }
        } else {
            // 裸命令名（python3 / node / clipslots…）→ 交给 env 在 PATH 里找。
            // 不做命令白名单：Skill 已经由用户显式启用，等价于用户授权。
            executable = "/usr/bin/env"; argv = [head] + rest
        }

        // 未被占位符消费的参数整体从 stdin 给一份 JSON，脚本可选读取。
        let stdinJSON = try? arguments.encodedText()
        let result = await AgentProcessRunner.run(executable: executable,
                                                 arguments: argv,
                                                 currentDirectory: skill.directory,
                                                 standardInput: stdinJSON,
                                                 timeout: 60)
        return Self.wrap(result: result, label: "\(skill.name)/\(tool.name)")
    }

    static func wrap(result: AgentProcessResult, label: String) -> AgentToolResult {
        if result.timedOut {
            return .failure("\(label) 执行超时（60s），已终止。", code: "TIMEOUT")
        }
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode != 0 {
            let detail = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
            return .failure("\(label) 退出码 \(result.exitCode)\(detail.isEmpty ? "" : "：\n\(AgentToolText.truncated(detail, limit: 2_000))")",
                            code: "SCRIPT_FAILED")
        }
        // stderr 里常有正常日志，成功时一并回传但排在后面。
        let combined = [out, err.isEmpty ? nil : "[stderr]\n\(err)"]
            .compactMap { $0 }.joined(separator: "\n")
        return AgentToolResult(content: AgentToolText.truncated(combined.isEmpty ? "(无输出)" : combined),
                               summary: "完成")
    }
}

// MARK: - 汇总注册表

public final class AgentToolRegistry: AgentToolExecuting {
    private let builtin: AgentBuiltinTools
    private let skills: AgentSkillTools

    public init(builtin: AgentBuiltinTools = AgentBuiltinTools(),
                skills: AgentSkillTools = AgentSkillTools()) {
        self.builtin = builtin
        self.skills = skills
    }

    public func update(enabledSkills: [AgentSkill]) {
        skills.update(enabledSkills: enabledSkills)
    }

    public func specs() -> [AgentToolSpec] {
        builtin.specs() + skills.specs()
    }

    public func execute(call: AgentToolCall) async -> AgentToolResult {
        if builtin.toolNames.contains(call.name) {
            return await builtin.execute(call: call)
        }
        return await skills.execute(call: call)
    }
}
