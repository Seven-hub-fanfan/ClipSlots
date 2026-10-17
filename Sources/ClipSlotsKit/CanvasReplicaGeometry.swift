import Foundation
import CoreGraphics

/// Adapted from the shipped TapNow canvas configuration and yP/hat helpers.
/// Coordinates here are AppKit points; no target code is loaded or executed.
public enum CanvasReplicaGeometry {
    public static let gridStep: CGFloat = 15
    public static let connectionRadius: CGFloat = 30
    public static let edgePanMargin: CGFloat = 40
    public static let edgePanSpeed: CGFloat = 15
    public static let mapSize = CGSize(width: 200, height: 150)
    public static let sliderWidth: CGFloat = 77
    public static let toolbarZoomMax: CGFloat = 2
    public static let springStiffness: Double = 120
    public static let springDamping: Double = 18

    /// TapNow's per-animation-frame velocity, scaled to elapsed time on macOS.
    public static func edgePan(point: CGPoint, viewport: CGRect, elapsed: Double = 1 / 60) -> CGSize {
        guard point.x.isFinite, point.y.isFinite, elapsed.isFinite, elapsed > 0,
              viewport.width > edgePanMargin * 2, viewport.height > edgePanMargin * 2 else { return .zero }
        func axis(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
            if value < low { return min(max(abs(value - low), 1), edgePanMargin) / edgePanMargin }
            if value > high { return -min(max(abs(value - high), 1), edgePanMargin) / edgePanMargin }
            return 0
        }
        let factor = edgePanSpeed * CGFloat(min(elapsed, 1 / 30) * 60)
        return CGSize(width: axis(point.x, low: viewport.minX + edgePanMargin,
                                  high: viewport.maxX - edgePanMargin) * factor,
                      height: axis(point.y, low: viewport.minY + edgePanMargin,
                                   high: viewport.maxY - edgePanMargin) * factor)
    }

    public struct MapProjection {
        public let scale: CGFloat
        public let offset: CGPoint
        public let bounds: CGRect
        public func rect(_ frame: CGRect) -> CGRect {
            CGRect(x: frame.minX * scale + offset.x, y: frame.minY * scale + offset.y,
                   width: frame.width * scale, height: frame.height * scale)
        }
        public func worldPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
        }
    }

    public static func mapProjection(nodes: [CGRect], viewport: CGRect) -> MapProjection {
        let bounds = nodes.reduce(viewport) { $0.union($1) }
        guard bounds.width > 0, bounds.height > 0 else {
            return MapProjection(scale: 1, offset: .zero, bounds: bounds)
        }
        let scale = min(mapSize.width / bounds.width, mapSize.height / bounds.height)
        let offset = CGPoint(x: -bounds.minX * scale + (mapSize.width - bounds.width * scale) / 2,
                             y: -bounds.minY * scale + (mapSize.height - bounds.height * scale) / 2)
        return MapProjection(scale: scale, offset: offset, bounds: bounds)
    }

    /// SVG's default xMidYMid meet adds offsetScale on all four sides.
    /// The HTML viewport overlay uses mapProjection, not this node projection.
    public static func mapNodeProjection(nodes: [CGRect], viewport: CGRect,
                                         size: CGSize = mapSize, offsetScale: CGFloat = 5) -> MapProjection {
        let bounds = nodes.reduce(viewport) { $0.union($1) }
        guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else {
            return MapProjection(scale: 1, offset: .zero, bounds: bounds)
        }
        let worldPerPoint = max(bounds.width / size.width, bounds.height / size.height)
        let padding = offsetScale * worldPerPoint
        let viewBox = CGRect(x: bounds.midX - size.width * worldPerPoint / 2 - padding,
                             y: bounds.midY - size.height * worldPerPoint / 2 - padding,
                             width: (size.width + 2 * offsetScale) * worldPerPoint,
                             height: (size.height + 2 * offsetScale) * worldPerPoint)
        let scale = min(size.width / viewBox.width, size.height / viewBox.height)
        return MapProjection(scale: scale,
            offset: CGPoint(x: -viewBox.minX * scale + (size.width - viewBox.width * scale) / 2,
                            y: -viewBox.minY * scale + (size.height - viewBox.height * scale) / 2),
            bounds: viewBox)
    }

    /// Exact damped harmonic motion for k=120, c=18, m=1. Preserves velocity
    /// when the pointer changes the target; no SwiftUI model/presentation lag.
    public struct MapSpring {
        public var position: CGSize
        public var velocity: CGSize = .zero
        public var target: CGSize
        public init(position: CGSize) { self.position = position; target = position }
        public mutating func advance(seconds: Double) {
            guard seconds.isFinite, seconds > 0 else { return }
            let decay = springDamping / 2
            let frequency = sqrt(springStiffness - decay * decay)
            let t = min(seconds, 1 / 15)
            let envelope = exp(-decay * t)
            let cosine = cos(frequency * t), sine = sin(frequency * t)
            func axis(_ value: CGFloat, _ speed: CGFloat, _ goal: CGFloat) -> (CGFloat, CGFloat) {
                let distance = Double(value - goal)
                let coefficient = (Double(speed) + decay * distance) / frequency
                let wave = distance * cosine + coefficient * sine
                let derivative = -distance * frequency * sine + coefficient * frequency * cosine
                return (goal + CGFloat(envelope * wave), CGFloat(envelope * (derivative - decay * wave)))
            }
            let x = axis(position.width, velocity.width, target.width)
            let y = axis(position.height, velocity.height, target.height)
            position = CGSize(width: x.0, height: y.0)
            velocity = CGSize(width: x.1, height: y.1)
        }
    }

    public static func dragTranslation(start: CGPoint, point: CGPoint, initialPan: CGSize,
                                       initialZoom: CGFloat, pan: CGSize, zoom: CGFloat) -> CGSize {
        let first = CanvasGeometry.canvasPoint(screen: start, pan: initialPan, zoom: initialZoom)
        let current = CanvasGeometry.canvasPoint(screen: point, pan: pan, zoom: zoom)
        return CGSize(width: (current.x - first.x) * zoom, height: (current.y - first.y) * zoom)
    }
}
