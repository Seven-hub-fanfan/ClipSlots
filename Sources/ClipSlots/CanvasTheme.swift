import SwiftUI

enum CanvasTheme {
    static var canvasChromeSurface: Color { CanvasSkin.chromeFill }
    static var canvasChromeInk: Color { CanvasSkin.ink }
    static var canvasChromeSecondaryInk: Color { CanvasSkin.secondaryInk }
    static var canvasChromeTertiaryInk: Color { CanvasSkin.faintInk }
    static var canvasCardMetaInk: Color { CanvasSkin.secondaryInk }
    static var canvasTextNodeFill: Color { CanvasSkin.cardEmptyFill }
    static var canvasTextNodeStroke: Color { CanvasSkin.border }
    static var canvasTextNodeInk: Color { CanvasSkin.ink }
    static var canvasTextNodePlaceholderInk: Color { CanvasSkin.faintInk }
    static var chromeAccentInk: Color { CanvasSkin.accent }
    static var chromeAccentSoftFill: Color { CanvasSkin.subtleFill }
    static var elevatedBackground: Color { CanvasSkin.chromeFill }
    static var subtleBorder: Color { CanvasSkin.border }
    static var chipBackground: Color { CanvasSkin.subtleFill }
    static var previewBackground: Color { CanvasSkin.subtleFill }
    static var minimalCardHoverBorder: Color { CanvasSkin.secondaryInk }
    static func cardShadow(isEmpty: Bool) -> Color {
        CanvasSkin.tone(isEmpty ? 0xeeeeee : 0xdddddd, 0x000000).opacity(0.15)
    }
}
