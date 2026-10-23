import SwiftUI
import AppKit

/// Shared by live output and saved messages so completing a turn does not change its typography.
enum AgentTextStyle: Equatable {
    case body, compact, reasoning

    var size: CGFloat { self == .body ? 15 : 13 }
    var lineSpacing: CGFloat { self == .body ? 6 : 5 }
    var blockSpacing: CGFloat { self == .body ? 12 : 9 }
    func headingSize(_ level: Int) -> CGFloat {
        size + (level == 1 ? 5 : level == 2 ? 3 : 1)
    }
}

/// Block structure is presentation-only; original messages remain untouched for copy and persistence.
enum AgentMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case list(marker: String, depth: Int, text: String)
    case quote(String)
    case code(language: String, text: String)
    case divider

    static func parse(_ text: String) -> [Self] {
        var blocks: [Self] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: (character: Character, length: Int, language: String)?
        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll(keepingCapacity: true)
            }
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = fence {
                let run = trimmed.prefix(while: { $0 == current.character })
                if run.count >= current.length && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks.append(.code(language: current.language, text: code.joined(separator: "\n")))
                    code.removeAll(keepingCapacity: true)
                    fence = nil
                } else { code.append(line) }
                continue
            }
            if let first = trimmed.first, first == "`" || first == "~" {
                let length = trimmed.prefix(while: { $0 == first }).count
                if length >= 3 {
                    flushParagraph()
                    fence = (first, length, String(trimmed.dropFirst(length)).trimmingCharacters(in: .whitespaces))
                    continue
                }
            }
            if trimmed.isEmpty { flushParagraph(); continue }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first?.isWhitespace == true {
                flushParagraph()
                blocks.append(.heading(hashes, String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)))
            } else if ["---", "***", "___"].contains(trimmed) {
                flushParagraph()
                blocks.append(.divider)
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                let content = String(trimmed.dropFirst(2))
                if case .quote(let previous) = blocks.last {
                    blocks[blocks.count - 1] = .quote(previous + "\n" + content)
                } else { blocks.append(.quote(content)) }
            } else if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
            } else if line.first?.isWhitespace == true,
                      case .list(let marker, let depth, let previous) = blocks.last,
                      paragraph.isEmpty {
                blocks[blocks.count - 1] = .list(marker: marker, depth: depth, text: previous + "\n" + trimmed)
            } else {
                paragraph.append(line)
            }
        }
        if let fence {
            // Incomplete fences are normal during streaming. Keep every received code byte visible.
            blocks.append(.code(language: fence.language, text: code.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private static func listItem(_ line: String) -> Self? {
        let indentation = line.prefix(while: { $0.isWhitespace })
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let content = line.trimmingCharacters(in: .whitespaces)
        let depth = min(indentation / 2, 6)
        if content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("+ ") {
            let text = String(content.dropFirst(2))
            if text.hasPrefix("[ ] ") { return .list(marker: "☐", depth: depth, text: String(text.dropFirst(4))) }
            if text.lowercased().hasPrefix("[x] ") { return .list(marker: "☑", depth: depth, text: String(text.dropFirst(4))) }
            return .list(marker: "•", depth: depth, text: text)
        }
        let digits = content.prefix(while: { $0.isASCII && $0.isNumber })
        let remainder = content.dropFirst(digits.count)
        if !digits.isEmpty, digits.count <= 9,
           let punctuation = remainder.first, punctuation == "." || punctuation == ")",
           remainder.dropFirst().first?.isWhitespace == true {
            return .list(marker: String(digits) + String(punctuation), depth: depth,
                         text: String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

struct AgentMarkdownText: View, Equatable {
    #if DEBUG
    static var debugParses = 0
    static var debugParseBytes = 0
    #endif
    let text: String
    var style: AgentTextStyle = .compact

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let blocks = AgentMarkdownBlock.parse(text)
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                BlockView(block: block, style: style)
                    .equatable()
                    .textSelection(.enabled)
                    .padding(.top, spacing(before: block, index: index, blocks: blocks))
            }
        }
        .font(.system(size: style.size))
        .lineSpacing(style.lineSpacing)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func spacing(before block: AgentMarkdownBlock, index: Int, blocks: [AgentMarkdownBlock]) -> CGFloat {
        guard index > 0 else { return 0 }
        if case .list = block, case .list = blocks[index - 1] { return 6 }
        if case .heading = block { return style.blockSpacing + 8 }
        return style.blockSpacing
    }

    /// Equatable block views keep already completed paragraphs out of the streaming parse path.
    private struct BlockView: View, Equatable {
        let block: AgentMarkdownBlock
        let style: AgentTextStyle

        var body: some View {
            switch block {
            case .paragraph(let text):
                Text(AgentMarkdownText.inline(text, size: style.size))
                    .fixedSize(horizontal: false, vertical: true)
            case .heading(let level, let text):
                Text(AgentMarkdownText.inline(text, size: style.headingSize(level)))
                    .font(.system(size: style.headingSize(level), weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            case .list(let marker, let depth, let text):
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(marker).monospacedDigit()
                        .frame(minWidth: 16, alignment: .trailing)
                    Text(AgentMarkdownText.inline(text, size: style.size))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(depth) * 16)
            case .quote(let text):
                Text(AgentMarkdownText.inline(text, size: style.size))
                    .foregroundColor(TapSkin.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(TapSkin.tone(0xd9d9dc, 0x49494c)).frame(width: 2)
                    }
            case .code(let language, let text):
                AgentCodeBlock(language: language, text: text, size: style.size - 1)
            case .divider:
                Rectangle().fill(AppTheme.subtleBorder).frame(height: 1).padding(.vertical, 4)
            }
        }
    }

    static func inline(_ text: String, size: CGFloat = 13) -> AttributedString {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPSLOTS_AGENT_PERF"] == "1" {
            debugParses += 1
            debugParseBytes += text.utf8.count
        }
        #endif
        var value = (try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in value.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                value[run.range].font = .system(size: size - 1, design: .monospaced)
                value[run.range].backgroundColor = TapSkin.tone(0xf0f0f2, 0x29292c)
            }
        }
        return value
    }
}

private struct AgentCodeBlock: View {
    let language: String
    let text: String
    let size: CGFloat
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language).lineLimit(1)
                Spacer(minLength: 12)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制代码", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("复制完整代码")
            }
            .font(.system(size: 12))
            .foregroundColor(TapSkin.secondaryInk)
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider().opacity(0.5)
            ScrollView(.horizontal) {
                Text(verbatim: text)
                    .font(.system(size: size, design: .monospaced))
                    .foregroundColor(TapSkin.ink)
                    .lineSpacing(4)
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
                    .padding(14)
            }
        }
        .background(TapSkin.tone(0xf7f7f8, 0x1c1c1e), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.subtleBorder, lineWidth: 1))
        .onChange(of: text) { _ in copied = false }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }
}
