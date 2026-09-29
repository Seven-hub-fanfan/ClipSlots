import SwiftUI
import ClipSlotsKit

/// Shared appearance control for the editor and canvas.
struct AppAppearanceButton: View {
    var compact = false
    @AppStorage(AppearanceDefaults.key) private var appearance = ThemeMode.dark.rawValue
    @AppStorage(AppSkin.defaultsKey) private var skin = AppSkin.fallback.rawValue
    @State private var presented = false
    private var mode: ThemeMode { ThemeMode(rawValue: appearance) ?? .system }

    var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: mode.icon)
                .font(.system(size: compact ? 13 : 14, weight: .medium))
                .foregroundColor(TapSkin.ink)
                .frame(width: compact ? 30 : 34, height: compact ? 30 : 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(TapSkin.chromeFill))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(TapSkin.border.opacity(0.7), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("外观 · \(mode.title) · \((AppSkin(rawValue: skin) ?? .minimal).title)")
        .accessibilityLabel("外观与主题")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 16) {
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
                Text("主题").font(.system(size: 12, weight: .medium)).foregroundColor(TapSkin.secondaryInk)
                HStack(spacing: 10) {
                    skinTile(.minimal)
                    skinTile(.colorful)
                }
                Text("编辑区、画布和面板使用同一套外观")
                    .font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk)
            }
            .padding(18).frame(width: 318)
            .foregroundColor(TapSkin.ink)
            .background(TapSkin.chromeFill)
        }
    }

    private func skinTile(_ value: AppSkin) -> some View {
        Button {
            AppSkinCenter.apply(value)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(value == .minimal ? TapSkin.subtleFill : [Color.purple, Color.teal, Color.blue][index].opacity(0.14))
                            .overlay(alignment: .top) {
                                Capsule().fill(value == .minimal ? TapSkin.secondaryInk : [Color.purple, Color.teal, Color.blue][index])
                                    .frame(height: 2).padding(.horizontal, 6).padding(.top, 6)
                            }
                            .frame(height: 40)
                    }
                }
                HStack {
                    Text(value.title).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    if skin == value.rawValue { Image(systemName: "checkmark.circle.fill").foregroundColor(TapSkin.accent) }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(TapSkin.cardEmptyFill))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(skin == value.rawValue ? TapSkin.accent : TapSkin.border, lineWidth: 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
