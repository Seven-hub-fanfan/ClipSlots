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

// MARK: - Radial Menu View (v2.4.2: page selector + group switcher)

struct RadialMenuView: View {
    @ObservedObject var store: SlotStoreObservable
    var onSelectSlot: (Int) -> Void
    var onDismiss: () -> Void

    @State private var hoveredIndex: Int? = nil
    @State private var appeared = false
    @State private var mode: RadialMenuMode = .childSlots
    @Environment(\.colorScheme) private var colorScheme

    private let menuSize: CGFloat = 230

    private var displayCount: Int {
        mode == .childSlots ? store.config.slots : store.currentPageSlotGroups.count
    }

    private var canSwitchGroup: Bool {
        store.currentPageSlotGroups.count > 1
    }

    var body: some View {
        VStack(spacing: 6) {
            // v2.4.4: Compact page selector
            pageSelector
                .padding(.top, 4)

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
                                    .stroke(AppTheme.radialOuterStroke(colorScheme), lineWidth: 0.6)
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
                                .stroke(AppTheme.radialDivider(colorScheme), lineWidth: 0.65)
                            }
                        }

                        if mode == .childSlots {
                            childSlotSegments(center: center, outerRadius: outerRadius, deadZoneRadius: deadZoneRadius)
                        } else {
                            specialSlotSegments(center: center, outerRadius: outerRadius, deadZoneRadius: deadZoneRadius)
                        }

                        Circle()
                            .stroke(AppTheme.radialDivider(colorScheme), lineWidth: 0.8)
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

            // v2.4.4: Compact group switcher
            groupSwitcher
        }
        .padding(4)
    }

    // MARK: - Page Selector (v2.4.2)

    private var pageSelector: some View {
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
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10))
                Text(store.currentPage?.name ?? "默认页面")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundColor(AppTheme.radialSecondaryText(colorScheme, isHovered: false))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Scope Label (v2.4.2)

    private var scopeLabel: some View {
        Text(store.currentSpecialSlot?.name ?? "默认槽位组")
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .foregroundColor(.secondary)
    }

    // MARK: - Group Switcher (v2.4.2)

    private var groupSwitcher: some View {
        HStack(spacing: 12) {
            Button {
                store.switchToPreviousSlotGroup()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!canSwitchGroup)
            .opacity(canSwitchGroup ? 1 : 0.3)

            Text(store.currentSpecialSlot?.name ?? "默认槽位组")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)

            Button {
                store.switchToNextSlotGroup()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!canSwitchGroup)
            .opacity(canSwitchGroup ? 1 : 0.3)
        }
        .foregroundColor(AppTheme.radialSecondaryText(colorScheme, isHovered: false))
        .padding(.bottom, 4)
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
                        .stroke(AppTheme.radialStroke(colorScheme, isHovered: true), lineWidth: 1.1)
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
                        .stroke(AppTheme.radialStroke(colorScheme, isHovered: true), lineWidth: 1.1)
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

    // MARK: - Text Helpers (v2.4.3)

    private func radialPreviewText(content: SlotContent, label: String) -> String {
        if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return label
        }

        var text = content.preview
        text = text.replacingOccurrences(of: "[文件]", with: "")
        text = text.replacingOccurrences(of: "[图片]", with: "")
        text = text.replacingOccurrences(of: "[视频]", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text
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
            .overlay(
                Circle().stroke(AppTheme.radialOuterStroke(colorScheme), lineWidth: 0.6)
            )
            .frame(width: deadZoneRadius * 2, height: deadZoneRadius * 2)
            .overlay {
                VStack(spacing: 4) {
                    if mode == .childSlots {
                        if let slot = idx {
                            let content = store.slots[slot] ?? SlotContent()
                            Image(systemName: "arrow.up.doc.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.accentColor)

                            Text("槽位 \(slot)")
                                .font(.system(size: 10, weight: .semibold))

                            if !content.isEmpty {
                                Text(radialPreviewText(content: content, label: store.labels[slot] ?? ""))
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(width: deadZoneRadius * 1.55)
                            }

                            Text("点击粘贴")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        } else {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.secondary)

                            Text(store.currentSpecialSlot?.name ?? "默认槽位组")
                                .font(.system(size: 9, weight: .semibold))
                                .lineLimit(1)
                                .frame(width: deadZoneRadius * 1.5)

                            Text("点击切换")
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
                .font(.system(size: isHovered ? 19 : 18, weight: isHovered ? .bold : .semibold, design: .rounded))
                .foregroundColor(AppTheme.radialPrimaryText(colorScheme, isHovered: isHovered, isEmpty: content.isEmpty))

            if !content.isEmpty {
                Text(radialPreviewText(content: content, label: label))
                    .font(.system(size: 8.5, weight: label.isEmpty ? .regular : .semibold))
                    .foregroundColor(AppTheme.radialSecondaryText(colorScheme, isHovered: isHovered))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: isHovered ? 96 : 76)
            } else {
                Text("空")
                    .font(.system(size: 9))
                    .foregroundColor(AppTheme.radialEmptyText(colorScheme))
            }
        }
        .offset(x: x, y: y)
        .animation(.easeOut(duration: 0.12), value: isHovered)
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
