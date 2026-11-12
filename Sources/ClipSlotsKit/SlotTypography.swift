import AppKit
import CoreText

/// Inter Extra Bold from the reference design, with a native Chinese fallback.
public enum SlotTypography {
    private static let fontURL = ClipSlotsResourceBundle.bundle?
        .url(forResource: "InterVariable", withExtension: "ttf", subdirectory: "Resources/Fonts")

    private static let registered: Bool = {
        guard let fontURL else { return false }
        return CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    }()

    public static let titleFont: NSFont = makeFont(size: 14)
    public static let numberFont: NSFont = makeFont(size: 13)

    private static func makeFont(size: CGFloat) -> NSFont {
        _ = registered
        guard let font = NSFont(name: "InterVariable", size: size) else {
            return .systemFont(ofSize: size, weight: .heavy)
        }
        let descriptor = font.fontDescriptor.addingAttributes([
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String):
                [NSNumber(value: 0x77676874): 800, NSNumber(value: 0x6f70737a): 14],
            .cascadeList: [NSFont.systemFont(ofSize: size, weight: .heavy).fontDescriptor]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? font
    }
}
