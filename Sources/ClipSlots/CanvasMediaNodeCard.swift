import SwiftUI
import ClipSlotsKit

/// 画布**媒体节点卡片**（图片 / 视频，v2.15.0）。
///
/// ## 它为什么不是 `CanvasNodeCardView` 里的一个分支
///
/// 通用槽位卡（`CanvasNodeCardView`）的主角是文字：预览区被钉在节点高度 34% 以内，节点拖高多出来
/// 的空间全部进 4 行正文预览。用户这一轮要的恰恰相反 —— 参考 TapNow，图片 / 视频节点上**媒体应该
/// 占满整张卡**，提示词收成底部一条摘要。这两套优先级共用一个视图就要在预算、正文行数、预览高度、
/// 点击语义四处各写一个 `if`，而这四处都有 smoke 断言或用户逐条指定的比例约束盯着。
///
/// 所以它是一张独立的卡，配一张独立的预算表（`CanvasMediaCardLayout`）。两张卡共享的只有
/// 「卡片外框 / 字号抵消缩放 / 附件缩略图缓存」这几样本来就已经抽出去的东西。
///
/// ## 自上而下
///
/// ```text
///   路径标识行（居中）＋ 左侧状态角标 ＋ 右侧类型图标
///   ┌────────────────────────────────┐
///   │            媒体区               │  ← 吃掉全部剩余高度；aspect-fit 不裁切
///   │   [尺寸 · 比例 · 时长 · 体积]    │  ← 左下悬浮角标（hover 才亮到满不透明）
///   │                      [⤢ 全屏]  │  ← 右上，hover 才出现
///   └────────────────────────────────┘
///   提示词摘要（单行，点击编辑）  ＋ 入参文件
/// ```
///
/// ## 编辑态为什么把媒体区整个换成编辑器
///
/// 底部提示词条只有 20pt（1x），在里面直接编辑等于在一条缝里打字。而"正在改提示词"的时候用户
/// 看的是文字不是图，把媒体区让出来是零损失的交换 —— 这比另开一个浮层简单得多，也不会出现
/// "浮层挡住了我想参照的那张图"。
struct CanvasMediaNodeCard: View {

    let node: CanvasNode
    let isSelected: Bool
    let isEditing: Bool
    /// 提示词实时值（= 槽位主体文本）。取数留在上层，理由同 `CanvasNodeCardView`。
    let text: String
    /// `页面 - 槽位组 - 槽位`，由上层用 `CanvasCardText.pathLabel` 拼好。
    let pathLabel: String
    let attachments: [SlotContent.SlotAttachment]
    let renderScale: CGFloat
    var textCounter: CGFloat = 1
    var viewZoom: CGFloat = 1
    /// 上层按屏幕坐标维持的 hover（光标正伸向卡片外的操作条时不算离开）。
    let isHoverHeld: Bool

    let onHoverChanged: (Bool) -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: (String) -> Void
    let onCancelEdit: () -> Void
    let onOpenInputFiles: () -> Void
    /// 打开全屏预览。传附件而不是节点：一个节点可能有多份产物，点的是哪一份由卡片决定。
    let onOpenFullscreen: (SlotContent.SlotAttachment) -> Void
    let onActivateNode: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false
    @State private var draft = ""

    // MARK: - 缩放换算

    private func s(_ v: CGFloat) -> CGFloat { max(0.01, v * renderScale) }

    /// 字号刻意不乘 renderScale，推导见 `CanvasScreenText`。
    private func fs(_ v: CGFloat) -> CGFloat {
        CanvasScreenText.layoutFontSize(v, renderScale: renderScale)
    }

    private var hoverActive: Bool { isHovering || isHoverHeld }

    /// 节点在屏幕上太小就不写字（与通用卡同一规格，避免两种卡的文字在同一缩放下一个有一个没有）。
    private var textOpacity: Double {
        CanvasScreenText.textVisible(nodeSize: CGSize(width: node.width, height: node.height),
                                    zoom: viewZoom) ? 1 : 0
    }

    // MARK: - 预算

    /// 内容区可用高度 = 节点排版高 − 上下内边距。
    private var contentHeight: CGFloat {
        max(0, s(node.height) - 2 * s(CanvasMediaCardLayout.cardPadding))
    }

    private var plan: CanvasMediaCardLayout.Plan {
        CanvasMediaCardLayout.plan(availableHeight: contentHeight,
                                   renderScale: renderScale,
                                   headerFontSize: 9.5,
                                   promptFontSize: 9.5)
    }

    // MARK: - 媒体来源

    /// 这张卡要展示哪一份媒体。
    ///
    /// 优先级：**产物**（`outputAttachmentIds` 里最后一个，即最新一次生成）> 第一个同类媒体附件。
    ///
    /// 为什么产物优先而不是"列表第一个"：媒体节点通常同时挂着入参（参考图 / 首帧）和产物，
    /// 而入参往往是先加进去的、排在前面。展示入参图会让人误以为"生成出来就是这样"。
    ///
    /// 为什么退而求其次要看普通附件：App 重启后 `node.state` 回到 `.idle`（状态不持久化），
    /// 若只认 `.succeeded` 就会出现"重启后所有图都不见了"。产物在磁盘上，它才是真相。
    private var primaryMedia: SlotContent.SlotAttachment? {
        CanvasMediaPick.primary(node: node, attachments: attachments)
    }

    /// 空态占位框要画成什么比例。
    ///
    /// 取节点参数里的 `ratio`：用户选了 `9:16` 就该看到一个竖的空框。解析不出来退成 1:1
    /// （而不是铺满整个媒体区）—— 铺满会让"有内容"和"没内容"在形状上无法区分。
    private var placeholderRatio: CGSize {
        CanvasMediaInfo.size(fromRatioString: node.ratio) ?? CGSize(width: 1, height: 1)
    }

    // MARK: - body

    var body: some View {
        VStack(spacing: plan.spacing) {
            if plan.showHeader { headerRow }
            mediaArea
                .frame(height: plan.mediaHeight)
            if plan.showPrompt { promptStrip }
        }
        .padding(s(CanvasMediaCardLayout.cardPadding))
        .frame(width: s(node.width), height: s(node.height), alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: s(14), style: .continuous)
                .fill(AppTheme.cardBackground(isEmpty: false))
        )
        .overlay(
            RoundedRectangle(cornerRadius: s(14), style: .continuous)
                .stroke(borderColor, lineWidth: s(isSelected ? 1.6 : 1))
        )
        .shadow(color: AppTheme.cardShadow(isEmpty: false),
                radius: s(isSelected ? 12 : 7),
                x: 0, y: s(isSelected ? 5 : 3))
        .onHover {
            isHovering = $0
            onHoverChanged($0)
        }
        .onChange(of: isEditing) { editing in
            if editing { draft = text }
        }
        .onAppear { draft = text }
    }

    private var borderColor: Color {
        if isEditing { return AppTheme.chromeAccentInk }
        if isSelected { return AppTheme.chromeAccentInk.opacity(0.85) }
        if hoverActive { return AppTheme.minimalCardHoverBorder }
        return AppTheme.subtleBorder
    }

    // MARK: - 顶部

    /// 路径标识居中 + 左状态角标 + 右类型图标。
    ///
    /// 居中那段用 `overlay` 而不是 `HStack` 的第二格：左右两侧宽度会变（"前方 3" 比 "失败" 宽），
    /// HStack 会让中间那段跟着左右晃。这条经验直接来自通用卡的 `headerRow`。
    private var headerRow: some View {
        Text(pathLabel)
            .font(.system(size: fs(9.5), weight: .semibold))
            .foregroundColor(AppTheme.canvasCardMetaInk)
            .lineLimit(1)
            .truncationMode(.middle)
            .canvasStableLabel()
            .canvasScreenFixedText(textCounter)
            .opacity(textOpacity)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) { statusBadge }
            .overlay(alignment: .trailing) {
                Image(systemName: node.kind.symbolName)
                    .font(.system(size: s(9), weight: .semibold))
                    .foregroundColor(AppTheme.canvasCardMetaInk.opacity(0.65))
            }
            .frame(height: plan.headerHeight)
    }

    /// 状态角标。`idle` 不显示任何东西（v2.11.8 二轮用户要求去掉"未生成"）。
    @ViewBuilder
    private var statusBadge: some View {
        switch node.state {
        case .idle:
            EmptyView()
        case .queued(let ahead):
            Label(ahead > 0 ? "前方 \(ahead)" : "排队", systemImage: "clock")
                .font(.system(size: fs(9), weight: .medium))
                .foregroundColor(AppTheme.canvasCardMetaInk)
                .canvasScreenFixedText(textCounter, anchor: .leading)
                .opacity(textOpacity)
        case .running(let startedAt):
            RunningBadge(startedAt: startedAt,
                         renderScale: renderScale,
                         textCounter: textCounter,
                         textOpacity: textOpacity)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: s(9), weight: .semibold))
                .foregroundColor(.green.opacity(0.85))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: s(9), weight: .semibold))
                .foregroundColor(.red.opacity(0.85))
        }
    }

    // MARK: - 媒体区

    private var mediaWellShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: s(CanvasMediaCardLayout.mediaCornerRadius), style: .continuous)
    }

    /// 媒体井的底色。
    ///
    /// 比卡片背景更深一档（浅色主题下也压暗）：媒体是 aspect-fit 的，四周一定有留白，
    /// 留白与卡片同色时图片会显得"漂"在卡片上、边界含糊；压暗一档就读作"这是一个画框"。
    /// 深色主题下反而要更黑 —— 深色卡片本身已经不亮，井要更黑才分得开。
    private var mediaWellFill: Color {
        scheme == .dark ? Color.black.opacity(0.32) : Color.black.opacity(0.055)
    }

    @ViewBuilder
    private var mediaArea: some View {
        ZStack {
            mediaWellShape.fill(mediaWellFill)

            if isEditing {
                promptEditor
            } else if let media = primaryMedia {
                mediaContent(media)
            } else {
                emptyPlaceholder
            }
        }
        .clipShape(mediaWellShape)
        .overlay(
            mediaWellShape
                .stroke(AppTheme.subtleBorder.opacity(scheme == .dark ? 0.5 : 0.7),
                        lineWidth: s(0.8))
        )
        .frame(maxWidth: .infinity)
    }

    /// 有媒体时的媒体区：图 + 左下信息角标 + 视频播放标记 + 右上全屏按钮。
    @ViewBuilder
    private func mediaContent(_ media: SlotContent.SlotAttachment) -> some View {
        ZStack {
            CanvasAttachmentPreviewImage(attachment: media,
                                         maxPixel: 720,
                                         contentMode: .fit)
                .allowsHitTesting(false)

            // 生成中 / 排队：盖一层薄雾 + 转圈。不隐藏旧图 —— 用户重跑一个节点时最想对比的就是
            // "上一版是什么样"，把它抹掉换成空框等于在生成期间剥夺参照物。
            if isBusy {
                ZStack {
                    Color.black.opacity(0.35)
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(min(1.4, max(0.7, renderScale)))
                }
                .allowsHitTesting(false)
            }

            if case .failed(let reason) = node.state {
                failureOverlay(reason)
            }
        }
        .contentShape(mediaWellShape)
        .onTapGesture(count: 2) { onOpenFullscreen(media) }
        .onTapGesture { onActivateNode() }
        .overlay(alignment: .bottomLeading) { infoBadge(media) }
        .overlay(alignment: .center) {
            if media.canvasIsVideoLike, !isBusy { playGlyph(media) }
        }
        .overlay(alignment: .topTrailing) {
            if hoverActive, !isBusy { fullscreenButton(media) }
        }
    }

    private var isBusy: Bool {
        switch node.state {
        case .queued, .running: return true
        default: return false
        }
    }

    /// 媒体信息角标：`1024×1024 · 1:1 · 2.4 MB`（视频还带时长）。
    ///
    /// 静息时压到 0.72 不透明度：它是**查阅信息**而不是内容，常驻满不透明会跟图抢注意力；
    /// hover 时提到满，因为那一刻用户正是在"仔细看这个节点"。
    ///
    /// 量不到任何一项就整体不画 —— 一个空的深色小条只会让人以为是渲染残留。
    @ViewBuilder
    private func infoBadge(_ media: SlotContent.SlotAttachment) -> some View {
        let line = CanvasMediaProbe.badgeLine(for: media)
        if !line.isEmpty, textOpacity > 0 {
            Text(line)
                .font(.system(size: fs(8.5), weight: .medium))
                .foregroundColor(.white.opacity(0.95))
                .canvasStableLabel()
                .lineLimit(1)
                .padding(.horizontal, s(5))
                .padding(.vertical, s(2.5))
                .background(
                    Capsule(style: .continuous).fill(Color.black.opacity(0.55))
                )
                .canvasScreenFixedText(textCounter, anchor: .bottomLeading)
                .opacity(hoverActive ? 1 : 0.72)
                .padding(s(CanvasMediaCardLayout.badgeInset))
                .allowsHitTesting(false)
        }
    }

    /// 视频的播放标记。
    ///
    /// 刻意**不**在卡片里内嵌 `AVPlayerView`：一屏十几个节点同时解码会把画布拖垮，而且缩放时
    /// 播放器图层与 SwiftUI 的变换会错位（这条在 `CanvasNodeCardView` 的注释里已经踩过）。
    /// 卡片上只画首帧 + 一个明确的播放按钮，真要看就去全屏。
    private func playGlyph(_ media: SlotContent.SlotAttachment) -> some View {
        Button { onOpenFullscreen(media) } label: {
            ZStack {
                Circle().fill(Color.black.opacity(0.42))
                Image(systemName: "play.fill")
                    .font(.system(size: s(13), weight: .semibold))
                    .foregroundColor(.white)
                    .offset(x: s(1))
            }
            .frame(width: s(34), height: s(34))
        }
        .buttonStyle(.plain)
        .help("全屏播放")
    }

    /// 右上角全屏按钮（hover 才出现）。
    private func fullscreenButton(_ media: SlotContent.SlotAttachment) -> some View {
        Button { onOpenFullscreen(media) } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: s(9), weight: .semibold))
                .foregroundColor(.white)
                .padding(s(5))
                .background(Circle().fill(Color.black.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .padding(s(CanvasMediaCardLayout.badgeInset))
        .help("全屏查看（也可双击媒体）")
    }

    private func failureOverlay(_ reason: String) -> some View {
        VStack(spacing: s(4)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: s(15), weight: .semibold))
                .foregroundColor(.red.opacity(0.85))
            Text(reason)
                .font(.system(size: fs(8.5), weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .canvasStableLabel()
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .canvasScreenFixedText(textCounter)
                .opacity(textOpacity)
        }
        .padding(s(8))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55))
        .allowsHitTesting(false)
    }

    /// 空态：按 `node.ratio` 画一个虚线占位框 + 类型图标 + 一句话。
    private var emptyPlaceholder: some View {
        GeometryReader { geo in
            let box = CanvasMediaCardLayout.fittedSize(
                content: placeholderRatio,
                in: CGSize(width: geo.size.width - s(16), height: geo.size.height - s(16))
            )
            ZStack {
                RoundedRectangle(cornerRadius: s(6), style: .continuous)
                    .strokeBorder(AppTheme.canvasCardMetaInk.opacity(0.45),
                                  style: StrokeStyle(lineWidth: s(1),
                                                     dash: [s(4), s(3)]))
                    .frame(width: max(s(12), box.width), height: max(s(12), box.height))
                VStack(spacing: s(4)) {
                    Image(systemName: node.kind == .video ? "film" : "photo")
                        .font(.system(size: s(16), weight: .light))
                        .foregroundColor(AppTheme.canvasCardMetaInk.opacity(0.75))
                    Text(node.kind == .video ? "还没有视频" : "还没有图片")
                        .font(.system(size: fs(9), weight: .medium))
                        .foregroundColor(AppTheme.canvasCardMetaInk)
                        .canvasStableLabel()
                        .canvasScreenFixedText(textCounter)
                        .opacity(textOpacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .contentShape(Rectangle())
        .onTapGesture { onActivateNode() }
    }

    // MARK: - 编辑器

    private var promptEditor: some View {
        CanvasPromptEditor(text: $draft,
                           font: CanvasFontCatalog.nsFont(family: node.fontName,
                                                          size: max(0.01, fs(node.resolvedBodyFontSize))),
                           onCommit: { onCommitEdit(draft) },
                           onCancel: onCancelEdit,
                           onBlur: { onCommitEdit(draft) })
            .padding(s(6))
    }

    // MARK: - 底部提示词条

    /// 单行提示词摘要 + 入参文件入口。
    ///
    /// 两者挤在一行是刻意的：媒体卡的纵向预算全给了媒体区，底部只剩一行的额度。提示词拿走
    /// 弹性宽度、入参文件收成一个带计数的图标 —— 后者是"有没有、几个"的问题，不需要文字。
    private var promptStrip: some View {
        HStack(spacing: s(6)) {
            Button(action: onBeginEdit) {
                HStack(spacing: s(4)) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: s(8.5), weight: .semibold))
                        .foregroundColor(AppTheme.canvasCardMetaInk.opacity(0.7))
                    Text(promptSummary)
                        .font(.system(size: fs(9.5), weight: .regular))
                        .foregroundColor(text.isEmpty
                                         ? AppTheme.canvasCardMetaInk.opacity(0.75)
                                         : AppTheme.canvasChromeInk)
                        .canvasStableLabel()
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .canvasScreenFixedText(textCounter, anchor: .leading)
                        .opacity(textOpacity)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(text.isEmpty ? "点击写提示词" : text)

            Button(action: onOpenInputFiles) {
                HStack(spacing: s(3)) {
                    Image(systemName: attachments.isEmpty ? "tray" : "tray.full")
                        .font(.system(size: s(9), weight: .semibold))
                    if !attachments.isEmpty {
                        Text("\(attachments.count)")
                            .font(.system(size: fs(9), weight: .semibold))
                            .canvasStableLabel()
                            .canvasScreenFixedText(textCounter, anchor: .trailing)
                            .opacity(textOpacity)
                    }
                }
                .foregroundColor(AppTheme.canvasCardMetaInk)
                .padding(.horizontal, s(5))
                .padding(.vertical, s(2))
                .background(
                    Capsule(style: .continuous)
                        .fill(AppTheme.canvasCardMetaInk.opacity(hoverActive ? 0.12 : 0.07))
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help("入参文件")
        }
        .frame(height: plan.promptHeight)
    }

    /// 提示词摘要：把换行压成空格。
    ///
    /// 不压的话单行 `Text` 会在第一个换行处截断，屏幕上看起来像"提示词只有一个词"——
    /// 而多行提示词（分镜、参数逐行写）在这个项目里非常常见。
    private var promptSummary: String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.isEmpty ? "点这里写提示词…" : flat
    }
}
