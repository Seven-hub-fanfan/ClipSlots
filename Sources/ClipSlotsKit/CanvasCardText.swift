import Foundation

/// 画布节点卡片上的**文字加工**（v2.11.8 二轮）。
///
/// 两件事都是纯字符串处理，所以放 Kit 并被 smoke 断言覆盖：它们的翻车方式是"少一行 / 多一个竖线"，
/// 在 UI 上看起来只是排版有点怪，不会报错，靠肉眼很难发现回归。
public enum CanvasCardText {

    // MARK: - 正文预览：去掉 Markdown 原始标记

    /// 卡片正文预览的行数**下限**（用户指定至少 4 行）。
    ///
    /// ★ v2.11.9：语义从“上限”改成“默认值 / 下限”。真正显示几行由卡片正文区**实际高度**
    /// 决定（见 `CanvasNodeCardView.promptLineLimit`）—— 把 4 当上限用了之后，默认高度的节点里
    /// 正文下面永远空着一大片（用户截图 image-242bbdf5 的红框）。
    public static let previewLineLimit = 4

    /// 预览行数的硬上限（★ v2.11.9）。
    ///
    /// 自适应行数需要一个封顶，否则一个被拘得很高的节点 + 小字号会把整篇 prompt（几千字）
    /// 都排到卡片上：字串加工和文本排版的开销会随行数线性增长，而“在画布上认出这个节点”
    /// 这个目的在二十多行处已经饫和。
    public static let previewLineCap = 28

    /// 把槽位正文变成**适合在卡片上直接读**的若干行纯文本。
    ///
    /// 用户的原始反馈是「去掉 Markdown 表格等原始模板字样」。槽位里常常存的是给模型用的
    /// prompt 模板，里面混着 `| 字段 | 值 |` 表格、`---` 分隔线、`###` 标题、```` ``` ```` 代码栅栏。
    /// 这些标记在编辑器里有意义，在一个 300pt 宽的卡片上只是噪声：一屏四行全被竖线和短横占满，
    /// 真正的内容一个字都看不到。
    ///
    /// 处理规则（顺序有意义）：
    ///   1. 整行丢弃：代码栅栏、表格分隔行（`|---|:--:|`）、纯分隔线（`---` / `***` / `___`）。
    ///   2. 表格数据行 `| a | b |` → 拆成 `a · b`（保留内容、丢掉框线）。
    ///   3. 行首标记剥离：`#` 标题、`>` 引用、`-`/`*`/`+` 列表符、有序列表 `1.`。
    ///   4. 行内标记剥离：`**粗体**` / `*斜体*` / `` `代码` `` 的包裹符号。
    ///   5. 折叠空白、丢弃空行，取前 `limit` 行。
    ///
    /// **刻意不做的事**：不解析 Markdown 语法树。这里要的不是渲染，是"把噪声抹平"，
    /// 一个能被断言钉住的正则级清洗足够，引一个解析器进来反而多一份失败模式。
    public static func previewLines(_ text: String, limit: Int = previewLineLimit) -> [String] {
        guard limit > 0 else { return [] }
        var out: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // 1) 整行丢弃
            if line.hasPrefix("```") || line.hasPrefix("~~~") { continue }
            if isTableSeparator(line) { continue }
            if isThematicBreak(line) { continue }

            var body = line

            // 2) 表格数据行 → 用 · 连接单元格
            if body.hasPrefix("|") {
                let cells = body
                    .split(separator: "|", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if cells.isEmpty { continue }
                body = cells.joined(separator: " · ")
            }

            // 3) 行首标记
            body = stripLeadingMarkers(body)
            // 4) 行内标记
            body = stripInlineMarkers(body)
            // 5) 折叠空白
            body = body.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            body = body.trimmingCharacters(in: .whitespaces)

            if body.isEmpty { continue }
            out.append(body)
            if out.count == limit { break }
        }
        return out
    }

    /// `previewLines` 的换行拼接版，直接喂给 SwiftUI 的 `Text`。
    public static func previewText(_ text: String, limit: Int = previewLineLimit) -> String {
        previewLines(text, limit: limit).joined(separator: "\n")
    }

    /// 表格分隔行：只由 `|`、`-`、`:`、空格组成，且至少有一个 `-`。
    static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("-"), line.contains("|") else { return false }
        return line.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    /// 主题分隔线：`---` / `***` / `___`（3 个及以上同字符）。
    static func isThematicBreak(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        for ch in ["-", "*", "_"] where compact.allSatisfy({ String($0) == ch }) {
            return true
        }
        return false
    }

    static func stripLeadingMarkers(_ line: String) -> String {
        var s = Substring(line)
        // 标题 #
        while s.first == "#" { s = s.dropFirst() }
        // 引用 >
        while s.first == ">" { s = s.dropFirst() }
        s = Substring(s.trimmingCharacters(in: .whitespaces))
        // 无序列表符：必须后跟空格，否则 "-30%" 这类内容会被吃掉第一个字符
        if let f = s.first, f == "-" || f == "*" || f == "+" {
            let rest = s.dropFirst()
            if rest.first == " " { s = Substring(rest.trimmingCharacters(in: .whitespaces)) }
        }
        // 有序列表 "1." / "12)"
        let digits = s.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let afterDigits = s.dropFirst(digits.count)
            if let sep = afterDigits.first, sep == "." || sep == ")" {
                let rest = afterDigits.dropFirst()
                if rest.first == " " || rest.isEmpty {
                    s = Substring(rest.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return String(s)
    }

    static func stripInlineMarkers(_ line: String) -> String {
        var s = line
        // 顺序：先长后短，否则 "**x**" 会被单星号规则拆成 "*x*"
        for token in ["***", "**", "*", "__", "`", "~~"] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        return s
    }

    // MARK: - 顶部路径标识

    /// 节点卡片左上角原本是「图像生成」这类**类型**标签。用户要求换成槽位的**原始出处**：
    /// `页面 - 槽位组 - 槽位`，居中排版。
    ///
    /// 理由是合理的：类型信息在卡片的形态上已经写着了（有没有图、有没有轮播），而"这个节点动的是
    /// 哪一页哪一组的第几号槽位"在画布上完全无从得知 —— 而它恰恰是误改数据时最想确认的一件事。
    ///
    /// - Parameters:
    ///   - pageName: 页面名。空/nil 时该段省略。
    ///   - groupName: 槽位组名。空/nil 时该段省略。
    ///   - slot: 槽位号（1 起）。
    ///   - isUnfiled: 是否是「未入库」保留组里的节点。是则整个标识退化成 `未入库 - N`
    ///     （未入库不属于任何用户页面，硬凑一个页面名只会造成误导）。
    public static func pathLabel(pageName: String?,
                                 groupName: String?,
                                 slot: Int,
                                 isUnfiled: Bool = false) -> String {
        if isUnfiled { return "未入库 - \(slot)" }
        var parts: [String] = []
        if let p = pageName?.trimmingCharacters(in: .whitespaces), !p.isEmpty { parts.append(p) }
        if let g = groupName?.trimmingCharacters(in: .whitespaces), !g.isEmpty { parts.append(g) }
        parts.append("\(slot)")
        return parts.joined(separator: " - ")
    }
}
