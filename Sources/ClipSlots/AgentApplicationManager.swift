import SwiftUI
import AppKit
import ClipSlotsKit
import AVKit

/// Center over the owner window, including the canvas, rather than attaching a
/// sheet to the sidebar's top edge.
@MainActor final class AgentApplicationManagerRequest: ObservableObject {
    var presented = false
    var tab = "应用"
    var changed: (() -> Void)?
    func open(_ tab: String) { self.tab = tab; presented = true; changed?() }
}

private final class ConnectorPanelLayout: ObservableObject {
    @Published var width: CGFloat = 680
    @Published var ownerHeight: CGFloat = 800
}

private struct ConnectorPanelContent: View {
    let item: AgentMarketItem
    @ObservedObject var sync: AgentMarketSyncStore
    @ObservedObject var layout: ConnectorPanelLayout
    let onClose: () -> Void
    let onSizeChange: (CGSize) -> Void
    var body: some View {
        AgentSourceConnectorWizard(item: item, sync: sync, onClose: onClose,
            availableWidth: layout.width, availableHeight: layout.ownerHeight, onSizeChange: onSizeChange)
    }
}

struct AgentApplicationManagerPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let model: AgentChatModel
    let sync: AgentMarketSyncStore
    let isReadOnly: Bool
    let initialTab: String
    let onClose: () -> Void
    var request: AgentApplicationManagerRequest? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class OwnerProbe: NSView {
        var attached: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attached?(window) }
    }
    func makeNSView(context: Context) -> NSView {
        let view = OwnerProbe()
        view.attached = { [weak coordinator = context.coordinator] owner in
            DispatchQueue.main.async { coordinator?.update(owner: owner) }
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.current = self
        request?.changed = { [weak coordinator = context.coordinator] in
            coordinator?.update(owner: coordinator?.owner)
        }
        let presented = isPresented
        DispatchQueue.main.async { context.coordinator.update(owner: view.window, expectedPresented: presented) }
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.close(notify: false) }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        private final class ManagerPanel: NSPanel {
            override var canBecomeKey: Bool { true }
        }
        var current: AgentApplicationManagerPresenter?
        var panel: NSPanel?
        var shade: NSView?
        weak var owner: NSWindow?
        var observers: [NSObjectProtocol] = []
        private let connectorLayout = ConnectorPanelLayout()
        private var connector = false
        private var connectorHeight: CGFloat = 420
        private final class Shade: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
        }
        func update(owner: NSWindow?, expectedPresented: Bool? = nil) {
            guard let current else { return }
            if let expectedPresented, expectedPresented != current.isPresented { return }
            if let owner { self.owner = owner }
            guard current.isPresented || current.request?.presented == true else { close(notify: false); return }
            guard panel == nil, let owner = self.owner, let content = owner.contentView else { return }
            let initialTab = current.request?.presented == true ? current.request!.tab : current.initialTab
            connector = initialTab == "连接" && current.sync.sourceConnection != nil
            connectorHeight = 420
            connectorLayout.width = min(680, max(280, content.bounds.width - 32))
            connectorLayout.ownerHeight = content.bounds.height
            let shade = Shade(frame: content.bounds)
            shade.wantsLayer = true; shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.70).cgColor
            shade.autoresizingMask = [.width, .height]; content.addSubview(shade)
            self.shade = shade
            let panel = ManagerPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                styleMask: [.borderless], backing: .buffered, defer: false)
            panel.appearance = owner.appearance
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = false; panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.contentView = NSHostingView(rootView: Group {
                if initialTab == "连接", let item = current.sync.sourceConnection {
                    ConnectorPanelContent(item: item, sync: current.sync, layout: connectorLayout,
                        onClose: { [weak self] in self?.close() }, onSizeChange: { [weak self] size in
                            DispatchQueue.main.async {
                                guard let self, self.panel != nil, abs(self.connectorHeight - size.height) > 0.5 else { return }
                                self.connectorHeight = size.height; self.center()
                            }
                        })
                } else {
                    AgentApplicationManager(model: current.model, sync: current.sync,
                        isReadOnly: current.isReadOnly, initialTab: initialTab, onClose: { [weak self] in self?.close() })
                }
            })
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.cornerRadius = 24
            panel.contentView?.layer?.masksToBounds = true
            owner.addChildWindow(panel, ordered: .above)
            self.panel = panel
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.center() }
                })
            }
            center(); panel.makeKeyAndOrderFront(nil)
        }
        func center() {
            guard let owner, let content = owner.contentView, let panel else { return }
            let center = owner.convertToScreen(content.bounds)
            let width = min(connector ? 680 : 720, max(280, center.width - 32))
            let height = min(connector ? min(640, connectorHeight) : 640, center.height * 0.85)
            if connector {
                if connectorLayout.width != width { connectorLayout.width = width }
                if connectorLayout.ownerHeight != center.height { connectorLayout.ownerHeight = center.height }
            }
            let frame = NSRect(x: center.midX - width / 2, y: center.midY - height / 2, width: width, height: height)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        }
        func close(notify: Bool = true) {
            let owner = panel?.parent
            if let panel { owner?.removeChildWindow(panel); panel.orderOut(nil) }
            panel = nil; shade?.removeFromSuperview(); shade = nil
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            if notify { current?.request?.presented = false; current?.isPresented = false; current?.onClose() }
            owner?.makeKey()
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool { if sender === panel { close() }; return false }
    }
}

struct AgentApplicationManager: View {
    @ObservedObject var model: AgentChatModel
    @ObservedObject var sync: AgentMarketSyncStore
    var isReadOnly = false
    var initialTab = "应用"
    var onClose: () -> Void
    @State private var tab = "应用"
    @State private var search = ""
    @State private var route = "list"
    @State private var selectedID: String?
    @State private var nestedSkill: AgentMarketItem?
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var originalForm = ["", "", ""]
    @State private var busy = false
    @State private var notice: String?
    @State private var discardAction: String?
    @State private var confirmDelete = false
    @State private var preview: MarketMedia?
    @State private var showConnection = false
    @State private var editingIcon: AgentMarketItem?
    private var selected: AgentMarketItem? { nestedSkill ?? selectedID.flatMap { sync.snapshot?.item($0) } }
    private var dirty: Bool { [name, description, instructions].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } != originalForm }
    private var editing: Bool { route == "create" || route == "edit" }
    private var matches: [AgentMarketItem] {
        sync.managementItems.filter { $0.kind == (tab == "应用" ? "app" : "skill")
            && (search.isEmpty || ($0.title + $0.summary + ($0.raw["instructions"]?.stringValue ?? "")).localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                if route == "list" {
                    HStack(spacing: 20) {
                        ForEach(["应用", "技能"], id: \.self) { title in
                            Button { tab = title } label: {
                                Text(title).font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(tab == title ? TapSkin.ink : TapSkin.secondaryInk)
                            }.buttonStyle(.plain).accessibilityIdentifier("market-manager-tab-" + title)
                        }
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("market-manager-tabs")
                } else {
                    Button { leave("back") } label: { Label("返回", systemImage: "chevron.left") }
                        .buttonStyle(.plain).foregroundStyle(TapSkin.secondaryInk)
                        .accessibilityIdentifier("market-manager-back")
                }
                Spacer()
                Button { leave("close") } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }
                    .buttonStyle(.plain).accessibilityIdentifier("market-manager-close")
            }.frame(height: 36)
            ZStack {
                // Keep this view mounted so Return restores the same scroll position.
                browse.opacity(route == "list" ? 1 : 0).allowsHitTesting(route == "list")
                    .accessibilityHidden(route != "list")
                if editing { editor }
                else if let selected, route == "detail" { detail(selected) }
                if busy && route == "detail" {
                    TapSkin.tone(0xffffff, 0x171717).opacity(0.90)
                    VStack(spacing: 14) {
                        if let selected { MarketArtwork(item: selected, sync: sync).frame(width: 48, height: 48) }
                        ProgressView()
                        Text(sourceAdded ? "正在更新…" : "正在安装应用…").font(.system(size: 14))
                    }.accessibilityIdentifier("market-manager-progress")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let notice { Text(notice).font(.system(size: 12)).foregroundStyle(.orange).accessibilityIdentifier("market-manager-error") }
            else if let error = sync.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(TapSkin.ink).background(TapSkin.tone(0xfafafa, 0x171717))
            .accessibilityElement(children: .contain).accessibilityIdentifier("agent-application-manager")
            .onAppear {
                tab = initialTab == "创建技能" ? "技能" : initialTab
                if initialTab == "创建技能" { beginEdit(nil) }
            }
            .task { await sync.refreshManagement() }
            .onExitCommand { leave("close") }
            .alert("放弃未保存的修改？", isPresented: Binding(get: { discardAction != nil }, set: { if !$0 { discardAction = nil } })) {
                Button("取消", role: .cancel) { discardAction = nil }
                Button("放弃", role: .destructive) {
                    let action = discardAction ?? "back"; discardAction = nil
                    performLeave(action)
                }
            } message: { Text("未保存的修改将被丢弃。") }
            .alert("卸载\(selected?.kind == "app" ? "应用" : "技能")？", isPresented: $confirmDelete) {
                Button("取消", role: .cancel) {}
                Button("卸载", role: .destructive) { if let selected { mutate(selected, action: "remove") } }
            } message: { Text(selected?.title ?? "") }
            .background(AgentApplicationManagerPresenter(isPresented: $showConnection, model: model,
                sync: sync, isReadOnly: isReadOnly, initialTab: "连接", onClose: {}))
            .sheet(item: $sync.connectingItem) { item in AgentApplicationConnection(item: item, sync: sync) }
            .background(AgentMarketPreviewPresenter(media: $preview))
            .sheet(item: $editingIcon) { item in
                AgentMarketPresentationEditor(item: item, sync: sync, onClose: { editingIcon = nil })
            }
    }
    private var sourceAdded: Bool { selected.map { sync.sourceAdded($0) } ?? false }
    private var browse: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(TapSkin.secondaryInk)
                    TextField("搜索", text: $search).textFieldStyle(.plain)
                        .accessibilityIdentifier("market-manager-search")
                }.padding(.horizontal, 16).frame(height: 44)
                    .background(TapSkin.tone(0xeeeeef, 0x242424), in: RoundedRectangle(cornerRadius: 16))
                if tab == "技能" {
                    Menu {
                        Button("创建技能") { beginEdit(nil) }.accessibilityIdentifier("market-manager-create")
                        Button("上传技能文件") { upload(folder: false) }
                        Button("上传技能文件夹") { upload(folder: true) }
                    } label: { Image(systemName: "plus").frame(width: 36, height: 36) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("market-manager-skill-add")
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(matches) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .center, spacing: 10) {
                                MarketArtwork(item: item, sync: sync).frame(width: 40, height: 40)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title.replacingOccurrences(of: "TapNow", with: "创作平台", options: .caseInsensitive))
                                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    Text(item.raw["author"]?["name"]?.stringValue
                                         ?? item.raw["author_name"]?.stringValue ?? "创作平台")
                                        .font(.system(size: 11)).foregroundStyle(TapSkin.secondaryInk).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if item.kind == "app" {
                                    Button { mutate(item, action: "add") } label: {
                                        if sync.pending.contains(item.id) { ProgressView().controlSize(.small) }
                                        else { Image(systemName: sync.sourceAdded(item) ? "checkmark" : "plus").frame(width: 28, height: 28) }
                                    }.buttonStyle(.plain).disabled(sync.sourceAdded(item) || isReadOnly || busy)
                                        .accessibilityIdentifier("market-add-" + item.name)
                                }
                            }
                            Text(item.summary).font(.system(size: 12)).foregroundStyle(TapSkin.secondaryInk)
                                .lineLimit(2).frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                            if let error = sync.itemErrors[item.id] {
                                Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(TapSkin.tone(0xffffff, 0x202020), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(TapSkin.tone(0xe7e7e9, 0x333333), lineWidth: 1))
                            .contentShape(Rectangle()).onTapGesture { open(item) }
                            .accessibilityElement(children: .contain).accessibilityIdentifier("market-card-" + item.name)
                            .accessibilityAction { open(item) }
                            .contextMenu {
                                Button("查看详情") { open(item) }
                                Button("图标与封面") { editingIcon = item }
                                if item.kind == "app", sync.installed[item.id]?.connection != nil {
                                    Button("管理工具连接") { sync.connectingItem = item }
                                }
                            }
                    }
                }.padding(1)
                if matches.isEmpty { Text("没有匹配的\(tab)").foregroundStyle(TapSkin.secondaryInk).padding(36) }
            }
        }
    }
    private func detail(_ item: AgentMarketItem) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                if item.kind == "app" { MarketArtwork(item: item, sync: sync).frame(width: 40, height: 40) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 18, weight: .bold))
                    Text(item.raw["author"]?["name"]?.stringValue ?? (item.isEditable ? "个人" : "创作平台"))
                        .font(.system(size: 14)).foregroundStyle(TapSkin.secondaryInk)
                }
                Spacer()
                if sync.sourceAdded(item) && (item.kind == "skill" || item.raw["install_mode"] != "system") {
                    Toggle("", isOn: Binding(get: { sync.sourceEnabled(item) }, set: { mutate(item, action: $0 ? "enabled" : "disabled") }))
                        .labelsHidden().toggleStyle(.switch).disabled(busy || isReadOnly)
                        .accessibilityIdentifier("market-manager-enabled")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if item.kind == "app" {
                        MarketMediaGallery(item: item, onPreview: { preview = $0 })
                        Text(item.raw["public_content"]?.stringValue ?? item.raw["long_description"]?.stringValue ?? item.raw["description"]?.stringValue ?? item.summary)
                            .font(.system(size: 14)).foregroundStyle(TapSkin.secondaryInk).textSelection(.enabled)
                        ForEach(item.connectorIDs, id: \.self) { id in
                            HStack {
                                Label(id, systemImage: "link")
                                Spacer()
                                Button(sync.connectorStatus(id) == "authenticated" ? "断开连接" : "连接") {
                                    if sync.connectorStatus(id) == "authenticated" {
                                        work {
                                            try await sync.service.disconnectConnector(id, session: sync.requireSession())
                                            await sync.refreshManagement()
                                        }
                                    } else { connectSource(item) }
                                }.buttonStyle(ConnectorButtonStyle(primary: false)).disabled(busy || isReadOnly)
                                    .accessibilityIdentifier("market-manager-connector-" + id)
                            }
                        }
                        if let skills = item.raw["skills"]?.arrayValue, !skills.isEmpty {
                            Text("技能").foregroundStyle(TapSkin.secondaryInk)
                            ForEach(Array(skills.enumerated()), id: \.offset) { index, raw in
                                Button {
                                    var fields = raw.objectValue ?? [:]; fields["kind"] = "skill"
                                    fields["name"] = raw["name"] ?? .string(item.activationSkill)
                                    fields["display_name"] = raw["display_name"] ?? fields["name"]
                                    fields["source"] = "system"; fields["is_editable"] = false
                                    let skill = AgentMarketItem(.object(fields))
                                    nestedSkill = skill
                                    Task {
                                        do {
                                            let value = try await sync.service.pluginSkill(item, name: skill.name, session: sync.requireSession())
                                            if selectedID == item.id, nestedSkill?.name == skill.name {
                                                var next = fields
                                                for (key, field) in value.objectValue ?? [:] { next[key] = field }
                                                nestedSkill = AgentMarketItem(.object(next))
                                            }
                                        } catch {
                                            if selectedID == item.id, nestedSkill?.name == skill.name { notice = error.localizedDescription }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "puzzlepiece.extension").frame(width: 32, height: 32)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(raw["display_name"]?.stringValue ?? raw["name"]?.stringValue ?? item.title)
                                            Text(raw["description"]?.stringValue ?? "").foregroundStyle(TapSkin.secondaryInk).lineLimit(1)
                                        }
                                        Spacer()
                                    }.font(.system(size: 12)).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityIdentifier("market-manager-plugin-skill-\(index)")
                            }
                        }
                    } else {
                        Text(item.summary).font(.system(size: 14)).foregroundStyle(TapSkin.secondaryInk)
                        if let body = item.raw["instructions"]?.stringValue ?? item.raw["public_content"]?.stringValue {
                            Text(body).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        } else { Text("尚未取得此 Skill 的完整正文").foregroundStyle(TapSkin.secondaryInk) }
                        if let files = item.raw["support_files"]?.arrayValue ?? item.raw["files"]?.arrayValue, !files.isEmpty {
                            Text("支持文件").foregroundStyle(TapSkin.secondaryInk)
                            ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                                let name = file["path"]?.stringValue ?? file["name"]?.stringValue ?? "文件"
                                if let address = file["url"]?.stringValue, let url = URL(string: address), url.scheme == "https" {
                                    Link(name, destination: url)
                                } else {
                                    Text(name).foregroundStyle(TapSkin.secondaryInk)
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
            }.accessibilityIdentifier("market-manager-detail")
            Divider()
            HStack(spacing: 16) {
                if nestedSkill == nil {
                    if sync.sourceAdded(item) {
                        if item.kind == "app" ? item.raw["install_mode"] != "system" : item.isEditable {
                            Button("卸载") { confirmDelete = true }.buttonStyle(.plain)
                                .foregroundStyle(.red).accessibilityIdentifier("market-manager-uninstall")
                        }
                        if item.isEditable {
                            Button("编辑") { beginEdit(item) }.buttonStyle(.plain).accessibilityIdentifier("market-manager-edit")
                        }
                        Spacer()
                        Button("在对话中使用") { use(item) }.buttonStyle(ConnectorButtonStyle(primary: true))
                            .disabled(item.connectorIDs.contains { sync.connectorStatus($0) == nil })
                            .accessibilityIdentifier("market-manager-use")
                    } else {
                        Spacer()
                        Button(item.kind == "app" ? "安装应用" : "添加技能") { mutate(item, action: "add") }
                            .buttonStyle(ConnectorButtonStyle(primary: true)).accessibilityIdentifier("market-manager-install")
                    }
                }
            }.disabled(busy || isReadOnly).frame(height: 32)
        }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(route == "create" ? "创建技能" : "编辑技能").font(.system(size: 18, weight: .bold)); Text("个人").foregroundStyle(TapSkin.secondaryInk) }
            Text("名称").font(.system(size: 13))
            TextField("技能名称", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("market-skill-name")
            Text("描述").font(.system(size: 13))
            TextEditor(text: $description).frame(height: 72).accessibilityIdentifier("market-skill-description")
            Text("指令").font(.system(size: 13))
            TextEditor(text: $instructions).frame(maxHeight: .infinity).accessibilityIdentifier("market-skill-instructions")
            HStack {
                Spacer()
                Button("取消") { leave("back") }.disabled(!dirty).accessibilityIdentifier("market-skill-cancel")
                Button(route == "create" ? "创建" : "保存") {
                    work {
                        let previous = route == "edit" ? selected : nil
                        let oldName = previous?.title
                        let saved = try await sync.saveManagedSkill(original: previous, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines))
                        if let oldName {
                        for index in model.draftSkillReferences.indices where model.draftSkillReferences[index].name == oldName {
                                let reference = model.draftSkillReferences[index]
                                model.draftSkillReferences[index] = AgentSkillReference(name: saved.title, path: reference.path,
                                    markdown: reference.markdown, applicationID: reference.applicationID)
                            }
                        }
                        selectedID = saved.id; route = previous == nil ? "list" : "detail"
                    }
                }.buttonStyle(ConnectorButtonStyle(primary: true)).disabled(!dirty || busy)
                    .accessibilityIdentifier("market-skill-save")
            }
        }.disabled(isReadOnly || busy)
    }
    private func open(_ item: AgentMarketItem) {
        selectedID = item.id; route = "detail"; notice = nil; nestedSkill = nil
        work { try await sync.managementDetail(item) }
    }
    private func beginEdit(_ item: AgentMarketItem?) {
        if let item, !item.isEditable { return }
        selectedID = item?.id; nestedSkill = nil
        name = item?.name ?? ""; description = item?.raw["description"]?.stringValue ?? ""
        instructions = item?.raw["instructions"]?.stringValue ?? ""
        originalForm = [name, description, instructions].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        route = item == nil ? "create" : "edit"; notice = nil
    }
    private func leave(_ action: String) {
        guard !busy else { return }
        if editing && dirty { discardAction = action }
        else { performLeave(action) }
    }
    private func performLeave(_ action: String) {
        if action == "close" { onClose() }
        else if nestedSkill != nil { nestedSkill = nil }
        else if route == "edit" { route = "detail" }
        else { route = "list"; notice = nil }
    }
    private func mutate(_ item: AgentMarketItem, action: String) {
        work {
            try await sync.changeInstallation(item, action: action)
            if action == "remove" { route = "list" }
            if action == "add", sync.session != nil, !item.connectorIDs.isEmpty {
                selectedID = item.id; connectSource(item)
            }
        }
    }
    private func connectSource(_ item: AgentMarketItem) {
        if sync.sourceConnection?.id != item.id { sync.sourceAuth = nil }
        sync.sourceConnection = item; showConnection = true
    }
    private func work(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; notice = nil
        Task { defer { busy = false }; do { try await operation() } catch { notice = error.localizedDescription } }
    }
    private func use(_ item: AgentMarketItem) {
        if item.kind == "app", !sync.isInstalled(item) {
            sync.connectionPrompt = item; onClose(); return
        }
        work {
            if !sync.sourceEnabled(item) { try await sync.changeInstallation(item, action: "enabled") }
            if try await model.prepareReference(loader: { try await sync.reference(item) }) { onClose() }
        }
    }
    private func upload(folder: Bool) {
        let panel = NSOpenPanel(); panel.canChooseFiles = !folder; panel.canChooseDirectories = folder
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            work {
                try await sync.importManagedSkill(url, folder: folder)
            }
        }
    }
}

struct AgentApplicationConnection: View {
    let item: AgentMarketItem
    @ObservedObject var sync: AgentMarketSyncStore
    @State private var tools: [AgentMCPTool] = []
    @State private var selected = Set<String>()
    @State private var client: AgentMCPClient?
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var authorization = AgentMarketAuthorization()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                MarketArtwork(item: item, sync: sync).frame(width: 36, height: 36)
                Text("连接" + item.title).font(.headline)
                Spacer()
                Button { task?.cancel(); authorization.cancel(); dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            if tools.isEmpty {
                Text("此应用需要工具服务授权。连接后，选择供当前 Agent 使用的工具。")
                    .font(.system(size: 13)).foregroundStyle(TapSkin.secondaryInk)
                Button("连接并授权") { connect(authorize: true) }
                    .buttonStyle(.borderedProminent).disabled(busy)
                    .accessibilityIdentifier("market-connect-authorize")
            } else {
                Text("选择绑定到“\(item.title)”的工具").font(.system(size: 13))
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(tools) { tool in
                            Toggle(isOn: Binding(get: { selected.contains(tool.name) },
                                set: { if $0 { selected.insert(tool.name) } else { selected.remove(tool.name) } })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tool.name).font(.system(size: 12, weight: .medium))
                                    Text(tool.description).font(.system(size: 11)).foregroundStyle(TapSkin.secondaryInk).lineLimit(3)
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }.padding(2)
                }.frame(maxHeight: 280)
                Button("添加到 Agent") {
                    guard let client else { return }
                    busy = true; error = nil
                    task = Task {
                        defer { busy = false }
                        do { try await sync.bind(item, client: client, selectedNames: selected); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(busy || selected.isEmpty)
                    .accessibilityIdentifier("market-connect-bind")
            }
            if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
        }.padding(24).frame(width: 480)
            .task { connect(authorize: false) }
            .onDisappear { task?.cancel(); authorization.cancel() }
    }
    private func connect(authorize: Bool) {
        guard !busy, let scope = sync.snapshot?.scope else { return }
        busy = true; error = nil
        task = Task {
            defer { busy = false }
            do {
                if authorize { try await authorization.connect(scope: scope) }
                let client = sync.clientFactory(AgentMCPClient.officialEndpoint, scope)
                let list = try await client.listTools()
                try Task.checkCancellation()
                guard sync.snapshot?.scope == scope else { throw AgentMCPError.invalidBinding }
                guard !list.isEmpty else { throw AgentMCPError.unavailable }
                self.client = client; tools = list
                // A generic server's inventory does not prove application
                // membership. The user explicitly chooses the mapping.
                selected = []
            } catch AgentMCPError.authorization where !authorize {
                // An unconnected app presents the authorization action.
            } catch { self.error = error.localizedDescription }
        }
    }
}
