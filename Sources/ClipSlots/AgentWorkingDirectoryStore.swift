import AppKit
import Combine
import ClipSlotsKit

@MainActor
final class AgentWorkingDirectoryStore: ObservableObject {
    static let shared = AgentWorkingDirectoryStore(root: ClipSlotsPaths.dataRoot)
    @Published private(set) var directories: [AgentWorkingDirectory] = []
    @Published private(set) var isChoosing = false
    @Published var error: String?
    private let catalog: AgentDirectoryCatalog
    private let journalRoot: URL
    private final class LiveGrant {
        weak var access: AgentDirectoryAccess?
        let id: UUID
        init(_ access: AgentDirectoryAccess, id: UUID) { self.access = access; self.id = id }
    }
    private var liveGrants: [LiveGrant] = []
    private func revoke(_ id: UUID) {
        for grant in liveGrants where grant.id == id { grant.access?.revoke() }
        liveGrants.removeAll { $0.id == id || $0.access == nil }
    }

    init(root: URL) {
        catalog = AgentDirectoryCatalog(root: root)
        journalRoot = root.appendingPathComponent("agent-directory-journal", isDirectory: true)
        do { directories = try catalog.load() }
        catch { self.error = error.localizedDescription }
    }
    func entry(_ id: UUID?) -> AgentWorkingDirectory? { directories.first { $0.id == id } }
    func access(_ id: UUID, sessionID: String? = nil, projectID: String? = nil) throws -> AgentDirectoryAccess {
        guard let entry = entry(id) else { throw AgentDirectoryError.unavailable }
        let context = sessionID.map {
            AgentDirectoryJournalContext(root: journalRoot, authorizationID: (entry.authorizationID ?? entry.id).uuidString,
                                         sessionID: $0, projectID: projectID)
        }
        let grant = try entry.resolve(journal: context)
        if grant.bookmarkNeedsRefresh || grant.url.path != entry.path {
            let renewed = try AgentWorkingDirectory.authorize(grant.url, id: id)
            var next = directories
            if let index = next.firstIndex(where: { $0.id == id }) {
                next[index].bookmark = renewed.bookmark
                next[index].path = renewed.path
                next[index].name = renewed.name
                try catalog.save(next)
                directories = next
            }
        }
        liveGrants.removeAll { $0.access == nil }
        liveGrants.append(LiveGrant(grant, id: id))
        return grant
    }
    @discardableResult
    func add(_ url: URL, replacing id: UUID? = nil) async throws -> UUID {
        let entry = try await Task.detached(priority: .userInitiated) {
            try AgentWorkingDirectory.authorize(url, id: id ?? UUID())
        }.value
        var next = directories
        let existing = next.firstIndex(where: { $0.id == id || $0.path == entry.path })
        let chosenID: UUID
        if let existing {
            var updated = next[existing]
            updated.name = entry.name; updated.path = entry.path; updated.bookmark = entry.bookmark
            updated.authorizationID = entry.authorizationID
            chosenID = updated.id
            next[existing] = updated
        } else { next.append(entry); chosenID = entry.id }
        try catalog.save(next)
        if let existing { revoke(directories[existing].id) }
        directories = next
        error = nil
        return chosenID
    }
    func remove(_ id: UUID) throws {
        let next = directories.filter { $0.id != id }
        try catalog.save(next)
        revoke(id)
        directories = next
        error = nil
    }
    func choose(replacing id: UUID? = nil, completion: @escaping (UUID) -> Void) {
        guard !isChoosing else { return }
        let panel = NSOpenPanel()
        panel.title = id == nil ? "添加本地目录" : "重新定位工作目录"
        panel.message = "Agent 可在此目录内读取文件；写入前会展示内容并等待确认。"
        panel.prompt = "使用此目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let previous = entry(id) { panel.directoryURL = URL(fileURLWithPath: previous.path) }
        isChoosing = true
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                defer { self.isChoosing = false }
                guard response == .OK, let url = panel.url else { return }
                do { completion(try await self.add(url, replacing: id)) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
