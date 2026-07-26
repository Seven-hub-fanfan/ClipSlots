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
            // P2-3 (v2.10.8): 挂载前先校验 DMG 完整性。`hdiutil verify` 校验映像内部
            // checksum，可拦截被截断/损坏/被篡改的下载包，避免把坏包安装进 /Applications。
            do {
                try Self.runProcess("/usr/bin/hdiutil", ["verify", dmgPath, "-quiet"], timeout: 120)
            } catch {
                DispatchQueue.main.async { failure("磁盘映像校验失败（可能下载损坏）：\(error.localizedDescription)") }
                return
            }

            // 2. 挂载 DMG。
            do {
                try Self.runProcess("/usr/bin/hdiutil",
                                    ["attach", dmgPath, "-nobrowse", "-quiet", "-mountpoint", mountPoint],
                                    timeout: 120)
            } catch {
                DispatchQueue.main.async { failure("挂载磁盘映像失败：\(error.localizedDescription)") }
                return
            }

            // 挂载点内定位 .app（package_dmg.sh 固定把 ClipSlots.app 放在卷根）。
            let mountedApp = mountPoint + "/" + appName
            guard FileManager.default.fileExists(atPath: mountedApp) else {
                try? Self.runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet", "-force"])
                // P2-2 (v2.10.8): detach 后清理挂载点空目录，避免每次更新泄漏一个。
                try? FileManager.default.removeItem(atPath: mountPoint)
                DispatchQueue.main.async { failure("磁盘映像中未找到 \(appName)") }
                return
            }

            DispatchQueue.main.async { progress("正在替换应用程序…") }

            // 3. 替换。先尝试无鉴权（App 在用户可写目录时可行），失败再用管理员授权。
            var installError: String? = nil
            do {
                // P1-1 (v2.10.8): 「先移除再拷贝」而非直接 `ditto 源 目标`。
                // `ditto 源 目标` 是把源内容「覆盖合并」进已存在的目标目录，不会删除新版本
                // 里已移除的旧文件（旧 dylib、被删/改名的 skill 资源、旧本地化文件等会残留），
                // 可能破坏 adhoc 签名或加载到过期资源，也可能因原地覆盖运行中 bundle 的
                // Mach-O 触发 Killed:9。故与管理员分支（rm -rf && ditto）对齐：先删旧 bundle，
                // 再整包 ditto，保证是「原子替换」语义而非合并。
                if FileManager.default.fileExists(atPath: targetApp) {
                    try FileManager.default.removeItem(atPath: targetApp)
                }
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

            // 4. 无论成败都卸载 DMG，并清理挂载点空目录（P2-2：避免每次更新泄漏一个）。
            try? Self.runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet", "-force"], timeout: 60)
            try? FileManager.default.removeItem(atPath: mountPoint)

            if let installError = installError {
                DispatchQueue.main.async { failure("安装失败：\(installError)") }
                return
            }

            // 5. 重启新版本 App 后结束当前进程。
            DispatchQueue.main.async {
                // P2-5 (v2.10.8): relaunch 时序加固。旧版用固定 `sleep 1` 猜测退出耗时，
                // 若本进程退出慢于 1s，open 会命中「App 仍在运行」而无法拉起新实例（甚至
                // 复用旧进程）。改为把当前 PID 传给分离出去的 shell，轮询等待旧进程真正
                // 退出后再 open，并加 10s 上限兜底，避免异常时永不重启。
                let pid = ProcessInfo.processInfo.processIdentifier
                let escapedTarget = Self.escapeForAppleScript(targetApp)
                let relaunch = "for i in $(seq 1 50); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done; "
                    + "open '\(escapedTarget)'"
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
            // P2-4 (v2.10.8): 覆盖「所有层级」的阻塞 modal，而非只处理一层。
            // 1. 递归结束每个窗口链上的 attachedSheet（sheet 可再挂 sheet）。
            for window in NSApp.windows {
                var host: NSWindow? = window
                var guardCount = 0
                while let h = host, let sheet = h.attachedSheet, guardCount < 16 {
                    h.endSheet(sheet)
                    host = sheet          // 继续向下检查该 sheet 自己挂的 sheet
                    guardCount += 1
                }
            }
            // 2. 循环退出仍在运行的嵌套 modal 会话（NSAlert.runModal / runModal(for:) 等
            //    可以层层嵌套），直到没有 modalWindow 或达到安全上限。
            var loops = 0
            while NSApp.modalWindow != nil && loops < 16 {
                NSApp.abortModal()
                loops += 1
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    /// 同步执行子进程，非零退出码抛错并携带 stderr。
    /// P2-1 (v2.10.8): 可选 `timeout`（秒）。hdiutil verify/attach/detach、ditto 在磁盘
    /// 或映像异常时可能长时间挂起，卡死后台安装队列且无取消入口。超时后强制 terminate
    /// 子进程并抛错，让上层回到失败路径（清理挂载点、提示用户），不再无限等待。
    private static func runProcess(_ launchPath: String, _ arguments: [String],
                                   timeout: TimeInterval? = nil) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        try task.run()

        if let timeout = timeout {
            let deadline = DispatchTime.now() + timeout
            let sema = DispatchSemaphore(value: 0)
            let watcher = DispatchQueue(label: "com.clipslots.update.proc-timeout")
            var timedOut = false
            watcher.async {
                if sema.wait(timeout: deadline) == .timedOut {
                    timedOut = true
                    if task.isRunning { task.terminate() }
                }
            }
            task.waitUntilExit()
            sema.signal()
            if timedOut {
                throw InstallError(message: "\(launchPath) 执行超时（>\(Int(timeout))s）已中止")
            }
        } else {
            task.waitUntilExit()
        }

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
