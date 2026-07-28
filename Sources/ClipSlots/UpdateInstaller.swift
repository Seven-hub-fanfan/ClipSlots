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

    // P1-3 (v2.10.9): 安装重入保护。install() 可能被重复触发（连点「安装并重启」、失败
    // 回调重入等），若后台安装流程并发跑会互相删除/替换 /Applications 里的 bundle，极其
    // 危险。用锁 + 标记保证同一时刻只有一个安装流程在进行。
    private let installLock = NSLock()
    private var isInstalling = false

    /// 自动安装已下载的 DMG。成功后会重启 App 并结束当前进程；失败通过 `failure` 回调（主线程）。
    /// - Parameters:
    ///   - dmgPath: 已下载到本地的 DMG 路径
    ///   - version: 目标版本号（用于进度文案；P2-8 (v2.10.16) 起还作为 ditto 前挂载 bundle 版本校验的预期值）
    ///   - progress: 安装进度文案回调（主线程）
    ///   - failure: 安装失败回调（主线程），携带可读错误信息
    func install(dmgPath: String,
                 version: String,
                 progress: @escaping (String) -> Void,
                 failure: @escaping (String) -> Void) {
        // 关键约束 1：安装前先强制 dismiss 所有 modal sheet / alert（主线程），
        // 否则残留弹窗会阻塞末尾的 NSApp.terminate()。
        Self.forceDismissBlockingModals()

        // P1-3 (v2.10.9): 重入保护。已有安装在进行时直接走失败回调返回，避免并发替换 bundle。
        installLock.lock()
        if isInstalling {
            installLock.unlock()
            DispatchQueue.main.async { failure("更新安装已在进行中") }
            return
        }
        isInstalling = true
        installLock.unlock()

        let appName = "ClipSlots.app"
        let targetApp = "/Applications/\(appName)"
        // UP-4 (v2.10.15): 用 FileManager.temporaryDirectory + appendingPathComponent 拼路径，
        // 避免直接字符串拼接 NSTemporaryDirectory()（可能缺/多尾部斜杠、含特殊字符）导致的脆弱路径。
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipslots-update-mnt-\(UUID().uuidString)").path

        // P1-3 (v2.10.9): 统一失败出口——先复位 isInstalling（加锁）再回调 failure，保证
        // 每条失败返回路径都能解除重入锁；成功路径会 terminate 进程，无需复位。
        let fail: (String) -> Void = { [weak self] message in
            if let self = self {
                self.installLock.lock()
                self.isInstalling = false
                self.installLock.unlock()
            }
            DispatchQueue.main.async { failure(message) }
        }

        queue.async {
            // P2-16 (v2.10.9): DMG 由 package_dmg.sh 以 UDZO(压缩) 格式生成并带内建 CRC 校验和。
            // `hdiutil verify` 只校验映像内部 checksum（完整性），并不校验签名/来源真实性——它
            // 无法「防中间人/MITM」（真正的防篡改依赖 HTTPS 下载 + P2-17 的下载大小校验 + 代码
            // 签名）。且 verify 对某些合法映像/环境可能过严而误报，若因此直接中止会挡掉正常更新。
            // 故改为非致命：verify 失败仅 NSLog 警告并继续，由 P2-17 的下载大小校验兜底。
            do {
                try Self.runProcess("/usr/bin/hdiutil", ["verify", dmgPath, "-quiet"], timeout: 120)
            } catch {
                NSLog("[ClipSlots] UpdateInstaller: hdiutil verify 未通过（非致命，继续安装）：\(error.localizedDescription)")
            }

            // 2. 挂载 DMG。
            do {
                try Self.runProcess("/usr/bin/hdiutil",
                                    ["attach", dmgPath, "-nobrowse", "-quiet", "-mountpoint", mountPoint],
                                    timeout: 120)
            } catch {
                // P2-18 (v2.10.9): attach 失败时清理可能残留的空挂载点目录（未挂载，删除安全），
                // 避免每次失败泄漏一个。
                try? FileManager.default.removeItem(atPath: mountPoint)
                fail("挂载磁盘映像失败：\(error.localizedDescription)")
                return
            }

            // 挂载点内定位 .app（package_dmg.sh 固定把 ClipSlots.app 放在卷根）。
            let mountedApp = mountPoint + "/" + appName
            guard FileManager.default.fileExists(atPath: mountedApp) else {
                // P1-2 (v2.10.9): 该 detach 补上 timeout: 60，与末尾 detach 一致，避免无超时挂起。
                // P2-18 (v2.10.9): 交由 detachAndCleanup 处理 detach 重试 + 仅在确认卸载后清理挂载点。
                Self.detachAndCleanup(mountPoint)
                fail("磁盘映像中未找到 \(appName)")
                return
            }

            DispatchQueue.main.async { progress("正在替换应用程序…") }

            // P2-8 (v2.10.16): ditto 替换前的第二道校验——核对挂载 bundle 的实际版本号是否等于预期 version。
            // 根因：install(dmgPath:version:...) 的 version 此前仅用于进度文案，ditto 无条件替换 DMG 根目录里
            // 的 ClipSlots.app，从不校验其 CFBundleShortVersionString，一旦下载/打包串包（版本不符）也会被静默
            // 安装。修复：在此（已挂载并定位到 mountedApp、ditto 之前）读取 mountedApp 的 Contents/Info.plist 的
            // CFBundleShortVersionString，与预期 version 规范化（去除可能的 "v/V" 前缀与首尾空白）后比对；不一致
            // （或读不到）则中止安装、detach 卸载 DMG，并走既有 fail 失败回调提示用户，绝不继续 ditto。
            // 本校验为纯文件读取，运行在既有后台串行队列（queue.async）中，不引入新线程，与线程模型一致。
            // P1-A (v2.10.17): 版本比对复用 UpdateChecker.parse() 的 SemVer 规范化，仅比较数字核心
            // （SemVer.core），剥离 `v/V` 前缀、`-` 预发布段与 `+` 构建元数据段。此前 normalizeVersion
            // 只去 `v` 前缀，不处理 `-beta.1` / `+build` 后缀，导致挂载 bundle 的数字版本 `2.11.0`
            // 与 tag_name 原值 `v2.11.0-beta.1` 恒不相等 → 误杀所有 beta 通道更新，且与 UpdateChecker
            // 「判定有新 beta 可更新」的逻辑自相矛盾。两处版本规范化就此收敛到同一 parse()，避免再次漂移。
            let normalizeCore: (String) -> [Int] = { raw in
                UpdateChecker.parse(raw).core
            }
            // 便于日志/文案展示的核心版本串（如 [2,11,0] → "2.11.0"）。
            let coreString: ([Int]) -> String = { $0.map(String.init).joined(separator: ".") }
            let mountedInfoPlist = mountedApp + "/Contents/Info.plist"
            guard let mountedVersion = NSDictionary(contentsOfFile: mountedInfoPlist)?["CFBundleShortVersionString"] as? String else {
                // 读不到版本号 → 无法通过第二道校验，按不一致处理：中止并卸载 DMG。
                NSLog("[ClipSlots] UpdateInstaller: 无法读取磁盘映像中 App 的 CFBundleShortVersionString，中止安装")
                Self.detachAndCleanup(mountPoint)
                fail("更新包版本不符，已中止安装（无法读取磁盘映像中 App 的版本号）")
                return
            }
            let mountedCore = normalizeCore(mountedVersion)
            let expectedCore = normalizeCore(version)
            guard mountedCore == expectedCore else {
                NSLog("[ClipSlots] UpdateInstaller: 版本校验失败，预期=\(version) 实际=\(mountedVersion)，中止安装")
                Self.detachAndCleanup(mountPoint)
                fail("更新包版本不符，已中止安装（预期 \(coreString(expectedCore))，实际 \(coreString(mountedCore))）")
                return
            }

            // 3. 替换。先尝试无鉴权（App 在用户可写目录时可行），失败再用管理员授权。
            var installError: String? = nil
            do {
                // P0 (v2.10.9): 原子替换 + 回滚，杜绝旧版「先 rm 目标再 ditto」在 ditto 失败时把
                // /Applications/ClipSlots.app 永久删除的致命风险。改为：先 ditto 到隐藏 staging，
                // 校验 staging 完整性，再用 replaceItemAt（原子）/moveItem 落到目标；任意步骤抛错
                // 都会移除 staging（原 App 原样保留）并转入管理员分支。
                let staging = "/Applications/.ClipSlots.app.new-\(UUID().uuidString)"
                // (1) ditto 到 staging，先清理可能残留的同名 staging。
                try? FileManager.default.removeItem(atPath: staging)
                try Self.runProcess("/usr/bin/ditto", [mountedApp, staging])
                // (2) 校验 staging 完整性：主可执行必须存在且可执行，否则移除 staging 并视为失败。
                guard FileManager.default.isExecutableFile(atPath: staging + "/Contents/MacOS/ClipSlots") else {
                    try? FileManager.default.removeItem(atPath: staging)
                    throw InstallError(message: "新版本完整性校验失败（主可执行缺失）")
                }
                // (3) 原子落地：目标存在用 replaceItemAt（原子替换），否则 moveItem。
                let stagingURL = URL(fileURLWithPath: staging)
                let targetURL = URL(fileURLWithPath: targetApp)
                if FileManager.default.fileExists(atPath: targetApp) {
                    _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: stagingURL)
                } else {
                    try FileManager.default.moveItem(at: stagingURL, to: targetURL)
                }
            } catch {
                // 任意失败：移除 staging（原 App 原样保留），转入管理员分支重试。
                // P0 (v2.10.9): 管理员分支同样用 staging + backup 做原子替换 + 回滚，永不让目标缺失。
                // 用 /bin/sh 脚本：ditto 到隐藏 staging → 校验 [ -x staging/主可执行 ] →（目标存在则）
                // mv 目标→backup → mv staging→目标；成功则 rm backup；最后一步 mv 失败则回滚
                // (mv backup→目标) 并 rm staging，非零退出。所有路径用 shellSingleQuoteEscape 转义。
                let adminStaging = "/Applications/.ClipSlots.app.new-\(UUID().uuidString)"
                let adminBackup = "/Applications/.ClipSlots.app.bak-\(UUID().uuidString)"
                let qMounted = Self.shellSingleQuoteEscape(mountedApp)
                let qTarget = Self.shellSingleQuoteEscape(targetApp)
                let qStaging = Self.shellSingleQuoteEscape(adminStaging)
                let qBackup = Self.shellSingleQuoteEscape(adminBackup)
                // UP-3 (v2.10.15): 用 trap ... EXIT 兜底清理 staging 临时目录。原脚本 set -e 下若中途
                // 某步失败会立即退出，跳过后续显式 rm，导致 staging 目录残留在 /Applications 下。改为
                // 先把 staging 路径存入 shell 变量 STAGING 并注册 EXIT trap，无论从哪条路径退出都会清理它。
                let shell = "STAGING='\(qStaging)'; "
                    + "trap 'rm -rf \"$STAGING\"' EXIT; "
                    + "set -e; "
                    + "rm -rf '\(qStaging)'; "
                    + "/usr/bin/ditto '\(qMounted)' '\(qStaging)'; "
                    + "[ -x '\(qStaging)/Contents/MacOS/ClipSlots' ] || { rm -rf '\(qStaging)'; exit 1; }; "
                    + "if [ -e '\(qTarget)' ]; then mv '\(qTarget)' '\(qBackup)'; fi; "
                    + "if mv '\(qStaging)' '\(qTarget)'; then rm -rf '\(qBackup)'; "
                    + "else if [ -e '\(qBackup)' ]; then mv '\(qBackup)' '\(qTarget)'; fi; rm -rf '\(qStaging)'; exit 1; fi"
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

            // 4. 无论成败都卸载 DMG，并在确认卸载后清理挂载点（P2-18：detach 重试 + 不误删已挂载卷）。
            Self.detachAndCleanup(mountPoint)

            if let installError = installError {
                fail("安装失败：\(installError)")
                return
            }

            // 5. 重启新版本 App 后结束当前进程。
            DispatchQueue.main.async {
                // v2.10.10: 更新替换 bundle 后 macOS 会把「辅助功能」授权与旧二进制解绑，
                // 新版本首次启动通常需要重新授权。置标记，供下次启动弹出「更新后重新授权」引导；
                // 同时在安装面板文案里提前告知用户「重启后请重新授权辅助功能」。
                UserDefaults.standard.set(true, forKey: UserPreferenceKeys.pendingAccessibilityReauthAfterUpdate)
                progress("更新完成，正在重启…（重启后如快捷键失效，请重新授权「辅助功能」）")
                NSLog("[UpdateInstaller] 安装完成，重启后请重新授权辅助功能（隐私与安全性 → 辅助功能）")

                // P2-5 (v2.10.8): relaunch 时序加固。旧版用固定 `sleep 1` 猜测退出耗时，
                // 若本进程退出慢于 1s，open 会命中「App 仍在运行」而无法拉起新实例（甚至
                // 复用旧进程）。改为把当前 PID 传给分离出去的 shell，轮询等待旧进程真正
                // 退出后再 open，并加 10s 上限兜底，避免异常时永不重启。
                let pid = ProcessInfo.processInfo.processIdentifier
                let escapedTarget = Self.shellSingleQuoteEscape(targetApp)
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
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        // P1-1 (v2.10.9): 并发抽干 stdout/stderr，修复子进程写入 >64KB 撑满 pipe 缓冲区后
        // 阻塞、而我们又在 waitUntilExit() 之后才读导致的死锁。两个 pipe 各自在后台队列
        // readDataToEndOfFile()，用 DispatchGroup 同步；错误信息只取 stderr，用 NSLock 保护
        // errData（stdout 读取后直接丢弃，仅为避免缓冲区写满阻塞）。
        let dataLock = NSLock()
        var errData = Data()
        let drainGroup = DispatchGroup()

        try task.run()

        drainGroup.enter()
        DispatchQueue.global().async {
            _ = outPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global().async {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            dataLock.lock(); errData = d; dataLock.unlock()
            drainGroup.leave()
        }

        if let timeout = timeout {
            let deadline = DispatchTime.now() + timeout
            let sema = DispatchSemaphore(value: 0)
            let watcher = DispatchQueue(label: "com.clipslots.update.proc-timeout")
            // P2-10 (v2.10.9): timedOut 跨线程读写（watcher 队列写、调用线程读），用 NSLock
            // 保护消除 data race。
            let timedOutLock = NSLock()
            var timedOut = false
            watcher.async {
                if sema.wait(timeout: deadline) == .timedOut {
                    timedOutLock.lock(); timedOut = true; timedOutLock.unlock()
                    if task.isRunning { task.terminate() }
                }
            }
            task.waitUntilExit()
            sema.signal()
            drainGroup.wait()
            timedOutLock.lock(); let didTimeOut = timedOut; timedOutLock.unlock()
            if didTimeOut {
                throw InstallError(message: "\(launchPath) 执行超时（>\(Int(timeout))s）已中止")
            }
        } else {
            task.waitUntilExit()
            drainGroup.wait()
        }

        if task.terminationStatus != 0 {
            dataLock.lock(); let data = errData; dataLock.unlock()
            let msg = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw InstallError(message: msg.isEmpty
                ? "\(launchPath) 退出码 \(task.terminationStatus)"
                : msg)
        }
    }

    /// P2-18 (v2.10.9): 卸载 DMG 并清理挂载点。detach 失败/超时时重试一次；只有在确认已
    /// 卸载（detach 成功）后才 removeItem 挂载点目录，避免对仍挂载的卷做 removeItem。
    private static func detachAndCleanup(_ mountPoint: String) {
        do {
            try runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet", "-force"], timeout: 60)
        } catch {
            NSLog("[ClipSlots] UpdateInstaller: detach 失败，重试一次：\(error.localizedDescription)")
            do {
                try runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet", "-force"], timeout: 60)
            } catch {
                // 仍失败：卷可能仍挂载，不再 removeItem（避免误删已挂载卷），仅记录日志留待系统清理。
                NSLog("[ClipSlots] UpdateInstaller: detach 重试仍失败，跳过挂载点清理：\(error.localizedDescription)")
                return
            }
        }
        // 已确认卸载，安全清理挂载点空目录。
        try? FileManager.default.removeItem(atPath: mountPoint)
    }

    /// P2-19 (v2.10.9): 由 escapeForAppleScript 更名而来——它实际做的是「shell 单引号转义」，
    /// 用于把路径安全嵌入 shell 单引号字符串（含 P0 管理员分支的 /bin/sh 脚本），与 AppleScript
    /// 无关。转义单引号供 shell 单引号字符串内安全使用。
    private static func shellSingleQuoteEscape(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// 转义 AppleScript 字符串字面量中的反斜杠与双引号。
    private static func escapeForAppleScriptString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
