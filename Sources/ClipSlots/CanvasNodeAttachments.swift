import SwiftUI
import AppKit
import ClipSlotsKit

/// 画布节点卡片上的**附件展示**（v2.11.7 hotfix19）。
///
/// ## 背景
///
/// 用户反馈「在画布上看不到附件信息」。槽位的图片 / 视频 / 文档全都住在
/// `SlotContent.attachments` 里，而节点卡片此前只渲染主体文本 —— 于是一个「只放了图、没写字」的
/// 槽位拖到画布上就是一张空白卡片，看起来像是拖丢了。
///
/// ## 为什么需要一层缓存 + 异步
///
/// `AttachmentThumbnailProvider.thumbnail(for:maxPixel:)` 是**同步磁盘 IO + ImageIO 解码**。
/// 画布上一屏可能有十几张卡片、每张卡片可能挂着数个附件，而 SwiftUI 的 `body` 在拖拽 / 缩放 /
/// 选中变化时会被反复求值。直接在 `body` 里调它，等于每帧都在主线程上解码几十张图 —— 表现是
/// 拖动节点时整个画布卡成幻灯片。
///
/// `body` 只读本地状态。文件版本检查、缓存与解码全部在后台串行队列，
/// 完成后回主线程。失败结果按文件版本缓存，原图恢复或被覆盖后可以重试。
enum CanvasAttachmentThumbnails {

    /// 缓存键必须带 `maxPixel`：同一个附件在预览区（240px）和芯片（40px）要两种尺寸，
    /// 只用 id 做键会让先加载的那个尺寸把另一处也顶掉（芯片里塞进 240px 大图，或预览区被拉花）。
    private static func key(_ att: SlotContent.SlotAttachment, maxPixel: CGFloat) -> String {
        "\(att.canvasSourceVersion)::\(Int(maxPixel.rounded()))"
    }

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // 一屏十几张卡片 × 每张数个附件 × 两种尺寸，128 足够覆盖工作集又不至于长期占着内存。
        c.countLimit = 128
        return c
    }()

    /// 「这张生不出缩略图」的记忆。见类型注释。
    private static var misses = Set<String>()

    /// 解码队列刻意是**串行**的：并发解码多张大图会瞬时占用数倍内存（ATT-3 那次 OOM 的同源风险），
    /// 而缩略图本来就只需要「在一两帧之内陆续出现」，不需要并行。
    private static let queue = DispatchQueue(label: "clipslots.canvas.attachment.thumbnail",
                                            qos: .userInitiated)

    /// 请求加载。已命中缓存 / 已知失败 / 正在加载中都会**立即返回且不重复排队**。
    static func load(_ att: SlotContent.SlotAttachment,
                     maxPixel: CGFloat,
                     completion: @escaping (NSImage?) -> Void) {
        queue.async {
            // stat 与解码都在串行后台队列。每次请求检查文件版本，失败文件恢复后也能重新加载。
            let k = key(att, maxPixel: maxPixel)
            if let hit = cache.object(forKey: k as NSString) {
                DispatchQueue.main.async { completion(hit) }
                return
            }
            if misses.contains(k) {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let image = AttachmentThumbnailProvider.thumbnail(for: att, maxPixel: maxPixel)
            if let image { cache.setObject(image, forKey: k as NSString) }
            else {
                if misses.count >= 256 { misses.remove(misses.first!) }
                misses.insert(k)
            }
            DispatchQueue.main.async { completion(image) }
        }
    }
}

// MARK: - 附件语义

extension SlotContent.SlotAttachment {
    /// 在画布上是否按「图像」呈现。
    ///
    /// 刻意不只看 `type == .image`：项目里大量图片是以 `.file` 落库的（拖入 / 溢出写入路径），
    /// 只信 type 会让一半图片显示成 Finder 文档图标（v2.8.9 已经在附件面板里踩过这个坑）。
    var canvasIsImageLike: Bool {
        if type == .image { return true }
        guard type == .file else { return false }
        let ext = ((path?.isEmpty == false ? path! : name) as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp"].contains(ext)
    }

    /// 生不出缩略图时的语义图标。
    var canvasFallbackSymbol: String {
        switch type {
        case .image: return "photo"
        case .file:
            let ext = ((path?.isEmpty == false ? path! : name) as NSString).pathExtension.lowercased()
            if ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext) { return "film" }
            if ["pdf"].contains(ext) { return "doc.richtext" }
            if ["zip", "rar", "7z", "tar", "gz"].contains(ext) { return "doc.zipper" }
            return "doc"
        case .text: return "text.alignleft"
        case .url: return "link"
        case .reference: return "arrow.up.right.square"
        }
    }

    /// 芯片上显示的短名。空名兜底成类型名，绝不显示成一个孤零零的图标（用户无法判断那是什么）。
    var canvasDisplayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let path, !path.isEmpty { return (path as NSString).lastPathComponent }
        switch type {
        case .image: return "图片"
        case .file: return "文件"
        case .text: return "文本"
        case .url: return "链接"
        case .reference: return "引用"
        }
    }
}

// MARK: - 预览区的附件大图

/// 节点预览区里的附件图像。
///
/// 只在「节点自己还没有生成结果」时出现：生成结果是这个节点的产物，附件是它的输入，产物在就该
/// 显示产物 —— 这个优先级由调用方（`CanvasNodeCardView.previewArea`）决定，本视图不参与判断。
struct CanvasAttachmentPreviewImage: View {
    let attachment: SlotContent.SlotAttachment
    /// 解码上限（像素）。预览区在 1x 下约 236×148，取 480 兼顾 Retina 与放大后的清晰度。
    var maxPixel: CGFloat = 480
    /// 填充模式（v2.15.0）。
    ///
    /// 默认 `.fill` 是槽位卡堆叠预览的需求：那里的卡片是**固定尺寸的小卡**，留白会让一叠卡片
    /// 显得参差不齐。媒体节点相反 —— 它要传达"这张图是什么形状"，裁掉边缘就是在骗人（用户还会
    /// 对着旁边的 `9:16` 角标怀疑角标错了）。所以媒体卡显式传 `.fit`。
    var contentMode: ContentMode = .fill

    @State private var image: NSImage?
    /// 当前 `image` 属于哪个附件。★ 七轮：防"迟到的异步回调把上一张图贴到已经换了内容的卡片上"。
    ///
    /// 用户报「翻页后同屏出现两张一模一样的图」。窗口下标本身没问题（`CardWindow.indicesAreSane`），
    /// 问题出在这里：`request()` 的完成回调闭包捕获的是**调用那一刻的 self 快照**，所以
    /// 闭包里读 `attachment` 永远是老附件，光靠 `guard` 比不出新旧；而 `@State` 的存储是跨结构体
    /// 实例共享的，翻页后视图被复用时旧回调一落地就把老图写进了新位置 —— 那张老图往往正好也在
    /// 新窗口里，于是同屏出现两张相同的图。把"这张图属于谁"一起存下来，渲染时和当前 `attachment.id`
    /// 对不上就当没有图，脏图无法上屏。
    @State private var shownId: UUID?

    var body: some View {
        ZStack {
            if let image, shownId == attachment.id {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: attachment.canvasFallbackSymbol)
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(AppTheme.canvasCardMetaInk.opacity(0.55))
            }
        }
        .task(id: "\(attachment.canvasSourceIdentity)|\(maxPixel)") {
            image = nil
            shownId = nil
            // 只对在屏幕上的预览检查版本；没有变化时不发布状态、不重新解码。
            while !Task.isCancelled {
                let loaded = await withCheckedContinuation { continuation in
                    CanvasAttachmentThumbnails.load(attachment, maxPixel: maxPixel) { continuation.resume(returning: $0) }
                }
                guard !Task.isCancelled else { return }
                if image !== loaded || shownId != attachment.id {
                    image = loaded
                    shownId = attachment.id
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
