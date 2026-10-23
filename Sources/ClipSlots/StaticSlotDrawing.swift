import SwiftUI

/// Combines static slot artwork while leaving native controls and media in their normal rendering path.
struct StaticSlotDrawing: ViewModifier {
    let eligible: Bool
    private static let enabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CLIPSLOTS_PROBE_STATIC_SLOT_DRAWING"] != "0"
        #else
        return true
        #endif
    }()

    @ViewBuilder
    func body(content: Content) -> some View {
        if eligible && Self.enabled {
            content.drawingGroup()
        } else {
            content
        }
    }
}
