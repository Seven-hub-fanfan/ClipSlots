import Foundation
import SwiftUI

// v2.9.54: 社区插件（第三方独立工具，如 Espanso / massCode / MonitorControl）的安装状态存储。
//
// 这三个是第三方独立应用，ClipSlots 无法真正安装/卸载它们，因此这里仅做「安装标记」管理：
//   - 「安装」= 打开其官网/GitHub 下载页（由调用方执行 NSWorkspace.shared.open）+ 标记为已安装；
//   - 「卸载」= 清除标记（不会真正卸载第三方工具本身，仅取消本地标记）。
//
// 标记持久化到 UserDefaults（单一 key 存一组已安装的插件 id），App 重启后保留。
@MainActor
final class CommunityPluginInstallStore: ObservableObject {

    /// UserDefaults 存储键（数组形式存已安装的插件 id）。
    private static let defaultsKey = "community_plugin_installed_ids_v1"

    /// 已标记为「已安装」的社区插件 id 集合。
    @Published private(set) var installedIDs: Set<String>

    private let defaults = UserDefaults.standard

    init() {
        let saved = defaults.array(forKey: Self.defaultsKey) as? [String] ?? []
        installedIDs = Set(saved)
    }

    /// 该插件当前是否被标记为已安装。
    func isInstalled(_ id: String) -> Bool {
        installedIDs.contains(id)
    }

    /// 标记为已安装并持久化（调用方负责打开下载页）。
    func markInstalled(_ id: String) {
        guard !installedIDs.contains(id) else { return }
        installedIDs.insert(id)
        persist()
    }

    /// 清除安装标记并持久化。
    func markUninstalled(_ id: String) {
        guard installedIDs.contains(id) else { return }
        installedIDs.remove(id)
        persist()
    }

    private func persist() {
        defaults.set(Array(installedIDs), forKey: Self.defaultsKey)
    }
}
