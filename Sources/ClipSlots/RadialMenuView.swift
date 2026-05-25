import SwiftUI
import AppKit

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

// MARK: - AppKit Mouse Tracking View

private final class MouseTrackingView: NSView {
    var onHover: ((CGPoint) -> Void)?
    var onClick: (() -> Void)?
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onHover?(point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onHover?(point)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
        let point = convert(event.locationInWindow, from: nil)
        onHover?(point)
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

private struct MouseTrackingOverlay: NSViewRepresentable {
    var onHover: (CGPoint) -> Void
    var onClick: () -> Void
    var onMouseEntered: () -> Void
    var onMouseExited: () -> Void

    func makeNSView(context: Context) -> MouseTrackingView {
        let view = MouseTrackingView()
        view.onHover = onHover
        view.onClick = onClick
        view.onMouseEntered = onMouseEntered
        view.onMouseExited = onMouseExited
        return view
    }

    func updateNSView(_ nsView: MouseTrackingView, context: Context) {
        nsView.onHover = onHover
        nsView.onClick = onClick
        nsView.onMouseEntered = onMouseEntered
        nsView.onMouseExited = onMouseExited
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
    @State private var mouseLocation: CGPoint = .zero

    private let menuSize: CGFloat = 340

    var body: some View {
        let outerRadius = menuSize / 2
        let deadZoneRadius = outerRadius * 0.22
        let center = CGPoint(x: menuSize / 2, y: menuSize / 2)

        ZStack {
            // Background circle
            Circle()
                .fill(Color.black.opacity(0.85))
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.5), radius: 25, y: 8)

            // Divider lines
            ForEach(0..<slotCount, id: \.self) { i in
                let segmentAngle = 360.0 / Double(slotCount)
                let a = Angle(degrees: Double(i) * segmentAngle - 90)
                dividerLine(angle: a, innerRadius: deadZoneRadius + 2, outerRadius: outerRadius - 2)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
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
                        .fill(segmentFill(slot: slot, content: content))
                        .overlay(
                            PieSegmentShape(startAngle: startAngle, endAngle: endAngle, innerRadius: deadZoneRadius, outerRadius: outerRadius)
                                .stroke(
                                    hoveredSlot == slot ? Color.accentColor : Color.white.opacity(0.15),
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
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                .frame(width: deadZoneRadius * 2 + 4, height: deadZoneRadius * 2 + 4)

            // Center dead zone
            Circle()
                .fill(Color.black.opacity(0.75))
                .frame(width: deadZoneRadius * 2, height: deadZoneRadius * 2)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

            // Center icon
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.55))

            // Mouse tracking overlay (transparent, on top of everything)
            MouseTrackingOverlay(
                onHover: { location in
                    mouseLocation = location
                    updateHoveredSlot(location: location, center: center, deadZoneRadius: deadZoneRadius)
                },
                onClick: {
                    if let slot = hoveredSlot, let content = slots[slot], !content.isEmpty {
                        onSelect(slot)
                    } else {
                        onDismiss()
                    }
                },
                onMouseEntered: {},
                onMouseExited: {
                    hoveredSlot = nil
                }
            )
            .frame(width: menuSize, height: menuSize)
            .allowsHitTesting(true)
        }
        .frame(width: menuSize, height: menuSize)
        .clipShape(Circle())
    }

    private func updateHoveredSlot(location: CGPoint, center: CGPoint, deadZoneRadius: CGFloat) {
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
    }

    private func segmentFill(slot: Int, content: SlotContent) -> Color {
        if content.isEmpty {
            return Color.white.opacity(0.04)
        }
        if hoveredSlot == slot {
            return Color.accentColor.opacity(0.75)
        }
        return Color.white.opacity(0.08)
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
                .foregroundColor(isHovered ? .white : .white.opacity(content.isEmpty ? 0.25 : 0.85))

            if !content.isEmpty {
                Text(content.preview)
                    .font(.system(size: 9))
                    .foregroundColor(isHovered ? .white.opacity(0.85) : .white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: midRadius * 0.75)
            } else {
                Text("空")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.2))
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
