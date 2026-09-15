import Foundation

// v2.11.8: GitHub「最新 Release」解析（插件市场的动态下载链接）。
//
// 背景：插件市场里的第三方/官方插件条目原本硬编码版本号和 DMG 直链，每次那个 App 发版
// 都要跟着改一次 ClipSlots 的源码并重新发版，否则用户点「获取」下到的是旧版。改为运行时
// 问 GitHub API 拿 latest release。
//
// 为什么解析逻辑放在 Kit 而不是 App 层：这段代码要做两件容易出错、且值得被测试钉死的事
// —— 从 assets 数组里挑对文件、以及**校验拿到的 URL 能不能直接丢给浏览器**。App 层只剩
// URLSession + 缓存 + @Published 这些没法在 smoke 里跑的部分。
//
// 安全立场：`browser_download_url` 是从网络响应里读出来、然后**不经用户确认就交给
// NSWorkspace.open** 的字符串。正常情况下它由 GitHub 生成，可信；但一旦仓库 slug 被写错
// 指向他人仓库、或响应被中间人改写，我们就成了「一键下载任意文件」的启动器。所以这里对
// scheme 和 host 都做白名单，宁可降级到 Release 页面让用户自己点。
public struct GitHubLatestRelease: Equatable, Sendable {
    /// 原始 tag，如 "v2.2.3"。
    public let tag: String
    /// 用于展示的版本号：去掉 tag 前导的 v/V，如 "2.2.3"。
    public let version: String
    /// DMG 资产的直链（浏览器打开即开始下载，不落在 Release 页面）。
    public let dmgURL: URL

    public init(tag: String, version: String, dmgURL: URL) {
        self.tag = tag
        self.version = version
        self.dmgURL = dmgURL
    }
}

public enum GitHubReleaseParser {

    /// 允许直接交给浏览器打开的下载 host。
    ///
    /// GitHub 的 asset 直链落在 github.com（会 302 到 objects.githubusercontent.com）。
    /// 白名单只放这两支及其子域，别的一律当不可信。
    public static let trustedDownloadHosts = ["github.com", "githubusercontent.com"]

    /// 解析 `GET /repos/{owner}/{repo}/releases/latest` 的响应。
    ///
    /// 返回 nil 的情形（调用方都应降级到 Release 页面，而不是把错误弹给用户）：
    /// 不是 JSON 对象、没有 tag_name、assets 里没有 .dmg、或 .dmg 的直链没通过 host 校验。
    public static func parseLatest(_ data: Data) -> GitHubLatestRelease? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let tag = (root["tag_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !tag.isEmpty else { return nil }
        guard let assets = root["assets"] as? [[String: Any]] else { return nil }

        // 多个 .dmg 时取**第一个**（GitHub 按上传顺序返回）。ScrollApp 这类单包发布不存在歧义；
        // 将来若有 arm64/x86 双包，这里要按本机架构挑，而不是继续拿第一个 —— 所以刻意不写
        // 「随便挑一个」的兜底逻辑，让需求出现时必须回来改这段。
        for asset in assets {
            guard let name = asset["name"] as? String,
                  name.lowercased().hasSuffix(".dmg"),
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString),
                  isTrustedDownloadURL(url) else { continue }
            return GitHubLatestRelease(tag: tag, version: displayVersion(fromTag: tag), dmgURL: url)
        }
        return nil
    }

    /// tag → 展示版本号："v2.2.3" → "2.2.3"；本来没有前缀就原样返回。
    public static func displayVersion(fromTag tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, first == "v" || first == "V" else { return t }
        return String(t.dropFirst())
    }

    /// 这条 URL 能不能不经用户确认就丢给浏览器。
    public static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return trustedDownloadHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 仓库 slug 必须是干净的 "owner/repo"。
    ///
    /// 它会被拼进 api.github.com 的路径，含 `..`、`/`、空格、query 片段的字符串会把请求打到
    /// 别的 endpoint 去（甚至逃出 /repos/ 前缀），所以在拼 URL 之前就卡掉。
    public static func isValidRepoSlug(_ slug: String) -> Bool {
        let parts = slug.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        for part in parts {
            guard !part.isEmpty, part != ".", part != "..", part.count <= 100 else { return false }
            guard part.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        }
        return true
    }

    /// latest release 的 API 地址。slug 非法时返回 nil。
    public static func latestReleaseAPIURL(repo: String) -> URL? {
        guard isValidRepoSlug(repo) else { return nil }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
    }

    /// 降级用的人类可读 Release 页面（API 挂了 / 限流 / 没有 dmg 时打开它）。
    public static func latestReleasePageURL(repo: String) -> URL? {
        guard isValidRepoSlug(repo) else { return nil }
        return URL(string: "https://github.com/\(repo)/releases/latest")
    }
}
