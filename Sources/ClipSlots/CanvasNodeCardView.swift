import SwiftUI
import ClipSlotsKit

/// 画布节点卡片（v2.11.8 · 对齐 Crate 画布）。
///
/// 结构自上而下：类型标签行 → 预览区（扇形堆叠卡片）→ prompt → 入参文件 → 参数芯片栏。
///
/// ## 关于尺寸：为什么每个数值都要乘 `renderScale`（v2.11.8 修「放大变模糊」）
///
/// 此前的做法是卡片内部一律按 1x 写，缩放由节点层外面一个 `scaleEffect(zoom)` 统一施加。那样确实
/// 省事，代价是**放大后全糊**：`scaleEffect` 是渲染期的仿射变换 —— SwiftUI 先按 1x 布局把文字光栅化
/// 成位图，再把位图放大 2 倍，于是 200% 缩放下看到的是 2 倍放大的 1x 字形，边缘发虚、细边框糊成灰带。
/// 这不是"设置项没打开抗锯齿"，是像素本来就不存在。
///
/// 唯一的解法是把缩放**下沉到布局**：字号、内边距、圆角、线宽全部按当前 zoom 重算，让 SwiftUI 在
/// 真实像素尺寸上重新排版并重新光栅化文字。代价是缩放时每张卡片都要重新布局（此前只是改一个变换
/// 矩阵）—— 这笔账必须付：矢量清晰度是画布的基本可用性，而节点数量在这个 App 的量级（几十张）
/// 下重排一次仍在一帧内。
///
/// 所以本文件的铁律：**所有几何量都过 `s(_:)`，不要出现裸的常量尺寸**。漏乘一个的表现是"放大后
/// 某个边距/字号不跟着变"，在 100% 缩放下完全看不出来。
///
/// ## 关于文本的来源（v2.11.7 hotfix18 → hotfix20）
///
/// 卡片**不缓存正文**，而是用外部传进来的 `text`。节点就是槽位，正文的唯一真相是 `SlotContent`。
/// 卡片自己去读槽位数据就得认识主 store，那会把画布重新拖回"任一槽位变化触发全局重绘"的老路
/// —— 所以取数留在上层，卡片保持纯展示。
struct CanvasNodeCardView: View {
    let node: CanvasNode
    let isSelected: Bool
    /// 正文实时值 = 该槽位的主体文本。
    let text: String
    /// 槽位的实时 Label（编辑页改了 Label，这里跟着变）。
    let slotLabel: String?
    /// 槽位的实时附件列表 = 画布语境下的**入参文件**（v2.11.7 hotfix20 改名）。
    ///
    /// 与 `text` 同源同理：真相在槽位数据里，卡片只负责展示，取数留在上层。
    let attachments: [SlotContent.SlotAttachment]
    /// 当前画布缩放。见类型注释：卡片按它**重新布局**，不靠位图缩放。
    let renderScale: CGFloat
    /// 是否处于 inline 编辑态（由上层集中管理，保证同一时刻只有一个节点在编辑）。
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCommitEdit: (String) -> Void
    let onCancelEdit: () -> Void
    /// 点「入参文件 N」胶囊。弹层由上层（`CanvasWorkspaceView`）呈现 —— 它需要 `SlotStoreObservable`
    /// 才能增删改附件，而卡片刻意不认识主 store（见上面那段注释）。
    let onOpenInputFiles: () -> Void
    /// 把第 N 个附件挪到入参列表首位（扇形卡片的「设为入参」）。写数据同样上抛。
    let onPromoteInput: (Int) -> Void
    /// 轻提示（复制成功 / 断链等）。卡片不认识 `transientUI`，同上。
    let onToast: (String) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false
    @State private var draft = ""

    private func s(_ v: CGFloat) -> CGFloat { max(0.01, v * renderScale) }

    private var isEmptyPreview: Bool {
        if case .succeeded = node.state { return false }
        return true
    }

    /// 正文实际用的字体。
    ///
    /// **必须走 `CanvasFontCatalog`，不能写 `.font(.custom(node.fontName, size:))`** ——
    /// `Font.custom` 收的是字体名 / PostScript 名，而这里存的是用户在 picker 里选的**族名**
    /// （`HarmonyOS Sans SC`）。中文字体两者几乎从不相同，`Font.custom` 解析失败时会**静默**
    /// 回落系统字体：没有崩溃、没有告警，表现就是用户反馈的「选了字体但一点变化都没有」。
    private var bodyFont: Font {
        CanvasFontCatalog.font(family: node.fontName, size: node.resolvedBodyFontSize * renderScale)
    }

    /// 图片类附件在 `attachments` 里的下标。扇形卡片按它取图。
    private var imageAttachmentIndices: [Int] {
        attachments.enumerated().compactMap { $0.element.canvasIsImageLike ? $0.offset : nil }
    }

    private var fanSources: [CanvasFanGeometry.CardSource] {
        CanvasFanGeometry.cardSources(attachmentImageIndices: imageAttachmentIndices, text: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: s(8)) {
            typeRow
            previewArea
            promptArea
            inputFilesRow
            // 正文字号被调大后（最大 24pt）会把下面的内容顶出卡片。加一个可压缩的 Spacer，
            // 让参数栏始终钉在卡片底边，被挤掉的是正文的第二行而不是整条参数栏。
            Spacer(minLength: 0)
            paramChips
        }
        .padding(s(12))
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
        .onHover { isHovering = $0 }
        .onChange(of: isEditing) { editing in
            // 进编辑态就把当前槽位正文灌进草稿。焦点由 `CanvasPromptEditor` 自己在挂载时抢
            // （NSTextView 要等 window 就绪，SwiftUI 的 @FocusState 在深层子树里实测抢不稳）。
            if editing { draft = text }
        }
        .onAppear {
            if isEditing { draft = text }
        }
    }

    private var borderColor: Color {
        if isEditing { return AppTheme.chromeAccentInk }
        if isSelected { return AppTheme.chromeAccentInk.opacity(0.85) }
        if isHovering { return AppTheme.minimalCardHoverBorder }
        return AppTheme.subtleBorder
    }

    // MARK: - 类型标签行

    private var typeRow: some View {
        HStack(spacing: s(6)) {
            HStack(spacing: s(4)) {
                Image(systemName: node.kind.symbolName)
                    .font(.system(size: s(9), weight: .semibold))
                Text(node.kind.displayName)
                    .font(.system(size: s(10), weight: .semibold))
            }
            .foregroundColor(AppTheme.chromeAccentInk)
            .padding(.horizontal, s(6))
            .padding(.vertical, s(3))
            .background(
                Capsule(style: .continuous).fill(AppTheme.chromeAccentSoftFill)
            )

            Spacer(minLength: 0)

            // 编辑入口。只在悬停 / 选中时出现：常驻一个铅笔会让每张卡片都多一件视觉噪声，
            // 而画布上一屏可能有十几张卡片。
            if !isEditing && (isHovering || isSelected) {
                Button(action: onBeginEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: s(9), weight: .semibold))
                        .foregroundColor(AppTheme.chromeAccentInk)
                        .padding(s(3))
                        .background(Circle().fill(AppTheme.chromeAccentSoftFill))
                }
                .buttonStyle(.plain)
                .help("编辑内容（也可双击文本）")
            }

            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch node.state {
        case .idle:
            Text("未生成")
                .font(.system(size: s(9), weight: .medium))
                .foregroundColor(AppTheme.canvasCardMetaInk)
        case .queued(let ahead):
            // 「前方 N 个」用的是 CLI 真字段 queue_ahead_count，不是估算。
            Label(ahead > 0 ? "排队 · 前方 \(ahead)" : "排队中", systemImage: "clock")
                .font(.system(size: s(9), weight: .medium))
                .foregroundColor(AppTheme.canvasCardMetaInk)
        case .running(let startedAt):
            // 刻意不给百分比：CLI 不提供，编出来的进度在 10~20s 量级会明显失真。
            RunningBadge(startedAt: startedAt, renderScale: renderScale)
        case .succeeded:
            Label("已生成", systemImage: "checkmark.circle.fill")
                .font(.system(size: s(9), weight: .medium))
                .foregroundColor(.green.opacity(0.85))
        case .failed:
            Label("失败", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: s(9), weight: .medium))
                .foregroundColor(.red.opacity(0.85))
        }
    }

    // MARK: - 预览区

    /// ## 为什么图片分支必须先 `.frame` 再 `.clipShape`（v2.11.7 hotfix20 修的「图片错位」）
    ///
    /// 用户反馈"节点里的图片错位、还把编辑按钮挡住点不到"。根因不是坐标算错，是 **`aspectRatio(.fill)`
    /// 在 ZStack 里会溢出**：`.fill` 的语义是"短边贴合、长边超出"，一张 3:4 的竖图放进预览区，
    /// 高度会被撑到远超容器 —— 而 `ZStack` **不裁剪**超出的子视图。此前那份代码把 `.clipShape`
    /// 直接挂在 `Image` 上，裁的是**图片自己那个被撑高的框**（等于没裁），于是图片上下各溢出几十点，
    /// 向上盖住类型标签行里的铅笔按钮（所以"无法编辑"），向下盖住正文。
    ///
    /// 正确的顺序是：**先用 `.frame` 把容器尺寸钉死，再在容器外层裁剪**（`fillImageBox`）。
    ///
    /// ## 为什么外层那道兜底 `.clipShape` 被拿掉了（v2.11.8）
    ///
    /// 扇形堆叠卡片**必须**能溢出预览区：hover 展开时卡片要向两侧扇开、单卡要向上抬 8pt，
    /// 操作气泡还要浮在卡片上方。留着兜底裁剪，这些动作会被齐刷刷切掉一半 —— 那正是用户
    /// 要的"卡片飞出来"的反面。裁剪责任因此下移到**每个会溢出的图片分支自己**（`fillImageBox`）。
    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: s(10), style: .continuous)
                .fill(AppTheme.previewBackground)

            if case .succeeded(let path) = node.state,
               let img = NSImage(contentsOfFile: path) {
                // 产物在就显示产物：生成结果是这个节点的成品，入参堆叠此时让位。
                fillImageBox {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            } else if case .failed(let reason) = node.state {
                DiagonalHatch(spacing: s(7))
                    .stroke(AppTheme.subtleBorder.opacity(0.55), lineWidth: s(1))
                    .clipShape(RoundedRectangle(cornerRadius: s(10), style: .continuous))
                VStack(spacing: s(3)) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: s(14), weight: .semibold))
                    Text(reason)
                        .font(.system(size: s(9)))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundColor(.red.opacity(0.75))
                .padding(.horizontal, s(8))
            } else {
                // ★ v2.11.8：入参不再只画"第一张图"，而是整叠可扇开的卡片。见 CanvasSlotFanStack。
                CanvasSlotFanStack(sources: fanSources,
                                   attachments: attachments,
                                   renderScale: renderScale,
                                   nodeHovered: isHovering && !isEditing,
                                   boxHeight: 148,
                                   onEditText: onBeginEdit,
                                   onOpenInputFiles: onOpenInputFiles,
                                   onPromoteInput: onPromoteInput,
                                   onToast: onToast)
            }
        }
        .frame(height: s(148))
        .overlay(
            RoundedRectangle(cornerRadius: s(10), style: .continuous)
                .stroke(AppTheme.subtleBorder.opacity(0.6), lineWidth: s(0.5))
        )
    }

    /// 「填充式图片盒」：用 `Color.clear` 定尺、内容走 overlay、再 `.clipped()`。见 `previewArea` 的注释。
    private func fillImageBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Color.clear
            .overlay(content())
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: s(10), style: .continuous))
    }

    // MARK: - 提示词（= 槽位正文）

    @ViewBuilder
    private var promptArea: some View {
        if isEditing {
            editor
        } else {
            Group {
                if text.isEmpty {
                    Text(attachments.isEmpty ? "双击填写提示词…" : "仅入参文件，无提示词")
                        .font(bodyFont)
                        .foregroundColor(AppTheme.canvasCardMetaInk.opacity(0.75))
                } else {
                    Text(text)
                        .font(bodyFont)
                        .foregroundColor(.primary.opacity(0.88))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: s(26), alignment: .topLeading)
            // 命中区要盖满整行，否则空节点只有那句灰字那么窄，双击基本点不中。
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onBeginEdit)
        }
    }

    /// inline 提示词编辑器（v2.11.7 hotfix20 重写）。
    ///
    /// ## 键位契约
    ///   - **回车 = 保存**（用户明确要求）。
    ///   - **Shift+回车 = 换行**。
    ///   - Esc = 放弃。
    ///   - 失焦 = 保存（点画布别处、切到另一个节点）。
    ///
    /// ## 为什么不用 SwiftUI `TextEditor`
    ///
    /// `TextEditor` 会把 Return 直接吞掉插进文本，SwiftUI 在 macOS 13 上**没有**任何合法钩子能
    /// 在它之前拿到这个键（`.onKeyPress` 是 macOS 14+；`.onSubmit` 对 `TextEditor` 不触发）。
    /// 所以这里换成裹了 `NSTextView` 的 `CanvasPromptEditor`，在
    /// `textView(_:doCommandBy:)` 里按修饰键分流 —— 这是唯一能同时满足"回车保存"和"Shift+回车换行"
    /// 的路径，而这两条正是用户要的。
    private var editor: some View {
        VStack(alignment: .leading, spacing: s(4)) {
            // 编辑器字号同样乘 renderScale：光标与选区是 NSTextView 自己画的，字号不跟着缩放
            // 会出现"放大后光标只有半个字高"这种一眼假的错位。
            CanvasPromptEditor(text: $draft,
                               font: CanvasFontCatalog.nsFont(family: node.fontName,
                                                              size: node.resolvedBodyFontSize * renderScale),
                               onCommit: { onCommitEdit(draft) },
                               onCancel: onCancelEdit,
                               onBlur: { onCommitEdit(draft) })
                .frame(height: s(40))
                .padding(.horizontal, s(4))
                .padding(.vertical, s(2))
                .background(
                    RoundedRectangle(cornerRadius: s(6), style: .continuous)
                        .fill(AppTheme.previewBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: s(6), style: .continuous)
                        .stroke(AppTheme.chromeAccentInk.opacity(0.5), lineWidth: s(1))
                )

            HStack(spacing: s(6)) {
                Text("回车保存")
                    .font(.system(size: s(8), weight: .medium))
                    .foregroundColor(AppTheme.chromeAccentInk)
                Text("⇧回车换行")
                    .font(.system(size: s(8)))
                    .foregroundColor(AppTheme.canvasCardMetaInk)
                Spacer(minLength: 0)
                Text("Esc 放弃")
                    .font(.system(size: s(8)))
                    .foregroundColor(AppTheme.canvasCardMetaInk.opacity(0.8))
            }
        }
    }

    // MARK: - 入参文件

    /// 「入参文件 N」胶囊。
    ///
    /// ★ hotfix19 这里是一排缩略图（`CanvasNodeAttachmentStrip`），用户反馈"点了完全没反应"——
    /// 它当时确实只是一排 `Image`，没有任何交互。改成一个明确的按钮：**看得出能点**。
    /// 名字用「入参文件」而不是「附件」：画布语境下它们是喂给模型的输入，不是"顺带附上的东西"。
    @ViewBuilder
    private var inputFilesRow: some View {
        Button(action: onOpenInputFiles) {
            HStack(spacing: s(4)) {
                Image(systemName: attachments.isEmpty ? "tray" : "tray.full")
                    .font(.system(size: s(8), weight: .semibold))
                Text(attachments.isEmpty ? "入参文件" : "入参文件 \(attachments.count)")
                    .font(.system(size: s(9), weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: s(6), weight: .bold))
                    .opacity(0.6)
            }
            .foregroundColor(attachments.isEmpty
                             ? AppTheme.canvasCardMetaInk
                             : AppTheme.chromeAccentInk)
            .padding(.horizontal, s(7))
            .padding(.vertical, s(3))
            .background(
                Capsule(style: .continuous)
                    .fill(attachments.isEmpty
                          ? AppTheme.previewBackground
                          : AppTheme.chromeAccentSoftFill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(AppTheme.subtleBorder.opacity(attachments.isEmpty ? 0.7 : 0), lineWidth: s(0.5))
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("管理入参文件：增删、调整顺序（与该槽位的附件是同一份数据）")
    }

    // MARK: - 参数芯片栏

    private var paramChips: some View {
        HStack(spacing: s(4)) {
            chip(node.model)
            chip(node.ratio)
            if node.count > 1 { chip("×\(node.count)") }
            Spacer(minLength: 0)
            slotBadge
        }
    }

    /// 槽位标记：这张卡片是哪个槽位。
    ///
    /// hotfix20 起它不再是"溯源"信息而是**身份**信息 —— 节点就是这个槽位，所以永远显示，
    /// 没有 Label 时退回「槽位 N」而不是整块消失（一张说不出自己是谁的卡片没法核对）。
    private var slotBadge: some View {
        let name = (slotLabel?.isEmpty == false) ? slotLabel! : "槽位 \(node.slot)"
        return HStack(spacing: s(2)) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: s(7), weight: .semibold))
            Text(name)
                .font(.system(size: s(8), weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(AppTheme.canvasCardMetaInk)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: s(8), weight: .medium))
            .foregroundColor(AppTheme.canvasCardMetaInk)
            .lineLimit(1)
            .padding(.horizontal, s(5))
            .padding(.vertical, s(2))
            .background(
                RoundedRectangle(cornerRadius: s(4), style: .continuous)
                    .fill(AppTheme.chipBackground)
            )
    }
}

// MARK: - 生成中角标

/// 已用秒数会自己走字。用独立小视图承载 `TimelineView`，避免每秒重绘整张卡片。
private struct RunningBadge: View {
    let startedAt: Date
    var renderScale: CGFloat = 1

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(spacing: 3 * renderScale) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6 * renderScale)
                    .frame(width: 8 * renderScale, height: 8 * renderScale)
                Text("生成中 \(elapsed)s")
                    .font(.system(size: max(0.01, 9 * renderScale), weight: .medium))
                    .foregroundColor(AppTheme.canvasCardMetaInk)
            }
        }
    }
}

// MARK: - 斜纹占位

/// 45° 斜纹填充。用 Shape 而不是贴图，缩放时始终清晰。
struct DiagonalHatch: Shape {
    var spacing: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard spacing > 0, rect.width > 0, rect.height > 0 else { return p }
        var x = -rect.height
        var guardCount = 0
        while x < rect.width && guardCount < 600 {
            p.move(to: CGPoint(x: rect.minX + x, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + x + rect.height, y: rect.minY))
            x += spacing
            guardCount += 1
        }
        return p
    }
}
