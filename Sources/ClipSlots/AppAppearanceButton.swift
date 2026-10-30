import SwiftUI
import ClipSlotsKit

/// Shared appearance control for the editor and canvas.
struct AppAppearanceButton: View {
    var compact = false
    var canvasPalette = false
    @AppStorage(AppearanceDefaults.key) private var appearance = ThemeMode.light.rawValue
    @State private var presented = false
    private var mode: ThemeMode { ThemeMode(rawValue: appearance) ?? .system }
    private var chromeFill: Color { canvasPalette ? CanvasSkin.chromeFill : TapSkin.chromeFill }

    var body: some View {
        trigger
        .buttonStyle(.plain)
        .help("外观 · \(mode.title)")
        .accessibilityLabel("外观")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            appearancePanel
        }
    }

    @ViewBuilder private var trigger: some View {
        if canvasPalette {
            Button { presented.toggle() } label: {
                Image(systemName: mode.icon)
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(CanvasHeaderButtonStyle(iconOnly: true, isActive: presented))
        } else {
        Button { presented.toggle() } label: {
            Image(systemName: mode.icon)
                .font(.system(size: compact ? 13 : 14, weight: .medium))
                .foregroundColor(TapSkin.ink)
                .frame(width: compact ? 30 : 34, height: compact ? 30 : 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(chromeFill))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(TapSkin.border.opacity(0.7), lineWidth: 1))
                .contentShape(Rectangle())
        }
        }
    }

    private var appearancePanel: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("外观").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 3) {
                    ForEach(ThemeMode.allCases, id: \.rawValue) { value in
                        Button { appearance = value.rawValue } label: {
                            Text(value.title)
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity).frame(height: 28)
                                .foregroundColor(mode == value ? TapSkin.onAccent : TapSkin.secondaryInk)
                                .background(RoundedRectangle(cornerRadius: 7).fill(mode == value ? TapSkin.accent : Color.clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(value.title)
                        .accessibilityAddTraits(mode == value ? [.isSelected] : [])
                    }
                }
                .padding(3).background(RoundedRectangle(cornerRadius: 9).fill(TapSkin.subtleFill))
            }
            .padding(16).frame(width: 290)
            .foregroundColor(TapSkin.ink)
            .background(TapSkin.chromeFill)
    }

}
