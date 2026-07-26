import Foundation
import AppKit

// v2.9.54: 自动下载并安装更新。
//
// 流程：
//   1. 用 URLSession 后台下载 DMG 到临时目录，实时更新进度条；
//   2. 支持「取消」中断下载；
//   3. 下载完成后用 NSWorkspace 打开 DMG，并弹窗提示用户将 ClipSlots.app 拖入
//      「应用程序」文件夹完成安装（标准 DMG 安装体验）。
//
// UI 用一个轻量 NSPanel（进度条 + 文案 + 取消按钮），不阻塞主窗口。
@MainActor
final class UpdateDownloader: NSObject {

    static let shared = UpdateDownloader()

    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    private var panel: NSPanel?
    private var progressBar: NSProgressIndicator?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?
    // v2.10.7: 面板底部按钮引用。下载阶段只显示「取消」；下载完成后 actionButton 显示为「安装并重启」。
    private var actionButton: NSButton?
    private var cancelButton: NSButton?

    private var version: String = ""

    // P2-17 (v2.10.9): 从 UpdateChecker 传入的期望下载字节数（Release asset 的 size）。
    // 下载完成后据此校验实际文件大小，>0 时才校验（缺失则跳过）。
    private var expectedSize: Int64 = 0

    // v2.10.7: 下载完成、等待安装的 DMG 本地路径。
    private var pendingInstallDMGPath: String?

    // P2-6 (v2.10.8): 是否正在执行「安装并重启」。安装启动后后台流程不可中途取消，
    // 此标记用于同时屏蔽「取消」按钮和标题栏关闭按钮(X)，避免点 X 关掉面板但后台
    // 安装仍在继续并最终 terminate 的语义混乱。
    private var isInstalling = false

    /// 开始下载指定 DMG。
    /// - Parameter expectedSize: P2-17 (v2.10.9) Release asset 的期望字节数（0 表示未知、跳过校验）。
    func startDownload(from url: URL, version: String, expectedSize: Int64 = 0) {
        // 若已有下载在进行，先取消旧的。
        cancel()
        self.version = version
        self.expectedSize = expectedSize

        presentPanel()

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
    }

    /// 取消下载并关闭进度窗口。
    func cancel() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        dismissPanel()
    }

    // MARK: - 进度窗口

    private func presentPanel() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 130))

        let title = NSTextField(labelWithString: "正在下载 v\(version)…")
        title.frame = NSRect(x: 20, y: 92, width: 340, height: 20)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        content.addSubview(title)
        self.titleLabel = title

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 66, width: 340, height: 16))
        bar.isIndeterminate = true
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        content.addSubview(bar)
        self.progressBar = bar

        let detail = NSTextField(labelWithString: "正在连接…")
        detail.frame = NSRect(x: 20, y: 44, width: 340, height: 18)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        content.addSubview(detail)
        self.detailLabel = detail

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(onCancelPressed))
        cancelButton.frame = NSRect(x: 280, y: 10, width: 80, height: 28)
        cancelButton.bezelStyle = .rounded
        content.addSubview(cancelButton)
        self.cancelButton = cancelButton

        // v2.10.7: 下载阶段隐藏；下载完成后显示为「安装并重启」，点击触发自动安装。
        let actionButton = NSButton(title: "安装并重启", target: self, action: #selector(onInstallPressed))
        actionButton.frame = NSRect(x: 168, y: 10, width: 104, height: 28)
        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r"
        actionButton.isHidden = true
        content.addSubview(actionButton)
        self.actionButton = actionButton

        let panel = NSPanel(contentRect: content.frame,
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.title = "ClipSlots 更新"
        panel.contentView = content
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // v2.9.54 fix: 我们自己用 self.panel 强持有该窗口，必须关闭「关闭即释放」，
        // 否则点击标题栏红色关闭按钮时 AppKit 会额外 release，导致 ARC 下过度释放而崩溃。
        panel.isReleasedWhenClosed = false
        // 让标题栏的关闭按钮与「取消」按钮行为一致：取消下载并清理窗口，
        // 避免用户点 X 后下载仍在后台继续、完成后突然弹出 DMG。
        panel.standardWindowButton(.closeButton)?.target = self
        panel.standardWindowButton(.closeButton)?.action = #selector(onCancelPressed)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    @objc private func onCancelPressed() {
        // P2-6 (v2.10.8): 安装阶段不可取消，X/取消一律忽略（安装流程会自行重启或报错）。
        if isInstalling { return }
        cancel()
    }

    private func dismissPanel() {
        panel?.orderOut(nil)
        panel = nil
        progressBar = nil
        titleLabel = nil
        detailLabel = nil
        actionButton = nil
        cancelButton = nil
    }

    private func updateProgress(_ fraction: Double, detail: String) {
        if let bar = progressBar {
            bar.isIndeterminate = false
            bar.doubleValue = fraction
        }
        detailLabel?.stringValue = detail
    }

    // MARK: - 完成 / 失败

    private func handleFinished(tempURL: URL) {
        // 把下载文件挪到一个带 .dmg 后缀的稳定临时路径，再用 Finder 打开。
        let fm = FileManager.default
        let dest = fm.temporaryDirectory.appendingPathComponent("ClipSlots-\(version).dmg")
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: tempURL, to: dest)
        } catch {
            handleFailure("移动下载文件失败：\(error.localizedDescription)")
            return
        }

        // P2-17 (v2.10.9): 校验下载文件字节数与 Release asset 声明的 size 是否一致。
        // 不一致说明下载被截断/不完整（或与服务端记录不符），此时明确报错并删除坏文件，
        // 绝不进入后续挂载 + ditto 安装流程，避免把损坏包装进 /Applications。
        if expectedSize > 0 {
            let attrs = try? fm.attributesOfItem(atPath: dest.path)
            let actualSize = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            if actualSize != expectedSize {
                try? fm.removeItem(at: dest)
                handleFailure("下载文件大小校验失败：期望 \(expectedSize) 字节，实际 \(actualSize) 字节。下载可能不完整，请重试。")
                return
            }
        }

        session?.finishTasksAndInvalidate()
        session = nil
        task = nil

        // v2.10.7: 下载完成后不再要求手动拖拽 DMG。切换面板为「安装就绪」，
        // 用户点击「安装并重启」即自动完成挂载 + ditto 替换 + 重启。
        pendingInstallDMGPath = dest.path
        presentInstallReady()
    }

    /// v2.10.7: 下载完成后把进度面板切换为「安装就绪」状态。
    private func presentInstallReady() {
        if panel == nil { presentPanel() }
        progressBar?.stopAnimation(nil)
        progressBar?.isIndeterminate = false
        progressBar?.doubleValue = 1.0
        titleLabel?.stringValue = "下载完成 v\(version)"
        detailLabel?.stringValue = "点击「安装并重启」自动完成更新，无需手动拖拽。"
        cancelButton?.title = "稍后"
        actionButton?.isHidden = false
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// v2.10.7: 点击「安装并重启」——静默自动安装。
    @objc private func onInstallPressed() {
        guard let dmgPath = pendingInstallDMGPath else { return }
        // P2-6 (v2.10.8): 进入不可取消的安装阶段，同时屏蔽标题栏关闭按钮(X)。
        isInstalling = true
        panel?.standardWindowButton(.closeButton)?.isEnabled = false
        titleLabel?.stringValue = "正在安装 v\(version)…"
        detailLabel?.stringValue = "正在替换应用程序，请稍候…"
        progressBar?.isIndeterminate = true
        progressBar?.startAnimation(nil)
        actionButton?.isEnabled = false
        cancelButton?.isEnabled = false

        UpdateInstaller.shared.install(
            dmgPath: dmgPath,
            version: version,
            progress: { [weak self] text in
                self?.detailLabel?.stringValue = text
            },
            failure: { [weak self] message in
                self?.handleInstallFailure(message, dmgPath: dmgPath)
            }
        )
        // 安装成功后 UpdateInstaller 会重启 App 并结束进程，无需成功回调。
    }

    /// v2.10.7: 自动安装失败——回退到手动安装（打开 DMG 让用户自行拖入）。
    private func handleInstallFailure(_ message: String, dmgPath: String) {
        // P2-6 (v2.10.8): 安装失败，退出安装态，恢复面板正常可关闭。
        isInstalling = false
        dismissPanel()
        let alert = NSAlert()
        alert.messageText = "自动安装失败"
        alert.informativeText = message + "\n\n可改用手动安装：打开磁盘映像后，将 ClipSlots.app 拖入「应用程序」文件夹。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "手动安装")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: dmgPath))
        }
    }

    private func handleFailure(_ message: String) {
        dismissPanel()
        let alert = NSAlert()
        alert.messageText = "下载失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好的")
        alert.runModal()
        session?.invalidateAndCancel()
        session = nil
        task = nil
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateDownloader: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite
        let fraction = expected > 0 ? Double(totalBytesWritten) / Double(expected) : 0
        let writtenMB = Double(totalBytesWritten) / 1_048_576.0
        let totalMB = Double(expected) / 1_048_576.0
        let detail: String
        if expected > 0 {
            detail = String(format: "%.1f MB / %.1f MB（%.0f%%）", writtenMB, totalMB, fraction * 100)
        } else {
            detail = String(format: "已下载 %.1f MB", writtenMB)
        }
        Task { @MainActor in
            self.updateProgress(fraction, detail: detail)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // location 在回调返回后会被删除，必须在此同步搬运到我们自己的临时文件。
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("clipslots-dl-\(UUID().uuidString).dmg")
        do {
            try fm.moveItem(at: location, to: staging)
        } catch {
            Task { @MainActor in
                self.handleFailure("保存下载文件失败：\(error.localizedDescription)")
            }
            return
        }
        Task { @MainActor in
            self.handleFinished(tempURL: staging)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error = error as NSError? else { return }
        // 用户主动取消不弹错误。
        if error.code == NSURLErrorCancelled { return }
        Task { @MainActor in
            self.handleFailure("网络错误：\(error.localizedDescription)")
        }
    }
}
