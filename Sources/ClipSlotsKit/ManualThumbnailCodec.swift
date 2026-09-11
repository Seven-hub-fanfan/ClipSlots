import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 手动缩略图归一化编解码（v2.11.2）
//
// 本文件把「任意图片 → 最长边 ≤1024 的 JPEG 字节」这段归一化逻辑从 GUI 层
// (`ManualThumbnailService.ManualThumbnailMaker`) 下沉到 Kit，原因只有一个：
// **CLI 也要能设置槽位缩略图**，而 CLI 不依赖 ClipSlots（GUI）target。
//
// 下沉后 GUI / CLI 共用同一份编码参数与降采样实现，杜绝「GUI 存 1024/q0.85、CLI 存别的」
// 这种双份真理——一旦两侧参数漂移，同一张图在两个入口下产出的字节不同，用户会看到
// 「命令行设的封面比界面里糊」这类无从排查的差异。
//
// 设计要点：
//   • 降采样走 `CGImageSourceCreateThumbnailAtIndex` 增量解码，全程只解出目标尺寸的位图。
//     若先 `NSImage(contentsOf:)` 再缩放，一张 8000×6000 的照片会有 ~190MB 的瞬时峰值。
//   • 编码沿用 `NSBitmapImageRep`（而非 CGImageDestination），与下沉前逐字节等价。
//   • SVG / PDF 明确拒绝：它们是矢量/文档，ImageIO 的位图缩略图路径要么拿不到、要么
//     栅格化出一张与用户预期不符的图；与其给个惊喜，不如明确报「不支持」。
public enum ManualThumbnailCodec {

    /// 归一化后的最长边（像素）。1024 足够覆盖 Retina 下的卡片主预览与轮盘扇区，
    /// 又能把一张 4K 截图从数 MB 压到百 KB 级，避免大图撑爆槽位目录。
    public static let maxPixelEdge: CGFloat = 1024

    /// JPEG 压缩质量。0.85 是「肉眼几乎无损 / 体积可控」的常用折中。
    public static let jpegQuality: CGFloat = 0.85

    /// 明确**不**受支持的输入扩展名。矢量图与文档格式在这里直接短路，
    /// 不去碰 ImageIO——避免不同 macOS 版本对 SVG 的支持差异导致行为飘忽。
    public static let rejectedExtensions: Set<String> = ["svg", "svgz", "pdf"]

    /// 明确**不**受支持的输入 UTI（按内容嗅探到的类型，比扩展名更可靠）。
    private static let rejectedUTIs: Set<String> = ["public.svg-image", "com.adobe.pdf"]

    // MARK: - 错误

    public enum CodecError: LocalizedError, Equatable {
        /// 文件不存在或是个目录。
        case fileNotFound(String)
        /// 明确不支持的格式（SVG / PDF）。
        case unsupportedFormat(String)
        /// 能读到文件，但 ImageIO 解不出位图（损坏 / 不是图片）。
        case decodeFailed(String)
        /// 位图拿到了，但 JPEG 编码失败。
        case encodeFailed

        public var errorDescription: String? {
            switch self {
            case .fileNotFound(let p):
                return "找不到图片文件「\(p)」"
            case .unsupportedFormat(let name):
                return "「\(name)」是矢量图或文档格式（SVG / PDF），不支持作为槽位缩略图；请先导出为 PNG / JPEG"
            case .decodeFailed(let name):
                return "无法读取图片「\(name)」，可能不是受支持的图片格式或文件已损坏"
            case .encodeFailed:
                return "图片编码失败"
            }
        }
    }

    // MARK: - 公开入口

    /// 把磁盘上的图片文件归一化成「最长边 ≤1024 的 JPEG」字节。
    ///
    /// 支持 PNG / JPEG / HEIC / HEIF / TIFF / GIF / BMP / WebP 等 ImageIO 能解的位图格式，
    /// 一律输出 JPEG；SVG / PDF 抛 `.unsupportedFormat`。
    public static func normalizedJPEGData(from url: URL) throws -> Data {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw CodecError.fileNotFound(url.path)
        }
        if rejectedExtensions.contains(url.pathExtension.lowercased()) {
            throw CodecError.unsupportedFormat(url.lastPathComponent)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CodecError.decodeFailed(url.lastPathComponent)
        }
        return try normalizedJPEGData(source: source, sourceName: url.lastPathComponent)
    }

    /// 把内存中的图片字节归一化成 JPEG。截图路径（`screencapture` 产物）与 pack 导入复用它。
    public static func normalizedJPEGData(from data: Data, sourceName: String = "image") throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CodecError.decodeFailed(sourceName)
        }
        return try normalizedJPEGData(source: source, sourceName: sourceName)
    }

    /// 非抛出版本：任何失败（含 SVG / PDF）都归一化为 nil。
    /// 供「能不能当缩略图」这类只关心成败、不关心原因的判定点使用。
    public static func normalizedJPEGDataOrNil(from url: URL) -> Data? {
        try? normalizedJPEGData(from: url)
    }

    /// 把已解码的 NSImage 编码成 JPEG（同样先保证最长边 ≤ `maxPixelEdge`）。
    public static func jpegData(from image: NSImage) -> Data? {
        guard let cg = downsampledCGImage(from: image) else { return nil }
        return jpegData(from: cg)
    }

    /// 轻量探测：这个文件能不能被归一化成缩略图。
    ///
    /// 只读图片头（`CGImageSourceCopyPropertiesAtIndex`），**不解码像素**，因此可以在批量
    /// 预检阶段对几十个文件连续调用而不担心内存与耗时。注意它比真正的 `normalizedJPEGData`
    /// 宽松（头正常但像素段损坏的文件仍会在编码期失败），所以调用方不能拿它当最终保证。
    public static func isDecodableImage(url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        if rejectedExtensions.contains(url.pathExtension.lowercased()) { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        if let uti = CGImageSourceGetType(source) as String?, rejectedUTIs.contains(uti) { return false }
        guard CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0 > 0,
              (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0 > 0 else {
            return false
        }
        return true
    }

    // MARK: - 内部实现

    private static func normalizedJPEGData(source: CGImageSource, sourceName: String) throws -> Data {
        // 内容嗅探出来的类型优先于扩展名：有人会把 .pdf 改名成 .png。
        if let uti = CGImageSourceGetType(source) as String?, rejectedUTIs.contains(uti) {
            throw CodecError.unsupportedFormat(sourceName)
        }
        guard let cg = downsampledCGImage(source: source) else {
            throw CodecError.decodeFailed(sourceName)
        }
        guard let data = jpegData(from: cg) else {
            throw CodecError.encodeFailed
        }
        return data
    }

    /// 增量降采样选项：限制最长边 + 强制从主图生成（无内嵌缩略图的文件也能工作）。
    private static func thumbnailOptions() -> CFDictionary {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelEdge.rounded()))
        ] as CFDictionary
    }

    private static func downsampledCGImage(source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions())
    }

    /// 保证 CGImage 最长边 ≤ maxPixelEdge；已经够小就原样返回（不做无谓重采样）。
    private static func downsampledCGImage(from image: NSImage) -> CGImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let longest = CGFloat(max(cg.width, cg.height))
        guard longest > maxPixelEdge, longest > 0 else { return cg }

        let scale = maxPixelEdge / longest
        let w = max(1, Int((CGFloat(cg.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(cg.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil,
                                  width: w,
                                  height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cg
    }

    private static func jpegData(from cg: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cg)
        // NSBitmapImageRep 从 CGImage 构造时 size 取的是像素数；显式对齐，避免编码出带诡异 DPI 的图。
        rep.size = NSSize(width: cg.width, height: cg.height)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }
}
