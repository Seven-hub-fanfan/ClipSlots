import SwiftUI

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
                    .background(.thinMaterial, in: Capsule())
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
    var onDismiss: () -> Void

    @State private var hoveredIndex: Int? = nil
    @State private var appeared = false
    @State private var mode: RadialMenuMode = .childSlots
    @Environment(\.colorScheme) private var colorScheme

    private let menuSize: CGFloat = 340

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
                    let deadZoneRadius = outerRadius * 0.24

                    ZStack {
                        Circle()
                            .fill(AppTheme.radialBackground(colorScheme))
                            .background(AppTheme.radialMaterial(colorScheme), in: Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.15), lineWidth: 0.6)
                            )

                        if displayCount > 0 {
                            ForEach(0..<displayCount, id: \.self) { i in
                                let segmentAngle = 360.0 / Double(displayCount)
                                let a = Angle(degrees: Double(i) * segmentAngle - 90)
                                dividerLine(
                                    center: center,
                                    angle: a,
                                    innerRadius: deadZoneRadius + 2,
                                    outerRadius: outerRadius - 3
                                )
                                .stroke(AppTheme.radialDivider(colorScheme), lineWidth: 1)
                            }
                        }

                        if mode == .childSlots {
                            childSlotSegments(center: center, outerRadius: outerRadius, deadZoneRadius: deadZoneRadius)
                        } else {
                            specialSlotSegments(center: center, outerRadius: outerRadius, deadZoneRadius: deadZoneRadius)
                        }

                        Circle()
                            .stroke(AppTheme.radialDivider(colorScheme), lineWidth: 1)
                            .frame(width: deadZoneRadius * 2 + 4, height: deadZoneRadius * 2 + 4)

                        centerView(deadZoneRadius: deadZoneRadius)
                    }
                    .frame(width: outerRadius * 2, height: outerRadius * 2)
                    .contentShape(Circle())
                    .scaleEffect(appeared ? 1 : 0.92)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.22, dampingFraction: 0.82), value: appeared)
                    .onAppear { appeared = true }
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let location):
                            updateHover(location: location, center: center, deadZoneRadius: deadZoneRadius)
                        case .ended:
                            hoveredIndex = nil
                        }
                    }
                    .onTapGesture {
                        handleTap()
                    }
                }
            }
            .frame(width: menuSize, height: menuSize)

            // v2.4.2: Slot group switcher
            groupSwitcher
                .padding(.top, 8)
                .padding(.bottom, 6)
        }
        .frame(width: menuSize)
        .padding(.vertical, 8)
    }

    // MARK: - Top Navigation (v2.4.6: vertical two-tier)

    private var topNavigationStack: some View {
        VStack(spacing: 4) {
            pageSelectorGlass
            scopeLabelGlass
        }
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
            RadialGlassPill(horizontalPadding: 12, verticalPadding: 5) {
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
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var scopeLabelGlass: some View {
        RadialGlassPill(horizontalPadding: 9, verticalPadding: 4) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.82)

                Text(store.currentSpecialSlot?.name ?? "默认槽位组")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 120)
            }
            .opacity(0.88)
        }
    }

    // MARK: - Group Switcher (v2.4.2)

    private var groupSwitcher: some View {
        RadialGlassPill(horizontalPadding: 10, verticalPadding: 5) {
            HStack(spacing: 10) {
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
            let isHovered = hoveredIndex == slot

            ZStack {
                PieSegmentShape(startAngle: startAngle, endAngle: endAngle, innerRadius: deadZoneRadius, outerRadius: outerRadius)
                    .fill(AppTheme.radialSegment(colorScheme, isEmpty: content.isEmpty, isHovered: isHovered))

                if isHovered {
                    PieSegmentShape(startAngle: startAngle, endAngle: endAngle, innerRadius: deadZoneRadius, outerRadius: outerRadius)
                        .stroke(AppTheme.radialStroke(colorScheme, isHovered: true), lineWidth: 2)
                }

                segmentLabel(slot: slot, content: content, label: store.labels[slot] ?? "", angle: midAngle, midRadius: (deadZoneRadius + outerRadius) / 2)
            }
            .scaleEffect(isHovered ? 1.018 : 1.0)
            .animation(.easeOut(duration: 0.10), value: isHovered)
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
                }

                specialSlotLabel(name: special.name, index: i + 1, isCurrent: isCurrent, angle: midAngle, midRadius: (deadZoneRadius + outerRadius) / 2)
            }
            .scaleEffect(isHovered ? 1.018 : 1.0)
            .animation(.easeOut(duration: 0.10), value: isHovered)
        }
    }

    // MARK: - Tap Handling

    private func handleTap() {
        let cnt = displayCount
        if cnt == 0 {
            mode = .childSlots
            return
        }

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
            mode = .childSlots
            hoveredIndex = nil
        }
    }

    private func updateHover(location: CGPoint, center: CGPoint, deadZoneRadius: CGFloat) {
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let cnt = displayCount

        if distance < deadZoneRadius || cnt == 0 {
            hoveredIndex = nil
            return
        }

        var angle = atan2(dy, dx) * 180 / .pi + 90
        if angle < 0 { angle += 360 }
        let segmentAngle = 360.0 / Double(cnt)
        let index = Int(angle / segmentAngle)
        let capped = min(index + 1, cnt)

        hoveredIndex = mode == .childSlots ? capped : index
    }

    @ViewBuilder
    private func centerView(deadZoneRadius: CGFloat) -> some View {
        let idx = hoveredIndex

        Circle()
            .fill(AppTheme.radialCenterBackground(colorScheme))
            .frame(width: deadZoneRadius * 2, height: deadZoneRadius * 2)
            .overlay(
                Circle().stroke(AppTheme.radialDivider(colorScheme), lineWidth: 1)
            )
            .overlay {
                VStack(spacing: 4) {
                    if mode == .childSlots {
                        Image(systemName: idx != nil ? "arrow.up.doc.fill" : "folder.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(idx != nil ? .accentColor : .secondary)

                        if let slot = idx {
                            Text("槽位 \(slot)")
                                .font(.system(size: 10, weight: .semibold))
                            Text("点击粘贴")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
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

    @ViewBuilder
    private func segmentLabel(slot: Int, content: SlotContent, label: String, angle: Angle, midRadius: CGFloat) -> some View {
        let rad = CGFloat(angle.radians)
        let x = midRadius * cos(rad)
        let y = midRadius * sin(rad)
        let isHovered = hoveredIndex == slot

        VStack(spacing: 3) {
            Text("\(slot)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.radialPrimaryText(colorScheme, isHovered: isHovered, isEmpty: content.isEmpty))

            if !content.isEmpty {
                Text(label.isEmpty ? content.preview : label)
                    .font(.system(size: 9, weight: label.isEmpty ? .regular : .semibold))
                    .foregroundColor(AppTheme.radialSecondaryText(colorScheme, isHovered: isHovered))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: midRadius * 0.78)
            } else {
                Text("空")
                    .font(.system(size: 9))
                    .foregroundColor(AppTheme.radialEmptyText(colorScheme))
            }
        }
        .offset(x: x, y: y)
        .animation(.easeOut(duration: 0.1), value: isHovered)
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
        .animation(.easeOut(duration: 0.1), value: isHovered)
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
