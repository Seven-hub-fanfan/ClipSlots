import AppKit
import SwiftUI
import ClipSlotsKit

struct CanvasIdleTextItem {
    let node: CanvasNode
    let text: String
    let path: String
}

/// One host admits passive slots directly on display turns. Adding a slot
/// changes an AppKit child and its layers, without publishing a SwiftUI list.
struct CanvasIdleTextLayer: NSViewRepresentable {
    let items: [CanvasIdleTextItem]
    let pan: CGSize
    let zoom: CGFloat
    let layoutZoom: CGFloat
    let registry: CanvasLocalControlRegistry
    let onOpenInputFiles: (CanvasNode) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        view.update(items: items, pan: pan, zoom: zoom, scale: layoutZoom, dark: scheme == .dark,
                    reducedMotion: reducedMotion, registry: registry, open: onOpenInputFiles)
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.cancel() }

    final class Host: NSView {
        override var isFlipped: Bool { true }
        private var cards: [String: CanvasIdleTextSlot.Surface] = [:]
        private var pending: [CanvasIdleTextItem] = []
        private var ticker: UUID?
        private var pan = CGSize.zero
        private var zoom: CGFloat = 1
        private var scale: CGFloat = 2
        private var dark = false
        private var reduced = false
        private var registry = CanvasLocalControlRegistry()
        private var open: (CanvasNode) -> Void = { _ in }
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? {
            for child in subviews.reversed() {
                if let hit = child.hitTest(child.convert(point, from: self)) { return hit }
            }
            return nil
        }
        func update(items: [CanvasIdleTextItem], pan: CGSize, zoom: CGFloat, scale: CGFloat, dark: Bool,
                    reducedMotion: Bool, registry: CanvasLocalControlRegistry, open: @escaping (CanvasNode) -> Void) {
            self.pan = pan; self.zoom = zoom; self.scale = scale
            self.dark = dark; self.reduced = reducedMotion; self.registry = registry; self.open = open
            let ids = Set(items.map { $0.node.id })
            for id in Array(cards.keys) where !ids.contains(id) {
                cards.removeValue(forKey: id)?.removeFromSuperview()
                registry.nativeNodes[id] = nil
            }
            for item in items where cards[item.node.id] != nil { configure(cards[item.node.id]!, item: item) }
            pending = items.filter { cards[$0.node.id] == nil }
            guard !pending.isEmpty else { cancel(); return }
            guard ticker == nil else { return }
            ticker = CanvasDisplayClock.shared.subscribe { [weak self] in
                guard let self, let item = self.pending.first else { self?.cancel(); return }
                self.pending.removeFirst()
                let surface = CanvasIdleTextSlot.Surface()
                self.configure(surface, item: item)
                self.cards[item.node.id] = surface
                self.addSubview(surface)
                if self.pending.isEmpty { self.cancel() }
            }
        }
        private func configure(_ surface: CanvasIdleTextSlot.Surface, item: CanvasIdleTextItem) {
            let node = item.node
            surface.update(node: node, text: item.text, path: item.path, scale: scale, zoom: zoom,
                           dark: dark, reducedMotion: reduced, registry: registry, open: { [weak self] in self?.open(node) })
            let frame = CGRect(x: node.x * zoom + pan.width, y: node.y * zoom + pan.height,
                               width: node.width * zoom, height: node.height * zoom)
            let bounds = CGRect(x: 0, y: 0, width: node.width * scale, height: node.height * scale)
            if surface.frame != frame { surface.frame = frame }
            if surface.bounds != bounds { surface.bounds = bounds }
        }
        func cancel() {
            if let ticker { CanvasDisplayClock.shared.unsubscribe(ticker) }
            ticker = nil
        }
        deinit {
            cancel()
            for id in cards.keys { registry.nativeNodes[id] = nil }
        }
    }
}
