import SwiftUI
import ClipSlotsKit

extension Notification.Name {
    static let canvasPileGalleryCloseRequested = Notification.Name("CanvasPileGalleryCloseRequested")
}

@MainActor enum CanvasPileMotionAccessibility {
    static func shouldReduceMotion(_ system: Bool) -> Bool {
        #if DEBUG
        return system || CanvasPileGalleryProbeBridge.forceReduceMotion
        #else
        return system
        #endif
    }
}

/// Owns its viewport and gesture lifetime; never changes the canvas camera.
struct CanvasPileGallery: View {
    let pile: CanvasPile
    let nodes: [CanvasNode]
    let text: (CanvasNode) -> String
    let media: (CanvasNode) -> SlotContent.SlotAttachment?
    let sourceFrame: CGRect
    let canvasZoom: CGFloat
    let sourceExpansion: CGFloat
    let close: (CGFloat) -> Void
    let unstack: () -> Void
    let promote: (String) -> Void
    let extract: (String, CGPoint) -> Void
    let preview: (CanvasNode) -> Void

    private enum Completion {
        case close, unstack, handoff(CanvasPileGallerySession.Handoff, CGPoint)
    }
    @State private var session = CanvasPileGallerySession()
    @State private var pan = CGSize.zero
    @State private var scale = CanvasPileGeometry.galleryInitialZoom
    @State private var spread = false
    @State private var sourcePoses: [String: CanvasPileMemberPose] = [:]
    @State private var snapshotFrame = CGRect.zero
    @State private var snapshotExpansion: CGFloat = 1
    @State private var localOrigin = CGPoint.zero
    @State private var dragStartFrame = CGRect.zero
    @State private var pointer = CGPoint.zero
    @State private var grab = CGPoint.zero
    @State private var carrying = false
    @State private var overReturnTarget = false
    @State private var handoffPose: CanvasPileMemberPose?
    @State private var completionTask: Task<Void, Never>?
    @GestureState private var panPreview = CGSize.zero
    @GestureState private var dragActive = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { CanvasPileMotionAccessibility.shouldReduceMotion(systemReduceMotion) }

    private var chromeVisible: Bool {
        spread && !session.isCollapsed && session.phase != .closing
    }
    private var pileMembers: [CanvasNode] {
        if session.phase == .returningToPile, let id = session.memberID {
            return nodes.filter { $0.id != id } + nodes.filter { $0.id == id }
        }
        return session.isCollapsed ? nodes.filter { $0.id != session.memberID } : nodes
    }
    private var expansion: CGFloat {
        if session.phase == .returningToPile { return CanvasPileGalleryMotion.interactiveExpansion }
        if session.isCollapsed {
            return overReturnTarget ? CanvasPileGalleryMotion.returnExpansion : CanvasPileGalleryMotion.compactExpansion
        }
        return sourcePoses.isEmpty ? sourceExpansion : snapshotExpansion
    }

    var body: some View {
        GeometryReader { proxy in
            let frames = CanvasPileGeometry.galleryFrames(nodes)
            let origin = proxy.frame(in: .named(CanvasWorkspaceView.spaceName)).origin
            let initialFrame = sourceFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            let folded = CanvasPileGalleryMotion.pilePoses(pileMembers,
                screenFrame: sourcePoses.isEmpty ? initialFrame : snapshotFrame,
                                                           zoom: canvasZoom, expansion: expansion)
            ZStack {
                backdrop
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    if let frame = frames[node.id] {
                        member(node, index: index, gridFrame: frame, folded: folded, viewport: proxy.size)
                    }
                }
                chrome
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(CanvasPileGalleryInput { event, point in scroll(event, at: point, viewport: proxy.size) })
            .onAppear {
                localOrigin = proxy.frame(in: .named(CanvasWorkspaceView.spaceName)).origin
                snapshotFrame = sourceFrame.offsetBy(dx: -localOrigin.x, dy: -localOrigin.y)
                snapshotExpansion = sourceExpansion
                sourcePoses = CanvasPileGalleryMotion.pilePoses(nodes, screenFrame: snapshotFrame,
                    zoom: canvasZoom, expansion: sourceExpansion)
                #if DEBUG
                publishProbe(frames: frames, viewport: proxy.size)
                #endif
                armCompletion(seconds: CanvasPileGalleryMotion.completionDuration(memberCount: nodes.count),
                              action: nil, openOnNextTurn: true)
            }
            .onDisappear {
                completionTask?.cancel()
                completionTask = nil
                #if DEBUG
                CanvasPileGalleryProbeBridge.sessions.removeValue(forKey: pile.id)
                CanvasPileGalleryProbeBridge.sources.removeValue(forKey: pile.id)
                CanvasPileGalleryProbeBridge.grids.removeValue(forKey: pile.id)
                CanvasPileGalleryProbeBridge.returnTargets.removeValue(forKey: pile.id)
                CanvasPileGalleryProbeBridge.viewports.removeValue(forKey: pile.id)
                CanvasPileGalleryProbeBridge.carried.removeValue(forKey: pile.id)
                CanvasPileGalleryProbeBridge.expansions.removeValue(forKey: pile.id)
                CanvasPileGalleryProbeBridge.reducedMotion.removeValue(forKey: pile.id)
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: .canvasPileGalleryCloseRequested)) { notice in
                if notice.object as? String == pile.id { requestDismiss() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                cancelDrag()
            }
            .onChange(of: dragActive) { active in
                if !active {
                    // SwiftUI resets GestureState on cancellation as well as mouse-up.
                    // onEnded settles synchronously; this only handles the missing end.
                    DispatchQueue.main.async { if !dragActive { cancelDrag() } }
                }
            }
            .onChange(of: nodes.map(\.id)) { ids in
                if let id = session.memberID, !ids.contains(id) {
                    completionTask?.cancel()
                    close(snapshotExpansion)
                }
            }
            .onExitCommand { requestDismiss() }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("pile-gallery-\(session.phase.rawValue)")
            #if DEBUG
            .onChange(of: session) { _ in publishProbe(frames: frames, viewport: proxy.size) }
            .onChange(of: overReturnTarget) { _ in publishProbe(frames: frames, viewport: proxy.size) }
            .onChange(of: pointer) { _ in publishProbe(frames: frames, viewport: proxy.size) }
            .onChange(of: carrying) { _ in publishProbe(frames: frames, viewport: proxy.size) }
            .onChange(of: handoffPose) { _ in publishProbe(frames: frames, viewport: proxy.size) }
            .onChange(of: systemReduceMotion) { _ in publishProbe(frames: frames, viewport: proxy.size) }
            #endif
        }
    }

    private var backdrop: some View {
        CanvasSkin.void.opacity(chromeVisible ? 0.94 : 0)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1,
                duration: session.isCollapsed ? 0.18 : 0.22)
                .delay(session.phase == .opening ? 0.07 : session.phase == .closing ? 0.28 : 0),
                value: chromeVisible)
            .onTapGesture { requestDismiss() }
            .gesture(DragGesture(minimumDistance: 3)
                .updating($panPreview) { value, state, _ in
                    if session.phase == .open { state = value.translation }
                }
                .onEnded { value in
                    guard session.phase == .open else { return }
                    pan.width += value.translation.width; pan.height += value.translation.height
                })
    }

    private func member(_ node: CanvasNode, index: Int, gridFrame: CGRect,
                        folded: [String: CanvasPileMemberPose], viewport: CGSize) -> some View {
        let grid = gridPose(gridFrame, viewport: viewport)
        let isDragged = session.memberID == node.id
        let pose = isDragged ? draggedPose(node)
            : spread && !session.isCollapsed ? grid
            : session.phase == .opening ? sourcePoses[node.id] ?? folded[node.id] ?? grid
            : folded[node.id] ?? sourcePoses[node.id] ?? grid
        // Native culling includes the label/action bands; in-flight cards are
        // retained so a viewport change cannot destroy their gesture or animation.
        let visible = session.phase != .open || isDragged
            || pose.rotatedBounds.insetBy(dx: -128, dy: -128).intersects(CGRect(origin: .zero, size: viewport))
        return CanvasPileGalleryMember(size: CanvasPileGeometry.displaySize(node), pose: pose,
            name: memberName(node), showLabel: chromeVisible && !isDragged, visible: visible,
            phase: session.phase, index: index, dragging: isDragged, carrying: carrying,
            reduceMotion: reduceMotion, content: { galleryCard(node) }, actions: {
                HStack(spacing: 12) {
                    Button("置顶") { if session.phase == .open { promote(node.id) } }
                        .accessibilityIdentifier("pile-promote-\(node.id)")
                    Button("抽出") { extractFromButton(node, grid: grid, viewport: viewport) }
                        .accessibilityIdentifier("pile-extract-\(node.id)")
                    if media(node) != nil {
                        Button("预览") { if session.phase == .open { preview(node) } }
                            .accessibilityIdentifier("pile-preview-\(node.id)")
                    }
                }.font(.system(size: 11)).foregroundColor(CanvasSkin.ink).buttonStyle(.plain)
                    .disabled(session.phase != .open)
            })
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(CanvasWorkspaceView.spaceName))
                .updating($dragActive) { _, state, _ in state = true }
                .onChanged { value in dragChanged(value, node: node, grid: grid) }
                .onEnded { value in dragEnded(value, node: node, grid: grid) })
            .allowsHitTesting(visible && (session.phase == .open || (isDragged && session.isDragging)))
    }

    private func gridPose(_ frame: CGRect, viewport: CGSize) -> CanvasPileMemberPose {
        CanvasPileGalleryMotion.gridPose(frame, viewport: viewport,
            pan: CGSize(width: pan.width + panPreview.width, height: pan.height + panPreview.height), zoom: scale)
    }

    private func draggedPose(_ node: CanvasNode) -> CanvasPileMemberPose {
        if let handoffPose { return handoffPose }
        let size = carrying ? CanvasPileGeometry.displaySize(node).applying(canvasZoom) : dragStartFrame.size
        return CanvasPileMemberPose(frame: CanvasPileGalleryMotion.carriedFrame(size: size, pointer: pointer, grab: grab),
                                    zIndex: 30)
    }

    private func dragChanged(_ value: DragGesture.Value, node: CanvasNode, grid: CanvasPileMemberPose) {
        if session.phase == .open {
            guard session.beginDrag(node.id) else { return }
            completionTask?.cancel()
            dragStartFrame = grid.frame
            let start = localPoint(value.startLocation)
            grab = CanvasPileGalleryMotion.grabFraction(pointer: start, frame: grid.frame)
            pointer = localPoint(value.location)
            carrying = false; handoffPose = nil
            DispatchQueue.main.async {
                if session.isDragging && session.memberID == node.id { carrying = true }
            }
        }
        guard session.isDragging, session.memberID == node.id else { return }
        pointer = localPoint(value.location)
        session.updateDrag(value.translation)
        if session.isCollapsed {
            overReturnTarget = CanvasPileGalleryMotion.returnBounds(nodes.filter { $0.id != node.id },
                screenFrame: snapshotFrame, zoom: canvasZoom).contains(pointer)
        }
    }

    private func dragEnded(_ value: DragGesture.Value, node: CanvasNode, grid: CanvasPileMemberPose) {
        guard session.isDragging, session.memberID == node.id else { return }
        dragChanged(value, node: node, grid: grid)
        let carried = draggedPose(node)
        guard let handoff = session.finishDrag(overReturnTarget: overReturnTarget) else { return }
        settle(handoff, carried: carried, cell: grid)
    }

    private func cancelDrag() {
        guard session.isDragging, let id = session.memberID,
              let node = nodes.first(where: { $0.id == id }) else { return }
        // pan/zoom input is frozen during a drag; use its original cell exactly.
        let grid = CanvasPileMemberPose(frame: dragStartFrame, zIndex: 1)
        let carried = draggedPose(node)
        guard let handoff = session.cancelDrag() else { return }
        settle(handoff, carried: carried, cell: grid)
    }

    private func settle(_ handoff: CanvasPileGallerySession.Handoff, carried: CanvasPileMemberPose,
                        cell: CanvasPileMemberPose) {
        overReturnTarget = false
        let target: CanvasPileMemberPose
        let duration: Double
        switch handoff {
        case .cell:
            target = cell; duration = CanvasPileGalleryMotion.pickupDuration
        case .pile(let id):
            let reordered = nodes.filter { $0.id != id } + nodes.filter { $0.id == id }
            target = CanvasPileGalleryMotion.pilePoses(reordered, screenFrame: snapshotFrame,
                zoom: canvasZoom, expansion: CanvasPileGalleryMotion.interactiveExpansion)[id] ?? carried
            duration = CanvasPileGalleryMotion.collapseDuration
        case .canvas(let id):
            // Own-native deferred mutation: the original node is revealed only
            // after the overlay reaches its original render size.
            let node = nodes.first { $0.id == id }
            let size = CGSize(width: (node?.width ?? 1) * canvasZoom, height: (node?.height ?? 1) * canvasZoom)
            target = CanvasPileMemberPose(frame: CGRect(x: carried.frame.midX - size.width / 2,
                y: carried.frame.midY - size.height / 2, width: size.width, height: size.height), zIndex: 30)
            duration = CanvasPileGalleryMotion.landingDuration
        }
        handoffPose = target
        let screenCenter = CGPoint(x: target.frame.midX + localOrigin.x, y: target.frame.midY + localOrigin.y)
        // Closing other members may still be in flight when the pointer is released.
        armCompletion(seconds: max(duration, session.isCollapsed ? CanvasPileGalleryMotion.collapseDuration : 0) + 0.02,
                      action: .handoff(handoff, screenCenter))
    }

    private func extractFromButton(_ node: CanvasNode, grid: CanvasPileMemberPose, viewport: CGSize) {
        guard session.beginDrag(node.id) else { return }
        dragStartFrame = grid.frame; grab = CGPoint(x: 0.5, y: 0.5)
        pointer = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        carrying = true
        session.updateDrag(CGSize(width: CanvasPileGalleryMotion.collapseThreshold, height: 0))
        let carried = draggedPose(node)
        if let handoff = session.finishDrag(overReturnTarget: false) {
            settle(handoff, carried: carried, cell: grid)
        }
    }

    private func requestDismiss(unstackAfterClose: Bool = false) {
        if session.isDragging { cancelDrag(); return }
        guard session.requestClose() else { return }
        spread = false
        armCompletion(seconds: CanvasPileGalleryMotion.completionDuration(memberCount: nodes.count),
                      action: unstackAfterClose ? .unstack : .close)
    }

    private func armCompletion(seconds: Double, action: Completion?, openOnNextTurn: Bool = false) {
        completionTask?.cancel()
        let revision = session.revision
        // Without motion there is no presentation transition to wait for. In
        // particular, an opening gallery must enable its controls in this turn,
        // even if the main actor's task queue is busy.
        if reduceMotion {
            completionTask = nil
            if openOnNextTurn { spread = true }
            finishCompletion(revision: revision, action: action)
            return
        }
        completionTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, session.revision == revision else { return }
            if openOnNextTurn { spread = true }
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            finishCompletion(revision: revision, action: action)
        }
    }

    private func finishCompletion(revision: Int, action: Completion?) {
        guard session.complete(revision: revision) else { return }
        handoffPose = nil; carrying = false; overReturnTarget = false
        switch action {
        case .close: close(snapshotExpansion)
        case .unstack: unstack()
        case .handoff(.pile(let id), _): promote(id); close(CanvasPileGalleryMotion.interactiveExpansion)
        case .handoff(.canvas(let id), let point): extract(id, point)
        case .handoff(.cell, _), .none: break
        }
    }

    private func localPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - localOrigin.x, y: point.y - localOrigin.y)
    }

    private func memberName(_ node: CanvasNode) -> String {
        let first = text(node).split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first, !first.isEmpty { return first }
        return media(node)?.name ?? node.kind.displayName
    }

    @ViewBuilder private func galleryCard(_ node: CanvasNode) -> some View {
        if let attachment = media(node) {
            CanvasAttachmentPreviewImage(attachment: attachment, maxPixel: 640, contentMode: .fit)
                .background(CanvasSkin.cardEmptyFill)
        } else {
            Text(text(node).isEmpty ? node.kind.displayName : text(node))
                .font(.system(size: 14)).foregroundColor(CanvasSkin.ink)
                .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(CanvasSkin.cardEmptyFill)
        }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Text("堆叠 · \(nodes.count) 个成员").font(.system(size: 13, weight: .medium))
                Spacer()
                Button("展开堆叠") { requestDismiss(unstackAfterClose: true) }
                    .accessibilityIdentifier("gallery-unstack")
                Button { requestDismiss() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .accessibilityIdentifier("gallery-close")
            }.foregroundColor(CanvasSkin.ink).buttonStyle(.plain).padding(22)
            Spacer()
            HStack(spacing: 16) {
                Button { scale = max(0.15, scale / 1.2) } label: { Image(systemName: "minus") }
                Text("\(Int(scale * 100))%").monospacedDigit()
                Button { scale = min(2, scale * 1.2) } label: { Image(systemName: "plus") }
            }.font(.system(size: 12)).foregroundColor(CanvasSkin.chromeInk).buttonStyle(.plain)
                .padding(12).background(CanvasSkin.chromeFill, in: Capsule()).padding(.bottom, 20)
        }
        .opacity(chromeVisible ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16).delay(session.phase == .opening ? 0.32 : 0),
                   value: chromeVisible)
        .allowsHitTesting(session.phase == .open)
    }

    private func scroll(_ event: NSEvent, at point: CGPoint, viewport: CGSize) {
        guard session.phase == .open else { return }
        let zooming = event.type == .magnify || event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.control)
        if zooming {
            let old = scale
            let next = min(max(old * (event.type == .magnify ? 1 + event.magnification
                : CGFloat(pow(1.01, Double(event.scrollingDeltaY)))), 0.15), 2)
            let anchor = CGPoint(x: point.x - viewport.width / 2, y: point.y - viewport.height / 2)
            pan = CGSize(width: anchor.x - (anchor.x - pan.width) * next / old,
                         height: anchor.y - (anchor.y - pan.height) * next / old)
            scale = next
        } else {
            pan.width += event.scrollingDeltaX; pan.height += event.scrollingDeltaY
        }
    }

    #if DEBUG
    private func publishProbe(frames: [String: CGRect], viewport: CGSize) {
        CanvasPileGalleryProbeBridge.sessions[pile.id] = session
        CanvasPileGalleryProbeBridge.sources[pile.id] = sourcePoses
        CanvasPileGalleryProbeBridge.grids[pile.id] = frames.mapValues { gridPose($0, viewport: viewport) }
        CanvasPileGalleryProbeBridge.returnTargets[pile.id] = overReturnTarget
        CanvasPileGalleryProbeBridge.viewports[pile.id] = CGRect(origin: localOrigin, size: viewport)
        CanvasPileGalleryProbeBridge.expansions[pile.id] = expansion
        CanvasPileGalleryProbeBridge.reducedMotion[pile.id] = reduceMotion
        CanvasPileGalleryProbeBridge.carried[pile.id] = nodes.first { $0.id == session.memberID }.map { draggedPose($0) }
    }
    #endif
}

private extension CGSize {
    func applying(_ scale: CGFloat) -> CGSize { CGSize(width: width * scale, height: height * scale) }
}

private struct CanvasPileGalleryMember<Content: View, Actions: View>: View {
    let size: CGSize
    let pose: CanvasPileMemberPose
    let name: String
    let showLabel: Bool
    let visible: Bool
    let phase: CanvasPileGallerySession.Phase
    let index: Int
    let dragging: Bool
    let carrying: Bool
    let reduceMotion: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    private var movement: Animation? {
        guard !reduceMotion else { return nil }
        if dragging && [.dragging, .collapsed].contains(phase) { return nil }
        let duration = phase == .landingOnCanvas ? CanvasPileGalleryMotion.landingDuration
            : [.collapsed, .returningToPile].contains(phase) ? CanvasPileGalleryMotion.collapseDuration
            : phase == .returningToCell ? CanvasPileGalleryMotion.pickupDuration
            : [.opening, .closing].contains(phase) ? CanvasPileGeometry.galleryDuration : CanvasPileGeometry.reflowDuration
        let delay = [.opening, .closing].contains(phase) ? CanvasPileGalleryMotion.stagger(index: index) : 0
        return .timingCurve(0.65, 0, 0.35, 1, duration: duration).delay(delay)
    }

    var body: some View {
        content().frame(width: size.width, height: size.height)
            .overlay(Color.black.opacity(pose.shade)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.26), value: pose.shade))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                Text(name).font(.system(size: 12, weight: .medium)).foregroundColor(CanvasSkin.ink)
                    .lineLimit(1).frame(width: size.width, height: 40, alignment: .bottomLeading)
                    .padding(.bottom, 8).offset(y: -40)
                    .opacity(showLabel ? 1 : 0).allowsHitTesting(false)
                    .animation(labelAnimation, value: showLabel)
            }
            .overlay(alignment: .bottomLeading) {
                actions().offset(y: 28).opacity(showLabel ? 1 : 0)
                    .allowsHitTesting(showLabel && phase == .open)
                    .animation(labelAnimation, value: showLabel)
            }
            .rotationEffect(.degrees(pose.rotation))
            .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1,
                duration: CanvasPileGalleryMotion.rotationDuration)
                .delay(phase == .closing ? CanvasPileGalleryMotion.closingRotationDelay : 0), value: pose.rotation)
            .scaleEffect(x: pose.frame.width / max(size.width, 1), y: pose.frame.height / max(size.height, 1))
            .position(x: pose.frame.midX, y: pose.frame.midY)
            .animation(movement, value: pose.frame)
            .animation(reduceMotion ? nil : .timingCurve(0.65, 0, 0.35, 1,
                duration: CanvasPileGalleryMotion.pickupDuration), value: carrying)
            .opacity(visible ? 1 : 0)
            .zIndex(Double(pose.zIndex))
    }

    private var labelAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: CanvasPileGalleryMotion.labelDuration)
            .delay(showLabel && phase == .opening ? CanvasPileGalleryMotion.labelDelay
                + CanvasPileGalleryMotion.stagger(index: index) : 0)
    }
}

private struct CanvasPileGalleryInput: NSViewRepresentable {
    let scroll: (NSEvent, CGPoint) -> Void
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.scroll = scroll }
    final class Anchor: NSView {
        var scroll: ((NSEvent, CGPoint) -> Void)?
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                self.scroll?(event, point)
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

#if DEBUG
@MainActor enum CanvasPileGalleryProbeBridge {
    static var forceReduceMotion: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CLIPSLOTS_PILE_REDUCE_MOTION"] == "1" && env["CLIPSLOTS_PILE_PROBE"] == "1"
            && Bundle.main.bundleIdentifier == "com.clipslots.app.canvas-v2174-test"
            && env["CLIPSLOTS_DATA_DIR"]?.hasPrefix("/tmp/clipslots-v2174-") == true
    }
    static var sessions: [String: CanvasPileGallerySession] = [:]
    static var sources: [String: [String: CanvasPileMemberPose]] = [:]
    static var grids: [String: [String: CanvasPileMemberPose]] = [:]
    static var returnTargets: [String: Bool] = [:]
    static var viewports: [String: CGRect] = [:]
    static var carried: [String: CanvasPileMemberPose] = [:]
    static var expansions: [String: CGFloat] = [:]
    static var reducedMotion: [String: Bool] = [:]
}
#endif
