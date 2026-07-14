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
    private func binaryVersion(at path: String) -> String? {
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

    private var bundledVersion: String? {
        guard let bundledCLIPath else { return nil }
        return binaryVersion(at: bundledCLIPath)
    }

    private var installedVersion: String? {
        binaryVersion(at: Self.targetPath)
    }

    // MARK: - State refresh

    func refreshState() {
        guard FileManager.default.fileExists(atPath: Self.targetPath) else {
            state = .notInstalled
            return
        }
        let installed = installedVersion ?? "未知"
        if let bundled = bundledVersion, bundled != installed {
            state = .outdated(installed: installed, bundled: bundled)
        } else {
            state = .installed(version: installed)
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
        runPrivileged(script, successMessage: "CLI 安装成功。")
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

        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: appleScript)
            _ = script?.executeAndReturnError(&errorInfo)

            DispatchQueue.main.async {
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
