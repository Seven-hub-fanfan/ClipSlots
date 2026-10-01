import SwiftUI
import AppKit
import ClipSlotsKit

// MARK: - Agent 侧边栏
//
// TapNow 录屏布局：紧凑会话栏 → 居中欢迎卡/连续回答 → 一体输入框。
// 编辑页与画布页各一个会话（互不干扰，见 AgentSessionStore）。
//
// 两个刻意的取舍：
//   1. **思考内容默认折叠**。deepseek-reasoner 的思维链常比答案长好几倍，
//      默认展开会把答案挤出视野；但正在思考时会显示实时预览（否则等待期间界面死寂）。
//   2. **工具调用显示成状态行而不是气泡**。工具结果是给模型看的 JSON，用户要看的是
//      "调了什么、成没成"。想看原文可以展开那一行。

struct AgentSidebarView: View {
    // #region debug-point A:sidebar-counts
    #if DEBUG
    static var debugBodies = 0
    static var debugScrolls = 0
    static var debugBottom: CGFloat?
    #endif
    // #endregion
    @ObservedObject var model: AgentChatModel
    /// 由宿主页面控制显隐（编辑页/画布页各自持有）。
    @Binding var isVisible: Bool
    var workspaceMode: WorkspaceMode = .canvas

    @AppStorage(AgentPreferences.modelKey) private var modelName = AgentConfig.defaultModel
    @AppStorage(AgentPreferences.systemPromptKey) private var systemPrompt = AgentConfig.defaultSystemPrompt
    @AppStorage(AgentPreferences.thinkingModeKey) private var thinkingRaw = AgentThinkingMode.serverDefault.rawValue
    @AppStorage(AgentPreferences.reasoningEffortKey) private var reasoningEffort = ""
    @AppStorage(AgentPreferences.endpointKey) private var endpoint = AgentConfig.defaultEndpoint.absoluteString
    @AppStorage(AgentPreferences.enabledSkillsKey) private var enabledSkillsRaw = ""

    private var draft: String {
        get { model.draft }
        nonmutating set { model.draft = newValue }
    }
    @State private var showConfig = false
    @State private var showSkillPicker = false
    @State private var suggestionPage = 0
    @State private var followsLatest = true
    @State private var inputFocusRequest = 0
    @State private var scrollTask: Task<Void, Never>?
    private final class ScrollPosition {
        var bottom: CGFloat?
        var viewportHeight: CGFloat = 0
    }
    @State private var scrollPosition = ScrollPosition()

    /// 侧栏定宽。v2.11.7 hotfix24 起改为引用 `WindowLayoutMetrics` 里的同一个常量 ——
    /// 主窗口最小宽度的推导需要用到这个数，两处各写一遍迟早会对不上。
    static let width: CGFloat = WindowLayoutMetrics.agentSidebarWidth

    private var enabledSlugs: Set<String> { AgentPreferences.decodeEnabledSlugs(enabledSkillsRaw) }
    private var panelFill: Color { TapSkin.tone(0xfafafa, 0x111111) }
    private var inputFill: Color { TapSkin.tone(0xf0f1f3, 0x1a1a1a) }
    private var hairline: Color { TapSkin.tone(0xe0e1e5, 0x2b2b2b) }
    private var welcomesUser: Bool { model.isEmpty && !model.isRunning && draft.isEmpty }
    private var suggestionPages: [[AgentSuggestion]] {
        workspaceMode == .canvas ? AgentSuggestion.canvasPages : AgentSuggestion.editPages
    }

    var body: some View {
        // #region debug-point A:sidebar-body
        #if DEBUG
        let _ = ProcessInfo.processInfo.environment["CLIPSLOTS_AGENT_PERF"] == "1" ? { Self.debugBodies += 1 }() : ()
        #endif
        // #endregion
        VStack(spacing: 0) {
            header
            transcript
            inputArea
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(panelFill)
        .foregroundColor(TapSkin.ink)
        // 贴边描边：和左侧槽位库面板同一手法，视觉上把它读成窗口 chrome 而不是浮层卡片。
        .overlay(alignment: .leading) {
            Rectangle().fill(AppTheme.subtleBorder).frame(width: 1)
        }
        .sheet(isPresented: $showConfig) { AgentConfigView() }
        .onChange(of: workspaceMode) { _ in suggestionPage = 0 }
        .onDisappear { scrollTask?.cancel(); scrollTask = nil }
        .onAppear {
            AgentSkillLibrary.shared.refresh()
            inputFocusRequest += 1
            #if DEBUG
            // UI fixtures exercise rendering and input without requesting the user's keychain.
            if Bundle.main.bundleIdentifier == "com.clipslots.app.canvas-v2174-test",
               ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1" {
                return
            }
            #endif
            // 用户要求：首次打开侧栏若无 API Key，直接弹配置页。
            //
            // v2.11.8: 这里**必须**异步探测。旧写法是同步 `if !model.hasAPIKey`，而钥匙串在
            // 弹系统授权框时会阻塞调用线程 —— 侧栏是首帧渲染的，主线程一卡，主窗口在用户
            // 点掉授权框前根本不显示（覆盖安装后必然复现，因为 adhoc 签名每次都变）。
            Task {
                let hasKey = await AgentKeychainProbe.hasAPIKey()
                if !hasKey { showConfig = true }
            }
        }
        .onChange(of: model.needsConfiguration) { needs in
            guard needs else { return }
            showConfig = true
            model.needsConfiguration = false
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Button("新建对话", action: newConversation)
                if !model.recentConversations.isEmpty {
                    Section("最近会话") {
                        ForEach(model.recentConversations) { conversation in
                            Button(conversation.title.isEmpty ? "未发送草稿" : conversation.title) {
                                model.openConversation(id: conversation.id)
                                followsLatest = true
                                inputFocusRequest += 1
                            }
                        }
                    }
                }
                Button("复制当前对话") {
                    let text = model.transcript.compactMap { item -> String? in
                        switch item.kind {
                        case .user(let text): return "我：\(text)"
                        case .assistant(let text, _, _): return "Agent：\(text)"
                        case .tools: return nil
                        }
                    }.joined(separator: "\n\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }.disabled(model.isEmpty)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16))
                    Text(conversationTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundColor(TapSkin.faintInk)
                }
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .help("会话操作")
            Spacer(minLength: 0)
            iconButton("slider.horizontal.3", help: "Agent 设置") { showConfig = true }
            iconButton("square.and.pencil", help: "新建对话", action: newConversation)
            iconButton("arrow.up.right.and.arrow.down.left", help: "收起侧栏") {
                withAnimation(Anim.transition) { isVisible = false }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
    }

    private var conversationTitle: String {
        model.messages.first(where: { $0.role == .user }).map { String($0.content.prefix(14)) } ?? "新建对话"
    }

    private func newConversation() {
        model.clearHistory()
        draft = ""
        followsLatest = true
        inputFocusRequest += 1
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(TapSkin.secondaryInk)
                .frame(width: 30, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 转写区

    private var transcript: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if welcomesUser {
                            emptyState
                                .frame(minHeight: max(0, geometry.size.height - 60))
                        }

                        ForEach(model.transcript) { item in
                            // 每条历史始终对应一个布局节点，避免条件分支影响 lazy 滚动定位。
                            VStack(alignment: .leading, spacing: 0) {
                                switch item.kind {
                                case .user(let text):
                                    userBubble(text)
                                case .assistant(let text, let reasoning, let isFailure):
                                    assistantBubble(text: text, reasoning: reasoning, isFailure: isFailure)
                                case .tools(let rows):
                                    toolRows(rows)
                                }
                            }
                        }

                        if model.isRunning {
                            if !model.liveActivities.isEmpty { toolRows(model.liveActivities) }
                            streamingBubble
                        }

                        if let errorText = model.errorText { errorBanner(errorText) }
                        if let persistenceError = model.persistenceError {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(persistenceError).font(.system(size: 11)).foregroundColor(.orange)
                                Button("重试保存") { model.flushSession() }.buttonStyle(.plain)
                            }
                        }
                        Color.clear.frame(height: 1).id("agent_bottom")
                            .background(GeometryReader { marker in
                                Color.clear.preference(key: AgentTranscriptBottomKey.self,
                                    value: marker.frame(in: .named("agentTranscript")).maxY)
                            })
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(AgentTranscriptScrollObserver { followsLatest = $0 })
                }
                .coordinateSpace(name: "agentTranscript")
                .onPreferenceChange(AgentTranscriptBottomKey.self) { bottom in
                    scrollPosition.bottom = bottom
                    scrollPosition.viewportHeight = geometry.size.height
                    // #region debug-point A:bottom-position
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["CLIPSLOTS_AGENT_PERF"] == "1" { Self.debugBottom = bottom }
                    #endif
                    // #endregion
                    // Lazy 历史在滚到末尾后会修正估算高度；继续跟随真实末尾，直到进入可视区。
                    let needsCorrection = bottom.map { $0 > geometry.size.height + 2 || $0 < 0 } ?? true
                    if followsLatest && needsCorrection {
                        scrollToBottom(proxy)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !followsLatest && !model.isEmpty {
                        Button {
                            followsLatest = true
                            scrollToBottom(proxy)
                        } label: {
                            Label("回到最新", systemImage: "arrow.down")
                                .font(.system(size: 11))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(inputFill, in: Capsule())
                                .overlay(Capsule().stroke(hairline))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 8)
                    }
                }
                .onChange(of: model.messages.count) { _ in if followsLatest { scrollToBottom(proxy) } }
                .onChange(of: model.streamingContent) { _ in if followsLatest { scrollToBottom(proxy) } }
                .onChange(of: model.streamingReasoning) { _ in if followsLatest { scrollToBottom(proxy) } }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard scrollTask == nil else { return }
        scrollTask = Task { @MainActor in
            // 首次合并高频请求；高度估算修正后最多再定位几帧，避免长消息完成时末尾离屏。
            for pass in 0..<6 {
                try? await Task.sleep(for: .milliseconds(pass == 0 ? 80 : 16))
                guard !Task.isCancelled else { return }
                guard followsLatest else { break }
                if pass > 0, let bottom = scrollPosition.bottom,
                   bottom >= 0, bottom <= scrollPosition.viewportHeight + 2 { break }
                // #region debug-point A:sidebar-scroll
                #if DEBUG
                if ProcessInfo.processInfo.environment["CLIPSLOTS_AGENT_PERF"] == "1" { Self.debugScrolls += 1 }
                #endif
                // #endregion
                proxy.scrollTo("agent_bottom", anchor: .bottom)
            }
            scrollTask = nil
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Hi，欢迎回来", systemImage: "sparkles")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundColor(TapSkin.secondaryInk)
                Text(workspaceMode == .canvas ? "今天一起创作点什么？" : "今天想怎样编辑槽位？")
                    .font(.system(size: 26, weight: .medium))
            }
            HStack(spacing: 12) {
                suggestionCard(suggestionPages[suggestionPage][0], angle: -2)
                suggestionCard(suggestionPages[suggestionPage][1], angle: 2)
            }
            .padding(.top, 6)
            HStack {
                Spacer()
                iconButton("arrow.2.squarepath", help: "换一组建议") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        suggestionPage = (suggestionPage + 1) % suggestionPages.count
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionCard(_ suggestion: AgentSuggestion, angle: Double) -> some View {
        Button {
            // #region debug-point C-D:suggestion-action
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_CONTROL_PROBE"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7784/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "slot-input-controls", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "C-D", "msg": "[DEBUG] suggestion action", "data": ["session": model.displayName, "title": suggestion.title]]); URLSession.shared.dataTask(with: r).resume() }
            #endif
            // #endregion
            draft = suggestion.prompt
            inputFocusRequest += 1
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(suggestion.category, systemImage: suggestion.symbol)
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.system(size: 11))
                }
                .foregroundColor(TapSkin.faintInk)
                Text(suggestion.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(TapSkin.ink)
                    .lineLimit(2)
                Text(suggestion.detail)
                    .font(.system(size: 12))
                    .foregroundColor(TapSkin.secondaryInk)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 140)
            .background(inputFill, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rotationEffect(.degrees(angle))
        .accessibilityLabel(suggestion.title)
        .help("填入输入框，编辑后发送")
    }

    // MARK: 气泡

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 28)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(TapSkin.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(inputFill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func assistantBubble(text: String, reasoning: String?, isFailure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("ClipSlots", systemImage: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(TapSkin.secondaryInk)
            VStack(alignment: .leading, spacing: 8) {
                if let reasoning, !reasoning.isEmpty {
                    ReasoningDisclosure(text: reasoning)
                }
                if !text.isEmpty {
                    AgentMarkdownText(text: text)
                        .equatable()
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(isFailure ? .orange : TapSkin.ink)
            if !text.isEmpty { copyButton(text) }
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.canvasCardMetaInk)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
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
                        .equatable()
                } else if model.streamingReasoning.isEmpty {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 10, height: 10)
                        Text("思考中…").font(.system(size: 11)).foregroundColor(AppTheme.canvasCardMetaInk)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    case .stopped:
                        Image(systemName: "stop.circle")
                            .font(.system(size: 9)).foregroundColor(AppTheme.canvasCardMetaInk)
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
        VStack(alignment: .leading, spacing: 6) {
            if let usage = model.usageLine {
                Text(usage)
                    .font(.system(size: 9))
                    .foregroundColor(AppTheme.canvasCardMetaInk)
            }

            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    AgentDraftEditor(text: $model.draft, focusRequest: inputFocusRequest, onSend: send)
                        .frame(height: draftHeight)
                        .padding(.horizontal, 9)
                        .padding(.top, 12)
                        .accessibilityLabel("Agent 输入")
                    if draft.isEmpty {
                        Text("随心输入")
                            .font(.system(size: 13))
                            .foregroundColor(TapSkin.faintInk)
                            .padding(.horizontal, 15)
                            .padding(.top, 14)
                            .allowsHitTesting(false)
                    }
                }

                HStack(spacing: 8) {
                    skillButton
                    Spacer(minLength: 0)
                    Button { showConfig = true } label: {
                        HStack(spacing: 5) {
                            Text(modelName).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(TapSkin.secondaryInk)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("模型与推理设置")
                    Button {
                        if model.isRunning { model.stop() } else { send() }
                    } label: {
                        Image(systemName: model.isRunning ? "stop.fill" : "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(TapSkin.onAccent)
                            .frame(width: 34, height: 34)
                            .background(TapSkin.accent.opacity(canSend || model.isRunning ? 1 : 0.35), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend && !model.isRunning)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(model.isRunning ? "停止生成" : "发送 · ⌘Return")
                    .accessibilityLabel(model.isRunning ? "停止生成" : "发送")
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .background(inputFill, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(hairline, lineWidth: 1))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 6)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var draftHeight: CGFloat {
        let bounds = (draft as NSString).boundingRect(
            with: CGSize(width: Self.width - 54, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        return min(180, max(60, ceil(bounds.height) + 8))
    }

    private var skillButton: some View {
        Button {
            showSkillPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .regular))
                Text("Skill")
                    .font(.system(size: 10, weight: .medium))
                if !enabledSlugs.isEmpty {
                    Text("\(enabledSlugs.count)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .background(TapSkin.accent)
                        .foregroundColor(TapSkin.onAccent)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .foregroundColor(TapSkin.secondaryInk)
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
        guard canSend, !model.isRunning else { return }
        followsLatest = true
        model.send(text: text, config: currentConfig, enabledSkills: currentSkills)
        // 缺 API Key 时 send 会同步置起 needsConfiguration 并直接返回，
        // 这种情况保留输入内容——用户填完 Key 回来还能直接发，而不是白打一段字。
        if !model.needsConfiguration { draft = "" }
    }
}

private struct AgentSuggestion {
    let category: String
    let symbol: String
    let title: String
    let detail: String
    let prompt: String

    static let canvasPages: [[AgentSuggestion]] = [
        [
            .init(category: "灵感创作", symbol: "sparkles", title: "把一个想法\n打磨成画面",
                  detail: "从主体、光线到构图，写好生图提示词。",
                  prompt: "帮我把这个画面想法优化为可直接用于生图的提示词，先问我主体与风格。只产出提示词。"),
            .init(category: "视频分镜", symbol: "lightbulb", title: "让故事从第一帧\n开始发生",
                  detail: "梳理镜头和情绪，让画面自然衔接。",
                  prompt: "帮我规划一段短视频的分镜，先了解故事主题、时长和视觉风格。")
        ],
        [
            .init(category: "槽位整理", symbol: "square.grid.2x2", title: "理清素材\n让灵感各就各位",
                  detail: "浏览当前组的槽位，整理内容与用途。",
                  prompt: "列出当前组所有槽位，概括每个槽位的内容，并给出整理建议。"),
            .init(category: "素材检索", symbol: "magnifyingglass", title: "找回那份\n刚好合适的素材",
                  detail: "按主题检索槽位，快速找到已有内容。",
                  prompt: "帮我查找槽位里的素材，先问我想找的主题或关键词。")
        ]
    ]

    static let editPages: [[AgentSuggestion]] = [
        [
            .init(category: "编辑槽位", symbol: "square.and.pencil", title: "润色槽位内容\n保留原来的意思",
                  detail: "读取槽位正文，按你的要求修改并写回。",
                  prompt: "帮我编辑当前组的槽位内容。先列出槽位，让我选择要编辑的槽位和修改要求；读取原文后保留核心信息，给出修改稿，确认后写回原槽位。"),
            .init(category: "批量修改", symbol: "text.badge.checkmark", title: "统一多个槽位\n的格式与表达",
                  detail: "批量调整标题、措辞和结构。",
                  prompt: "帮我批量编辑当前组的槽位。先列出有正文的槽位，让我选择范围和格式要求，再展示修改前后的对照，确认后逐个写回。")
        ],
        [
            .init(category: "槽位整理", symbol: "square.grid.2x2", title: "整理槽位内容\n让素材各就各位",
                  detail: "概括内容，整理分组与命名。",
                  prompt: "列出当前组所有槽位，概括正文和附件，找出重复或用途相近的内容，给出槽位命名与整理建议，确认后再修改。"),
            .init(category: "查找替换", symbol: "magnifyingglass", title: "找到目标内容\n再精确修改",
                  detail: "按关键词检索，核对后替换。",
                  prompt: "帮我在槽位正文中查找并替换内容。先问我要查找和替换的文字，以及操作范围；列出命中的槽位和原文片段，确认后再写回。")
        ]
    ]
}

private struct AgentTranscriptBottomKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

/// 只由用户滚动改变跟随状态，内容增长不会把“跟随最新”误判为离开底部。
private struct AgentTranscriptScrollObserver: NSViewRepresentable {
    let onScroll: (Bool) -> Void

    final class Host: NSView {
        var onScroll: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        private weak var observedScroll: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        func attach() {
            guard let scroll = enclosingScrollView, observedScroll !== scroll else { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observedScroll = scroll
            observer = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main
            ) { [weak self, weak scroll] _ in
                guard let scroll, let document = scroll.documentView else { return }
                let visible = scroll.documentVisibleRect
                let gap = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY
                self?.onScroll?(gap < 40)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        view.onScroll = onScroll
        DispatchQueue.main.async { [weak view] in view?.attach() }
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

struct AgentMarkdownText: View, Equatable {
    // #region debug-point A:markdown-counts
    #if DEBUG
    static var debugParses = 0
    static var debugParseBytes = 0
    #endif
    // #endregion
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
                            Line(text: line).equatable()
                        }
                    }
                }
            }
        }
    }

    private struct Line: View, Equatable {
        let text: String
        var body: some View { AgentMarkdownText.lineView(text) }
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
        // #region debug-point A:markdown-parse
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPSLOTS_AGENT_PERF"] == "1" { Self.debugParses += 1; Self.debugParseBytes += s.utf8.count }
        #endif
        // #endregion
        return (try? AttributedString(markdown: s,
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
