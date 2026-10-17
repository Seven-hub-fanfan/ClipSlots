import Foundation

/// Native presentation coordinates, not persisted node geometry.
public struct CanvasPileMemberPose: Equatable {
    public var frame: CGRect
    public var rotation: Double
    public var shade: Double
    public var zIndex: Int

    public init(frame: CGRect, rotation: Double = 0, shade: Double = 0, zIndex: Int = 0) {
        self.frame = frame; self.rotation = rotation; self.shade = shade; self.zIndex = zIndex
    }

    public var rotatedBounds: CGRect {
        let angle = rotation * .pi / 180
        let width = abs(cos(angle)) * frame.width + abs(sin(angle)) * frame.height
        let height = abs(sin(angle)) * frame.width + abs(cos(angle)) * frame.height
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    public func interpolated(to target: Self, progress: CGFloat) -> Self {
        let p = progress.isFinite ? min(max(progress, 0), 1) : 0
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        return Self(frame: CGRect(x: mix(frame.minX, target.frame.minX), y: mix(frame.minY, target.frame.minY),
                                  width: mix(frame.width, target.frame.width), height: mix(frame.height, target.frame.height)),
                    rotation: rotation + (target.rotation - rotation) * Double(p),
                    shade: shade + (target.shade - shade) * Double(p), zIndex: target.zIndex)
    }
}

public enum CanvasPileGalleryMotion {
    // as.gallery, CPe, FMe, LMe, hP from the archived static slices.
    public static let collapseThreshold: CGFloat = 72
    public static let compactExpansion: CGFloat = 1
    public static let interactiveExpansion: CGFloat = 2
    public static let returnExpansion: CGFloat = 2.35
    public static let collapseDuration = 0.36
    public static let pickupDuration = 0.32
    public static let rotationDuration = 0.26
    public static let closingRotationDelay = 0.18
    public static let staggerStep = 0.012
    public static let labelDelay = 0.32
    public static let labelDuration = 0.16
    public static let landingDuration = 0.18

    public static func hasCrossedThreshold(_ delta: CGSize) -> Bool {
        guard delta.width.isFinite, delta.height.isFinite else { return false }
        return hypot(delta.width, delta.height) >= collapseThreshold
    }

    public static func stagger(index: Int) -> Double {
        Double(min(max(index, 0), 4)) * staggerStep
    }

    public static func completionDuration(memberCount: Int) -> Double {
        CanvasPileGeometry.galleryDuration + stagger(index: memberCount - 1) + 0.02
    }

    /// FPe's screen center/zoom and d_'s last-five layout and hidden-member fit.
    /// C0/b3 were not exported: bounds use a native union of rotated visible cards.
    public static func pilePoses(_ members: [CanvasNode], screenFrame: CGRect,
                                 zoom: CGFloat, expansion: CGFloat) -> [String: CanvasPileMemberPose] {
        guard zoom.isFinite, zoom > 0, !members.isEmpty else { return [:] }
        let visible = Array(members.suffix(5))
        let cover = CanvasPileGeometry.displaySize(visible[0])
        let firstVisible = members.count - visible.count
        var result: [String: CanvasPileMemberPose] = [:]
        for (index, member) in members.enumerated() {
            let visibleIndex = index - firstVisible
            let layer = CanvasPileGeometry.layer(index: max(visibleIndex, 0), count: visible.count, expansion: expansion)
            let size = CanvasPileGeometry.displaySize(member)
            let fit = visibleIndex >= 0 ? 1 : min(max(cover.width - 16, 1) / max(size.width, 1),
                                                  max(cover.height - 16, 1) / max(size.height, 1), 1)
            let width = size.width * zoom * fit, height = size.height * zoom * fit
            result[member.id] = CanvasPileMemberPose(
                frame: CGRect(x: screenFrame.midX + layer.offset.x * zoom - width / 2,
                              y: screenFrame.midY + layer.offset.y * zoom - height / 2,
                              width: width, height: height),
                rotation: layer.rotation, shade: layer.shade, zIndex: max(visibleIndex + 1, 0))
        }
        return result
    }

    public static func returnBounds(_ members: [CanvasNode], screenFrame: CGRect, zoom: CGFloat) -> CGRect {
        let poses = pilePoses(members, screenFrame: screenFrame, zoom: zoom, expansion: returnExpansion)
        return poses.values.filter { $0.zIndex > 0 }.map(\.rotatedBounds).reduce(CGRect.null) { $0.union($1) }
    }

    public static func gridPose(_ frame: CGRect, viewport: CGSize, pan: CGSize, zoom: CGFloat) -> CanvasPileMemberPose {
        CanvasPileMemberPose(frame: CGRect(x: viewport.width / 2 + frame.minX * zoom + pan.width,
                                          y: viewport.height / 2 + frame.minY * zoom + pan.height,
                                          width: frame.width * zoom, height: frame.height * zoom), zIndex: 1)
    }

    /// Own-native replacement for the missing NPe: retain the fractional grab
    /// point when the picked-up card changes from gallery zoom to canvas zoom.
    public static func grabFraction(pointer: CGPoint, frame: CGRect) -> CGPoint {
        CGPoint(x: min(max((pointer.x - frame.minX) / max(frame.width, 1), 0), 1),
                y: min(max((pointer.y - frame.minY) / max(frame.height, 1), 0), 1))
    }

    public static func carriedFrame(size: CGSize, pointer: CGPoint, grab: CGPoint) -> CGRect {
        CGRect(x: pointer.x - size.width * grab.x, y: pointer.y - size.height * grab.y,
               width: size.width, height: size.height)
    }
}

/// One gallery gesture owns the session until its visual handoff completes.
/// Revision-checked completion prevents cancelled timers from closing a new phase.
public struct CanvasPileGallerySession: Equatable {
    public enum Phase: String {
        case opening, open, dragging, collapsed, closing
        case returningToCell, returningToPile, landingOnCanvas, closed
    }
    public enum Handoff: Equatable {
        case cell(String), pile(String), canvas(String)
    }

    public private(set) var phase: Phase = .opening
    public private(set) var memberID: String?
    public private(set) var revision = 0

    public init() {}
    public var isDragging: Bool { phase == .dragging || phase == .collapsed }
    public var isCollapsed: Bool {
        [.collapsed, .returningToPile, .landingOnCanvas].contains(phase)
    }

    @discardableResult public mutating func beginDrag(_ id: String) -> Bool {
        guard phase == .open, !id.isEmpty else { return false }
        memberID = id; phase = .dragging; revision += 1
        return true
    }

    @discardableResult public mutating func updateDrag(_ delta: CGSize) -> Bool {
        guard phase == .dragging, CanvasPileGalleryMotion.hasCrossedThreshold(delta) else { return false }
        phase = .collapsed; revision += 1
        return true
    }

    @discardableResult public mutating func finishDrag(overReturnTarget: Bool) -> Handoff? {
        guard isDragging, let id = memberID else { return nil }
        let result: Handoff
        if phase == .dragging { phase = .returningToCell; result = .cell(id) }
        else if overReturnTarget { phase = .returningToPile; result = .pile(id) }
        else { phase = .landingOnCanvas; result = .canvas(id) }
        revision += 1
        return result
    }

    /// rDe.Zt: cancellation restores a cell before collapse, returns to the pile
    /// after collapse. Neither path extracts content.
    @discardableResult public mutating func cancelDrag() -> Handoff? {
        finishDrag(overReturnTarget: true)
    }

    @discardableResult public mutating func requestClose() -> Bool {
        guard phase == .open || phase == .opening else { return false }
        phase = .closing; revision += 1
        return true
    }

    @discardableResult public mutating func complete(revision expected: Int) -> Bool {
        guard expected == revision else { return false }
        switch phase {
        case .opening, .returningToCell: phase = .open
        case .closing, .returningToPile, .landingOnCanvas: phase = .closed
        default: return false
        }
        memberID = nil; revision += 1
        return true
    }
}
