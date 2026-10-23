import Foundation
import SwiftUI
import ClipSlotsKit

// v2.11.8: 插件市场条目的「最新版本 / 下载直链」运行时解析器。
//
// 解决的问题：插件条目里写死版本号和 DMG 直链，等于把「别的 App 什么时候发版」变成了
// ClipSlots 的发版事项 —— ScrollApp 出 2.2.4，ClipSlots 里的链接就成了过期指路牌。
//
// 三条设计约束：
//   1. **不能让点击等网络**。所以缓存写进 UserDefaults，市场一打开就先显示上次拿到的版本号，
//      同时在后台刷新；用户点「获取」时如果缓存还新鲜（10 分钟内）直接用，不再等一次 RTT。
//   2. **失败必须有出路**。GitHub 匿名 API 是每小时 60 次/IP，加上离线、限流、仓库改名，
//      失败是常态而不是异常。任何失败都降级到 Release 页面（用户自己点一下 assets 也能下到），
//      绝不弹错误框拦住人。
//   3. **失败不能变成刷屏**。限流下每次打开市场都重试只会把 60 次配额烧光，所以失败后
//      有 `failureBackoff` 冷却期。
@MainActor
final class GitHubReleaseWatcher: ObservableObject {

    /// 全局单例：插件市场是 popover，每次开关都会重建视图。若把状态挂在 @StateObject 上，
    /// 关掉再打开就丢掉了「正在加载」和内存态缓存，等于每次开都重新打一次 API。
    static let shared = GitHubReleaseWatcher()

    struct Entry: Equatable {
        var version: String?
        var dmgURL: URL?
        var fetchedAt: Date?
        var isResolving: Bool = false
        /// 最近一次失败时间，用于退避；成功后清空。
        var failedAt: Date?
    }

    /// 展示用缓存的新鲜度上限：超过就在后台刷新一次（仍先显示旧值）。
    private let displayTTL: TimeInterval = 6 * 3600
    /// 点击「获取」时可直接复用缓存直链的上限：更短，避免下到刚被替换掉的包。
    private let clickTTL: TimeInterval = 600
    /// 失败退避，防止限流时把配额打空。
    private let failureBackoff: TimeInterval = 120
    private let requestTimeout: TimeInterval = 8

    @Published private(set) var entries: [String: Entry] = [:]

    private let defaults = UserDefaults.standard
    private func cacheKey(_ repo: String) -> String { "plugin.release.cache.\(repo)" }

    private init() {}

    // MARK: - 读取（视图侧）

    func entry(for repo: String) -> Entry {
        if let e = entries[repo] { return e }
        let loaded = loadCache(repo)
        entries[repo] = loaded
        return loaded
    }

    /// 卡片/详情页展示的版本号。nil 表示还没拿到（视图显示「获取中…」）。
    func version(for repo: String) -> String? { entry(for: repo).version }

    func isResolving(_ repo: String) -> Bool { entry(for: repo).isResolving }

    // MARK: - 刷新

    /// 市场打开时调用：只刷新缓存过期（或从未拿到）的仓库。
    func refreshStale(repos: [String]) {
        for repo in Set(repos) {
            let e = entry(for: repo)
            if e.isResolving { continue }
            if let failedAt = e.failedAt, Date().timeIntervalSince(failedAt) < failureBackoff { continue }
            let age = e.fetchedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            guard age > displayTTL else { continue }
            Task { _ = await fetch(repo: repo) }
        }
    }

    /// 点「获取」时调用：返回一个**一定能打开**的 URL（直链优先，拿不到就 Release 页面）。
    func resolveDownloadURL(repo: String) async -> URL? {
        let cached = entry(for: repo)
        if let url = cached.dmgURL,
           let at = cached.fetchedAt,
           Date().timeIntervalSince(at) < clickTTL {
            return url
        }
        if let fresh = await fetch(repo: repo) { return fresh.dmgURL }
        return GitHubReleaseParser.latestReleasePageURL(repo: repo)
    }

    // MARK: - 网络

    @discardableResult
    private func fetch(repo: String) async -> GitHubLatestRelease? {
        guard let api = GitHubReleaseParser.latestReleaseAPIURL(repo: repo) else { return nil }
        var e = entry(for: repo)
        e.isResolving = true
        entries[repo] = e

        defer {
            var done = entry(for: repo)
            done.isResolving = false
            entries[repo] = done
        }

        var request = URLRequest(url: api)
        request.timeoutInterval = requestTimeout
        // GitHub 要求带 UA，匿名请求少了它会被 403。Accept 固定住 API 版本，避免将来响应形状漂移。
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ClipSlots/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let release = GitHubReleaseParser.parseLatest(data) else {
                markFailure(repo)
                return nil
            }
            var ok = entry(for: repo)
            ok.version = release.version
            ok.dmgURL = release.dmgURL
            ok.fetchedAt = Date()
            ok.failedAt = nil
            entries[repo] = ok
            saveCache(repo, version: release.version, dmgURL: release.dmgURL, fetchedAt: ok.fetchedAt!)
            return release
        } catch {
            markFailure(repo)
            return nil
        }
    }

    /// 失败只记时间，**不清掉旧缓存** —— 离线时继续显示上次拿到的版本号，比显示「获取中…」诚实。
    private func markFailure(_ repo: String) {
        var e = entry(for: repo)
        e.failedAt = Date()
        entries[repo] = e
    }

    // MARK: - 磁盘缓存

    private func loadCache(_ repo: String) -> Entry {
        guard let dict = defaults.dictionary(forKey: cacheKey(repo)) else { return Entry() }
        let version = dict["version"] as? String
        let url = (dict["dmgURL"] as? String).flatMap(URL.init(string:))
        let fetchedAt = (dict["fetchedAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        // 缓存里的直链也要过一遍 host 校验：UserDefaults 是用户可写的（`defaults write`），
        // 不校验就等于给「改一条本地配置 → ClipSlots 帮你打开任意下载链接」留了门。
        let trusted = url.flatMap { GitHubReleaseParser.isTrustedDownloadURL($0) ? $0 : nil }
        return Entry(version: version, dmgURL: trusted, fetchedAt: fetchedAt)
    }

    private func saveCache(_ repo: String, version: String, dmgURL: URL, fetchedAt: Date) {
        defaults.set(["version": version,
                      "dmgURL": dmgURL.absoluteString,
                      "fetchedAt": fetchedAt.timeIntervalSince1970],
                     forKey: cacheKey(repo))
    }
}
