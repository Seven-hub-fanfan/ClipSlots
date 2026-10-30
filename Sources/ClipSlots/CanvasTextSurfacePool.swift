import AppKit
import SwiftUI
import ClipSlotsKit

/// A bounded pool of detached native text surfaces. Reentering the same canvas
/// reuses Core Animation text layers instead of rebuilding their fonts/shadows.
final class CanvasTextSurfacePool {
    private var surfaces: [String: CanvasIdleTextSlot.Surface] = [:]
    private var pendingHosts: [UUID: Int] = [:]
    var isMounting: Bool { pendingHosts.values.contains { $0 > 0 } }
    func pending(_ count: Int, host: UUID) {
        pendingHosts[host] = count > 0 ? count : nil
    }
    func surface(for id: String) -> CanvasIdleTextSlot.Surface {
        if let surface = surfaces[id] { return surface }
        let surface = CanvasIdleTextSlot.Surface()
        surfaces[id] = surface
        return surface
    }
    func retain(_ ids: Set<String>) {
        if surfaces.count > 128 { surfaces = surfaces.filter { ids.contains($0.key) } }
    }
}

struct CanvasPooledTextLayer: NSViewRepresentable {
    let pool: CanvasTextSurfacePool
    let items: [CanvasIdleTextItem]
    let pan: CGSize
    let zoom: CGFloat
    let layoutZoom: CGFloat
    let registry: CanvasLocalControlRegistry
    let onOpenInputFiles: (CanvasNode) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    func makeNSView(context: Context) -> Host { Host(pool: pool) }
    func updateNSView(_ view: Host, context: Context) {
        view.update(items: items, pan: pan, zoom: zoom, scale: layoutZoom,
                    dark: scheme == .dark, reduced: reducedMotion, registry: registry, open: onOpenInputFiles)
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.detach() }
    final class Host: NSView {
        let pool: CanvasTextSurfacePool
        private let hostID = UUID()
        private var mounted = Set<String>()
        private var pending: [CanvasIdleTextItem] = []
        private var ticker: UUID?
        private var pan = CGSize.zero
        private var zoom: CGFloat = 1
        private var scale: CGFloat = 2
        private var dark = false
        private var reduced = false
        private var registry = CanvasLocalControlRegistry()
        private struct ContentKey: Equatable {
            let node: CanvasNode
            let text: String
            let path: String
            let scale: CGFloat
            let dark: Bool
            let textVisible: Bool
            let fanVisible: Bool
        }
        private var contentKeys: [String: ContentKey] = [:]
        private var open: (CanvasNode) -> Void = { _ in }
        override var isFlipped: Bool { true }
        init(pool: CanvasTextSurfacePool) { self.pool = pool; super.init(frame: .zero); wantsLayer = true }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? {
            for child in subviews.reversed() {
                if let hit = child.hitTest(child.convert(point, from: self)) { return hit }
            }
            return nil
        }
        func update(items: [CanvasIdleTextItem], pan: CGSize, zoom: CGFloat, scale: CGFloat,
                    dark: Bool, reduced: Bool, registry: CanvasLocalControlRegistry,
                    open: @escaping (CanvasNode) -> Void) {
            if self.registry !== registry { contentKeys = [:] }
            self.pan = pan; self.zoom = zoom; self.scale = scale
            self.dark = dark; self.reduced = reduced; self.registry = registry; self.open = open
            let ids = Set(items.map { $0.node.id })
            for id in mounted.subtracting(ids) {
                pool.surface(for: id).removeFromSuperview()
                registry.nativeNodes[id] = nil
                contentKeys[id] = nil
            }
            mounted.formIntersection(ids)
            for item in items where mounted.contains(item.node.id) { configure(item) }
            pending = items.filter { !mounted.contains($0.node.id) }
            pool.pending(pending.count, host: hostID)
            pool.retain(ids)
            if pending.isEmpty { cancel(); return }
            guard ticker == nil else { return }
            ticker = CanvasDisplayClock.shared.subscribe { [weak self] in
                guard let self, let item = self.pending.first else { self?.cancel(); return }
                self.pending.removeFirst()
                self.configure(item)
                self.addSubview(self.pool.surface(for: item.node.id))
                self.mounted.insert(item.node.id)
                self.pool.pending(self.pending.count, host: self.hostID)
                if self.pending.isEmpty { self.cancel() }
            }
        }
        private func configure(_ item: CanvasIdleTextItem) {
            let node = item.node, surface = pool.surface(for: item.node.id)
            let plan = CanvasCardLayout.verticalPlan(nodeHeight: node.height, renderScale: scale,
                                                     headerFontSize: 9.5, footerFontSize: 9.5)
            let cardSize = CanvasFanGeometry.fanCardSize(boxHeight: plan.previewHeight1x)
            let key = ContentKey(node: node, text: item.text, path: item.path, scale: scale,
                                 dark: dark,
                                 textVisible: CanvasScreenText.textVisible(nodeSize: node.frame.size, zoom: zoom),
                                 fanVisible: CanvasScreenText.cardTextVisible(cardSize: cardSize, zoom: zoom))
            if contentKeys[node.id] != key {
            surface.update(node: node, text: item.text, path: item.path, scale: scale, zoom: zoom,
                dark: dark, reducedMotion: reduced, registry: registry, open: { [weak self] in self?.open(node) })
                contentKeys[node.id] = key
            }
            let frame = CGRect(x: node.x * zoom + pan.width, y: node.y * zoom + pan.height,
                               width: node.width * zoom, height: node.height * zoom)
            let bounds = CGRect(x: 0, y: 0, width: node.width * scale, height: node.height * scale)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if surface.frame != frame { surface.frame = frame }
            if surface.bounds != bounds { surface.bounds = bounds }
            CATransaction.commit()
        }
        private func cancel() {
            if let ticker { CanvasDisplayClock.shared.unsubscribe(ticker) }
            ticker = nil
        }
        func detach() {
            cancel()
            pool.pending(0, host: hostID)
            for id in mounted {
                pool.surface(for: id).removeFromSuperview()
                registry.nativeNodes[id] = nil
            }
            mounted = []; pending = []; contentKeys = [:]
        }
        deinit { detach() }
    }
}
