import SwiftUI
import AppKit
import ClipSlotsKit

/// Static edges, command previews and flow all stay below the node layer.
/// Only connected edge leaves observe handle motion; Core Animation drives flow.
struct CanvasEdgeLayer: View {
    let edges: [CanvasEdge]
    let frames: [String: CGRect]
    let selectedEdgeId: String?
    let selectedNodeIDs: Set<String>
    let visibleOutputIDs: Set<String>
    let visibleInputIDs: Set<String>
    let frozenOutputPoints: [String: CGPoint]
    let frozenInputPoints: [String: CGPoint]
    let portMotions: CanvasPortMotions
    let zoom: CGFloat
    let isFlowing: (CanvasEdge) -> Bool
    let roleOptions: (CanvasEdge) -> [CanvasEdgeRole]
    let onSelect: (String) -> Void
    let onSetRole: (String, CanvasEdgeRole) -> Void
    let onDisconnect: (String) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(edges) { edge in
                if let from = frames[edge.fromNodeId], let to = frames[edge.toNodeId] {
                    CanvasEdgeShapeView(
                        edge: edge, fromRect: from, toRect: to,
                        isSelected: edge.id == selectedEdgeId,
                        endpointSelected: selectedNodeIDs.contains(edge.fromNodeId) || selectedNodeIDs.contains(edge.toNodeId),
                        isFlowing: isFlowing(edge), zoom: zoom,
                        outputVisible: visibleOutputIDs.contains(edge.fromNodeId),
                        inputVisible: visibleInputIDs.contains(edge.toNodeId),
                        sourceFrozen: frozenOutputPoints[edge.fromNodeId],
                        targetFrozen: frozenInputPoints[edge.toNodeId],
                        fromMotion: portMotions.motion(nodeID: edge.fromNodeId, output: true),
                        toMotion: portMotions.motion(nodeID: edge.toNodeId, output: false),
                        roleOptions: roleOptions(edge),
                        onSelect: { onSelect(edge.id) },
                        onSetRole: { onSetRole(edge.id, $0) },
                        onDisconnect: { onDisconnect(edge.id) })
                }
            }
        }
    }
}

private struct CanvasEdgeShapeView: View {
    let edge: CanvasEdge
    let fromRect: CGRect
    let toRect: CGRect
    let isSelected: Bool
    let endpointSelected: Bool
    let isFlowing: Bool
    let zoom: CGFloat
    let outputVisible: Bool
    let inputVisible: Bool
    let sourceFrozen: CGPoint?
    let targetFrozen: CGPoint?
    @ObservedObject var fromMotion: CanvasPortMotion
    @ObservedObject var toMotion: CanvasPortMotion
    let roleOptions: [CanvasEdgeRole]
    let onSelect: () -> Void
    let onSetRole: (CanvasEdgeRole) -> Void
    let onDisconnect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let sourceOffset = fromMotion.presentationOffset(output: true)
        let targetOffset = toMotion.presentationOffset(output: false)
        let start = sourceFrozen ?? CGPoint(x: fromRect.maxX + (outputVisible ? CanvasSkin.portOffset + sourceOffset.x : 0),
                            y: fromRect.midY + (outputVisible ? sourceOffset.y : 0))
        let end = targetFrozen ?? CGPoint(x: toRect.minX + (inputVisible ? -CanvasSkin.portOffset + targetOffset.x : 0),
                          y: toRect.midY + (inputVisible ? targetOffset.y : 0))
        let c = CanvasEdgeGeometry.controlPoints(start: start, end: end, outSide: .right, inSide: .left,
                                                 coordinateScale: zoom)
        let curve = CanvasEdgeCurve(start: start, c1: c.0, c2: c.1, end: end)
        let active = isSelected || endpointSelected
        let ink = active ? Color.white.opacity(isSelected ? 1 : 0.565) : CanvasSkin.edgeInk
        let width = 2.5 * zoom
        let band = CanvasEdgeHitBand(start: start, c1: c.0, c2: c.1, end: end, width: 20 * zoom)
        ZStack(alignment: .topLeading) {
            curve.stroke(ink, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .allowsHitTesting(false)
            if isFlowing && endpointSelected && !reduceMotion {
                CanvasFlowStroke(start: start, c1: c.0, c2: c.1, end: end, width: width, active: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            CanvasEdgeArrow(start: start, c1: c.0, c2: c.1, end: end, size: 8 * zoom)
                .fill(ink).allowsHitTesting(false)
            if let badge = edge.role.badgeText {
                Text(badge).font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(CanvasSkin.chromeInk)
                    .padding(.horizontal, 6).padding(.vertical, 2.5)
                    .background(Capsule().fill(CanvasSkin.chromeFill))
                    .position(CanvasEdgeGeometry.badgeAnchor(start: start, c1: c.0, c2: c.1, end: end))
                    .allowsHitTesting(false)
            }
            band.fill(Color.white.opacity(0.001)).contentShape(band)
                .onTapGesture(perform: onSelect)
                .contextMenu {
                    ForEach(roleOptions, id: \.self) { role in
                        Button { onSelect(); onSetRole(role) } label: {
                            Label(role.displayName, systemImage: edge.role == role ? "checkmark" : role.symbolName)
                        }
                    }
                    Divider()
                    Button(role: .destructive) { onSelect(); onDisconnect() } label: {
                        Label("断开连接", systemImage: "scissors")
                    }
                }
        }
    }
}

/// Padded user-space gradient allows stops outside [0,1] without clipping the
/// original -0.5/-0.3/-0.1 → 1/1.2/1.4 animation to CAGradientLayer's bounds.
private struct CanvasFlowStroke: NSViewRepresentable {
    let start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint
    let width: CGFloat
    let active: Bool

    func makeNSView(context: Context) -> FlowView { FlowView() }
    func updateNSView(_ view: FlowView, context: Context) {
        view.configure(start: start, c1: c1, c2: c2, end: end, width: width, active: active)
    }
    final class FlowView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        private let gradient = CAGradientLayer()
        private let maskLayer = CAShapeLayer()
        private var source = CGPoint.zero, destination = CGPoint.zero
        private var requested = false
        private var notifications: [NSObjectProtocol] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            gradient.colors = [
                NSColor(calibratedRed: 82/255, green: 82/255, blue: 91/255, alpha: 0).cgColor,
                NSColor.white.cgColor,
                NSColor(calibratedRed: 82/255, green: 82/255, blue: 91/255, alpha: 0).cgColor
            ]
            gradient.locations = [0, 0.1, 0.2]
            maskLayer.fillColor = nil
            maskLayer.strokeColor = NSColor.white.cgColor
            maskLayer.lineCap = .round
            gradient.mask = maskLayer
            layer?.addSublayer(gradient)
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in self?.updateClock()
                })
            }
        }
        required init?(coder: NSCoder) { nil }
        deinit { notifications.forEach(NotificationCenter.default.removeObserver) }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateClock() }
        override func layout() { super.layout(); updateGeometry(); updateClock() }

        func configure(start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint, width: CGFloat, active: Bool) {
            source = start; destination = end; requested = active
            let path = CGMutablePath()
            path.move(to: start); path.addCurve(to: end, control1: c1, control2: c2)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            maskLayer.path = path; maskLayer.lineWidth = width
            updateGeometry()
            CATransaction.commit()
            updateClock()
        }
        private func updateGeometry() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            gradient.frame = bounds; maskLayer.frame = bounds
            let dx = destination.x - source.x, dy = destination.y - source.y
            gradient.startPoint = CGPoint(x: (source.x - dx * 0.5) / bounds.width,
                                          y: (source.y - dy * 0.5) / bounds.height)
            gradient.endPoint = CGPoint(x: (source.x + dx * 1.5) / bounds.width,
                                        y: (source.y + dy * 1.5) / bounds.height)
            CATransaction.commit()
        }
        private func updateClock() {
            let pathVisible = maskLayer.path.map {
                $0.boundingBoxOfPath.insetBy(dx: -maskLayer.lineWidth, dy: -maskLayer.lineWidth).intersects(bounds)
            } ?? false
            let enabled = requested && pathVisible && window?.isKeyWindow == true
                && window?.isMiniaturized == false && !NSApp.isHidden
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_GROUP_REPLICA_PROBE"] == "1", requested {
                NSLog("[FlowProbe] bounds=%@ path=%@ key=%@ visible=%@ hidden=%@ enabled=%@",
                      NSStringFromRect(bounds), NSStringFromRect(maskLayer.path?.boundingBoxOfPath ?? .zero),
                      String(window?.isKeyWindow == true), String(pathVisible), String(NSApp.isHidden), String(enabled))
            }
            #endif
            gradient.isHidden = !enabled
            if enabled {
                guard gradient.animation(forKey: "flow") == nil else { return }
                let animation = CABasicAnimation(keyPath: "locations")
                animation.fromValue = [0, 0.1, 0.2]
                animation.toValue = [0.75, 0.85, 0.95]
                animation.duration = 2
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                gradient.add(animation, forKey: "flow")
            } else {
                gradient.removeAnimation(forKey: "flow")
            }
        }
    }
}

struct CanvasEdgeCurve: Shape {
    let start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start); path.addCurve(to: end, control1: c1, control2: c2)
        return path
    }
}

struct CanvasEdgeArrow: Shape {
    let start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint
    let size: CGFloat
    func path(in rect: CGRect) -> Path {
        let arrow = CanvasEdgeGeometry.arrowHead(start: start, c1: c1, c2: c2, end: end, size: size)
        var p = Path()
        p.move(to: arrow.tip); p.addLine(to: arrow.left); p.addLine(to: arrow.right); p.closeSubpath()
        return p
    }
}

struct CanvasEdgeHitBand: Shape {
    let start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint
    var width: CGFloat = 20
    func path(in rect: CGRect) -> Path {
        CanvasEdgeCurve(start: start, c1: c1, c2: c2, end: end).path(in: rect)
            .strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

struct CanvasLinkDragPreview: View {
    let start: CGPoint
    let cursor: CGPoint
    let hasTarget: Bool
    var zoom: CGFloat = 1
    var fromInput = false
    var body: some View {
        let c = CanvasEdgeGeometry.controlPoints(start: start, end: cursor,
                                                 outSide: fromInput ? .left : .right,
                                                 inSide: fromInput ? .right : .left,
                                                 coordinateScale: zoom)
        CanvasEdgeCurve(start: start, c1: c.0, c2: c.1, end: cursor)
            .stroke(hasTarget ? CanvasSkin.edgeInkActive : CanvasSkin.edgeInk,
                    style: StrokeStyle(lineWidth: 2.5 * zoom, lineCap: .round))
            .allowsHitTesting(false)
    }
}

struct CanvasMovingLinkPreview: View {
    @ObservedObject var motion: CanvasPortMotion
    let start: CGPoint
    let targetHome: CGPoint
    let zoom: CGFloat
    let fromInput: Bool
    var body: some View {
        let offset = motion.presentationOffset(output: fromInput)
        CanvasLinkDragPreview(start: start,
                              cursor: CGPoint(x: targetHome.x + offset.x, y: targetHome.y + offset.y),
                              hasTarget: true, zoom: zoom, fromInput: fromInput)
    }
}

struct CanvasPort: View {
    let isActive: Bool
    let isConnected: Bool
    var body: some View {
        ZStack {
            Circle().fill(CanvasSkin.void)
            Circle().stroke(isActive ? CanvasSkin.portStrokeActive : CanvasSkin.portStroke,
                            lineWidth: CanvasSkin.portStrokeWidth)
            if isConnected {
                Circle().fill(isActive ? CanvasSkin.portStrokeActive : CanvasSkin.portStroke)
                    .frame(width: CanvasSkin.portDiameter * 0.3, height: CanvasSkin.portDiameter * 0.3)
            } else {
                Image(systemName: "plus").font(.system(size: CanvasSkin.portGlyphSize, weight: .medium))
                    .foregroundColor(isActive ? CanvasSkin.portStrokeActive : CanvasSkin.portStroke)
            }
        }
        .frame(width: CanvasSkin.portDiameter, height: CanvasSkin.portDiameter)
        .frame(width: 32, height: 32).contentShape(Circle()).help("点击新建，或拖动连到另一个节点")
    }
}
