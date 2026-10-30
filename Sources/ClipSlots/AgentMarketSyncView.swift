import SwiftUI
import AppKit
import ClipSlotsKit

@MainActor final class AgentMarketSyncStore: ObservableObject {
    static let shared = AgentMarketSyncStore()
    let service: AgentMarketSyncService
    @Published var snapshot: AgentMarketSnapshot? {
        didSet {
            items = snapshot?.items ?? []
            if oldValue?.scope != snapshot?.scope {
                revision = UUID(); installed = [:]; pending = []; itemErrors = [:]
                connectingItem = nil; connectionPrompt = nil; sourceConnection = nil; sourceAuth = nil
            }
        }
    }
    @Published private(set) var items: [AgentMarketItem] = []
    @Published var installed: [String: AgentMarketInstallation] = [:]
    @Published var pending: Set<String> = []
    @Published var itemErrors: [String: String] = [:]
    @Published var connectingItem: AgentMarketItem?
    @Published var connectionPrompt: AgentMarketItem?
    @Published var sourceConnection: AgentMarketItem?
    @Published var sourceAuth: AgentConnectorSession?
    var clientFactory: @Sendable (URL, String) -> AgentMCPClient = { endpoint, scope in
        AgentMCPClient(endpoint: endpoint) {
            guard endpoint == AgentMCPClient.officialEndpoint else { throw AgentMCPError.invalidBinding }
            return try await AgentMarketCredentials.shared.token(scope: scope)
        }
    }
    private var installTasks: [String: Task<Void, Error>] = [:]
    @Published var isRefreshing = false
    @Published var error: String?
    @Published var presentation: [String: MarketPresentation] = [:]
    var session: AgentMarketDesktopSession?
    var revision = UUID()
    let readsDesktop: Bool
    init(service: AgentMarketSyncService = .init(), fixture: AgentMarketSnapshot? = nil, readsDesktop: Bool = true) {
        self.service = service; snapshot = fixture; self.readsDesktop = readsDesktop
        items = fixture?.items ?? []
    }
    /// Startup loads local capabilities without refreshing or rewriting the
    /// synchronized catalog. Network synchronization belongs to the manager.
    func loadCached() async {
        guard !isRefreshing else { return }
        let currentSession = readsDesktop ? await Task.detached { AgentMarketDesktopSession.read() }.value : nil
        let scope = readsDesktop ? currentSession?.scope ?? "public" : snapshot?.scope ?? "public"
        session = currentSession
        if snapshot == nil || snapshot?.scope != scope {
            let scoped = await service.load(scope: scope)
            let publicSnapshot = await service.load()
            snapshot = scoped ?? publicSnapshot
            if snapshot?.scope != scope { snapshot?.skills = [:]; snapshot?.scope = scope }
            AgentSkillLibrary.shared.resetMarketScope()
            AgentSkillLibrary.shared.refresh()
        }
        do { installed = try await service.installations(scope: scope) }
        catch { self.error = "无法读取已添加应用：\(error.localizedDescription)" }
        let root = await service.root
        if let data = try? Data(contentsOf: root.appendingPathComponent("presentation.json")),
           let value = try? JSONDecoder().decode([String: MarketPresentation].self, from: data) { presentation = value }
    }
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true; error = nil
        defer { isRefreshing = false }
        let token = UUID(); revision = token
        let currentSession = readsDesktop ? await Task.detached { AgentMarketDesktopSession.read() }.value : nil
        session = currentSession
        let scope = readsDesktop ? currentSession?.scope ?? "public" : snapshot?.scope ?? "public"
        if snapshot == nil || snapshot?.scope != scope {
            await service.activate(scope: scope)
            AgentSkillLibrary.shared.resetMarketScope()
            let scoped = await service.load(scope: scope)
            let publicSnapshot = await service.load()
            installed = [:]; itemErrors = [:]
            snapshot = scoped ?? publicSnapshot
            if snapshot?.scope != scope {
                snapshot?.skills = [:]
                snapshot?.scope = scope
            }
            AgentSkillLibrary.shared.refresh()
        }
        do { installed = try await service.installations(scope: scope) }
        catch { self.error = "无法读取已添加应用：\(error.localizedDescription)"; return }
        let root = await service.root
        if let data = try? Data(contentsOf: root.appendingPathComponent("presentation.json")),
           let value = try? JSONDecoder().decode([String: MarketPresentation].self, from: data) { presentation = value }
        guard readsDesktop else { return }
        do {
            let result = try await service.refresh(session: currentSession, force: force)
            guard revision == token else { return }
            if result.scope != scope {
                session = nil
                AgentSkillLibrary.shared.resetMarketScope()
            }
            snapshot = result
            installed = try await service.installations(scope: result.scope)
            AgentSkillLibrary.shared.refresh()
        } catch { self.error = error.localizedDescription }
    }
    func detail(_ item: AgentMarketItem) async {
        guard readsDesktop else { return }
        let scope = snapshot?.scope, token = revision
        do {
            let detail = try await service.fetchDetail(item, session: session)
            guard scope == snapshot?.scope, token == revision, var current = snapshot else { return }
            current.details[item.id] = detail; try await service.commit(current); snapshot = current
        } catch { self.error = error.localizedDescription }
    }
    func materialize(_ item: AgentMarketItem) async throws -> AgentSkill {
        guard let current = snapshot else { throw AgentMarketSyncError.unavailableSkill }
        if readsDesktop, current.scope != "public" {
            let liveSession = await Task.detached { AgentMarketDesktopSession.read() }.value
            guard liveSession?.scope == current.scope else {
                await refresh(force: true)
                throw AgentMarketSyncError.requiresLogin
            }
        }
        let result = try await service.materialize(item, snapshot: current)
        guard snapshot?.scope == current.scope else { throw AgentMarketSyncError.requiresLogin }
        AgentSkillLibrary.shared.refresh()
        return result
    }
    func isInstalled(_ item: AgentMarketItem) -> Bool {
        guard let record = installed[item.id] else { return false }
        if record.skillSlug != nil { return true }
        return record.connection?.isValid == true && record.connection?.scope == snapshot?.scope
            && record.connection?.applicationID == item.id
    }
    func add(_ item: AgentMarketItem) async throws {
        if item.kind == "app", snapshot?.markdown(for: item) == nil, !isInstalled(item) {
            guard !pending.contains(item.id) else { return }
            pending.insert(item.id)
            defer { pending.remove(item.id) }
            if readsDesktop {
                let scope = snapshot?.scope
                guard let live = await Task.detached(operation: { AgentMarketDesktopSession.read() }).value,
                      live.scope == scope else { throw AgentMarketSyncError.requiresLogin }
                try await service.ensureRemoteInstallation(item, session: live)
                guard snapshot?.scope == scope else { throw AgentMarketSyncError.requiresLogin }
            }
            connectingItem = item
        } else { try await install(item) }
    }
    func bind(_ item: AgentMarketItem, client: AgentMCPClient, selectedNames: Set<String>) async throws {
        guard let current = snapshot else { throw AgentMarketSyncError.invalidResponse }
        pending.insert(item.id)
        defer { pending.remove(item.id) }
        let record = try await service.bind(item, snapshot: current, client: client, selectedNames: selectedNames)
        guard current.scope == snapshot?.scope else { throw AgentMCPError.invalidBinding }
        installed[item.id] = record
        itemErrors[item.id] = nil
        connectingItem = nil
    }
    func applicationTools(readOnly: Bool, automaticApproval: Bool,
                          isCurrent: @escaping @MainActor @Sendable () -> Bool,
                          onInteraction: @escaping @Sendable (AgentInteraction) async -> Void) -> [AgentToolExecuting] {
        guard let scope = snapshot?.scope else { return [] }
        let service = self.service, readsDesktop = self.readsDesktop
        return installed.values.compactMap { record in
            guard record.isEnabled, managedApplicationEnabled(AgentMarketItem(record.item).id),
                  let binding = record.connection, binding.isValid, binding.scope == scope else { return nil }
            let title = AgentMarketItem(record.item).title
            return AgentMCPApplicationTools(binding: binding, title: title,
                client: clientFactory(binding.endpoint, scope), readOnly: readOnly,
                isCurrent: { [weak self] in
                    guard await isCurrent(), await self?.snapshot?.scope == scope,
                          await self?.managedApplicationEnabled(binding.applicationID) == true else { return false }
                    if readsDesktop, scope != "public" {
                        guard await Task.detached(operation: { AgentMarketDesktopSession.read()?.scope }).value == scope else { return false }
                    }
                    let record = try? await service.installations(scope: scope)[binding.applicationID]
                    return record?.isEnabled == true && record?.connection == binding
                }, approve: { tool, call in
                    // External effects always ask; read-only annotations allow
                    // execution only when the user selected automatic approval.
                    if tool.readOnly && automaticApproval { return true }
                    return await AgentApplicationApproval.request(title: title, tool: tool, call: call,
                        isCurrent: isCurrent, onInteraction: onInteraction)
                })
        }
    }
    private func managedApplicationEnabled(_ id: String) -> Bool {
        guard let raw = snapshot?.managerCatalog?.first(where: { AgentMarketItem($0).id == id }) else { return true }
        let item = AgentMarketItem(raw)
        return item.sourceAdded && item.sourceEnabled
    }
    func install(_ item: AgentMarketItem) async throws {
        guard let current = snapshot else { throw AgentMarketSyncError.invalidResponse }
        let key = current.scope + "|" + item.id
        if let task = installTasks[key] { return try await task.value }
        pending.insert(item.id); itemErrors[item.id] = nil
        let task = Task { @MainActor in
            if self.readsDesktop, current.scope != "public" {
                let live = await Task.detached { AgentMarketDesktopSession.read() }.value
                guard live?.scope == current.scope else { throw AgentMarketSyncError.requiresLogin }
            }
            let record = try await self.service.install(item, snapshot: current)
            guard self.snapshot?.scope == current.scope else { throw AgentMarketSyncError.requiresLogin }
            self.installed[item.id] = record
            if let slug = record.skillSlug {
                var enabled = AgentPreferences.decodeEnabledSlugs(UserDefaults.standard.string(forKey: AgentPreferences.enabledSkillsKey) ?? "")
                enabled.insert(slug)
                UserDefaults.standard.set(AgentPreferences.encodeEnabledSlugs(enabled), forKey: AgentPreferences.enabledSkillsKey)
                AgentSkillLibrary.shared.refresh()
            }
        }
        installTasks[key] = task
        defer {
            installTasks[key] = nil
            if snapshot?.scope == current.scope { pending.remove(item.id) }
        }
        do { try await task.value }
        catch {
            if snapshot?.scope == current.scope { itemErrors[item.id] = error.localizedDescription }
            throw error
        }
    }
    func reference(_ item: AgentMarketItem) async throws -> AgentSkillReference {
        guard let current = snapshot else { throw AgentMarketSyncError.invalidResponse }
        try await install(item)
        let reference = try await service.reference(current.item(item.id) ?? item, snapshot: current)
        guard snapshot?.scope == current.scope else { throw AgentMarketSyncError.requiresLogin }
        return reference
    }
    func save(_ value: MarketPresentation, for id: String) async throws {
        let root = await service.root
        var next = presentation; next[id] = value
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: root.appendingPathComponent("presentation.json"), options: .atomic)
        presentation = next
    }
    func importIcon(_ url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024, NSImage(data: data) != nil else { throw AgentMarketSyncError.invalidURL }
        let root = await service.root
        let name = AgentMarketSyncService.hash(data.base64EncodedString())
        let directory = root.appendingPathComponent("custom-icons")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return "local:" + name
    }
}

struct MarketPresentation: Codable, Equatable {
    var followsSource = true
    var icon = ""
    var cover = ""
    var fit = "contain"
    var rounded = true
}

struct AgentAppMarketView: View {
    @ObservedObject var model: AgentChatModel
    var isReadOnly = false
    var fixtureSkills: [AgentSkill]? = nil
    var onClose: () -> Void
    var onUse: () -> Void
    var body: some View {
        if fixtureSkills != nil {
            AgentLocalAppMarketView(model: model, isReadOnly: isReadOnly, fixtureSkills: fixtureSkills, onClose: onClose, onUse: onUse)
        } else {
            AgentSyncedAppMarketView(model: model, isReadOnly: isReadOnly, onClose: onClose, onUse: onUse)
                .accessibilityElement(children: .contain).accessibilityIdentifier("agent-app-market")
        }
    }
}

struct AgentSyncedAppMarketView: View {
    @ObservedObject var model: AgentChatModel
    var isReadOnly = false
    var onClose: () -> Void
    var onUse: () -> Void
    var initialItem: AgentMarketItem? = nil
    @ObservedObject var sync: AgentMarketSyncStore = .shared
    @AppStorage(AgentPreferences.enabledSkillsKey) private var enabledRaw = ""
    @State private var selection: String?
    @State private var search = ""
    @State private var tab = "全部"
    @State private var category = ""
    @State private var local = false
    @State private var configure = false
    @State private var text = ""
    @State private var values: [String: String] = [:]
    @State private var notice: String?
    @State private var working = false
    @State private var showForm = false
    @State private var useTask: Task<Void, Never>?
    private var fill: Color { TapSkin.tone(0xffffff, 0x1e1e1e) }
    private var edge: Color { TapSkin.tone(0xe4e4e8, 0x333333) }
    private var items: [AgentMarketItem] { sync.items }
    private var selected: AgentMarketItem? { selection.flatMap { sync.snapshot?.item($0) } }
    private var filtered: [AgentMarketItem] {
        items.filter { item in
            if tab != "全部" && item.kind != (tab == "应用" ? "app" : "skill") { return false }
            if !category.isEmpty && item.raw["business_scenario"]?.stringValue != category { return false }
            let terms = item.raw["search_terms"]?.arrayValue ?? []
            let keywords = terms.compactMap { $0.stringValue }.joined(separator: " ")
            let searchable = [item.title, item.summary, item.name, keywords].joined(separator: " ")
            return search.isEmpty || searchable.localizedCaseInsensitiveContains(search)
        }
    }
    private var featured: [AgentMarketItem] {
        (sync.snapshot?.catalog["featured"]?.arrayValue ?? []).compactMap {
            sync.snapshot?.item(($0["kind"]?.stringValue ?? "") + ":" + ($0["name"]?.stringValue ?? ""))
        }
    }
    var body: some View {
        Group {
            if local {
                AgentLocalAppMarketView(model: model, isReadOnly: isReadOnly, onClose: { local = false }, onUse: onUse)
            } else {
                VStack(spacing: 0) {
                    header
                    Rectangle().fill(edge).frame(height: 1)
                    if let selected { detail(selected) } else { browse }
                }.background(TapSkin.tone(0xfafafa, 0x111111))
                    .foregroundStyle(TapSkin.ink)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("agent-synced-market")
            }
        }
        .task {
            await sync.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                await sync.refresh()
            }
        }
        .onChange(of: model.selectedConversationID) { _ in selection = nil; values = [:]; notice = nil; useTask?.cancel() }
        .onAppear { if let initialItem { selection = initialItem.id } }
        .onChange(of: selection) { _ in useTask?.cancel() }
        .onDisappear { useTask?.cancel() }
        .sheet(isPresented: $configure) {
            if let selected {
                AgentMarketPresentationEditor(item: selected, sync: sync, onClose: { configure = false })
            }
        }
        .sheet(item: $sync.connectingItem) { item in AgentApplicationConnection(item: item, sync: sync) }
    }
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                if selection == nil { onClose() } else { selection = nil; notice = nil }
            } label: { Image(systemName: "chevron.left").frame(width: 26, height: 28) }
                .buttonStyle(.plain).accessibilityIdentifier(selection == nil ? "agent-market-close" : "market-sync-back")
            Text("应用市场").font(.system(size: 16, weight: .semibold))
            Spacer(minLength: 0)
            if sync.isRefreshing { ProgressView().controlSize(.small) }
            Button { Task { await sync.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).disabled(sync.isRefreshing).help("同步目录、配置和技能")
                .accessibilityIdentifier("market-sync-refresh")
            Menu {
                Button("本地技能与画布 MCP") { local = true }
                if selected != nil { Button("图标与封面") { configure = true }.disabled(isReadOnly) }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).fixedSize()
        }.padding(.horizontal, 12).frame(height: 48)
    }
    private var browse: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(TapSkin.secondaryInk)
                TextField("搜索应用和技能", text: $search).textFieldStyle(.plain)
                    .accessibilityIdentifier("market-sync-search")
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.font(.system(size: 12)).padding(10).background(fill, in: RoundedRectangle(cornerRadius: 10)).padding(16)
            HStack(spacing: 20) {
                ForEach(["全部", "应用", "技能"], id: \.self) { value in
                    Button { tab = value } label: {
                        VStack(spacing: 8) {
                            Text(value).font(.system(size: 12, weight: tab == value ? .semibold : .regular))
                            Capsule().fill(tab == value ? TapSkin.ink : .clear).frame(height: 2)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("market-sync-tab-" + value)
                }
                Spacer()
            }.padding(.horizontal, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    categoryButton("", "全部")
                    ForEach(Array((sync.snapshot?.catalog["categories"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, entry in
                        categoryButton(entry["id"]?.stringValue ?? "", entry["label"]?.stringValue ?? "")
                    }
                }.padding(.horizontal, 16)
            }.padding(.vertical, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let error = sync.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).accessibilityIdentifier("market-sync-error") }
                    HStack {
                        Text(sync.snapshot?.accountStatus ?? "正在读取配置…").font(.system(size: 10))
                        Spacer()
                        Text("\(items.count) 项").font(.system(size: 10))
                    }.foregroundStyle(TapSkin.secondaryInk).accessibilityIdentifier("market-sync-status")
                    if tab == "全部", category.isEmpty, search.isEmpty, !featured.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(featured) { item in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Button { open(item) } label: {
                                            MarketArtwork(item: item, sync: sync, isCover: true).frame(width: 218, height: 112)
                                        }.buttonStyle(.plain).accessibilityIdentifier("market-sync-featured-" + item.name)
                                        HStack {
                                            Button { open(item) } label: {
                                                Text(clean(item.title)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                            }.buttonStyle(.plain)
                                            Spacer(minLength: 0)
                                            MarketAddButton(item: item, sync: sync, model: model, isReadOnly: isReadOnly, onUse: onUse)
                                        }
                                    }.frame(width: 218, alignment: .leading)
                                }
                            }
                        }.padding(.bottom, 6)
                    }
                    ForEach(filtered) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            row(item)
                            if let error = sync.itemErrors[item.id] {
                                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                                    .accessibilityIdentifier("market-add-error-" + item.name)
                            }
                        }
                    }
                    if filtered.isEmpty && !sync.isRefreshing {
                        Text("没有匹配的应用或技能").font(.system(size: 12)).foregroundStyle(TapSkin.secondaryInk)
                            .padding(.vertical, 40).accessibilityIdentifier("market-sync-empty")
                    }
                    Button { local = true } label: { Label("本地技能与画布 MCP", systemImage: "point.3.connected.trianglepath.dotted") }
                        .buttonStyle(.plain).font(.system(size: 12)).padding(.vertical, 12)
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
    }
    private func categoryButton(_ id: String, _ label: String) -> some View {
        Button { category = id } label: {
            Text(clean(label)).font(.system(size: 10, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                .background(category == id ? TapSkin.tone(0xe9e9ed, 0x303033) : fill, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("market-sync-category-" + id)
    }
    private func row(_ item: AgentMarketItem) -> some View {
        HStack(spacing: 8) {
            Button { open(item) } label: {
                HStack(alignment: .top, spacing: 11) {
                    MarketArtwork(item: item, sync: sync).frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(clean(item.title)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(clean(item.summary)).font(.system(size: 10)).foregroundStyle(TapSkin.secondaryInk).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("market-sync-item-" + item.name)
            MarketAddButton(item: item, sync: sync, model: model, isReadOnly: isReadOnly, onUse: onUse)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(edge, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    private func open(_ item: AgentMarketItem) {
        selection = item.id; text = ""; values = [:]; notice = nil; showForm = false
        Task { await sync.detail(item) }
    }
    private func detail(_ item: AgentMarketItem) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MarketArtwork(item: item, sync: sync, isCover: true).frame(height: 148)
                    HStack(alignment: .top) {
                        Text(clean(item.title)).font(.system(size: 22, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                        Button { configure = true } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain)
                            .disabled(isReadOnly).help("图标与封面配置").accessibilityIdentifier("market-sync-presentation")
                    }
                    Text(clean(item.summary)).font(.system(size: 12)).foregroundStyle(TapSkin.secondaryInk)
                    if let markdown = sync.snapshot?.markdown(for: item) {
                        DisclosureGroup("Skill 正文") {
                            ScrollView { Text(markdown).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(maxHeight: 220)
                        }.font(.system(size: 12)).accessibilityIdentifier("market-sync-markdown")
                    } else {
                        Text(item.kind == "app" ? "应用的远端连接器需在来源应用中配置；此处可使用已同步的创作入口。"
                             : "目录已同步，尚未取得此 Skill 正文。").font(.system(size: 11)).foregroundStyle(TapSkin.secondaryInk)
                            .accessibilityIdentifier("market-sync-unavailable-skill")
                    }
                    DisclosureGroup("使用指南") { guide(item) }.font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 0) {
                      Button { showForm.toggle() } label: {
                          HStack(spacing: 6) {
                              Image(systemName: showForm ? "chevron.down" : "chevron.right")
                                  .font(.system(size: 10)).foregroundStyle(TapSkin.secondaryInk)
                              Text("填写创作需求")
                              Spacer()
                          }.contentShape(Rectangle())
                      }.buttonStyle(.plain).accessibilityIdentifier("market-sync-form")
                      if showForm {
                      VStack(alignment: .leading, spacing: 12) {
                      ForEach(Array(item.fields.enumerated()), id: \.offset) { _, field in
                        let id = field["id"]?.stringValue ?? ""
                        VStack(alignment: .leading, spacing: 6) {
                            Text(clean(field["label"]?.stringValue ?? id) + (field["required"]?.boolValue == true ? " *" : ""))
                                .font(.system(size: 12, weight: .medium))
                            if let options = field["options"]?.arrayValue, !options.isEmpty {
                                Picker("", selection: Binding(get: { values[id] ?? "" }, set: { values[id] = $0 })) {
                                    Text("请选择").tag("")
                                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                                        Text(option["label"]?.stringValue ?? option.stringValue ?? "")
                                            .tag(option["value"]?.stringValue ?? option.stringValue ?? "")
                                    }
                                }.labelsHidden().accessibilityIdentifier("market-sync-field-" + id)
                            } else {
                              TextField(clean(field["placeholder"]?.stringValue ?? ""),
                                      text: Binding(get: { values[id] ?? "" }, set: { values[id] = $0 }))
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("market-sync-field-" + id)
                            }
                        }
                    }
                    TextField(item.starter.isEmpty ? "你的创作需求" : "补充要求（选填）", text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(3...8).accessibilityIdentifier("market-sync-prompt")
                    HStack {
                        Button { model.chooseAttachments() } label: { Label("添加资料", systemImage: "paperclip") }
                            .disabled(isReadOnly || model.isImportingAttachments)
                        Spacer()
                        Text("\(model.draftAttachments.count + model.draftReferences.count) 个参考").foregroundStyle(TapSkin.secondaryInk)
                    }.font(.system(size: 11))
                      Button("引用并带入需求") { use(item, includeForm: true) }
                        .disabled(isReadOnly || working || model.isAddingSkill)
                        .accessibilityIdentifier("market-sync-use-form")
                      }.padding(.top, 10)
                      }
                    }.font(.system(size: 12))
                    DisclosureGroup("应用配置") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let recommended = item.raw["recommended_model"] {
                                Text("推荐模型：" + clean(recommended["display_name"]?.stringValue ?? recommended["id"]?.stringValue ?? ""))
                            }
                            Text("图标：" + (item.iconURL == nil ? "来源默认样式" : "来源图片"))
                            if let style = item.iconStyle { Text("图标样式：" + style) }
                            Text("目录版本：" + (sync.snapshot?.version ?? ""))
                            ForEach(["capabilities", "connectors", "library", "collection", "preset_gallery", "influencer_studio"], id: \.self) { key in
                                if let value = item.raw[key], value != .array([]) {
                                    DisclosureGroup(configLabel(key)) {
                                        Text(clean((try? value.encodedText(pretty: true)) ?? "")).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                    }
                                }
                            }
                        }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 12))
                    if let message = notice ?? sync.itemErrors[item.id] {
                        Text(message).font(.system(size: 11)).foregroundStyle(.orange).accessibilityIdentifier("market-sync-notice")
                    }
                }.padding(16)
            }
            Rectangle().fill(edge).frame(height: 1)
            HStack(spacing: 12) {
                MarketAddButton(item: item, sync: sync, model: model, isReadOnly: isReadOnly, onUse: onUse)
                Button(working ? "正在读取…" : "引用到当前对话") { use(item) }
                    .font(.system(size: 12, weight: .semibold)).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("market-sync-use")
            }
                .frame(maxWidth: .infinity).padding(12).disabled(isReadOnly || working || model.isAddingSkill)
        }
    }
    private func use(_ item: AgentMarketItem, includeForm: Bool = false) {
        guard !working, !isReadOnly else { return }
        working = true; notice = nil
        useTask = Task {
            defer { working = false }
            do {
                let prompt = includeForm ? try item.prompt(values: values, text: text,
                    referenceCount: model.draftAttachments.count + model.draftReferences.count) : ""
                if try await model.prepareReference(prompt: prompt, loader: { try await sync.reference(item) }) { onUse() }
            } catch is CancellationError {
            } catch { notice = error.localizedDescription }
        }
    }
    @ViewBuilder private func guide(_ item: AgentMarketItem) -> some View {
        let guide = item.raw["guide"]
        if let steps = guide?["steps"]?.arrayValue, !steps.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 9) {
                        Text("\(index + 1)").font(.system(size: 11)).frame(width: 20, height: 20).background(fill, in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(clean(step["title"]?.stringValue ?? "")).font(.system(size: 12, weight: .medium))
                            Text(clean(step["description"]?.stringValue ?? "")).font(.system(size: 11)).foregroundStyle(TapSkin.secondaryInk)
                        }
                    }
                }
            }
        }
        if let outputs = guide?["outputs"]?.arrayValue, !outputs.isEmpty {
            Text(clean(outputs.compactMap(\.stringValue).joined(separator: " · "))).font(.system(size: 11)).foregroundStyle(TapSkin.secondaryInk)
        }
    }
    private func configLabel(_ key: String) -> String {
        ["capabilities": "能力", "connectors": "连接器", "library": "素材库", "collection": "合集", "preset_gallery": "预设", "influencer_studio": "创作配置"][key] ?? key
    }
    private func clean(_ value: String) -> String { value.replacingOccurrences(of: "TapNow", with: "创作平台", options: .caseInsensitive) }
}

struct MarketArtwork: View {
    let item: AgentMarketItem
    @ObservedObject var sync: AgentMarketSyncStore
    var isCover = false
    @State private var image: NSImage?
    private var settings: MarketPresentation { sync.presentation[item.id] ?? .init() }
    private var icon: String? {
        !settings.followsSource && !settings.icon.isEmpty ? settings.icon : item.iconURL
    }
    private var cover: String? {
        !settings.followsSource && !settings.cover.isEmpty ? settings.cover : item.coverURL
    }
    private var source: String? { isCover ? cover ?? icon : icon }
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                TapSkin.tone(0xefeff2, 0x29292d)
                if let image {
                    if (isCover && cover != nil) || (!isCover && settings.fit == "cover") {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: size.width, height: size.height).clipped()
                    } else {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: isCover ? min(64, size.width - 16) : max(0, size.width - 4),
                                   height: isCover ? min(64, size.height - 16) : max(0, size.height - 4))
                            .clipShape(RoundedRectangle(cornerRadius: settings.rounded ? (isCover ? 12 : 6) : 0))
                    }
                } else {
                    ZStack {
                        Color(red: Double((item.iconColor >> 16) & 255) / 255,
                              green: Double((item.iconColor >> 8) & 255) / 255,
                              blue: Double(item.iconColor & 255) / 255)
                        Text(item.iconInitials).font(.system(size: isCover ? 24 : 13, weight: .semibold))
                            .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                    }.frame(width: isCover ? 64 : size.width, height: isCover ? 64 : size.height)
                        .clipShape(RoundedRectangle(cornerRadius: settings.rounded ? 10 : 0))
                }
            }.frame(width: size.width, height: size.height).clipped()
        }
            .clipShape(RoundedRectangle(cornerRadius: isCover ? 13 : (settings.rounded ? 8 : 0)))
            .accessibilityIdentifier((isCover ? "market-sync-cover-" : "market-sync-icon-") + item.name)
            .task(id: source) {
                image = nil
                guard let source else { return }
                do {
                    let data: Data
                    if source.hasPrefix("local:") {
                        let root = await sync.service.root
                        data = try await Task.detached {
                            try Data(contentsOf: root.appendingPathComponent("custom-icons/" + String(source.dropFirst(6))))
                        }.value
                    } else { data = try await sync.service.image(source) }
                    if !Task.isCancelled {
                        image = ClipSlotsImageIO.downsampledImage(data: data, maxPixel: isCover ? 640 : 128)
                            ?? NSImage(data: data)
                    }
                } catch { }
            }
    }
}

struct MarketAddButton: View {
    let item: AgentMarketItem
    @ObservedObject var sync: AgentMarketSyncStore
    @ObservedObject var model: AgentChatModel
    var isReadOnly = false
    var referencesInstalled = true
    var onUse: () -> Void
    @State private var referencing = false
    @State private var task: Task<Void, Never>?
    private var busy: Bool { referencing || sync.pending.contains(item.id) }
    var body: some View {
        Button {
            guard !busy, !isReadOnly else { return }
            let installed = sync.isInstalled(item)
            if installed && !referencesInstalled { return }
            referencing = true
            task = Task {
                defer { referencing = false }
                do {
                    if installed {
                        if try await model.prepareReference(loader: { try await sync.reference(item) }) { onUse() }
                    } else { try await sync.add(item) }
                } catch is CancellationError {
                } catch { sync.itemErrors[item.id] = error.localizedDescription }
            }
        } label: {
            Group {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: sync.isInstalled(item) ? "checkmark" : "plus").font(.system(size: 13, weight: .semibold)) }
            }.frame(width: 30, height: 30)
                .background(TapSkin.tone(0xeeeeF1, 0x323235), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).fixedSize()
            .disabled(isReadOnly || busy || (sync.isInstalled(item) && model.isAddingSkill))
            .help(sync.isInstalled(item) ? (referencesInstalled ? "已添加 · 引用到当前对话" : "已添加") : "添加到 Agent")
            .accessibilityLabel((sync.isInstalled(item) ? (referencesInstalled ? "引用 " : "已添加 ") : "添加 ") + item.title)
            .accessibilityIdentifier("market-add-" + item.name)
            .onDisappear { task?.cancel() }
    }
}

struct AgentApplicationPicker: View {
    @ObservedObject var model: AgentChatModel
    @ObservedObject var sync: AgentMarketSyncStore = .shared
    let localItems: [AgentComposerItem]
    var isReadOnly = false
    var onLocalPick: (AgentComposerItem.Action) async throws -> Bool
    var onUse: () -> Void
    var onMarket: () -> Void
    @State private var search = ""
    @State private var tab = "应用"
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    private var matches: [AgentMarketItem] {
        sync.items.filter {
            $0.kind == (tab == "应用" ? "app" : "skill")
                && (search.isEmpty || ($0.title + " " + $0.summary).localizedCaseInsensitiveContains(search))
        }
    }
    private var localMatches: [AgentComposerItem] {
        localItems.filter { $0.isSkill && !$0.id.contains("/market-sync/scopes/")
            && (search.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 3) {
                    ForEach(["应用","技能"],id:\.self) { value in
                        Button { tab = value } label: {
                            Text(value).font(.system(size:12,weight:.medium))
                                .frame(maxWidth:.infinity).padding(.vertical,6)
                                .background(tab == value ? TapSkin.tone(0xffffff,0x444446) : .clear,
                                            in:RoundedRectangle(cornerRadius:7))
                        }.buttonStyle(.plain).accessibilityIdentifier("market-picker-tab-" + value)
                    }
                }.padding(3).background(TapSkin.tone(0xefeff1,0x2b2b2d),in:RoundedRectangle(cornerRadius:10))
                Button { onMarket() } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain).help("打开应用市场").accessibilityIdentifier("market-picker-open-market")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(TapSkin.secondaryInk)
                TextField("搜索应用和技能", text: $search).textFieldStyle(.plain)
                    .accessibilityIdentifier("market-picker-search")
            }.padding(10).background(TapSkin.tone(0xf2f2f4, 0x29292c), in: RoundedRectangle(cornerRadius: 9))
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(matches) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 5) {
                                Button {
                                    task = Task {
                                        do {
                                            if sync.isInstalled(item) {
                                                if try await model.prepareReference(loader: { try await sync.reference(item) }) { onUse() }
                                            } else { try await sync.add(item) }
                                        } catch is CancellationError {
                                        } catch { sync.itemErrors[item.id] = error.localizedDescription }
                                    }
                                } label: {
                                    HStack(spacing: 7) {
                                        MarketArtwork(item: item, sync: sync).frame(width: 28, height: 28)
                                        Text(item.title.replacingOccurrences(of: "TapNow", with: "创作平台", options: .caseInsensitive))
                                            .font(.system(size: 11, weight: .medium))
                                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(isReadOnly || model.isAddingSkill || sync.pending.contains(item.id))
                                    .accessibilityIdentifier("market-picker-item-" + item.name)
                                MarketAddButton(item: item, sync: sync, model: model, isReadOnly: isReadOnly, onUse: onUse)
                            }
                            if let error = sync.itemErrors[item.id] { Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                        }.padding(8).frame(maxWidth: .infinity, minHeight: 52)
                            .background(TapSkin.tone(0xf7f7f8, 0x252527), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if tab == "技能" {
                        ForEach(localMatches) { item in
                            Button {
                                task = Task {
                                    do { if try await onLocalPick(item.action) { onUse() } }
                                    catch { self.error = error.localizedDescription }
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "sparkles").frame(width: 24)
                                    Text(String(item.title.dropFirst())).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                }.font(.system(size: 11)).padding(8).frame(maxWidth: .infinity, minHeight: 52)
                                    .background(TapSkin.tone(0xf7f7f8, 0x252527), in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).disabled(isReadOnly || model.isAddingSkill)
                                .accessibilityIdentifier("agent-skill-pick-" + item.id)
                        }
                    }
                }
                if matches.isEmpty && (tab == "应用" || localMatches.isEmpty) {
                    Text(sync.isRefreshing ? "正在读取…" : "没有匹配的应用或技能")
                        .font(.system(size: 12)).foregroundStyle(TapSkin.secondaryInk).padding(24)
                }
            }.frame(height: 280)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
        }.padding(12).frame(width: 388).foregroundStyle(TapSkin.ink)
            .background(TapSkin.tone(0xffffff, 0x202020))
            .accessibilityElement(children: .contain).accessibilityIdentifier("agent-application-picker")
            .task { await sync.refresh() }
            .onExitCommand { dismiss() }
            .onDisappear { task?.cancel() }
    }
}

struct AgentMarketPresentationEditor: View {
    let item: AgentMarketItem
    @ObservedObject var sync: AgentMarketSyncStore
    var onClose: () -> Void
    @State private var value = MarketPresentation()
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("图标与封面").font(.headline); Spacer(); Button("完成") { onClose() } }
            Toggle("跟随来源配置", isOn: $value.followsSource).accessibilityIdentifier("market-sync-follow-icon")
            VStack(alignment: .leading, spacing: 10) {
                TextField("图标图片 URL", text: $value.icon).textFieldStyle(.roundedBorder).accessibilityIdentifier("market-sync-icon-url")
                Button("选择本地图标…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]; panel.allowsMultipleSelection = false
                    panel.begin { response in
                        if response == .OK, let url = panel.url {
                            Task { do { value.icon = try await sync.importIcon(url) } catch { self.error = error.localizedDescription } }
                        }
                    }
                }
                TextField("封面图片 URL", text: $value.cover).textFieldStyle(.roundedBorder)
                Picker("图标显示", selection: $value.fit) { Text("完整").tag("contain"); Text("填充").tag("cover") }.pickerStyle(.segmented)
                Toggle("圆角图标", isOn: $value.rounded)
            }.disabled(value.followsSource)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            Button("保存配置") {
                Task {
                    do {
                        for source in [value.icon, value.cover] where !source.isEmpty && !source.hasPrefix("local:") {
                            guard URL(string: source)?.scheme == "https" else { throw AgentMarketSyncError.invalidURL }
                        }
                        try await sync.save(value, for: item.id); onClose()
                    } catch { self.error = error.localizedDescription }
                }
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("market-sync-save-presentation")
        }.padding(20).frame(width: 380)
            .onAppear { value = sync.presentation[item.id] ?? .init() }
    }
}
