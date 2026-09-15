import SwiftUI
import AppKit
import ClipSlotsKit

/// 槽位节点的「扇形堆叠卡片」（v2.11.8 · 对齐 Crate 画布）。
///
/// 取代此前预览区里那张**单图**。单图的问题不是不好看，是**说了谎**：一个槽位可以挂 4 个入参
/// 文件、可以是三段文字，卡片上却只画第一张图 —— 用户在画布上根本看不出这个槽位到底装了几件
/// 东西，得点开入参文件面板才知道。堆叠卡片把「数量」变成了视觉信息。
///
/// ## 三态
///   - **收拢**：2~4 张卡叠着，略微错位 + 轻微旋转，后卡下沉，右下角一个 + 角标。
///   - **整节点 hover → 展开**：以底边中心为轴向左右扇开，一眼看全每张卡的内容。
///   - **单卡 hover**：抬起 8pt、放大 1.08、Z 层提到最上（不提 Z 层的话放大的那 8% 会被邻卡切掉）。
///
/// ## 刻意的取舍
///   - **展开只是视觉溢出，不改布局**。卡片全部走 `offset`/`rotationEffect`（渲染期变换），
///     容器尺寸恒为预览区大小 —— 否则 hover 一张卡就会把下面的正文、参数栏往下推，
///     一屏十几个节点时整个画布会随鼠标"呼吸"。
///   - **角度关于中轴严格对称**（几何在 `CanvasFanGeometry`，可被 smoke 断言）：视觉重心不随
///     张数奇偶左右跳动。
///   - **卡片自己不认识 store**。改数据的三件事（编辑正文 / 打开入参面板 / 置为首个入参）全部
///     以闭包上抛，与 `CanvasNodeCardView` 的既有约定一致。
struct CanvasSlotFanStack: View {

    /// 每张卡的内容来源（由 `CanvasFanGeometry.cardSources` 定，图片附件优先、其次正文分段、都没有=空卡）。
    let sources: [CanvasFanGeometry.CardSource]
    /// 槽位的完整附件列表。`sources` 里的 `attachmentIndex` 是它的下标。
    let attachments: [SlotContent.SlotAttachment]
    /// 当前缩放（= 画布 zoom）。所有尺寸乘它，保证放大后是**重新排版**而不是位图拉伸。
    let renderScale: CGFloat
    /// 整个节点是否被悬停（展开的唯一开关）。
    let nodeHovered: Bool
    /// 预览区可用高度（1x）。卡片按它收敛，避免在小节点上戳出卡片外。
    let boxHeight: CGFloat

    let onEditText: () -> Void
    let onOpenInputFiles: () -> Void
    /// 把第 N 个附件挪到列表首位。首位 = 缩略图/圆盘取的那一张，所以这件事等于"设为主入参"。
    let onPromoteInput: (Int) -> Void
    let onToast: (String) -> Void

    @State private var hoveredCard: Int? = nil
    /// 打开了操作气泡的卡片下标。
    @State private var openedCard: Int? = nil

    /// 展开动画。用户明确指定的参数，不要顺手改成 `Anim.transition`。
    private static let fanSpring = Animation.spring(response: 0.35, dampingFraction: 0.72)

    private var expanded: Bool { nodeHovered }

    private func s(_ v: CGFloat) -> CGFloat { max(0.01, v * renderScale) }

    /// 卡片尺寸（1x）。比预览区窄一圈：扇开时靠旋转向两侧溢出，卡片本身再宽就会把邻卡完全盖住。
    private var cardSize: CGSize {
        let h = min(132, max(64, boxHeight - 10))
        return CGSize(width: h * 0.82, height: h)
    }

    private var layouts: [CanvasFanGeometry.CardLayout] {
        CanvasFanGeometry.layouts(count: sources.count,
                                  expanded: expanded,
                                  hoveredIndex: hoveredCard)
    }

    var body: some View {
        ZStack {
            ForEach(layouts, id: \.index) { layout in
                cardView(layout)
            }

            if let opened = openedCard {
                actionBubble(for: opened)
                    .zIndex(500)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // hover 离开整个节点时把气泡收掉：留一个悬在别处的黑气泡会被当成渲染残留。
        .onChange(of: nodeHovered) { hovering in
            if !hovering {
                hoveredCard = nil
                openedCard = nil
            }
        }
        // 内容变了（切槽位 / 附件增删）就重置交互态，否则 openedCard 会指向一张已经不存在的卡。
        .onChange(of: sources.count) { _ in
            hoveredCard = nil
            openedCard = nil
        }
    }

    // MARK: - 单张卡片

    private func cardView(_ layout: CanvasFanGeometry.CardLayout) -> some View {
        let source = sources.indices.contains(layout.index) ? sources[layout.index] : .empty
        return cardBody(source)
            .frame(width: s(cardSize.width), height: s(cardSize.height))
            .background(
                RoundedRectangle(cornerRadius: s(17), style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: s(17), style: .continuous)
                    .stroke(Color.white, lineWidth: s(2.6))
            )
            // 卡片边缘再压一道极淡的灰线：纯白卡叠在浅色预览底上时，白描边本身是看不见的，
            // 少了这道线整叠卡会糊成一团。
            .overlay(
                RoundedRectangle(cornerRadius: s(17), style: .continuous)
                    .stroke(Color.black.opacity(0.10), lineWidth: s(0.6))
            )
            .shadow(color: Color.black.opacity(hoveredCard == layout.index ? 0.26 : 0.16),
                    radius: s(hoveredCard == layout.index ? 9 : 5),
                    x: 0, y: s(hoveredCard == layout.index ? 5 : 2.5))
            .overlay(alignment: .bottomTrailing) {
                // + 角标只挂在最前面那张（收拢态下也只有它露着），展开后隐掉：
                // 4 个 + 号一起出现会让人以为每张卡各能加东西。
                if layout.index == sources.count - 1, !expanded {
                    plusBadge
                }
            }
            .scaleEffect(layout.scale, anchor: .bottom)
            .rotationEffect(.degrees(layout.angle), anchor: .bottom)
            .offset(x: s(layout.offset.width), y: s(layout.offset.height))
            .zIndex(layout.zIndex)
            .animation(CanvasSlotFanStack.fanSpring, value: expanded)
            .animation(CanvasSlotFanStack.fanSpring, value: hoveredCard)
            .onHover { inside in
                // 收拢态不做单卡 hover：卡片几乎完全重叠，此时"单卡放大"只会让最前面那张
                // 无缘无故抖一下，用户根本分不清自己指的是哪一张。
                guard expanded else { return }
                if inside {
                    hoveredCard = layout.index
                } else if hoveredCard == layout.index {
                    hoveredCard = nil
                }
            }
            .onTapGesture {
                withAnimation(CanvasSlotFanStack.fanSpring) {
                    openedCard = (openedCard == layout.index) ? nil : layout.index
                }
            }
    }

    @ViewBuilder
    private func cardBody(_ source: CanvasFanGeometry.CardSource) -> some View {
        switch source {
        case .attachmentIndex(let idx):
            if attachments.indices.contains(idx) {
                // 用 Color.clear 定尺 + overlay 承载图片 + clipped：`aspectRatio(.fill)` 会溢出，
                // 而 ZStack 不裁剪 —— 这正是 hotfix20「图片错位盖住按钮」的根因，别改回去。
                Color.clear
                    .overlay(CanvasAttachmentPreviewImage(attachment: attachments[idx], maxPixel: 360))
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: s(14), style: .continuous))
                    .padding(s(2.6))
            } else {
                emptyCardBody
            }

        case .textSegment(let text):
            Text(text)
                .font(.system(size: s(10.5)))
                .foregroundColor(.black.opacity(0.78))
                .lineLimit(7)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(s(8))

        case .empty:
            emptyCardBody
        }
    }

    private var emptyCardBody: some View {
        RoundedRectangle(cornerRadius: s(14), style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: s(1.4), dash: [s(4), s(3)]))
            .foregroundColor(Color.black.opacity(0.22))
            .overlay(
                VStack(spacing: s(4)) {
                    Image(systemName: "tray")
                        .font(.system(size: s(15), weight: .light))
                    Text("空槽位")
                        .font(.system(size: s(9), weight: .medium))
                }
                .foregroundColor(Color.black.opacity(0.35))
            )
            .padding(s(3))
    }

    /// 右下角 + 角标：把「这叠卡还能加东西」摆到明处，点它直通入参文件面板。
    private var plusBadge: some View {
        Button(action: onOpenInputFiles) {
            Image(systemName: "plus")
                .font(.system(size: s(9), weight: .bold))
                .foregroundColor(.white)
                .frame(width: s(19), height: s(19))
                .background(Circle().fill(AppTheme.chromeAccentInk))
                .overlay(Circle().stroke(Color.white, lineWidth: s(1.6)))
                .shadow(color: .black.opacity(0.2), radius: s(2), x: 0, y: s(1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("添加入参文件")
        .offset(x: s(5), y: s(5))
    }

    // MARK: - 操作气泡

    /// 点卡片弹出的黑色圆角气泡。
    ///
    /// 位置固定在整叠卡片的**正上方**，不跟着被点的那张卡飘：跟着飘的话相邻两张卡的气泡会
    /// 各偏 20~30pt，用户连点两张就会觉得气泡在乱跳；而气泡里已经写明了操作对象的类型。
    private func actionBubble(for index: Int) -> some View {
        let source = sources.indices.contains(index) ? sources[index] : .empty
        return HStack(spacing: s(2)) {
            bubbleButton("编辑", "pencil") {
                openedCard = nil
                switch source {
                case .textSegment, .empty: onEditText()
                case .attachmentIndex: onOpenInputFiles()
                }
            }
            bubbleDivider
            bubbleButton("复制", "doc.on.doc") {
                openedCard = nil
                copyCard(source)
            }
            if case .attachmentIndex(let ai) = source {
                bubbleDivider
                bubbleButton("设为入参", "star") {
                    openedCard = nil
                    onPromoteInput(ai)
                }
            }
        }
        .padding(.horizontal, s(5))
        .padding(.vertical, s(4))
        .background(
            RoundedRectangle(cornerRadius: s(11), style: .continuous)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: s(11), style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: s(0.8))
        )
        .shadow(color: .black.opacity(0.35), radius: s(10), x: 0, y: s(4))
        .offset(y: -s(bubbleLift))
        .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
    }

    /// 气泡相对预览区中心的上移量。
    ///
    /// 「卡片顶 + 22」是理想位置，但卡片几乎顶满预览区（`cardSize` 只比它矮 10pt），照这个抬
    /// 会把气泡顶到预览区外面，压在节点标题「图像生成」上——看起来像错位的浮层。所以再夹一道
    /// 上限：气泡整体必须留在预览区内（`bubbleHeight` 是气泡自身高度的估值）。
    private var bubbleLift: CGFloat {
        let ideal = cardSize.height / 2 + 22
        let bubbleHeight: CGFloat = 26
        let ceiling = max(0, boxHeight / 2 - bubbleHeight / 2 - 4)
        return min(ideal, ceiling)
    }

    private var bubbleDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: s(0.8), height: s(13))
    }

    private func bubbleButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: s(3)) {
                Image(systemName: symbol)
                    .font(.system(size: s(8.5), weight: .semibold))
                Text(title)
                    .font(.system(size: s(9.5), weight: .medium))
            }
            .foregroundColor(.white.opacity(0.94))
            .padding(.horizontal, s(6))
            .padding(.vertical, s(3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 「复制」的落地：文本进剪贴板、图片附件优先给**文件 URL**（能直接粘进 Finder / 其他 App），
    /// 只有内嵌字节的附件才退化成图片对象。
    private func copyCard(_ source: CanvasFanGeometry.CardSource) {
        let pb = NSPasteboard.general
        switch source {
        case .textSegment(let text):
            pb.clearContents()
            pb.setString(text, forType: .string)
            onToast("已复制文本")

        case .attachmentIndex(let idx):
            guard attachments.indices.contains(idx) else { return }
            let att = attachments[idx]
            if let path = att.path, !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                pb.clearContents()
                pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
                onToast("已复制文件")
            } else if let data = att.resolveData(), let image = NSImage(data: data) {
                pb.clearContents()
                pb.writeObjects([image])
                onToast("已复制图片")
            } else {
                // 断链的附件复制出去会是一个空剪贴板，静默失败比报错更难查。
                onToast("这个入参文件已断链，无法复制")
            }

        case .empty:
            onToast("空槽位没有可复制的内容")
        }
    }
}
