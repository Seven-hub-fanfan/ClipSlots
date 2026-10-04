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
    var legacyCanvasModel: AgentChatModel?
    @State private var showLegacyCanvas = false

    @AppStorage(AgentPreferences.modelKey) private var modelName = AgentConfig.defaultModel
    @AppStorage(AgentPreferences.systemPromptKey) private var systemPrompt = AgentConfig.defaultSystemPrompt
    @AppStorage(AgentPreferences.thinkingModeKey) private var thinkingRaw = AgentThinkingMode.serverDefault.rawValue
    @AppStorage(AgentPreferences.reasoningEffortKey) private var reasoningEffort = ""
    @AppStorage(AgentPreferences.endpointKey) private var endpoint = AgentConfig.defaultEndpoint.absoluteString
    @AppStorage(AgentPreferences.enabledSkillsKey) private var enabledSkillsRaw = ""
    @AppStorage(CodexPreferences.modelKey) private var codexModel = ""
    @AppStorage(CodexPreferences.effortKey) private var codexEffort = ""
    @AppStorage(CodexPreferences.sandboxKey) private var codexSandbox = "read-only"
    @ObservedObject private var desktop = CodexWorkspaceModel.shared
    @State private var showDesktopTools = false
    @State private var showCustomModel = false
    @State private var customModelDraft = ""
    @AppStorage(TikaBackendPreferences.backendKindKey) private var sidebarBackendRaw = "deepseek"
    @AppStorage(CodexPreferences.workspaceBackendKey) private var workspaceBackendRaw = "codex"

    private var draft: String {
        get { model.draft }
        nonmutating set { model.draft = newValue }
    }
    @State private var showConfig = false
    @State private var showSkillPicker = false
    @StateObject private var completion = AgentComposerCompletion()
    @ObservedObject private var skillLibrary = AgentSkillLibrary.shared
    @State private var suggestionPage = 0
    @State private var followsLatest = true
    @State private var latestIsVisible = true
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
    private var isFullPage: Bool { workspaceMode == .agent }
    private var textStyle: AgentTextStyle { isFullPage ? .body : .compact }
    private var backendKind: AgentBackendKind {
        AgentBackendKind(rawValue: isFullPage ? workspaceBackendRaw : sidebarBackendRaw) ?? .deepseek
    }
    private var modelLabel: String {
        switch backendKind {
        case .codex:
            let selected = model.codexContext?.model ?? codexModel
            return selected.isEmpty ? (desktop.settings.model.isEmpty ? "Codex · 自动" : desktop.settings.model) : selected
        case .tika: return "Tika Agent"
        case .deepseek: return modelName
        }
    }
    private var composerCwd: String {
        if let cwd = model.codexContext?.cwd, !cwd.isEmpty { return cwd }
        return ClipSlotsPaths.dataRoot.appendingPathComponent("agent-workspace").path
    }

    private var enabledSlugs: Set<String> { AgentPreferences.decodeEnabledSlugs(enabledSkillsRaw) }
    private var panelFill: Color { isFullPage ? TapSkin.tone(0xffffff, 0x121212) : TapSkin.tone(0xfafafa, 0x111111) }
    private var inputFill: Color { isFullPage ? TapSkin.tone(0xffffff, 0x202020) : TapSkin.tone(0xf0f1f3, 0x1a1a1a) }
    private var hairline: Color { TapSkin.tone(0xe0e1e5, 0x2b2b2b) }
    private var welcomesUser: Bool { model.isEmpty && !model.isRunning && (isFullPage || (draft.isEmpty && model.draftAttachments.isEmpty)) }
    private var suggestionPages: [[AgentSuggestion]] {
        workspaceMode == .edit ? AgentSuggestion.editPages : AgentSuggestion.canvasPages
    }

    var body: some View {
        // #region debug-point A:sidebar-body
        #if DEBUG
        let _ = ProcessInfo.processInfo.environment["CLIPSLOTS_AGENT_PERF"] == "1" ? { Self.debugBodies += 1 }() : ()
        #endif
        // #endregion
        VStack(spacing: 0) {
            if !isFullPage || !model.isEmpty { header }
            transcript
            inputArea.frame(maxWidth: isFullPage ? 800 : .infinity)
                .frame(maxWidth: .infinity)
        }
        .frame(width: isFullPage ? nil : Self.width)
        .frame(maxWidth: isFullPage ? .infinity : nil)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(panelFill)
        .foregroundColor(TapSkin.ink)
        // 贴边描边：和左侧槽位库面板同一手法，视觉上把它读成窗口 chrome 而不是浮层卡片。
        .overlay(alignment: .leading) {
            Rectangle().fill(AppTheme.subtleBorder).frame(width: 1)
        }
        .sheet(isPresented: $showConfig) { AgentConfigView(isWorkspace: isFullPage) }
        .sheet(isPresented: $showDesktopTools) { CodexToolsView(chat: model) }
        .sheet(isPresented: $showLegacyCanvas) {
            if let legacyCanvasModel {
                LegacyCanvasHistoryView(model: legacyCanvasModel)
            }
        }
        .alert("自定义模型", isPresented: $showCustomModel) {
            TextField("模型 ID", text: $customModelDraft)
            Button("取消", role: .cancel) {}
            Button("使用") { setModelChoice(model: customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines), effort: "") }
        } message: {
            Text("使用当前模型服务支持的模型 ID。")
        }
        .onChange(of: workspaceMode) { _ in suggestionPage = 0 }
        .onChange(of: composerCwd) { _ in refreshComposerSkills() }
        .onChange(of: backendKind) { _ in refreshComposerSkills() }
        .onChange(of: model.selectedConversationID) { _ in
            followsLatest = true
            completion.dismiss()
            inputFocusRequest += 1
        }
        .onDisappear { scrollTask?.cancel(); scrollTask = nil }
        .onAppear {
            AgentSkillLibrary.shared.refresh()
            refreshComposerSkills()
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
            guard model.requiresAPIKey else { return }
            Task {
                let hasKey = await AgentKeychainProbe.hasAPIKey()
                if !hasKey, model.requiresAPIKey { showConfig = true }
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
                if legacyCanvasModel != nil {
                    Button("查看旧版画布记录") { showLegacyCanvas = true }
                }
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
            if !isFullPage {
                iconButton("arrow.up.right.and.arrow.down.left", help: "收起侧栏") {
                    withAnimation(Anim.transition) { isVisible = false }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
    }

    private var conversationTitle: String { model.currentConversationTitle }

    private func newConversation() {
        if isFullPage { desktop.cancelSelection() }
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
                    LazyVStack(alignment: .leading, spacing: isFullPage ? 16 : 18) {
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
                                    if let context = model.canvasContext,
                                       let message = model.messages.first(where: { $0.id.uuidString == item.id }),
                                       let refs = message.canvasReferences {
                                        ForEach(refs) { ref in
                                            DisclosureGroup("引用快照 · \(ref.title)") {
                                                Text(ref.text.isEmpty ? "无正文" : ref.text)
                                                    .textSelection(.enabled)
                                                Text(ref.attachmentNames.joined(separator: "、"))
                                                Button("定位素材") { context.locate(ref) }
                                            }.font(.system(size: 11)).padding(.top, 8)
                                        }
                                    }
                                case .assistant(let text, let reasoning, let isFailure):
                                    assistantBubble(text: text, reasoning: reasoning, isFailure: isFailure)
                                    if let context = model.canvasContext, !isFailure, !text.isEmpty {
                                        Button("预览并填入选中节点") {
                                            context.prepare(text: text, conversationID: model.selectedConversationID)
                                        }
                                        .font(.system(size: 11)).buttonStyle(.plain)
                                        .foregroundColor(TapSkin.accent).padding(.top, 8)
                                        .disabled(model.isRunning)
                                        .accessibilityIdentifier("agent-canvas-preview")
                                    }
                                case .tools(let rows):
                                    toolRows(rows)
                                }
                            }
                        }

                        if model.isRunning {
                            let recordedIDs = Set(model.messages.flatMap(\.toolCalls).map(\.id))
                            let unrecorded = model.liveActivities.filter { !recordedIDs.contains($0.id) }
                            if !unrecorded.isEmpty { toolRows(unrecorded) }
                            if model.pendingInteractions.isEmpty || !model.streamingContent.isEmpty {
                                streamingBubble
                            }
                        }

                        ForEach(model.pendingInteractions) { request in
                            AgentInteractionView(request: request, model: model)
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
                    .padding(.horizontal, isFullPage ? 24 : 18)
                    .padding(.vertical, isFullPage ? 24 : 14)
                    .frame(maxWidth: isFullPage ? 760 : .infinity)
                    .frame(maxWidth: .infinity)
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
                    if latestIsVisible == needsCorrection { latestIsVisible = !needsCorrection }
                    if followsLatest && needsCorrection {
                        scrollToBottom(proxy)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !followsLatest && !latestIsVisible && !model.isEmpty {
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
                        .accessibilityIdentifier("agent-back-to-latest")
                        .padding(.bottom, 8)
                    }
                }
                .onChange(of: model.messages.count) { _ in if followsLatest { scrollToBottom(proxy) } }
                .onChange(of: model.pendingInteractions.count) { _ in if followsLatest { scrollToBottom(proxy) } }
                .onChange(of: model.selectedConversationID) { _ in scrollToBottom(proxy) }
                .onAppear { if !model.isEmpty { scrollToBottom(proxy) } }
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
                Text(workspaceMode == .edit ? "今天想怎样编辑槽位？" : "今天一起创作点什么？")
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
        .frame(maxWidth: isFullPage ? 560 : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Spacer(minLength: isFullPage ? 60 : 28)
            Text(AgentMarkdownText.inline(text, size: textStyle.size))
                .font(.system(size: textStyle.size))
                .lineSpacing(textStyle.lineSpacing)
                .foregroundColor(TapSkin.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(TapSkin.tone(0xf4f4f5, 0x262628),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.top, isFullPage ? 10 : 0)
        .padding(.bottom, isFullPage ? 12 : 0)
    }

    private func assistantBubble(text: String, reasoning: String?, isFailure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !isFullPage {
                Label(backendKind == .codex ? "Codex" : "ClipSlots", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(TapSkin.secondaryInk)
            }
            VStack(alignment: .leading, spacing: 14) {
                if let reasoning, !reasoning.isEmpty {
                    ReasoningDisclosure(text: reasoning) { followsLatest = false }
                }
                if !text.isEmpty {
                    AgentMarkdownText(text: text, style: textStyle)
                        .equatable()
                        .textSelection(.enabled)
                        .accessibilityIdentifier("agent-message-body")
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
                .font(.system(size: 12))
                .foregroundColor(TapSkin.secondaryInk)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("复制这段回答")
    }

    private var streamingBubble: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 14) {
                if !model.streamingReasoning.isEmpty {
                    ReasoningDisclosure(text: model.streamingReasoning,
                                        isStreaming: model.streamingContent.isEmpty) {
                        followsLatest = false
                    }
                }
                if !model.streamingContent.isEmpty {
                    AgentMarkdownText(text: model.streamingContent, style: textStyle)
                        .equatable()
                } else if model.streamingReasoning.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 14, height: 14)
                        Text("正在处理…").font(.system(size: 13)).foregroundColor(TapSkin.secondaryInk)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toolRows(_ rows: [AgentToolActivity]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(row.argumentsPreview)
                        if let result = model.messages.last(where: { $0.toolCallId == row.id && $0.role == .tool }) {
                            Text(result.content)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                } label: {
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
                    Text(toolTitle(row.name))
                        .font(.system(size: 12, weight: .medium))
                    Text(row.argumentsPreview)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(AppTheme.canvasCardMetaInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let summary = row.summary {
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundColor(row.state == .failure ? .orange : AppTheme.canvasCardMetaInk)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(isFullPage ? Color.clear : AppTheme.chipBackground)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
    }

    private func toolTitle(_ name: String) -> String {
        ["commandExecution": "运行命令", "fileChange": "文件更改",
         "mcpToolCall": "调用工具", "webSearch": "搜索网页"][name] ?? name
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
        VStack(alignment: .leading, spacing: isFullPage ? 0 : 6) {
            if let context = model.canvasContext {
                CanvasAgentComposer(model: model, context: context)
            }
            if isFullPage && backendKind == .codex {
                projectPicker
            }
            if model.remoteIsActive {
                Text("桌面端正在运行此会话 · 完成后刷新继续")
                    .font(.system(size: 11)).foregroundColor(.secondary).padding(10)
            }
            if let usage = model.usageLine {
                Text(usage)
                    .font(.system(size: 9))
                    .foregroundColor(AppTheme.canvasCardMetaInk)
            }

            VStack(spacing: 8) {
                if completion.isOpen {
                    AgentComposerMenu(completion: completion, isScanning: skillLibrary.isScanning)
                        .padding(.horizontal, 8).padding(.top, 8)
                }
                if !model.draftSkillReferences.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.draftSkillReferences) { skill in
                                HStack(spacing: 5) {
                                    Image(systemName: "sparkles")
                                    Text(skill.name).lineLimit(1)
                                    Button {
                                        model.draftSkillReferences.removeAll { $0.id == skill.id }
                                    } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).help("移除技能引用")
                                }
                                .font(.system(size: 11)).padding(8)
                                .background(TapSkin.accent.opacity(0.1), in: Capsule())
                                .help("本轮引用 · " + skill.path)
                            }
                        }
                    }.padding(.horizontal, 12).padding(.top, 8)
                }
                if !model.draftAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.draftAttachments) { file in
                                HStack(spacing: 5) {
                                    Image(systemName: file.isImage ? "photo" : "doc")
                                    Text(file.name).lineLimit(1)
                                    Button {
                                        model.draftAttachments.removeAll { $0.id == file.id }
                                    } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).help("移除附件")
                                }
                                .font(.system(size: 11))
                                .padding(8).background(panelFill, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }.padding(.horizontal, 12).padding(.top, 10)
                }
                AgentDraftEditor(text: $model.draft, focusRequest: inputFocusRequest,
                                 placeholder: "输入消息，/ 快捷操作，$ 引用技能",
                                 completion: completion, completionItems: composerItems,
                                 onCompletion: performComposerAction, onSend: send)
                    .frame(height: draftHeight)
                    .padding(.horizontal, 9)
                    .padding(.top, 12)
                    .accessibilityLabel("Agent 输入")

                HStack(spacing: 8) {
                    if isFullPage {
                        Button(action: chooseAttachments) {
                            Image(systemName: "paperclip").font(.system(size: 15)).frame(width: 30, height: 32)
                        }
                        .buttonStyle(.plain)
                        .help("添加图片或文件 · 最多 8 个，每个 20 MB")
                        .accessibilityLabel("添加附件")
                        .disabled(backendKind != .codex || model.isAddingAttachments)
                        if model.isAddingAttachments { ProgressView().controlSize(.small) }
                    }
                    if isFullPage && backendKind == .codex {
                        Button { showDesktopTools = true } label: {
                            Image(systemName: "plus").font(.system(size: 16)).frame(width: 26, height: 32)
                        }.buttonStyle(.plain).help("Skills 与 MCP")
                        permissionPicker
                    }
                    skillButton
                    if model.isAddingSkill { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                    if isFullPage && backendKind == .codex {
                        modelPicker
                    } else {
                    Button { showConfig = true } label: {
                        HStack(spacing: 5) {
                            Text(modelLabel).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(TapSkin.secondaryInk)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("模型与推理设置")
                    }
                    Button {
                        if model.isRunning { model.stop() } else { send() }
                    } label: {
                        Image(systemName: model.isRunning ? "stop.fill" : "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(isFullPage ? panelFill : TapSkin.onAccent)
                            .frame(width: 34, height: 34)
                            .background((isFullPage ? TapSkin.ink : TapSkin.accent).opacity(canSend || model.isRunning ? 1 : 0.35), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend && !model.isRunning)
                    .help(model.isRunning ? "停止生成" : "Enter 发送 · Shift+Enter 换行")
                    .accessibilityLabel(model.isRunning ? "停止生成" : "发送")
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .background(inputFill, in: RoundedRectangle(cornerRadius: isFullPage ? 24 : 18))
            .overlay(RoundedRectangle(cornerRadius: isFullPage ? 24 : 18).stroke(hairline.opacity(0.7), lineWidth: 1))
            .shadow(color: .black.opacity(isFullPage ? 0.035 : 0), radius: 12, y: 2)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, isFullPage ? 20 : 10)
        .padding(.top, 6)
    }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.draftAttachments.isEmpty
            || !model.draftReferences.isEmpty || !model.draftSkillReferences.isEmpty)
            && !model.isAddingAttachments && !model.isAddingSkill
            && (!model.isCodex || !model.remoteIsActive)
    }

    private var draftHeight: CGFloat {
        let bounds = (draft as NSString).boundingRect(
            with: CGSize(width: Self.width - 54, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        return min(180, max(isFullPage ? 84 : 60, ceil(bounds.height) + 8))
    }

    private var skillButton: some View {
        Button {
            completion.openSkills()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .regular))
                Text("技能")
                    .font(.system(size: 10, weight: .medium))
                if !model.draftSkillReferences.isEmpty {
                    Text("\(model.draftSkillReferences.count)")
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
        .help("引用本轮技能 · 也可输入 $ 搜索")
        .accessibilityIdentifier("agent-reference-skill")
        .disabled(model.isAddingSkill)
        .contextMenu {
            if model.canvasProjectID == nil {
                Button("管理可执行技能…") { showSkillPicker = true }
            }
        }
        .popover(isPresented: $showSkillPicker, arrowEdge: .top) {
            AgentSkillPickerView(builtinToolCount: AgentBuiltinTools().specs().count)
        }
    }

    private var composerItems: [AgentComposerItem] {
        var items: [AgentComposerItem] = [
            .init(id: "skills", title: "/skills", detail: "选择本轮引用的技能规范", action: .skills),
            .init(id: "model", title: "/model", detail: "模型与推理设置", action: .model),
            .init(id: "new", title: "/new", detail: "保存当前对话并新建", action: .newConversation)
        ]
        if isFullPage && backendKind == .codex {
            items += [
                .init(id: "mcp", title: "/mcp", detail: "管理本机 Skills 与 MCP", action: .tools),
                .init(id: "attach", title: "/attach", detail: "添加图片或文件", action: .attachment)
            ]
        }
        // Local catalog is cached; no scanning or network requests on keystrokes.
        var seen = Set<String>()
        if backendKind == .codex && desktop.skillsCwd == composerCwd {
            for skill in desktop.skills where skill.enabled {
                let path = skill.id
                guard seen.insert(path).inserted else { continue }
                items.append(.init(id: path, title: "$" + skill.name, detail: skill.description,
                                   action: .skill(name: skill.name, path: path)))
            }
        }
        for skill in skillLibrary.skills {
            let path = skill.markdownPath
            guard seen.insert(path).inserted else { continue }
            items.append(.init(id: path, title: "$" + skill.name, detail: skill.description,
                               action: .skill(name: skill.name, path: path)))
        }
        return items
    }

    private func performComposerAction(_ action: AgentComposerItem.Action) {
        switch action {
        case .skills: break // Native editor already replaced /skills with $.
        case .model: showConfig = true
        case .newConversation: newConversation()
        case .tools: showDesktopTools = true
        case .attachment: chooseAttachments()
        case .skill(let name, let path): model.addSkillReference(name: name, path: path)
        }
    }

    private func refreshComposerSkills() {
        if backendKind == .codex { desktop.refreshTools(cwd: composerCwd) }
    }

    // MARK: 动作

    private var currentConfig: AgentConfig {
        var config = AgentPreferences.config(model: modelName,
                                systemPrompt: systemPrompt,
                                thinkingRaw: thinkingRaw,
                                reasoningEffort: reasoningEffort,
                                endpoint: endpoint)
        if backendKind == .codex {
            config.model = (model.codexContext?.model ?? codexModel).trimmingCharacters(in: .whitespacesAndNewlines)
            if model.codexContext?.model == "" { config.model = desktop.settings.model }
            let effort = model.codexContext?.effort ?? codexEffort
            config.reasoningEffort = effort.isEmpty ? nil : effort
        }
        return config
    }

    private var projectPicker: some View {
        Menu {
            ForEach(desktop.projects) { project in
                Button(project.name + " · " + project.path) {
                    desktop.cancelSelection()
                    model.selectProject(project)
                }
            }
            Divider()
            Button("选择文件夹…") { desktop.chooseProject(chat: model) }
        } label: {
            Label(model.codexContext?.cwd.isEmpty == false
                  ? URL(fileURLWithPath: model.codexContext!.cwd).lastPathComponent : "选择项目",
                  systemImage: "folder")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .font(.system(size: 12)).foregroundColor(TapSkin.secondaryInk)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 36)
        .background(TapSkin.tone(0xf5f5f5, 0x191919), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 14)
        .disabled(model.isRunning)
        .help(model.codexThreadID == nil ? "选择当前工作目录" : "选择项目会新建对话并保存当前草稿")
    }

    private var permissionPicker: some View {
        Menu {
            Button("终端只读") { codexSandbox = "read-only" }
            Button("可编辑项目文件") { codexSandbox = "workspace-write" }
        } label: {
            Label(codexSandbox == "workspace-write" ? "可编辑项目" : "终端只读", systemImage: "shield.lefthalf.filled")
                .font(.system(size: 11))
                .foregroundColor(codexSandbox == "workspace-write" ? .orange : TapSkin.secondaryInk)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(model.isRunning)
            .help("槽位操作通过 ClipSlots 工具；此处控制终端对项目文件的权限。")
    }

    private var modelPicker: some View {
        Menu {
            Section("模型") {
                Button("跟随本机默认") { setModelChoice(model: "", effort: "") }
                ForEach(desktop.models) { option in
                    Button(option.title) { setModelChoice(model: option.id, effort: "") }
                }
                Button("自定义模型…") { customModelDraft = modelLabel; showCustomModel = true }
            }
            Section("推理强度") {
                Button("默认") { setModelChoice(model: model.codexContext?.model ?? codexModel, effort: "") }
                ForEach(desktop.models.first(where: { $0.id == modelLabel })?.efforts ?? ["low", "medium", "high"], id: \.self) { effort in
                    Button(effortLabel(effort)) { setModelChoice(model: model.codexContext?.model ?? codexModel, effort: effort) }
                }
            }
        } label: {
            Text(modelLabel + " " + effortLabel(model.codexContext?.effort ?? (codexEffort.isEmpty ? desktop.settings.effort : codexEffort)) + " ⌄")
                .lineLimit(1)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .font(.system(size: 11)).frame(height: 32).fixedSize()
            .disabled(model.isRunning)
    }

    private func effortLabel(_ value: String) -> String {
        ["low": "低", "medium": "中", "high": "高", "xhigh": "极高", "minimal": "最小", "none": "无"][value] ?? value
    }

    private func setModelChoice(model choice: String, effort: String) {
        if model.codexContext == nil {
            model.codexContext = .init(cwd: "", provider: desktop.settings.provider)
        }
        model.codexContext?.model = choice
        model.codexContext?.effort = effort
        model.codexContext?.hasLocalModelChoice = true
        if choice.isEmpty { model.codexContext?.provider = desktop.settings.provider }
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.begin { response in
            guard response == .OK else { return }
            model.addAttachments(panel.urls)
        }
    }

    private var currentSkills: [AgentSkill] {
        AgentSkillLibrary.shared.skills(withSlugs: enabledSlugs)
    }

    private func send() {
        let text = draft
        guard canSend, !model.isRunning else { return }
        followsLatest = true
        if model.send(text: text, config: currentConfig, enabledSkills: currentSkills) { draft = "" }
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

struct ReasoningDisclosure: View {
    let text: String
    var isStreaming = false
    var onExpand: () -> Void = {}
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                expanded.toggle()
                if expanded { onExpand() }
            } label: {
                HStack(spacing: 8) {
                    if isStreaming {
                        ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 14, height: 14)
                    }
                    Text(isStreaming ? "正在思考" : "思考过程")
                        .font(.system(size: 13))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(TapSkin.secondaryInk)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agent-reasoning-toggle")
            .accessibilityLabel(isStreaming ? "正在思考" : "思考过程")
            .accessibilityValue(expanded ? "已展开" : "已折叠")
            .help(expanded ? "收起思考过程" : "展开思考过程")

            if expanded {
                AgentMarkdownText(text: text, style: .reasoning)
                    .equatable()
                    .foregroundColor(TapSkin.tone(0x55555b, 0xb9b9bf))
                    .textSelection(.enabled)
                    .padding(.leading, 16)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(TapSkin.tone(0xdedee2, 0x424248)).frame(width: 2)
                    }
                    .accessibilityIdentifier("agent-reasoning-content")
            }
        }
    }
}
