import Foundation
import SwiftUI

// v2.10.10: 社区插件（第三方独立工具，如 Espanso / massCode / MonitorControl）的
// **真实**安装状态检测。
//
// 历史问题（v2.9.54）：安装状态靠 UserDefaults 标记——用户点一下「安装」（实际只是
// 打开官网）就被记为「已安装」，与磁盘上是否真的存在该 App 完全脱节，导致显示
// 「已安装」但其实没装。
//
// v2.10.10 修复：改为真实检测 `/Applications/<AppName>.app`（含 `~/Applications`）
// 是否存在（FileManager.fileExists），并对 `/Applications` 目录做 FSEvents 监听，
// 用户安装/卸载后界面状态自动实时刷新，不再依赖 UserDefaults。
@MainActor
final class CommunityPluginInstallStore: ObservableObject {

    // P2 (v2.10.13): 与 StorageDirectoryWatcher（v2.10.3）对齐——FSEvents 的 C 回调此前用
    // Unmanaged.passUnretained(self) 作为上下文，回调里 takeUnretainedValue()。若实例在回调
    // 仍在途时被释放，会解引用已释放的 self → 悬垂/野指针。改为传入 passRetained 的 WeakBox
    // （弱引用持有 self），回调检查 weak 是否已释放并安全 no-op；deinit 里在停止/失效 stream
    // 后再 release 该 box，避免残留回调解引用已释放的 box。
    private final class WeakBox {
        weak var store: CommunityPluginInstallStore?
        init(_ store: CommunityPluginInstallStore) { self.store = store }
    }

    /// 当前真实检测到「已安装」（App bundle 存在于磁盘）的社区插件 id 集合。
    @Published private(set) var installedIDs: Set<String>

    /// 扫描的应用目录：系统级 `/Applications` 与用户级 `~/Applications`。
    private let searchDirectories: [String]

    /// FSEvents 监听流（监听应用目录的增删）。
    private var eventStream: FSEventStreamRef?
    /// 持有传给 FSEvents 上下文的 WeakBox（passRetained）；在 deinit 停止 stream 后 release。
    private var boxRef: Unmanaged<WeakBox>?

    init() {
        var dirs = ["/Applications"]
        let userApps = (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        dirs.append(userApps)
        searchDirectories = dirs
        installedIDs = []
        installedIDs = Self.scan(searchDirectories: dirs)
        startMonitoring()
    }

    deinit {
        // FSEvents 清理不涉及主线程隔离状态，可安全在 deinit 内直接停止。
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        // P2 (v2.10.13): 在 stream 失效后再 release box，保证不会有残留回调解引用已释放的 box。
        boxRef?.release()
    }

    /// 该插件当前是否真实已安装（其对应 App bundle 存在于磁盘）。
    func isInstalled(_ id: String) -> Bool {
        installedIDs.contains(id)
    }

    /// 某插件对应 App 的实际磁盘路径（存在时返回，用于「打开」按钮）。
    func installedAppPath(for id: String) -> String? {
        guard let appName = Self.appName(for: id) else { return nil }
        for dir in searchDirectories {
            let path = (dir as NSString).appendingPathComponent(appName)
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// 重新扫描并刷新已安装集合（FSEvents 回调与手动触发共用）。
    func refresh() {
        let latest = Self.scan(searchDirectories: searchDirectories)
        if latest != installedIDs {
            installedIDs = latest
        }
    }

    // MARK: - 扫描

    /// 查表：插件 id → 对应 App bundle 名（来自 PluginCatalog）。
    private static func appName(for id: String) -> String? {
        PluginCatalog.allItems.first { $0.id == id }?.appName
    }

    /// 遍历目录检测所有声明了 appName 的社区插件是否安装。
    private static func scan(searchDirectories: [String]) -> Set<String> {
        var result = Set<String>()
        let fm = FileManager.default
        for item in PluginCatalog.allItems {
            guard let appName = item.appName else { continue }
            for dir in searchDirectories {
                let path = (dir as NSString).appendingPathComponent(appName)
                if fm.fileExists(atPath: path) {
                    result.insert(item.id)
                    break
                }
            }
        }
        return result
    }

    // MARK: - FSEvents 监听

    private func startMonitoring() {
        // P2 (v2.10.13): 用 passRetained 的 WeakBox 作为回调上下文（见类顶部说明），
        // 弱引用持有 self；回调固定投递到主队列后再检查 weak 是否已释放。
        let box = WeakBox(self)
        let boxRef = Unmanaged.passRetained(box)
        var context = FSEventStreamContext(
            version: 0,
            info: boxRef.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let box = Unmanaged<WeakBox>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                // 弱回引用：实例已释放则为 nil → 安全 no-op。
                guard let store = box.store else { return }
                store.refresh()
            }
        }

        let paths = searchDirectories as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // 0.5s 去抖延迟
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf)
        ) else {
            boxRef.release() // 平衡 passRetained（创建失败）
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        eventStream = stream
        self.boxRef = boxRef // 保活到 stream 生命周期结束（deinit release）
    }
}
