import Foundation
import PDFKit
import Darwin
import ImageIO
import AVFoundation
import AppKit

public enum AgentAttachmentImport {
    public static let maxBytes = 262_144
    public static let maxFiles = 6
    public static let maxImageBytes = 1_048_576
    public static let maxTotalImageBytes = 2_097_152
    private static let imageTypes = [
        "public.png": "image/png", "public.jpeg": "image/jpeg",
        "org.webmproject.webp": "image/webp", "com.compuserve.gif": "image/gif"
    ]

    /// Capture authorized file contents once. Queued turns and history never reread the source.
    public static func capture(_ url: URL) throws -> AgentAttachment {
        try capture(url, imageName: nil)
    }

    public static func captureImageFile(_ url: URL, name: String) throws -> AgentAttachment {
        try capture(url, imageName: name)
    }

    private static func capture(_ url: URL, imageName: String?) throws -> AgentAttachment {
        guard url.isFileURL else { throw ImportError.unsupported }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ImportError.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ImportError.unsupported }
        let isImage = imageName != nil || ["png", "jpg", "jpeg", "webp", "gif"].contains(url.pathExtension.lowercased())
        let isVideo = ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
        let limit = isImage ? maxImageBytes : (isVideo ? 24 * 1024 * 1024 : maxBytes)
        guard info.st_size <= limit else { throw ImportError.tooLarge }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw ImportError.unavailable }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw ImportError.tooLarge }
        }
        if isImage {
            return try captureImage(data, name: imageName ?? url.lastPathComponent)
        }
        if isVideo { return try captureVideo(data, name: url.lastPathComponent, extension: url.pathExtension) }
        let text: String
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(data: data), !document.isLocked,
                  document.pageCount <= 100 else { throw ImportError.unsupported }
            var extracted = ""
            for index in 0..<document.pageCount {
                extracted += "\n[页 \(index + 1)]\n" + (document.page(at: index)?.string ?? "")
                guard extracted.utf8.count <= maxBytes else { throw ImportError.tooLarge }
            }
            guard !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (0..<document.pageCount).contains(where: { !(document.page(at: $0)?.string ?? "").isEmpty })
            else { throw ImportError.noText }
            text = extracted
        } else {
            guard let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") else {
                throw ImportError.unsupported
            }
            text = decoded
        }
        return AgentAttachment(path: url.path, name: url.lastPathComponent,
                               textSnapshot: text, sha256: AgentDirectoryAccess.digest(data))
    }

    public static func captureImage(_ data: Data, name: String, path: String = "") throws -> AgentAttachment {
        guard data.count <= maxImageBytes else { throw ImportError.tooLarge }
        guard let mime = validatedImageMIME(data) else { throw ImportError.unsupported }
        return AgentAttachment(path: path, name: name, sha256: AgentDirectoryAccess.digest(data),
                               imageSnapshot: data, imageMIMEType: mime)
    }

    private static func captureVideo(_ data: Data, name: String, extension suffix: String) throws -> AgentAttachment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-video-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source").appendingPathExtension(suffix)
        try data.write(to: source, options: .atomic)
        let asset = AVURLAsset(url: source)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0, duration <= 120,
              !asset.tracks(withMediaType: .video).isEmpty else { throw ImportError.unsupported }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        var frames: [AgentAttachment] = [], timestamps: [String] = []
        for fraction in [0.0, 0.5, 0.9] {
            let image = try generator.copyCGImage(at: CMTime(seconds: duration * fraction, preferredTimescale: 600),
                                                actualTime: nil)
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
                throw ImportError.unsupported
            }
            let timestamp = String(format: "%.2f", duration * fraction)
            frames.append(try captureImage(jpeg, name: "\(name) · \(timestamp)s"))
            timestamps.append(timestamp)
        }
        try validate(frames)
        return AgentAttachment(path: "", name: name,
            textSnapshot: "视频 \(name)，时长 \(String(format: "%.2f", duration)) 秒。仅提供 \(timestamps.joined(separator: "、")) 秒的三张静态抽帧；未读取音轨、未分析帧间动作，其余画面未知。",
            sha256: AgentDirectoryAccess.digest(data), sampledFrames: frames)
    }

    public static func validate(_ files: [AgentAttachment]) throws {
        let frames = files.flatMap { $0.sampledFrames ?? [] }
        guard frames.allSatisfy({ $0.sampledFrames == nil && $0.imageSnapshot != nil }),
              frames.count <= 18 else { throw ImportError.unsupported }
        guard files.count <= maxFiles,
              files.reduce(0, { $0 + ($1.textSnapshot?.utf8.count ?? 0) }) <= maxBytes,
              (files + frames).reduce(0, { $0 + ($1.imageSnapshot?.count ?? 0) }) <= maxTotalImageBytes else {
            throw ImportError.tooLarge
        }
        for file in files + frames {
            guard file.sha256 != nil else { throw ImportError.unavailable }
            if let image = file.imageSnapshot {
                guard file.textSnapshot == nil, image.count <= maxImageBytes,
                      validatedImageMIME(image) == file.imageMIMEType,
                      AgentDirectoryAccess.digest(image) == file.sha256 else { throw ImportError.unsupported }
            } else if file.textSnapshot == nil { throw ImportError.unavailable }
        }
    }

    public static func validateImageSupport(history: [AgentMessage], supported: Bool) throws {
        let files = history.filter(\.isWireVisible).flatMap(\.inputAttachments)
        if files.contains(where: { $0.imageSnapshot != nil }) && !supported { throw ImportError.imageUnsupported }
        for message in history where message.isWireVisible {
            try validate(message.inputAttachments.filter { $0.imageSnapshot != nil })
        }
    }

    private static func validatedImageMIME(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, let mime = imageTypes[type],
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = props[kCGImagePropertyPixelWidth as String] as? Int,
              let height = props[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 25_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
        return mime
    }

    public enum ImportError: LocalizedError {
        case unavailable, unsupported, tooLarge, noText, imageUnsupported
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "附件内容不可读取，请重新添加文件。"
            case .unsupported: return "支持 UTF-8 文本、含文字 PDF、静态 PNG/JPEG/WebP/GIF，以及 120 秒内可解码的 MP4/MOV/M4V（三张抽帧，无音轨）。"
            case .tooLarge: return "每轮最多 6 个附件、256 KB 文字；图片每张 1 MB、合计 2 MB；视频源文件最多 24 MB。"
            case .noText: return "此 PDF 没有可提取文字，请先转换为文本。"
            case .imageUnsupported: return "当前服务未明确声明此模型支持图片，请查询模型列表并选择支持图像的模型；Tika 暂不支持图片输入。"
            }
        }
    }
}
