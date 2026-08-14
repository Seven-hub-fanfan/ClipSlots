import SwiftUI
import ClipSlotsKit
import AVKit

struct SlotCardView: View {
    let slot: Int
    let content: SlotContent
    let specialSlotId: String
    var label: String = ""
    var saveShortcut: String = ""
    var pasteShortcut: String = ""
    var onPaste: () -> Void
    var onCopy: () -> Void
    var onSave: () -> Void
    var onClear: () -> Void
    var onSetLabel: (String) -> Void
    var onEditText: ((String) -> Void)? = nil
    var onEditHTML: ((String) -> Void)? = nil
    var onDropFiles: (([URL]) -> Void)? = nil
    // v2.10.19: 单独删除主体文本内容（保留附件）。
    var onClearBody: (() -> Void)? = nil

    // v2.9.36: when true, this slot was the most recent paste target and shows a
    // persistent "上次粘贴" badge in the top-right corner until another slot is pasted.
    var isLastPasted: Bool = false

    // v2.9.37: transient flash highlight triggered by tapping the footer "上次粘贴"
    // button — the card glows for ~2s so the user can spot where the last paste went.
    var isFlashHighlighted: Bool = false

    // v2.7.76: shared store so the main-grid card can host the same attachment
    // button used on the node canvas, reading/writing the same SlotContent.attachments.
    var store: SlotStoreObservable? = nil

    // v2.7.0: Connection props
    var connectionDotColor: Color? = nil
    var isConnectionMode: Bool = false
    var connectedPorts: Set<SlotPort> = []
    var highlightedPort: SlotPort? = nil
    var isPortVisible: Bool = false
    var onBeginDrag: ((SlotPort, CGPoint) -> Void)?
    var onUpdateDrag: ((CGPoint) -> Void)?
    var onEndDrag: (() -> Void)?

    @State private var editingLabel = false
    @State private var labelText = ""
    @State private var isHovering = false
    @State private var showingPreview = false
    @State private var showingTextEditor = false
    @State private var showingHTMLEditor = false
    @State private var editingText = ""
    @State private var isDropTargeted = false

    @Environment(\.colorScheme) private var colorScheme
    // v2.10.70: 拖拽 live-resize 期间去掉卡片软阴影——resize 时 N 张可见卡片的软阴影每帧重合成开销很大。
    @ObservedObject private var liveResize = LiveResizeMonitor.shared

    private var slotAccent: Color {
        AppTheme.slotAccent(slot, scheme: colorScheme)
    }

    private var cardOutlineColor: Color {
        if isFlashHighlighted { return slotAccent }
        if isDropTargeted { return slotAccent.opacity(0.72) }
        if isHovering { return slotAccent.opacity(0.72) }
        return AppTheme.subtleBorder(colorScheme)
    }

    private var cardOutlineWidth: CGFloat {
        if isFlashHighlighted { return 2.5 }
        if isDropTargeted { return 1.2 }
        return isHovering ? 1.5 : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spacingMedium) {
            headerRow

            // Thumbnail area — split empty vs filled to prevent @State image reuse
            Group {
                if content.isEmpty {
                    EmptySlotThumbnailView()
                } else if content.isVideoFile, let url = content.primaryFileURL {
                    InlineSlotVideoPreview(url: url)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.slotPreviewCornerRadius, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: AppTheme.slotPreviewCornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.slotPreviewCornerRadius, style: .continuous)
                                .fill(Color.clear)
                                .contentShape(RoundedRectangle(cornerRadius: AppTheme.slotPreviewCornerRadius, style: .continuous))
                                .onTapGesture {
                                    // v2.7.35: AVPlayerView is an NSView and can swallow SwiftUI gestures.
                                    // Put the click layer above it so video behaves like image cards.
                                    showingPreview = true
                                }
                        )
                        .help("点击查看视频大图预览")
                } else {
                    SlotThumbnailView(content: content, specialSlotId: specialSlotId, slot: slot)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.slotPreviewCornerRadius, style: .continuous))
                        .onTapGesture {
                            if content.canPreview {
                                showingPreview = true
                            }
                        }
                        .help(content.canPreview ? "点击查看大图" : "")
                }
            }
            // v2.10.20: 「删除主体文本」叉号位于内容预览框左上角，
            // 避开右上角卡片级「上次粘贴」角标；仅当槽位有主体内容时显示。
            .overlay(alignment: .topLeading) {
                if let onClearBody, (!content.items.isEmpty || content.htmlSource != nil) {
                    Button(action: onClearBody) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary.opacity(0.75))
                            .background(
                                Circle()
                                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.9))
                                    .frame(width: 14, height: 14)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("删除此槽位的文本内容（保留附件）")
                    .padding(6)
                }
            }

            // Metadata — fixed single-line, with the attachment button pinned on the right.
            // v2.7.76: moved the attachment button off the header row (it squeezed the slot
            // title) down here just above the action buttons. It's a plain Button, so it
            // won't trigger the card's paste/edit/hover/drag.
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(content.metadataSummary)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.68))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(content.metadataSummary)

                Spacer(minLength: 4)

                if let store = store {
                    // v2.10.89 (perf): 把附件数直接传给按钮，热路径零存储读。
                    // 卡片本来就持有权威的 `content`，而按钮内部原先靠 `store.attachments(for:)`
                    // 自己做存储读（stat 系统调用 + queue.sync），一次 body 要读 9 次、×10 张卡片
                    // ≈ 90 次主线程同步 I/O，且因按钮自己观察主 store 而绕过了卡片 .equatable() 短路。
                    // 这是 v2.10.88 两处渲染优化之外、hover 切槽位卡顿的第二条根因，影响面还覆盖
                    // 每次保存/清空/Toast/切组（详见 NodeAttachmentButton 的注释）。
                    NodeAttachmentButton(
                        slot: slot,
                        store: store,
                        attachmentCountOverride: content.attachments.count
                    )
                }
            }
            // v2.8.2 (P2-5): use minHeight so the row can grow to fit the 22pt
            // NodeAttachmentButton pill instead of clipping it / shrinking its hit area.
            .frame(minHeight: 22, alignment: .leading)
            .padding(.horizontal, 2)

            actionRow
        }
        // v2.9.22: 卡片最小高度 280 → 216，配合空槽/缩略图/按钮区一起收紧，
        // 让 10 个槽位尽量不滚动就能看全；长文本卡片仍可自适应撑开。
        .frame(minHeight: 216, alignment: .top)
        // C-2 (v2.10.31): removed `.id(content.thumbnailKey(...))` from the card root.
        // thumbnailKey embeds updatedAt, so any minor content/metadata change (background
        // sync, label update) mutated the id and destroyed+rebuilt the whole card, wiping
        // its internal @State (editingLabel/labelText/editingText) — losing in-progress,
        // unsaved edits.
        // v2.10.73（方案③）：缩略图刷新不再依赖任何 `.id`。SlotThumbnailView 已去掉内部
        // `.id(currentKey)`，改为观察 ThumbnailProvider（keyed 共享缓存单一数据源）——currentKey
        // 变化即读新 key、命中秒出/未命中异步填充，卡片编辑态得以在切换/复用中存活。
        .padding(AppTheme.slotCardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.slotCardCornerRadius, style: .continuous)
                .fill(AppTheme.cardBackground(colorScheme, isEmpty: content.isEmpty))
                // v2.10.88 (perf · hover 切槽位卡顿): 阴影的 radius / y **不再随 hover 变化**。
                //
                // 原实现是 radius 5→9、y 2→4，而卡片链尾的 `.animation(Anim.interactive, value: isHovering)`
                // 会把它一并纳入隐式动画——于是每次 hover 进/出，这个高斯模糊的半径都要在 0.12s 内被
                // **逐帧重新计算**（模糊半径变化无法靠图层缓存复用，只能整块重新合成）。把鼠标从一张卡片
                // 移到相邻卡片时，两张卡片会同时各跑一遍这个逐帧重模糊（离开的那张缩+减半径、进入的那张
                // 放大+加半径），叠加下面 scaleEffect 对整张已合成卡片的重采样，正是「悬停状态下切到另一个
                // 槽位时 UI 发卡」的主因。
                //
                // hover 的视觉反馈完全由「描边加深加粗（cardOutlineColor / cardOutlineWidth，纯矢量描边，
                // 无模糊）+ 1.012 缩放」承担，这两者都便宜；去掉长在阴影上的那一档抬升，观感差异极小，
                // 但省掉了 hover 路径上唯一的逐帧模糊重算。
                .shadow(
                    color: liveResize.isResizing ? .clear : AppTheme.cardShadow(colorScheme, isEmpty: content.isEmpty),
                    radius: liveResize.isResizing ? 0 : (content.isEmpty ? 3 : 5),
                    y: liveResize.isResizing ? 0 : 2
                )
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.slotCardCornerRadius, style: .continuous)
                .strokeBorder(cardOutlineColor, lineWidth: cardOutlineWidth)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .topLeading) {
            Capsule()
                .fill(slotAccent)
                .frame(width: 34, height: 3)
                .padding(.leading, AppTheme.slotCardPadding)
                .allowsHitTesting(false)
        }
        // Hover state only; the composed-card transform is applied after every visual overlay.
        .onHover { hovering in
            isHovering = hovering
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
        .overlay(alignment: .center) {
            if isDropTargeted {
                DropImportOverlay(slot: slot)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .allowsHitTesting(false)
            }
        }
        // Flash keeps the original colored glow, but its hard edge is rendered by the
        // single card outline above so hover/drop/flash never produce parallel strokes.
        .shadow(
            color: isFlashHighlighted ? slotAccent.opacity(0.5) : Color.clear,
            radius: isFlashHighlighted ? 9 : 0
        )
        .animation(Anim.status, value: isFlashHighlighted)
        // v2.9.36: persistent "上次粘贴" corner badge, lightweight so it doesn't
        // cover the card's main content.
        .overlay(alignment: .topTrailing) {
            if isLastPasted {
                lastPasteBadge
                    .padding(.top, 6)
                    .padding(.trailing, 42)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .allowsHitTesting(false)
            }
        }
        .animation(Anim.transition, value: isLastPasted)
        // Apply one transform to the fully composed card. The outline is already unified,
        // so scaling cannot reveal multiple independently rasterized hard edges.
        //
        // v2.10.90 (perf · hover 光效不丝滑): **移除** v2.10.88 加的 `.compositingGroup()`。
        //
        // v2.10.88 的想法是「缩放前先把卡片拍平成一层，让 0.12s 的缩放退化成对单个位图做 GPU 变换」。
        // 这个推理只在「被拍平的内容在动画期间保持不变」时成立，而这里两个前提都不满足：
        //
        //   1) 描边就在这个组里，而且和缩放**由同一个 isHovering、在同一个 0.12s 窗口里一起变**
        //      （cardOutlineColor 淡入 accent、cardOutlineWidth 1 → 1.5）。内容每帧都在变 → 拍平出来的
        //      位图每帧都失效、必须重新生成。缓存收益为零，却凭空多出一次**离屏合成 pass**。
        //   2) 卡片子树里含 AppKit 视图：附件胶囊的 `AttachmentButtonAnchorReporter`
        //      （NSViewRepresentable，见 AttachmentManagerPanel.swift）持续上报锚点矩形；视频槽位还有
        //      `SafeInlineAVPlayerView`。compositingGroup 要维持这一层位图，就得在每帧对这些 NSView
        //      做快照再合成，这是 CPU/GPU 同步开销，比它想省掉的重采样更贵。
        //
        // 净效果是负优化——这正是「hover 光效慢慢的、感觉很卡」的主因。去掉后回到 SwiftUI 默认路径：
        // 描边是廉价矢量重绘，缩放是普通图层变换，两者互不放大。
        //
        // ⚠️ 不要因为「拍平能优化缩放」这条一般性经验再把它加回来：要加之前先确认组内没有随动画变化的
        // 内容、也没有 NSViewRepresentable，否则必然是净损失。
        // v2.10.88: 1.015 → 1.012。缩放比例直接决定重采样的像素量与外扩重绘面积；1.012 仍能读出
        // 「这张卡浮起来了」，但在 hover 快速掠过多张卡片时更轻。
        .scaleEffect(isHovering ? 1.012 : 1)
        .animation(Anim.interactive, value: isHovering)
        .sheet(isPresented: $showingPreview) {
            SlotPreviewView(content: content)
                .frame(width: 640, height: 500)
        }
        .contextMenu {
            // v2.5: Type-specific actions
            typeSpecificMenuItems
        }
    }

    // v2.10.54: 回退 v2.10.48 的 inline Popover（负优化——点气泡外部无保存 dismiss，编辑内容被静默
    // 丢弃），改回 Sheet（原 520×320 尺寸），并保留 v2.10.48 新增的 ⌘↩ 保存快捷键。
    // 纯文本编辑 Sheet。
    //
    // v2.10.90 (perf · ★逐字延迟根因): 两个编辑 Sheet 的内容改由独立的 `SlotTextEditorSheet` 承载。
    //
    // 原先 `TextEditor` 直接绑本视图的 `@State editingText`，于是**每敲一个字符都要重算整张卡片的
    // body**（缩略图 / 元数据 / actionRow / 6 层 overlay / 阴影 / scaleEffect / 两个 sheet 闭包全都跑一遍），
    // 延迟量随卡片复杂度增长——就是「每个字都像有延迟输入」的来源。拆出去后逐字输入只重算那个轻量 Sheet。
    //
    // `editingText` 保留，但现在只在 `beginEditing()` 里被写一次、作为传给 Sheet 的初值快照，
    // 打字过程中不再变化，因此不会再让卡片 body 失效。
    private var textEditorSheet: some View {
        SlotTextEditorSheet(
            slot: slot,
            mode: .plainText,
            initialText: editingText,
            onSave: { text in
                onEditText?(text)
                showingTextEditor = false
            },
            onCancel: { showingTextEditor = false }
        )
    }

    // HTML 原文编辑 Sheet。
    private var htmlEditorSheet: some View {
        SlotTextEditorSheet(
            slot: slot,
            mode: .html,
            initialText: editingText,
            onSave: { text in
                onEditHTML?(text)
                showingHTMLEditor = false
            },
            onCancel: { showingHTMLEditor = false }
        )
    }

    // v2.9.36: lightweight "上次粘贴" badge shown in the card's top-right corner.
    private var lastPasteBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .bold))
            Text("上次粘贴")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(slotAccent.opacity(0.92))
        )
        .overlay(
            Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: slotAccent.opacity(0.3), radius: 2, x: 0, y: 1)
        .help("这是最近一次粘贴的槽位")
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("\(slot)")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundColor(slotAccent)
                .monospacedDigit()
                .frame(minWidth: 34, alignment: .leading)
                .accessibilityLabel("槽位 \(slot)")

            // v2.7.9: Connection indicator with capsule badge
            if let dotColor = connectionDotColor {
                HStack(spacing: 4) {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                    Image(systemName: "link")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(dotColor)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Capsule().fill(dotColor.opacity(0.14)))
                .overlay(Capsule().stroke(dotColor.opacity(0.35), lineWidth: 0.8))
                .help("此槽位属于串联链路")
            }

            VStack(alignment: .leading, spacing: AppTheme.spacingTight) {
                if editingLabel {
                    TextField("标签", text: $labelText, onCommit: commitLabel)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                        .onExitCommand {
                            editingLabel = false
                        }
                } else {
                    HStack(spacing: 5) {
                        Text(displayTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)

                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary.opacity(isHovering ? 0.85 : 0.0))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        labelText = label
                        editingLabel = true
                    }
                    .help("点击编辑标签")
                }

                // v2.9.18: 类型文字与缩略图/元数据信息冗余；有内容时隐藏，只在空槽提示。
                if content.isEmpty {
                    Text("空槽位")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if !content.isEmpty {
                // v2.9.18: 密集 header 里去掉时间戳胶囊背景，改纯灰文字更克制。
                Text(timeAgo)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            moreActionsMenu
        }
        // v2.9.18: header 顶部留出呼吸空间，数字气泡不再紧贴卡片大圆角上沿（截图问题①）。
        .padding(.top, AppTheme.spacingTight)
    }

    private var contentPreview: some View {
        Group {
            if content.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Image(systemName: "tray")
                            .font(.callout)
                            .foregroundColor(.secondary.opacity(0.55))
                        Text("暂无内容")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    if !saveShortcut.isEmpty {
                        Text("使用 \(saveShortcut) 保存到此槽位")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.72))
                            .lineLimit(1)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: contentTypeIcon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 20)

                    Text(content.preview)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                        // v2.9.23: 统一所有槽位卡片文本预览行数为 28，避免部分卡片过早省略。
                        .lineLimit(28)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var actionRow: some View {
        VStack(spacing: 6) {
            if !content.isEmpty {
                HStack(spacing: 8) {
                    Button(action: beginEditing) {
                        Label(editActionTitle, systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SlotActionButtonStyle(kind: .accent(AppTheme.slotActionAccent(slot, scheme: colorScheme))))
                    .disabled(!canEditContent)
                    .help(editActionHelp)
                    .frame(maxWidth: .infinity)

                    Button(role: .destructive) { onClear() } label: {
                        Label("清空", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SlotActionButtonStyle(kind: .destructive))
                    .help("清空槽位内容（需要确认）")
                    .frame(maxWidth: .infinity)
                }
            } else {
                Button { onSave() } label: {
                    Label("保存到槽位 \(slot)", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SlotActionButtonStyle(kind: .accent(AppTheme.slotActionAccent(slot, scheme: colorScheme))))
                .help(saveShortcut.isEmpty ? "保存当前剪贴板内容到槽位 \(slot)" : saveShortcut)

                Color.clear
            }
        }
        .frame(height: 52)
        .sheet(isPresented: $showingHTMLEditor) { htmlEditorSheet }
        .sheet(isPresented: $showingTextEditor) { textEditorSheet }
    }

    private var canEditContent: Bool {
        (content.isHTMLContent && onEditHTML != nil) || (content.isPlainEditableText && onEditText != nil)
    }

    private var editActionTitle: String {
        canEditContent ? "编辑" : "不可编辑"
    }

    private var editActionHelp: String {
        if content.isHTMLContent && onEditHTML != nil { return "编辑 HTML 原文" }
        if content.isPlainEditableText && onEditText != nil { return "直接编辑此文本槽位" }
        return "此内容类型不支持直接编辑"
    }

    private func beginEditing() {
        if content.isHTMLContent, onEditHTML != nil {
            editingText = content.htmlEditableValue
            showingHTMLEditor = true
        } else if content.isPlainEditableText, onEditText != nil {
            editingText = content.editableTextValue
            showingTextEditor = true
        }
    }

    private var moreActionsMenu: some View {
        Menu {
            if content.isEmpty {
                Button { onSave() } label: {
                    Label(saveShortcut.isEmpty ? "保存到槽位" : "保存到槽位（\(saveShortcut)）", systemImage: "square.and.arrow.down")
                }
            } else {
                Button { onPaste() } label: {
                    Label(pasteShortcut.isEmpty ? "粘贴" : "粘贴（\(pasteShortcut)）", systemImage: "arrow.up.doc.fill")
                }
                Button { onCopy() } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }

                Divider()

                if content.isPlainEditableText, onEditText != nil {
                    Button(action: beginEditing) { Label("编辑文本", systemImage: "pencil") }
                }
                if content.isHTMLContent, onEditHTML != nil {
                    Button(action: beginEditing) { Label("编辑 HTML", systemImage: "chevron.left.forwardslash.chevron.right") }
                }
                Button { onSave() } label: {
                    Label(saveShortcut.isEmpty ? "覆盖" : "覆盖（\(saveShortcut)）", systemImage: "arrow.triangle.2.circlepath")
                }

                if let onClearBody, !content.items.isEmpty || content.htmlSource != nil {
                    Button(role: .destructive, action: onClearBody) {
                        Label("删除主体内容（保留附件）", systemImage: "doc.badge.minus")
                    }
                }

                typeSpecificMenuItems

                Divider()
                Button(role: .destructive) { onClear() } label: {
                    Label("清空槽位…", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
        .accessibilityLabel("槽位 \(slot) 更多操作")
    }

    private func commitLabel() {
        editingLabel = false
        onSetLabel(labelText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var displayTitle: String {
        if label.isEmpty { return "槽位 \(slot)" }
        return label
    }

    private var contentTypeIcon: String {
        if content.isEmpty { return "tray" }
        let text = content.preview
        if text.hasPrefix("[富文本]") { return "doc.richtext" }
        if text.hasPrefix("[图片") { return "photo" }
        if content.isVideoFile { return "film" }
        if text.hasPrefix("[文件") { return "doc" }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return "link" }
        return "doc.text"
    }

    private var contentTypeTitle: String {
        let text = content.preview
        if text.hasPrefix("[富文本]") { return "富文本" }
        if text.hasPrefix("[图片") { return "图片" }
        if content.isVideoFile { return "视频" }
        if text.hasPrefix("[文件") { return "文件" }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return "链接" }
        return "文本"
    }

    // MARK: - Context Menu (v2.5)

    @ViewBuilder
    private var typeSpecificMenuItems: some View {
        if let fileURL = content.primaryFileURL {
            Divider()

            let exists = SlotTypeActions.fileExists(fileURL)

            Button("打开文件") {
                SlotTypeActions.openFile(fileURL)
            }
            .disabled(!exists)

            Button("在 Finder 中显示") {
                SlotTypeActions.revealInFinder(fileURL)
            }
            .disabled(!exists)

            Button("复制文件路径") {
                SlotTypeActions.copyFilePath(fileURL)
            }

            Button("复制文件名") {
                SlotTypeActions.copyFileName(fileURL)
            }
        }

        if let webURL = content.detectedWebURL {
            Divider()

            Button("打开链接") {
                SlotTypeActions.openWebURL(webURL)
            }

            Button("复制链接") {
                SlotTypeActions.copyString(webURL.absoluteString)
            }

            Button("复制 Markdown 链接") {
                SlotTypeActions.copyMarkdownLink(webURL)
            }
        }
    }

    private var timeAgo: String {
        SlotCardView.relativeTimeString(since: content.timestamp)
    }

    // v2.10.76 (Phase 2.5 · body 重算缓存): 相对时间字符串按「分钟粒度」记忆化。
    // timeAgo 依赖“当前时间”，无法随内容永久缓存；但同一分钟内、对同一 timestamp 的重复求值结果不变，
    // 故用 (timestamp 秒, 当前分钟桶) 作 key 缓存，避免卡片 body 重算时反复做区间判断 + 字符串插值分配。
    // 语义与旧实现逐字节一致（含未来时间戳→“刚刚”）。metadataSummary 已于 v2.10.30 用 contentId::updatedAt
    // 缓存（见 SlotContent+Thumbnail.swift），无需再处理。
    private static let timeAgoCache = NSCache<NSString, NSString>()
    static func relativeTimeString(since date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)
        let minuteBucket = Int(now.timeIntervalSince1970 / 60)
        let key = "\(Int(date.timeIntervalSince1970))-\(minuteBucket)" as NSString
        if let cached = timeAgoCache.object(forKey: key) { return cached as String }
        let result: String
        if interval < 60 { result = "刚刚" }
        else if interval < 3600 { result = "\(Int(interval / 60)) 分钟前" }
        else if interval < 86400 { result = "\(Int(interval / 3600)) 小时前" }
        else { result = "\(Int(interval / 86400)) 天前" }
        timeAgoCache.setObject(result as NSString, forKey: key)
        return result
    }

    // MARK: - v2.7.0 Port Overlay

    @ViewBuilder
    private var portOverlay: some View {
        if isPortVisible || !connectedPorts.isEmpty {
            SlotPortLayer(
                slot: slot,
                size: CGSize(width: 250, height: 270),
                color: connectionDotColor ?? .accentColor,
                isVisible: isPortVisible,
                connectedPorts: connectedPorts,
                highlightedPort: highlightedPort,
                onBeginDrag: onBeginDrag ?? { _, _ in },
                onUpdateDrag: onUpdateDrag ?? { _ in },
                onEndDrag: onEndDrag ?? {}
            )
        }
    }

    // MARK: - v2.7.27 File Drop

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let onDropFiles else { return false }
        // v2.10.66: `loadItem` 的 completion 在任意（并发）队列回调，旧实现对共享 `var urls`
        // 无锁 append——多文件同时拖入时，数组扩容 / copy-on-write 与 retain/release 在多线程下
        // 竞争，会偶发丢文件甚至崩溃。改用专用串行队列串行化所有 append，并在主线程 notify 中
        // 同样经该队列读取以保证内存可见性。
        var urls: [URL] = []
        let collectQueue = DispatchQueue(label: "com.clipslots.filedrop.collect")
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let resolved: URL?
                if let data = item as? Data,
                   let string = String(data: data, encoding: .utf8),
                   let url = URL(string: string) {
                    resolved = url
                } else if let url = item as? URL {
                    resolved = url
                } else {
                    resolved = nil
                }
                if let resolved {
                    collectQueue.sync { urls.append(resolved) }
                }
            }
        }

        group.notify(queue: .main) {
            collectQueue.sync {
                if !urls.isEmpty { onDropFiles(urls) }
            }
        }
        return true
    }
}

// MARK: - v2.10.76 (Phase 1.2 · 让 SwiftUI 跳过未变卡片的 body)
//
// 主网格是 10 张 SlotCardView 的 ForEach。此前只要 ContentView.body 重新求值（任一 store.slots /
// labels / 其他 @Published 变更），10 张卡片的值都会被重建，SwiftUI 逐张 diff 其庞大的 body（缩略图 /
// 元数据 / 动作区 / 多个 overlay），即使只有一张槽位内容真正变化，其余 9 张也白白重算 body。
//
// 让 SlotCardView 遵循 Equatable 并在网格里用 `.equatable()` 包裹后，SwiftUI 会先用下面的 == 判断：
// 输入等价则直接复用上一帧渲染、跳过 body 求值。这样「保存 1 号槽 / hover / 切页」只让真正变动的那张
// 卡片重算 body，其余卡片零成本。
//
// == 覆盖了所有影响本卡片自身渲染的输入：
//   • thumbnailKey：编码 (specialSlotId, slot, contentId, updatedAt)，空槽固定为 ::empty——它既是
//     缩略图/预览/元数据/可编辑性的内容版本键（保证 v2.10.73 keyed 缩略图刷新正确），也天然覆盖
//     「内容变更 / 覆盖 / 切组切页」；
//   • label（标题）、saveShortcut/pasteShortcut（按钮与提示文案）；
//   • isLastPasted（右上角「上次粘贴」角标）、isFlashHighlighted（发光高亮）——最近粘贴视觉输入；
//   • connectionDotColor / 连线相关（连线口显隐与配色）；
//   • store 引用身份（附件按钮观察的是同一 store 实例，内容变化经 thumbnailKey 反映）。
// 注意：卡片内部的 hover（isHovering）、编辑态等是 @State，Equatable 命中复用时会被 SwiftUI 原样保留，
// 不受影响；hover 缩放/描边由卡片自身 onHover 驱动，无需进入 ==。timeAgo 依赖“当前时间”，命中复用时
// 不会自行走秒——这与迁移前一致（原本也只在 body 重算时刷新），非回归。
extension SlotCardView: Equatable {
    static func == (lhs: SlotCardView, rhs: SlotCardView) -> Bool {
        lhs.slot == rhs.slot
            && lhs.specialSlotId == rhs.specialSlotId
            && lhs.content.thumbnailKey(specialSlotId: lhs.specialSlotId, slot: lhs.slot)
                == rhs.content.thumbnailKey(specialSlotId: rhs.specialSlotId, slot: rhs.slot)
            && lhs.label == rhs.label
            && lhs.saveShortcut == rhs.saveShortcut
            && lhs.pasteShortcut == rhs.pasteShortcut
            && lhs.isLastPasted == rhs.isLastPasted
            && lhs.isFlashHighlighted == rhs.isFlashHighlighted
            && lhs.connectionDotColor == rhs.connectionDotColor
            && lhs.isConnectionMode == rhs.isConnectionMode
            && lhs.connectedPorts == rhs.connectedPorts
            && lhs.highlightedPort == rhs.highlightedPort
            && lhs.isPortVisible == rhs.isPortVisible
            && lhs.store === rhs.store
    }
}

// MARK: - Slot card action buttons

/// A compact rounded-rectangle style used by the card's primary actions.
/// It intentionally avoids the system bordered styles so a slot keeps its own identity.
private struct SlotActionButtonStyle: ButtonStyle {
    enum Kind {
        case accent(Color)
        case destructive
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        SlotActionButtonBody(configuration: configuration, kind: kind)
    }
}

private struct SlotActionButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: SlotActionButtonStyle.Kind

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var isDangerActive: Bool {
        if case .destructive = kind { return isHovering || configuration.isPressed }
        return false
    }

    private var backgroundColor: Color {
        guard isEnabled else {
            return colorScheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.10)
        }
        switch kind {
        case .accent(let color):
            return color
        case .destructive:
            if isDangerActive {
                return colorScheme == .dark ? AppTheme.danger : AppTheme.danger.opacity(0.14)
            }
            return colorScheme == .dark
                ? Color(red: 0.20, green: 0.21, blue: 0.23)
                : Color.black.opacity(0.075)
        }
    }

    private var foregroundColor: Color {
        guard isEnabled else { return .secondary }
        switch kind {
        case .accent:
            // Both themes use dark ink to preserve contrast over the vivid slot colors.
            return colorScheme == .dark ? Color.black.opacity(0.82) : Color.black.opacity(0.72)
        case .destructive:
            if colorScheme == .dark { return AppTheme.onAccentText }
            return isDangerActive ? AppTheme.danger : Color.black.opacity(0.68)
        }
    }

    private var backgroundBrightness: Double {
        guard colorScheme == .light, isHovering else { return 0 }
        if case .accent = kind { return -0.04 }
        return 0
    }

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
                    .brightness(backgroundBrightness)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(isEnabled ? 0.16 : 0.06), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .shadow(
                        color: backgroundColor.opacity(isEnabled ? 0.22 : 0),
                        radius: configuration.isPressed ? 1 : 4,
                        y: configuration.isPressed ? 0 : 2
                    )
                    .allowsHitTesting(false)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(isEnabled ? 1 : 0.68)
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(Anim.interactive, value: configuration.isPressed)
            .animation(Anim.interactive, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

// MARK: - v2.7.27 SlotContent Text Edit Helpers

// v2.10.90 (perf): `isHTMLContent` 的记忆化缓存。
//
// 它原本每次求值都要 `(plainText ?? preview).lowercased()` —— 对全文做一次**完整拷贝 + 大小写折叠**，
// 再跑三次 `contains`。而它在卡片 body 路径上被反复触发：`canEditContent` 直接调它一次，若为 false 还会
// 走 `isPlainEditableText`，后者内部**又**调一次；`editActionTitle` 再走一遍 `canEditContent` →
// 一次卡片 body 求值最多 4 次全文 lowercased()。hover 会重算整张卡片 body，编辑长文本时更是每个字符
// 都要重来一轮，正好落在最需要跟手的两条路径上。
//
// 沿用本项目既有做法（`SlotContent.preview` / `plainText` 已用同款 NSCache），以
// `contentId::updatedAt` 为键——内容一变键就变，不会读到过期结果。
private let slotIsHTMLCache: NSCache<NSString, NSNumber> = {
    let cache = NSCache<NSString, NSNumber>()
    cache.countLimit = 500
    return cache
}()

private extension SlotContent {
    var isHTMLContent: Bool {
        let key = "\(contentId)::\(updatedAt)::isHTML" as NSString
        if let cached = slotIsHTMLCache.object(forKey: key) { return cached.boolValue }
        let result = computeIsHTMLContent()
        slotIsHTMLCache.setObject(NSNumber(value: result), forKey: key)
        return result
    }

    private func computeIsHTMLContent() -> Bool {
        if let htmlSource, !htmlSource.isEmpty { return true }
        if let url = primaryFileURL, ["html", "htm"].contains(url.pathExtension.lowercased()) { return true }
        let raw = (plainText ?? preview).lowercased()
        return raw.contains("<html") || raw.contains("<!doctype html") || raw.contains("<body")
    }
    var htmlEditableValue: String { htmlSource ?? plainText ?? preview }
    var isPlainEditableText: Bool {
        // ATT-2 (v2.10.32): use the cheap `hasImage` type check instead of `inlineImage`.
        // This is evaluated in the card's actionRow body on every render; `inlineImage`
        // would fully decode a pasted image on the main thread. That used to be masked
        // because the grid thumbnail warmed the full-res cache, but the grid now decodes
        // only a downsampled thumbnail (see decodedInlineThumbnail), so reading
        // `inlineImage` here would re-introduce a main-thread full decode.
        primaryFileURL == nil && !hasImage && !isHTMLContent && !preview.hasPrefix("[图片") && !preview.hasPrefix("[文件") && !preview.hasPrefix("[富文本]")
    }
    var editableTextValue: String { plainText ?? preview }
}

// MARK: - v2.7.23 Inline Video Preview

private struct InlineSlotVideoPreview: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var poster: NSImage?

    var body: some View {
        ZStack {
            // v2.7.35: match image thumbnail background instead of hard black.
            Color(NSColor.controlBackgroundColor).opacity(0.55)

            if let player {
                SafeInlineAVPlayerView(player: player)
                    .padding(0)
            } else if let poster {
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.85))
                    Text("视频")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            VStack {
                Spacer()
                HStack {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("点击预览")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(AppTheme.onAccentText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.38)))
                .padding(.bottom, 7)
            }
        }
        .frame(maxWidth: .infinity)
        // v2.9.18: 与图片/文本缩略图一致，视频预览也改自适应高度填满灰框。
        .frame(minHeight: 120, idealHeight: 160, maxHeight: .infinity)
        .task(id: url) {
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                try Task.checkCancellation()
                loadPosterIfNeeded()
                guard player == nil else { player?.play(); return }
                let p = AVPlayer(url: url)
                p.isMuted = true
                player = p
                p.play()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func loadPosterIfNeeded() {
        guard poster == nil else { return }
        ThumbnailProvider.shared.thumbnail(
            for: url,
            cacheKey: "video-card-poster-\(url.absoluteString)",
            size: CGSize(width: 420, height: 240)
        ) { image, _ in
            poster = image
        }
    }
}

private struct SafeInlineAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        // v2.7.34: show the complete video composition in the card thumbnail.
        // resizeAspectFill cropped faces/edges and made the thumbnail look incomplete.
        view.videoGravity = .resizeAspect
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

// MARK: - v2.7.28 Refined Drop UX

private struct DropImportOverlay: View {
    let slot: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.slotCardCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.slotCardCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )

            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.16))
                        .frame(width: 46, height: 46)
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.accentColor)
                }

                VStack(spacing: 3) {
                    Text("松开导入到槽位 \(slot)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("图片、视频、PDF、文件夹")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 18)
        }
    }
}
