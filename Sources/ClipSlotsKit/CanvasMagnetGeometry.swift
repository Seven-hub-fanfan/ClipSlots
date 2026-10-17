import Foundation
import CoreGraphics

/// One adjustment for the whole dragged selection, with screen-space acquisition
/// and release distances so snapping feels the same at every zoom.
public enum CanvasMagnetGeometry {
    public struct Lock: Equatable {
        public let delta: CGFloat
        public let guide: CGFloat
    }

    public struct State: Equatable {
        public var x: Lock?
        public var y: Lock?
        public init(x: Lock? = nil, y: Lock? = nil) { self.x = x; self.y = y }
    }

    public struct Result {
        public let delta: CGSize
        public let verticalGuide: CGFloat?
        public let horizontalGuide: CGFloat?
        public let state: State
    }

    public static func resolve(moving: [CGRect], stationary: [CGRect], proposed: CGSize,
                               zoom: CGFloat, grid: Bool, previous: CGSize? = nil,
                               state: State = State()) -> Result {
        guard let first = moving.first, proposed.width.isFinite, proposed.height.isFinite,
              zoom.isFinite, zoom > 0 else {
            return Result(delta: proposed.width.isFinite && proposed.height.isFinite ? proposed : .zero,
                          verticalGuide: nil, horizontalGuide: nil, state: State())
        }
        let bounds = moving.dropFirst().reduce(first) { $0.union($1) }
        let translated = bounds.offsetBy(dx: proposed.width, dy: proposed.height)
        let threshold = 8 / max(0.05, zoom), release = 14 / max(0.05, zoom)
        let gap: CGFloat = 28
        var xs: [(CGFloat, CGFloat)] = []
        var ys: [(CGFloat, CGFloat)] = []
        for rect in stationary {
            if translated.maxY + gap + release >= rect.minY && translated.minY - gap - release <= rect.maxY {
                for a in [translated.minX, translated.midX, translated.maxX] {
                    for b in [rect.minX, rect.midX, rect.maxX] { xs.append((b - a, b)) }
                }
                xs.append((rect.maxX + gap - translated.minX, rect.maxX + gap))
                xs.append((rect.minX - gap - translated.maxX, rect.minX - gap))
            }
            if translated.maxX + gap + release >= rect.minX && translated.minX - gap - release <= rect.maxX {
                for a in [translated.minY, translated.midY, translated.maxY] {
                    for b in [rect.minY, rect.midY, rect.maxY] { ys.append((b - a, b)) }
                }
                ys.append((rect.maxY + gap - translated.minY, rect.maxY + gap))
                ys.append((rect.minY - gap - translated.maxY, rect.minY - gap))
            }
        }
        func pick(_ candidates: [(CGFloat, CGFloat)], lock: Lock?, previousDelta: CGFloat?,
                  proposedDelta: CGFloat) -> (CGFloat, CGFloat)? {
            func isHeld(_ candidate: (CGFloat, CGFloat)) -> Bool {
                if let lock {
                    return abs(proposedDelta + candidate.0 - lock.delta) < 0.0001
                        && abs(candidate.1 - lock.guide) < 0.0001
                }
                return previousDelta.map { abs($0 - proposedDelta - candidate.0) < 0.0001 } == true
            }
            let eligible = candidates.filter { candidate in
                abs(candidate.0) <= threshold
                    || (isHeld(candidate) && abs(candidate.0) <= release)
            }
            return eligible.min { a, b in
                let aHeld = isHeld(a), bHeld = isHeld(b)
                if aHeld != bHeld { return aHeld }
                if abs(a.0) != abs(b.0) { return abs(a.0) < abs(b.0) }
                return a.1 < b.1
            }
        }
        let x = pick(xs, lock: state.x, previousDelta: previous?.width, proposedDelta: proposed.width)
        let y = pick(ys, lock: state.y, previousDelta: previous?.height, proposedDelta: proposed.height)
        // ReactFlow anchors a multi-drag grid correction to its first item.
        // JavaScript Math.round ties go toward +infinity, including negatives.
        func gridDelta(_ origin: CGFloat, _ delta: CGFloat) -> CGFloat {
            let step = CanvasReplicaGeometry.gridStep
            return floor((origin + delta) / step + 0.5) * step - origin
        }
        let gridX = gridDelta(first.minX, proposed.width)
        let gridY = gridDelta(first.minY, proposed.height)
        return Result(delta: CGSize(width: x.map { proposed.width + $0.0 } ?? (grid ? gridX : proposed.width),
                                    height: y.map { proposed.height + $0.0 } ?? (grid ? gridY : proposed.height)),
                      verticalGuide: x?.1, horizontalGuide: y?.1,
                      state: State(x: x.map { Lock(delta: proposed.width + $0.0, guide: $0.1) },
                                   y: y.map { Lock(delta: proposed.height + $0.0, guide: $0.1) }))
    }

    /// Same row, immediately to the right; occupied frames cause horizontal
    /// displacement only, preserving the source's top alignment.
    public static func resultOrigin(source: CGRect, size: CGSize, occupied: [CGRect],
                                    gap: CGFloat = 28) -> CGPoint {
        var x = source.maxX + gap
        for _ in 0...occupied.count {
            let frame = CGRect(x: x, y: source.minY, width: size.width, height: size.height)
            let collisions = occupied.filter { $0.insetBy(dx: -gap / 2, dy: -8).intersects(frame) }
            guard let end = collisions.map(\.maxX).max() else { break }
            x = max(x, end + gap)
        }
        return CGPoint(x: x, y: source.minY)
    }
}
