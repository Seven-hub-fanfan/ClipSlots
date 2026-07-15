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

        var request = URLRequest(url: Self.latestAPI)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClipSlots-macOS", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false

                if let error = error {
                    self.presentError("网络请求失败：\(error.localizedDescription)")
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.presentError("无法解析服务器响应。")
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

                let latest = Self.normalize(rawTag)
                let current = Self.normalize(Self.currentVersion)
                let pageURL = (json["html_url"] as? String) ?? Self.releasesPage
                let notes = (json["body"] as? String) ?? ""

                if Self.compare(latest, isNewerThan: current) {
                    self.presentUpdateAvailable(latestTag: rawTag, pageURL: pageURL, notes: notes)
                } else {
                    self.presentUpToDate()
                }
            }
        }.resume()
    }

    // MARK: - Version helpers

    /// Strip a leading "v" and any pre-release suffix, keeping the numeric core.
    static func normalize(_ tag: String) -> [Int] {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Keep only the part before any "-" (pre-release) or "+" (build metadata).
        if let dashIdx = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            s = String(s[s.startIndex..<dashIdx])
        }
        return s.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Semantic-ish comparison: returns true if `a` represents a strictly newer version than `b`.
    static func compare(_ a: [Int], isNewerThan b: [Int]) -> Bool {
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    // MARK: - Alerts

    private func presentUpdateAvailable(latestTag: String, pageURL: String, notes: String) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(latestTag)"
        var info = "当前版本：v\(Self.currentVersion)\n最新版本：\(latestTag)"
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            let preview = trimmedNotes.count > 400 ? String(trimmedNotes.prefix(400)) + "…" : trimmedNotes
            info += "\n\n更新内容：\n\(preview)"
        }
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后再说")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let url = URL(string: pageURL) {
            NSWorkspace.shared.open(url)
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
}
