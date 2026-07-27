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
        // P2-12 (v2.10.9): 软链损坏——/usr/local/bin/clipslots 是符号链接但其目标已不存在
        // （例如旧 App 被删/移动）。FileManager.fileExists 会跟随符号链接把它误判为「未安装」，
        // 掩盖了「命令存在但指向失效」的真实故障，故单列此状态并在 UI 显式提示。
        case broken
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
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // P1-1 (v2.10.9): 并发抽干 stdout/stderr，修复子进程输出 >64KB 撑满 pipe 缓冲区后
        // 阻塞、而旧代码在 waitUntilExit() 之后才 readDataToEndOfFile（且 stderr 从不读取）
        // 导致的死锁。两个 pipe 各自在后台队列读取，用 DispatchGroup 同步；共享 Data 用 NSLock 保护。
        let dataLock = NSLock()
        var outData = Data()
        let drainGroup = DispatchGroup()

        do {
            try process.run()
        } catch {
            return nil
        }

        drainGroup.enter()
        DispatchQueue.global().async {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            dataLock.lock(); outData = d; dataLock.unlock()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global().async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        process.waitUntilExit()
        drainGroup.wait()

        dataLock.lock(); let data = outData; dataLock.unlock()
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = obj["version"] as? String
        else { return nil }
        return version
    }

    // MARK: - State refresh

    func refreshState() {
        let target = Self.targetPath
        let fm = FileManager.default
        // P2-12 (v2.10.9): 用 attributesOfItem（等价 lstat，不跟随符号链接）判断链接本身，
        // 区分「未安装」与「软链损坏（是符号链接但目标已不存在）」。旧代码直接用
        // FileManager.fileExists（跟随符号链接），会把 dangling symlink 误判为 .notInstalled。
        let linkAttrs = try? fm.attributesOfItem(atPath: target)
        let isSymlink = (linkAttrs?[.type] as? FileAttributeType) == .typeSymbolicLink
        // fileExists 跟随符号链接：目标存在 → true；目标缺失（dangling）→ false。
        let targetResolves = fm.fileExists(atPath: target)

        if isSymlink && !targetResolves {
            state = .broken
            return
        }
        guard targetResolves else {
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
        // P2-11 (v2.10.9): `ln -sf` 缺少 -n/-h：当 /usr/local/bin/clipslots 已是指向某个
        // 真实存在目录的符号链接时，ln 会把新链接创建到那个目录「内部」（生成
        // /usr/local/bin/clipslots/clipslots），而非替换该链接本身。加 -n（等价 -h，不跟随
        // 已存在的符号链接目标）确保始终原子替换链接本身。
        let script = "mkdir -p /usr/local/bin && ln -sfn \(shellQuote(source)) \(shellQuote(Self.targetPath))"
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

        // AU-1 (v2.10.15): `executeAndReturnError` 会同步阻塞当前线程（鉴权弹窗 + shell 执行），
        // 之前放在 DispatchQueue.main.async 里仍旧冻结主线程，安装/卸载期间 UI 无响应。
        // 改为在后台队列构造并执行 AppleScript（NSAppleScript 对象保持在闭包内局部、不跨线程），
        // 执行完再回到主线程更新所有 @Published/UI 状态。
        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: appleScript)
            _ = script?.executeAndReturnError(&errorInfo)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
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
