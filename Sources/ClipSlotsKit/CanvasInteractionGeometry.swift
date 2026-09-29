import Foundation
import CoreGraphics

public enum CanvasInteractionGeometry {
    /// 面板尽量位于媒体下方；底部放不下则移到上方，并始终留在可操作区域。
    public static func panelOrigin(node: CGRect, panel: CGSize, viewport: CGRect, gap: CGFloat = 12) -> CGPoint {
        let x = min(max(node.midX - panel.width / 2, viewport.minX),
                    max(viewport.minX, viewport.maxX - panel.width))
        let below = node.maxY + gap
        let above = node.minY - gap - panel.height
        // Tall portrait nodes can occupy the entire viewport height. Use free side space
        // before covering the media or its ports.
        if below + panel.height > viewport.maxY && above < viewport.minY {
            let sideY = min(max(node.midY - panel.height / 2, viewport.minY), max(viewport.minY, viewport.maxY - panel.height))
            if node.maxX + gap + panel.width <= viewport.maxX {
                return CGPoint(x: max(viewport.minX, node.maxX + gap), y: sideY)
            }
            if node.minX - gap - panel.width >= viewport.minX {
                return CGPoint(x: node.minX - gap - panel.width, y: sideY)
            }
        }
        let y = below + panel.height <= viewport.maxY ? below :
            (above >= viewport.minY ? above : max(viewport.minY, viewport.maxY - panel.height))
        return CGPoint(x: x, y: min(max(y, viewport.minY), max(viewport.minY, viewport.maxY - panel.height)))
    }

    public static func isVisible(_ frame: CGRect, viewport: CGRect, overscan: CGFloat = 240) -> Bool {
        frame.intersects(viewport.insetBy(dx: -overscan, dy: -overscan))
    }
}
