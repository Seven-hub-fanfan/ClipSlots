import SwiftUI

/// TapNow's canvas header: quiet surfaces, 40pt height and continuous 12pt corners.
struct CanvasHeaderButtonStyle: ButtonStyle {
    var iconOnly = false
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, iconOnly: iconOnly, isActive: isActive)
    }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        let iconOnly: Bool
        let isActive: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(CanvasSkin.ink)
                .padding(.horizontal, iconOnly ? 0 : 12)
                .frame(minWidth: 44, minHeight: 40, maxHeight: 40)
                .background(TapSkin.tone(
                    configuration.isPressed ? 0xe8e8e8 : (hovered || isActive ? 0xf0f0f0 : 0xfefefe),
                    configuration.isPressed ? 0x303030 : (hovered || isActive ? 0x242424 : 0x171717)))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(TapSkin.tone(0x000000, 0xffffff).opacity(isActive ? 0.12 : 0.045),
                            lineWidth: 0.5))
                .opacity(enabled ? 1 : 0.42)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .background {
                    #if DEBUG
                    CanvasHeaderButtonBounds()
                    #endif
                }
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

#if DEBUG
final class CanvasHeaderButtonProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct CanvasHeaderButtonBounds: NSViewRepresentable {
    func makeNSView(context: Context) -> CanvasHeaderButtonProbeView { CanvasHeaderButtonProbeView() }
    func updateNSView(_ view: CanvasHeaderButtonProbeView, context: Context) {}
}
#endif

/// The upright plug used by the Connect Agent entry, drawn with rounded strokes.
struct CanvasAgentPlug: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var path = Path()
        path.move(to: CGPoint(x: 9, y: 8)); path.addLine(to: CGPoint(x: 9, y: 2))
        path.move(to: CGPoint(x: 15, y: 8)); path.addLine(to: CGPoint(x: 15, y: 2))
        path.move(to: CGPoint(x: 18, y: 8)); path.addLine(to: CGPoint(x: 18, y: 13))
        path.addCurve(to: CGPoint(x: 14, y: 17),
                      control1: CGPoint(x: 18, y: 15.21), control2: CGPoint(x: 16.21, y: 17))
        path.addLine(to: CGPoint(x: 10, y: 17))
        path.addCurve(to: CGPoint(x: 6, y: 13),
                      control1: CGPoint(x: 7.79, y: 17), control2: CGPoint(x: 6, y: 15.21))
        path.addLine(to: CGPoint(x: 6, y: 8))
        path.closeSubpath()
        path.move(to: CGPoint(x: 12, y: 17)); path.addLine(to: CGPoint(x: 12, y: 22))
        return path.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.midX - 12 * scale,
                                           y: rect.midY - 12 * scale)))
    }
}
