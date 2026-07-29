import AppKit
import Foundation
import SwiftUI // AT-1 (v2.10.30): for the async InlineImageView below.
import ImageIO // ATT-1/ATT-2/UI-1 (v2.10.32): CGImageSource-based downsample & pixel probe.
import CoreGraphics
import ClipSlotsKit

// MARK: - Shared ImageIO helpers (v2.10.32)

// ATT-1/ATT-2/ATT-3/UI-1 (v2.10.32): a small, reusable ImageIO toolbox shared by
// every image call site (grid thumbnail, inline/hover/radial preview, HUD notice,
// attachment panel). It produces *downsampled* NSImages bounded by a max pixel edge
// and probes pixel/point dimensions from the image header WITHOUT decoding the full
// bitmap. This is the generalization of the previous C-1/C-3/C-5 fixes that only
// touched the attachment panel.
enum ClipSlotsImageIO {

    // Downsample options: cap the longest edge and force generation from the main
    // image (so files without an embedded thumbnail still work). ImageIO decodes
    // incrementally, so the full-resolution bitmap never lands in memory.
    private static func thumbnailOptions(maxPixel: CGFloat) -> CFDictionary {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixel.rounded()))
        ] as CFDictionary
    }

    private static func downsampled(source: CGImageSource, maxPixel: CGFloat) -> NSImage? {
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(maxPixel: maxPixel)) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Downsampled NSImage from raw image data, longest edge ≤ maxPixel.
    static func downsampledImage(data: Data, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsampled(source: source, maxPixel: maxPixel)
    }

    /// Downsampled NSImage from a file URL, longest edge ≤ maxPixel.
    static func downsampledImage(url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return downsampled(source: source, maxPixel: maxPixel)
    }

    /// Pixel dimensions read from the image header (no decode). Used for cache cost.
    static func pixelSize(data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(source: source)
    }

    private static func pixelSize(source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Point (DPI-normalized) size that matches what `NSImage.size` would report,
    /// computed from the header only (pixel size ÷ DPI/72). Used for the "w×h"
    /// summaries so the displayed value is unchanged while avoiding a full decode.
    static func pointSize(data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let ph = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        let dpiW = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let dpiH = (props[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 72
        let scaleW = dpiW > 0 ? dpiW / 72 : 1
        let scaleH = dpiH > 0 ? dpiH / 72 : 1
        return CGSize(width: (pw / scaleW).rounded(), height: (ph / scaleH).rounded())
    }

    /// Approximate decompressed byte cost of an NSImage using its real PIXEL
    /// dimensions (RGBA = 4 bytes/pixel).
    static func pixelCost(of image: NSImage) -> Int {
        let (pw, ph) = pixelDimensions(of: image)
        let cost = pw * ph * 4
        return cost > 0 ? cost : 1
    }

    /// Real pixel dimensions of an NSImage (NOT the DPI-normalized `size`).
    static func pixelDimensions(of image: NSImage) -> (Int, Int) {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return (cg.width, cg.height)
        }
        for rep in image.representations where rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        return (Int(image.size.width), Int(image.size.height))
    }
}

extension SlotContent {

    // MARK: - Image Detection

    /// All image-related pasteboard types found in this content.
    /// v2.10.33 (bug #2): delegate to the canonical `SlotContent.isImagePasteboardType`
    /// so this list, `preview`, and the decode paths below can never disagree (the old
    /// local pattern list omitted bare-extension types and some UTIs, letting an image
    /// slot decode to nil and render a "[png]" text preview).
    private var imageTypes: [String] {
        var found: Set<String> = []
        for itemList in items {
            for item in itemList where SlotContent.isImagePasteboardType(item.type) {
                found.insert(item.type)
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

    // ATT-1 (v2.10.32): approximate decompressed byte cost of an NSImage, used as the
    // NSCache cost so totalCostLimit reflects real memory pressure.
    //
    // Previously (C-3, v2.10.31) this used `image.size` — but `NSImage.size` is the
    // DPI-normalized POINT size, not pixels. A 144-DPI Retina 8192×4320 screenshot
    // reports size 4096×2160, so its real ~135MB decompressed footprint was charged
    // as only ~34MB, letting the 512MB cache hold ~2GB of real memory before evicting.
    // We now compute cost from the true PIXEL dimensions (CGImage.width/height, or
    // NSBitmapImageRep.pixelsWide/High), i.e. pixelsWide × pixelsHigh × 4 (RGBA).
    // The 512MB totalCostLimit is kept.
    private static func decompressedCost(of image: NSImage) -> Int {
        ClipSlotsImageIO.pixelCost(of: image)
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
                // v2.10.33 (bug #2): match the canonical image predicate used by
                // `hasImage`/`imageTypes`/`preview`, so every type that takes the image
                // branch (heic/gif/webp/bare-extension included) is actually attempted
                // here instead of decoding to nil and falling back to a text preview.
                if SlotContent.isImagePasteboardType(item.type) {
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

    // ATT-1/ATT-2 (v2.10.32): separate small-thumbnail cache for the main grid. The
    // grid cell is only ~140pt, so storing a full-resolution 8K NSImage there (as the
    // old `decodedInlineImage()` path did) both wasted memory and undercounted cost.
    // Full-res images stay in `inlineImageCache` (used only by the enlarge-preview
    // path); grid thumbnails live here. Each entry is tiny; bound by count + a small
    // cost limit as a safety net.
    private static let inlineThumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB of small thumbnails
        return cache
    }()

    // ATT-1/ATT-2 (v2.10.32): decode a DOWNSAMPLED inline image (longest edge ≤
    // maxPixel) via ImageIO instead of the full-resolution `NSImage(data:)`. Used by
    // the main grid thumbnail so a huge pasted image never decompresses to full size
    // just to draw a small cell. Cached separately from the full-res preview cache.
    func decodedInlineThumbnail(maxPixel: CGFloat) -> NSImage? {
        let cacheKey: NSString? = contentId.isEmpty ? nil : "\(contentId)::\(updatedAt)::\(Int(maxPixel))" as NSString
        if let cacheKey, let cached = Self.inlineThumbnailCache.object(forKey: cacheKey) {
            return cached
        }
        for itemList in items {
            for item in itemList {
                // v2.10.33 (bug #2): match the canonical image predicate used by
                // `hasImage`/`imageTypes`/`preview`, so every type that takes the image
                // branch (heic/gif/webp/bare-extension included) is actually attempted
                // here instead of decoding to nil and falling back to a text preview.
                if SlotContent.isImagePasteboardType(item.type) {
                    if let thumb = ClipSlotsImageIO.downsampledImage(data: item.data, maxPixel: maxPixel) {
                        if let cacheKey {
                            Self.inlineThumbnailCache.setObject(thumb, forKey: cacheKey, cost: ClipSlotsImageIO.pixelCost(of: thumb))
                        }
                        return thumb
                    }
                }
            }
        }
        return nil
    }

    // ATT-2/UI-1 (v2.10.32): cheap POINT-size probe of the first inline image item.
    // Reads only the image header (pixel size + DPI) via ImageIO and reproduces what
    // `NSImage.size` would report, so the "w×h" summaries stay identical while never
    // triggering a full-resolution decode on the main thread.
    func inlineImagePointSize() -> CGSize? {
        for itemList in items {
            for item in itemList {
                // v2.10.33 (bug #2): match the canonical image predicate used by
                // `hasImage`/`imageTypes`/`preview`, so every type that takes the image
                // branch (heic/gif/webp/bare-extension included) is actually attempted
                // here instead of decoding to nil and falling back to a text preview.
                if SlotContent.isImagePasteboardType(item.type) {
                    if let size = ClipSlotsImageIO.pointSize(data: item.data) { return size }
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

    // MARK: - Cache Invalidation (v2.10.33, bug #1)

    /// Drop the cached decoded image / downsampled thumbnail / metadata summary for a
    /// specific content identity (`contentId::updatedAt`). Called by the pack importer
    /// right after it mints a fresh `contentId` + `updatedAt` for each imported slot so
    /// that no stale entry — however unlikely a key coincidence — can bleed a local
    /// slot's thumbnail onto a freshly imported one. Thumbnails are keyed with a
    /// `::<maxPixel>` suffix, so we clear the known grid size (512) plus the raw key.
    static func invalidateInlineCaches(contentId: String, updatedAt: TimeInterval) {
        guard !contentId.isEmpty else { return }
        let base = "\(contentId)::\(updatedAt)"
        inlineImageCache.removeObject(forKey: base as NSString)
        metadataSummaryCache.removeObject(forKey: base as NSString)
        for maxPixel in [512, 256, 128, 1024] {
            inlineThumbnailCache.removeObject(forKey: "\(base)::\(maxPixel)" as NSString)
        }
    }

    /// Nuke every inline image cache. Used as a belt-and-suspenders sweep after a bulk
    /// pack import so the grid re-decodes each slot from its own (fresh-identity) bytes.
    /// Cheap: entries are lazily rebuilt on next render. v2.10.33 (bug #1).
    static func purgeAllInlineImageCaches() {
        inlineImageCache.removeAllObjects()
        inlineThumbnailCache.removeAllObjects()
        metadataSummaryCache.removeAllObjects()
    }

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
        // ATT-2 (v2.10.32): probe the image dimensions from the header instead of
        // fully decoding via `inlineImage`. `metadataSummary` is read inside
        // SlotCardView / SlotThumbnailView / SlotPreviewView bodies, so the old
        // `inlineImage` read forced a full-resolution decode of large pasted images on
        // the main thread. `inlineImagePointSize()` reads only the header and
        // reproduces the same "w×h" (DPI-normalized point) value that `image.size`
        // produced, so the displayed text is unchanged.
        if hasImage, let size = inlineImagePointSize() {
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
