import SwiftUI
import AppKit
import ClipSlotsKit

// MARK: - Agent 侧边栏
//
// Figma 风格贴右侧通高面板，编辑页与画布页各一个会话（互不干扰，见 AgentSessionStore）。
// 结构：头部（模型/清空/设置/关闭）→ 转写区（气泡 + 思考折叠 + 工具行）→ 输入区（Skill/发送）。
//
// 两个刻意的取舍：
//   1. **思考内容默认折叠**。deepseek-reasoner 的思维链常比答案长好几倍，
//      默认展开会把答案挤出视野；但正在思考时会显示实时预览（否则等待期间界面死寂）。
//   2. **工具调用显示成状态行而不是气泡**。工具结果是给模型看的 JSON，用户要看的是
//      "调了什么、成没成"。想看原文可以展开那一行。

struct AgentSidebarView: View {
    @ObservedObject var model: AgentChatModel
    /// 由宿主页面控制显隐（编辑页/画布页各自持有）。
    @Binding var isVisible: Bool

    @AppStorage(AgentPreferences.modelKey) private var modelName = AgentConfig.defaultModel
    @AppStorage(AgentPreferences.systemPromptKey) private var systemPrompt = AgentConfig.defaultSystemPrompt
    @AppStorage(AgentPreferences.thinkingModeKey) private var thinkingRaw = AgentThinkingMode.serverDefault.rawValue
    @AppStorage(AgentPreferences.reasoningEffortKey) private var reasoningEffort = ""
    @AppStorage(AgentPreferences.endpointKey) private var endpoint = AgentConfig.defaultEndpoint.absoluteString
    @AppStorage(AgentPreferences.enabledSkillsKey) private var enabledSkillsRaw = ""

    @State private var draft = ""
    @State private var showConfig = false
    @State private var showSkillPicker = false
    @FocusState private var inputFocused: Bool

    /// 侧栏定宽。v2.11.7 hotfix24 起改为引用 `WindowLayoutMetrics` 里的同一个常量 ——
    /// 主窗口最小宽度的推导需要用到这个数，两处各写一遍迟早会对不上。
    static let width: CGFloat = WindowLayoutMetrics.agentSidebarWidth

    private var enabledSlugs: Set<String> { AgentPreferences.decodeEnabledSlugs(enabledSkillsRaw) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            transcript
            Divider().opacity(0.35)
            inputArea
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppTheme.canvasChromeSurface)
        // 贴边描边：和左侧槽位库面板同一手法，视觉上把它读成窗口 chrome 而不是浮层卡片。
        .overlay(alignment: .leading) {
            Rectangle().fill(AppTheme.subtleBorder).frame(width: 1)
        }
        .sheet(isPresented: $showConfig) { AgentConfigView() }
        .onAppear {
            // 用户要求：首次打开侧栏若无 API Key，直接弹配置页。
            if !model.hasAPIKey { showConfig = true }
            AgentSkillLibrary.shared.refresh()
            inputFocused = true
        }
        .onChange(of: model.needsConfiguration) { needs in
            guard needs else { return }
            showConfig = true
            model.needsConfiguration = false
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.chromeAccentInk)
            Text("Agent")
                .font(.system(size: 12, weight: .semibold))
            Text(modelName)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(AppTheme.chipBackground)
                .foregroundColor(AppTheme.canvasCardMetaInk)
                .clipShape(Capsule())
                .lineLimit(1)

            Spacer(minLength: 0)

            if !model.isEmpty {
                iconButton("trash", help: "清空当前会话") { model.clearHistory() }
            }
            iconButton("gearshape", help: "Agent 设置") { showConfig = true }
            iconButton("sidebar.right", help: "收起侧栏") {
                withAnimation(Anim.transition) { isVisible = false }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.canvasCardMetaInk)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 转写区

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.isEmpty && model.streamingContent.isEmpty {
                        emptyState
                    }

                    ForEach(model.transcript) { item in
                        switch item.kind {
                        case .user(let text):
                            userBubble(text)
                        case .assistant(let text, let reasoning, let isFailure):
                            assistantBubble(text: text, reasoning: reasoning, isFailure: isFailure)
                        case .tools(let rows):
                            toolRows(rows)
                        }
                    }

                    // 正在进行的这一轮
                    if model.isRunning {
                        if !model.liveActivities.isEmpty { toolRows(model.liveActivities) }
                        streamingBubble
                    }

                    if let errorText = model.errorText {
                        errorBanner(errorText)
                    }

                    Color.clear.frame(height: 1).id("agent_bottom")
                }
                .padding(12)
            }
            .onChange(of: model.messages.count) { _ in scrollToBottom(proxy) }
            .onChange(of: model.streamingContent) { _ in scrollToBottom(proxy) }
            .onChange(of: model.streamingReasoning) { _ in scrollToBottom(proxy) }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // 不加动画：流式追加时每个 token 都要滚，带动画会互相打断成抖动。
        proxy.scrollTo("agent_bottom", anchor: .bottom)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("直接说要做什么")
                .font(.system(size: 12, weight: .semibold))
            ForEach(["列出当前组所有槽位", "把槽位 3 改成「赛博朋克城市夜景，霓虹反射」", "搜一下带「人像」的槽位"], id: \.self) { sample in
                Button {
                    draft = sample
                    inputFocused = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.right").font(.system(size: 8))
                        Text(sample).font(.system(size: 11)).multilineTextAlignment(.leading)
                    }
                    .foregroundColor(AppTheme.canvasCardMetaInk)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 7)
                    .background(AppTheme.chipBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Agent 能直接读写槽位；写入前不会二次确认。")
                .font(.system(size: 9))
                .foregroundColor(AppTheme.canvasCardMetaInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 气泡

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 28)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AppTheme.chromeAccentInk)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func assistantBubble(text: String, reasoning: String?, isFailure: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                if let reasoning, !reasoning.isEmpty {
                    ReasoningDisclosure(text: reasoning)
                }
                if !text.isEmpty {
                    AgentMarkdownText(text: text)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isFailure ? Color.orange.opacity(0.12) : AppTheme.elevatedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if !text.isEmpty { copyButton(text) }
            }
            Spacer(minLength: 28)
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 9))
                .foregroundColor(AppTheme.canvasCardMetaInk)
                .padding(4)
        }
        .buttonStyle(.plain)
        .help("复制这段回答")
    }

    private var streamingBubble: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                if !model.streamingReasoning.isEmpty && model.streamingContent.isEmpty {
                    // 思考阶段：显示尾部一小段，让人看得见"它在动"，又不铺满屏。
                    HStack(alignment: .top, spacing: 5) {
                        ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 10, height: 10)
                        Text(String(model.streamingReasoning.suffix(220)))
                            .font(.system(size: 10))
                            .foregroundColor(AppTheme.canvasCardMetaInk)
                            .lineLimit(4)
                    }
                }
                if !model.streamingContent.isEmpty {
                    AgentMarkdownText(text: model.streamingContent)
                } else if model.streamingReasoning.isEmpty {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 10, height: 10)
                        Text("思考中…").font(.system(size: 11)).foregroundColor(AppTheme.canvasCardMetaInk)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(AppTheme.elevatedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Spacer(minLength: 28)
        }
    }

    private func toolRows(_ rows: [AgentToolActivity]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    switch row.state {
                    case .running:
                        ProgressView().controlSize(.small).scaleEffect(0.45).frame(width: 10, height: 10)
                    case .success:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9)).foregroundColor(.green)
                    case .failure:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundColor(.orange)
                    }
                    Text(row.name)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    Text(row.argumentsPreview)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(AppTheme.canvasCardMetaInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let summary = row.summary {
                        Text(summary)
                            .font(.system(size: 9))
                            .foregroundColor(row.state == .failure ? .orange : AppTheme.canvasCardMetaInk)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(AppTheme.chipBackground)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 10)).foregroundColor(.red)
                Text(text)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("重试") { model.retryLast(config: currentConfig, enabledSkills: currentSkills) }
                    .controlSize(.small)
                Button("打开设置") { showConfig = true }
                    .buttonStyle(.link)
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(9)
        .background(Color.red.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: 输入区

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let usage = model.usageLine {
                Text(usage)
                    .font(.system(size: 9))
                    .foregroundColor(AppTheme.canvasCardMetaInk)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(.system(size: 12))
                    .focused($inputFocused)
                    .frame(minHeight: 34, maxHeight: 108)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .scrollContentBackground(.hidden)
                    .background(AppTheme.searchFieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(AppTheme.subtleBorder, lineWidth: 1))
                if draft.isEmpty {
                    Text("说点什么…（⌘↩ 发送）")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.canvasCardMetaInk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                skillButton
                Spacer(minLength: 0)
                if model.isRunning {
                    Button {
                        model.stop()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .controlSize(.small)
                } else {
                    Button(action: send) {
                        Label("发送", systemImage: "paperplane.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(12)
    }

    private var skillButton: some View {
        Button {
            showSkillPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Skill")
                    .font(.system(size: 10, weight: .medium))
                if !enabledSlugs.isEmpty {
                    Text("\(enabledSlugs.count)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .background(AppTheme.chromeAccentInk)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppTheme.chipBackground)
            .foregroundColor(AppTheme.chromeAccentInk)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("选择开放给 Agent 的 Skill")
        .popover(isPresented: $showSkillPicker, arrowEdge: .top) {
            AgentSkillPickerView(builtinToolCount: AgentBuiltinTools().specs().count)
        }
    }

    // MARK: 动作

    private var currentConfig: AgentConfig {
        AgentPreferences.config(model: modelName,
                                systemPrompt: systemPrompt,
                                thinkingRaw: thinkingRaw,
                                reasoningEffort: reasoningEffort,
                                endpoint: endpoint)
    }

    private var currentSkills: [AgentSkill] {
        AgentSkillLibrary.shared.skills(withSlugs: enabledSlugs)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.send(text: text, config: currentConfig, enabledSkills: currentSkills)
        // 缺 API Key 时 send 会同步置起 needsConfiguration 并直接返回，
        // 这种情况保留输入内容——用户填完 Key 回来还能直接发，而不是白打一段字。
        if !model.needsConfiguration { draft = "" }
    }
}

// MARK: - 思考折叠

private struct ReasoningDisclosure: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Anim.reveal) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Image(systemName: "brain")
                        .font(.system(size: 9))
                    Text("思考过程 · \(text.count) 字")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(AppTheme.canvasCardMetaInk)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.system(size: 10))
                    .foregroundColor(AppTheme.canvasCardMetaInk)
                    .textSelection(.enabled)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.chipBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }
}

// MARK: - 轻量 Markdown 渲染
//
// 不引三方库：Agent 的回答格式很有限（段落、列表、行内代码/粗体、围栏代码块），
// 用 AttributedString 的 inline markdown + 手工分块就够，且没有新依赖。
// 表格/图片这类不支持的语法会原样显示——这比渲染成错的更好。

struct AgentMarkdownText: View {
    let text: String

    private enum Block: Identifiable {
        case code(String)
        case lines([String])
        var id: String {
            switch self {
            case .code(let c): return "c" + c.prefix(24)
            case .lines(let l): return "l" + (l.first?.prefix(24) ?? "")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(of: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    Text(code)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.chipBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                case .lines(let lines):
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Self.lineView(line)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private static func lineView(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else if trimmed.hasPrefix("#") {
            let level = trimmed.prefix(while: { $0 == "#" }).count
            Text(inline(String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                .font(.system(size: level <= 2 ? 13 : 12, weight: .semibold))
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 5) {
                Text("•").font(.system(size: 12))
                Text(inline(String(trimmed.dropFirst(2)))).font(.system(size: 12))
            }
        } else {
            Text(inline(trimmed)).font(.system(size: 12))
        }
    }

    /// 行内 markdown（粗体/斜体/行内代码/链接）。
    /// 用 `inlineOnlyPreservingWhitespace` 而不是默认选项：默认会把整段当块级结构解析，
    /// 结果是自己吃掉换行，和上层"按行渲染"打架。
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    private static func blocks(of text: String) -> [Block] {
        var blocks: [Block] = []
        var buffer: [String] = []
        var codeBuffer: [String] = []
        var inCode = false

        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeBuffer.joined(separator: "\n")))
                    codeBuffer = []
                    inCode = false
                } else {
                    if !buffer.isEmpty { blocks.append(.lines(buffer)); buffer = [] }
                    inCode = true
                }
                continue
            }
            if inCode { codeBuffer.append(line) } else { buffer.append(line) }
        }
        // 未闭合的围栏（流式过程中很常见）也要渲染出来，否则正在生成的代码块会整段消失。
        if !codeBuffer.isEmpty { blocks.append(.code(codeBuffer.joined(separator: "\n"))) }
        if !buffer.isEmpty { blocks.append(.lines(buffer)) }
        return blocks
    }
}
