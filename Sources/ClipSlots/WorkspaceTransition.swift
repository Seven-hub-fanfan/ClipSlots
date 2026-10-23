import AppKit
import SwiftUI
import QuartzCore

/// Only this small native layer animates while SwiftUI mounts the destination.
/// The outgoing workspace is removed normally, including its event monitors.
@MainActor
final class WorkspaceTransition: ObservableObject {
    weak var surface: WorkspaceLoadingView?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var isSwitching = false
    let preparation = CanvasEntryPreparation()
    let editorMounts = CanvasNodeMountQueue()
    let sections = CanvasNodeMountQueue()
    let sidebarMounts = CanvasNodeMountQueue()
    private(set) var pendingMode: WorkspaceMode?

    func switchTo(_ mode: WorkspaceMode, prepare: @escaping () async -> Bool,
                  commit: @escaping () -> Void) {
        guard mode.isSelectable else { return }
        task?.cancel()
        sections.admitNative(Array(sections.pendingIDs))
        sidebarMounts.admitNative(Array(sidebarMounts.pendingIDs))
        editorMounts.admitNative(Array(editorMounts.pendingIDs))
        let ticket = UUID()
        generation = ticket
        isSwitching = true
        pendingMode = mode
        surface?.show(title: mode == .canvas ? "正在准备画布" : "正在打开编辑区")
        task = Task { [weak self] in
            // Give the compositor the loading layer before any heavy mounting.
            await CanvasDisplayClock.shared.nextFrame()
            guard !Task.isCancelled, self?.generation == ticket else { return }
            WorkspaceMountTrace.mark("prepare:\(mode.rawValue)")
            let ready = await prepare()
            guard !Task.isCancelled, let self, self.generation == ticket else { return }
            if ready {
                await self.editorMounts.retire()
                await self.sidebarMounts.retire()
                await self.sections.retire()
                guard !Task.isCancelled, self.generation == ticket else { return }
            }
            sections.reset()
            if ready {
                sections.enroll(mode == .edit
                    ? ["0-title", "0-title-left", "0-title-search", "0-title-tools",
                       "1-actions", "2-footer"]
                    : ["0-canvas-nodes", "1-canvas-project", "2-canvas-actions", "3-canvas-navigation",
                       "4-canvas-toolbar", "5-canvas-library"])
            }
            if ready {
                if mode == .canvas { editorMounts.reset() }
                WorkspaceMountTrace.measure("commit:\(mode.rawValue)", commit)
            }
            await CanvasDisplayClock.shared.nextFrame()
            if ready {
                sections.update(ids: sections.pendingIDs.sorted())
                while !sections.pendingIDs.isEmpty && !Task.isCancelled {
                    await CanvasDisplayClock.shared.nextFrame()
                }
                sidebarMounts.update(ids: sidebarMounts.pendingIDs.sorted())
                while !sidebarMounts.pendingIDs.isEmpty && !Task.isCancelled {
                    await CanvasDisplayClock.shared.nextFrame()
                }
            }
            if mode == .edit && ready {
                editorMounts.update(ids: editorMounts.pendingIDs.sorted())
                while !editorMounts.pendingIDs.isEmpty && !Task.isCancelled {
                    await CanvasDisplayClock.shared.nextFrame()
                }
            } else if mode == .canvas && ready {
                while preparation.textSurfaces.isMounting && !Task.isCancelled {
                    await CanvasDisplayClock.shared.nextFrame()
                }
            }
            await CanvasDisplayClock.shared.nextFrame()
            guard !Task.isCancelled, self.generation == ticket else { return }
            self.surface?.hide()
            WorkspaceMountTrace.mark("ready:\(mode.rawValue)")
            self.isSwitching = false
            self.pendingMode = nil
            self.task = nil
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        editorMounts.admitNative(Array(editorMounts.pendingIDs))
        editorMounts.reset()
        sections.admitNative(Array(sections.pendingIDs))
        sidebarMounts.admitNative(Array(sidebarMounts.pendingIDs))
        isSwitching = false
        pendingMode = nil
        surface?.hide()
    }
}

struct WorkspaceLoadingSurface: NSViewRepresentable {
    let transition: WorkspaceTransition
    func makeNSView(context: Context) -> WorkspaceLoadingView {
        let view = WorkspaceLoadingView()
        transition.surface = view
        return view
    }
    func updateNSView(_ view: WorkspaceLoadingView, context: Context) {}
    static func dismantleNSView(_ view: WorkspaceLoadingView, coordinator: ()) {
        view.hide()
    }
}

final class WorkspaceLoadingView: NSView {
    private let symbol = CAShapeLayer()
    private let label = CATextLayer()
    private var active = false
    private var hideTicket = UUID()
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { active ? self : nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.opacity = 0
        layer?.addSublayer(symbol)
        layer?.addSublayer(label)
        label.alignmentMode = .center
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.fontSize = 12
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        symbol.lineWidth = 3
        symbol.lineCap = .round
        symbol.fillColor = nil
        setAccessibilityIdentifier("workspace-loading")
        setAccessibilityRole(.progressIndicator)
        colors()
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); colors() }
    private func colors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            symbol.strokeColor = NSColor.labelColor.cgColor
            label.foregroundColor = NSColor.secondaryLabelColor.cgColor
        }
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        symbol.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        symbol.position = CGPoint(x: bounds.midX, y: bounds.midY - 12)
        symbol.path = CGPath(ellipseIn: CGRect(x: 5, y: 5, width: 34, height: 34), transform: nil)
        symbol.strokeStart = 0.08; symbol.strokeEnd = 0.82
        label.frame = CGRect(x: max(0, bounds.midX - 130), y: bounds.midY + 25, width: 260, height: 24)
        CATransaction.commit()
    }
    func show(title: String) {
        // A workspace switch can arrive before the resize layout pass. Resolve the
        // full window bounds before exposing this opaque layer, including its top edge.
        window?.contentView?.layoutSubtreeIfNeeded()
        hideTicket = UUID()
        active = true
        label.string = title
        setAccessibilityLabel(title)
        layer?.removeAnimation(forKey: "visibility")
        layer?.opacity = 1
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let spin = CABasicAnimation(keyPath: "transform.rotation")
            spin.fromValue = 0; spin.toValue = 2 * Double.pi
            spin.duration = 1.4; spin.repeatCount = .infinity
            symbol.add(spin, forKey: "spin")
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.5; pulse.toValue = 1
            pulse.duration = 0.9; pulse.autoreverses = true; pulse.repeatCount = .infinity
            symbol.add(pulse, forKey: "pulse")
        }
    }
    func hide() {
        guard active else { return }
        active = false
        let ticket = UUID(); hideTicket = ticket
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer?.presentation()?.opacity ?? 1; fade.toValue = 0
        fade.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
        layer?.opacity = 0
        layer?.add(fade, forKey: "visibility")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.hideTicket == ticket else { return }
            self.symbol.removeAllAnimations()
        }
    }
}
