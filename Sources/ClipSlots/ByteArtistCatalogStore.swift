import Foundation
import ClipSlotsKit

@MainActor
final class ByteArtistCatalogStore: ObservableObject {
    static let shared = ByteArtistCatalogStore()
    @Published private(set) var capabilities: [GenerationCapability] = []
    @Published private(set) var available: [(id: String, title: String)] = []
    @Published private(set) var workflows: [ByteArtistWorkflowSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var preparingID: String?
    @Published private(set) var issues: [String] = []
    @Published private(set) var hasMore = false
    @Published private(set) var total = 0
    @Published private(set) var favorites = Set<String>()
    @Published var error: String?
    var busy: Bool { isLoading || preparingID != nil }
    private var loadedAt: Date?
    private var page = 0
    private var operation: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var operationID = UUID()
    private var selectionID = UUID()
    private var outputMappings: [String: [GenerationOutputBinding]] = [:]
    private let preferencesURL: URL
    private struct Preferences: Codable {
        var favorites: Set<String>
        var mappings: [String: [GenerationOutputBinding]]
    }
    init(root: URL = ClipSlotsPaths.dataRoot) {
        preferencesURL = root.appendingPathComponent("byteartist/library-preferences.json")
        if let data = try? Data(contentsOf: preferencesURL),
           let saved = try? JSONDecoder().decode(Preferences.self, from: data) {
            favorites = saved.favorites; outputMappings = saved.mappings
        }
    }
    #if DEBUG
    var fixtureRuntime: ByteArtistRuntime?
    #endif
    func runtime() throws -> ByteArtistRuntime {
        #if DEBUG
        if let fixtureRuntime { return fixtureRuntime }
        #endif
        return try ByteArtistRuntime()
    }
    func capability(id: String) -> GenerationCapability? { capabilities.first { $0.id == id } }
    func loadIfNeeded() {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 600 { return }
        if !isLoading { reload() }
    }
    var entries: [ByteArtistWorkflowSummary] {
        var rows = Dictionary(workflows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in available where rows[item.id] == nil { rows[item.id] = .init(id: item.id, title: item.title) }
        for capability in capabilities {
            rows[capability.id] = .init(id: capability.id, title: capability.title,
                description: capability.metadata["description"]?.stringValue ?? rows[capability.id]?.description ?? "")
        }
        return rows.values.sorted {
            let a = favorites.contains($0.id), b = favorites.contains($1.id)
            return a == b ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : a
        }
    }
    func reload() {
        operation?.cancel()
        let token = UUID(); operationID = token
        isLoading = true; error = nil; issues = []
        operation = Task {
            defer { if operationID == token { isLoading = false; operation = nil } }
            do {
                let adapter = try runtime().adapter
                // Failure in a single source does not hide the other sources.
                do {
                    let imported = try await adapter.discoverCatalog()
                    guard !Task.isCancelled, operationID == token else { return }
                    capabilities = imported.capabilities; issues += imported.issues
                } catch { if !Task.isCancelled { issues.append(error.localizedDescription) } }
                do {
                    let local = try await adapter.localReferences()
                    guard !Task.isCancelled, operationID == token else { return }
                    available = local
                } catch { if !Task.isCancelled { issues.append(error.localizedDescription) } }
                let result = try await adapter.workflows()
                guard !Task.isCancelled, operationID == token else { return }
                workflows = result.workflows; total = result.total
                page = 1; hasMore = result.hasMore; loadedAt = Date()
            } catch {
                if !Task.isCancelled, operationID == token { self.error = error.localizedDescription }
            }
        }
    }
    func loadMore() {
        guard hasMore, !isLoading else { return }
        isLoading = true
        let token = UUID(); operationID = token
        operation = Task {
            defer { if operationID == token { isLoading = false; operation = nil } }
            do {
                let result = try await runtime().adapter.workflows(page: page + 1)
                guard !Task.isCancelled, operationID == token else { return }
                let known = Set(workflows.map(\.id))
                workflows += result.workflows.filter { !known.contains($0.id) }
                page = result.page; total = result.total; hasMore = result.hasMore
            } catch {
                if !Task.isCancelled, operationID == token { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() {
        operation?.cancel(); selectionTask?.cancel()
        operationID = UUID(); selectionID = UUID()
        isLoading = false; preparingID = nil
    }
    func add(id: String, selected: @escaping (GenerationCapability) -> Void) {
        selectionTask?.cancel()
        let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = UUID(); selectionID = token
        preparingID = clean; error = nil
        selectionTask = Task {
            defer { if selectionID == token { preparingID = nil; selectionTask = nil } }
            do {
                let adapter = try runtime().adapter
                try await adapter.preflight()
                try await adapter.refreshReference(id: clean)
                let result = try await adapter.discoverCatalog()
                guard !Task.isCancelled, selectionID == token else { return }
                capabilities = result.capabilities; issues = result.issues
                guard let capability = capabilities.first(where: { $0.id == clean }) else {
                    throw GenerationAdapterError.invalidResponse
                }
                selected(capability)
            } catch { if !Task.isCancelled, selectionID == token { self.error = error.localizedDescription } }
        }
    }
    func select(id: String, kind: GenerationArtifactKind, selected: @escaping (GenerationCapability) -> Void) {
        if let capability = capability(id: id) {
            guard capability.kind == kind else { error = "该能力与当前节点类型不匹配。"; return }
            selected(capability)
        } else {
            add(id: id) { capability in
                guard capability.kind == kind else {
                    self.error = "该工作流输出\(capability.kind.rawValue)，请在对应类型的节点使用。"; return
                }
                selected(capability)
            }
        }
    }
    func remove(_ id: String) {
        do {
            try runtime().adapter.removeReference(id: id)
            capabilities.removeAll { $0.id == id }
        } catch { self.error = error.localizedDescription }
    }
    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        savePreferences()
    }
    func mappings(for capability: GenerationCapability) -> [GenerationOutputBinding] {
        outputMappings[capability.id + "|" + capability.revision] ?? []
    }
    func saveMappings(_ mappings: [GenerationOutputBinding], task: GenerationTaskHandle) {
        outputMappings[task.capabilityID + "|" + task.capabilityRevision] = mappings
        savePreferences()
    }
    private func savePreferences() {
        do {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Preferences(favorites: favorites, mappings: outputMappings))
                .write(to: preferencesURL, options: .atomic)
        } catch { self.error = "能力偏好保存失败，请检查目录权限。" }
    }
}
