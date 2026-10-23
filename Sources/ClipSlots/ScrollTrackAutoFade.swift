import AppKit
import SwiftUI

/// Local to the editor grid; never changes the system's scrollbar preference.
struct ScrollTrackAutoFade: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.attach() }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }

    final class Anchor: NSView {
        private static let usesScrollLayer: Bool = {
            #if DEBUG
            return ProcessInfo.processInfo.environment["CLIPSLOTS_PROBE_LEGACY_SCROLL_LAYER"] != "1"
            #else
            return true
            #endif
        }()
        private static let usesClipLayer: Bool = {
            #if DEBUG
            return ProcessInfo.processInfo.environment["CLIPSLOTS_PROBE_LEGACY_CLIP_LAYER"] != "1"
            #else
            return true
            #endif
        }()
        private static let usesDocumentLayer: Bool = {
            #if DEBUG
            return ProcessInfo.processInfo.environment["CLIPSLOTS_PROBE_LEGACY_DOCUMENT_LAYER"] != "1"
            #else
            return true
            #endif
        }()
        private weak var scroll: NSScrollView?
        private var observer: NSObjectProtocol?
        private var fade: DispatchWorkItem?
        private var lastOrigin: CGPoint?
        private var lastScrollTime: TimeInterval = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        func attach() {
            guard let target = enclosingScrollView, scroll !== target else { return }
            detach()
            scroll = target
            if Self.usesScrollLayer, !target.wantsLayer { target.wantsLayer = true }
            if Self.usesClipLayer, !target.contentView.wantsLayer { target.contentView.wantsLayer = true }
            if Self.usesDocumentLayer, let document = target.documentView, !document.wantsLayer {
                document.wantsLayer = true
            }
            target.scrollerStyle = .overlay
            target.autohidesScrollers = true
            target.contentView.postsBoundsChangedNotifications = true
            lastOrigin = target.contentView.bounds.origin
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: target.contentView, queue: .main) { [weak self] _ in self?.scrolled() }
        }
        private func scrolled() {
            guard let scroll, scroll.contentView.bounds.origin != lastOrigin else { return }
            lastOrigin = scroll.contentView.bounds.origin
            lastScrollTime = ProcessInfo.processInfo.systemUptime
            if scroll.verticalScroller?.alphaValue != 1 {
                scroll.verticalScroller?.layer?.removeAllAnimations()
                scroll.verticalScroller?.alphaValue = 1
            }
            scheduleFade(after: 0.8)
        }
        private func scheduleFade(after seconds: Double) {
            guard fade == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.fade = nil
                self?.finishFade()
            }
            fade = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
        private func finishFade() {
            let remaining = 0.8 - (ProcessInfo.processInfo.systemUptime - lastScrollTime)
            if remaining > 0 { scheduleFade(after: remaining); return }
            guard let scroller = scroll?.verticalScroller else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.28
                scroller.animator().alphaValue = 0
            }
        }
        func detach() {
            fade?.cancel(); fade = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            scroll?.verticalScroller?.alphaValue = 1
            scroll = nil
        }
        deinit {
            fade?.cancel()
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
