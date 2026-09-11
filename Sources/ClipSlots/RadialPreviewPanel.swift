import SwiftUI
import ClipSlotsKit
import AVKit
import WebKit
import UniformTypeIdentifiers

/// v2.7.13: clean image-only preview. No material background, no rounded container,
/// no AppKit shadow. The HStack toolbar is the only top bar.
/// v2.7.15: supports all storable types (text, image, file, folder, video).
struct RadialPreviewPanel: View {
    let title: String
    let subtitle: String
    let content: AnyView
    @Binding var isPinned: Bool
    @State private var scale: CGFloat = 1
    @State private var dynamicTitle: String = ""
    @State private var dynamicSubtitle: String = ""

    /// v2.11.3 hotfix：当前有没有「可预览的目标」。
    ///
    /// 通知里的 `preview` payload 非 nil ⇔ 悬停到了一个有内容（或有手动封面图）的槽位；
    /// 没悬停、悬停到空槽、圆盘刚弹出、`clearPreviewContent()` 复位，全都是 nil。
    ///
    /// hotfix3 修正了作用范围：**只管内容区**。
    /// hotfix2 曾把工具栏也一起 `if` 掉，结果空态下置顶 / 缩放按钮整条不可点 —— 那是回归。
    /// 现在工具栏无条件常驻，只有「内容区 + 面板磨砂底」跟着它开关。
    ///
    /// 口径说明：这里判定的是「有没有可预览内容」，而不是「有没有附件」。
    /// 附件条本身另有 `if !content.attachments.isEmpty` 把关（见 RadialUniversalPreview），
    /// 所以无附件的槽位不会出现空的附件条；但它的文本 / 图片 / 文件预览仍会正常显示 ——
    /// 那是这扇窗从 v2.7.x 起的主职能。
    @State private var hasPreviewTarget = false

    /// hotfix3：留存最近一发 payload，供内容区重新挂载时补发。
    ///
    /// 内容区一旦随空态卸载，`RadialLivePreviewContent` 的 `@State previewPayload` 就一起没了；
    /// 而它的数据来源是通知 —— 下次悬停时顺序是「通知发出 → 面板 onReceive → hasPreviewTarget 翻真
    /// → 内容区才被创建并订阅」，那一发通知它必然错过，于是**空态后第一次悬停会显示空白**，
    /// 得再划到第二个扇区才恢复。所以内容区挂载后立刻把这份 payload 原样补发一次。
    @State private var retainedPayload: RadialHoverPreviewPayload?

    /// 面板外形：圆角矩形，背景 / 描边 / 裁剪共用同一份，避免三处圆角写歪。
    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            // hotfix3：工具栏**无条件常驻**。
            // 它承载标题 / 缩放 / 置顶三组控件，其中「置顶」尤其关键 —— 置顶后面板会脱离
            // 圆盘生命周期独立留在屏幕上（见 RadialMenuWindowController.isPreviewPinned），
            // 此时若工具栏跟着空态一起消失，用户就再也点不到那颗图钉来取消置顶了。
            // 空态下把它自己也切成 14pt 全圆角，让这条独立浮着的窄条不至于是个方角。
            toolbar
                .clipShape(RoundedRectangle(cornerRadius: hasPreviewTarget ? 0 : 14, style: .continuous))

            // hotfix3：内容区（文本 / 图片 / 文件预览 + 附件磨砂条）随悬停状态收放。
            // 无悬停 → 整块摘掉（`if`，不是 .opacity(0)/.hidden()），只剩上面那条标题栏。
            if hasPreviewTarget {
                Divider()

                ZStack {
                    // v2.7.17: smart background. Only show opaque background when there
                    // is actual content to preview. Empty state / image preview remain
                    // transparent / unobtrusive.
                    content
                        .scaleEffect(scale)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                // 内容区是刚刚才挂载的，它错过了触发本次展开的那一发通知，这里补发一次。
                .onAppear(perform: republishRetainedPayload)
            }
        }
        // v2.11.3 hotfix4：★这个 alignment 是"面板向上跳"的真凶，必须显式写 .top。
        //
        // `.frame(minHeight:)` 的默认对齐是 **.center**。hotfix3 把内容区改成条件渲染后，
        // 空态下 VStack 的自然高度只剩工具栏那 54pt，被塞进 220pt 高的框里垂直居中
        // → 工具栏被压低约 (220-54)/2 ≈ 83pt；内容区一展开、VStack 填满，工具栏又弹回顶部。
        // 于是每次悬停都能看见标题栏"向上跳"一下。
        // hotfix3 之前内容区常驻且带 maxHeight: .infinity，VStack 恒定填满，所以这个
        // .center 一直没被触发 —— 属于我上一轮改动带出来的连带问题。
        //
        // 说明：窗口层面本来就没有跳动的余地 —— NSPanel 是固定 360×480（minSize == maxSize），
        // origin 在 show 时算好后不再变，恢复位置时也是按 maxY 锚住上边缘。所以只需要
        // 把 SwiftUI 这层的顶部锚点补上，内容区就只会向下伸展。
        .frame(minWidth: 260, minHeight: 220, alignment: .top)
        // v2.9.25 hotfix5: 固定填满整个窗口并顶部对齐，工具栏钉在顶部，
        // 内容区始终占据剩余空间，空态/悬停态切换时工具栏不再跳动。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // v2.11.3：整个面板改为一整块磨砂玻璃。
        //
        // 此前这里是 `Color.clear`（v2.7.17 的"窗口全透明、只有内容卡片自带底"方案），
        // 配上纯白不透明的内容卡片，观感就是"一块白板悬在深色圆盘上"。
        // 现在反过来：面板本体用 `.ultraThinMaterial` 打底 —— 模糊透出下层圆盘扇区，
        // 亮/暗模式由系统 material 自动适配（不含任何硬编码白色，也不含任何彩色）；
        // 再压 0.88 不透明度，让通透感更明显。
        //
        // 层次关系：面板 ultraThin（最透）< 头部工具栏 ultraThin 叠加（略实，自然分隔）
        //          < 内容卡片 regularMaterial（最实，保证正文可读）。
        //
        // hotfix3：整幅磨砂底只在内容区展开时铺。空态下面板收成一条标题栏，
        // 若这层还在，圆盘右侧就又会挂着一块 360×480 的空磨砂色块（hotfix 要修的正是它）。
        .background {
            if hasPreviewTarget {
                panelShape.fill(.ultraThinMaterial).opacity(0.88)
            }
        }
        .overlay {
            if hasPreviewTarget {
                panelShape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
        .clipShape(panelShape)
        // v2.11.3 hotfix4：展开 / 收起走 0.15s easeOut，高度不再瞬变。
        // 挂在这一层（而不是内容区内部）才能同时覆盖三件事：内容区的插入删除、
        // 磨砂底与描边的淡入淡出、工具栏圆角在 0/14pt 之间的过渡。
        .animation(.easeOut(duration: 0.15), value: hasPreviewTarget)
        .onReceive(NotificationCenter.default.publisher(for: .radialMenuHoveredSlotChanged)) { note in
            if let payload = note.userInfo?["preview"] as? RadialHoverPreviewPayload {
                dynamicTitle = payload.title
                dynamicSubtitle = payload.subtitle
                retainedPayload = payload
                hasPreviewTarget = true
            } else {
                dynamicTitle = ""
                dynamicSubtitle = ""
                retainedPayload = nil
                hasPreviewTarget = false
            }
        }
    }

    /// 内容区重新挂载后补发留存的 payload，避免"空态后第一次悬停显示空白"。
    ///
    /// 用 `DispatchQueue.main.async` 推迟一拍：`onAppear` 正处在本次渲染事务里，
    /// 同步 post 会在视图更新途中改 `@State`（SwiftUI 会告 "Modifying state during view update"）。
    /// 补发的这一发通知也会被本面板自己收到，但赋的值与当前完全相同，不会引起新的挂载 —— 不存在循环。
    private func republishRetainedPayload() {
        guard let payload = retainedPayload else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .radialMenuHoveredSlotChanged,
                object: nil,
                userInfo: [
                    "mode": "childSlots",
                    "slot": payload.slot,
                    "preview": payload
                ]
            )
        }
    }

    /// 顶部工具栏（标题 + 缩放 + 置顶）。
    private var toolbar: some View {
        // v2.7.13: use this app toolbar as the only top bar.
        HStack(spacing: 10) {
            Image(systemName: "eye")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(dynamicTitle.isEmpty ? title : dynamicTitle)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(dynamicSubtitle.isEmpty ? "实时预览" : dynamicSubtitle)
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Button { scale = max(0.75, scale - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { scale = min(1.8, scale + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { isPinned.toggle() } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .foregroundColor(isPinned ? .accentColor : .secondary)
                    .padding(6)
                    .background(Circle().fill(isPinned ? Color.accentColor.opacity(0.16) : Color.clear))
            }
            .help(isPinned ? "已置顶：拖到哪里就固定到哪里" : "置顶预览窗")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .frame(height: 54)
        // v2.9.22: 头部由近乎不透明的 windowBackgroundColor(0.96) 改为半透明毛玻璃，
        // 消除圆盘弹出后"大块不透明矩形遮屏"的观感，恢复通透效果。
        .background(.ultraThinMaterial)
    }
}

// MARK: - v2.7.15 Live Preview Content (all storable types)

struct RadialLivePreviewContent: View {
    @ObservedObject var store: SlotStoreObservable
    @State private var hoveredSlot: Int?
    @State private var previewPayload: RadialHoverPreviewPayload?
    // v2.9.18: 空态占位需要按深浅色取浅底，引入 colorScheme。
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let payload = previewPayload {
                // v2.7.59: when hovering a slot group in radial menu, use the
                // payload's content from the target group, not store.slots[slot]
                // which always reads from the current group.
                RadialUniversalPreview(content: payload.content,
                                       specialSlotId: payload.specialSlotId,
                                       slot: payload.slot)
                    .id("payload-\(payload.specialSlotId)-\(payload.slot)")
            } else if let slot = hoveredSlot,
                      let content = store.slots[slot],
                      // v2.11.0 hotfix2: 空槽也可能设了手动封面图（扇区已能显示），
                      // 这里同样放行，否则悬停这类槽位预览窗会整块留白。
                      !content.isEmpty || content.hasManualThumbnail {
                RadialUniversalPreview(content: content,
                                       specialSlotId: store.currentSpecialSlotId,
                                       slot: slot)
                    .id(slot)
            } else {
                // v2.9.25 hotfix5: 空态改为填满剩余空间的透明占位，保证内容区高度恒定，
                // 工具栏不会因为空态/悬停态切换而位移。视觉上保持空白（无图标、无文字）。
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .radialMenuHoveredSlotChanged)) { note in
            if let payload = note.userInfo?["preview"] as? RadialHoverPreviewPayload {
                previewPayload = payload
                hoveredSlot = nil
            } else {
                previewPayload = nil
                hoveredSlot = note.object as? Int
            }
        }
    }
}

// MARK: - v2.7.15 Universal Preview

private struct RadialUniversalPreview: View {
    let content: SlotContent
    /// v2.11.0 hotfix2：手动缩略图的字节按 `{组}/{槽}` 定址，所以预览窗必须知道自己在预览谁。
    /// 悬停「组」模式下这里是目标组 id + 该组首个非空槽位（与 payload 一致）。
    let specialSlotId: String
    let slot: Int

    /// 该槽位的手动封面图（id + 磁盘 URL）；未设置或字节缺失时为 nil → 完全维持原有预览逻辑。
    private var manualThumbnail: (id: String, url: URL)? {
        guard let id = content.manualThumbnailId, !id.isEmpty,
              let url = SpecialSlotStorage.shared.manualThumbnailURL(slot, in: specialSlotId) else { return nil }
        return (id, url)
    }

    var body: some View {
        // v2.11.1「附件预览」：主视觉区 + 底部附件条。
        //
        // 优先级（与用户约定的一致）：手动封面图 → 槽位主体内容 → 图片附件缩略图 → 文本 → 空。
        // 「图片附件」只在**主体为空**（items 为空、槽位只挂了附件）时上位当主视觉；主体有内容时
        // 主体永远占主视觉区，附件走底部那条 strip —— 否则用户存的正文会被一张随手带的截图挤下去。
        VStack(spacing: 0) {
            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !content.attachments.isEmpty {
                Divider().opacity(0.6)
                RadialAttachmentStrip(attachments: content.attachments)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var mainArea: some View {
        Group {
            if let manual = manualThumbnail {
                // v2.11.0 hotfix2：手动封面图优先级最高，与扇区侧 / 卡片侧（ThumbnailProvider）一致。
                //
                // 但预览窗和扇区的职责不同：扇区只需要「一眼认出是哪个槽」，预览窗还要能看清内容。
                // 所以这里不是简单替换，而是分两种形态：
                //  · 槽位有内容 → 封面图占顶部一条（高度自适应，上限 42% 且不超过 220pt），下面继续渲染原内容；
                //  · 空槽只有封面图 → 封面图铺满整个内容区（不再显示"空文本"卡片）。
                if content.isEmpty {
                    RadialManualThumbnailView(manualThumbnailId: manual.id, url: manual.url)
                        .padding(14)
                } else {
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            RadialManualThumbnailView(manualThumbnailId: manual.id, url: manual.url)
                                .frame(height: min(220, max(96, geo.size.height * 0.42)))
                                .padding(.horizontal, 14)
                                .padding(.top, 12)
                                .padding(.bottom, 8)
                            Divider().opacity(0.6)
                            contentPreview
                        }
                    }
                }
            } else if content.items.isEmpty, let hero = firstImageAttachment {
                // 主体空、只挂了附件：让第一张图片附件当主视觉，比一张空白文本卡片有用得多。
                RadialAttachmentImageView(attachment: hero, maxPixel: 1024, contentMode: .fit)
                    .padding(14)
            } else {
                contentPreview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 第一张「图片型」附件。用于主体为空时的主视觉兜底（走 Kit 的同一份 plan，口径与附件条一致）。
    private var firstImageAttachment: SlotContent.SlotAttachment? {
        let plan = RadialAttachmentPreviewPlanner.plan(
            imageFlags: content.attachments.map { RadialAttachmentKind.isImage($0) }
        )
        guard let index = plan.heroImageIndex else { return nil }
        return content.attachments[index]
    }

    @ViewBuilder
    private var contentPreview: some View {
        Group {
            if content.hasRenderableInlineImage {
                // ATT-2 (v2.10.32): decode the inline image off the main thread before
                // display. Previously this read `content.inlineImage` synchronously in
                // the body, so hovering a radial slot with a big pasted image decoded it
                // full-resolution on the main thread and janked the hover.
                RadialInlineImagePreview(content: content)
            } else if content.isImageFile, let url = content.primaryFileURL {
                RadialImageFilePreview(url: url)
            } else if content.isVideoFile, let url = content.primaryFileURL {
                RadialVideoPreview(url: url)
            } else if content.hasImage {
                // v2.10.85: 走到这里意味着内联图片只有 Finder 文件图标（icns），且这个文件
                // 既不是图片也不是视频（PDF / 压缩包 / 应用等）。这类文件的 Finder 图标本身
                // 常常带真实内容缩览，比纯图标卡片信息量更大，所以保留原来的图标渲染，
                // 只把"图片文件"这一类改走真实像素路径。
                RadialInlineImagePreview(content: content)
            } else if let html = content.preferredHTMLSourceForPreview {
                RadialHTMLPreview(html: html)
            } else if content.isHTMLDocument {
                RadialFileCardPreview(url: content.primaryFileURL ?? URL(fileURLWithPath: "/"), icon: "exclamationmark.triangle.fill", title: "HTML 原文缺失")
            } else if let url = content.primaryFileURL {
                RadialFileCardPreview(url: url, icon: content.isDirectoryLike ? "folder.fill" : "doc.fill", title: content.isDirectoryLike ? "文件夹" : "文件")
            } else {
                RadialTextPreview(text: content.bestTextForPreview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - v2.11.1 Attachment Preview (悬浮预览 Panel 的附件展示区)

/// 附件的「种类判定 + 语义图标」。
///
/// 为什么不直接用 `att.type`：`.file` 类附件里混着大量其实是图片/视频的东西（拖进来的 PNG、
/// 录屏 MOV），只看 type 会把它们全渲染成一个灰色文档图标。这里按扩展名的 UTType 再分一层，
/// 与附件面板 `AttachmentThumbnailProvider` 的判定口径一致。
enum RadialAttachmentKind {
    /// 是否「能出真实像素」的图片附件（图片型 + 扩展名 conforms to .image 的文件型）。
    ///
    /// 注意 `.file` 分支要求 `path` 非空：`AttachmentThumbnailProvider.previewImage` 对
    /// 文件型附件只认 `path`，没有 path 就永远解不出图，提前判 false 才不会让 panel 卡在 spinner。
    static func isImage(_ att: SlotContent.SlotAttachment) -> Bool {
        switch att.type {
        case .image:
            return true
        case .file:
            guard let path = att.path, !path.isEmpty else { return false }
            return AttachmentThumbnailProvider.isImage(URL(fileURLWithPath: path))
        default:
            return false
        }
    }

    /// 非图片附件的 SF Symbol。按 UTType 粗分音频 / 视频 / PDF / 压缩包 / 文本。
    static func icon(for att: SlotContent.SlotAttachment) -> String {
        switch att.type {
        case .text:      return "doc.text"
        case .url:       return "link"
        case .reference: return "arrow.triangle.branch"
        case .image:     return "photo"
        case .file:
            // path 缺失（外置字节 / 导入包只留了名字）时退回按附件名的扩展名判断。
            let ext = ((att.path?.isEmpty == false ? att.path! : att.name) as NSString)
                .pathExtension.lowercased()
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "doc" }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
            if type.conforms(to: .audio) { return "music.note" }
            if type.conforms(to: .image) { return "photo" }
            if type.conforms(to: .pdf) { return "doc.richtext" }
            if type.conforms(to: .archive) { return "archivebox" }
            if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
            if type.conforms(to: .plainText) || type.conforms(to: .text) { return "doc.text" }
            return "doc"
        }
    }
}

/// 预览窗里的附件条：图片附件出缩略图（最多 3 张），其余出「图标 + 文件名」小卡。
///
/// 数据来源全部是 `content.attachments` 这个**已在内存**的字段（缓存层把 data 置 nil 只留
/// storagePath）——和扇区角标同一条约定：**绝不**调 `store.attachments(for:)`（stat + queue.sync
/// 的主线程同步 I/O）。真要读字节时只走 `previewImage(for:)` 里的 path / storageFileURL，
/// 而且整个解码都在后台线程 + 全局 ThumbnailDecodeLimiter 限流下进行。
private struct RadialAttachmentStrip: View {
    let attachments: [SlotContent.SlotAttachment]

    /// 最多渲染几张图片缩略图。再多就折成「+N」——预览窗只有 360pt 宽，
    /// 也避免一次悬停就拉起十几个解码任务。
    private static let maxImageThumbnails = 3
    private static let thumbnailSide: CGFloat = 52

    var body: some View {
        // 「谁上缩略图 / 谁折成 +N / 谁走小卡」的选择交给 Kit 里的纯函数决定（有 smoke 断言兜底），
        // 这里只负责把计划渲染出来。
        let plan = RadialAttachmentPreviewPlanner.plan(
            imageFlags: attachments.map { RadialAttachmentKind.isImage($0) },
            maxImageThumbnails: Self.maxImageThumbnails
        )

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "paperclip")
                    .font(.system(size: 9, weight: .bold))
                Text("附件 \(attachments.count)")
                    .font(.system(size: 10, weight: .bold))
                Spacer(minLength: 0)
            }
            // v2.11.3：预览窗整体改走系统中性色，这里不再染品牌蓝紫。
            // （扇区上那枚 paperclip 角标仍保留品牌色 —— 那是圆盘本体的视觉锚点；
            //   预览窗则要尽量"隐形"，让内容本身说话。）
            .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(plan.imageIndices, id: \.self) { index in
                        RadialAttachmentImageView(attachment: attachments[index],
                                                  maxPixel: 128,
                                                  contentMode: .fill)
                            .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                            )
                            .help(attachments[index].name)
                    }

                    if plan.hiddenImageCount > 0 {
                        Text("+\(plan.hiddenImageCount)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                            .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.thinMaterial)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                            )
                            .help("另有 \(plan.hiddenImageCount) 张图片附件")
                    }

                    ForEach(plan.chipIndices, id: \.self) { index in
                        fileChip(attachments[index])
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(height: 92)
    }

    /// 非图片附件：图标 + 文件名（+ 类型名）小卡。
    private func fileChip(_ att: SlotContent.SlotAttachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: RadialAttachmentKind.icon(for: att))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(att.name.isEmpty ? att.type.displayName : att.name)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(att.type.displayName)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.thumbnailSide)
        .frame(maxWidth: 140)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .help(att.name)
    }
}

/// 单个图片附件的异步缩略图：spinner → 后台解码 → 替换；解码失败退回语义图标。
///
/// 解码走 `AttachmentThumbnailProvider.previewImage`（ImageIO 增量下采样，绝不整图解码），
/// 并复用全局 `ThumbnailDecodeLimiter` 限流，和网格缩略图 / 内联图预览共用同一份并发配额 ——
/// 快速划过多个带附件的扇区时不会瞬时拉起一堆解码抢 CPU。
private struct RadialAttachmentImageView: View {
    let attachment: SlotContent.SlotAttachment
    let maxPixel: CGFloat
    let contentMode: ContentMode

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                Image(systemName: RadialAttachmentKind.icon(for: attachment))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 附件 id 是 UUID，换槽 / 换附件必然换 id → 一定重新解码，不会串图。
        .task(id: attachment.id) {
            let att = attachment
            let px = maxPixel
            let decoded = await ThumbnailDecodeLimiter.shared.run {
                await Task.detached(priority: .userInitiated) { () -> NSImage? in
                    AttachmentThumbnailProvider.previewImage(for: att, maxPixel: px)
                }.value
            }
            guard !Task.isCancelled else { return }
            image = decoded
            failed = decoded == nil
        }
    }
}

// MARK: - v2.11.0 hotfix2 Manual Thumbnail Preview

/// 预览窗里的手动封面图：按可用区域等比缩放（fit，不裁切），圆角 + 细描边。
///
/// 为什么不直接复用扇区用的 `ManualThumbnailImage`：那条路走 `ManualThumbnailCache`，
/// 解码档位是 256px（够扇区 56pt 用），放到 360×480 的预览窗里会明显发虚。这里改成
/// 按 1024（= 手动缩略图入库时的最长边上限，等于原图）单独解码，同时把缓存里已有的
/// 256px 版本当作占位先顶上，避免悬停瞬间闪白。
private struct RadialManualThumbnailView: View {
    let manualThumbnailId: String
    let url: URL
    @State private var image: NSImage?
    @ObservedObject private var cache = ManualThumbnailCache.shared

    var body: some View {
        ZStack {
            if let shown = image ?? cache.cachedImage(id: manualThumbnailId) {
                Image(nsImage: shown)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 3)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // id 是内容寻址的（换图必换 UUID），所以换槽/换图都会重新触发解码，绝不串图。
        .task(id: manualThumbnailId) {
            let target = url
            let decoded = await ThumbnailDecodeLimiter.shared.run {
                await Task.detached(priority: .userInitiated) { () -> NSImage? in
                    ClipSlotsImageIO.downsampledImage(url: target, maxPixel: 1024)
                }.value
            }
            if !Task.isCancelled { image = decoded }
        }
    }
}

private struct RadialImagePreview: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ATT-2 (v2.10.32): async, off-main inline-image decoder for the radial hover
// preview. Mirrors RadialImageFilePreview's pattern (spinner → background decode →
// publish) so the same layout is preserved while the full-resolution decode of a
// big pasted image no longer runs on the main thread inside the view body.
private struct RadialInlineImagePreview: View {
    let content: SlotContent
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                RadialImagePreview(image: image)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: content.inlineImageIdentity) {
            let snapshot = content
            // P2 (v2.10.49): 径向悬停预览的内联图解码此前直接 Task.detached 全速解码，未经并发限流。
            // 快速扫视多个图片槽位时会瞬时并发拉起多个全尺寸解码，与网格缩略图争抢 CPU/内存。
            // 改为复用已有的全局 ThumbnailDecodeLimiter（2–6 并发上限），与网格/内联缩略图共用同一配额，
            // 削峰而不改变解码结果；decodedInlineImage 内部命中缓存时几乎瞬返。
            let decoded = await ThumbnailDecodeLimiter.shared.run {
                // 显式标注闭包返回类型为 NSImage?：`a ?? b` 两侧都是 Optional<NSImage>，
                // 但在无类型标注的 detached 闭包里会被推断成公共父类 NSObject?，导致回填 @State 时
                // 类型不匹配。与 ThumbnailProvider.load 中同款写法保持一致。
                await Task.detached(priority: .userInitiated) { () -> NSImage? in
                    // PERF-4 (v2.10.84): 内联（粘贴进来的）图片此前仍走 `decodedInlineImage()` 全尺寸解码，
                    // 而径向预览窗只有 360×480 —— 一张 8K 粘贴图会瞬时解出上百 MB 位图，快速扫视图片
                    // 槽位时反复制造 CPU/内存尖峰，既拖慢 hover 也挤压网格缩略图的解码配额。
                    //
                    // 同文件的**磁盘图片文件**路径早在 v2.10.35 (P1-6) 就改成了下采样（maxPixel: 2048
                    // + 失败回退全尺寸），只有这条内联路径被漏掉。这里对齐同一策略与同一上限，保持两条
                    // 预览路径行为一致。
                    //
                    // 观感无损：2048px 远超预览窗所需分辨率。缓存也不会串味——
                    // `decodedInlineThumbnail` 的缓存键含 maxPixel（"contentId::updatedAt::2048"），
                    // 与网格用的 512 版本各自独立；解码失败仍回退 `decodedInlineImage()`，即与改动前等价。
                    snapshot.decodedInlineThumbnail(maxPixel: 2048) ?? snapshot.decodedInlineImage()
                }.value
            }
            if !Task.isCancelled { image = decoded }
        }
    }
}

private struct RadialImageFilePreview: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                RadialImagePreview(image: image)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear {
            // v2.8.0 (perf M4): decode the on-disk image on a background queue so
            // hovering a radial slot that points at an image file no longer blocks
            // the main thread while a full-resolution NSImage decodes.
            guard image == nil else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                // P1-6 (v2.10.35): 磁盘图片文件此前用 NSImage(contentsOf:) 全尺寸解码（8K 图约 135MB
                // 瞬时占用），而径向预览窗仅 360×480。改走已有的 ClipSlotsImageIO 下采样帮助函数，
                // 只解码到 maxPixel，失败再回退全尺寸；仅改磁盘"图片文件"解码路径。
                let decoded = ClipSlotsImageIO.downsampledImage(url: url, maxPixel: 2048) ?? NSImage(contentsOf: url)
                DispatchQueue.main.async { image = decoded }
            }
        }
    }
}

// MARK: - v2.11.3 预览卡片统一磨砂背景

/// 预览窗内各类内容卡片（文本 / 文件 / HTML）的统一背景。
///
/// v2.11.3 之前用的是 `Color(NSColor.textBackgroundColor)` —— 亮色模式下就是**纯白且完全不透明**，
/// 一块白矩形直接糊在深色圆盘上，既突兀又把下层扇区完全挡死。
/// 现在换成系统 material：
///  · `.regularMaterial` 自带高斯模糊，下层圆盘内容能透上来但不干扰阅读；
///  · material 本身就是动态色，亮/暗模式自动适配，不再有任何硬编码白色；
///  · 额外压 0.88 不透明度，让通透感再上一档。
///
/// 关于 0.88 的施加位置：只压在**背景层**上，不是整卡 `.opacity(0.88)`。
/// 整卡压会连带把文字也降到 88%，本来就半透明的底上再叠淡文字，正文可读性会明显掉档；
/// 只压背景层即可拿到"背景更透"的观感，同时正文保持 100% 实心。
private struct RadialPreviewCardBackground: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(.regularMaterial).opacity(0.88))
            // 半透明底在浅色墙纸上边界会发虚，补一道极淡的中性描边把卡片轮廓勾出来。
            // 用 Color.primary 派生 → 亮/暗模式自动翻转，不引入任何彩色。
            .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
    }
}

private extension View {
    func radialPreviewCard(cornerRadius: CGFloat = 12) -> some View {
        modifier(RadialPreviewCardBackground(cornerRadius: cornerRadius))
    }
}

private struct RadialTextPreview: View {
    let text: String

    var body: some View {
        // v2.7.17: text preview gets its own adaptive background card.
        // The card size fits the text content, not the full window.
        ScrollView {
            Text(text.isEmpty ? "空文本" : text)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .radialPreviewCard()
        .padding(14)
        .animation(Anim.interactive, value: text)
    }
}

private struct RadialFileCardPreview: View {
    let url: URL
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            Text(url.deletingLastPathComponent().path)
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.75))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // v2.7.17: file preview also gets its own adaptive card.
        .radialPreviewCard()
        .padding(14)
        .animation(Anim.interactive, value: url)
    }
}

// MARK: - v2.7.19 Video Preview

private struct RadialVideoPreview: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                SafeAVPlayerView(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text("视频预览")
                        .font(.system(size: 13, weight: .semibold))
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                }
                .padding(18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92))
        .onAppear {
            if player == nil {
                let p = AVPlayer(url: url)
                player = p
                p.isMuted = true
                p.play()
            }
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - v2.7.22 Safe AVPlayerView Bridge
// Do NOT use SwiftUI.VideoPlayer here. On macOS 15.7.x the private
// _AVKit_SwiftUI framework can abort while instantiating generic metadata.
// Using AppKit AVPlayerView avoids the crashing SwiftUI wrapper.
private struct SafeAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

// MARK: - Deprecated image-only preview kept for compatibility

private struct RadialImageOnlyPreview: View {
    let content: SlotContent
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadImageIfNeeded() }
    }

    private func loadImageIfNeeded() {
        guard image == nil else { return }
        // ATT-2 (v2.10.32): decode inline images off the main thread as well. The old
        // code read `content.inlineImage` synchronously (both in the body and here),
        // decoding a full-resolution pasted image on the main thread.
        if content.hasRenderableInlineImage {
            let snapshot = content
            DispatchQueue.global(qos: .userInitiated).async {
                let decoded = snapshot.decodedInlineImage()
                DispatchQueue.main.async { if decoded != nil { image = decoded } }
            }
            return
        }
        guard content.isImageFile, let url = content.primaryFileURL else { return }
        // v2.8.0 (perf M4): decode off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            // P1-6 (v2.10.35): 同上，磁盘图片文件走 ClipSlotsImageIO 下采样解码，避免为小尺寸展示
            // 全分辨率解码巨图；失败回退 NSImage(contentsOf:)。仅改磁盘"图片文件"路径。
            let decoded = ClipSlotsImageIO.downsampledImage(url: url, maxPixel: 2048) ?? NSImage(contentsOf: url)
            DispatchQueue.main.async { if decoded != nil { image = decoded } }
        }
    }
}

// MARK: - v2.7.29 HTML Live Preview

private struct RadialHTMLPreview: View {
    let html: String
    var body: some View {
        HTMLWebLivePreview(html: html)
            .radialPreviewCard()
            .padding(14)
    }
}

private struct HTMLWebLivePreview: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        let wrapped = """
        <!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>html,body{margin:0;padding:12px;background:transparent;font:14px -apple-system,BlinkMacSystemFont,sans-serif;} img,video{max-width:100%;height:auto;} *{box-sizing:border-box;}</style></head><body>\(html)</body></html>
        """
        nsView.loadHTMLString(wrapped, baseURL: nil)
    }
}

// MARK: - v2.7.33 HTML Source Priority

private extension SlotContent {
    var preferredHTMLSourceForPreview: String? {
        if let htmlSource, !htmlSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return htmlSource }
        if let url = primaryFileURL, ["html", "htm"].contains(url.pathExtension.lowercased()),
           let html = try? String(contentsOf: url, encoding: .utf8) { return html }
        let raw = plainText ?? preview
        let lower = raw.lowercased()
        if lower.contains("<html") || lower.contains("<!doctype html") || lower.contains("<body") { return raw }
        return nil
    }
}

// MARK: - SlotContent Helper

private extension SlotContent {
    var bestTextForPreview: String {
        // v2.7.34: radial menu should preview the real stored text, not only the
        // short card summary. This fixes previews showing only "1. ... 2..."
        // or "[HTML]" when the underlying plainText/htmlSource exists.
        if let htmlSource, !htmlSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return htmlSource.strippingHTMLTagsForClipSlotsPreview()
        }
        if let plainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plainText
        }
        return preview
    }

    var isImageLikeForRadialPreview: Bool {
        // ATT-2 (v2.10.32): cheap type check instead of `inlineImage` (which fully decodes).
        hasImage || isImageFile
    }

    var isDirectoryLike: Bool {
        guard let url = primaryFileURL else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - v2.7.34 String HTML Stripping

private extension String {
    func strippingHTMLTagsForClipSlotsPreview() -> String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
