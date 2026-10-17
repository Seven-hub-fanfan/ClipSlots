import AppKit
import SwiftUI
import ClipSlotsKit

struct CanvasMiniMap: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let nodes: [CanvasNode]
    let selectedIDs: Set<String>
    let viewport: CGRect
    @Binding var pan: CGSize
    let zoom: CGFloat
    let reduceMotion: Bool
    let onViewportEnd: () -> Void

    func makeNSView(context: Context) -> CanvasMiniMapView { CanvasMiniMapView() }
    func updateNSView(_ view: CanvasMiniMapView, context: Context) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        view.nodes = nodes; view.selectedIDs = selectedIDs; view.viewport = viewport
        view.zoom = zoom; view.reduceMotion = reduceMotion
        view.onPan = { pan = $0 }; view.onEnd = onViewportEnd
        view.synchronize(pan: pan)
    }
    static func dismantleNSView(_ view: CanvasMiniMapView, coordinator: ()) { view.cancelMotion() }
}

/// One AppKit mouse session owns the map gesture, including release outside its bounds.
/// The viewport rectangle follows the pointer; canvas motion follows the physical spring.
final class CanvasMiniMapView: NSView {
    var nodes: [CanvasNode] = []
    var selectedIDs: Set<String> = []
    var viewport = CGRect.zero
    var zoom: CGFloat = 1
    var reduceMotion = false
    var onPan: (CGSize) -> Void = { _ in }
    var onEnd: () -> Void = {}
    private(set) var pan = CGSize.zero
    private(set) var isDraggingViewport = false
    private var startPoint = CGPoint.zero
    private var startPan = CGSize.zero
    private var startZoom: CGFloat = 1
    private var startRect = CGRect.zero
    private var draggedRect: CGRect?
    private var spring: CanvasReplicaGeometry.MapSpring?
    private var timer: Timer?
    private var lastTime: TimeInterval = 0
    private var stopTime: TimeInterval?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("画布小地图，拖动视口或点击定位")
        setAccessibilityIdentifier("canvas-minimap")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var worldViewport: CGRect {
        let safeZoom = max(zoom, CanvasGeometry.zoomMin)
        let origin = CanvasGeometry.canvasPoint(screen: viewport.origin, pan: pan, zoom: safeZoom)
        return CGRect(origin: origin, size: CGSize(width: viewport.width / safeZoom, height: viewport.height / safeZoom))
    }
    var projection: CanvasReplicaGeometry.MapProjection {
        CanvasReplicaGeometry.mapProjection(nodes: nodes.map(\.frame), viewport: worldViewport)
    }
    var viewportRect: CGRect { draggedRect ?? projection.rect(worldViewport) }
    func synchronize(pan value: CGSize) {
        if spring == nil { pan = value }
        needsDisplay = true
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isDraggingViewport ? .closedHand : .openHand)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let background = dark
            ? NSColor(srgbRed: 24 / 255, green: 24 / 255, blue: 27 / 255, alpha: 0.92)
            : NSColor(srgbRed: 247 / 255, green: 247 / 255, blue: 249 / 255, alpha: 0.97)
        let nodeFill = dark
            ? NSColor(srgbRed: 90 / 255, green: 90 / 255, blue: 99 / 255, alpha: 0.5)
            : NSColor(srgbRed: 160 / 255, green: 165 / 255, blue: 177 / 255, alpha: 0.6)
        let viewportInk = dark ? NSColor.white
            : NSColor(srgbRed: 64 / 255, green: 68 / 255, blue: 78 / 255, alpha: 0.9)
        context.saveGState()
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.clip()
        context.setFillColor(background.cgColor)
        context.fill(bounds)
        let nodeProjection = CanvasReplicaGeometry.mapNodeProjection(nodes: nodes.map(\.frame), viewport: worldViewport)
        for node in nodes {
            let selected = selectedIDs.contains(node.id)
            let radius = 4 * nodeProjection.scale
            let path = CGPath(roundedRect: nodeProjection.rect(node.frame),
                              cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(path)
            context.setFillColor(selected
                ? NSColor(srgbRed: 59 / 255, green: 130 / 255, blue: 246 / 255, alpha: 0.9).cgColor
                : nodeFill.cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(selected
                ? NSColor(srgbRed: 59 / 255, green: 130 / 255, blue: 246 / 255, alpha: 0.6).cgColor
                : viewportInk.withAlphaComponent(dark ? 0.6 : 0.4).cgColor)
            context.setLineWidth(nodeProjection.scale)
            context.strokePath()
        }
        let rect = viewportRect
        context.addRect(bounds); context.addRect(rect)
        context.setFillColor(NSColor.black.withAlphaComponent(dark ? 0.22 : 0.06).cgColor)
        context.drawPath(using: .eoFill)
        context.setFillColor((dark ? NSColor.black : NSColor.white).withAlphaComponent(dark ? 0.1 : 0.25).cgColor)
        context.fill(rect)
        // CSS border is drawn inside the element's 1.5pt boundary.
        context.setStrokeColor(viewportInk.cgColor); context.setLineWidth(1.5)
        context.stroke(rect.insetBy(dx: 0.75, dy: 0.75))
        context.restoreGState()
        context.setStrokeColor(viewportInk.withAlphaComponent(dark ? 0.15 : 0.14).cgColor)
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                               cornerWidth: 7.5, cornerHeight: 7.5, transform: nil))
        context.strokePath()
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = viewportRect
        let currentProjection = projection
        startPoint = point; startPan = pan; startZoom = zoom; startRect = rect
        stopTime = nil
        if rect.minX <= point.x && point.x <= rect.maxX && rect.minY <= point.y && point.y <= rect.maxY {
            isDraggingViewport = true; draggedRect = rect
        } else {
            isDraggingViewport = false; draggedRect = nil
            let world = currentProjection.worldPoint(point)
            startMotion(target: CGSize(width: viewport.midX - world.x * zoom,
                                       height: viewport.midY - world.y * zoom))
            stopTime = ProcessInfo.processInfo.systemUptime + 0.3
        }
        window?.invalidateCursorRects(for: self)
    }
    override func mouseDragged(with event: NSEvent) {
        guard isDraggingViewport else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
        draggedRect = startRect.offsetBy(dx: delta.width, dy: delta.height)
        let scale = projection.scale
        let target = CGSize(width: startPan.width - delta.width / scale * startZoom,
                            height: startPan.height - delta.height / scale * startZoom)
        startMotion(target: target)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard isDraggingViewport else { return }
        isDraggingViewport = false; draggedRect = nil
        if reduceMotion { onEnd(); needsDisplay = true; return }
        if timer == nil { startMotion(target: pan) }
        stopTime = ProcessInfo.processInfo.systemUptime + 0.3
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    private func startMotion(target: CGSize) {
        if reduceMotion {
            pan = target; onPan(target); needsDisplay = true
            if !isDraggingViewport { onEnd() }
            return
        }
        if spring == nil { spring = .init(position: pan) }
        spring?.target = target
        guard timer == nil else { return }
        lastTime = ProcessInfo.processInfo.systemUptime
        let next = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard var motion = spring else { return }
        motion.advance(seconds: now - lastTime); lastTime = now
        spring = motion
        if abs(pan.width - motion.position.width) > 0.0001 || abs(pan.height - motion.position.height) > 0.0001 {
            pan = motion.position; onPan(pan); needsDisplay = true
        }
        if let stopTime, now >= stopTime {
            timer?.invalidate(); timer = nil; spring = nil; self.stopTime = nil
            onEnd()
        }
    }
    func cancelMotion() {
        timer?.invalidate(); timer = nil; spring = nil; stopTime = nil
        isDraggingViewport = false; draggedRect = nil
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelMotion() }
        super.viewWillMove(toWindow: newWindow)
    }
}
