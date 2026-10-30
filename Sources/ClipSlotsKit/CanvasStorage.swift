import Foundation

/// 画布文档的落盘存储（v2.11.7）。
///
/// 范式对齐 `SlotConnectionStorage`：内存缓存 + `NSLock`、跨进程 `StorageLock` 保护落盘、
/// `.atomic` 原子写、写前字节比对跳过无变化 IO、损坏文件旁置 `.corrupt` 备份。
///
/// 与槽位数据的一处**刻意差异**：画布是派生资产（节点可重建、产物另存），所以解码失败时
/// 直接返回 `.empty` 让用户从空画布重来，而不是像槽位那样层层设防。把 `.corrupt` 留在盘上
/// 是为了事后能捞，但不因此阻塞进入画布。
///
/// ★ v2.13.0：文档按**项目**分文件（`canvas/projects/<projectId>/canvas.json`）。同时新增
/// `lastLoadFailed` —— 因为"解码失败就当空画布"这条策略和 v2.13.0 的私有槽位清扫
/// （`CanvasPrivateSlotSweep`）是致命组合：空画布意味着"没有任何槽位被引用"，清扫会把整个
/// 项目的内容一次抹掉。清扫必须能问出"这份空画布是真的空，还是根本没读出来"。
public final class CanvasStorage {

    public static let shared = CanvasStorage()

    private let cacheLock = NSLock()
    /// projectId → 文档。按项目分桶，切项目时不必互相清缓存。
    private var cache: [String: CanvasDocument] = [:]
    /// projectId → 这个项目最近一次 `load()` 是否因为文件损坏而回落成空画布。
    private var loadFailed: [String: Bool] = [:]
    private var saveErrors: [String: String] = [:]

    /// 覆盖数据目录，仅供测试使用。
    private let rootOverride: URL?

    public init(rootOverride: URL? = nil) {
        self.rootOverride = rootOverride
    }

    private var canvasDir: URL {
        (rootOverride ?? ClipSlotsPaths.dataRoot).appendingPathComponent("canvas", isDirectory: true)
    }

    /// 某个项目的画布文档路径。
    ///
    /// 与 `CanvasProjectStorage.docURL` 保持同一套拼法（那边负责项目索引与迁移，这边负责文档
    /// 本体）。刻意各自拼一次而不是互相调用：两个 Storage 之间引入依赖会让测试的 rootOverride
    /// 串成一条链，而路径规则只有两行。
    private func fileURL(projectId: String) -> URL {
        canvasDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent("canvas.json")
    }

    /// 这个项目最近一次加载是不是失败了（文档损坏 → 回落成空画布）。
    ///
    /// **清扫私有槽位前必须问一次**，理由见类型注释。
    public func lastLoadFailed(projectId: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return loadFailed[projectId] ?? false
    }

    public func lastSaveError(projectId: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return saveErrors[projectId]
    }

    /// A user-confirmed gateway command compares the graph on disk while the
    /// cross-process storage lock is held. A concurrent writer wins instead of
    /// being silently overwritten by a delayed Agent response.
    public func saveComparingGraph(_ document: CanvasDocument, expectedRevision: String,
                                   projectId: String) throws {
        let url = fileURL(projectId: projectId)
        try StorageLock.shared.withLock {
            let existing = try JSONDecoder().decode(CanvasDocument.self, from: Data(contentsOf: url))
            guard AgentCanvasSync.revision(existing) == expectedRevision else {
                throw AgentOperationError("画布已被另一进程修改，请重新检查预览后应用。")
            }
            var next = document
            next.schemaVersion = CanvasDocument.currentSchemaVersion
            next.updatedAt = Date()
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            cacheLock.lock()
            cache[projectId] = next
            loadFailed[projectId] = false
            saveErrors.removeValue(forKey: projectId)
            cacheLock.unlock()
        }
    }

    // MARK: - 读

    /// Strict readback never converts a missing/corrupt source into an empty
    /// graph, migrates files, or consults the rendering/storage cache.
    public func readbackSnapshot(projectId: String) throws -> AgentCanvasReadbackSnapshot {
        guard !projectId.isEmpty, projectId.utf8.count <= 512, ![".", ".."].contains(projectId),
              !projectId.contains("/"), !projectId.contains("\\"),
              !projectId.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentGatewayError.originMismatch
        }
        struct StrictGraph: Decodable {
            let nodes: [CanvasNode]
            let edges: [CanvasEdge]
            enum CodingKeys: String, CodingKey { case schemaVersion, nodes, edges }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                guard try c.decode(Int.self, forKey: .schemaVersion) == CanvasDocument.currentSchemaVersion else {
                    throw AgentGatewayError.malformedPayload
                }
                nodes = try c.decode([CanvasNode].self, forKey: .nodes)
                // The native v2 encoder deliberately omits empty edges.
                // Missing nodes/file and malformed arrays still fail strictly.
                edges = try c.decodeIfPresent([CanvasEdge].self, forKey: .edges) ?? []
            }
        }
        return try StorageLock.shared.withLock {
            let url = fileURL(projectId: projectId)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 64 * 1024 * 1024 else {
                throw AgentGatewayError.malformedPayload
            }
            let graph = try JSONDecoder().decode(StrictGraph.self, from: Data(contentsOf: url))
            guard Set(graph.nodes.map(\.id)).count == graph.nodes.count,
                  Set(graph.edges.map(\.id)).count == graph.edges.count else {
                throw AgentGatewayError.malformedPayload
            }
            return .init(projectID: projectId, nodes: graph.nodes, edges: graph.edges)
        }
    }

    /// 读取画布文档。缓存命中直接返回；未命中读盘（**不持 cacheLock 做 IO**，避免同步磁盘
    /// 读阻塞其他线程 —— 这是 P2-2 在连线存储上踩过的坑）。
    public func load(projectId: String) -> CanvasDocument {
        cacheLock.lock()
        if let cached = cache[projectId] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let url = fileURL(projectId: projectId)
        var loaded: CanvasDocument? = nil
        var failed = false
        do {
            try WorkflowProjectTransaction(root: rootOverride ?? ClipSlotsPaths.dataRoot).recover(projectID: projectId)
            try CanvasStructureCopyTransaction(root: rootOverride ?? ClipSlotsPaths.dataRoot).recover(projectID: projectId)
        } catch {
            // Keep graph/content/journal intact for recovery. In particular, never run private reconciliation.
            cacheLock.lock()
            loadFailed[projectId] = true
            cacheLock.unlock()
            NSLog("[ClipSlots][canvas] 工作流事务恢复失败，保留原数据：\(ApplicationDiagnostics.error(error))")
            return .empty
        }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                loaded = try JSONDecoder().decode(CanvasDocument.self, from: data)
            } catch {
                // 损坏：旁置备份供人工恢复，随后按空画布继续。
                let corrupt = url.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: corrupt)
                try? FileManager.default.moveItem(at: url, to: corrupt)
                loaded = nil
                // ★ 记账。"文件存在但读不出来"与"文件不存在（新项目）"是两回事：后者的空画布是
                // 真实状态，前者的空画布是丢失 —— 而清扫私有槽位只能在真实状态上做。
                failed = true
                NSLog("[ClipSlots][canvas] 项目 \(projectId) 的画布文档损坏，已旁置 .corrupt 并按空画布继续")
            }
        }

        let result = loaded ?? .empty
        cacheLock.lock()
        // 双重检查：读盘期间可能已有别的线程填好缓存。
        if let cached = cache[projectId] {
            cacheLock.unlock()
            return cached
        }
        cache[projectId] = result
        loadFailed[projectId] = failed
        cacheLock.unlock()
        return result
    }

    // MARK: - 写

    /// 保存画布文档。返回是否成功落盘（内容无变化时也返回 true）。
    @discardableResult
    public func save(_ doc: CanvasDocument, projectId: String) -> Bool {
        var toWrite = doc
        toWrite.schemaVersion = CanvasDocument.currentSchemaVersion
        toWrite.updatedAt = Date()

        let url = fileURL(projectId: projectId)
        do {
            let data = try JSONEncoder().encode(toWrite)
            return try StorageLock.shared.withLock {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                       withIntermediateDirectories: true)
                // 写前比对：画布拖拽会高频触发保存，内容没变就不碰磁盘。
                if (try? Data(contentsOf: url)) != data {
                    try data.write(to: url, options: .atomic)
                }
                // 缓存只代表已落盘内容；失败不能解除加载失败保护或伪装成保存成功。
                cacheLock.lock()
                cache[projectId] = toWrite
                loadFailed[projectId] = false
                saveErrors.removeValue(forKey: projectId)
                cacheLock.unlock()
                return true
            }
        } catch {
            cacheLock.lock()
            saveErrors[projectId] = error.localizedDescription
            cacheLock.unlock()
            return false
        }
    }

    /// 丢弃内存缓存，下次 `load()` 重新读盘。
    public func invalidateCache() {
        cacheLock.lock()
        cache = [:]
        loadFailed = [:]
        cacheLock.unlock()
    }
}
