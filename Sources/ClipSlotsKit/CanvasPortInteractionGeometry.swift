import Foundation
import CoreGraphics

/// Cursor-follow bounds recovered from TapNow's Noe/Roe handle.
/// Native anchors stay separate from the edge endpoint on the card.
public enum CanvasPortInteractionGeometry {
    public static func follows(_ point: CGPoint, home: CGPoint, output: Bool, zoom: CGFloat) -> Bool {
        guard zoom.isFinite, zoom > 0, point.x.isFinite, point.y.isFinite else { return false }
        let x = (point.x - home.x) / zoom
        let y = (point.y - home.y) / zoom
        return x >= (output ? -24 : -40) && x <= (output ? 40 : 24)
            && y >= -40 && y <= 40
    }

    public static func point(cursor: CGPoint, home: CGPoint, output: Bool, zoom: CGFloat) -> CGPoint {
        follows(cursor, home: home, output: output, zoom: zoom) ? cursor : home
    }
}
