import SwiftUI
import AppKit
import ClipSlotsKit

/// Canvas surfaces use the shared minimal appearance.
enum CanvasSkin {
    static func tone(_ light: UInt32, _ dark: UInt32) -> Color { TapSkin.tone(light, dark) }
    static var ink: Color { TapSkin.ink }
    static var secondaryInk: Color { TapSkin.secondaryInk }
    static var faintInk: Color { TapSkin.faintInk }
    static var border: Color { TapSkin.border }
    static var subtleFill: Color { TapSkin.subtleFill }
    static var accent: Color { ink }
    static var onAccent: Color { tone(0xffffff, 0x17181b) }
    static var textPolishAccent: Color { TapSkin.tone(0x4e5de4, 0x9aa5ff) }
    static func nodeAccent(_ kind: CanvasNodeKind) -> Color {
        ink
    }
    static var void: Color { tone(0xf3f3f3, 0x080808) }
    static var gridDot: Color { tone(0xc7c7c7, 0x404040) }
    static var cardEmptyFill: Color { tone(0xffffff, 0x1f1f1f) }
    static var cardEmptySelectedFill: Color { tone(0xf9f9f9, 0x292929) }
    static var cardEmptyGlyph: Color { faintInk }
    static var tagInk: Color { secondaryInk }
    static var tagInkActive: Color { ink }
    static var edgeInk: Color { tone(0x999999, 0xffffff).opacity(0.376) }
    static var edgePreviewInk: Color { tone(0x77777d, 0xb1b1b7) }
    static var edgeInkActive: Color { accent }
    static var portStroke: Color { tone(0x7a7a7a, 0x7a7a7a) }
    static var portStrokeActive: Color { tone(0x252525, 0xf5f5f5) }
    static var chromeFill: Color { tone(0xfefefe, 0x222222) }
    static var chromeInk: Color { ink }
    static var chromeInkDim: Color { secondaryInk }
    static var chromeDivider: Color { border }
    static var chipFill: Color { subtleFill }
    static var chipInk: Color { ink }
    static var menuFill: Color { chromeFill }
    static var menuRowHoverFill: Color { subtleFill }
    static var menuTileFill: Color { subtleFill }
    static var menuSectionInk: Color { secondaryInk }
    static let gridStep = CanvasReplicaGeometry.gridStep
    static let gridDotSize = TapSkin.gridDotSize
    static let cardRadius: CGFloat = 16
    static let cardEmptyGlyphSize = TapSkin.cardEmptyGlyphSize
    static let tagFontSize = TapSkin.tagFontSize
    static let tagGlyphSize = TapSkin.tagGlyphSize
    static let tagGap = TapSkin.tagGap
    static let tagHeight = TapSkin.tagHeight
    static let edgeWidth = TapSkin.edgeWidth
    static let edgeWidthActive = TapSkin.edgeWidthActive
    static let edgeHitSlop = TapSkin.edgeHitSlop
    static let portDiameter: CGFloat = 24
    static let portOffset: CGFloat = 37
    static let portStrokeWidth: CGFloat = 2
    static let portGlyphSize: CGFloat = 14
    static let toolbarHeight = TapSkin.toolbarHeight
    static let titlebarInset = TapSkin.titlebarInset
    static let toolbarRadius = TapSkin.toolbarRadius
    static let toolbarIconSize = TapSkin.toolbarIconSize
    static let toolbarItemSpacing = TapSkin.toolbarItemSpacing
    static let toolbarGap = TapSkin.toolbarGap
    static let chipHeight = TapSkin.chipHeight
    static let chipRadius = TapSkin.chipRadius
    static let chipInset = TapSkin.chipInset
    static let chipFontSize = TapSkin.chipFontSize
    static let menuRadius = TapSkin.menuRadius
    static let stateAnim = TapSkin.stateAnim
    static let placeAnim = TapSkin.placeAnim
}
