import SwiftUI
import AppKit
import ClipSlotsKit

/// Canvas-only palette. Colorful light retains its colors; both dark skins
/// resolve to the exact same neutral values without changing editor/Agent colors.
enum CanvasSkin {
    static var colorful: Bool { TapSkin.colorful }
    static func tone(_ light: UInt32, _ dark: UInt32) -> Color { TapSkin.tone(light, dark) }
    static var ink: Color { TapSkin.ink }
    static var secondaryInk: Color { TapSkin.secondaryInk }
    static var faintInk: Color { TapSkin.faintInk }
    static var border: Color { TapSkin.border }
    static var subtleFill: Color { TapSkin.subtleFill }
    static var accent: Color { colorful ? tone(0x4e5de4, 0xf0f1f4) : ink }
    static var onAccent: Color { tone(0xffffff, 0x17181b) }
    static var textPolishAccent: Color { TapSkin.tone(0x4e5de4, 0x9aa5ff) }
    static func nodeAccent(_ kind: CanvasNodeKind) -> Color {
        guard colorful else { return ink }
        switch kind {
        case .text: return tone(0x8454c7, 0xf0f1f4)
        case .image: return tone(0x147d76, 0xf0f1f4)
        case .video: return tone(0x3869c8, 0xf0f1f4)
        case .slot, .batchTemplate: return tone(0xa86b18, 0xf0f1f4)
        }
    }
    static var void: Color { tone(colorful ? 0xf1f3f9 : 0xf3f3f3, 0x080808) }
    static var gridDot: Color { tone(colorful ? 0xc2c7d6 : 0xc7c7c7, 0x404040) }
    static var cardEmptyFill: Color { tone(0xffffff, 0x1f1f1f) }
    static var cardEmptySelectedFill: Color { tone(colorful ? 0xf3f4ff : 0xf9f9f9, 0x292929) }
    static var cardEmptyGlyph: Color { faintInk }
    static var tagInk: Color { secondaryInk }
    static var tagInkActive: Color { ink }
    static var edgeInk: Color { TapSkin.edgeInk }
    static var edgeInkActive: Color { accent }
    static var portStroke: Color { secondaryInk }
    static var portStrokeActive: Color { accent }
    static var chromeFill: Color { tone(colorful ? 0xfefeff : 0xfefefe, 0x222222) }
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
    static let cardRadius = TapSkin.cardRadius
    static let cardEmptyGlyphSize = TapSkin.cardEmptyGlyphSize
    static let tagFontSize = TapSkin.tagFontSize
    static let tagGlyphSize = TapSkin.tagGlyphSize
    static let tagGap = TapSkin.tagGap
    static let tagHeight = TapSkin.tagHeight
    static let edgeWidth = TapSkin.edgeWidth
    static let edgeWidthActive = TapSkin.edgeWidthActive
    static let edgeHitSlop = TapSkin.edgeHitSlop
    static let portDiameter = TapSkin.portDiameter
    static let portOffset = TapSkin.portOffset
    static let portStrokeWidth = TapSkin.portStrokeWidth
    static let portGlyphSize = TapSkin.portGlyphSize
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
