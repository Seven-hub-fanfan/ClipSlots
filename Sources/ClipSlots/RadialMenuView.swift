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
    @Environment(\.colorScheme) private var colorScheme

    private let menuSize: CGFloat = 340

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let outerRadius = min(geo.size.width, geo.size.height) / 2
            let deadZoneRadius = outerRadius * 0.22

            ZStack {
                // Background
                Circle()
                    .fill(AppTheme.radialBackground(colorScheme))
                    .background(AppTheme.radialMaterial(colorScheme), in: Circle())
                    .shadow(color: AppTheme.radialShadow(colorScheme), radius: 25, y: 8)

                // Divider lines
                ForEach(0..<slotCount, id: \.self) { i in
                    let segmentAngle = 360.0 / Double(slotCount)
                    let a = Angle(degrees: Double(i) * segmentAngle - 90)
                    dividerLine(angle: a, innerRadius: deadZoneRadius + 2, outerRadius: outerRadius - 2)
                        .stroke(AppTheme.radialDivider(colorScheme), lineWidth: 1)
                }

                // Segments
                ForEach(1...slotCount, id: \.self) { slot in
                    let content = slots[slot] ?? SlotContent()
                    let segmentAngle = 360.0 / Double(slotCount)
                    let startAngle = Angle(degrees: Double(slot - 1) * segmentAngle - 90)
                    let endAngle = Angle(degrees: Double(slot) * segmentAngle - 90)
                    let midAngle = Angle(degrees: (Double(slot - 1) + 0.5) * segmentAngle - 90)

                    ZStack {
                        PieSegmentShape(startAngle: startAngle, endAngle: endAngle, innerRadius: deadZoneRadius, outerRadius: outerRadius)
                            .fill(AppTheme.radialSegment(colorScheme, isEmpty: content.isEmpty, isHovered: hoveredSlot == slot))
                            .overlay(
                                PieSegmentShape(startAngle: startAngle, endAngle: endAngle, innerRadius: deadZoneRadius, outerRadius: outerRadius)
                                    .stroke(
                                        AppTheme.radialStroke(colorScheme, isHovered: hoveredSlot == slot),
                                        lineWidth: hoveredSlot == slot ? 2 : 1
                                    )
                            )

                        segmentLabel(
                            slot: slot, content: content,
                            angle: midAngle,
                            midRadius: (deadZoneRadius + outerRadius) / 2
                        )
                    }
                }

                // Inner ring
                Circle()
                    .stroke(AppTheme.radialDivider(colorScheme), lineWidth: 1)
                    .frame(width: deadZoneRadius * 2 + 4, height: deadZoneRadius * 2 + 4)

                // Center dead zone
                Circle()
                    .fill(AppTheme.radialCenterBackground(colorScheme))
                    .frame(width: deadZoneRadius * 2, height: deadZoneRadius * 2)
                    .overlay(
                        Circle()
                            .stroke(AppTheme.radialDivider(colorScheme), lineWidth: 1)
                    )

                // Center icon
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 20))
                    .foregroundColor(AppTheme.radialSecondaryText(colorScheme, isHovered: false))
            }
            .frame(width: outerRadius * 2, height: outerRadius * 2)
            .contentShape(Circle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let dx = location.x - center.x
                    let dy = location.y - center.y
                    let distance = sqrt(dx * dx + dy * dy)
                    if distance < deadZoneRadius {
                        hoveredSlot = nil
                    } else {
                        var angle = atan2(dy, dx) * 180 / .pi + 90
                        if angle < 0 { angle += 360 }
                        let segmentAngle = 360.0 / Double(slotCount)
                        let index = Int(angle / segmentAngle)
                        hoveredSlot = min(index + 1, slotCount)
                    }
                case .ended:
                    hoveredSlot = nil
                }
            }
            .onTapGesture {
                if let slot = hoveredSlot, let content = slots[slot], !content.isEmpty {
                    onSelect(slot)
                } else {
                    onDismiss()
                }
            }
        }
        .frame(width: menuSize, height: menuSize)
    }

    @ViewBuilder
    private func segmentLabel(slot: Int, content: SlotContent, angle: Angle, midRadius: CGFloat) -> some View {
        let rad = CGFloat(angle.radians)
        let x = midRadius * cos(rad)
        let y = midRadius * sin(rad)
        let isHovered = hoveredSlot == slot

        VStack(spacing: 2) {
            Text("\(slot)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.radialPrimaryText(colorScheme, isHovered: isHovered, isEmpty: content.isEmpty))

            if !content.isEmpty {
                Text(content.preview)
                    .font(.system(size: 9))
                    .foregroundColor(AppTheme.radialSecondaryText(colorScheme, isHovered: isHovered))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: midRadius * 0.75)
            } else {
                Text("空")
                    .font(.system(size: 9))
                    .foregroundColor(AppTheme.radialEmptyText(colorScheme))
            }
        }
        .offset(x: x, y: y)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private func dividerLine(angle: Angle, innerRadius: CGFloat, outerRadius: CGFloat) -> Path {
        let rad = CGFloat(angle.radians)
        var path = Path()
        path.move(to: CGPoint(x: innerRadius * cos(rad), y: innerRadius * sin(rad)))
        path.addLine(to: CGPoint(x: outerRadius * cos(rad), y: outerRadius * sin(rad)))
        return path
    }
}
