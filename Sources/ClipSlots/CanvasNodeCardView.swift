import SwiftUI
import ClipSlotsKit

/// 画布节点卡片（v2.11.7 · 版本 C2 极简浮动）。
///
/// 结构自上而下：类型标签行 → 预览区 → prompt → 参数芯片栏。对应架构文档 9.2。
///
/// 关于尺寸：卡片在**画布空间**是固定尺寸（`CanvasNode.defaultSize`），缩放由外层 `scaleEffect`
/// 统一施加。所以这里所有数值都按 1x 写，不要在内部再乘 zoom —— 那会导致文字与边框的缩放比例
/// 不一致（`scaleEffect` 是位图级缩放，内部再算一遍等于缩放两次）。
///
/// ## 关于文本的来源（v2.11.7 hotfix18）
///
/// 卡片**不读 `node.prompt`** 来显示正文，而是用外部传进来的 `text`。原因：绑定了槽位的节点，
/// 它的正文就是那个槽位的主体数据本身（画布与编辑页双向同步），真相在 `SlotStoreObservable`
/// 里而不在节点副本里。卡片自己去读槽位数据就得认识主 store，那会把画布重新拖回"任一槽位变化
/// 触发全局重绘"的老路 —— 所以取数留在上层，卡片保持纯展示。
struct CanvasNodeCardView: View {
    let node: CanvasNode
    let isSelected: Bool
    /// 正文实时值。绑定槽位的节点 = 槽位主体文本；未绑定 = `node.prompt`。
    let text: String
    /// 溯源槽位的实时 Label（编辑页改了 Label，这里跟着变）。
    let slotLabel: String?
    /// 溯源槽位的实时附件列表（v2.11.7 hotfix19）。未绑定槽位的节点为空数组。
    ///
    /// 与 `text` 同源同理：真相在槽位数据里，卡片只负责展示，取数留在上层。
    let attachments: [SlotContent.SlotAttachment]
    /// 是否处于 inline 编辑态（由上层集中管理，保证同一时刻只有一个节点在编辑）。
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCommitEdit: (String) -> Void
    let onCancelEdit: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

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
        CanvasFontCatalog.font(family: node.fontName, size: node.resolvedBodyFontSize)
    }

    /// 预览区要展示的附件大图（第一张图片类附件）。
    ///
    /// 只在**节点自己还没有生成结果**时启用：生成结果是产物、附件是输入，产物在就该显示产物。
    private var previewAttachment: SlotContent.SlotAttachment? {
        guard isEmptyPreview else { return nil }
        return attachments.first { $0.canvasIsImageLike }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            typeRow
            previewArea
            promptArea
            if !attachments.isEmpty {
                CanvasNodeAttachmentStrip(attachments: attachments)
            }
            // 正文字号被调大后（最大 24pt）会把下面的内容顶出卡片。加一个可压缩的 Spacer，
            // 让参数栏始终钉在卡片底边，被挤掉的是正文的第二行而不是整条参数栏。
            Spacer(minLength: 0)
            paramChips
        }
        .padding(12)
        .frame(width: node.width, height: node.height, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardBackground(isEmpty: false))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor, lineWidth: isSelected ? 1.6 : 1)
        )
        .shadow(color: AppTheme.cardShadow(isEmpty: false),
                radius: isSelected ? 12 : 7,
                x: 0, y: isSelected ? 5 : 3)
        .onHover { isHovering = $0 }
        .onChange(of: isEditing) { editing in
            if editing {
                draft = text
                // 下一拍再抢焦点：本拍 TextEditor 还没进视图树，直接置 true 会被丢掉。
                DispatchQueue.main.async { editorFocused = true }
            }
        }
        .onAppear {
            if isEditing { draft = text; DispatchQueue.main.async { editorFocused = true } }
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
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: node.kind.symbolName)
                    .font(.system(size: 9, weight: .semibold))
                Text(node.kind.displayName)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(AppTheme.chromeAccentInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous).fill(AppTheme.chromeAccentSoftFill)
            )

            Spacer(minLength: 0)

            // 编辑入口。只在悬停 / 选中时出现：常驻一个铅笔会让每张卡片都多一件视觉噪声，
            // 而画布上一屏可能有十几张卡片。
            if !isEditing && (isHovering || isSelected) {
                Button(action: onBeginEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(AppTheme.chromeAccentInk)
                        .padding(3)
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
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(AppTheme.canvasCardMetaInk)
        case .queued(let ahead):
            // 「前方 N 个」用的是 CLI 真字段 queue_ahead_count，不是估算。
            Label(ahead > 0 ? "排队 · 前方 \(ahead)" : "排队中", systemImage: "clock")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(AppTheme.canvasCardMetaInk)
        case .running(let startedAt):
            // 刻意不给百分比：CLI 不提供，编出来的进度在 10~20s 量级会明显失真。
            RunningBadge(startedAt: startedAt)
        case .succeeded:
            Label("已生成", systemImage: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.green.opacity(0.85))
        case .failed:
            Label("失败", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.red.opacity(0.85))
        }
    }

    // MARK: - 预览区

    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.previewBackground)

            if case .succeeded(let path) = node.state,
               let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let att = previewAttachment {
                // ★ v2.11.7 hotfix19：槽位有图片附件时，预览区直接画它。
                // 在此之前这里永远是斜纹占位，于是「只放了图、没写字」的槽位拖到画布上是一张
                // 完全空白的卡片 —— 用户反馈的「看不到附件信息」最直观的那一半就是这个。
                CanvasAttachmentPreviewImage(attachment: att)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    // 左上角角标点明「这是输入附件，不是生成结果」，否则会被误读成已经出图了。
                    .overlay(alignment: .topLeading) {
                        Label("附件", systemImage: "paperclip")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(AppTheme.onAccentText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule(style: .continuous).fill(Color.black.opacity(0.45)))
                            .padding(6)
                    }
            } else {
                // 斜纹占位（对齐 C2 设计稿）：未生成状态一眼可辨，且不像「加载失败」。
                DiagonalHatch()
                    .stroke(AppTheme.subtleBorder.opacity(0.55), lineWidth: 1)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if case .failed(let reason) = node.state {
                    VStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 14, weight: .semibold))
                        Text(reason)
                            .font(.system(size: 9))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.red.opacity(0.75))
                    .padding(.horizontal, 8)
                } else {
                    Image(systemName: node.kind == .video ? "film" : "photo")
                        .font(.system(size: 18, weight: .light))
                        .foregroundColor(AppTheme.canvasCardMetaInk.opacity(0.5))
                }
            }
        }
        .frame(height: 148)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.subtleBorder.opacity(0.6), lineWidth: 0.5)
        )
    }

    // MARK: - prompt

    @ViewBuilder
    private var promptArea: some View {
        if isEditing {
            editor
        } else {
            Group {
                if text.isEmpty {
                    Text(attachments.isEmpty ? "双击填写内容…" : "仅附件，无文本")
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
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
            // 命中区要盖满整行，否则空节点只有那句灰字那么窄，双击基本点不中。
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onBeginEdit)
        }
    }

    /// inline 编辑器。
    ///
    /// **提交时机 = 失焦**（点画布别处、切到另一个节点、Tab 走焦点），不是按 Enter —— 正文是多行
    /// prompt，Enter 必须留给换行。Esc 放弃本次修改。
    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $draft)
                .font(bodyFont)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .frame(height: 40)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppTheme.previewBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(AppTheme.chromeAccentInk.opacity(0.5), lineWidth: 1)
                )
                .onChange(of: editorFocused) { focused in
                    // 失焦即落库。这里不判 draft 是否变过 —— 判等交给下游（store 与槽位写入都会
                    // 在无变化时提前返回），在这里判会漏掉"改了又改回来"之外的边界。
                    if !focused { onCommitEdit(draft) }
                }
                .onExitCommand(perform: onCancelEdit)

            HStack(spacing: 6) {
                Text(node.sourceSlot == nil ? "仅本节点" : "同步到槽位")
                    .font(.system(size: 8))
                    .foregroundColor(AppTheme.canvasCardMetaInk)
                Spacer(minLength: 0)
                Text("Esc 放弃")
                    .font(.system(size: 8))
                    .foregroundColor(AppTheme.canvasCardMetaInk.opacity(0.8))
            }
        }
    }

    // MARK: - 参数芯片栏

    private var paramChips: some View {
        HStack(spacing: 4) {
            chip(node.model)
            chip(node.ratio)
            if node.count > 1 { chip("×\(node.count)") }
            Spacer(minLength: 0)
            if let label = slotLabel, !label.isEmpty {
                // 溯源标记：这个节点绑的是哪个槽位。绑定后正文与该槽位双向同步。
                HStack(spacing: 2) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 7, weight: .semibold))
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(AppTheme.canvasCardMetaInk)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(AppTheme.canvasCardMetaInk)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(AppTheme.chipBackground)
            )
    }
}

// MARK: - 生成中角标

/// 已用秒数会自己走字。用独立小视图承载 `TimelineView`，避免每秒重绘整张卡片。
private struct RunningBadge: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(spacing: 3) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 8, height: 8)
                Text("生成中 \(elapsed)s")
                    .font(.system(size: 9, weight: .medium))
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
