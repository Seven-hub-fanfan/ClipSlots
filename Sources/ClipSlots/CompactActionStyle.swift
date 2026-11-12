import SwiftUI
import ClipSlotsKit

/// All editor actions share the same label metrics, including stateful actions.
struct CompactActionLabel: View {
    let title: String
    let icon: String
    var arguments: [CVarArg] = []
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.monochrome)
            AppLocalizedText(title, arguments: arguments)
                .font(.system(size: 12, weight: .semibold))
        }
    }
}

/// Shared neutral controls for editor actions, settings and canvas chrome.
struct CompactActionStyle: ButtonStyle {
    var selected = false
    var destructive = false
    var iconOnly = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, selected: selected, destructive: destructive,
                iconOnly: iconOnly, enabled: enabled)
    }

    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let destructive: Bool
        let iconOnly: Bool
        let enabled: Bool
        @State private var hovering = false
        private var ink: Color { selected ? TapSkin.tone(0xffffff, 0x000000) : destructive ? Neu.dangerInk : Neu.ink }
        private var fill: Color {
            if selected {
                return configuration.isPressed ? TapSkin.tone(0x171717, 0xb8b8b8)
                    : hovering ? TapSkin.tone(0x474747, 0xfafafa) : TapSkin.tone(0x303030, 0xe0e0e0)
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
