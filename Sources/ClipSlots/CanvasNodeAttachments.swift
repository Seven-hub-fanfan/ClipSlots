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
/// 所以这里的契约是：
///   - `body` **只读缓存**，命中就同步返回（这条路径必须零 IO）。
///   - 未命中时把解码丢到后台串行队列，完成后回主线程写 `@State` 触发一次重绘。
///   - **失败也要记住**（`misses`）：不少附件（缺失文件、非标准格式）永远生不出缩略图，
///     不记负结果的话每次视图重建都会重跑一遍失败的解码，成本与成功路径一样高却毫无收益。
enum CanvasAttachmentThumbnails {

    /// 缓存键必须带 `maxPixel`：同一个附件在预览区（240px）和芯片（40px）要两种尺寸，
    /// 只用 id 做键会让先加载的那个尺寸把另一处也顶掉（芯片里塞进 240px 大图，或预览区被拉花）。
    private static func key(_ att: SlotContent.SlotAttachment, maxPixel: CGFloat) -> String {
        "\(att.id.uuidString)::\(Int(maxPixel.rounded()))"
    }

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // 一屏十几张卡片 × 每张数个附件 × 两种尺寸，128 足够覆盖工作集又不至于长期占着内存。
        c.countLimit = 128
        return c
    }()

    /// 「这张生不出缩略图」的记忆。见类型注释。
    private static var misses = Set<String>()
    /// 正在解码中的键。同一附件在预览区与芯片里可能同时出现，去重后避免重复解码同一份数据。
    private static var inFlight = Set<String>()
    private static let lock = NSLock()

    /// 解码队列刻意是**串行**的：并发解码多张大图会瞬时占用数倍内存（ATT-3 那次 OOM 的同源风险），
    /// 而缩略图本来就只需要「在一两帧之内陆续出现」，不需要并行。
    private static let queue = DispatchQueue(label: "clipslots.canvas.attachment.thumbnail",
                                            qos: .userInitiated)

    /// 只读缓存。`body` 里唯一允许调的入口。
    static func cached(_ att: SlotContent.SlotAttachment, maxPixel: CGFloat) -> NSImage? {
        cache.object(forKey: key(att, maxPixel: maxPixel) as NSString)
    }

    /// 是否已经确定这张没有缩略图（可以直接画语义图标，不必再等）。
    static func isKnownMiss(_ att: SlotContent.SlotAttachment, maxPixel: CGFloat) -> Bool {
        let k = key(att, maxPixel: maxPixel)
        lock.lock(); defer { lock.unlock() }
        return misses.contains(k)
    }

    /// 请求加载。已命中缓存 / 已知失败 / 正在加载中都会**立即返回且不重复排队**。
    static func load(_ att: SlotContent.SlotAttachment,
                     maxPixel: CGFloat,
                     completion: @escaping (NSImage?) -> Void) {
        let k = key(att, maxPixel: maxPixel)
        if let hit = cache.object(forKey: k as NSString) {
            completion(hit)
            return
        }

        lock.lock()
        if misses.contains(k) {
            lock.unlock()
            completion(nil)
            return
        }
        if inFlight.contains(k) {
            // 已有同键任务在跑。这里不排第二份，也不给 completion —— 调用方会在对方完成写入缓存后
            // 的下一次视图求值里读到结果。
            lock.unlock()
            return
        }
        inFlight.insert(k)
        lock.unlock()

        queue.async {
            let image = AttachmentThumbnailProvider.thumbnail(for: att, maxPixel: maxPixel)
            if let image {
                cache.setObject(image, forKey: k as NSString)
            }
            lock.lock()
            inFlight.remove(k)
            if image == nil { misses.insert(k) }
            lock.unlock()
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
        guard type == .file, let path, !path.isEmpty else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp"].contains(ext)
    }

    /// 生不出缩略图时的语义图标。
    var canvasFallbackSymbol: String {
        switch type {
        case .image: return "photo"
        case .file:
            guard let path, !path.isEmpty else { return "doc" }
            let ext = (path as NSString).pathExtension.lowercased()
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

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if CanvasAttachmentThumbnails.isKnownMiss(attachment, maxPixel: maxPixel) {
                Image(systemName: attachment.canvasFallbackSymbol)
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(AppTheme.canvasCardMetaInk.opacity(0.55))
            } else {
                // 加载中不放 ProgressView：一屏十几张卡片同时转圈是纯噪声，静默占位更安静。
                Color.clear
            }
        }
        .onAppear { request() }
        // 附件换了（切换绑定槽位 / 槽位内容被替换）就重新取，否则会一直显示上一份附件的图。
        .onChange(of: attachment.id) { _ in
            image = nil
            request()
        }
    }

    private func request() {
        if let hit = CanvasAttachmentThumbnails.cached(attachment, maxPixel: maxPixel) {
            image = hit
            return
        }
        CanvasAttachmentThumbnails.load(attachment, maxPixel: maxPixel) { loaded in
            if let loaded { image = loaded }
        }
    }
}

// MARK: - 附件条

/// 节点卡片底部的附件条。
///
/// 展示口径：最多 `visibleLimit` 个；图片类画缩略图方块，非图片画「图标 + 文件名」；
/// 超出的折成 `+N`。刻意**不做滚动**：卡片宽度固定 260pt，在画布上做横向滚动区会和画布本身的
/// 滚轮平移抢事件（滚轮在画布上的语义是翻页平移）。要看全部附件走编辑页的附件管理器。
struct CanvasNodeAttachmentStrip: View {
    let attachments: [SlotContent.SlotAttachment]
    var visibleLimit: Int = 3

    private var visible: [SlotContent.SlotAttachment] { Array(attachments.prefix(visibleLimit)) }
    private var overflow: Int { max(0, attachments.count - visibleLimit) }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "paperclip")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(AppTheme.canvasCardMetaInk)

            ForEach(visible, id: \.id) { att in
                CanvasAttachmentChip(attachment: att)
            }

            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.canvasCardMetaInk)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(AppTheme.chipBackground)
                    )
            }

            Spacer(minLength: 0)
        }
        .help(attachments.map(\.canvasDisplayName).joined(separator: "\n"))
    }
}

/// 单个附件芯片。图片类 = 缩略图方块；其余 = 图标 + 名字。
private struct CanvasAttachmentChip: View {
    let attachment: SlotContent.SlotAttachment
    /// 芯片在 1x 下 18pt，按 Retina 取 2 倍余量解码。
    private let maxPixel: CGFloat = 48

    @State private var image: NSImage?

    var body: some View {
        Group {
            if attachment.canvasIsImageLike {
                thumbnailTile
            } else {
                fileChip
            }
        }
        .onAppear { request() }
        .onChange(of: attachment.id) { _ in
            image = nil
            request()
        }
    }

    private var thumbnailTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(AppTheme.chipBackground)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: attachment.canvasFallbackSymbol)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(AppTheme.canvasCardMetaInk)
            }
        }
        .frame(width: 18, height: 18)
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(AppTheme.subtleBorder.opacity(0.7), lineWidth: 0.5)
        )
    }

    private var fileChip: some View {
        HStack(spacing: 3) {
            Image(systemName: attachment.canvasFallbackSymbol)
                .font(.system(size: 8, weight: .semibold))
            Text(attachment.canvasDisplayName)
                .font(.system(size: 8, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundColor(AppTheme.canvasCardMetaInk)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: 78, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(AppTheme.chipBackground)
        )
    }

    private func request() {
        // 只有图片类才需要解码。非图片芯片画的是 SF Symbol + 文件名，去问一次
        // `NSWorkspace.icon(forFile:)` 拿 Finder 图标却又不用它，纯属白花一次磁盘 IO。
        guard attachment.canvasIsImageLike else { return }
        if let hit = CanvasAttachmentThumbnails.cached(attachment, maxPixel: maxPixel) {
            image = hit
            return
        }
        CanvasAttachmentThumbnails.load(attachment, maxPixel: maxPixel) { loaded in
            if let loaded { image = loaded }
        }
    }
}
