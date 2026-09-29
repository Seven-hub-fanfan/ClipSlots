import Foundation
import AppKit
import ClipSlotsKit

/// AVFoundation 不会把 .bin 自动识别成 MP4。使用保留原扩展名的临时软链接，
/// 原字节仍只在槽位存储中保留一份；退出进程时清理链接。
final class CanvasVideoAsset {
    static let shared = CanvasVideoAsset()
    private let lock = NSLock()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipslots-video-\(UUID().uuidString)", isDirectory: true)
    private var aliases: [String: URL] = [:]
    private var terminationObserver: NSObjectProtocol?

    private init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.directory)
        }
    }
    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        try? FileManager.default.removeItem(at: directory)
    }

    func url(for source: URL, fileName: String) -> URL {
        guard source.pathExtension.lowercased() == "bin",
              CanvasAttachmentKind.from(fileName: fileName) == .video else { return source }
        lock.lock()
        defer { lock.unlock() }
        let key = source.path + "|" + fileName
        if let alias = aliases[key] { return alias }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = (fileName as NSString).pathExtension.lowercased()
            let alias = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
            aliases[key] = alias
            return alias
        } catch { return source }
    }
}

extension SlotContent.SlotAttachment {
    var canvasPlaybackURL: URL? {
        canvasLocalURL.map { CanvasVideoAsset.shared.url(for: $0, fileName: name) }
    }
}
