import Foundation

/// 画布文档的落盘存储（v2.11.7）。
///
/// 范式对齐 `SlotConnectionStorage`：内存缓存 + `NSLock`、跨进程 `StorageLock` 保护落盘、
/// `.atomic` 原子写、写前字节比对跳过无变化 IO、损坏文件旁置 `.corrupt` 备份。
///
/// 与槽位数据的一处**刻意差异**：画布是派生资产（节点可重建、产物另存），所以解码失败时
/// 直接返回 `.empty` 让用户从空画布重来，而不是像槽位那样层层设防。把 `.corrupt` 留在盘上
/// 是为了事后能捞，但不因此阻塞进入画布。
public final class CanvasStorage {

    public static let shared = CanvasStorage()

    private let cacheLock = NSLock()
    private var cache: CanvasDocument?

    /// 覆盖数据目录，仅供测试使用。
    private let rootOverride: URL?

    public init(rootOverride: URL? = nil) {
        self.rootOverride = rootOverride
    }

    private var canvasDir: URL {
        (rootOverride ?? ClipSlotsPaths.dataRoot).appendingPathComponent("canvas", isDirectory: true)
    }

    private var fileURL: URL {
        canvasDir.appendingPathComponent("canvas.json")
    }

    // MARK: - 读

    /// 读取画布文档。缓存命中直接返回；未命中读盘（**不持 cacheLock 做 IO**，避免同步磁盘
    /// 读阻塞其他线程 —— 这是 P2-2 在连线存储上踩过的坑）。
    public func load() -> CanvasDocument {
        cacheLock.lock()
        if let cached = cache {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let url = fileURL
        var loaded: CanvasDocument? = nil
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
            }
        }

        let result = loaded ?? .empty
        cacheLock.lock()
        // 双重检查：读盘期间可能已有别的线程填好缓存。
        if let cached = cache {
            cacheLock.unlock()
            return cached
        }
        cache = result
        cacheLock.unlock()
        return result
    }

    // MARK: - 写

    /// 保存画布文档。返回是否成功落盘（内容无变化时也返回 true）。
    @discardableResult
    public func save(_ doc: CanvasDocument) -> Bool {
        var toWrite = doc
        toWrite.schemaVersion = CanvasDocument.currentSchemaVersion
        toWrite.updatedAt = Date()

        cacheLock.lock()
        cache = toWrite
        cacheLock.unlock()

        let url = fileURL
        do {
            let data = try JSONEncoder().encode(toWrite)
            return (try? StorageLock.shared.withLock {
                try FileManager.default.createDirectory(at: canvasDir, withIntermediateDirectories: true)
                // 写前比对：画布拖拽会高频触发保存，内容没变就不碰磁盘。
                if let old = try? Data(contentsOf: url), old == data { return true }
                try data.write(to: url, options: .atomic)
                return true
            }) ?? false
        } catch {
            return false
        }
    }

    /// 丢弃内存缓存，下次 `load()` 重新读盘。
    public func invalidateCache() {
        cacheLock.lock()
        cache = nil
        cacheLock.unlock()
    }
}
