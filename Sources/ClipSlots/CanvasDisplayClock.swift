import AppKit
import CoreVideo
import QuartzCore

/// One display-linked clock for all small canvas animations. Samples use the
/// actual compositor cadence and do not redraw the complete canvas.
final class CanvasDisplayClock: NSObject {
    static let shared = CanvasDisplayClock()
    private var link: CVDisplayLink?
    private var subscribers: [UUID: () -> Void] = [:]
    private let subscriptionsLock = NSLock()
    private let lock = NSLock()
    private var queued = false
    private var nativeLink: AnyObject?
    private var fallbackTimer: Timer?
    private var active = false
    private var delivering = false
    private var lastDisplayTurn: TimeInterval?

    private override init() {
        super.init()
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if let link {
            CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
                guard let context else { return kCVReturnSuccess }
                let clock = Unmanaged<CanvasDisplayClock>.fromOpaque(context).takeUnretainedValue()
                clock.enqueue()
                return kCVReturnSuccess
            }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    @discardableResult
    func subscribe(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        subscriptionsLock.lock()
        let wasEmpty = subscribers.isEmpty
        subscribers[id] = callback
        subscriptionsLock.unlock()
        if wasEmpty { reconcileOnMain() }
        return id
    }

    func unsubscribe(_ id: UUID) {
        subscriptionsLock.lock()
        let removed = subscribers.removeValue(forKey: id)
        let empty = subscribers.isEmpty
        subscriptionsLock.unlock()
        if empty { reconcileOnMain() }
        withExtendedLifetime(removed) {}
    }

    private func reconcileOnMain() {
        if Thread.isMainThread { reconcile() }
        else { DispatchQueue.main.async { [weak self] in self?.reconcile() } }
    }

    private func reconcile() {
        subscriptionsLock.lock()
        let empty = subscribers.isEmpty
        subscriptionsLock.unlock()
        if empty {
            active = false
            if #available(macOS 14.0, *), let nativeLink = nativeLink as? CADisplayLink {
                nativeLink.invalidate()
            }
            nativeLink = nil
            fallbackTimer?.invalidate(); fallbackTimer = nil
            if let link, CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
        } else if !active {
            active = true
            start()
        }
    }

    private func start() {
        if #available(macOS 14.0, *), let screen = NSScreen.main {
            let display = screen.displayLink(target: self, selector: #selector(displayTurn(_:)))
            let rate = Float(max(60, screen.maximumFramesPerSecond))
            display.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            nativeLink = display
            display.add(to: .main, forMode: .common)
            // A display link may pause for an inactive or non-presenting app.
            // Admission must still complete; this watchdog is scheduling only,
            // and must never be treated as evidence of presented frames.
            lastDisplayTurn = nil
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.lastDisplayTurn.map({ ProcessInfo.processInfo.systemUptime - $0 > 1.0 / 30 }) ?? true {
                    self.deliver()
                }
            }
            fallbackTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }
        if let link, CVDisplayLinkStart(link) == kCVReturnSuccess { return }
        // Unsupported display configurations must never strand pending nodes or continuations.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.deliver() }
        fallbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @available(macOS 14.0, *)
    @objc private func displayTurn(_ display: CADisplayLink) {
        lastDisplayTurn = ProcessInfo.processInfo.systemUptime
        deliver()
    }

    private func deliver() {
        guard Thread.isMainThread else { enqueue(); return }
        guard !delivering else { return }
        delivering = true
        defer { delivering = false }
        subscriptionsLock.lock()
        let ids = Array(subscribers.keys)
        subscriptionsLock.unlock()
        for id in ids {
            subscriptionsLock.lock()
            let callback = subscribers[id]
            subscriptionsLock.unlock()
            // Never hold a lock while callbacks publish or unsubscribe themselves.
            callback?()
        }
    }

    private func enqueue() {
        lock.lock()
        if queued { lock.unlock(); return }
        queued = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // SwiftUI publication can synchronously enter a nested run loop.
            // Keep the turn reserved until every callback has returned.
            defer {
                self.lock.lock(); self.queued = false; self.lock.unlock()
            }
            self.deliver()
        }
    }

    /// Resume on the next scheduling turn; callers check cancellation.
    @MainActor
    func nextFrame() async {
        await withCheckedContinuation { continuation in
            var token: UUID?
            var resumed = false
            token = subscribe { [weak self] in
                guard !resumed else { return }
                resumed = true
                if let token { self?.unsubscribe(token) }
                continuation.resume()
            }
        }
    }
}
