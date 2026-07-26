import Foundation
import AppKit

// v2.10.7: App 内自动静默安装更新。
//
// 背景：此前更新完成后仍需用户手动把 ClipSlots.app 拖入「应用程序」，且会遭遇
// 「App 正在运行，无法替换」→ 点退出但被 modal sheet/alert 阻塞 → 弹窗被 Finder
// 遮住 → 卡死只能强退 的连锁问题。本类在下载完成后自动完成安装，全程无需拖拽：
//   1. 强制关闭所有阻塞弹窗（sheet / modal），保证后续 NSApp.terminate() 不被阻塞；
//   2. hdiutil attach 挂载 DMG；
//   3. ditto 替换 /Applications/ClipSlots.app（无权限时用 NSAppleScript 以管理员授权，
//      与 CLIInstallManager 的主线程 NSAppleScript 修法一致）；
//   4. hdiutil detach 卸载 DMG；
//   5. open 重启新版本 App 后 terminate 自身。
//
// 线程模型：整个安装流程（挂载、ditto、卸载）在后台串行队列执行，避免阻塞主线程；
// 仅 NSAppleScript（管理员授权）必须切回主线程（DispatchQueue.main.sync）。所有
// AppKit 访问（弹窗 dismiss / terminate / open）都在主线程执行。
final class UpdateInstaller {

    static let shared = UpdateInstaller()

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let queue = DispatchQueue(label: "com.clipslots.update-installer", qos: .userInitiated)

    /// 自动安装已下载的 DMG。成功后会重启 App 并结束当前进程；失败通过 `failure` 回调（主线程）。
    /// - Parameters:
    ///   - dmgPath: 已下载到本地的 DMG 路径
    ///   - version: 目标版本号（仅用于文案）
    ///   - progress: 安装进度文案回调（主线程）
    ///   - failure: 安装失败回调（主线程），携带可读错误信息
    func install(dmgPath: String,
                 version: String,
                 progress: @escaping (String) -> Void,
                 failure: @escaping (String) -> Void) {
        // 关键约束 1：安装前先强制 dismiss 所有 modal sheet / alert（主线程），
        // 否则残留弹窗会阻塞末尾的 NSApp.terminate()。
        Self.forceDismissBlockingModals()

        let appName = "ClipSlots.app"
        let targetApp = "/Applications/\(appName)"
        let mountPoint = NSTemporaryDirectory() + "clipslots-update-mnt-\(UUID().uuidString)"

        queue.async {
            // 2. 挂载 DMG。
            do {
                try Self.runProcess("/usr/bin/hdiutil",
                                    ["attach", dmgPath, "-nobrowse", "-quiet", "-mountpoint", mountPoint])
            } catch {
                DispatchQueue.main.async { failure("挂载磁盘映像失败：\(error.localizedDescription)") }
                return
            }

            // 挂载点内定位 .app（package_dmg.sh 固定把 ClipSlots.app 放在卷根）。
            let mountedApp = mountPoint + "/" + appName
            guard FileManager.default.fileExists(atPath: mountedApp) else {
                try? Self.runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet", "-force"])
                DispatchQueue.main.async { failure("磁盘映像中未找到 \(appName)") }
                return
            }

            DispatchQueue.main.async { progress("正在替换应用程序…") }

            // 3. ditto 替换。先尝试无鉴权（App 在用户可写目录时可行），失败再用管理员授权。
            var installError: String? = nil
            do {
                // 直接 ditto 覆盖到 /Applications。ditto 会原子替换目录内容。
                try Self.runProcess("/usr/bin/ditto", [mountedApp, targetApp])
            } catch {
                // 权限不足或目标被占用：用 NSAppleScript 以管理员权限执行（必须主线程）。
                let escapedMounted = Self.escapeForAppleScript(mountedApp)
                let escapedTarget = Self.escapeForAppleScript(targetApp)
                let shell = "rm -rf '\(escapedTarget)' && /usr/bin/ditto '\(escapedMounted)' '\(escapedTarget)'"
                let script = "do shell script \"\(Self.escapeForAppleScriptString(shell))\" with administrator privileges"

                // 关键约束 2：NSAppleScript 必须在主线程执行。
                DispatchQueue.main.sync {
                    var errInfo: NSDictionary?
                    if let apple = NSAppleScript(source: script) {
                        apple.executeAndReturnError(&errInfo)
                        if let errInfo = errInfo {
                            let msg = (errInfo[NSAppleScript.errorMessage] as? String) ?? "管理员授权安装失败"
                            installError = msg
                        }
                    } else {
                        installError = "无法创建安装脚本"
                    }
                }
            }

            // 4. 无论成败都卸载 DMG。
            try? Self.runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet", "-force"])

            if let installError = installError {
                DispatchQueue.main.async { failure("安装失败：\(installError)") }
                return
            }

            // 5. 重启新版本 App 后结束当前进程。
            DispatchQueue.main.async {
                let relaunch = "sleep 1 && open '\(targetApp)'"
                Process.launchedProcess(launchPath: "/bin/sh", arguments: ["-c", relaunch])
                // 再次强制关闭弹窗，确保 terminate 不被任何后弹出的 sheet 阻塞。
                Self.forceDismissBlockingModals()
                NSApp.terminate(nil)
            }
        }
    }

    /// 强制关闭所有 modal sheet / alert，避免阻塞 NSApp.terminate()。必须主线程调用。
    static func forceDismissBlockingModals() {
        let work = {
            for window in NSApp.windows {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                }
            }
            // 结束仍在运行的 modal 会话（NSAlert.runModal / runModal(for:) 等）。
            if NSApp.modalWindow != nil {
                NSApp.abortModal()
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    /// 同步执行子进程，非零退出码抛错并携带 stderr。
    private static func runProcess(_ launchPath: String, _ arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw InstallError(message: msg.isEmpty
                ? "\(launchPath) 退出码 \(task.terminationStatus)"
                : msg)
        }
    }

    /// 转义单引号，供 shell 单引号字符串内安全使用。
    private static func escapeForAppleScript(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// 转义 AppleScript 字符串字面量中的反斜杠与双引号。
    private static func escapeForAppleScriptString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
