import SwiftUI
import AppKit
import ClipSlotsKit

// MARK: - Agent 侧边栏
//
// TapNow 录屏布局：紧凑会话栏 → 居中欢迎卡/连续回答 → 一体输入框。
// 编辑页和画布页共用当前项目会话，见 AgentSessionStore.sidebarSession。
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
    static var debugWidthWrites = 0
    static var debugLiveWidth: CGFloat?
    #endif
    // #endregion
    @ObservedObject var model: AgentChatModel
    /// 由宿主页面控制显隐（编辑页/画布页各自持有）。
    @Binding var isVisible: Bool
    var workspaceMode: WorkspaceMode = .canvas
    var isExpanded = false
    var onToggleExpanded: (() -> Void)?
    var legacyCanvasModel: AgentChatModel?
    var legacyEditModel: AgentChatModel?
    var isReadOnly = false
    var entryMounts: CanvasNodeMountQueue?
    var credentialStateProvider: (() async -> (hasKey: Bool, error: AgentKeychainError?))?
    var marketSync: AgentMarketSyncStore = .shared
    @State private var showLegacyCanvas = false
    @State private var showLegacyEdit = false
    @State private var showContextInfo = false
    @State private var contextPinned = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("agent.panel.requestedWidth") private var requestedWidth = 440.0
    @State private var windowWidth = WindowLayoutMetrics.minWindowContentWidth
    @State private var dragStartWidth: CGFloat?
    @State private var liveWidth: CGFloat?
    @State private var showRename = false
    @State private var renameTitle = ""
    @State private var editingQueueID: UUID?
    @State private var queueEditText = ""
    @State private var showQueueEdit = false

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
    @State private var credentialNotice: String?
    @State private var showSkillPicker = false
    @State private var showAppMarket = false
    @State private var showSourceConnector = false
    @StateObject private var applicationManagerRequest = AgentApplicationManagerRequest()
    @State private var marketTab = "应用"
    @StateObject private var skillImporter = CommunitySkillManager(installsExternalAgents: false)
    @State private var dismissedExtensionEntry = false
    @State private var showReferencePicker = false
    @State private var showModelPicker = false
    @State private var showWorkflowLibrary = false
    @State private var showComposerAdd = false
    @State private var showCaptureMenu = false
    @StateObject private var completion = AgentComposerCompletion()
    @StateObject private var modelCatalog = AgentModelCatalogStore()
    @StateObject private var voice = AgentVoiceInput()
    @StateObject private var capture = AgentScreenCapture()
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
    private var panelWidth: CGFloat {
        WindowLayoutMetrics.agentPanelWidth(requested: liveWidth ?? requestedWidth, windowWidth: windowWidth)
    }
    private var isFullPage: Bool { isExpanded || workspaceMode == .agent }
    private var textStyle: AgentTextStyle { isFullPage ? .body : .compact }
    private var backendKind: AgentBackendKind { model.backendKind }
    private var conversationSource: String {
        "\(ObjectIdentifier(model)):\(model.selectedConversationID.uuidString)"
    }
    private var modelLabel: String {
        switch backendKind {
        case .tika: return "Tika Agent"
        case .deepseek: return ModelConfigurationBridge.profile(.agent)?.model ?? modelName
        case .gateway:
            return UserDefaults.standard.string(forKey: AgentGatewayPreferences.modelKey)
                ?? AgentGatewayPreferences.defaultModel
        }
    }
    private var enabledSlugs: Set<String> { AgentPreferences.decodeEnabledSlugs(enabledSkillsRaw) }
    private var panelFill: Color { isFullPage ? TapSkin.tone(0xffffff, 0x121212) : TapSkin.tone(0xfafafa, 0x111111) }
    private var inputFill: Color { TapSkin.tone(0xf7f7f7, 0x191919) }
    private var hairline: Color { TapSkin.tone(0xe0e1e5, 0x2b2b2b) }
    private var welcomesUser: Bool { model.isEmpty && !model.isRunning && model.pendingInteractions.isEmpty && (isFullPage || (draft.isEmpty && model.draftAttachments.isEmpty)) }
    private var suggestionPages: [[AgentSuggestion]] {
        workspaceMode == .edit ? AgentSuggestion.editPages : AgentSuggestion.canvasPages
    }

    var body: some View {
        // #region debug-point A:sidebar-body
        #if DEBUG
        let _ = ProcessInfo.processInfo.environment["CLIPSLOTS_AGENT_PERF"] == "1" ? { Self.debugBodies += 1 }() : ()
        #endif
        // #endregion
        WorkspaceDockLayout(width: isFullPage ? nil : panelWidth) {
        ZStack {
        VStack(spacing: 0) {
            section("header", height: 64) {
                if !isFullPage || !model.isEmpty || onToggleExpanded != nil { header }
            }
            section("transcript") { transcript }
            section("input", height: 180) {
                AgentConnectorPrompt(sync: marketSync) {
                    guard let item = marketSync.connectionPrompt else { return }
                    marketSync.sourceConnection = item; marketSync.connectionPrompt = nil
                    showSourceConnector = true
                }
                if welcomesUser && !dismissedExtensionEntry {
                    extensionEntry.padding(.bottom, 2)
                }
                if capture.needsPermission {
                    Button("打开系统设置 · 屏幕录制权限") { capture.openPermissionSettings() }
                        .font(.system(size: 11)).padding(.horizontal, 12)
                        .accessibilityIdentifier("agent-capture-permission-settings")
                }
                if !isReadOnly && (model.canResumeGateway || !model.artifacts.isEmpty) {
                    AgentReplicaControls(model: model, onDismiss: { inputFocusRequest += 1 })
                }
                inputArea.frame(maxWidth: isFullPage ? 800 : .infinity)
                    .frame(maxWidth: .infinity)
                    .disabled(isReadOnly)
            }
        }
        }
        .background(AgentApplicationManagerPresenter(isPresented: $showAppMarket,
            model: model, sync: marketSync, isReadOnly: isReadOnly, initialTab: marketTab,
            onClose: { inputFocusRequest += 1 }, request: applicationManagerRequest))
        .background(AgentApplicationManagerPresenter(isPresented: $showSourceConnector,
            model: model, sync: marketSync, isReadOnly: isReadOnly, initialTab: "连接",
            onClose: { inputFocusRequest += 1 }))
        .sheet(item: Binding(get: { marketSync.connectingItem }, set: { marketSync.connectingItem = $0 })) { item in
            AgentApplicationConnection(item: item, sync: marketSync)
        }
        .frame(width: isFullPage ? nil : panelWidth)
        .frame(maxWidth: isFullPage ? .infinity : nil)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(panelFill)
        #if DEBUG
        .background(MainWindowChromeRegression.SurfaceBounds(.sidebar))
        #endif
        .foregroundColor(TapSkin.ink)
        // 贴边描边：和左侧槽位库面板同一手法，视觉上把它读成窗口 chrome 而不是浮层卡片。
        .overlay(alignment: .leading) {
            Rectangle().fill(AppTheme.subtleBorder).frame(width: 1)
        }
        .background(AgentPanelWindowWidthProbe { windowWidth = $0 })
        .overlay(alignment: .leading) {
            if !isFullPage {
                Color.clear.frame(width: 8).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            if dragStartWidth == nil { dragStartWidth = panelWidth }
                            liveWidth = WindowLayoutMetrics.agentPanelWidth(
                                requested: (dragStartWidth ?? panelWidth) - value.translation.width,
                                windowWidth: windowWidth)
                            #if DEBUG
                            Self.debugLiveWidth = liveWidth
                            #endif
                        }
                        .onEnded { _ in commitPanelWidth() })
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .accessibilityLabel("调整 Agent 面板宽度")
                    .accessibilityIdentifier("agent-panel-resize")
            }
        }
        .sheet(isPresented: $showConfig) { AgentConfigView(isWorkspace: model.usesWorkspaceBackend) }
        .sheet(isPresented: $showWorkflowLibrary, onDismiss: { inputFocusRequest += 1 }) {
            if let context = model.canvasContext { WorkflowSkillLibraryView(model: model, context: context) }
        }
        .alert("重命名对话", isPresented: $showRename) {
            TextField("对话标题", text: $renameTitle)
            Button("保存") { model.renameConversation(model.selectedConversationID, title: renameTitle) }
            Button("取消", role: .cancel) {}
        }
        .alert("编辑待发送消息", isPresented: $showQueueEdit) {
            TextField("消息内容", text: $queueEditText)
            Button("保存") { if let id = editingQueueID { model.editQueuedSubmission(id, text: queueEditText) } }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showLegacyCanvas) {
            if let legacyCanvasModel {
                LegacyCanvasHistoryView(model: legacyCanvasModel)
            }
        }
        .sheet(isPresented: $showLegacyEdit) {
            if let legacyEditModel {
                LegacyCanvasHistoryView(model: legacyEditModel, title: "旧版编辑记录")
            }
        }
        .onChange(of: workspaceMode) { _ in suggestionPage = 0 }
        .onChange(of: backendKind) { _ in refreshComposerSkills() }
        .onChange(of: conversationSource) { _ in
            voice.cancel()
            capture.cancel()
            followsLatest = true
            completion.dismiss()
            showReferencePicker = false
            showModelPicker = false
            showComposerAdd = false
            showCaptureMenu = false
            showContextInfo = false
            contextPinned = false
            inputFocusRequest += 1
        }
        .onChange(of: backendKind) { _ in credentialNotice = nil }
        .task(id: backendKind.rawValue + ":" + (ModelConfigurationBridge.profile(.agent)?.id ?? "")) {
            credentialNotice = nil
            guard !isReadOnly, model.requiresAPIKey else { return }
            #if DEBUG
            if credentialStateProvider == nil,
               Bundle.main.bundleIdentifier == "com.clipslots.app.canvas-v2174-test",
               ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1" {
                return
            }
            #endif
            let state: (hasKey: Bool, error: AgentKeychainError?)
            if let credentialStateProvider { state = await credentialStateProvider() }
            else {
                let profile = backendKind == .deepseek ? ModelConfigurationBridge.profile(.agent) : nil
                let result = await AgentKeychainProbe.keyState(service: profile?.keyService ?? AgentKeychain.service,
                    account: profile?.keyAccount ?? AgentKeychain.account)
                state = (result.hasKey, result.error)
            }
            guard !Task.isCancelled, model.requiresAPIKey else { return }
            credentialNotice = state.error?.localizedDescription
            if !state.hasKey, state.error == nil {
                if ModelConfigurationBridge.profile(.agent) != nil { credentialNotice = "请在模型 → 配置中心保存此模型的密钥。" }
                else { showConfig = true }
            }
        }
        .onDisappear { voice.cancel(); capture.cancel(); commitPanelWidth(); scrollTask?.cancel(); scrollTask = nil }
        .onAppear {
            model.applicationStore = marketSync
            AgentSkillLibrary.shared.refresh()
            refreshComposerSkills()
            inputFocusRequest += 1
        }
        .task { await marketSync.loadCached() }
        .onChange(of: model.needsConfiguration) { needs in
            guard needs, !isReadOnly else { return }
            showConfig = true
            model.needsConfiguration = false
        }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ name: String, height: CGFloat? = nil,
                                       @ViewBuilder content: @escaping () -> Content) -> some View {
        WorkspaceSectionAdmission(
            admission: sidebarAdmission(name),
            height: height, traceLabel: "sidebar-\(name)") {
                VStack(spacing: 0, content: content)
            }
    }

    private func inputSection<Content: View>(_ name: String,
                                            @ViewBuilder content: @escaping () -> Content) -> some View {
        WorkspaceSectionAdmission(admission: sidebarAdmission(name),
                                  traceLabel: "sidebar-\(name)", content: content)
    }

    private func sidebarAdmission(_ name: String) -> CanvasNodeAdmission {
        let id: String?
        switch name {
        case "header": id = "0-sidebar-header"
        case "transcript": id = "1-sidebar-transcript"
        case "input-context": id = "2-sidebar-context"
        case "input-tools": id = "3-sidebar-tools"
        default: id = nil
        }
        return id.flatMap { entryMounts?.admission(for: $0) } ?? .immediate
    }

    private func commitPanelWidth() {
        if let liveWidth, requestedWidth != Double(liveWidth) {
            requestedWidth = Double(liveWidth)
            #if DEBUG
            Self.debugWidthWrites += 1
            #endif
        }
        liveWidth = nil
        dragStartWidth = nil
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Button("新建对话", action: newConversation).disabled(isReadOnly)
                Button("重命名对话") {
                    renameTitle = model.currentConversationTitle; showRename = true
                }.disabled(isReadOnly)
                Button("从当前对话创建分支") { model.forkConversation() }.disabled(isReadOnly || model.isEmpty)
                Button("删除当前对话", role: .destructive) { model.deleteConversation(model.selectedConversationID) }
                    .disabled(isReadOnly)
                if legacyCanvasModel != nil {
                    Button("查看旧版画布记录") { showLegacyCanvas = true }
                }
                if legacyEditModel != nil {
                    Button("查看旧版编辑记录") { showLegacyEdit = true }
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
                        case .compaction(let entry):
                            return entry.phase == .finished ? "上下文已压缩" : "正在压缩上下文…"
                        case .taskSubagent(let entry):
                            switch entry.content {
                            case .tasks(let snapshot): return snapshot.tasks.compactMap { $0["subject"]?.stringValue }.joined(separator: "\n")
                            case .subagent(let state): return "\(state.agentType ?? "子任务") · \(state.status.label)\n\(state.text)"
                            }
                        }
                    }.joined(separator: "\n\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }.disabled(model.isEmpty)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 16))
                    Text(conversationTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: conversationMenuWidth)
            .accessibilityIdentifier("agent-conversation-menu")
            .overlay(alignment: .trailing) {
                // AppKit's borderless Menu label drops nested chevron images.
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundColor(TapSkin.faintInk)
                    .allowsHitTesting(false)
                    .accessibilityLabel("会话菜单展开标记")
                    .accessibilityIdentifier("agent-conversation-chevron")
            }
            .help("会话操作")
            Spacer(minLength: 0)
            iconButton("square.and.pencil", help: "新建对话", action: newConversation).disabled(isReadOnly)
            if let onToggleExpanded {
                iconButton(isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           help: isExpanded ? "还原 Agent 侧栏" : "Agent 全屏",
                           action: onToggleExpanded)
                    .accessibilityIdentifier("canvas-agent-expand")
            }
            if !isFullPage, onToggleExpanded == nil {
                iconButton("sidebar.right", help: "收起侧栏") {
                    withAnimation(Anim.transition) { isVisible = false }
                }
            }
            Menu {
                Button("Agent 设置") { showConfig = true }
                Button("管理技能") { showSkillPicker = true }
                Button("重命名对话") {
                    renameTitle = model.currentConversationTitle; showRename = true
                }
                if !isFullPage, onToggleExpanded != nil {
                    Button("收起侧栏") {
                        withAnimation(Anim.transition) { isVisible = false }
                    }.accessibilityIdentifier("agent-close-sidebar")
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 32)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
    }

    private var conversationTitle: String { model.currentConversationTitle }

    private var conversationMenuWidth: CGFloat {
        let titleWidth = (conversationTitle as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
        // Reserve icon, spacing and chevron inside the native button so the
        // indicator stays beside the title and clicking it opens the menu.
        return min(max(96, panelWidth - 160), ceil(titleWidth) + 44)
    }

    private func newConversation() {
        guard !isReadOnly else { return }
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
                            emptyState(width: geometry.size.width - (isFullPage ? 48 : 36))
                                .frame(minHeight: max(0, geometry.size.height - 60))
                        }

                        ForEach(model.transcript) { item in
                            // 每条历史始终对应一个布局节点，避免条件分支影响 lazy 滚动定位。
                            VStack(alignment: .leading, spacing: 0) {
                                switch item.kind {
                                case .user(let text):
                                    userBubble(text)
                                    if let context = model.canvasContext,
                                       let turn = model.messages.first(where: { $0.id.uuidString == item.id })?.canvasTurn {
                                        CanvasAgentCoverageView(turn: turn, receipts: model.canvasReadReceipts(for: turn),
                                                                context: context)
                                    }
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
                                    assistantBubble(text: text, reasoning: reasoning, isFailure: isFailure, copyText: item.copyText)
                                    if let context = model.canvasContext, !isFailure,
                                       let source = model.messages.first(where: { $0.id.uuidString == item.id }),
                                       !source.content.isEmpty {
                                        HStack(spacing: 16) {
                                            if !item.canvasChanged {
                                                Button("预览并填入选中节点") {
                                                    context.prepare(text: source.content, conversationID: model.selectedConversationID)
                                                }.accessibilityIdentifier("agent-canvas-preview")
                                            }
                                            Button("保存为 Skill") { model.prepareWorkflowSkill(messageID: item.id) }
                                                .accessibilityIdentifier("agent-save-workflow-skill")
                                        }
                                        .font(.system(size: 11)).buttonStyle(.plain)
                                        .foregroundColor(TapSkin.accent).padding(.top, 8)
                                        .disabled(model.isRunning || isReadOnly)
                                    }
                                    if !isFailure, let message = model.messages.first(where: { $0.id.uuidString == item.id }) {
                                        Button("从这里创建分支") { model.forkConversation(through: message.id) }
                                            .font(.system(size: 10)).buttonStyle(.plain).foregroundColor(TapSkin.faintInk)
                                            .disabled(isReadOnly || model.isRunning).padding(.top, 5)
                                    }
                                case .tools(let rows):
                                    toolRows(rows)
                                case .compaction(let entry):
                                    AgentCompactionCard(entry: entry)
                                case .taskSubagent(let entry):
                                    AgentTaskSubagentCard(entry: entry)
                                }
                            }
                        }

                        if model.isRunning {
                            let recordedIDs = Set(model.messages.flatMap(\.toolCalls).map(\.id))
                            let unrecorded = model.liveActivities.filter { !recordedIDs.contains($0.id) }
                            if !unrecorded.isEmpty { toolRows(unrecorded) }
                            if model.pendingInteractions.isEmpty || !model.streamingContent.isEmpty {
                                ForEach(model.streamingTranscript) { item in
                                    switch item.kind {
                                    case .assistant(let text, let reasoning, _):
                                        streamingBubble(text: text, reasoning: reasoning ?? "",
                                            showsThinking: item.isStreamingTail && model.showsThinking)
                                    case .compaction(let entry):
                                        AgentCompactionCard(entry: entry)
                                    case .taskSubagent(let entry):
                                        AgentTaskSubagentCard(entry: entry)
                                    case .tools, .user:
                                        EmptyView()
                                    }
                                }
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
                .onAppear { if !model.isEmpty && followsLatest { scrollToBottom(proxy) } }
                .onChange(of: model.streamingContent) { _ in if followsLatest { scrollToBottom(proxy) } }
                .onChange(of: model.streamingReasoning) { _ in if followsLatest { scrollToBottom(proxy) } }
                .onChange(of: model.contextCompactions) { _ in if followsLatest { scrollToBottom(proxy) } }
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

    private func emptyState(width: CGFloat) -> some View {
        let compact = !isFullPage || min(width, 560) < 428
        let layout = compact ? AnyLayout(VStackLayout(spacing: 20)) : AnyLayout(HStackLayout(spacing: 12))
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Hi，欢迎回来", systemImage: "sparkles")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundColor(TapSkin.secondaryInk)
                    .accessibilityIdentifier("agent-welcome-greeting")
                Text(workspaceMode == .edit ? "今天想怎样编辑槽位？" : "今天一起创作点什么？")
                    .font(.system(size: 26, weight: .medium))
                    .accessibilityIdentifier("agent-welcome-question")
            }
            .modifier(CreativeWelcomeReveal(token: model.selectedConversationID))
            layout {
                suggestionCard(suggestionPages[suggestionPage][0], index: 0, compact: compact)
                suggestionCard(suggestionPages[suggestionPage][1], index: 1, compact: compact)
            }
            .padding(.top, 6)
            HStack {
                Spacer()
                iconButton("arrow.2.squarepath", help: "换一组建议") {
                    suggestionPage = (suggestionPage + 1) % suggestionPages.count
                }
                .accessibilityIdentifier("agent-refresh-suggestions")
            }
        }
        .frame(maxWidth: isFullPage ? 560 : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var extensionEntry: some View {
        HStack(spacing: 8) {
            Button {
                completion.dismiss()
                showComposerAdd = false
                showReferencePicker = false
                showAppMarket = true
            } label: {
                HStack(spacing: 7) {
                    HStack(spacing: -3) {
                        ForEach(["puzzlepiece.extension", "square.grid.2x2", "folder"], id: \.self) { symbol in
                            Image(systemName: symbol).font(.system(size: 10))
                                .frame(width: 17, height: 17)
                                .background(panelFill, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text("应用市场").font(.system(size: 11, weight: .medium))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help("浏览应用市场与技能")
                .accessibilityIdentifier("agent-extension-entry")
            Button { dismissedExtensionEntry = true } label: {
                Image(systemName: "xmark").font(.system(size: 9)).frame(width: 15, height: 18)
            }.buttonStyle(.plain)
                .accessibilityLabel("关闭应用拓展入口")
                .accessibilityIdentifier("agent-extension-dismiss")
        }
        .foregroundColor(TapSkin.secondaryInk)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(TapSkin.tone(0xededee, 0x252525), in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private func suggestionCard(_ suggestion: AgentSuggestion, index: Int, compact: Bool) -> some View {
        CreativeSuggestionCard(category: suggestion.category, symbol: suggestion.symbol,
                               title: suggestion.title, detail: suggestion.detail,
                               index: index, compact: compact, fill: inputFill) {
            // #region debug-point C-D:suggestion-action
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_CONTROL_PROBE"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7784/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "slot-input-controls", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "C-D", "msg": "[DEBUG] suggestion action", "data": ["session": model.displayName, "title": suggestion.title]]); URLSession.shared.dataTask(with: r).resume() }
            #endif
            // #endregion
            draft = suggestion.prompt
            inputFocusRequest += 1
        }
        .accessibilityIdentifier("agent-suggestion-\(index)")
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

    private func assistantBubble(text: String, reasoning: String?, isFailure: Bool, copyText: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !isFullPage {
                Label("ClipSlots", systemImage: "sparkles")
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
                        .accessibilityIdentifier("agent-message-body")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(isFailure ? .orange : TapSkin.ink)
            if let copyText { copyButton(copyText) }
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

    private func streamingBubble(text: String, reasoning: String, showsThinking: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 14) {
                if !reasoning.isEmpty {
                    ReasoningDisclosure(text: reasoning,
                                        isStreaming: showsThinking && text.isEmpty) {
                        followsLatest = false
                    }
                }
                if !text.isEmpty {
                    AgentMarkdownText(text: text, style: textStyle)
                        .equatable()
                } else if reasoning.isEmpty && showsThinking {
                    HStack(spacing: 8) {
                        CreativeLoadingMark().frame(width: 24, height: 24)
                        Text(model.isWaitingForCredential ? "正在读取凭据…" : "正在处理…")
                            .font(.system(size: 13)).foregroundColor(TapSkin.secondaryInk)
                    }
                    if model.isWaitingForCredential {
                        Text("若 macOS 弹出钥匙串授权，请完成授权。此时尚未发送请求，可以随时停止。")
                            .font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
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
                    if !row.name.hasPrefix("canvas_") {
                        Text(row.argumentsPreview)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(AppTheme.canvasCardMetaInk)
                            .lineLimit(1)
                    }
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
         "mcpToolCall": "调用工具", "webSearch": "搜索网页",
         "canvas_overview": "查看画布概览", "canvas_nodes": "读取节点目录",
         "canvas_edges": "读取连线", "canvas_read_node": "读取节点资料",
         "canvas_read_run": "读取生成记录", "canvas_current": "查看当前画布",
         "canvas_get_node": "查看节点", "canvas_create_node": "新建节点",
         "canvas_edit_node": "修改正文", "canvas_configure_node": "调整生成参数",
         "canvas_move_node": "移动节点", "canvas_connect_nodes": "连接节点",
         "canvas_disconnect_edge": "断开连线", "canvas_group_nodes": "创建编组",
         "canvas_delete_nodes": "删除节点", "canvas_undo": "撤销画布操作",
         "canvas_redo": "重做画布操作", "canvas_generate": "生成素材"][name] ?? name
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
                    .disabled(isReadOnly)
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
        WorkspaceContentBoundary {
        VStack(alignment: .leading, spacing: isFullPage ? 0 : 6) {
            inputSection("input-context") {
            if !model.queuedSubmissions.isEmpty { queueView }
            if let error = voice.error {
                Text(error).font(.caption).foregroundColor(.orange).padding(.horizontal, 4)
            }
            if let credentialNotice {
                HStack(alignment: .top, spacing: 8) {
                    Text(credentialNotice).font(.system(size: 11)).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("设置") { showConfig = true }
                        .buttonStyle(.plain).font(.system(size: 11))
                }
                .padding(.horizontal, 4)
                .accessibilityIdentifier("agent-credential-notice")
            }
            VoiceRecordingStatus(voice: voice)
            }

            VStack(spacing: 8) {
                WorkspaceContentBoundary {
                if let context = model.canvasContext {
                    CanvasAgentComposer(model: model, context: context)
                        .padding(.horizontal, 12)
                }
                if model.isAddingSkill || !model.draftSkillReferences.isEmpty || model.isPolishing {
                    composerToolbar.padding(.horizontal, 10).padding(.top, 9)
                }
                if let error = model.polishError {
                    Text(error).font(.system(size: 11)).foregroundColor(.orange)
                        .lineLimit(2).help(error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                }
                if completion.isOpen {
                    AgentComposerMenu(completion: completion, isScanning: skillLibrary.isScanning)
                        .padding(.horizontal, 8).padding(.top, 8)
                }
                if !model.draftAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.draftAttachments) { file in
                                HStack(spacing: 5) {
                                    if let data = file.imageSnapshot ?? file.sampledFrames?.first?.imageSnapshot,
                                       let image = NSImage(data: data) {
                                        Image(nsImage: image).resizable().scaledToFit()
                                            .frame(width: 32, height: 32)
                                            .accessibilityLabel(file.name + " 图片预览")
                                    } else { Image(systemName: "doc") }
                                    Text(file.name).lineLimit(1)
                                    if file.sampledFrames != nil { Text("3 帧 · 无音轨").foregroundColor(.secondary) }
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
                }
                inputSection("input-editor") {
                AgentDraftEditor(text: $model.draft, focusRequest: inputFocusRequest,
                                 conversationID: model.selectedConversationID,
                                 sourceID: ObjectIdentifier(model),
                                 replacementID: model.polishReplacementID,
                                 isEditable: !isReadOnly && !voice.isRecording && !voice.isStarting,
                                 placeholder: "随心输入",
                                 completion: completion, completionItems: composerItems,
                                 onCompletion: performComposerAction, onSend: send)
                    .frame(height: draftHeight)
                    .padding(.horizontal, 9)
                    .padding(.top, 2)
                    .accessibilityLabel("Agent 输入")
                }

                inputSection("input-tools") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        composerContextControls
                        Spacer(minLength: 0)
                        contextUsageButton
                        composerRunControls
                    }
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            composerContextControls
                            Spacer(minLength: 0)
                            contextUsageButton
                        }
                        HStack(spacing: 6) {
                            Spacer(minLength: 0)
                            composerRunControls
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                }
            }
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(inputFill)
                    .shadow(color: .black.opacity(isFullPage ? 0.035 : 0), radius: 12, y: 2)
                    .overlay {
                        ComposerEntranceGlow(token: "\(model.selectedConversationID):\(model.isPolishing)",
                                             active: model.isPolishing || (model.isEmpty && !model.isRunning),
                                             repeating: model.isPolishing)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
            }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(hairline.opacity(0.7), lineWidth: 0.5))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, isFullPage ? 20 : 10)
        .padding(.top, 6)
        #if DEBUG
        .background(MainWindowChromeRegression.SurfaceBounds(.composer))
        #endif
        }
    }

    @ViewBuilder private var composerContextControls: some View {
        composerAddMenu
        AgentWorkingDirectoryPicker(model: model, directories: model.workingDirectories, compact: true)
        AgentApprovalPicker(model: model)
        captureControls
    }

    @ViewBuilder private var composerRunControls: some View {
        AgentPolishButton(busy: model.isPolishing,
            enabled: !isReadOnly && !model.isRunning && !voice.isRecording && !voice.isStarting
                && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            compact: true) {
                showModelPicker = false
                completion.dismiss()
                model.polishDraft(config: currentConfig)
            }
            .accessibilityIdentifier("agent-ai-polish")
        modelPicker
        Button {
            if voice.isRecording || voice.isStarting { voice.stop() }
            else {
                let conversation = model.selectedConversationID
                let initial = model.draft
                voice.start { text in
                    guard model.selectedConversationID == conversation else { return }
                    model.draft = initial + (initial.isEmpty ? "" : "\n") + text
                }
            }
        } label: {
            Image(systemName: voice.isStarting ? "stop.circle" : voice.isRecording ? "waveform" : "mic")
                .foregroundColor(voice.isRecording || voice.isStarting ? TapSkin.accent : TapSkin.secondaryInk)
                .frame(width: 26, height: 30)
        }.buttonStyle(.plain)
            .help(voice.isRecording || voice.isStarting ? "停止语音输入" : "本地语音输入")
            .accessibilityLabel(voice.isStarting ? "取消语音输入" : voice.isRecording ? "停止语音输入" : "语音输入")
            .accessibilityIdentifier("agent-voice-input")
        if model.isRunning {
            Button(action: send) {
                Image(systemName: "text.badge.plus").frame(width: 30, height: 30)
            }.buttonStyle(.plain).disabled(!canSend).help("加入待发送队列 · Enter")
                .accessibilityIdentifier("agent-enqueue")
        }
        Button {
            if model.isRunning { model.stop() } else { send() }
        } label: {
            Image(systemName: model.isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(inputFill)
                .frame(width: 34, height: 34)
                .background(TapSkin.ink.opacity(canSend || model.isRunning ? 1 : 0.35), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !model.isRunning)
        .help(model.isRunning ? "停止生成" : "Enter 发送 · Shift+Enter 换行")
        .accessibilityLabel(model.isRunning ? "停止生成" : "发送")
        .accessibilityIdentifier("agent-send-stop")
    }

    private var captureControls: some View {
        HStack(spacing: 0) {
            Button {
                if capture.isCapturing { capture.cancel() }
                else { capture.start(.image, model: model) }
            } label: {
                Image(systemName: capture.isCapturing ? "xmark" : "scissors")
                    .font(.system(size: 13)).frame(width: 25, height: 30)
            }.buttonStyle(.plain)
                .help(capture.isCapturing ? "取消截取" : "截图")
                .accessibilityLabel(capture.isCapturing ? "取消截取" : "截图")
                .accessibilityIdentifier("agent-screen-capture")
            Button { showCaptureMenu.toggle() } label: {
                Image(systemName: "chevron.up").font(.system(size: 7)).frame(width: 10, height: 30)
            }.buttonStyle(.plain)
                .help("截图与录屏")
                .accessibilityLabel("截图与录屏")
                .accessibilityIdentifier("agent-capture-menu")
                .disabled(capture.isCapturing)
                .popover(isPresented: $showCaptureMenu, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        captureMenuItem("录屏", symbol: "video", kind: .video)
                            .accessibilityIdentifier("agent-capture-record")
                        captureMenuItem("截图", symbol: "scissors", kind: .image)
                            .accessibilityIdentifier("agent-capture-image")
                    }
                    .padding(8).frame(width: 160)
                    .foregroundColor(TapSkin.ink).background(TapSkin.tone(0xffffff, 0x202020))
                }
        }.fixedSize().disabled(model.isImportingAttachments)
    }

    private func captureMenuItem(_ title: String, symbol: String, kind: AgentScreenCapture.Kind) -> some View {
        Button {
            showCaptureMenu = false
            DispatchQueue.main.async { capture.start(kind, model: model) }
        } label: {
            Label(title, systemImage: symbol).font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var composerAddMenu: some View {
        Button { showComposerAdd.toggle() } label: {
            Image(systemName: "plus").font(.system(size: 13))
                .frame(width: 26, height: 26)
                .background(inputFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(hairline.opacity(0.7), lineWidth: 0.5))
        }
        .buttonStyle(.plain).fixedSize()
        .accessibilityIdentifier("agent-composer-add")
        .background(AgentComposerMenuPresenter(presented: $showComposerAdd,
            content: AgentComposerAddMenu(model: model, sync: marketSync, localItems: composerItems,
                fromCanvas: {
                    showComposerAdd = false
                    model.canvasContext?.addSelection(to: model); inputFocusRequest += 1
                }, attach: {
                    showComposerAdd = false
                    DispatchQueue.main.async { model.chooseAttachments() }
                }, directory: {
                    showComposerAdd = false
                    DispatchQueue.main.async { model.workingDirectories.choose { model.selectWorkingDirectory($0) } }
                }, manage: openApplicationManager, importSkill: uploadSkill, createSkill: {
                    openApplicationManager("创建技能")
                }, localPick: referenceLocalSkill, onUse: finishApplicationReference,
                workflowLibrary: model.canvasContext == nil ? nil : openWorkflowLibrary)))
        .popover(isPresented: $showReferencePicker, arrowEdge: .top) {
            applicationPicker
        }
        .popover(isPresented: $showSkillPicker, arrowEdge: .top) {
            AgentSkillPickerView(builtinToolCount: AgentBuiltinTools().specs().count)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("agent-extension-picker")
        }
    }

    private var applicationPicker: some View {
        AgentInstalledApplicationList(model: model, sync: marketSync, localItems: composerItems,
            localPick: referenceLocalSkill, onUse: finishApplicationReference,
            onManage: { openApplicationManager("应用") })
    }

    private func referenceLocalSkill(_ action: AgentComposerItem.Action) async throws -> Bool {
        guard case .skill(let name, let path) = action else { return false }
        let entry = (skillLibrary.workflowEntries[model.canvasProjectID ?? ""] ?? []).first {
            WorkflowSkillStore().markdownURL($0).path == path
        }
        return try await model.referenceSkill(name: name, path: path, workflow: entry)
    }

    private func finishApplicationReference() {
        showComposerAdd = false; showReferencePicker = false
        inputFocusRequest += 1
    }

    private func openApplicationManager(_ tab: String) {
        showComposerAdd = false; showReferencePicker = false; marketTab = tab
        DispatchQueue.main.async { applicationManagerRequest.open(tab) }
    }

    private func openWorkflowLibrary() {
        guard model.canvasContext != nil else { return }
        showComposerAdd = false
        showReferencePicker = false
        DispatchQueue.main.async { showWorkflowLibrary = true }
    }

    private func uploadSkill(folder: Bool) {
        showComposerAdd = false; showReferencePicker = false
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
            panel.allowsMultipleSelection = false
            panel.message = folder ? "选择包含 SKILL.md 的技能文件夹" : "选择技能文件"
            panel.begin { result in
                if result == .OK, let url = panel.url {
                    Task {
                        do { try await marketSync.importManagedSkill(url, folder: folder) }
                        catch { model.errorText = error.localizedDescription }
                    }
                }
            }
        }
    }

    private func addMenuItem(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            showComposerAdd = false
            DispatchQueue.main.async(execute: action)
        } label: {
            Label(title, systemImage: symbol).font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// A bounded horizontal strip keeps references from changing the editor's
    /// vertical position or pushing the polish control outside a narrow panel.
    private var composerToolbar: some View {
        HStack(spacing: 8) {
            skillButton.fixedSize(horizontal: true, vertical: false)
            if model.isAddingSkill {
                ProgressView().controlSize(.small).frame(width: 16, height: 30)
            }
            if model.draftSkillReferences.isEmpty {
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.draftSkillReferences) { skill in
                            HStack(spacing: 5) {
                                Image(systemName: skill.applicationID == nil ? "sparkles" : "square.grid.2x2")
                                Text(skill.name).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: 180)
                                Button {
                                    model.draftSkillReferences.removeAll { $0.id == skill.id }
                                } label: {
                                    Image(systemName: "xmark").frame(width: 18, height: 26)
                                }
                                .buttonStyle(.plain)
                                .help("移除引用")
                                .accessibilityLabel("移除引用 · " + skill.name)
                                .accessibilityIdentifier("agent-remove-skill-\(skill.id)")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.leading, 8).padding(.trailing, 4)
                            .frame(height: 30)
                            .background(TapSkin.accent.opacity(0.10),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .help("本轮引用 · " + skill.name)
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: 30)
                .accessibilityIdentifier("agent-skill-references")
            }
            if model.isPolishing {
                Button("取消") { model.cancelPolish() }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .fixedSize()
            }
        }
        .frame(height: 32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-composer-toolbar")
    }

    private var canSend: Bool {
        !isReadOnly && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.draftAttachments.isEmpty
            || !model.draftReferences.isEmpty || !model.draftSkillReferences.isEmpty)
            && !model.isAddingSkill && !model.isPolishing && !model.isImportingAttachments
            && model.canvasContext?.isLoadingReferences != true
    }

    private var draftHeight: CGFloat {
        let bounds = (draft as NSString).boundingRect(
            with: CGSize(width: (isFullPage ? 760 : panelWidth) - 54, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        return min(180, max(isFullPage ? 84 : 60, ceil(bounds.height) + 8))
    }

    private var skillButton: some View {
        Button {
            completion.dismiss()
            showModelPicker = false
            showReferencePicker.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .regular))
                Text("应用")
                    .font(.system(size: 11, weight: .medium))
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
            .frame(height: 30)
            .foregroundColor(TapSkin.secondaryInk)
            .background(showReferencePicker ? CreativeMenuStyle.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("添加或引用应用与技能 · 也可输入 $ 搜索技能")
        .accessibilityIdentifier("agent-reference-skill")
        .disabled(model.isAddingSkill)
        .contextMenu {
            if model.canvasProjectID == nil {
                Button("管理可执行技能…") { showSkillPicker = true }
            }
        }
    }

    private var composerItems: [AgentComposerItem] {
        var items: [AgentComposerItem] = [
            .init(id: "skills", title: "/skills", detail: "选择本轮引用的技能规范", action: .skills),
            .init(id: "model", title: "/model", detail: "模型与推理设置", action: .model),
            .init(id: "new", title: "/new", detail: "保存当前对话并新建", action: .newConversation)
        ]
        if model.canvasContext != nil {
            items.append(.init(id: "summarize", title: "/summarize", detail: "总结画布创作方法，预览后保存 Skill", action: .summarize))
        }
        // Local catalog is cached; no scanning or network requests on keystrokes.
        var seen = Set<String>()
        for entry in skillLibrary.workflowEntries[model.canvasProjectID ?? ""] ?? [] {
            let path = WorkflowSkillStore().markdownURL(entry).path
            seen.insert(path)
            items.append(.init(id: path, title: "$" + entry.name, detail: entry.sourceLabel + " · " + entry.summary,
                               action: .skill(name: entry.name, path: path)))
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
        case .model:
            showReferencePicker = false
            completion.dismiss()
            showModelPicker = true
        case .newConversation: newConversation()
        case .summarize: draft = CanvasAgentContext.summarizePrompt
        case .skill(let name, let path):
            let entry = (skillLibrary.workflowEntries[model.canvasProjectID ?? ""] ?? []).first {
                WorkflowSkillStore().markdownURL($0).path == path
            }
            model.addSkillReference(name: name, path: path, workflow: entry)
        }
    }

    private func refreshComposerSkills() {
        skillLibrary.refreshWorkflows(projectID: model.canvasProjectID)
    }

    // MARK: 动作

    private var contextCapacityLine: String {
        if let observation = currentContextDisplay {
            return observation.percentage.map { String(format: " · 上下文 %.1f%%", $0) } ?? ""
        }
        guard let tokens = currentPromptTokens,
              let capacity = modelCatalog.models.first(where: { $0.id == modelLabel })?.contextWindow else { return "" }
        let percentage = Double(tokens) * 100 / Double(capacity)
        return String(format: " · 最近请求上下文 %.1f%%", percentage)
    }

    private var currentContextUsage: AgentContextUsage? {
        guard let usage = model.contextUsage, usage.model == modelLabel,
              usage.endpoint == currentConfig.endpoint else { return nil }
        return usage
    }

    private var currentPromptTokens: Int? {
        if model.isEmpty && !model.isRunning { return 0 }
        guard model.contextObservation.snapshot == nil else { return nil }
        return currentContextUsage == nil ? nil : model.reportedPromptTokens
    }

    private var currentContextDisplay: AgentContextUsageDisplay? {
        model.contextDisplay(model: modelLabel, endpoint: currentConfig.endpoint)
    }

    private var contextUsedText: String {
        currentContextDisplay?.usedTokens.map { $0.formatted() }
            ?? currentPromptTokens.map { $0.formatted() } ?? "—"
    }

    private var contextFraction: Double? {
        if let observation = currentContextDisplay { return observation.fraction }
        if model.isEmpty && !model.isRunning { return 0 }
        guard let tokens = currentPromptTokens,
              let capacity = modelCatalog.models.first(where: { $0.id == modelLabel })?.contextWindow else { return nil }
        return min(1, max(0, Double(tokens) / Double(capacity)))
    }

    private var contextUsageButton: some View {
        Button {
            contextPinned.toggle()
            showContextInfo = contextPinned
        } label: {
            ZStack {
                Circle().stroke(TapSkin.secondaryInk.opacity(0.28), lineWidth: 2.5)
                if let fraction = contextFraction {
                    Circle().trim(from: 0, to: fraction)
                        .stroke(TapSkin.secondaryInk, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }.frame(width: 14, height: 14).frame(width: 26, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("上下文 \(contextUsedText) tokens\(contextCapacityLine)")
        .accessibilityLabel(currentContextDisplay?.statusLabel ?? "最近请求上下文用量")
        .accessibilityIdentifier("agent-context-usage")
        .onHover { if !contextPinned { showContextInfo = $0 } }
        .onChange(of: showContextInfo) { if !$0 { contextPinned = false } }
        .onChange(of: modelLabel) {
            model.contextConfigurationChanged(model: $0, endpoint: currentConfig.endpoint)
        }
        .onChange(of: currentConfig.endpoint) {
            model.contextConfigurationChanged(model: modelLabel, endpoint: $0)
        }
        .popover(isPresented: $showContextInfo, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("上下文占用").font(.system(size: 12, weight: .semibold))
                HStack {
                    Text("已用 token")
                    Spacer()
                    Text(contextUsedText)
                }.font(.system(size: 11)).monospacedDigit()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("已用 token：" + contextUsedText)
                    .accessibilityIdentifier("agent-context-used")
                HStack {
                    Text("占比")
                    Spacer()
                    Text(contextPercentageText)
                }.font(.system(size: 11)).monospacedDigit()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("占比：" + (contextFraction == nil ? "未知" : contextPercentageText))
                    .accessibilityIdentifier("agent-context-percentage")
                if let observation = currentContextDisplay {
                    Text(observation.statusLabel + " · " + observation.sourceLabel)
                        .font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk)
                    if let capacity = observation.maxTokens {
                        Text("容量 \(capacity.formatted()) tokens")
                            .font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk)
                    }
                } else if let capacity = modelCatalog.models.first(where: { $0.id == modelLabel })?.contextWindow {
                    Text("容量 \(capacity.formatted()) tokens").font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk)
                }
                if let usage = currentContextUsage {
                    Divider()
                    contextRow("工作区", tokens: usage.workspace, color: .purple)
                    contextRow("工具调用与 Agent", tokens: usage.toolsAndAgent, color: .blue)
                    contextRow("历史消息", tokens: usage.history, color: .orange)
                    contextRow("系统指令", tokens: usage.system, color: .green)
                }
                let pending = AgentContextUsage.estimate(AgentMessage(role: .user, content: draft,
                    attachments: model.draftAttachments, canvasReferences: model.draftReferences,
                    skillReferences: model.draftSkillReferences).wireContent)
                if pending > 0 { contextRow("待发送内容", tokens: pending, color: TapSkin.secondaryInk) }
                if currentContextUsage != nil || pending > 0 {
                    Text("分项为文本估算；总量以服务返回为准，包含图像用量。")
                    .font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(12).frame(width: currentContextUsage == nil && draft.isEmpty && model.draftReferences.isEmpty
                && model.draftAttachments.isEmpty && model.draftSkillReferences.isEmpty ? 180 : 260, alignment: .leading)
                .foregroundColor(TapSkin.ink).background(TapSkin.tone(0xffffff, 0x222222))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("agent-context-popover")
        }
    }

    private var contextPercentageText: String {
        if let observation = currentContextDisplay {
            return observation.percentage.map { $0 == 0 ? "0%" : String(format: "%.1f%%", $0) } ?? "—"
        }
        return contextFraction.map { $0 == 0 ? "0%" : String(format: "%.1f%%", $0 * 100) } ?? "—"
    }

    private func contextRow(_ title: String, tokens: Int, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
            Spacer()
            Text("≈ " + tokens.formatted()).monospacedDigit()
        }.font(.system(size: 11))
    }

    private var currentConfig: AgentConfig {
        var config = AgentPreferences.config(model: modelName,
                                systemPrompt: systemPrompt,
                                thinkingRaw: thinkingRaw,
                                reasoningEffort: reasoningEffort,
                                endpoint: endpoint)
        if backendKind == .gateway {
            config.model = modelLabel
            if let gatewayEndpoint = AgentGatewayPreferences.endpoint() { config.endpoint = gatewayEndpoint }
        }
        config.supportsImageInput = backendKind != .tika && modelCatalog.supportsImages(
            model: modelLabel,
            endpoint: backendKind == .gateway ? AgentGatewayPreferences.endpoint() : URL(string: endpoint),
            gateway: backendKind == .gateway)
        return config
    }

    private var modelPicker: some View {
        Button {
            showReferencePicker = false
            completion.dismiss()
            showModelPicker.toggle()
            if showModelPicker { refreshModelCatalog() }
        } label: {
            Group {
                if modelLabel.lowercased().contains("deepseek") {
                    AgentBrandIcon(identifier: "deepseek", size: 19)
                } else {
                    Image(systemName: backendKind == .gateway ? "cpu" : "circle.hexagongrid")
                        .font(.system(size: 14))
                }
            }
                .foregroundColor(TapSkin.ink)
                .frame(width: 26, height: 30)
                .background(showModelPicker ? TapSkin.subtleFill : .clear, in: Circle())
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .disabled(model.isRunning || model.isPolishing)
            .help("当前模型：" + modelLabel)
            .accessibilityLabel("当前模型：" + modelLabel)
            .accessibilityIdentifier("agent-model-picker")
            .agentModelPopover(isPresented: $showModelPicker) {
                AgentSidebarModelPicker(options: agentModelOptions, selected: backendKind == .deepseek
                    ? ModelConfigurationBridge.profile(.agent).map { "profile:" + $0.id } ?? modelLabel : modelLabel,
                    loading: modelCatalog.isLoading, notice: modelCatalog.error, compactDetails: false,
                    refresh: refreshModelCatalog,
                    settings: { showModelPicker = false; showConfig = true },
                    reasoningEffort: reasoningEffort,
                    effortModelIDs: backendKind == .deepseek
                        ? Set(agentModelOptions.filter { $0.id.lowercased().hasPrefix("deepseek") }.map(\.id)) : [],
                    changeEffort: { choice, effort in
                        guard backendKind == .deepseek, !model.isRunning,
                              agentModelOptions.contains(where: { $0.id == choice && $0.available }),
                              ["low", "high", "max"].contains(effort) else { return }
                        modelName = choice
                        reasoningEffort = effort
                        thinkingRaw = AgentThinkingMode.enabled.rawValue
                    }) { choice in
                        guard agentModelOptions.contains(where: { $0.id == choice && $0.available }) else { return }
                        showModelPicker = false
                        if choice.hasPrefix("profile:") {
                            let id = String(choice.dropFirst(8))
                            Task {
                                await ModelWorkspaceStore.shared.setDefault(.agent, id: id)
                                AgentBackendCoordinator.setKind(.deepseek, for: model.usesWorkspaceBackend ? .workspace : .sidebar)
                                model.reloadBackendSelection()
                            }
                            inputFocusRequest += 1
                            return
                        }
                        if backendKind == .deepseek { modelName = choice }
                        if backendKind == .gateway {
                            UserDefaults.standard.set(choice, forKey: AgentGatewayPreferences.modelKey)
                            model.reloadBackendSelection()
                        }
                        inputFocusRequest += 1
                    }
            }
    }

    private func refreshModelCatalog() {
        if backendKind == .tika { return }
        if backendKind == .deepseek, ModelConfigurationBridge.profile(.agent) != nil { return }
        let selectedEndpoint = backendKind == .gateway
            ? AgentGatewayPreferences.endpoint() : URL(string: endpoint)
        if let selectedEndpoint { modelCatalog.refresh(endpoint: selectedEndpoint, gateway: backendKind == .gateway) }
    }

    private var agentModelOptions: [AgentDiscoveredModel] {
        let configured = ModelConfigurationBridge.agentProfiles().map { profile in
            AgentDiscoveredModel(id: "profile:" + profile.id, contextWindow: nil, supportsImages: profile.supportsImages,
                displayName: profile.name, description: "\(profile.model) · \(profile.endpoint)")
        }
        if !configured.isEmpty { return configured }
        if backendKind != .tika, !modelCatalog.models.isEmpty {
            if modelCatalog.models.contains(where: { $0.id == modelLabel }) { return modelCatalog.models }
            return [.init(id: modelLabel, contextWindow: nil, supportsImages: nil,
                          description: "已保存的模型 ID，当前服务列表未列出。可在模型设置中修改。")]
                + modelCatalog.models
        }
        switch backendKind {
        case .tika:
            return [.init(id: "Tika Agent", contextWindow: nil, supportsImages: nil,
                          description: "模型由 Tika 后端配置。可在服务设置中管理连接。")]
        case .gateway:
            let current = UserDefaults.standard.string(forKey: AgentGatewayPreferences.modelKey) ?? AgentGatewayPreferences.defaultModel
            return [.init(id: current, contextWindow: nil, supportsImages: nil,
                          description: "模型与服务地址在 Agent 设置中配置。")]
        case .deepseek:
            return [.init(id: modelName, contextWindow: nil, supportsImages: nil,
                          description: "使用已保存的模型 ID 和服务连接；查询成功后显示服务模型列表。")]
        }
    }

    private var currentSkills: [AgentSkill] {
        AgentSkillLibrary.shared.skills(withSlugs: enabledSlugs)
    }

    private func send() {
        voice.cancel()
        let text = draft
        guard canSend else { return }
        followsLatest = true
        if model.send(text: text, config: currentConfig, enabledSkills: currentSkills) { draft = "" }
    }

    private var queueView: some View {
        DisclosureGroup("待发送 · \(model.queuedSubmissions.count)") {
            ForEach(Array(model.queuedSubmissions.enumerated()), id: \.element.id) { index, submission in
                HStack(spacing: 6) {
                    Text("\(index + 1)").foregroundColor(TapSkin.faintInk)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(submission.text).lineLimit(2)
                        if let status = model.queuedSteerStatus(submission) {
                            Text(status).foregroundColor(TapSkin.faintInk)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        editingQueueID = submission.id; queueEditText = submission.text; showQueueEdit = true
                    } label: { Image(systemName: "pencil") }.help("编辑")
                        .disabled(submission.hotRunID != nil)
                    if submission.hotReceipt?.state == .returned {
                        Button("恢复草稿") { model.restoreReturnedSteerDraft(submission.id) }
                    } else if backendKind == .gateway
                        && (model.isRunning || model.canResumeGateway || submission.hotRunID != nil) {
                        Button(submission.hotRunID != nil ? "核对追加"
                               : model.canHotSteer ? "追加指令" : "停止后发送") {
                            model.steerQueuedSubmission(submission.id)
                        }
                            .disabled(model.isControllingRun || isReadOnly)
                            .accessibilityIdentifier("agent-gateway-steer")
                    }
                    Button { model.moveQueuedSubmission(submission.id, by: -1) } label: {
                        Image(systemName: "arrow.up")
                    }.disabled(index == 0 || submission.hotRunID != nil).help("上移")
                    Button { model.removeQueuedSubmission(submission.id) } label: {
                        Image(systemName: "xmark")
                    }.help("移除").disabled(submission.hotRunID != nil)
                }.buttonStyle(.plain).padding(.vertical, 4)
            }
            if let reason = model.queuePauseReason {
                Text(reason).foregroundColor(.orange)
                Button("继续发送") { model.resumeQueue() }
                    .disabled(model.isRunning || model.canResumeGateway || model.isControllingRun || isReadOnly)
            }
        }
        .font(.system(size: 11)).padding(10)
        .background(inputFill, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("agent-queue")
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
            .init(category: "创作方法", symbol: "paintpalette", title: "把这个项目的风格做成 Skill",
                  detail: "沉淀题材、视觉关键词和镜头语言。",
                  prompt: CanvasAgentContext.summarizePrompt),
            .init(category: "视频分镜", symbol: "sparkles", title: "用 MiniMax H3 创作有声多镜头短片",
                  detail: "同步设计镜头、对白、环境声和音乐。",
                  prompt: "帮我用 MiniMax H3 规划有声多镜头短片。先了解主题、时长与视觉风格，再查询实际可用模型；仅在服务确实提供该模型和音频能力时使用，否则明确说明限制。先预览分镜和提示词，确认后再生成。")
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
