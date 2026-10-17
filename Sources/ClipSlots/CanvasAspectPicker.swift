import SwiftUI
import ClipSlotsKit

/// The symbol uses the actual ratio (including catalog values such as "1:1 2K").
/// It is independent of source media dimensions, which remain authoritative.
struct CanvasAspectGlyph: View {
    let ratio: String
    var size: CGFloat = 13
    var body: some View {
        Group {
            if let aspect = CanvasNodeSizing.aspectRatio(ratio) {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(lineWidth: 1)
                    .frame(width: aspect >= 1 ? size : size * aspect,
                           height: aspect >= 1 ? size / aspect : size)
            } else {
                Image(systemName: ratio.isEmpty ? "aspectratio" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: size * 0.8))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Shows the actual catalog options, including model-specific resolution suffixes.
struct CanvasAspectPicker: View {
    private typealias TapSkin = CanvasSkin
    let options: [CrateModelCatalog.RatioOption]
    let selected: String
    let onPick: (String) -> Void
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("画面比例").font(.system(size: 12, weight: .medium)).foregroundColor(TapSkin.chromeInkDim)
            if options.isEmpty {
                Text("该模型未公布比例档位").font(.system(size: 12))
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(options, id: \.value) { option in
                            Button {
                                onPick(option.value)
                            } label: {
                                VStack(spacing: 7) {
                                    CanvasAspectGlyph(ratio: option.value, size: 26)
                                        .foregroundColor(selected == option.value ? TapSkin.ink : TapSkin.chromeInkDim)
                                        .frame(height: 28)
                                    Text(option.label)
                                        .font(.system(size: 10, weight: selected == option.value ? .semibold : .regular))
                                        .lineLimit(2).multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity).frame(height: 66)
                                .background(RoundedRectangle(cornerRadius: 10).fill(
                                    selected == option.value || hovered == option.value ? CreativeMenuStyle.hover : .clear))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                                    selected == option.value ? TapSkin.ink.opacity(0.45) : .clear, lineWidth: 0.5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { if $0 { hovered = option.value } else if hovered == option.value { hovered = nil } }
                            .accessibilityLabel("画面比例 \(option.label)")
                            .accessibilityIdentifier("canvas-ratio-" + option.value)
                            .accessibilityAddTraits(selected == option.value ? [.isSelected] : [])
                        }
                    }
                }
                .frame(height: CGFloat(min(4, (options.count + 3) / 4)) * 72)
            }
        }
        .padding(14)
        .frame(width: 310)
        .foregroundColor(TapSkin.chromeInk)
        .background(CreativeMenuStyle.fill)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
