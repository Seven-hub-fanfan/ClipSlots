import SwiftUI

/// Shared neutral controls for editor actions, settings and canvas chrome.
struct CompactActionStyle: ButtonStyle {
    var selected = false
    var destructive = false
    var iconOnly = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, selected: selected, destructive: destructive,
                iconOnly: iconOnly, dark: scheme == .dark, enabled: enabled)
    }

    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let destructive: Bool
        let iconOnly: Bool
        let dark: Bool
        let enabled: Bool
        @State private var hovering = false
        private var ink: Color { selected ? (dark ? .black : .white) : destructive ? Neu.dangerInk : Neu.ink }
        private var fill: Color {
            if selected {
                return dark ? Color(white: configuration.isPressed ? 0.72 : hovering ? 0.98 : 0.88)
                    : Color(white: configuration.isPressed ? 0.09 : hovering ? 0.28 : 0.19)
            }
            if destructive { return Neu.dangerInk.opacity(hovering ? 0.13 : 0.07) }
            return Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.08 : 0.035)
        }
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(ink)
                .padding(.horizontal, iconOnly ? 0 : 12)
                .frame(minWidth: iconOnly ? 32 : 64)
                .frame(height: 32)
                .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(selected ? 0 : hovering ? 0.13 : 0.07), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}
