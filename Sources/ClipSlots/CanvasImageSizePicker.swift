import SwiftUI
import ClipSlotsKit

struct CanvasImageSizePicker: View {
    private typealias TapSkin = CanvasSkin
    let selection: CanvasImageConfiguration.Selection
    let onPick: (String, String) -> Void
    @State private var hovered: String?
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("画质").font(.system(size: 12, weight: .medium)).foregroundColor(mutedInk)
            HStack(spacing: 4) {
                ForEach(CanvasImageConfiguration.qualities, id: \.self) { quality in
                    Button { onPick(selection.ratio, quality) } label: {
                        Text(quality).font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .background {
                                if selection.quality == quality {
                                    RoundedRectangle(cornerRadius: 6).fill(selectionFill)
                                        .matchedGeometryEffect(id: "quality", in: highlight)
                                        .allowsHitTesting(false)
                                }
                            }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("canvas-image-quality-" + quality)
                        .accessibilityAddTraits(selection.quality == quality ? [.isSelected] : [])
                }
            }.padding(2).background(sectionFill, in: RoundedRectangle(cornerRadius: 8))
            Text("比例").font(.system(size: 12, weight: .medium)).foregroundColor(mutedInk)
                .padding(.top, 8)
            HStack(alignment: .top, spacing: 6) {
                tile("1:1", height: 52).frame(width: 56)
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(Array(CanvasImageConfiguration.ratios[1...4]), id: \.self) { tile($0) }
                    }
                    HStack(spacing: 4) {
                        ForEach(Array(CanvasImageConfiguration.ratios[5...7]), id: \.self) { tile($0) }
                        Color.clear.frame(maxWidth: .infinity).frame(height: 43)
                    }
                }
            }.padding(4).background(sectionFill, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16).frame(width: 320)
        .foregroundColor(TapSkin.chromeInk)
        .background(TapSkin.tone(0xffffff, 0x333333).opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selection)
    }
    private var mutedInk: Color { TapSkin.tone(0x767676, 0x858585) }
    private var sectionFill: Color { TapSkin.tone(0xefefef, 0x3b3b3b).opacity(0.65) }
    private var selectionFill: Color { TapSkin.tone(0xe0e0e0, 0x484848).opacity(0.75) }
    private func tile(_ ratio: String, height: CGFloat = 43) -> some View {
        Button { onPick(ratio, selection.quality) } label: {
            VStack(spacing: ratio == "1:1" ? 4 : 2) {
                CanvasAspectGlyph(ratio: ratio, size: ratio == "1:1" ? 20 : 14)
                Text(ratio).font(.system(size: ratio == "1:1" ? 12 : 10))
            }
            .frame(maxWidth: .infinity).frame(height: height)
            .foregroundColor(selection.ratio == ratio ? TapSkin.chromeInk : mutedInk)
            .background {
                if selection.ratio == ratio {
                    RoundedRectangle(cornerRadius: 6).fill(selectionFill)
                        .matchedGeometryEffect(id: "ratio", in: highlight)
                        .allowsHitTesting(false)
                } else if hovered == ratio {
                    RoundedRectangle(cornerRadius: 6).fill(selectionFill.opacity(0.5))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .onHover { if $0 { hovered = ratio } else if hovered == ratio { hovered = nil } }
            .accessibilityLabel("画面比例 " + ratio)
            .accessibilityIdentifier("canvas-ratio-" + ratio)
            .accessibilityAddTraits(selection.ratio == ratio ? [.isSelected] : [])
    }
}

struct CanvasGenerationCountPicker: View {
    let count: Int
    let onPick: (Int) -> Void
    @State private var hovered: Int?
    var body: some View {
        VStack(spacing: 4) {
            ForEach(1...4, id: \.self) { value in
                Button { onPick(value) } label: {
                    HStack {
                        Text("×\(value)")
                        Spacer()
                        if value == count { Image(systemName: "checkmark") }
                    }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 30)
                        .background(value == count || hovered == value ? CanvasSkin.subtleFill : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .onHover { hovered = $0 ? value : nil }
                    .accessibilityLabel("生成 \(value) 次")
                    .accessibilityIdentifier("canvas-count-option-\(value)")
            }
        }.padding(4).frame(width: 96)
            .foregroundColor(CanvasSkin.chromeInk)
            .background(CreativeMenuStyle.fill, in: RoundedRectangle(cornerRadius: 12))
    }
}
