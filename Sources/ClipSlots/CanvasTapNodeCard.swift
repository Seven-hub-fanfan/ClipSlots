import SwiftUI
import ClipSlotsKit

/// **TapNow 形态的统一节点卡**（v2.16.0）。
///
/// ## 为什么把两张卡合成一张
///
/// v2.15.0 的分法是「槽位卡（文字主导） + 媒体卡（媒体主导）」，两张卡各有一套外框、标题行、
/// 提示词区、底部入参行。实测 TapNow 之后发现这个分法本身就是偏差的来源：**TapNow 的卡片没有
/// 任何内部结构**——没有标题栏、没有提示词条、没有底部功能行，就是一块圆角的内容。所有身份信息
/// （这是什么节点、叫什么名字）挂在卡片**外面上方**的一行小签上；所有操作藏在选中后浮出的工具条里。
///
/// 一旦内部结构清零，"文字主导 vs 媒体主导"就不成立了——剩下的差别只是**中间那块内容画什么**：
/// 有媒体画媒体、有文字画文字、什么都没有画一个 glyph。那是一个 `switch`，不是两个视图。
///
/// ## 自上而下（全部实测自 TapNow.app）
///
/// ```text
///   ┌ 工具条（选中才出现，浮在卡外上方 44pt）──────────────┐
///   └────────────────────────────────────────────────┘
///   [glyph] 节点名                        ← 名签，卡外上方 6pt，11pt #939393
///  ⊕┌──────────────────────────────────┐⊕   ← 左右端口，圆心距卡边 28pt
///   │                                  │     悬停 / 选中才出现
///   │            内容铺满               │
///   │                        [替换]     │   ← hover chip，卡内右上
///   │  ┌ 提示词（hover 时底部渐变浮出）  │
///   └──────────────────────────────────┘     圆角 12pt，**任何状态都没有描边**
/// ```
///
/// ## 卡片没有描边这件事，是实测出来的
///
/// idle / hover / 选中三张 Retina 截图在卡片边界处**逐像素完全相同**。我一开始以为看到了选中高亮环，
/// 那是图片亮部贴着纯黑底的错觉。选中与否完全靠"工具条 + 端口出现"表达。
/// 这一条很关键：只要给卡片补上描边，整体气质立刻从"内容"退回"控件"。
struct CanvasTapNodeCard: View {

    let node: CanvasNode
    let isSelected: Bool
    let isEditing: Bool
    let text: String
    /// 名签上的名字。沿用既有的 `pathLabel`（「未入库 · 2」/「灵感 · 3」这类）。
    let pathLabel: String
    let attachments: [SlotContent.SlotAttachment]
    let renderScale: CGFloat
    let textCounter: CGFloat
    let viewZoom: CGFloat
    /// 外部维持的 hover（拖过端口、操作条时不希望卡片认为鼠标已经离开）。
    let isHoverHeld: Bool
    /// 这个节点能不能"入库"（只有画布私有节点能）。
    let canArchive: Bool

    let onHoverChanged: (Bool) -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: (String) -> Void
    let onCancelEdit: () -> Void
    let onOpenFullscreen: (SlotContent.SlotAttachment) -> Void
    let onArchive: () -> Void

    @State private var isHovering = false
    @State private var draft = ""

    // MARK: - 缩放换算

    private func s(_ v: CGFloat) -> CGFloat { max(0.01, v * renderScale) }

    private func fs(_ v: CGFloat) -> CGFloat {
        CanvasScreenText.layoutFontSize(v, renderScale: renderScale)
    }

    private var hoverActive: Bool { isHovering || isHoverHeld }

    /// 节点在屏幕上太小就不写字（与旧卡同一规格）。
    private var textVisible: Bool {
        CanvasScreenText.textVisible(nodeSize: CGSize(width: node.width, height: node.height),
                                    zoom: viewZoom)
    }

    private var media: SlotContent.SlotAttachment? {
        CanvasMediaPick.primary(node: node, attachments: attachments)
    }

    private var isBusy: Bool {
        switch node.state {
        case .queued, .running: return true
        default: return false
        }
    }

    // MARK: - body

    var body: some View {
        content
            .frame(width: s(node.width), height: s(node.height))
            .background(cardFill)
            .clipShape(RoundedRectangle(cornerRadius: s(TapSkin.cardRadius), style: .continuous))
            .overlay(statusVeil)
            .overlay(alignment: .topTrailing) { hoverChips }
            // 信息角标的位置**随内容而变**，原因见 `infoBadge` 注释末尾那段。
            .overlay(alignment: media == nil ? .bottomLeading : .topLeading) { infoBadge }
            .overlay(alignment: .bottom) { promptVeil }
            .overlay(alignment: .topLeading) { nameTag }
            // 光标：卡片上是"可以抓起来"的开手，正在拖是握拳（握拳那一档由工作区在拖拽时接管）。
            .tapCursor(.openHand)
            .onHover { hovering in
                isHovering = hovering
                onHoverChanged(hovering)
            }
            .onChange(of: isEditing) { editing in
                if editing { draft = text }
            }
            .animation(TapSkin.stateAnim, value: hoverActive)
            .animation(TapSkin.stateAnim, value: isSelected)
    }

    // MARK: - 填充

    /// 有媒体时**不画填充**：媒体自己就是那块面，底下再垫一层灰只会在 aspect 不匹配的边缘露出来。
    @ViewBuilder
    private var cardFill: some View {
        if media != nil && !isEditing {
            Color.black
        } else if isSelected {
            TapSkin.cardEmptySelectedFill
        } else {
            TapSkin.cardEmptyFill
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if isEditing {
            promptEditor
        } else if let media {
            mediaBody(media)
        } else if !text.isEmpty {
            textBody
        } else {
            emptyGlyph
        }
    }

    /// 媒体铺满并裁切（TapNow 的招牌观感）。
    ///
    /// 用 `.fill` 而不是 `.fit`：TapNow 的卡片长宽比总是等于内容长宽比，所以它那边 fill 与 fit
    /// 没有区别；我们的节点尺寸是用户拖出来的，`.fit` 会在卡里留两条黑边，那两条黑边在纯黑画布上
    /// 看起来就是"卡片破了个口"。真实尺寸不会因此说不清——它在 hover 角标和全屏预览里都在。
    @ViewBuilder
    private func mediaBody(_ att: SlotContent.SlotAttachment) -> some View {
        ZStack {
            CanvasAttachmentPreviewImage(attachment: att, maxPixel: 900, contentMode: .fill)
                .frame(width: s(node.width), height: s(node.height))
                .clipped()
            if att.canvasIsVideoLike, !isBusy {
                // 视频的播放标记。实心白三角压在半透明黑圆上：视频首帧可能是任意亮度，
                // 纯白三角在雪景首帧上会消失。
                Image(systemName: "play.fill")
                    .font(.system(size: s(13)))
                    .foregroundColor(.white)
                    .padding(s(9))
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpenFullscreen(att) }
    }

    @ViewBuilder
    private var textBody: some View {
        Text(text)
            .font(CanvasFontCatalog.font(family: node.fontName,
                                         size: fs(node.resolvedBodyFontSize)))
            .foregroundColor(Color(red: 0.91, green: 0.91, blue: 0.91))
            .lineSpacing(s(2))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(s(12))
            .canvasStableLabel()
            .canvasScreenFixedText(textCounter, anchor: .topLeading)
            .opacity(textVisible ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onBeginEdit() }
    }

    @ViewBuilder
    private var emptyGlyph: some View {
        Image(systemName: node.kind.symbolName)
            .font(.system(size: s(TapSkin.cardEmptyGlyphSize), weight: .light))
            .foregroundColor(TapSkin.cardEmptyGlyph)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onBeginEdit() }
    }

    @ViewBuilder
    private var promptEditor: some View {
        // ★ v2.16.1：`draft` 必须在编辑器**出现时**也种一次，不能只靠下面那个
        // `onChange(of: isEditing)`。`onChange` 只在值**发生变化**时触发；如果卡片是在
        // 「已经处于编辑态」的情况下才被创建出来的，它一次都不会响。而这条路径真实存在：
        // 节点身份是 `groupId#slot`，槽位重排会 `rebindNode` 改 id，SwiftUI 于是销毁旧卡、
        // 建一张新卡 —— 新卡的 `draft` 是空串，`isEditing` 已经是 true，接着 `onBlur` 会拿
        // 这个空串去 `onCommitEdit`，把节点原有文字**整段清掉**。
        CanvasPromptEditor(text: $draft,
                           font: CanvasFontCatalog.nsFont(family: node.fontName,
                                                          size: max(0.01, fs(node.resolvedBodyFontSize))),
                           onCommit: { onCommitEdit(draft) },
                           onCancel: onCancelEdit,
                           onBlur: { onCommitEdit(draft) })
            .onAppear { draft = text }
            .padding(s(8))
    }

    // MARK: - 名签（卡外上方）

    @ViewBuilder
    private var nameTag: some View {
        CanvasNodeNameTag(symbol: node.kind.symbolName,
                          label: pathLabel,
                          isActive: hoverActive || isSelected,
                          cardWidth: node.width,
                          renderScale: renderScale,
                          textCounter: textCounter)
            .opacity(textVisible ? 1 : 0)
    }

    // MARK: - 信息角标（hover 才出现）

    /// 媒体的「尺寸 · 比例 · 时长 · 体积」，文本的「N 字」。
    ///
    /// ## 为什么从常驻改成 hover
    ///
    /// v2.15.0 这两个角标是常驻的（媒体卡右上角一直挂着 `1024×1024 · 1:1 · 1.2 MB`，文本卡右上角
    /// 一直挂着 `328 字`）。功能上没错 —— 用户明确要过"尺寸等媒体信息"。问题是**代价被低估了**：
    /// 一屏十几张卡，就是十几块小字压在内容的右上角，而 TapNow 那种"媒体墙"的观感恰恰来自
    /// 卡片上除了内容什么都没有。
    ///
    /// 改成 hover 之后信息一个字都没少（鼠标本来就要移过去才会去读它），静止画面却干净了。
    /// 这是本版反复用到的同一条取舍：**信息不删，但只在被需要的那一刻出现。**
    ///
    /// ## 为什么它的位置要分两种（媒体在上、文本在下）
    ///
    /// 第一版统一放左上角，装机一看就发现撞了：文本节点的正文也是从左上角开始排的，
    /// 于是「20 字」这块胶囊**正好压在第一行字上**，把用户真正想读的内容盖掉一截。
    ///
    /// 媒体节点没这个问题（媒体是整块图，左上角压掉的是画面边角，不是信息），而它的**底部**
    /// 归提示词浮层用。文本节点正相反：顶部是正文起点，底部是空的（短文本尤其）。
    /// 所以两者各让一边 —— 位置跟着"这张卡的哪一侧是空的"走，而不是图省事取一个统一值。
    @ViewBuilder
    private var infoBadge: some View {
        if hoverActive, !isEditing, textVisible, let line = infoLine {
            Text(line)
                .font(.system(size: fs(9.5), weight: .medium))
                .foregroundColor(TapSkin.chipInk)
                .padding(.horizontal, s(6))
                .padding(.vertical, s(2.5))
                .background(Capsule(style: .continuous).fill(TapSkin.chipFill))
                .canvasStableLabel()
                .canvasScreenFixedText(textCounter, anchor: .topLeading)
                .padding(s(TapSkin.chipInset))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private var infoLine: String? {
        if let media { return CanvasMediaProbe.badgeLine(for: media) }
        guard !text.isEmpty else { return nil }
        return "\(text.count) 字"
    }

    // MARK: - hover chips（卡内右上）

    /// TapNow 在这里放的是「替换」。我们这里放的是**这个节点此刻真正能做的两件事**：
    /// 全屏看（有媒体）与入库（还没进槽位库）。
    ///
    /// 只在 hover 时出现：常驻按钮会让每张卡上永远有两个灰点，而画布上一屏十几张卡，
    /// 二十个灰点就是噪声。
    @ViewBuilder
    private var hoverChips: some View {
        if hoverActive, !isEditing, textVisible {
            HStack(spacing: s(5)) {
                if canArchive {
                    chip("入库", glyph: "tray.and.arrow.down", action: onArchive)
                }
                if let media {
                    chip(nil, glyph: "arrow.up.left.and.arrow.down.right") { onOpenFullscreen(media) }
                }
            }
            .padding(s(TapSkin.chipInset))
            .transition(.opacity)
        }
    }

    private func chip(_ title: String?, glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: s(3)) {
                Image(systemName: glyph)
                    .font(.system(size: fs(TapSkin.chipFontSize), weight: .semibold))
                if let title {
                    Text(title)
                        .font(.system(size: fs(TapSkin.chipFontSize), weight: .medium))
                }
            }
            .foregroundColor(TapSkin.chipInk)
            .padding(.horizontal, s(8))
            .frame(height: s(TapSkin.chipHeight))
            .background(
                RoundedRectangle(cornerRadius: s(TapSkin.chipRadius), style: .continuous)
                    .fill(TapSkin.chipFill)
            )
        }
        .buttonStyle(.plain)
        .canvasScreenFixedText(textCounter, anchor: .topTrailing)
    }

    // MARK: - 提示词（hover 时从底部浮出）

    /// 提示词**不常驻**。
    ///
    /// TapNow 把提示词放在屏幕底部的独立输入条里，卡片上一个字都不写。直接照搬要动整套编辑流程，
    /// 折中是：平时不显示，hover 时从底部渐变浮出一行。这样静止画面是干净的媒体墙，
    /// 而"这张图是用什么提示词出来的"仍然一抬手就能看到。
    @ViewBuilder
    private var promptVeil: some View {
        if hoverActive, !isEditing, !text.isEmpty, media != nil, textVisible {
            HStack(spacing: 0) {
                Text(text)
                    .font(.system(size: fs(10.5)))
                    .foregroundColor(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, s(10))
            .padding(.bottom, s(8))
            .padding(.top, s(18))
            .background(
                LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.72)],
                               startPoint: .top, endPoint: .bottom)
            )
            .canvasStableLabel()
            .canvasScreenFixedText(textCounter, anchor: .bottomLeading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onBeginEdit() }
            .transition(.opacity)
        }
    }

    // MARK: - 状态遮罩

    /// 生成中 / 失败的覆盖层。
    ///
    /// 生成中**保留旧图**只加一层薄雾：把卡片清空成灰块会让用户以为"上一版丢了"，而重跑失败时
    /// 上一版其实还在磁盘上。
    @ViewBuilder
    private var statusVeil: some View {
        switch node.state {
        case .queued:
            veil(Color.black.opacity(0.3)) {
                Text("排队中")
                    .font(.system(size: fs(10), weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
        case .running(let startedAt):
            veil(Color.black.opacity(0.34)) {
                VStack(spacing: s(6)) {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                    RunningBadge(startedAt: startedAt,
                                 renderScale: renderScale,
                                 textCounter: textCounter,
                                 viewZoom: viewZoom)
                }
            }
        case .failed(let message):
            veil(Color.black.opacity(0.52)) {
                VStack(spacing: s(4)) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: fs(13)))
                        .foregroundColor(.orange)
                    Text(message)
                        .font(.system(size: fs(9.5)))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, s(8))
                }
                .canvasScreenFixedText(textCounter, anchor: .center)
            }
        default:
            EmptyView()
        }
    }

    private func veil<Content: View>(_ fill: Color,
                                     @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: s(TapSkin.cardRadius), style: .continuous)
                .fill(fill)
            if textVisible { content() }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 节点名签

/// 卡片**外面上方**那一行「图标 + 名字」。
///
/// ## 为什么名字必须在卡外
///
/// TapNow 的卡片里一个字都没有，节点叫什么写在卡片上方的小签上。这不只是排版偏好 ——
/// 名字一旦进到卡里，就得从内容区切一条 13~20pt 的横带给它，而那条横带在**每一张卡**上都要切，
/// 于是"卡片 = 一块内容"变成"卡片 = 一个带标题的控件"。这是 v2.15.0 观感偏工具感的主因之一。
///
/// ## 为什么用 overlay + offset 而不是 VStack
///
/// 节点的 `frame` 就是它在画布坐标系里的矩形：连线端点、命中判定、框选、最小化阈值全都按这个
/// 矩形算。`VStack { tag; card }` 会把名签高度并进 frame，于是"节点有多高"在数据模型和屏幕之间
/// 差了 20pt —— 症状是连线接在名签上、框选框比卡片高一截、拖动时命中区偏移。
/// `overlay` + 负 `offset` 让名签在视觉上跑到卡外，而 frame 一动不动。
///
/// 抽成独立视图是因为它有**两个消费者**：`CanvasTapNodeCard`（文本/媒体）与
/// `CanvasNodeCardView`（槽位）。两张卡内部结构完全不同，但名签必须逐像素一致 ——
/// 它是用户判断"这两个是同一类东西"的主要线索。
struct CanvasNodeNameTag: View {
    let symbol: String
    let label: String
    let isActive: Bool
    /// 卡片宽度（画布坐标）。名签最多和卡片一样宽，超出中间截断。
    let cardWidth: CGFloat
    let renderScale: CGFloat
    let textCounter: CGFloat

    private func s(_ v: CGFloat) -> CGFloat { max(0.01, v * renderScale) }
    private func fs(_ v: CGFloat) -> CGFloat {
        CanvasScreenText.layoutFontSize(v, renderScale: renderScale)
    }

    var body: some View {
        HStack(spacing: s(4)) {
            Image(systemName: symbol)
                .font(.system(size: fs(TapSkin.tagGlyphSize), weight: .medium))
            Text(label)
                .font(.system(size: fs(TapSkin.tagFontSize), weight: .regular))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundColor(isActive ? TapSkin.tagInkActive : TapSkin.tagInk)
        .frame(maxWidth: s(cardWidth), alignment: .leading)
        .canvasStableLabel()
        .canvasScreenFixedText(textCounter, anchor: .bottomLeading)
        .offset(y: -s(TapSkin.tagGap + TapSkin.tagHeight))
        .help(label)
        // 名签不吃事件：它悬在卡片外面，若能命中就会在卡片上方多出一条"点不到卡但也不是空白"的
        // 死区 —— 而那里正是用户去点操作条的路径。
        .allowsHitTesting(false)
    }
}
