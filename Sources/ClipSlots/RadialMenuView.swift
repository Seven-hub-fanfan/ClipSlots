import SwiftUI
import ClipSlotsKit

// MARK: - Radial Menu Mode

enum RadialMenuMode {
    case childSlots
    case specialSlots
}

// MARK: - Pie Segment Shape

struct PieSegmentShape: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let endRad = CGFloat(endAngle.radians)
        var path = Path()

        path.addArc(center: center, radius: outerRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.addLine(to: CGPoint(x: center.x + innerRadius * cos(endRad), y: center.y + innerRadius * sin(endRad)))
        path.addArc(center: center, radius: innerRadius, startAngle: endAngle, endAngle: startAngle, clockwise: true)
        path.closeSubpath()

        return path
    }
}

// MARK: - Sector Outer Arc (v2.11.1「上次粘贴」标识)

/// 只描扇区**外沿**的一段圆弧。
///
/// 与 `PieSegmentShape().stroke()` 的区别：后者会同时描出两条径向边和内弧，
/// 那两条径向边正好压在相邻扇区的分隔线上，视觉上像是选中了两个扇区。
/// 状态标识要的是「这一格的外框亮起来」，因此单独一个只画外弧的 Shape。
struct SegmentOuterArcShape: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: radius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: false)
        return path
    }
}

// MARK: - Radial Glass Pill (v2.4.5)

private struct RadialGlassPill<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let content: Content

    init(
        horizontalPadding: CGFloat = 10,
        verticalPadding: CGFloat = 5,
        @ViewBuilder content: () -> Content
    ) {
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .foregroundColor(AppTheme.radialGlassButtonText(colorScheme))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                Capsule()
                    .fill(AppTheme.radialGlassButtonTint(colorScheme))
                    .background(AppTheme.radialMaterial(colorScheme), in: Capsule())
            )
            .overlay(
                Capsule()
                    .stroke(AppTheme.radialGlassButtonStroke(colorScheme), lineWidth: 0.7)
            )
            .overlay(
                Capsule()
                    .stroke(AppTheme.radialGlassButtonInnerStroke(colorScheme), lineWidth: 0.4)
                    .padding(0.6)
            )
            .shadow(color: AppTheme.radialGlassButtonShadow(colorScheme), radius: 3, x: 0, y: 1)
    }
}

// MARK: - Radial Menu View (v2.4.2: page selector + group switcher)

struct RadialMenuView: View {
    @ObservedObject var store: SlotStoreObservable
    var onSelectSlot: (Int) -> Void
    var onPasteAll: (() -> Void)? = nil
    var onDismiss: () -> Void
    var connectionMap: SlotConnectionMap = .empty

    private var liveConnectionMap: SlotConnectionMap {
        // v2.7.26: always prefer the store's live currentConnectionMap.
        // The fallback keeps compatibility with older callers.
        store.currentConnectionMap.edges.isEmpty ? connectionMap : store.currentConnectionMap
    }

    private var hoveredPreviewContent: SlotContent? {
        guard let idx = effectiveIndex else { return nil }
        if mode == .childSlots {
            return store.slots[idx]
        }
        let groups = store.currentPageSlotGroups
        guard idx >= 0, idx < groups.count else { return nil }
        let targetGroup = groups[idx]
        // v2.7.58: when hovering a slot group in radial menu, preview the target
        // group's first non-empty slot, not the current group's current slot content.
        return store.firstNonEmptySlotContent(pageId: store.currentPageId, specialSlotId: targetGroup.id)
    }

    private var previewTitle: String {
        guard let idx = effectiveIndex else { return "实时预览" }
        if mode == .childSlots { return store.labels[idx] ?? "槽位 \(idx)" }
        let groups = store.currentPageSlotGroups
        guard idx >= 0, idx < groups.count else { return "实时预览" }
        return "\(groups[idx].name) · 预览"
    }

    private var hoveredPreviewPayload: RadialHoverPreviewPayload? {
        guard let idx = effectiveIndex else { return nil }
        if mode == .childSlots {
            // v2.11.0 hotfix2：空槽也可能有手动封面图（扇区已显示），这类槽位同样要发预览 payload，
            // 否则悬停它时预览窗只剩空态。有内容的槽位行为完全不变。
            guard let content = store.slots[idx], !content.isEmpty || content.hasManualThumbnail else { return nil }
            return RadialHoverPreviewPayload(
                title: store.labels[idx] ?? "槽位 \(idx)",
                subtitle: "实时预览",
                content: content,
                pageId: store.currentPageId,
                specialSlotId: store.currentSpecialSlotId,
                slot: idx
            )
        }
        let groups = store.currentPageSlotGroups
        guard idx >= 0, idx < groups.count else { return nil }
        let targetGroup = groups[idx]
        guard let snapshot = store.firstNonEmptySlotSnapshot(pageId: store.currentPageId, specialSlotId: targetGroup.id) else { return nil }
        return RadialHoverPreviewPayload(
            title: targetGroup.name,
            subtitle: "第 \(snapshot.slot) 槽 · 实时预览",
            content: snapshot.content,
            pageId: store.currentPageId,
            specialSlotId: targetGroup.id,
            slot: snapshot.slot
        )
    }

    @State private var hoveredIndex: Int? = nil
    @State private var appeared = false
    @State private var mode: RadialMenuMode = .childSlots
    // v2.11.1「圆盘内跳转到上次粘贴」：由底栏按钮设置的**程序化**聚焦槽位。
    // 与 hoveredIndex 分开存：鼠标一旦接管（updateHover / handleTap）就清掉它，
    // 否则鼠标移开扇区后聚焦会「复活」，看起来像高亮卡住了。
    @State private var focusedSlot: Int? = nil
    // 聚焦所属的组。切组是异步读盘（loadSlotsAsync），期间 currentSpecialSlotId 已经变了但
    // slots 还是旧组的；记住组 id 才能判断这次聚焦是否仍指向用户当前看到的组。
    @State private var focusedGroupId: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    /// 圆盘当前「生效」的索引：鼠标 hover 优先，其次才是「上次粘贴」跳转带来的程序化聚焦。
    /// 扇区高亮、中心提示、预览窗 payload 统一走它，这样跳转后的表现与手动 hover 完全一致。
    private var effectiveIndex: Int? {
        if let hoveredIndex { return hoveredIndex }
        guard mode == .childSlots,
              let focusedSlot,
              focusedGroupId == store.currentSpecialSlotId else { return nil }
        return focusedSlot
    }

    private let menuSize: CGFloat = 372
    // v2.7.12: keep hover segments safely inside the radial disk.
    // Previous hover style scaled the whole sector and used outerRadius directly,
    // causing blue sectors to protrude outside the white circle at 1/5/6/8 etc.
    private let segmentOuterInset: CGFloat = 8
    private let segmentInnerInset: CGFloat = 1.5

    private var displayCount: Int {
        mode == .childSlots ? store.config.slots : store.currentPageSlotGroups.count
    }

    private var canSwitchGroup: Bool {
        store.currentPageSlotGroups.count > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            // v2.4.6: Vertical two-tier page + scope
            topNavigationStack
                .padding(.bottom, 6)

            // Radial circle
            ZStack {
                GeometryReader { geo in
                    let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    let outerRadius = min(geo.size.width, geo.size.height) / 2
                    let segmentOuterRadius = outerRadius - segmentOuterInset
                    let deadZoneRadius = outerRadius * 0.24
                    let segmentInnerRadius = deadZoneRadius + segmentInnerInset

                    ZStack {
                        Circle()
                            .fill(AppTheme.radialBackground(colorScheme))
                            .background(AppTheme.radialMaterial(colorScheme), in: Circle())
                            .overlay(
                                Circle()
                                    .stroke(AppTheme.radialOuterStroke(colorScheme), lineWidth: 0.9)
                            )
                            .overlay(
                                Circle()
                                    .stroke(AppTheme.radialOuterGlow(colorScheme), lineWidth: 1.2)
                                    .blur(radius: 0.6)
                                    .padding(1.2)
                            )
                            .overlay(
                                Circle()
                                    .stroke(AppTheme.radialInnerShadow(colorScheme), lineWidth: 7)
                                    .blur(radius: 5)
                                    .padding(6)
                            )

                        if displayCount > 0 {
                            ForEach(0..<displayCount, id: \.self) { i in
                                let segmentAngle = 360.0 / Double(displayCount)
                                let a = Angle(degrees: Double(i) * segmentAngle - 90)
                                dividerLine(
                                    center: center,
                                    angle: a,
                                    innerRadius: deadZoneRadius + 2,
                                    outerRadius: segmentOuterRadius
                                )
                                .stroke(AppTheme.radialDivider(colorScheme), lineWidth: 1)
                            }
                        }

                        if mode == .childSlots {
                            childSlotSegments(center: center, outerRadius: segmentOuterRadius, deadZoneRadius: segmentInnerRadius)
                        } else {
                            specialSlotSegments(center: center, outerRadius: segmentOuterRadius, deadZoneRadius: segmentInnerRadius)
                        }

                        Circle()
                            .stroke(AppTheme.radialDivider(colorScheme), lineWidth: 1)
                            .frame(width: deadZoneRadius * 2 + 4, height: deadZoneRadius * 2 + 4)

                        centerView(deadZoneRadius: deadZoneRadius)
                    }
                    .frame(width: outerRadius * 2, height: outerRadius * 2)
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .scaleEffect(appeared ? 1 : 0.92)
                    .opacity(appeared ? 1 : 0)
                    .animation(Anim.transition, value: appeared)
                    .onAppear { appeared = true }
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let location):
                            updateHover(location: location, center: center, deadZoneRadius: deadZoneRadius)
                        case .ended:
                            if hoveredIndex != nil {
                                hoveredIndex = nil
                                postHoverPreviewPayload()
                            }
                        }
                    }
                    .onTapGesture {
                        handleTap()
                    }
                }
            }
            .frame(width: menuSize, height: menuSize)
            .shadow(color: AppTheme.radialShadow(colorScheme), radius: 18, x: 0, y: 10)
            .compositingGroup()

            // v2.4.2: Slot group switcher
            groupSwitcher
                .padding(.top, 8)
                .padding(.bottom, 6)
        }
        .frame(width: menuSize + 56)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        // v2.11.1: 跨组跳转时 switchSpecialSlot 走的是异步读盘（loadSlotsAsync）。扇区高亮按
        // 「槽位序号」渲染、与内容无关，可以立刻生效；但预览窗 payload 依赖 store.slots，
        // 点击瞬间读到的还是旧组内容。等新组数据提交（slotsContentSignature 变化）后补发一次。
        .onChange(of: store.slotsContentSignature) { _ in
            guard hoveredIndex == nil, effectiveIndex != nil else { return }
            postHoverPreviewPayload()
        }
        // 用户手动切组（圆盘左右箭头 / 组扇区 / 页面切换）后，旧的程序化聚焦不再有意义。
        .onChange(of: store.currentSpecialSlotId) { newValue in
            if focusedGroupId != newValue { clearProgrammaticFocus() }
        }
    }

    // MARK: - Top Navigation (v2.4.6: vertical two-tier)

    private var topNavigationStack: some View {
        pageSelectorGlass
    }

    private var pageSelectorGlass: some View {
        Menu {
            ForEach(store.pages) { page in
                Button {
                    store.switchToPage(id: page.id)
                } label: {
                    if page.id == store.currentPageId {
                        Label(page.name, systemImage: "checkmark")
                    } else {
                        Text(page.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))

                Text(store.currentPage?.name ?? "默认页面")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(AppTheme.radialGlassButtonText(colorScheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(AppTheme.radialGlassButtonTint(colorScheme))
                    .background(AppTheme.radialMaterial(colorScheme), in: Capsule())
            )
            .overlay(
                Capsule()
                    .stroke(AppTheme.radialGlassButtonStroke(colorScheme), lineWidth: 0.7)
            )
            .overlay(
                Capsule()
                    .stroke(AppTheme.radialGlassButtonInnerStroke(colorScheme), lineWidth: 0.4)
                    .padding(0.6)
            )
            .shadow(color: AppTheme.radialGlassButtonShadow(colorScheme), radius: 3, x: 0, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: - Group Switcher (v2.4.2)

    private var groupSwitcher: some View {
        RadialGlassPill(horizontalPadding: 10, verticalPadding: 5) {
            HStack(spacing: 8) {
                Button {
                    store.switchToPreviousSlotGroup()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(!canSwitchGroup)
                .opacity(canSwitchGroup ? 1 : 0.35)

                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.82)

                    Text(store.currentSpecialSlot?.name ?? "默认槽位组")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140)
                }

                // v2.11.1: 「上次粘贴」跳转。位置刻意夹在组名 chip 与「全部粘贴」之间——
                // 左侧是「我现在在哪」，右侧是「对这一组做什么」，中间放「回到刚才那一格」。
                lastPasteJumpButton

                Button {
                    handlePasteAll()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("全部粘贴")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .help("粘贴当前槽位组全部非空内容")

                Button {
                    store.switchToNextSlotGroup()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(!canSwitchGroup)
                .opacity(canSwitchGroup ? 1 : 0.35)
            }
        }
    }

    // MARK: - Jump to Last Paste (v2.11.1, radial-only)

    /// 底栏「上次粘贴」定位按钮。
    ///
    /// v2.11.3 hotfix2：由纯图标（`checkmark.circle.fill`）改成**带文字的胶囊按钮**。
    /// 纯图标在这条底栏里辨识度不够——左右邻居分别是「📁 组名」和「全部粘贴」两个带字元素，
    /// 中间夹一颗无字圆点，用户得靠 tooltip 才知道它干什么。
    ///
    /// 样式对齐底栏既有语言：`radialGlassButtonTint` 深灰胶囊底 + `radialGlassButtonText`
    /// 高对比文字 + `radialGlassButtonStroke` 描边，与组名 chip / 页面切换 chip 同一套 token，
    /// 因此亮暗模式自动跟随（亮色=半透白底深字，暗色=半透黑底白字）。
    /// 保留一枚 10pt 小对勾在文字左侧：卡片胶囊 / 扇区外弧 / 这颗按钮三处共用同一个符号，
    /// 视觉上串成同一个概念。刻意不用 `checkmark.arrow.trianglehead.counterclockwise`
    /// ——那是 SF Symbols 6（macOS 15+）才有的符号，本 App 最低支持 13.0，老系统会渲染成空白方块。
    ///
    /// 无记录时整颗置灰（0.35）并禁用，tooltip 提示「尚未粘贴过任何槽位」。
    ///
    /// v2.11.4：有记录时胶囊底色改成**目标槽位自己的颜色**（@0.65），文字/图标按合成后亮度
    /// 自动取黑或白（`SlotAccentPalette.pillInk`，走 WCAG 对比度而非 HSB brightness——
    /// 后者会把深蓝和亮黄判成同一亮度，必然选错墨色）。这样这颗按钮、卡片角标、扇区外弧
    /// 三处的颜色是同一个，眼睛不用二次翻译「上次粘贴的是哪一格」。
    /// 无记录时保持原来的玻璃灰 token，不做染色。
    private var lastPasteJumpButton: some View {
        let address = store.lastPasteAddress
        let accentSlot = address?.slot
        return Button {
            jumpToLastPasteInRadial()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("上次粘贴")
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundColor(AppTheme.radialSlotPillText(slot: accentSlot))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(AppTheme.radialSlotPillFill(slot: accentSlot)))
            .overlay(Capsule().stroke(AppTheme.radialSlotPillStroke(slot: accentSlot), lineWidth: 0.7))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(address == nil)
        .opacity(address == nil ? 0.35 : 1)
        .help(store.lastPasteDescription.map { "在圆盘内定位到上次粘贴：\($0)" } ?? "尚未粘贴过任何槽位")
    }

    /// 圆盘内跳转到「上次粘贴」的槽位。
    ///
    /// 刻意**不复用** `store.jumpToLastPaste()`：那条路径是为主界面卡片设计的
    /// （flashHighlightSlot → 滚动定位 + 2s 闪烁），还要求主窗口在前台。圆盘这颗按钮的诉求
    /// 恰恰相反——**不打开 GUI、不抢焦点**也能定位。所以这里只做三件事：
    ///   1. 切到目标组（`switchSpecialSlot` = `selectAndActivateSpecialSlot`，内部会一并同步
    ///      pages / currentPageId，因此跨页也是这一句搞定）；
    ///   2. 把扇区聚焦到目标槽位（`focusedSlot` / `focusedGroupId` → `effectiveIndex`）；
    ///   3. 让预览窗跟着切过去（postHoverPreviewPayload）。
    ///
    /// 圆盘保持打开，不 `onDismiss()`、不 `makeKeyAndOrderFront`、不 `NSApp.activate` ——
    /// 主界面的页/组状态由 store 自己更新，磁盘侧 FSEvents 也会自然感知，无需前台化。
    private func jumpToLastPasteInRadial() {
        guard let address = store.lastPasteAddress else { return }

        // 若当前停在「组扇区」模式，先回到槽位模式，否则聚焦的槽位序号无处可高亮。
        mode = .childSlots
        // 鼠标可能正悬在别的扇区上：程序化聚焦要立刻生效，就得先让 hover 让位。
        hoveredIndex = nil
        focusedGroupId = address.groupId
        focusedSlot = address.slot

        if store.currentSpecialSlotId != address.groupId {
            store.switchSpecialSlot(id: address.groupId)
        }

        // 同组直接命中；跨组时这一发用的还是旧组内容，等 slotsContentSignature 变化后
        // body 上的 onChange 会补发一次正确的 payload（见 body 末尾注释）。
        postHoverPreviewPayload()
    }

    /// 鼠标接管后放弃程序化聚焦。
    private func clearProgrammaticFocus() {
        guard focusedSlot != nil || focusedGroupId != nil else { return }
        focusedSlot = nil
        focusedGroupId = nil
    }

    // MARK: - Child Slot Segments

    @ViewBuilder
    private func childSlotSegments(center: CGPoint, outerRadius: CGFloat, deadZoneRadius: CGFloat) -> some View {
        let slotCount = store.config.slots
        ForEach(1...slotCount, id: \.self) { slot in
            let content = store.slots[slot] ?? SlotContent()
            let segmentAngle = 360.0 / Double(slotCount)
            let startAngle = Angle(degrees: Double(slot - 1) * segmentAngle - 90)
            let endAngle = Angle(degrees: Double(slot) * segmentAngle - 90)
            let midAngle = Angle(degrees: (Double(slot - 1) + 0.5) * segmentAngle - 90)
            // v2.11.1: hover 与「上次粘贴跳转」的程序化聚焦走同一套高亮，用 effectiveIndex 统一。
            let isHovered = effectiveIndex == slot
            // v2.11.1: 「上次粘贴」标识——只在扇区外沿描一段弧，不占扇区内部任何空间。
            let isLastPasted = store.isLastPasted(slot: slot, groupId: store.currentSpecialSlotId)

            ZStack {
                PieSegmentShape(startAngle: startAngle, endAngle: endAngle, innerRadius: deadZoneRadius, outerRadius: outerRadius)
                    // v2.11.4: 悬停填充改用**该槽位自己的颜色**（原先是统一的系统强调色蓝）。
                    // 非悬停态仍走原来的白玻璃档位 —— 十格全染色会变成调色盘，反而看不出焦点。
                    .fill(isHovered
                          ? AppTheme.radialSegmentHoverFill(slot: slot)
                          : AppTheme.radialSegment(colorScheme, isEmpty: content.isEmpty, isHovered: false))

                if isHovered {
                    PieSegmentShape(startAngle: startAngle, endAngle: endAngle, innerRadius: deadZoneRadius, outerRadius: outerRadius)
                        .stroke(AppTheme.radialSegmentHoverStroke(slot: slot), lineWidth: 2)
                        .background(
                            PieSegmentShape(startAngle: startAngle, endAngle: endAngle, innerRadius: deadZoneRadius, outerRadius: outerRadius)
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.22))
                                .blur(radius: 0.4)
                        )
                }

                // 外沿高亮弧放在 hover 描边**之上**：hover 时也要看得见这格是上次粘贴的。
                // v2.11.4 hotfix：改用 `radialSlotAccent`（提亮版）——基础色描在深色扇区外沿
                // 会闷成一条暗边，尤其琥珀/橄榄那两支几乎看不出是高亮。色相与主界面卡片角标一致。
                if isLastPasted,
                   let arc = RadialSegmentLayoutCalculator.lastPasteArc(outerRadius: outerRadius,
                                                                       startDegrees: startAngle.degrees,
                                                                       endDegrees: endAngle.degrees) {
                    SegmentOuterArcShape(startAngle: .degrees(arc.startDegrees),
                                         endAngle: .degrees(arc.endDegrees),
                                         radius: arc.radius)
                        .stroke(AppTheme.radialSlotAccent(slot),
                                style: StrokeStyle(lineWidth: arc.lineWidth, lineCap: .round))
                        .shadow(color: AppTheme.radialSlotAccent(slot).opacity(0.45), radius: 3)
                        .allowsHitTesting(false)
                }

                segmentLabel(slot: slot,
                             content: content,
                             label: store.labels[slot] ?? "",
                             angle: midAngle,
                             midRadius: (deadZoneRadius + outerRadius) / 2,
                             innerRadius: deadZoneRadius,
                             outerRadius: outerRadius,
                             segmentDegrees: segmentAngle)
            }
            // v2.7.12: do not scale the sector. Scaling pushes arc edges outside
            // the circular disk and creates the visible broken blue caps.
            .animation(Anim.interactive, value: isHovered)
        }
    }

    // MARK: - Special Slot Segments (v2.4.2: current page only)

    @ViewBuilder
    private func specialSlotSegments(center: CGPoint, outerRadius: CGFloat, deadZoneRadius: CGFloat) -> some View {
        let groups = store.currentPageSlotGroups  // v2.4.2: per-page instead of global

        ForEach(Array(groups.enumerated()), id: \.element.id) { i, special in
            let segmentAngle = 360.0 / Double(groups.count)
            let startAngle = Angle(degrees: Double(i) * segmentAngle - 90)
            let endAngle = Angle(degrees: Double(i + 1) * segmentAngle - 90)
            let midAngle = Angle(degrees: (Double(i) + 0.5) * segmentAngle - 90)
            let isHovered = hoveredIndex == i
            let isCurrent = special.id == store.currentSpecialSlotId

            ZStack {
                PieSegmentShape(startAngle: startAngle, endAngle: endAngle, innerRadius: deadZoneRadius, outerRadius: outerRadius)
                    .fill(AppTheme.radialSegment(colorScheme, isEmpty: false, isHovered: isHovered))

                if isHovered {
                    PieSegmentShape(startAngle: startAngle, endAngle: endAngle, innerRadius: deadZoneRadius, outerRadius: outerRadius)
                        .stroke(AppTheme.radialStroke(colorScheme, isHovered: true), lineWidth: 2)
                        .background(
                            PieSegmentShape(startAngle: startAngle, endAngle: endAngle, innerRadius: deadZoneRadius, outerRadius: outerRadius)
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.22))
                                .blur(radius: 0.4)
                        )
                }

                specialSlotLabel(name: special.name, index: i + 1, isCurrent: isCurrent, angle: midAngle, midRadius: (deadZoneRadius + outerRadius) / 2)
            }
            // v2.7.12: no sector scaling; keep highlight clipped inside disk.
            .animation(Anim.interactive, value: isHovered)
        }
    }

    // MARK: - Tap Handling

    private func handleTap() {
        let cnt = displayCount
        if cnt == 0 {
            mode = .childSlots
            return
        }

        // v2.11.1: 圆盘上的任意点击都视为「鼠标接管」，先释放程序化聚焦。
        // 注意 handleTap 只处理**圆盘内**的点击（底栏按钮走各自的 Button action，不经过这里），
        // 所以点「上次粘贴」跳转按钮不会自己把刚设好的聚焦清掉。
        clearProgrammaticFocus()

        if mode == .childSlots, hoveredIndex == nil {
            mode = .specialSlots
            hoveredIndex = nil
            return
        }

        if mode == .specialSlots, hoveredIndex == nil {
            mode = .childSlots
            hoveredIndex = nil
            return
        }

        guard let idx = hoveredIndex else { return }

        if mode == .childSlots {
            let slot = idx
            let content = store.slots[slot] ?? SlotContent()
            if content.isEmpty { onDismiss(); return }
            onSelectSlot(slot)
        } else {
            // v2.4.2: switch to selected slot group in current page
            let groups = store.currentPageSlotGroups
            guard idx < groups.count else { return }
            let special = groups[idx]
            store.switchSpecialSlot(id: special.id)
            // Force radial menu to redraw labels / connection dots immediately after group switch.
            hoveredIndex = nil
            mode = .childSlots
        }
    }

    private func updateHover(location: CGPoint, center: CGPoint, deadZoneRadius: CGFloat) {
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let cnt = displayCount

        // v2.11.1: 指针一进入圆盘就交还控制权——「上次粘贴」跳转带来的程序化聚焦到此为止。
        // 不这么做的话，鼠标划过扇区再移开（hoveredIndex 归 nil）时聚焦会「复活」，
        // 高亮看起来像卡在了一个用户早已离开的槽位上。
        clearProgrammaticFocus()

        if distance < deadZoneRadius || cnt == 0 {
            if hoveredIndex != nil {
                hoveredIndex = nil
                postHoverPreviewPayload()
            }
            return
        }

        var angle = atan2(dy, dx) * 180 / .pi + 90
        if angle < 0 { angle += 360 }
        let segmentAngle = 360.0 / Double(cnt)
        let index = Int(angle / segmentAngle)
        let capped = min(index + 1, cnt)

        let nextHoveredIndex = mode == .childSlots ? capped : index
        if hoveredIndex != nextHoveredIndex {
            hoveredIndex = nextHoveredIndex
            postHoverPreviewPayload()
        }
    }

    private func postHoverPreviewPayload() {
        NotificationCenter.default.post(
            name: .radialMenuHoveredSlotChanged,
            object: nil,
            userInfo: [
                "mode": mode == .childSlots ? "childSlots" : "specialSlots",
                // v2.11.1: 用 effectiveIndex —— 「上次粘贴」跳转后没有鼠标 hover，
                // 但预览窗同样要跟着切到目标槽位（这正是「不开 GUI 也能看」的关键）。
                "slot": effectiveIndex as Any,
                "preview": hoveredPreviewPayload as Any
            ]
        )
    }

    @ViewBuilder
    private func centerView(deadZoneRadius: CGFloat) -> some View {
        let idx = effectiveIndex

        Circle()
            .fill(AppTheme.radialCenterBackground(colorScheme))
            .background(AppTheme.radialMaterial(colorScheme), in: Circle())
            .frame(width: deadZoneRadius * 2, height: deadZoneRadius * 2)
            .overlay(
                Circle().stroke(AppTheme.radialOuterStroke(colorScheme), lineWidth: 0.8)
            )
            .shadow(color: AppTheme.radialShadow(colorScheme), radius: 8, x: 0, y: 4)
            .overlay {
                VStack(spacing: 4) {
                    if mode == .childSlots {
                        Image(systemName: idx != nil ? "arrow.up.doc.fill" : "folder.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(idx != nil ? .accentColor : .secondary)

                        if let slot = idx {
                            let chain = liveConnectionMap.chainSlots(startingAt: slot)
                            if chain.count > 1 {
                                Text("槽位 \(slot)")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("串联 \(chain.count) 个槽位")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                                Text(compactChainDescription(chain))
                                    .font(.system(size: 7))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text("槽位 \(slot)")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("点击粘贴")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text(store.currentSpecialSlot?.name ?? "默认槽位组")
                                .font(.system(size: 9, weight: .semibold))
                                .lineLimit(1)
                                .frame(width: deadZoneRadius * 1.5)
                            Text("点击切组")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.accentColor)

                        Text("返回")
                            .font(.system(size: 10, weight: .semibold))
                        Text("子槽位")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
            }
    }

    /// v2.11.0：解析扇区里某槽位手动缩略图的磁盘 URL。
    ///
    /// 轮盘只在 `.childSlots` 模式下展示当前组的子槽位，因此直接查当前组即可；
    /// `.specialSlots` 模式画的是「组」而非槽位，没有手动缩略图的概念。
    /// 存储层会顺带校验字节文件存在性，缺失时返回 nil → 扇区自动退回原有纯文字展示。
    private func manualThumbnailURL(slot: Int, manualThumbnailId: String) -> URL? {
        guard mode == .childSlots else { return nil }
        return SpecialSlotStorage.shared.manualThumbnailURL(slot, in: store.currentSpecialSlotId)
    }

    @ViewBuilder
    private func segmentLabel(slot: Int,
                              content: SlotContent,
                              label: String,
                              angle: Angle,
                              midRadius: CGFloat,
                              innerRadius: CGFloat,
                              outerRadius: CGFloat,
                              segmentDegrees: Double) -> some View {
        let rad = CGFloat(angle.radians)
        // v2.11.1: 文字/缩略图的 hover 态同样用 effectiveIndex，跳转后的扇区表现与手动 hover 一致。
        let isHovered = effectiveIndex == slot

        // v2.11.0「槽位缩略图手动上传」：手动封面图在扇区内以圆角方形（center-crop）呈现。
        //
        // 只对**手动**缩略图生效，自动缩略图维持原样：轮盘是「瞬时弹出 → 扫一眼 → 松手选中」的
        // 高频交互，为 10 个扇区同步解 10 张自动缩略图会让弹出明显掉帧；而手动封面图是用户主动
        // 设的强识别信号（就是为了「一眼认出这是哪个槽」），值得这点开销，且实测只有少数槽位会设。
        let manual: (id: String, url: URL)? = {
            guard let manualId = content.manualThumbnailId, !manualId.isEmpty,
                  let manualURL = manualThumbnailURL(slot: slot, manualThumbnailId: manualId) else { return nil }
            return (manualId, manualURL)
        }()

        // v2.11.0 hotfix：缩略图与文字块**各自**沿扇区中轴线取极坐标锚点，不再共用一个 VStack。
        //
        // 旧写法把两者塞进 VStack 再对整体 .offset 到中轴线中点，于是缩略图被推到 VStack 顶部 =
        // 「屏幕正上方」。除了正上方那个扇区，这个位移都有垂直于中轴线的分量，实测 10 槽位下 8 个
        // 扇区的缩略图角偏差 25°~30°（半扇区仅 18°）——直接歪进邻居扇区，顶部扇区还紧贴圆盘边缘。
        // 现在两个锚点都在中轴线上，位移方向恒为径向，方位角再变也不会漂出楔形。
        let layout = manual == nil
            ? nil
            : RadialSegmentLayoutCalculator.layout(innerRadius: innerRadius,
                                                   outerRadius: outerRadius,
                                                   segmentDegrees: segmentDegrees)

        ZStack {
            if let manual, let layout {
                let side = layout.thumbnailSide
                let corner = max(6, side * 0.18)
                ManualThumbnailImage(manualThumbnailId: manual.id,
                                     url: manual.url,
                                     side: side,
                                     cornerRadius: corner) {
                    // 解码未就绪时用等尺寸占位，避免图一出现就把布局撑开、造成扇区内容跳动。
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: side, height: side)
                }
                .offset(x: layout.thumbnailRadius * cos(rad),
                        y: layout.thumbnailRadius * sin(rad))

                segmentTextBlock(slot: slot, content: content, label: label, isHovered: isHovered,
                                 textWidth: layout.textBlockWidth)
                    .offset(x: layout.textRadius * cos(rad),
                            y: layout.textRadius * sin(rad))
            } else {
                // 无手动缩略图（或扇区太窄放不下）：仍走「纯文字居中」的原有布局，
                // 只是标签宽度同样按楔形弦宽收敛，避免长标签横向压过扇区分隔线。
                segmentTextBlock(slot: slot, content: content, label: label, isHovered: isHovered,
                                 textWidth: RadialSegmentLayoutCalculator.textBlockWidth(
                                    atRadius: midRadius,
                                    segmentDegrees: segmentDegrees,
                                    preferred: midRadius * 0.78))
                    .offset(x: midRadius * cos(rad), y: midRadius * sin(rad))
            }
        }
        .animation(Anim.interactive, value: isHovered)
    }

    /// 扇区内的文字块：槽位编号（+ 串联色点）+ 标签/预览。
    /// 从 `segmentLabel` 里抽出来，好让它能作为独立元素挂到自己的中轴线锚点上。
    @ViewBuilder
    private func segmentTextBlock(slot: Int, content: SlotContent, label: String, isHovered: Bool, textWidth: CGFloat) -> some View {
        VStack(spacing: 3) {
            // v2.7.0: Slot number + connection dot
            HStack(spacing: 4) {
                Text("\(slot)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.radialPrimaryText(colorScheme, isHovered: isHovered, isEmpty: content.isEmpty))

                if let colorId = liveConnectionMap.colorId(for: slot) {
                    Circle()
                        .fill(SlotConnectionColor.color(for: colorId))
                        .frame(width: 6, height: 6)
                }

                // v2.11.1「扇区附件角标」：有附件就在编号旁挂一个回形针。
                //
                // 为什么挂在**编号这一行**而不是新起一行/挂到扇区外沿：
                //  • v2.11.0 hotfix 的教训——往 VStack 里加带高度的块 = 沿**屏幕垂直方向**位移，
                //    只有正上方那个扇区才等价于「径向向外」，其余扇区会把内容顶出楔形。
                //    HStack 是横向对称扩张，整块仍锚在原来的中轴线锚点上，几何上安全。
                //  • 扇区外沿在有手动缩略图时只剩 ~12pt（缩略图最远角已到 R+side/√2），塞不下角标。
                // 宽度不变量（编号 + 色点 + 角标 ≤ 该半径处弦宽）由
                // RadialSegmentLayoutCalculator.numberRowFits 在 smoke 测试里钉死。
                //
                // 性能：attachments 是 store.slots 里已在内存的字段（缓存层把 data 置 nil 只留
                // storagePath），isEmpty 是 O(1)。**绝不能**改用 store.attachments(for:) —— 那是
                // stat + queue.sync 的主线程同步 I/O，v2.10.89 已经在卡片上踩过一次 hover 卡顿。
                //
                // 配色（v2.11.1 用户修正）：角标染成品牌蓝紫（radialAttachmentBadge），与主界面
                // 卡片上的「附件 N」胶囊同色系；圆盘其余元素（扇区底色、hover 高亮、底栏胶囊）
                // 一律不动。
                if !content.attachments.isEmpty {
                    Image(systemName: "paperclip")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(AppTheme.radialAttachmentBadge(colorScheme))
                        .frame(width: RadialSegmentLayoutCalculator.badgeIconWidth,
                               height: RadialSegmentLayoutCalculator.badgeIconWidth)
                        .background(Circle().fill(AppTheme.radialAttachmentBadgeFill(colorScheme)))
                        .help(content.attachments.count > 1
                              ? "该槽位有 \(content.attachments.count) 个附件"
                              : "该槽位有附件")
                }
            }

            if !content.isEmpty {
                Text(label.isEmpty ? content.preview : label)
                    .font(.system(size: 9, weight: label.isEmpty ? .regular : .semibold))
                    .foregroundColor(AppTheme.radialSecondaryText(colorScheme, isHovered: isHovered))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: textWidth)
            } else {
                // v2.9.18: 空槽占位由"空"文字改为更克制的圆点符号，减少圆盘文字噪音
                //（纯 UI 占位替换，字号/颜色 token/位置计算均保持不变，不触碰任何交互逻辑）。
                Image(systemName: "circle.dotted")
                    .font(.system(size: 9))
                    .foregroundColor(AppTheme.radialEmptyText(colorScheme))
            }
        }
        // 位置由调用方（segmentLabel）按中轴线锚点决定；本视图只负责内容。
    }

    @ViewBuilder
    private func specialSlotLabel(name: String, index: Int, isCurrent: Bool, angle: Angle, midRadius: CGFloat) -> some View {
        let rad = CGFloat(angle.radians)
        let x = midRadius * cos(rad)
        let y = midRadius * sin(rad)
        let isHovered = hoveredIndex == (index - 1)

        VStack(spacing: 3) {
            Image(systemName: isCurrent ? "folder.fill" : "folder")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isCurrent ? .accentColor : AppTheme.radialPrimaryText(colorScheme, isHovered: isHovered, isEmpty: false))

            Text(name)
                .font(.system(size: 10, weight: isCurrent ? .bold : .medium))
                .foregroundColor(AppTheme.radialSecondaryText(colorScheme, isHovered: isHovered))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: midRadius * 0.7)
        }
        .offset(x: x, y: y)
        .animation(Anim.interactive, value: isHovered)
    }

    private func handlePasteAll() {
        // v2.7.20: "全部粘贴" must use the current slot group paste-all flow,
        // not node-connection chain paste. Also avoid double dismiss: the controller
        // handles dismissal after paste-all completes/starts.
        if let onPasteAll {
            onPasteAll()
        } else {
            NotificationCenter.default.post(name: .radialMenuPasteAllRequested, object: nil)
            onDismiss()
        }
    }

    private func dividerLine(center: CGPoint, angle: Angle, innerRadius: CGFloat, outerRadius: CGFloat) -> Path {
        let rad = CGFloat(angle.radians)
        let start = CGPoint(x: center.x + innerRadius * cos(rad), y: center.y + innerRadius * sin(rad))
        let end = CGPoint(x: center.x + outerRadius * cos(rad), y: center.y + outerRadius * sin(rad))
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }
}

extension Notification.Name {
    static let radialMenuHoveredSlotChanged = Notification.Name("ClipSlots.radialMenuHoveredSlotChanged")
    static let radialMenuPasteAllRequested = Notification.Name("ClipSlots.radialMenuPasteAllRequested")
}

struct RadialHoverPreviewPayload {
    let title: String
    let subtitle: String
    let content: SlotContent
    let pageId: String
    let specialSlotId: String
    let slot: Int
}
