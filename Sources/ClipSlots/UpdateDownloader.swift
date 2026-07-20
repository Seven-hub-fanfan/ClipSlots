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

    private var version: String = ""

    /// 开始下载指定 DMG。
    func startDownload(from url: URL, version: String) {
        // 若已有下载在进行，先取消旧的。
        cancel()
        self.version = version

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
        cancel()
    }

    private func dismissPanel() {
        panel?.orderOut(nil)
        panel = nil
        progressBar = nil
        titleLabel = nil
        detailLabel = nil
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

        dismissPanel()
        NSWorkspace.shared.open(dest)

        let alert = NSAlert()
        alert.messageText = "下载完成"
        alert.informativeText = "ClipSlots \(version) 已下载并打开磁盘映像。\n\n请在弹出的窗口中，将 ClipSlots.app 拖入「应用程序」文件夹完成安装，然后重新启动应用。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()

        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
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
