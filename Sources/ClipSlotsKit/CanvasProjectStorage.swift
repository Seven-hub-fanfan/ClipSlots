import Foundation

/// 项目索引的落盘存储（v2.13.0）。
///
/// 范式对齐 `CanvasStorage`：内存缓存 + `NSLock`、跨进程 `StorageLock` 保护落盘、`.atomic` 原子写、
/// 写前字节比对跳过无变化 IO。
///
/// 与画布文档的一处**关键差异**：画布文档坏了可以丢弃重建（派生资产），但项目索引坏了等于
/// **用户所有画布一起失踪** —— 画布文件还在盘上，只是没人知道它们的存在。所以这里解码失败时
/// 不走"丢弃重来"，而是**扫描 `projects/` 目录把孤儿项目捞回来**（见 `recovered`）。
public final class CanvasProjectStorage {

    public static let shared = CanvasProjectStorage()

    private let cacheLock = NSLock()
    private var cache: CanvasProjectIndex?

    private let rootOverride: URL?

    public init(rootOverride: URL? = nil) {
        self.rootOverride = rootOverride
    }

    private var canvasDir: URL {
        (rootOverride ?? ClipSlotsPaths.dataRoot).appendingPathComponent("canvas", isDirectory: true)
    }

    private var indexURL: URL {
        canvasDir.appendingPathComponent("projects.json")
    }

    /// 各项目画布文档的根目录。
    public var projectsDir: URL {
        canvasDir.appendingPathComponent("projects", isDirectory: true)
    }

    /// v2.12.x 及更早版本那份唯一的画布文档。
    private var legacyDocURL: URL {
        canvasDir.appendingPathComponent("canvas.json")
    }

    // MARK: - 读

    public func load() -> CanvasProjectIndex {
        cacheLock.lock()
        if let cached = cache {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var loaded: CanvasProjectIndex? = nil
        if FileManager.default.fileExists(atPath: indexURL.path) {
            if let data = try? Data(contentsOf: indexURL) {
                loaded = try? JSONDecoder().decode(CanvasProjectIndex.self, from: data)
            }
            if loaded == nil {
                // 索引损坏：旁置备份，然后从目录结构把项目捞回来。**不能**直接回落到
                // `.initial` —— 那会让用户 5 个项目变成 1 个空的，而画布文件全都还在盘上。
                let corrupt = indexURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: corrupt)
                try? FileManager.default.moveItem(at: indexURL, to: corrupt)
                loaded = recovered()
                NSLog("[ClipSlots][canvas] projects.json 损坏，已从目录结构恢复 \(loaded?.projects.count ?? 0) 个项目")
            }
        }

        let result = CanvasProjectIndex.normalized(loaded ?? migratedFromLegacy())
        cacheLock.lock()
        if let cached = cache {
            cacheLock.unlock()
            return cached
        }
        cache = result
        cacheLock.unlock()
        // 首次建立索引（升级 / 全新安装）立刻落盘，免得每次启动都重跑一遍迁移。
        if loaded == nil { _ = save(result) }
        return result
    }

    /// 没有索引时的初始状态：把 v2.12.x 那份唯一画布收成「默认项目」。
    ///
    /// 迁移用**拷贝**而不是移动：老文件留在原地当隐式备份。它只有几 KB，而"升级后画布空了"
    /// 是那种再也挽回不了用户信任的失败。
    private func migratedFromLegacy() -> CanvasProjectIndex {
        let index = CanvasProjectIndex.initial
        guard FileManager.default.fileExists(atPath: legacyDocURL.path) else { return index }
        let dest = docURL(projectId: CanvasProject.defaultId)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return index }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: legacyDocURL, to: dest)
            NSLog("[ClipSlots][canvas] 已把 v2.12 的单画布迁移成默认项目（原文件保留为备份）")
        } catch {
            NSLog("[ClipSlots][canvas] 迁移旧画布失败（按空画布继续）：\(error)")
        }
        return index
    }

    /// 索引丢了但画布文件还在时，从 `projects/<id>/canvas.json` 反推项目列表。
    ///
    /// 名字已经无从得知（名字只存在索引里），用 id 前 8 位凑一个可辨认的占位名，让用户至少能
    /// 打开画布看见自己的东西，然后自己改名。
    private func recovered() -> CanvasProjectIndex {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: projectsDir.path) else {
            return CanvasProjectIndex.initial
        }
        var projects: [CanvasProject] = []
        for id in ids.sorted() {
            guard !id.hasPrefix("."),
                  fm.fileExists(atPath: docURL(projectId: id).path) else { continue }
            let name = id == CanvasProject.defaultId
                ? CanvasProject.defaultName
                : "恢复的项目 \(id.prefix(8))"
            projects.append(CanvasProject(id: id, name: name))
        }
        guard !projects.isEmpty else { return CanvasProjectIndex.initial }
        return CanvasProjectIndex(projects: projects, activeProjectId: projects[0].id)
    }

    // MARK: - 写

    @discardableResult
    public func save(_ raw: CanvasProjectIndex) -> Bool {
        let index = CanvasProjectIndex.normalized(raw)
        cacheLock.lock()
        cache = index
        cacheLock.unlock()

        do {
            let data = try JSONEncoder().encode(index)
            return (try? StorageLock.shared.withLock {
                try FileManager.default.createDirectory(at: canvasDir, withIntermediateDirectories: true)
                if let old = try? Data(contentsOf: indexURL), old == data { return true }
                try data.write(to: indexURL, options: .atomic)
                return true
            }) ?? false
        } catch {
            return false
        }
    }

    public func invalidateCache() {
        cacheLock.lock()
        cache = nil
        cacheLock.unlock()
    }

    // MARK: - 路径

    /// 某个项目的画布文档路径。
    public func docURL(projectId: String) -> URL {
        projectsDir
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent("canvas.json")
    }

    /// 删项目时把它的画布文档目录移进 `.trash`（软删除，与槽位删组同一套语义）。
    ///
    /// 刻意不用 `removeItem`：项目里可能攒了几十个节点的布局，误删一次是不可逆的。
    /// 槽位内容那边由调用方负责删它的私有组（同样进 `.trash`）。
    @discardableResult
    public func trashProjectDocs(projectId: String) -> Bool {
        let fm = FileManager.default
        let dir = projectsDir.appendingPathComponent(projectId, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return true }
        let trash = canvasDir.appendingPathComponent(".trash", isDirectory: true)
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        var dest = trash.appendingPathComponent("\(projectId)-\(stamp)", isDirectory: true)
        var bump = 1
        while fm.fileExists(atPath: dest.path) {
            dest = trash.appendingPathComponent("\(projectId)-\(stamp)-\(bump)", isDirectory: true)
            bump += 1
        }
        do {
            try fm.moveItem(at: dir, to: dest)
            return true
        } catch {
            NSLog("[ClipSlots][canvas] 删项目时移动画布文档失败：\(error)")
            return false
        }
    }
}
