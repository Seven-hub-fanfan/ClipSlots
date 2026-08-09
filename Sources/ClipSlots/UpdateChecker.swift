import Foundation
import AppKit

// v2.9.8: "检查更新" entry.
// Calls the GitHub Releases "latest" API, compares the tag against the running
// version and shows a native alert. If a newer version exists, offers a
// "前往下载" button that opens the release page in the default browser.
@MainActor
final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    /// Current running app version. v2.9.9: dynamically read from Info.plist (CFBundleShortVersionString)
    /// via `AppVersion.current` — no longer hardcoded.
    static var currentVersion: String { AppVersion.current }

    private static let latestAPI = URL(string: "https://api.github.com/repos/Seven-hub-fanfan/ClipSlots/releases/latest")!
    private static let releasesPage = "https://github.com/Seven-hub-fanfan/ClipSlots/releases/latest"

    @Published private(set) var isChecking = false

    /// User-initiated check (always shows a result alert, including "已是最新版").
    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true

        // v2.10.12: 强制忽略本地缓存，避免 URLSession 复用磁盘里陈旧的失败响应
        // （如上一次的 403），导致每次检查都直接返回缓存而不再真正发网络请求。
        var request = URLRequest(url: Self.latestAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClipSlots-macOS", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                // P2 (v2.10.13): isChecking 之前在弹窗展示「之前」就被复位，用户快速连点
                // 「检查更新」会堆叠多次请求/弹窗。改为在整个结果处理（含同步 runModal 弹窗
                // 展示）结束后，通过 defer 统一复位——所有分支（error/403/最新/有更新）在
                // 弹窗关闭后才允许再次发起检查。
                defer { self.isChecking = false }

                if let error = error {
                    self.presentError("网络请求失败：\(error.localizedDescription)")
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.presentError("无法解析服务器响应。")
                    return
                }
                // v2.10.12: 单独处理 403，区分「频率限制」与「其他被拒绝」，并给出前往
                // GitHub Releases 页面手动下载的入口，避免用户被卡在 API 限流上。
                if http.statusCode == 403 {
                    let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
                    if remaining == "0" {
                        self.presentError403RateLimit()
                    } else {
                        self.presentError403Forbidden()
                    }
                    return
                }
                guard http.statusCode == 200, let data = data else {
                    self.presentError("检查更新失败（HTTP \(http.statusCode)）。请稍后重试。")
                    return
                }
                guard
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let rawTag = json["tag_name"] as? String
                else {
                    self.presentError("无法解析最新版本信息。")
                    return
                }

                let latest = Self.parse(rawTag)
                let current = Self.parse(Self.currentVersion)
                let pageURL = (json["html_url"] as? String) ?? Self.releasesPage
                let notes = (json["body"] as? String) ?? ""
                // v2.9.54: 解析 Release assets，取第一个 .dmg 的 browser_download_url 用于自动下载。
                // P2-17 (v2.10.9): 一并取回该 asset 的 size 用于下载后大小校验。
                // v2.10.67: 一并解析期望 SHA-256（asset digest 优先，回退 release body），
                // 用于下载完成后的加密级完整性校验（方案 A）。body 在此传入以支持回退解析。
                let dmgAsset = Self.extractDMGURL(from: json, body: notes)

                if Self.compare(latest, isNewerThan: current) {
                    self.presentUpdateAvailable(latestTag: rawTag, pageURL: pageURL, notes: notes, dmgAsset: dmgAsset)
                } else {
                    self.presentUpToDate()
                }
            }
        }.resume()
    }

    // MARK: - Version helpers

    /// Parsed semantic version: numeric core + optional pre-release identifier.
    /// P2 (v2.10.13): 之前 normalize 直接丢弃 `-beta` 预发布后缀，导致 `2.11.0-beta`
    /// 与 `2.11.0` 被判为相等（beta 用户收不到正式版更新）。改为保留预发布段并按
    /// SemVer 规则比较：数字核心相同时，正式版 > 预发布版。
    struct SemVer: Equatable {
        let core: [Int]
        let pre: String?   // nil = 正式版；非空 = 预发布标识（如 "beta.1"）
    }

    static func parse(_ tag: String) -> SemVer {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // build metadata（+ 之后）不参与比较，先剥离。
        if let plus = s.firstIndex(of: "+") { s = String(s[s.startIndex..<plus]) }
        var pre: String? = nil
        if let dash = s.firstIndex(of: "-") {
            let p = String(s[s.index(after: dash)...])
            pre = p.isEmpty ? nil : p
            s = String(s[s.startIndex..<dash])
        }
        let core = s.split(separator: ".").map { Int($0) ?? 0 }
        return SemVer(core: core, pre: pre)
    }

    /// Kept for backward compatibility; returns the numeric core only.
    static func normalize(_ tag: String) -> [Int] {
        parse(tag).core
    }

    /// Semantic comparison: returns true if `a` represents a strictly newer version than `b`.
    static func compare(_ a: SemVer, isNewerThan b: SemVer) -> Bool {
        let count = max(a.core.count, b.core.count)
        for i in 0..<count {
            let av = i < a.core.count ? a.core[i] : 0
            let bv = i < b.core.count ? b.core[i] : 0
            if av != bv { return av > bv }
        }
        // 数字核心相等：按 SemVer，正式版 > 预发布版。
        switch (a.pre, b.pre) {
        case (nil, nil): return false             // 完全相等
        case (nil, .some): return true            // a 是正式版，b 是预发布 → a 更新
        case (.some, nil): return false           // a 是预发布，b 是正式版 → a 不更新
        case let (.some(ap), .some(bp)):
            return ap.compare(bp, options: .numeric) == .orderedDescending
        }
    }

    // MARK: - Alerts

    /// v2.10.67: 承载单个可下载 DMG 资产的解析结果。
    /// 在 (url, size) 基础上新增可选 `sha256`（期望哈希，统一小写 hex，64 位；无则 nil），
    /// 由 `extractDMGURL` 一路透传到 `UpdateDownloader.startDownload` 做完整性校验。
    struct DMGAsset {
        let url: URL
        let size: Int64
        let sha256: String?
    }

    /// v2.9.54: 从 Release JSON 的 assets 中取第一个 .dmg 的 browser_download_url。
    /// P2-17 (v2.10.9): 同时返回该 asset 的 `size`（字节数），下游 UpdateDownloader 在下载
    /// 完成后据此校验下载文件大小，防止把被截断/不完整的包安装进 /Applications。
    /// v2.10.67: 额外解析期望 SHA-256（见 `extractExpectedSHA256`），下游据此做加密级完整性校验。
    static func extractDMGURL(from json: [String: Any], body: String) -> DMGAsset? {
        guard let assets = json["assets"] as? [[String: Any]] else { return nil }
        for asset in assets {
            if let name = asset["name"] as? String,
               name.lowercased().hasSuffix(".dmg"),
               let urlString = asset["browser_download_url"] as? String,
               let url = URL(string: urlString),
               // P2-3 (v2.10.8): 强制 HTTPS。自动下载后会挂载并 ditto 进 /Applications，
               // 明文 HTTP 存在中间人替换安装包的风险；非 https 一律拒绝（GitHub Release
               // 资产本就是 https，此处是纵深防御，防止异常/被篡改的 JSON 混入 http 链接）。
               url.scheme?.lowercased() == "https" {
                // size 可能是 Int / NSNumber，缺失时置 0（下游据 >0 判定是否校验）。
                let size = (asset["size"] as? NSNumber)?.int64Value ?? 0
                // v2.10.67: 期望 SHA-256——优先 asset digest，回退 release body。
                let sha256 = Self.extractExpectedSHA256(asset: asset, body: body)
                return DMGAsset(url: url, size: size, sha256: sha256)
            }
        }
        return nil
    }

    // MARK: - SHA-256 期望值解析（v2.10.67）

    /// 解析该 DMG asset 的期望 SHA-256，来源优先级：
    ///  ① asset 的 `digest` 字段（GitHub 原生返回，形如 `"sha256:<64位hex>"`）——去前缀取 hex；
    ///  ② 回退到 release `body` 中 "SHA256" 关键字附近的第一个 64 位十六进制串
    ///     （见 `extractSHA256FromBody`，用于兼容仅在正文写了哈希的 Release）。
    /// 统一返回小写 hex；解析失败返回 nil（下游据此走「宽松/强制」策略）。
    static func extractExpectedSHA256(asset: [String: Any], body: String) -> String? {
        // ① asset digest（大小写不敏感识别前缀）。
        if let digest = (asset["digest"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let lower = digest.lowercased()
            let prefix = "sha256:"
            if lower.hasPrefix(prefix) {
                let hex = String(lower.dropFirst(prefix.count))
                if isValidSHA256Hex(hex) { return hex }
            } else if isValidSHA256Hex(lower) {
                // 兜底：个别情况下 digest 可能不带前缀，只要是合法 64 位 hex 也接受。
                return lower
            }
        }
        // ② 回退到 release body 文本解析。
        return extractSHA256FromBody(body)
    }

    /// 从 release body 里解析期望 SHA-256：仅在包含 "sha256" 关键字（大小写不敏感）的行内
    /// 查找**独立的** 64 位十六进制串，避免误匹配 commit hash（40 位）或 SHA-512（128 位）等。
    /// 命中第一条即返回（小写 hex）；无匹配返回 nil。
    static func extractSHA256FromBody(_ body: String) -> String? {
        guard !body.isEmpty else { return nil }
        // 前后加“非 hex 字符”边界，防止把更长 hex 串（如 sha512 的 128 位）的前 64 位截出来。
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])"
        ) else { return nil }
        for rawLine in body.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            guard line.lowercased().contains("sha256") else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex.firstMatch(in: line, options: [], range: range),
               let r = Range(match.range, in: line) {
                return String(line[r]).lowercased()
            }
        }
        return nil
    }

    /// 校验字符串是否为合法的 64 位十六进制（SHA-256）表示。
    static func isValidSHA256Hex(_ s: String) -> Bool {
        return s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }

    private func presentUpdateAvailable(latestTag: String, pageURL: String, notes: String, dmgAsset: DMGAsset?) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(latestTag)"
        var info = "当前版本：v\(Self.currentVersion)\n最新版本：\(latestTag)"
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            let preview = trimmedNotes.count > 400 ? String(trimmedNotes.prefix(400)) + "…" : trimmedNotes
            info += "\n\n更新内容：\n\(preview)"
        }
        // v2.9.50: 说明 CLI 与 Agent Skill 会随 App 升级自动同步，无需重装。
        info += "\n\n更新 App 后，CLI 和 Agent Skill 会自动同步为新版，无需重新安装。"
        alert.informativeText = info
        alert.alertStyle = .informational

        // v2.9.54: 若能拿到 DMG 直链，提供「自动下载并安装」，无需手动去 GitHub。
        if let dmgAsset = dmgAsset {
            alert.addButton(withTitle: "自动下载并安装")
            alert.addButton(withTitle: "前往下载页")
            alert.addButton(withTitle: "稍后再说")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                // P2-17 (v2.10.9): 把期望大小一并传给下载器，下载完成后校验字节数。
                // v2.10.67: 同时传入期望 SHA-256，下载器据此做加密级完整性校验（方案 A）。
                UpdateDownloader.shared.startDownload(from: dmgAsset.url, version: latestTag, expectedSize: dmgAsset.size, expectedSHA256: dmgAsset.sha256)
            case .alertSecondButtonReturn:
                if let url = URL(string: pageURL) { NSWorkspace.shared.open(url) }
            default:
                break
            }
        } else {
            alert.addButton(withTitle: "前往下载")
            alert.addButton(withTitle: "稍后再说")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn, let url = URL(string: pageURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "当前版本 v\(Self.currentVersion) 已经是最新版，无需更新。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "检查更新失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    // v2.10.12: GitHub API 频率限制（X-RateLimit-Remaining == "0"）专用提示。
    private func presentError403RateLimit() {
        self.present403Alert(
            informativeText: "GitHub API 访问已达频率限制，请约 1 小时后再试。\n如需立即查看最新版本，可前往 GitHub Releases 页面。"
        )
    }

    // v2.10.12: 其他 403（非频率限制）专用提示。
    private func presentError403Forbidden() {
        self.present403Alert(
            informativeText: "访问被拒绝（HTTP 403），请检查网络后重试。\n也可前往 GitHub Releases 页面手动下载最新版本。"
        )
    }

    // v2.10.12: 403 弹窗共用逻辑，提供「查看 GitHub Releases」入口绕过 API 限流手动下载。
    private func present403Alert(informativeText: String) {
        let alert = NSAlert()
        alert.messageText = "检查更新失败"
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "查看 GitHub Releases")
        alert.addButton(withTitle: "好的")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: Self.releasesPage) {
            NSWorkspace.shared.open(url)
        }
    }
}
