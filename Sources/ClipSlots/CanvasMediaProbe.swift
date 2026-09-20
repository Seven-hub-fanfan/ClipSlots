import AppKit
import AVFoundation
import ImageIO
import ClipSlotsKit

/// 附件的**本地可读 URL**（v2.15.0）。
///
/// 画布上的媒体有三种落盘形态，全都得能被统一拿到一个 `URL`：
///   - `path` 指向用户原始文件（拖进来的图 / 视频）；
///   - `storageFileURL` 指向槽位目录里的外置字节（`{slotDir}/attachments/{id}.bin`，生成产物走这条）；
///   - 只有内嵌 `data`（小文件，直接躺在 json 里）。
///
/// 前两种直接返回；第三种**不返回 URL** —— 而不是悄悄写一个临时文件。理由：全屏预览与
/// 「在访达中显示」是两条会把这个 URL 交给系统的路径，给它一个 `/tmp` 下随时会被清掉的路径，
/// 表现是"刚才能看、过一会儿打不开"，比一开始就说"这份内容没有独立文件"糟糕得多。
/// 图片的内嵌形态另有 `resolveData()` 可以直接解码，不依赖 URL。
extension SlotContent.SlotAttachment {

    /// 磁盘上真实存在的文件 URL；只有内嵌字节时返回 nil。
    var canvasLocalURL: URL? {
        let fm = FileManager.default
        if let path, !path.isEmpty, fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let url = storageFileURL, fm.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    /// 在画布上是否按「视频」呈现。
    ///
    /// 与 `canvasIsImageLike` 同构：不能只看 `type`，视频在这个项目里基本都是以 `.file` 落库的。
    var canvasIsVideoLike: Bool {
        let name = (path?.isEmpty == false ? path! : self.name)
        return CanvasAttachmentKind.from(fileName: name) == .video
    }
}

/// 媒体节点角标要显示的**客观事实**（v2.15.0）。
///
/// 刻意只装"量出来的数"，不装任何显示文案：怎么写成字是 `CanvasMediaInfo` 的事（Kit 层纯函数、
/// 有 smoke 盯着），这里只负责"量到了什么"。两件事分开的收益是显示口径改动不需要碰 IO 代码。
struct CanvasMediaFacts: Equatable {
    /// 像素尺寸。视频取轨道 `naturalSize`（已应用旋转矩阵），图片读文件头。
    var pixelSize: CGSize?
    /// 文件字节数。内嵌字节形态下取 `data.count`。
    var byteCount: Int64?
    /// 时长（秒），仅视频。
    var duration: Double?
    /// 格式（`PNG` / `MP4`）。
    var format: String?

    /// 一个都没量到 —— 调用方据此整体隐藏角标（画一个空角标等于画一道无意义的深色条）。
    var isEmpty: Bool {
        pixelSize == nil && byteCount == nil && duration == nil && format == nil
    }
}

/// 媒体元信息探测（v2.15.0）。
///
/// ## 为什么是「同步 + 内存缓存 + 负结果也缓存」
///
/// 这套结构是照抄 `VideoThumbnailProvider` 的，理由也一样，而且在这里更充分：
///   - 探测的成本是**读文件头 / 读轨道属性**，不解码任何像素，在本地文件上是几十微秒量级；
///   - 做成异步就要引入加载态 + 占位 + 完成回调触发重绘，而这个信息只是角标上的一行小字 ——
///     为一行小字引入一条异步链路，换来的是"缩放/拖拽时角标闪烁"这种更糟的观感；
///   - **负结果必须记住**：缺失文件、只有内嵌字节的视频永远量不到时长，不记的话每次视图求值
///     都会白跑一次 AVFoundation。这正是画布卡顿最隐蔽的来源（v2.11.19 在缩略图上踩过）。
///
/// ## 缓存键为什么带 mtime + size
///
/// 同一槽位重跑生成会**覆盖**同一个 `attachments/{id}.bin`，路径和附件 id 都不变。只认 id 的话
/// 角标会一直显示上一条产物的尺寸 —— 而"图换了、尺寸没换"比"没有尺寸"更容易误导人。
enum CanvasMediaProbe {

    private struct CacheKey: Hashable {
        let id: String
        let modified: TimeInterval
        let size: Int64
    }

    private static var cache: [CacheKey: CanvasMediaFacts] = [:]
    private static let maxCachedItems = 96

    /// 探测。失败返回 `isEmpty == true` 的空事实而不是 nil：调用方只需判断 `isEmpty`，
    /// 不必再区分"量不到"和"没量"。
    static func facts(for att: SlotContent.SlotAttachment) -> CanvasMediaFacts {
        let url = att.canvasLocalURL
        let key = makeKey(att, url: url)
        if let hit = cache[key] { return hit }

        var facts = CanvasMediaFacts()
        facts.format = CanvasMediaInfo.formatLabel(fileName: displayFileName(att))

        if let url {
            facts.byteCount = fileSize(url)
            if att.canvasIsVideoLike {
                facts.duration = VideoThumbnailProvider.duration(forFile: url.path)
                facts.pixelSize = videoPixelSize(url)
            } else {
                facts.pixelSize = ClipSlotsImageIO.pixelSize(url: url)
            }
        } else if let data = att.resolveData() {
            // 内嵌字节：视频量不到（没有 URL 给 AVFoundation），图片能从数据头读尺寸。
            facts.byteCount = Int64(data.count)
            if !att.canvasIsVideoLike {
                facts.pixelSize = ClipSlotsImageIO.pixelSize(data: data)
            }
        }

        if cache.count >= maxCachedItems { cache.removeAll(keepingCapacity: true) }
        cache[key] = facts
        return facts
    }

    /// 角标整行文案。空事实返回空串。
    ///
    /// 顺序是 `尺寸 · 比例 · 时长 · 体积`：从"这是什么形状"到"这有多大"，越靠前的越常被用来
    /// 一眼区分两个节点。格式（PNG/MP4）刻意**不进角标** —— 它在文件名里已经有了，
    /// 而角标的横向空间在 280pt 宽的卡片上非常紧。
    static func badgeLine(for att: SlotContent.SlotAttachment) -> String {
        let f = facts(for: att)
        guard !f.isEmpty else { return "" }
        return CanvasMediaInfo.badgeLine([
            f.pixelSize.flatMap { CanvasMediaInfo.sizeLabel($0) },
            f.pixelSize.flatMap { CanvasMediaInfo.ratioLabel($0) },
            f.duration.flatMap { CanvasMediaInfo.durationLabel($0) },
            f.byteCount.flatMap { CanvasMediaInfo.byteLabel($0) },
        ])
    }

    // MARK: - 内部

    private static func displayFileName(_ att: SlotContent.SlotAttachment) -> String {
        if let path = att.path, !path.isEmpty { return (path as NSString).lastPathComponent }
        return att.name
    }

    private static func makeKey(_ att: SlotContent.SlotAttachment, url: URL?) -> CacheKey {
        guard let url,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return CacheKey(id: att.id.uuidString, modified: 0, size: 0)
        }
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return CacheKey(id: att.id.uuidString, modified: modified, size: size)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 else { return nil }
        return size
    }

    /// 视频像素尺寸。
    ///
    /// 必须过一遍 `preferredTransform`：竖屏视频（9:16）的轨道 `naturalSize` 往往是横的
    /// `1920×1080` + 一个 90° 旋转矩阵。直接用 naturalSize 会把一条竖视频的角标写成 `16:9`，
    /// 而它在卡片上明明是竖的 —— 这种"角标和眼睛不一致"比没有角标更让人不信任。
    private static func videoPixelSize(_ url: URL) -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let natural = track.naturalSize
        guard natural.width > 0, natural.height > 0 else { return nil }
        let transformed = natural.applying(track.preferredTransform)
        let w = abs(transformed.width)
        let h = abs(transformed.height)
        guard w > 0, h > 0 else { return natural }
        return CGSize(width: w.rounded(), height: h.rounded())
    }
}

/// 「这个节点该展示 / 该全屏哪一份媒体」的唯一答案（v2.15.0）。
///
/// 抽成一处是因为它有**两个消费者**：卡片上画的那张图（`CanvasMediaNodeCard`）和全屏预览打开的
/// 那份文件（`CanvasWorkspaceView.openFullscreen`）。两边各写一遍挑选规则，迟早出现"卡片上是
/// 产物图、点全屏弹出来的是参考图"——而这两张图在同一个节点上共存是常态。
enum CanvasMediaPick {

    /// 优先级：**最新产物** > 与节点类型同类的附件 > 任意图/视频附件。
    ///
    /// - 产物优先：媒体节点通常同时挂着入参（参考图 / 首帧）和产物，而入参往往先加进去、排在前面。
    ///   展示入参会让人误以为"生成出来就是这样"。
    /// - 取 `last` 而不是 `first`：重跑会往 `outputAttachmentIds` 追加，最后一个才是最新一版。
    /// - 退到普通附件：App 重启后 `node.state` 回到 `.idle`（状态不持久化），只认 `.succeeded`
    ///   会让"重启后图都不见了"。磁盘上的附件才是真相。
    static func primary(node: CanvasNode,
                        attachments: [SlotContent.SlotAttachment]) -> SlotContent.SlotAttachment? {
        let outputs = Set(node.outputAttachmentIds)
        if let produced = attachments.last(where: { outputs.contains($0.id.uuidString) }) {
            return produced
        }
        let wantsVideo = node.kind == .video
        if let sameKind = attachments.first(where: {
            wantsVideo ? $0.canvasIsVideoLike : $0.canvasIsImageLike
        }) {
            return sameKind
        }
        return attachments.first(where: { $0.canvasIsImageLike || $0.canvasIsVideoLike })
    }
}
