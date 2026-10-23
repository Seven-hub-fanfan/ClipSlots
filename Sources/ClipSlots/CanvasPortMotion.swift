import SwiftUI
import AppKit
import ClipSlotsKit

/// The handle's presentation and native hit testing sample the same motion.
/// Only this small leaf redraws during a return animation, not the canvas.
final class CanvasPortMotion: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var highlighted = false
    private var lastCursor: CGPoint?
    private var from = CGPoint.zero
    private var destination = CGPoint.zero
    private var began = 0.0
    private var duration = 0.0
    private var overshoot: Double = 1.56
    private var firstFollowUntil: Double?
    private var following = false
    private var geometry: CGRect?
    private var coordinateScale: CGFloat = 1
    private var captureHome: CGPoint?
    private var revealFrom = 0.0
    private var revealTo = 0.0
    private var revealBegan = 0.0
    private var ticker: UUID?
    private let ticksAutomatically: Bool

    init(ticksAutomatically: Bool = true) { self.ticksAutomatically = ticksAutomatically }
    deinit { if let ticker { CanvasDisplayClock.shared.unsubscribe(ticker) } }

    func configure(zoom: CGFloat) {
        guard zoom.isFinite, zoom > 0 else { return }
        coordinateScale = zoom
    }
    func reveal(at now: Double = ProcessInfo.processInfo.systemUptime) -> CGFloat {
        let progress = min(max((now - revealBegan) / 0.3, 0), 1)
        let eased = Self.cubic(progress, overshoot: 1.56)
        return CGFloat(revealFrom) + CGFloat(revealTo - revealFrom) * eased
    }
    func opacity(at now: Double = ProcessInfo.processInfo.systemUptime) -> Double {
        Double(min(max(reveal(at: now), 0), 1))
    }
    func setVisible(_ visible: Bool, now: Double = ProcessInfo.processInfo.systemUptime) {
        let target = visible ? 1.0 : 0.0
        guard target != revealTo else { return }
        revealFrom = Double(reveal(at: now)); revealTo = target; revealBegan = now
        revision &+= 1
        startTicker()
    }
    func presentationOffset(output: Bool, at now: Double = ProcessInfo.processInfo.systemUptime) -> CGPoint {
        let magnetic = offset(at: now)
        // Hidden left handle translates right; hidden right handle translates left.
        return CGPoint(x: magnetic.x + (output ? -24 : 24) * coordinateScale * (1 - reveal(at: now)), y: magnetic.y)
    }

    func offset(at now: Double = ProcessInfo.processInfo.systemUptime) -> CGPoint {
        if following, let until = firstFollowUntil, now >= until, duration == 0.25 { return destination }
        guard duration > 0 else { return destination }
        let amount = min(max((now - began) / duration, 0), 1)
        let fraction = Self.cubic(amount, overshoot: overshoot)
        return CGPoint(x: from.x + (destination.x - from.x) * fraction,
                       y: from.y + (destination.y - from.y) * fraction)
    }

    func update(cursor: CGPoint?, home: CGPoint, output: Bool, zoom: CGFloat,
                now: Double = ProcessInfo.processInfo.systemUptime) {
        // A moved/zoomed node establishes a new screen-space hover session.
        let nextGeometry = CGRect(x: home.x, y: home.y, width: zoom, height: output ? 1 : 0)
        if geometry != nextGeometry {
            clear()
            geometry = nextGeometry
        }
        coordinateScale = zoom
        lastCursor = cursor
        guard let cursor else {
            reset(now: now)
            return
        }
        // The 80-square container itself moves with the glyph. Mouseleave is
        // tested against its presentation rect; the captured home stays fixed.
        let presented = offset(at: now)
        guard abs(cursor.x - home.x - presented.x) <= 40 * zoom,
              abs(cursor.y - home.y - presented.y) <= 40 * zoom else {
            reset(now: now)
            return
        }
        if !following {
            from = .zero; destination = .zero; duration = 0
            captureHome = home
            firstFollowUntil = nil
        }
        following = true
        let captured = captureHome ?? home
        guard CanvasPortInteractionGeometry.follows(cursor, home: captured, output: output, zoom: zoom) else {
            move(to: .zero, duration: 0.4, overshoot: 1.56, now: now)
            return
        }
        let next = CGPoint(x: cursor.x - captured.x, y: cursor.y - captured.y)
        if firstFollowUntil == nil { firstFollowUntil = now + 0.25 }
        let easing = now < (firstFollowUntil ?? now) ? 0.25 : 0
        move(to: next, duration: easing, overshoot: 1.8, now: now)
        refreshHighlight(at: now)
    }

    func reset(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard following else { return }
        let displayed = offset(at: now)
        following = false
        lastCursor = nil; highlighted = false
        captureHome = nil
        firstFollowUntil = nil
        move(to: .zero, duration: 0.4, overshoot: 1.56, now: now, origin: displayed)
    }

    func clear() {
        if let ticker { CanvasDisplayClock.shared.unsubscribe(ticker) }
        ticker = nil
        from = .zero
        lastCursor = nil; highlighted = false
        destination = .zero
        duration = 0
        following = false
        captureHome = nil
        firstFollowUntil = nil
        if ProcessInfo.processInfo.systemUptime < revealBegan + 0.3 { startTicker() }
    }

    private func move(to next: CGPoint, duration seconds: Double, overshoot: Double, now: Double,
                      origin: CGPoint? = nil) {
        guard destination != next || duration != seconds else { return }
        from = origin ?? offset(at: now)
        destination = next
        began = now
        duration = seconds
        self.overshoot = overshoot
        revision &+= 1
        if seconds > 0 { startTicker() }
    }

    private func startTicker() {
        guard ticksAutomatically, ticker == nil else { return }
        ticker = CanvasDisplayClock.shared.subscribe { [weak self] in
            guard let self else { return }
            self.revision &+= 1
            let time = ProcessInfo.processInfo.systemUptime
            self.refreshHighlight(at: time)
            let magneticDone = time >= self.began + self.duration
                || (self.following && time >= (self.firstFollowUntil ?? .infinity))
            if magneticDone && time >= self.revealBegan + 0.3 {
                if let ticker = self.ticker { CanvasDisplayClock.shared.unsubscribe(ticker) }
                self.ticker = nil
            }
        }
    }

    private func refreshHighlight(at now: Double) {
        guard let cursor = lastCursor, let geometry else { highlighted = false; return }
        let delta = presentationOffset(output: geometry.height == 1, at: now)
        let next = hypot(cursor.x - geometry.minX - delta.x, cursor.y - geometry.minY - delta.y)
            <= CanvasSkin.portDiameter * coordinateScale / 2
        if highlighted != next { highlighted = next }
    }

    /// CSS cubic-bezier(.34, y1, .64, 1), including its intentional overshoot.
    private static func cubic(_ progress: Double, overshoot: Double) -> CGFloat {
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let t = (low + high) / 2, inverse = 1 - t
            let x = 3 * inverse * inverse * t * 0.34 + 3 * inverse * t * t * 0.64 + t * t * t
            if x < progress { low = t } else { high = t }
        }
        let t = (low + high) / 2, inverse = 1 - t
        return CGFloat(3 * inverse * inverse * t * overshoot + 3 * inverse * t * t + t * t * t)
    }
}

final class CanvasPortMotions {
    private var entries: [String: CanvasPortMotion] = [:]

    func motion(nodeID: String, output: Bool) -> CanvasPortMotion {
        let key = nodeID + (output ? ":output" : ":input")
        if let existing = entries[key] { return existing }
        let motion = CanvasPortMotion()
        entries[key] = motion
        return motion
    }

    func reset(except keys: Set<String> = []) {
        for (key, motion) in entries where !keys.contains(key) { motion.reset() }
    }

    func prune(nodeIDs: Set<String>) {
        entries = entries.filter { key, _ in
            nodeIDs.contains(String(key.dropLast(key.hasSuffix(":output") ? 7 : 6)))
        }
    }
}

struct CanvasMovingPort: View {
    @ObservedObject var motion: CanvasPortMotion
    let home: CGPoint
    var frozenPoint: CGPoint? = nil
    let isActive: Bool
    let isConnected: Bool
    var visible = true
    var output = true
    var zoom: CGFloat = 1
    var forceHidden = false

    var body: some View {
        let offset = motion.presentationOffset(output: output)
        let point = frozenPoint ?? CGPoint(x: home.x + offset.x, y: home.y + offset.y)
        CanvasPort(isActive: isActive || motion.highlighted, isConnected: isConnected, zoom: zoom)
            .opacity(forceHidden ? 0 : frozenPoint != nil ? 1 : motion.opacity())
            .position(point)
            .allowsHitTesting(false)
            .onAppear { motion.configure(zoom: zoom); motion.setVisible(visible) }
            .onChange(of: zoom) { motion.configure(zoom: $0) }
            .onChange(of: visible) { motion.setVisible($0) }
    }
}
