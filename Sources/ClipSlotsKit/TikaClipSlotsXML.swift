import Foundation

// MARK: - ClipSlots × Tika 的 XML 工具契约
//
// v2.17.7 起，Tika 后端不用 OpenAI tool_calls，而是用一段"提示词软契约 + App 端拦截 XML"的
// 组合来触达本机 ClipSlots CLI。约定长这样（详见 docs/tika-agent-system-prompt.md）：
//
//   <clipslots-call cmd="clipslots list --json"/>
//
// 拿到 assistant 完整文本后，App 端要做的三件事全在这个文件里：
//
//   1. **精确提取** —— 只识别 `<clipslots-call cmd="..."/>` 单标签形式（提示词里也只让它这么写），
//      提取 `cmd` 属性字符串。**忍受** `&quot;` / `&amp;` / `&lt;` / `&gt;` / `&apos;`
//      这五种最常见的实体转义（模型会用它们来嵌双引号）。
//
//   2. **词法切分** —— 把 cmd 字符串按 POSIX shell 词法切成 argv 数组（支持 `"..."` / `'...'`
//      / 反斜杠转义）。**不**通过 `/bin/sh -c` 跑；shell 特殊字符如 `;`、`|`、`&&`、`` ` ``
//      对我们而言只是普通字符，没有注入面。
//
//   3. **白名单校验** —— argv[0] 必须是 `clipslots`（或干脆不写，直接从子命令起头也认），
//      第一个子命令必须在白名单里。任何越界写法都返回结构化错误让上层原样回喂给 Agent。
//
// 拒执行的失败结果用 `<clipslots-result ok="false" code="...">` 序列化，让 Agent 学会自救。
//
// 这个文件**只做纯字符串处理**：不跑 Process、不读文件系统、不碰 UI。全部行为 smoke 可测。

// MARK: - 白名单

/// ClipSlots CLI 允许在 Tika XML 契约里调用的**全部**子命令。
///
/// 这个集合是"给模型开的最小闸门"，凡是模型可能编出来但 CLI 里没有的（`set`、`update`、
/// `add`、`edit`、`remove`、`mv`、`cp`、`ls`、`sudo`、`rm`……）一律不在此列，被拒后回喂
/// `COMMAND_NOT_ALLOWED`，让 Agent 自己纠正。
///
/// 增补规则：必须同时改 `docs/tika-agent-system-prompt.md` 的白名单表，否则模型行为
/// 与 App 拦截层会背离，用户看到的错误码就没办法自愈。
public enum ClipSlotsCommandGuard {

    /// 允许直接调用的子命令。所有名字与 `clipslots --help` 里列出的子命令**大小写、连字符**完全一致。
    public static let allowedCommands: Set<String> = [
        // 只读
        "list", "groups", "pages", "read", "search", "version", "help",
        // 写正文
        "write", "clear", "paste",
        // 组织
        "create-group", "create-page", "rename-group",
        // 删除（破坏性）
        "delete-group", "delete-page",
        // 附件与缩略图
        "write-attachment", "set-thumbnail", "clear-thumbnail",
        // 维护
        "repair-index",
    ]

    public static func isAllowed(_ command: String) -> Bool {
        allowedCommands.contains(command)
    }
}

// MARK: - 结构化调用

/// 提取到的一次 clipslots 调用。**argv 是 clipslots 本体后面的参数**（不含 "clipslots"）。
public struct ClipSlotsToolCall: Equatable, Sendable {
    /// 从 XML 里提取的原始 cmd 属性（未做 shell-lex）。保留原文方便报错时回显给 Agent。
    public let rawCommand: String
    /// 已经过 shell-lex 且白名单校验的 argv。给 clipslots CLI 直传。
    /// 例：`["list", "--page-name", "灵感", "--json"]`
    public let argv: [String]
    /// argv[0] 也就是首个子命令（白名单成员）。冗余存一份方便 UI 显示"这次调的是 list"。
    public var subcommand: String { argv.first ?? "" }

    public init(rawCommand: String, argv: [String]) {
        self.rawCommand = rawCommand
        self.argv = argv
    }
}

/// 拦截失败时的原因。code 是 stable、给 Agent 自愈用的；message 给 UI 展示。
public struct ClipSlotsToolExtractionError: Equatable, Sendable {
    public let rawCommand: String
    public let code: String
    public let message: String

    public init(rawCommand: String, code: String, message: String) {
        self.rawCommand = rawCommand
        self.code = code
        self.message = message
    }
}

/// 一次扫描出的所有结果，按在文本里出现的顺序。
public struct ClipSlotsToolExtraction: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public enum Payload: Equatable, Sendable {
            case ok(ClipSlotsToolCall)
            case error(ClipSlotsToolExtractionError)
        }
        public let payload: Payload
        /// XML 标签在原文中的字符范围（供上层做"把 assistant 文本里 XML 替换成人类可读描述"的渲染）。
        public let range: Range<String.Index>
    }
    public var items: [Item]

    public var callsOnly: [ClipSlotsToolCall] {
        items.compactMap { if case let .ok(c) = $0.payload { return c } else { return nil } }
    }
    public var errorsOnly: [ClipSlotsToolExtractionError] {
        items.compactMap { if case let .error(e) = $0.payload { return e } else { return nil } }
    }
    public var isEmpty: Bool { items.isEmpty }
}

// MARK: - 扫描器

/// 从一段 assistant 文本里把所有 `<clipslots-call ... />` 依次提取出来。
///
/// 为什么手写扫描而不是 `XMLParser`：assistant 文本里 XML 是"混在自然语言里的片段"，
/// 前后可能有 markdown、代码块、中文标点；`XMLParser` 要求整段是 well-formed XML，
/// 我们只想在一大坨字里找形状为 `<clipslots-call cmd="..."/>` 的片段。手写扫描更贴需求。
///
/// 支持两种形态：
///   - 自闭合：`<clipslots-call cmd="..."/>`  ← 提示词强制这种
///   - 双标签：`<clipslots-call cmd="...">...</clipslots-call>` ← 也接（宽容）
public enum ClipSlotsToolScanner {

    public static func scan(_ text: String) -> ClipSlotsToolExtraction {
        var items: [ClipSlotsToolExtraction.Item] = []
        var searchRange = text.startIndex..<text.endIndex

        while let openRange = text.range(of: "<clipslots-call", range: searchRange) {
            // 找到本次 tag 的结束位置：`/>` 或 `>` （后者再吃到 `</clipslots-call>`）
            // 但 attribute 值里可能出现 `>`，所以要扫过引号里的部分。
            let closeIndex = findTagClose(in: text, from: openRange.upperBound)
            guard let tagCloseIndex = closeIndex else {
                // 没找到结束——tag 未闭合，剩下的都当没找到
                break
            }

            // 判定是否自闭合（tagCloseIndex 前一位是 `/`）
            let tagBody = text[openRange.upperBound..<tagCloseIndex]

            // 找 cmd="..."
            let cmd = extractCmdAttribute(from: String(tagBody))

            // 计算完整 XML 片段的范围（供上层替换用）
            let fullEndIndex: String.Index
            if String(tagBody).hasSuffix("/") {
                fullEndIndex = text.index(after: tagCloseIndex)
            } else {
                // 双标签形式：吃到 </clipslots-call>
                if let closeTagRange = text.range(of: "</clipslots-call>",
                                                  range: tagCloseIndex..<text.endIndex) {
                    fullEndIndex = closeTagRange.upperBound
                } else {
                    fullEndIndex = text.index(after: tagCloseIndex)
                }
            }

            let fullRange = openRange.lowerBound..<fullEndIndex
            let rawCommand = cmd ?? ""

            if let cmd = cmd {
                switch parseAndGuard(rawCommand: cmd) {
                case .success(let call):
                    items.append(.init(payload: .ok(call), range: fullRange))
                case .failure(let error):
                    items.append(.init(payload: .error(error), range: fullRange))
                }
            } else {
                items.append(.init(
                    payload: .error(.init(rawCommand: "",
                                          code: "MISSING_CMD_ATTRIBUTE",
                                          message: "<clipslots-call> 标签缺少 cmd 属性。")),
                    range: fullRange))
            }

            searchRange = fullEndIndex..<text.endIndex
        }

        return ClipSlotsToolExtraction(items: items)
    }

    /// 从 `<clipslots-call` 之后开始扫，找到本 tag 的收尾 `>`（自闭合或普通）。
    /// 扫描过程中会跳过双引号 / 单引号里的内容，避免 attribute 值里的 `>` 误判。
    private static func findTagClose(in text: String, from start: String.Index) -> String.Index? {
        var i = start
        var inDouble = false
        var inSingle = false
        while i < text.endIndex {
            let c = text[i]
            if inDouble {
                if c == "\"" { inDouble = false }
            } else if inSingle {
                if c == "'" { inSingle = false }
            } else {
                if c == "\"" { inDouble = true }
                else if c == "'" { inSingle = true }
                else if c == ">" { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// 从 tag body（`<clipslots-call` 与 `>` 之间的部分）里抠 `cmd="..."` 或 `cmd='...'`。
    /// 只支持 XML 属性最规范的两种引号形态；等号两侧可以有空格。
    private static func extractCmdAttribute(from tagBody: String) -> String? {
        // 找 `cmd`
        guard let cmdRange = tagBody.range(of: "cmd") else { return nil }
        var i = cmdRange.upperBound
        // 跳过空白
        while i < tagBody.endIndex, tagBody[i].isWhitespace { i = tagBody.index(after: i) }
        guard i < tagBody.endIndex, tagBody[i] == "=" else { return nil }
        i = tagBody.index(after: i)
        while i < tagBody.endIndex, tagBody[i].isWhitespace { i = tagBody.index(after: i) }
        guard i < tagBody.endIndex else { return nil }
        let quote = tagBody[i]
        guard quote == "\"" || quote == "'" else { return nil }
        i = tagBody.index(after: i)

        var value = ""
        while i < tagBody.endIndex {
            let c = tagBody[i]
            if c == quote { return decodeXMLEntities(value) }
            value.append(c)
            i = tagBody.index(after: i)
        }
        return nil // 未闭合引号
    }

    /// 只处理 5 种最常见的 XML 实体，覆盖模型可能用来嵌双引号的所有写法。
    private static func decodeXMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: 词法切分 + 白名单

    private enum ParseResult {
        case success(ClipSlotsToolCall)
        case failure(ClipSlotsToolExtractionError)
    }

    private static func parseAndGuard(rawCommand: String) -> ParseResult {
        let tokens: [String]
        do {
            tokens = try shellSplit(rawCommand)
        } catch {
            return .failure(.init(rawCommand: rawCommand,
                                  code: "MALFORMED_CMD",
                                  message: "cmd 属性词法解析失败：\(error.localizedDescription)"))
        }

        var argv = tokens
        // 允许写 `clipslots list ...` 也允许直接 `list ...`
        if let first = argv.first, first == "clipslots" || first.hasSuffix("/clipslots") {
            argv.removeFirst()
        }
        guard let sub = argv.first else {
            return .failure(.init(rawCommand: rawCommand,
                                  code: "EMPTY_COMMAND",
                                  message: "cmd 属性为空或只写了 'clipslots'，缺少子命令。"))
        }
        guard ClipSlotsCommandGuard.isAllowed(sub) else {
            return .failure(.init(rawCommand: rawCommand,
                                  code: "COMMAND_NOT_ALLOWED",
                                  message: "子命令 '\(sub)' 不在白名单里。允许的子命令见提示词速查表。"))
        }
        return .success(.init(rawCommand: rawCommand, argv: argv))
    }
}

// MARK: - POSIX shell-lex（够用即可，不追求完整实现）

/// POSIX 词法分析出错的原因。目前只有一种。
public struct ShellSplitError: Error, LocalizedError, Equatable {
    public let reason: String
    public var errorDescription: String? { reason }
}

/// 一个够用的 shell-lex：
/// - 空白（空格 / 制表 / 换行）分隔 token；
/// - `"..."` 与 `'...'` 都支持；`"..."` 内允许反斜杠转义 `\"`、`\\`、`\n`（转成真换行）；
/// - `'...'` 内不做任何转义（POSIX 语义）；
/// - 未闭合的引号 → 抛错，返回 `MALFORMED_CMD`。
///
/// 刻意**不实现**：变量插值 `$X`、命令替换 `` `...` ``、glob。用户的场景里都用不到，
/// 而且不实现等于关掉这几个注入面。
public func shellSplit(_ input: String) throws -> [String] {
    enum State { case outside, unquoted, doubleQuoted, singleQuoted }

    var tokens: [String] = []
    var current = ""
    var state: State = .outside
    var i = input.startIndex

    func push() {
        if !current.isEmpty { tokens.append(current); current = "" }
    }

    while i < input.endIndex {
        let c = input[i]
        switch state {
        case .outside:
            if c.isWhitespace {
                // 保持在 outside
            } else if c == "\"" {
                state = .doubleQuoted
            } else if c == "'" {
                state = .singleQuoted
            } else if c == "\\" {
                // outside 状态遇到反斜杠 = POSIX "开始一个新 token，转义下一个字符"
                i = input.index(after: i)
                guard i < input.endIndex else {
                    throw ShellSplitError(reason: "命令末尾有未完成的反斜杠转义")
                }
                current.append(input[i])
                state = .unquoted
            } else {
                current.append(c)
                state = .unquoted
            }
        case .unquoted:
            if c.isWhitespace {
                push()
                state = .outside
            } else if c == "\"" {
                state = .doubleQuoted
            } else if c == "'" {
                state = .singleQuoted
            } else if c == "\\" {
                // 反斜杠转义下一个字符
                i = input.index(after: i)
                guard i < input.endIndex else {
                    throw ShellSplitError(reason: "命令末尾有未完成的反斜杠转义")
                }
                current.append(input[i])
            } else {
                current.append(c)
            }
        case .doubleQuoted:
            if c == "\"" {
                state = .unquoted
            } else if c == "\\" {
                i = input.index(after: i)
                guard i < input.endIndex else {
                    throw ShellSplitError(reason: "双引号内有未完成的反斜杠转义")
                }
                let n = input[i]
                switch n {
                case "n": current.append("\n")
                case "t": current.append("\t")
                case "r": current.append("\r")
                default: current.append(n)  // \\ \" \/ 等原样保留后一个字符
                }
            } else {
                current.append(c)
            }
        case .singleQuoted:
            if c == "'" {
                state = .unquoted
            } else {
                current.append(c)
            }
        }
        i = input.index(after: i)
    }

    switch state {
    case .outside:
        break
    case .unquoted:
        push()
    case .doubleQuoted:
        throw ShellSplitError(reason: "未闭合的双引号")
    case .singleQuoted:
        throw ShellSplitError(reason: "未闭合的单引号")
    }

    return tokens
}

// MARK: - 结果回喂

/// 一次 clipslots 命令执行完毕的结构化结果。**stdout 会原样进 CDATA**，Agent 自己去解那段 JSON。
public struct ClipSlotsToolExecutionResult: Sendable {
    public let ok: Bool
    /// 结构化 code。成功时可为空；失败时优先来自 CLI stdout 的 `error_code`，回退用扫描器/拦截器给的 code。
    public let code: String
    /// 子进程退出码。超时/杀掉时约定为 -1。
    public let exitCode: Int32
    /// 子进程 stdout 原文——一般是 JSON，Agent 自己解析。
    public let stdout: String
    /// 子进程 stderr 原文——只在失败时对 Agent 有用；成功时也带上无害。
    public let stderr: String
    /// 是否是超时。
    public let timedOut: Bool

    public init(ok: Bool, code: String, exitCode: Int32,
                stdout: String, stderr: String, timedOut: Bool) {
        self.ok = ok
        self.code = code
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    /// 直接对应 CLI 拦截失败（还没到执行阶段）的构造。
    public static func rejection(_ error: ClipSlotsToolExtractionError) -> ClipSlotsToolExecutionResult {
        .init(ok: false, code: error.code, exitCode: -2,
              stdout: "", stderr: error.message, timedOut: false)
    }
}

/// 生成回喂 XML。Tika 端只识别自然语言，把它作为下一轮 user 消息发过去即可。
///
/// **CDATA 里不能出现 `]]>`**——如果 stdout 恰好含 `]]>`（几乎不可能，clipslots 输出都是 JSON），
/// 用 `]]]]><![CDATA[>` 分割规避。
public enum ClipSlotsResultEnvelope {

    public static func render(_ result: ClipSlotsToolExecutionResult,
                              command: String) -> String {
        let okAttr = result.ok ? "true" : "false"
        let codeAttr = escapeXMLAttr(result.code)
        let cmdAttr = escapeXMLAttr(command)
        let payload = escapeCDATA(result.stdout.isEmpty && !result.ok
                                    ? "stderr: " + result.stderr
                                    : result.stdout)

        return """
        <clipslots-result ok="\(okAttr)" code="\(codeAttr)" exit="\(result.exitCode)" cmd="\(cmdAttr)">
        <![CDATA[\(payload)]]>
        </clipslots-result>
        """
    }

    private static func escapeXMLAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeCDATA(_ s: String) -> String {
        // 用 CDATA 分割规避 `]]>`
        s.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
    }
}
