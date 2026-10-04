import SwiftUI
import AppKit
import ClipSlotsKit

/// Only this subtree observes token updates; the slot grid and canvas stay outside.
struct AgentWorkspaceView: View {
    @ObservedObject var model: AgentChatModel
    @State private var search = ""
    @State private var showConfig = false
    @State private var page: CodexPage = .chat
    @State private var navigationVisible = true
    @State private var automationDraft: CodexAutomation?
    @ObservedObject private var desktop = CodexWorkspaceModel.shared
    @ObservedObject private var automations = CodexAutomationModel.shared
    @FocusState private var searchFocused: Bool

    private var remoteHistory: [CodexThreadSummary] {
        guard model.isCodex else { return [] }
        return desktop.threads.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                || $0.cwd.localizedCaseInsensitiveContains(search)
        }
    }

    private var history: [AgentChatModel.SavedConversation] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.recentConversations.filter { saved in
            let inDesktop = model.isCodex && desktop.threads.contains { $0.id == saved.codexThreadID }
            return !inDesktop && (query.isEmpty || saved.title.localizedCaseInsensitiveContains(query)
                || saved.messages.contains { $0.content.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            if navigationVisible {
                if page == .chat { navigation } else { pageNavigation }
            }
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TapSkin.tone(0xffffff, 0x111111))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TapSkin.tone(0xfafafa, 0x111111))
        .sheet(isPresented: $showConfig) { AgentConfigView(isWorkspace: true) }
        .onAppear { desktop.refresh(chat: model) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            desktop.refresh(chat: model)
        }
        .onChange(of: model.isRunning) { running in
            if !running { desktop.refresh(chat: model) }
        }
    }

    private var rail: some View {
        VStack(spacing: 18) {
            railButton("sidebar.left", "展开或收起会话栏") { navigationVisible.toggle() }
            railButton("house", "主页", selected: page == .chat) { page = .chat }
            railButton("clock", "定时任务", selected: page == .automations) { page = .automations }
            railButton("square.stack.3d.up", "Skills 与 MCP", selected: page == .tools) { page = .tools }
            Menu {
                Button("项目") { page = .projects }
                Button("代码审查") { page = .review }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17)).frame(width: 36, height: 34)
            }.menuStyle(.borderlessButton).fixedSize().help("更多").accessibilityLabel("更多")
            Spacer()
            railButton("circle.lefthalf.filled", "切换深浅外观") {
                AppearanceDefaults.currentRawValue = AppearanceDefaults.currentRawValue == ThemeMode.light.rawValue
                    ? ThemeMode.dark.rawValue : ThemeMode.light.rawValue
            }
            railButton("gearshape", "连接与设置") { showConfig = true }
        }
        .padding(.vertical, 18)
        .frame(width: 52)
        .background(TapSkin.tone(0xf4f4f4, 0x151515))
    }

    private func railButton(_ image: String, _ title: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image).font(.system(size: 17))
                .foregroundColor(selected ? TapSkin.ink : TapSkin.secondaryInk).frame(width: 36, height: 34)
                .background(selected ? TapSkin.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
            .accessibilityIdentifier("codex-nav-\(title)")
    }

    private func newConversation() {
        page = .chat
        desktop.cancelSelection()
        model.clearHistory()
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .chat:
            AgentSidebarView(model: model, isVisible: .constant(true), workspaceMode: .agent)
        case .automations:
            CodexAutomationsView(chat: model, editing: $automationDraft, openThread: openThread)
        case .projects:
            CodexProjectsView(chat: model) { page = .chat }
        case .review:
            CodexReviewView(chat: model, openThread: openThread)
        case .tools:
            CodexToolsView(chat: model, embedded: true) { page = .chat }
        }
    }

    private func openThread(_ id: String) {
        guard !model.isRunning else { return }
        page = .chat
        desktop.loadThread(id, chat: model)
    }

    private var pageNavigation: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(page.title).font(.system(size: 19, weight: .semibold)).frame(height: 52)
            if page == .automations {
                Button {
                    var task = CodexAutomation()
                    task.cwd = model.codexContext?.cwd ?? AgentBackendCoordinator.codexConfiguration().workingDirectory
                    task.model = model.codexContext?.model ?? desktop.settings.model
                    task.provider = model.codexContext?.provider ?? desktop.settings.provider
                    automationDraft = task
                } label: {
                    Label("新建任务", systemImage: "plus").font(.system(size: 14, weight: .medium))
                }.buttonStyle(.plain)
                Text("即将执行").font(.system(size: 12, weight: .medium)).foregroundColor(TapSkin.secondaryInk)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(automations.tasks.filter(\.enabled).sorted { $0.nextRun < $1.nextRun }) { task in
                            Button { automationDraft = task } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(task.name).font(.system(size: 12, weight: .medium))
                                    Text(task.nextRun, style: .relative).font(.caption).foregroundColor(.secondary)
                                }
                            }.buttonStyle(.plain).help("编辑任务")
                        }
                        if automations.tasks.filter(\.enabled).isEmpty {
                            Text("暂无已安排的任务").font(.system(size: 12)).foregroundColor(TapSkin.faintInk)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { Spacer(minLength: 0) }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 4) {
                pageLink(.chat, "house")
                pageLink(.automations, "clock")
                pageLink(.projects, "folder")
                pageLink(.review, "checkmark.bubble")
                pageLink(.tools, "square.stack.3d.up")
            }
        }.padding(.horizontal, 16).padding(.bottom, 16).frame(width: 238)
            .frame(maxHeight: .infinity).background(TapSkin.tone(0xfafafa, 0x191919))
            .foregroundColor(TapSkin.ink)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Text(model.isCodex ? "Codex" : "Agent")
                    .font(.system(size: 19, weight: .semibold))
                    .accessibilityIdentifier("agent-workspace-title")
                Spacer(minLength: 0)
                Button { desktop.refresh(chat: model) } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 26, height: 30)
                }.buttonStyle(.plain).help("刷新桌面会话").disabled(desktop.isRefreshing)
                Button { searchFocused = true } label: {
                    Image(systemName: "magnifyingglass").frame(width: 24, height: 30)
                }.buttonStyle(.plain).help("搜索对话")
            }
            .frame(height: 52)

            Button { newConversation() } label: {
                Label("新建对话", systemImage: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agent-new-conversation")

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundColor(TapSkin.faintInk)
                TextField("搜索对话", text: $search).textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("搜索对话")
                    .accessibilityIdentifier("agent-history-search")
            }
            .font(.system(size: 12))
            .padding(10)
            .background(TapSkin.tone(0xeceef1, 0x202020), in: RoundedRectangle(cornerRadius: 8))

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    Text("当前对话").font(.system(size: 10, weight: .medium))
                        .foregroundColor(TapSkin.faintInk).padding(.vertical, 7)
                    HStack(spacing: 8) {
                        Image(systemName: model.isRunning ? "ellipsis.bubble" : "bubble.left")
                        Text(model.currentConversationTitle).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(10)
                    .background(TapSkin.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundColor(TapSkin.ink)
                    Text("最近会话").font(.system(size: 10, weight: .medium))
                        .foregroundColor(TapSkin.faintInk).padding(.top, 16).padding(.bottom, 7)
                    ForEach(remoteHistory) { thread in
                        Button {
                            page = .chat
                            desktop.loadThread(thread.id, chat: model)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    if thread.isActive { Circle().fill(Color.green).frame(width: 5, height: 5) }
                                    Text(thread.title).font(.system(size: 12)).lineLimit(2)
                                }
                                Text(URL(fileURLWithPath: thread.cwd).lastPathComponent)
                                    .font(.system(size: 10)).foregroundColor(TapSkin.faintInk).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(model.codexThreadID == thread.id ? TapSkin.ink.opacity(0.06) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.isRunning)
                    }
                    ForEach(history) { conversation in
                        Button {
                            page = .chat
                            desktop.cancelSelection()
                            model.openConversation(id: conversation.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(conversation.title.isEmpty ? "未发送草稿" : conversation.title)
                                    .font(.system(size: 12)).lineLimit(2)
                                Text(conversation.updatedAt, style: .date)
                                    .font(.system(size: 10)).foregroundColor(TapSkin.faintInk)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if history.isEmpty && remoteHistory.isEmpty {
                        Text(search.isEmpty ? "新的想法，从一次对话开始。" : "没有匹配的会话")
                            .font(.system(size: 11)).foregroundColor(TapSkin.faintInk)
                            .padding(.horizontal, 10).padding(.vertical, 16)
                    }
                }
            }
            Spacer(minLength: 0)
            if desktop.isRefreshing || desktop.isLoadingThread {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(desktop.isLoadingThread ? "读取会话…" : "同步本机…").font(.system(size: 10))
                }.foregroundColor(TapSkin.secondaryInk)
            }
            if let error = desktop.errorText, model.isCodex {
                Text(error).font(.system(size: 10)).foregroundColor(.orange).lineLimit(4)
                    .help(error)
            }
            Divider().opacity(0.4)
            HStack {
                Button { showConfig = true } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(model.isCodex ? desktop.accountLabel : "连接与设置", systemImage: "circle.inset.filled")
                            .font(.system(size: 11)).lineLimit(1)
                        if model.isCodex {
                            Text(desktop.engineLabel).font(.system(size: 9)).lineLimit(2)
                        }
                    }.help(desktop.enginePath)
                }.buttonStyle(.plain)
                Spacer()
            }
            .foregroundColor(TapSkin.secondaryInk)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(width: 238)
        .frame(maxHeight: .infinity)
        .background(TapSkin.tone(0xfafafa, 0x191919))
        .foregroundColor(TapSkin.ink)
    }

    private func pageLink(_ destination: CodexPage, _ image: String) -> some View {
        Button { page = destination } label: {
            Label(destination.title, systemImage: image)
                .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(9)
                .background(page == destination ? TapSkin.ink.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityIdentifier("codex-page-link-\(destination.rawValue)")
    }
}
