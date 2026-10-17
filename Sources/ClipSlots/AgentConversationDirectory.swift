import Foundation
import Combine
import ClipSlotsKit

enum AgentConversationSource: Hashable, Sendable {
    case workspace
    case edit
    case legacyCanvas
    case project(String)

    var projectID: String? {
        if case .project(let id) = self { return id }
        return nil
    }

    func url(dataRoot: URL) -> URL {
        let root = dataRoot.appendingPathComponent("agent-sessions")
        switch self {
        case .workspace: return root.appendingPathComponent("workspace.json")
        case .edit: return root.appendingPathComponent("edit.json")
        case .legacyCanvas: return root.appendingPathComponent("canvas.json")
        case .project(let id):
            let safeID = Data(id.utf8).map { String(format: "%02x", $0) }.joined()
            return root.appendingPathComponent("canvas-projects/\(safeID).json")
        }
    }

    static func projectSource(filename: String) -> Self? {
        let hex = filename
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let value = UInt8(hex[index..<end], radix: 16) else { return nil }
            bytes.append(value)
            index = end
        }
        guard let id = String(bytes: bytes, encoding: .utf8), !id.isEmpty else { return nil }
        return .project(id)
    }

    var sortKey: String {
        switch self {
        case .workspace: return "0"
        case .edit: return "1"
        case .legacyCanvas: return "2"
        case .project(let id): return "3:" + id
        }
    }
}

struct AgentConversationEntry: Identifiable, Sendable {
    let id: UUID
    let source: AgentConversationSource
    let title: String
    let updatedAt: Date
    let searchableText: String
    let isCurrent: Bool
    let isRunning: Bool

    init(_ saved: AgentChatModel.SavedConversation, source: AgentConversationSource,
         current: Bool, running: Bool = false) {
        id = saved.id
        self.source = source
        title = saved.title.isEmpty ? "未发送草稿" : saved.title
        updatedAt = saved.updatedAt
        searchableText = saved.title + "\n" + saved.draft + "\n"
            + saved.messages.map(\.content).joined(separator: "\n")
        isCurrent = current
        isRunning = running
    }
}

/// Metadata-only index. Models remain owned by AgentSessionStore, with one
/// writer per original file. No merged transcript or migration is produced.
@MainActor
final class AgentConversationDirectory: ObservableObject {
    @Published private(set) var entries: [AgentConversationEntry] = []
    @Published private(set) var selectedModel: AgentChatModel
    @Published private(set) var selectedSource: AgentConversationSource = .workspace
    @Published private(set) var readOnlyReason: String?
    @Published private(set) var error: String?
    @Published private(set) var isScanning = false
    private weak var sessions: AgentSessionStore?
    private weak var canvas: CanvasStore?
    private var projects: [CanvasProject] = []
    private var diskEntries: [AgentConversationEntry] = []
    private var revisionTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()
    private var observers: Set<AnyCancellable> = []
    private var canvasObservers: Set<AnyCancellable> = []

    init(sessions: AgentSessionStore) {
        self.sessions = sessions
        selectedModel = sessions.agent
        observeChanges()
        rebuild()
    }

    /// Keeps existing isolated rendering fixtures usable without a global store.
    init(singleModel: AgentChatModel) {
        selectedModel = singleModel
        observeChanges()
        rebuild()
    }

    private func observeChanges() {
        NotificationCenter.default.publisher(for: AgentChatModel.conversationChangedNotification)
            .sink { [weak self] notification in
                guard let self, let model = notification.object as? AgentChatModel,
                      self.sessions?.liveSessions.contains(where: { $0.1 === model }) == true
                        || self.selectedModel === model else { return }
                self.revisionTask?.cancel()
                self.revisionTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    self?.rebuild()
                }
            }.store(in: &observers)
    }

    func bind(canvas: CanvasStore) {
        if self.canvas === canvas { return }
        self.canvas = canvas
        projects = canvas.projects
        canvasObservers.removeAll()
        canvas.$projects.sink { [weak self] projects in
            self?.projects = projects
            Task { @MainActor [weak self] in self?.rebuild() }
        }.store(in: &canvasObservers)
        canvas.$activeProjectId.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateReadOnlyState() }
        }.store(in: &canvasObservers)
        rebuild()
    }

    func sourceLabel(_ source: AgentConversationSource) -> String {
        switch source {
        case .workspace: return "Agent 页"
        case .edit: return "编辑助手"
        case .legacyCanvas: return "旧版画布记录"
        case .project(let id):
            return projects.first { $0.id == id }.map { "画布 · " + $0.name }
                ?? "已移除项目 · " + String(id.prefix(8))
        }
    }

    func refresh() {
        guard let sessions else { rebuild(); return }
        scanTask?.cancel()
        let token = UUID()
        scanID = token
        let dataRoot = sessions.dataRoot
        isScanning = true
        scanTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.scan(dataRoot: dataRoot)
            }.value
            guard let self, self.scanID == token, !Task.isCancelled else { return }
            self.diskEntries = result.entries
            self.error = result.failedFiles.isEmpty ? nil
                : "部分历史无法读取，原文件保留：" + result.failedFiles.joined(separator: "、")
            self.isScanning = false
            self.rebuild()
        }
    }

    private nonisolated static func scan(dataRoot: URL) -> (entries: [AgentConversationEntry], failedFiles: [String]) {
        var sources: [AgentConversationSource] = [.workspace, .edit, .legacyCanvas]
        let projectFolder = dataRoot.appendingPathComponent("agent-sessions/canvas-projects")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: projectFolder, includingPropertiesForKeys: nil)) ?? []
        sources += files.filter { $0.pathExtension == "json" }.compactMap {
            AgentConversationSource.projectSource(filename: $0.deletingPathExtension().lastPathComponent)
        }
        var rows: [AgentConversationEntry] = []
        var failed: [String] = []
        for source in sources {
            let url = source.url(dataRoot: dataRoot)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let saved = try JSONDecoder().decode(AgentChatModel.SavedSessions.self, from: Data(contentsOf: url))
                if !saved.current.messages.isEmpty || !saved.current.draft.isEmpty
                    || !(saved.current.draftSkillReferences ?? []).isEmpty
                    || !(saved.current.draftReferences ?? []).isEmpty
                    || !(saved.current.draftAttachments ?? []).isEmpty {
                    rows.append(.init(saved.current, source: source, current: true))
                }
                rows += saved.recent.map { .init($0, source: source, current: false) }
            } catch { failed.append(url.lastPathComponent) }
        }
        return (rows, failed)
    }

    func rebuild() {
        let live = sessions?.liveSessions ?? [(.workspace, selectedModel)]
        let liveSources = Set(live.map(\.0))
        var rows = diskEntries.filter { !liveSources.contains($0.source) }
        for (source, model) in live {
            if model.containsCurrentConversation {
                rows.append(.init(model.snapshot, source: source, current: true, running: model.isRunning))
            }
            rows += model.recentConversations.map { .init($0, source: source, current: false) }
        }
        // Live entries win over stale disk records, then newest timestamp and a
        // deterministic source order break UUID collisions without copying data.
        rows.sort {
            let a = liveSources.contains($0.source), b = liveSources.contains($1.source)
            if a != b { return a }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            return $0.source.sortKey < $1.source.sortKey
        }
        var seen = Set<UUID>()
        entries = rows.filter { seen.insert($0.id).inserted }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        updateReadOnlyState()
    }

    @discardableResult
    func open(_ entry: AgentConversationEntry, canvas: CanvasStore, store: SlotStoreObservable) -> Bool {
        guard let sessions else {
            selectedModel.openConversation(id: entry.id)
            rebuild()
            return selectedModel.selectedConversationID == entry.id
        }
        bind(canvas: canvas)
        let model: AgentChatModel
        if let id = entry.source.projectID, canvas.projects.contains(where: { $0.id == id }) {
            if canvas.activeProjectId != id && !canvas.switchProject(to: id) {
                error = "画布项目切换未完成，请先保存当前画布再重试。"
                return false
            }
            model = sessions.canvasSession(canvas: canvas, store: store)
        } else {
            model = sessions.session(source: entry.source)
        }
        guard model.selectedConversationID == entry.id
            || model.recentConversations.contains(where: { $0.id == entry.id }) else {
            error = "这条记录已变化，请刷新会话目录。"
            refresh()
            return false
        }
        if model.selectedConversationID != entry.id { model.openConversation(id: entry.id) }
        selectedSource = entry.source
        selectedModel = model
        error = nil
        rebuild()
        return true
    }

    func newConversation(source: AgentConversationSource, canvas: CanvasStore, store: SlotStoreObservable) {
        guard let sessions else { selectedModel.clearHistory(); rebuild(); return }
        let model: AgentChatModel
        if let id = source.projectID {
            guard canvas.projects.contains(where: { $0.id == id }),
                  canvas.activeProjectId == id || canvas.switchProject(to: id) else {
                error = "此项目不可用，不能新建项目会话。"; return
            }
            model = sessions.canvasSession(canvas: canvas, store: store)
        } else {
            model = sessions.session(source: source)
        }
        model.clearHistory()
        selectedSource = source
        selectedModel = model
        rebuild()
    }

    private func updateReadOnlyState() {
        if selectedSource == .legacyCanvas {
            readOnlyReason = "旧版画布记录仅供查看，请在所属项目的新会话中继续。"
        } else if let id = selectedSource.projectID, canvas?.activeProjectId != id {
            readOnlyReason = projects.contains(where: { $0.id == id })
                ? "当前展示其他项目的记录，返回所属画布项目后继续。"
                : "此画布项目已移除，记录保留为只读。"
        } else {
            readOnlyReason = nil
        }
    }
}
