import Foundation
import CoreGraphics

public enum CanvasNodeSizing {
    public static let defaultShortSide: CGFloat = 320

    /// Catalog values can include a resolution suffix, e.g. "16:9 4K".
    public static func aspectRatio(_ value: String) -> CGFloat? {
        guard let expression = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*[:：/]\s*(\d+(?:\.\d+)?)"#),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let left = Range(match.range(at: 1), in: value), let right = Range(match.range(at: 2), in: value),
              let width = Double(value[left]), let height = Double(value[right]),
              width > 0, height > 0, width.isFinite, height.isFinite else { return nil }
        let aspect = CGFloat(width / height)
        return (0.125...8).contains(aspect) ? aspect : nil
    }

    public static func size(ratio: String, shortSide: CGFloat = defaultShortSide) -> CGSize? {
        guard let aspect = aspectRatio(ratio) else { return nil }
        let base = shortSide.isFinite ? min(640, max(160, shortSide)) : defaultShortSide
        return aspect >= 1 ? CGSize(width: base * aspect, height: base) : CGSize(width: base, height: base / aspect)
    }

    public static func initialSize(for kind: CanvasNodeKind) -> CGSize {
        if kind == .slot { return CanvasNode.defaultSize }
        if kind == .text { return CGSize(width: defaultShortSide, height: defaultShortSide) }
        return size(ratio: CanvasNode.defaultRatio(for: kind)) ?? CGSize(width: defaultShortSide, height: defaultShortSide)
    }
}
