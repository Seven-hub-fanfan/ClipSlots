import Foundation
import SwiftUI

// v2.9.6: CLI install management from the Settings page.
//
// The `clipslots` CLI binary is bundled inside the app at
// `ClipSlots.app/Contents/MacOS/clipslots-cli`.
//
// ⚠️ Case-insensitive filesystem note: macOS APFS/HFS+ treats
// `clipslots` and `ClipSlots` as the SAME name, so we can NOT bundle the CLI
// as `Contents/MacOS/clipslots` (it would collide with / overwrite the GUI
// binary `Contents/MacOS/ClipSlots`). We therefore bundle it as
// `clipslots-cli` and expose it to the user as the command `clipslots` by
// symlinking `/usr/local/bin/clipslots` -> the bundled `clipslots-cli`.
@MainActor
final class CLIInstallManager: ObservableObject {

    /// User-facing command path (what agents / terminals invoke).
    static let targetPath = "/usr/local/bin/clipslots"

    enum InstallState: Equatable {
        case notInstalled
        case installed(version: String)      // installed & up to date
        case outdated(installed: String, bundled: String)
    }

    @Published private(set) var state: InstallState = .notInstalled
    @Published private(set) var isBusy = false
    @Published var lastMessage: String?
    @Published var lastMessageIsError = false

    // MARK: - Source resolution

    /// Absolute path of the CLI binary bundled inside the running app.
    private var bundledCLIPath: String? {
        let macos = (Bundle.main.bundlePath as NSString)
            .appendingPathComponent("Contents/MacOS")
        let candidate = (macos as NSString).appendingPathComponent("clipslots-cli")
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    // MARK: - Version helpers

    /// Run `<binary> version` and parse the JSON `{"ok":true,"version":"x"}`.
    /// `nonisolated static` so it can run off the main actor — `waitUntilExit()`
    /// must never block the main thread (v2.10.3 P1 fix: CLI startup can be slow
    /// under `flock` contention, which previously froze the Settings UI).
    nonisolated private static func binaryVersion(at path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = obj["version"] as? String
        else { return nil }
        return version
    }

    // MARK: - State refresh

    func refreshState() {
        let target = Self.targetPath
        guard FileManager.default.fileExists(atPath: target) else {
            state = .notInstalled
            return
        }
        // Resolve the bundled path on the main actor, then probe versions off-main
        // (each probe spawns a subprocess + waitUntilExit) and hop back to update UI.
        let bundledPath = bundledCLIPath
        DispatchQueue.global(qos: .userInitiated).async {
            let installed = Self.binaryVersion(at: target) ?? "未知"
            let bundled = bundledPath.flatMap { Self.binaryVersion(at: $0) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let bundled, bundled != installed {
                    self.state = .outdated(installed: installed, bundled: bundled)
                } else {
                    self.state = .installed(version: installed)
                }
            }
        }
    }

    // MARK: - Actions

    func install() {
        guard let source = bundledCLIPath else {
            report("找不到内置 CLI 二进制（clipslots-cli），请重新安装 App。", isError: true)
            return
        }
        // mkdir -p /usr/local/bin then symlink the bundled CLI as `clipslots`.
        let script = "mkdir -p /usr/local/bin && ln -sf \(shellQuote(source)) \(shellQuote(Self.targetPath))"
        // v2.9.26: 安装成功后，若 /usr/local/bin 不在 PATH 中，追加提示。
        var successMessage = "CLI 安装成功。"
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        if !path.contains("/usr/local/bin") {
            successMessage += "\n提示：请确认 /usr/local/bin 在您的 PATH 中，否则在终端输入 clipslots 可能找不到命令。"
        }
        runPrivileged(script, successMessage: successMessage)
    }

    func uninstall() {
        let script = "rm -f \(shellQuote(Self.targetPath))"
        runPrivileged(script, successMessage: "CLI 已卸载。")
    }

    // MARK: - Privileged execution (macOS auth dialog)

    private func runPrivileged(_ shellCommand: String, successMessage: String) {
        isBusy = true
        lastMessage = nil
        // Escape for embedding inside an AppleScript string literal.
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        // P0-2: NSAppleScript is not thread-safe — construct AND execute it on the
        // main thread. Previously this ran on a background queue, causing random crashes.
        DispatchQueue.main.async {
            // P2-7 (v2.10.5): NSAppleScript 的鉴权弹窗 + shell 执行会同步阻塞主线程，
            // 先前置的 isBusy 转圈来不及绘制。执行前显式驱动一次 runloop，让转圈状态
            // 有机会先画出来，缓解 UI 短时冻结的观感（非崩溃，纯手感优化）。
            RunLoop.current.run(until: Date())
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: appleScript)
            _ = script?.executeAndReturnError(&errorInfo)

            self.isBusy = false
            if let errorInfo {
                // -128 = user cancelled the authorization dialog.
                let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                if code == -128 {
                    self.report("已取消操作。", isError: false)
                } else {
                    let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "未知错误"
                    self.report("操作失败：\(msg)", isError: true)
                }
            } else {
                self.report(successMessage, isError: false)
            }
            self.refreshState()
        }
    }

    // MARK: - Utilities

    private func report(_ message: String, isError: Bool) {
        lastMessage = message
        lastMessageIsError = isError
    }

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
