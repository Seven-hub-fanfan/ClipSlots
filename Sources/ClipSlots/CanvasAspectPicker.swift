import SwiftUI
import ClipSlotsKit

/// Shows the actual catalog options, including model-specific resolution suffixes.
struct CanvasAspectPicker: View {
    let options: [CrateModelCatalog.RatioOption]
    let selected: String
    let onPick: (String) -> Void

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
                                    let aspect = CanvasNodeSizing.aspectRatio(option.value) ?? 1
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(selected == option.value ? TapSkin.accent : TapSkin.chromeInkDim, lineWidth: 1.2)
                                        .frame(width: aspect >= 1 ? 26 : 26 * aspect,
                                               height: aspect >= 1 ? 26 / aspect : 26)
                                        .frame(height: 28)
                                    Text(option.label)
                                        .font(.system(size: 10, weight: selected == option.value ? .semibold : .regular))
                                        .lineLimit(2).multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity, minHeight: 58)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 7).fill(selected == option.value ? TapSkin.accent.opacity(0.12) : TapSkin.subtleFill))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("画面比例 \(option.label)")
                            .accessibilityAddTraits(selected == option.value ? [.isSelected] : [])
                        }
                    }
                }
                .frame(height: CGFloat(min(4, (options.count + 3) / 4)) * 72)
            }
        }
        .padding(14)
        .frame(width: 284)
        .foregroundColor(TapSkin.chromeInk)
        .background(TapSkin.chromeFill)
    }
}
