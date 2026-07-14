import AppKit
import Foundation
import ClipSlotsKit

extension SlotContent {

    // MARK: - Image Detection

    /// All image-related pasteboard types found in this content.
    private var imageTypes: [String] {
        let imageTypePatterns = ["public.png", "public.tiff", "public.jpeg", "public.image",
                                 "com.apple.icns", "com.compuserve.gif", "public.heic",
                                 "public.heif", "public.avci", "public.webp", "org.webmproject.webp"]
        var found: Set<String> = []
        for itemList in items {
            for item in itemList {
                let lower = item.type.lowercased()
                for pattern in imageTypePatterns {
                    if lower == pattern || lower.contains("image") {
                        found.insert(item.type)
                    }
                }
            }
        }
        return Array(found)
    }

    /// True if this content contains any image data.
    var hasImage: Bool {
        !imageTypes.isEmpty
    }

    /// Process-wide cache of decoded inline images, keyed by `contentId::updatedAt`.
    /// v2.8.0 (perf H1): `inlineImage` was previously re-decoding the raw image
    /// data via `NSImage(data:)` on *every* access. Because this property is read
    /// inside SwiftUI View bodies (search preview, radial preview, HUD, metadata),
    /// the original full-resolution image was decoded on the main thread on every
    /// re-render. Decoding once per content version and caching the result removes
    /// that repeated main-thread work. Keyed by the stable content identity so an
    /// overwrite (new contentId/updatedAt) still misses the cache.
    private static let inlineImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    /// Attempt to decode an NSImage from inline image data.
    var inlineImage: NSImage? {
        let cacheKey: NSString? = contentId.isEmpty ? nil : "\(contentId)::\(updatedAt)" as NSString
        if let cacheKey, let cached = Self.inlineImageCache.object(forKey: cacheKey) {
            return cached
        }
        for itemList in items {
            for item in itemList {
                let lower = item.type.lowercased()
                if lower.contains("image") || lower == "public.png" || lower == "public.tiff" || lower == "public.jpeg" {
                    if let image = NSImage(data: item.data) {
                        if let cacheKey {
                            Self.inlineImageCache.setObject(image, forKey: cacheKey)
                        }
                        return image
                    }
                }
            }
        }
        return nil
    }

    // MARK: - File URL Detection

    // `primaryFileURL` / `fileDisplayName` moved to ClipSlotsKit
    // (SlotContent+FileDetection.swift) so the shared data layer can resolve
    // file URLs without importing AppKit/UI code.

    /// Image file extensions.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "webp", "bmp",
        "heic", "heif", "tiff", "tif", "ico", "icns", "avif"
    ]

    /// True if the file URL points to an image file (by extension).
    var isImageFile: Bool {
        guard let url = primaryFileURL else { return false }
        return Self.imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// True if this is a file reference (not inline data).
    var isFileContent: Bool {
        primaryFileURL != nil
    }

    // MARK: - Video Detection

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "wmv"
    ]

    var isVideoFile: Bool {
        guard let url = primaryFileURL else { return false }
        return Self.videoExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Display Kind

    enum SlotDisplayKind {
        case image
        case video
        case file
        case text
        case empty
    }

    var displayKind: SlotDisplayKind {
        if hasImage || isImageFile { return .image }
        if isVideoFile { return .video }
        if isFileContent { return .file }
        if !preview.isEmpty && preview != "(空)" { return .text }
        return .empty
    }

    // MARK: - Suggested Label

    /// Suggest a label based on content: file name without extension, or timestamp for images.
    var suggestedLabel: String? {
        if let url = primaryFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        if hasImage {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            return "图片 \(formatter.string(from: Date()))"
        }
        return nil
    }

    // MARK: - Metadata

    /// Summary string like "PNG · 512×512" or "PDF 文件".
    var metadataSummary: String {
        if let image = inlineImage {
            let size = image.size
            let w = Int(size.width)
            let h = Int(size.height)
            let typeName = imageTypes.first?.replacingOccurrences(of: "public.", with: "").uppercased() ?? "IMG"
            return "\(typeName) · \(w)×\(h)"
        }
        if let url = primaryFileURL {
            let ext = url.pathExtension.uppercased()
            if ext.isEmpty { return "文件" }
            if isVideoFile { return "\(ext) 视频" }
            return "\(ext) 文件"
        }
        if !preview.isEmpty {
            let charCount = items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } }
            if charCount < 1024 { return "\(charCount) B 文本" }
            if charCount < 1024 * 1024 { return "\(charCount / 1024) KB 文本" }
            return "文本"
        }
        return ""
    }

    /// True if this content can show a visual preview.
    var canPreview: Bool {
        displayKind == .image || displayKind == .video || displayKind == .file
    }
}
