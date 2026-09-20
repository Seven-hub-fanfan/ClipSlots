import AppKit
import AVFoundation
import ClipSlotsKit

/// 视频产物的**首帧缩略图**供给者（v2.11.19）。
///
/// ## 为什么需要它
///
/// 画布卡片的预览区在 v2.11.18 之前只有一条路径：`NSImage(contentsOfFile: path)`。视频节点接入后
/// 那条路径对 mp4 **静默返回 nil** —— 症状不是报错，而是"生成成功了但卡片上什么都没有"，
/// 与"生成失败"在视觉上完全一样，用户无法区分。所以视频产物必须有自己的取图路径。
///
/// ## 为什么是内存缓存、而且刻意不落盘
///
/// 全 App 的缩略图策略是**纯内存、无磁盘缓存**（见数据目录约定：`~/.local/share/clipslots/` 下
/// 只有槽位数据，没有缓存目录）。给视频破这个例会带来两个新问题：缓存失效谁负责（视频被用户
/// 删了、或同一槽位重跑覆盖），以及磁盘占用谁清理。抽首帧的成本是一次 `AVAssetImageGenerator`，
/// 在本地文件上是毫秒级，不值得为它引入第一个磁盘缓存。
///
/// 缓存键必须带 **mtime + size**，不能只用路径：同一个槽位重跑生成，产物路径可能一样
/// （`attachments/{id}.bin` 被覆盖），只认路径的话卡片会一直显示上一条视频的首帧。
///
/// ## 为什么抽第 0.0s 之后的一点点
///
/// 很多模型的首帧是纯黑（淡入开场），抽 0s 得到一张全黑图，看起来和"没预览"一样。实测取
/// `min(0.6s, 时长 * 0.1)` 能在绝大多数片子上拿到有内容的一帧，同时不会跑到画面已经大幅变化的
/// 位置（那会让用户觉得"这不是我的视频开头"）。
///
/// ## 线程
///
/// `thumbnail(forFile:)` 是**同步**的，只在主线程被 SwiftUI 的 body 调用。这看起来违反"不要在
/// body 里做 IO"，但实际取舍相反：一次本地抽帧是毫秒级，而做成异步就需要一个
/// `@Published` 的加载态 + 占位图 + 完成后触发重绘，那条链路在画布这种"一屏几十个节点"的场景里
/// 反而更容易抖动（每次滚动都重新触发异步任务）。真正大的视频文件由 `maxCachedItems` 兜住内存。
enum VideoThumbnailProvider {

    /// 缓存上限。画布上同时可见的视频节点不会太多，32 项足够覆盖一屏 + 邻近滚动区域。
    /// 超过就整体清空而不是 LRU 淘汰：LRU 需要维护访问序，而这里的收益差别可以忽略——
    /// 清空后最多是那一帧多花几毫秒重新抽。
    private static let maxCachedItems = 32

    private struct CacheKey: Hashable {
        let path: String
        let modified: TimeInterval
        let size: Int64
    }

    private static var cache: [CacheKey: NSImage] = [:]
    /// 抽帧失败过的键。记下来是为了**不要每次重绘都重试**：一个损坏/半下载的 mp4 会让每帧都
    /// 白跑一次 AVFoundation，那是画布卡顿最隐蔽的一种来源。
    private static var failed: Set<CacheKey> = []

    /// 取首帧。不是视频、文件不存在、抽帧失败都返回 nil（调用方按"没有预览"处理）。
    static func thumbnail(forFile path: String) -> NSImage? {
        guard CanvasAttachmentKind.from(fileName: path) == .video else { return nil }
        guard let key = makeKey(path) else { return nil }
        if let hit = cache[key] { return hit }
        if failed.contains(key) { return nil }

        guard let image = extractFirstFrame(path) else {
            failed.insert(key)
            return nil
        }
        if cache.count >= maxCachedItems {
            cache.removeAll(keepingCapacity: true)
            failed.removeAll(keepingCapacity: true)
        }
        cache[key] = image
        return image
    }

    /// 视频时长（秒）。卡片右下角的时长角标用它。取不到返回 nil（角标就不显示）。
    ///
    /// 与首帧共用一次 `AVURLAsset` 本来更省，但时长是**在首帧之前**就要用到的（角标先画、图后到），
    /// 而且 `asset.duration` 不涉及解码，成本比抽帧低一个量级，分开取更简单。
    static func duration(forFile path: String) -> Double? {
        guard CanvasAttachmentKind.from(fileName: path) == .video else { return nil }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    /// `mm:ss`。视频最长 30s，所以刻意不做小时位——那只会让绝大多数角标多两个字符。
    static func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - 内部

    private static func makeKey(_ path: String) -> CacheKey? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return CacheKey(path: path, modified: modified, size: size)
    }

    private static func extractFirstFrame(_ path: String) -> NSImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        // 必须开这个：不开时抽出来的帧不带轨道的旋转矩阵，竖屏视频（9:16）的首帧会被画成横的。
        generator.appliesPreferredTrackTransform = true
        // 长边压到 640：卡片预览区最大也就几百 pt，抽一张 4k 原尺寸图只是白占内存
        // （一张 3840×2160 的 NSImage 约 33MB，32 项缓存就能吃掉 1GB）。
        generator.maximumSize = CGSize(width: 640, height: 640)

        let seconds = CMTimeGetSeconds(asset.duration)
        let target = seconds.isFinite && seconds > 0 ? min(0.6, seconds * 0.1) : 0
        let time = CMTime(seconds: target, preferredTimescale: 600)

        // 容差给满：精确抽帧要解码到指定帧，在长视频上明显更慢，而这里只是要"一张能看出内容的图"。
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
