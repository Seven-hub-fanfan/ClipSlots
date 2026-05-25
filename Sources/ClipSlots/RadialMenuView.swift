import SwiftUI

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

// MARK: - Radial Menu View

struct RadialMenuView: View {
    let slots: [Int: SlotContent]
    let labels: [Int: String]
    let slotCount: Int
    var onSelect: (Int) -> Void
    var onDismiss: () -> Void

    @State private var hoveredSlot: Int? = nil
    @State private var appeared = false
    @Environment(\.colorScheme) private var colorScheme

    private let menuSize: CGFloat = 360

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let outerRadius = min(geo.size.width, geo.size.height) / 2
            let deadZoneRadius = outerRadius * 0.24

            ZStack {
                Circle()
                    .fill(AppTheme.radialBackground(colorScheme))
                    .background(AppTheme.radialMaterial(colorScheme), in: Circle())
                    .shadow(color: AppTheme.radialShadow(colorScheme), radius: 26, y: 9)

                ForEach(0..<slotCount, id: \.self) { i in
                    let segmentAngle = 360.0 / Double(slotCount)
                    let a = Angle(degrees: Double(i) * segmentAngle - 90)
                    dividerLine(
                        center: center,
                        angle: a,
                        innerRadius: deadZoneRadius + 2,
                        outerRadius: outerRadius - 3
                    )
                    .stroke(AppTheme.radialDivider(colorScheme), lineWidth: 1)
                }

                ForEach(1...slotCount, id: \.self) { slot in
                    let content = slots[slot] ?? SlotContent()
                    let segmentAngle = 360.0 / Double(slotCount)
                    let startAngle = Angle(degrees: Double(slot - 1) * segmentAngle - 90)
                    let endAngle = Angle(degrees: Double(slot) * segmentAngle - 90)
                    let midAngle = Angle(degrees: (Double(slot - 1) + 0.5) * segmentAngle - 90)
                    let isHovered = hoveredSlot == slot

                    ZStack {
                        PieSegmentShape(startAngle: startAngle, endAngle: endAngle, innerRadius: deadZoneRadius, outerRadius: outerRadius)
                            .fill(AppTheme.radialSegment(colorScheme, isEmpty: content.isEmpty, isHovered: isHovered))

                        if isHovered {
                            PieSegmentShape(startAngle: startAngle, endAngle: endAngle, innerRadius: deadZoneRadius, outerRadius: outerRadius)
                                .stroke(AppTheme.radialStroke(colorScheme, isHovered: true), lineWidth: 2)
                        }

                        segmentLabel(slot: slot, content: content, label: labels[slot] ?? "", angle: midAngle, midRadius: (deadZoneRadius + outerRadius) / 2)
                    }
                    .scaleEffect(isHovered ? 1.018 : 1.0)
                    .animation(.easeOut(duration: 0.10), value: isHovered)
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
                    hoveredSlot = nil
                }
            }
            .onTapGesture {
                guard let slot = hoveredSlot else {
                    onDismiss()
                    return
                }
                let content = slots[slot] ?? SlotContent()
                if content.isEmpty {
                    onDismiss()
                } else {
                    onSelect(slot)
                }
            }
        }
        .frame(width: menuSize, height: menuSize)
    }

    private func updateHover(location: CGPoint, center: CGPoint, deadZoneRadius: CGFloat) {
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)

        if distance < deadZoneRadius {
            hoveredSlot = nil
            return
        }

        var angle = atan2(dy, dx) * 180 / .pi + 90
        if angle < 0 { angle += 360 }
        let segmentAngle = 360.0 / Double(slotCount)
        let index = Int(angle / segmentAngle)
        hoveredSlot = min(index + 1, slotCount)
    }

    @ViewBuilder
    private func centerView(deadZoneRadius: CGFloat) -> some View {
        let slot = hoveredSlot
        let content = hoveredSlot.flatMap { slots[$0] } ?? SlotContent()

        Circle()
            .fill(AppTheme.radialCenterBackground(colorScheme))
            .frame(width: deadZoneRadius * 2, height: deadZoneRadius * 2)
            .overlay(
                Circle().stroke(AppTheme.radialDivider(colorScheme), lineWidth: 1)
            )
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: slot == nil ? "rectangle.stack.fill" : (content.isEmpty ? "tray" : "arrow.up.doc.fill"))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(slot == nil ? .accentColor : (content.isEmpty ? .secondary : .accentColor))

                    if let slot {
                        Text("槽位 \(slot)")
                            .font(.system(size: 11, weight: .semibold))
                        Text(content.isEmpty ? "空" : "点击粘贴")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    } else {
                        Text("ClipSlots")
                            .font(.system(size: 11, weight: .semibold))
                        Text("移动选择")
                            .font(.system(size: 9))
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
        let isHovered = hoveredSlot == slot

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
