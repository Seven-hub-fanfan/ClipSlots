import AppKit
import Foundation
import SwiftUI // AT-1 (v2.10.30): for the async InlineImageView below.
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
        // C-3 (v2.10.31): countLimit=64 alone let 64 decoded 8K images (~100MB+
        // each once decompressed) accumulate to multiple GB and OOM on
        // memory-constrained machines. Add a totalCostLimit sized in *decompressed*
        // bytes and pass a per-image cost at every setObject. 512MB is a sane cap:
        // it holds ~5 full-screen 8K images (8192×4320×4B ≈ 135MB) or many smaller
        // thumbnails while bounding worst-case resident memory. countLimit stays as
        // a secondary safety net for tiny-image floods.
        cache.countLimit = 64
        cache.totalCostLimit = 512 * 1024 * 1024 // 512 MB of decompressed pixels
        return cache
    }()

    // C-3 (v2.10.31): approximate decompressed byte cost of an NSImage, used as the
    // NSCache cost so totalCostLimit reflects real memory pressure (width × height ×
    // 4 bytes for RGBA). Falls back to a small non-zero cost when the size is unknown.
    private static func decompressedCost(of image: NSImage) -> Int {
        let size = image.size
        let cost = Int(size.width * size.height * 4)
        return cost > 0 ? cost : 1
    }

    /// Attempt to decode an NSImage from inline image data.
    ///
    /// NOTE: this remains a synchronous accessor because many callers across the
    /// app read it inline (search preview, radial preview, HUD, metadata, node
    /// card). After the first decode the result is cached, so repeat reads of the
    /// same content version are O(1). For the *first* decode of a huge image on
    /// the UI path, prefer the async `InlineImageView` (see AT-1 below) which
    /// warms this same cache off the main thread.
    var inlineImage: NSImage? {
        decodedInlineImage()
    }

    // AT-1 (v2.10.30): factored the actual decode out of the `inlineImage`
    // accessor so both the synchronous accessor and the async `InlineImageView`
    // share one implementation and one cache. Previously `inlineImage` decoded
    // the full-resolution `NSImage(data:)` synchronously on whatever thread read
    // it; because it is read inside SwiftUI view bodies, the first read of an 8K
    // screenshot blocked the main thread ~200-500ms while a preview opened.
    // `InlineImageView` now performs this decode on a background task and, on
    // completion, this cache is populated so later synchronous reads never
    // re-decode on the main thread.
    func decodedInlineImage() -> NSImage? {
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
                            // C-3 (v2.10.31): pass the decompressed-byte cost so the
                            // cache's totalCostLimit can evict large images correctly.
                            Self.inlineImageCache.setObject(image, forKey: cacheKey, cost: Self.decompressedCost(of: image))
                        }
                        return image
                    }
                }
            }
        }
        return nil
    }

    // AT-1 (v2.10.30): stable identity used as `.task(id:)` for `InlineImageView`
    // so the async decoder only re-runs when the underlying content version
    // changes (matches the `inlineImageCache` key shape).
    var inlineImageIdentity: String { "\(contentId)::\(updatedAt)" }

    // MARK: - File URL Detection

    // `primaryFileURL` / `fileDisplayName` moved to ClipSlotsKit
    // (SlotContent+FileDetection.swift) so the shared data layer can resolve
    // file URLs without importing AppKit/UI code.

    /// Image file extensions.
    private static let imageExtensions: Set<String> = SlotContent.imageFileExtensions

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

    // AT-2 (v2.10.30): process-wide cache of the computed summary string, keyed by
    // the same `contentId::updatedAt` identity as `inlineImageCache`. `metadataSummary`
    // is read inside `SlotCardView` / `SlotThumbnailView` / `SlotPreviewView` bodies;
    // for text (non-file) attachments it recursively `reduce`-summed every item's byte
    // count on *every* body evaluation, dropping frames while scrolling / switching
    // slots. Caching the finished string makes repeat reads O(1); an overwrite mints a
    // new identity and misses the cache, so the summary still refreshes correctly.
    private static let metadataSummaryCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 128
        return cache
    }()

    /// Summary string like "PNG · 512×512" or "PDF 文件".
    var metadataSummary: String {
        // AT-2 (v2.10.30): serve from cache when possible so the render loop never
        // re-traverses the item bytes.
        let cacheKey: NSString? = contentId.isEmpty ? nil : "\(contentId)::\(updatedAt)" as NSString
        if let cacheKey, let cached = Self.metadataSummaryCache.object(forKey: cacheKey) {
            return cached as String
        }
        let summary = computeMetadataSummary()
        if let cacheKey {
            Self.metadataSummaryCache.setObject(summary as NSString, forKey: cacheKey)
        }
        return summary
    }

    // AT-2 (v2.10.30): the original (uncached) summary computation, now invoked at
    // most once per content version.
    private func computeMetadataSummary() -> String {
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

// AT-1 (v2.10.30): async, off-main inline-image decoder view.
//
// Motivation: `SlotContent.inlineImage` is a synchronous computed property that
// runs `NSImage(data:)` on the full-resolution image. Because it is read inside
// SwiftUI view bodies, opening a preview for a huge image (e.g. an 8K screenshot)
// decoded on the main thread and froze the first frame for ~200-500ms.
//
// This view mirrors the existing async-thumbnail pattern (`AttachmentThumbnail`
// in AttachmentManagerPopover.swift): it renders `placeholder` immediately, then
// decodes on a background `Task.detached` and publishes the image when ready. The
// decode routes through `SlotContent.decodedInlineImage()`, which populates the
// shared `inlineImageCache`, so any subsequent *synchronous* `inlineImage` read of
// the same content version returns instantly without re-decoding on the main
// thread.
//
// Callers that currently read `content.inlineImage` directly inside a body (e.g.
// SlotThumbnailView, SlotPreviewView, RadialPreviewPanel, GlobalSearchResultsView)
// can adopt this view to move the first decode off-main. Those files are outside
// this change's edit scope; adopting them is a follow-up for the main agent.
struct InlineImageView<Placeholder: View>: View {
    let content: SlotContent
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: NSImage?

    init(content: SlotContent, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
            } else {
                placeholder()
            }
        }
        .task(id: content.inlineImageIdentity) {
            let snapshot = content
            let decoded = await Task.detached(priority: .userInitiated) {
                snapshot.decodedInlineImage()
            }.value
            if !Task.isCancelled { image = decoded }
        }
    }
}
