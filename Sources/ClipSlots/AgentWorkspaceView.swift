import SwiftUI
import AppKit
import ClipSlotsKit

/// Only this subtree observes token updates; the slot grid and canvas stay outside.
struct AgentWorkspaceView: View {
    @StateObject var directory: AgentConversationDirectory
    private let canvas: CanvasStore?
    private let store: SlotStoreObservable?
    @State private var search = ""
    @State private var showConfig = false
    @State private var navigationVisible = true
    @FocusState private var searchFocused: Bool

    init(model: AgentChatModel) {
        _directory = StateObject(wrappedValue: AgentConversationDirectory(singleModel: model))
        canvas = nil
        store = nil
    }

    init(sessions: AgentSessionStore, canvas: CanvasStore, store: SlotStoreObservable) {
        _directory = StateObject(wrappedValue: sessions.directory)
        self.canvas = canvas
        self.store = store
    }

    private var model: AgentChatModel { directory.selectedModel }

    private var history: [AgentConversationEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return directory.entries.filter { saved in
            guard saved.id != model.selectedConversationID else { return false }
            return query.isEmpty || saved.searchableText.localizedCaseInsensitiveContains(query)
                || directory.sourceLabel(saved.source).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            if navigationVisible {
                navigation
            }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Label(directory.sourceLabel(directory.selectedSource),
                          systemImage: directory.selectedSource.projectID == nil ? "bubble.left" : "rectangle.3.group")
                    if let reason = directory.readOnlyReason {
                        Text("只读").foregroundColor(.orange).help(reason)
                    }
                    Spacer()
                    if let canvas, let store, directory.selectedSource.projectID != nil {
                        Button("返回所属画布") {
                            let entry = AgentConversationEntry(model.snapshot, source: directory.selectedSource,
                                                               current: true, running: model.isRunning)
                            if directory.open(entry, canvas: canvas, store: store) {
                                NotificationCenter.default.post(name: .setWorkspaceMode, object: nil,
                                                                userInfo: ["mode": "canvas"])
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("agent-return-canvas")
                            .disabled(directory.readOnlyReason != nil && !canvas.projects.contains {
                                $0.id == directory.selectedSource.projectID
                            })
                    }
                }
                .font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk)
                .padding(.horizontal, 20).frame(height: 38)
                if let reason = directory.readOnlyReason {
                    Text(reason).font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk)
                        .padding(.horizontal, 20).padding(.bottom, 8)
                }
                if let error = directory.error {
                    Text(error).font(.system(size: 11)).foregroundColor(.orange)
                        .padding(.horizontal, 20).padding(.bottom, 8)
                }
                AgentSidebarView(model: model, isVisible: .constant(true), workspaceMode: .agent,
                                 isReadOnly: directory.readOnlyReason != nil)
                    .id(ObjectIdentifier(model))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(TapSkin.tone(0xffffff, 0x111111))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TapSkin.tone(0xfafafa, 0x111111))
        .sheet(isPresented: $showConfig) { AgentConfigView(isWorkspace: model.usesWorkspaceBackend) }
        .onAppear {
            if let canvas { directory.bind(canvas: canvas) }
            directory.refresh()
        }
    }

    private var rail: some View {
        VStack(spacing: 18) {
            railButton("sidebar.left", "展开或收起会话栏") { navigationVisible.toggle() }
            railButton("house", "主页", selected: true) { navigationVisible = true }
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
            .accessibilityIdentifier("agent-nav-\(title)")
    }

    private func newConversation() {
        if let canvas, let store {
            directory.newConversation(source: directory.selectedSource == .legacyCanvas
                                      ? .workspace : directory.selectedSource, canvas: canvas, store: store)
        } else {
            model.clearHistory()
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Text("Agent")
                    .font(.system(size: 19, weight: .semibold))
                    .accessibilityIdentifier("agent-workspace-title")
                Spacer(minLength: 0)
                Button { searchFocused = true } label: {
                    Image(systemName: "magnifyingglass").frame(width: 24, height: 30)
                }.buttonStyle(.plain).help("搜索对话")
            }
            .frame(height: 52)

            HStack(spacing: 0) {
                Button { newConversation() } label: {
                    Label("新建对话", systemImage: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("新建 · " + directory.sourceLabel(directory.selectedSource))
                .accessibilityIdentifier("agent-new-conversation")
                if let canvas, let store {
                    Menu {
                        Button("Agent 页") { directory.newConversation(source: .workspace, canvas: canvas, store: store) }
                        Button("编辑助手") { directory.newConversation(source: .edit, canvas: canvas, store: store) }
                        ForEach(canvas.projects) { project in
                            Button("画布 · " + project.name) {
                                directory.newConversation(source: .project(project.id), canvas: canvas, store: store)
                            }
                        }
                    } label: { Image(systemName: "chevron.down").frame(width: 28, height: 32) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("选择新会话的来源")
                }
            }

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
                    ForEach(history) { conversation in
                        Button {
                            if let canvas, let store {
                                directory.open(conversation, canvas: canvas, store: store)
                            } else {
                                model.openConversation(id: conversation.id)
                                directory.rebuild()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(conversation.title.isEmpty ? "未发送草稿" : conversation.title)
                                    .font(.system(size: 12)).lineLimit(2)
                                Text(conversation.updatedAt, style: .date)
                                    .font(.system(size: 10)).foregroundColor(TapSkin.faintInk)
                                HStack(spacing: 4) {
                                    Text(directory.sourceLabel(conversation.source))
                                    if conversation.isRunning { Text("· 生成中") }
                                    else if conversation.isCurrent { Text("· 当前") }
                                }
                                .font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("agent-conversation-\(conversation.id.uuidString)")
                    }
                    if history.isEmpty {
                        Text(search.isEmpty ? "新的想法，从一次对话开始。" : "没有匹配的会话")
                            .font(.system(size: 11)).foregroundColor(TapSkin.faintInk)
                            .padding(.horizontal, 10).padding(.vertical, 16)
                    }
                }
            }
            Spacer(minLength: 0)
            Divider().opacity(0.4)
            HStack {
                Button { showConfig = true } label: {
                    Label("连接与设置", systemImage: "circle.inset.filled")
                        .font(.system(size: 11))
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

}
