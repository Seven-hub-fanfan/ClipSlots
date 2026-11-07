import AppKit
import SwiftUI
import QuartzCore
import ImageIO
import ClipSlotsKit

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
    let navigation = WorkspaceNavigationState()
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
        navigation.requestedMode = mode
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
            self.navigation.requestedMode = nil
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
        navigation.requestedMode = nil
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
    struct Frames: @unchecked Sendable {
        let images: [CGImage]
        let times: [NSNumber]
        let duration: Double
    }
    let symbol = CALayer()
    let envelope = CALayer()
    private(set) var frames: Frames?
    private var preparation: Task<Frames?, Never>?
    private var preparationID = UUID()
    private var active = false
    private var generation = UUID()
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { active ? self : nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.opacity = 0
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(envelope)
        envelope.addSublayer(symbol)
        symbol.contentsGravity = .resizeAspect
        setAccessibilityIdentifier("workspace-loading")
        setAccessibilityRole(.progressIndicator)
        startPreparing()
    }
    required init?(coder: NSCoder) { nil }
    private func startPreparing() {
        guard frames == nil, preparation == nil else { return }
        preparationID = UUID()
        let url = AgentBackgroundResources.pageURL?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TapNowMotion/workspace-loading.webp")
        preparation = Task.detached(priority: .userInitiated) {
            guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            var images: [CGImage] = [], durations: [Double] = []
            for index in 0..<CGImageSourceGetCount(source) {
                guard !Task.isCancelled,
                      let image = CGImageSourceCreateImageAtIndex(source, index,
                        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                      let webp = properties["{WebP}"] as? [String: Any],
                      let delay = (webp["UnclampedDelayTime"] ?? webp["DelayTime"]) as? NSNumber else { return nil }
                images.append(image); durations.append(max(0.01, delay.doubleValue))
            }
            guard !images.isEmpty else { return nil }
            let total = durations.reduce(0, +)
            var elapsed = 0.0
            let times = durations.map { duration -> NSNumber in
                defer { elapsed += duration }
                return NSNumber(value: elapsed / total)
            }
            return Frames(images: images, times: times, duration: total)
        }
    }
    func prepareAnimation() async {
        startPreparing()
        guard let preparation else { return }
        let ticket = preparationID
        let result = await preparation.value
        guard preparationID == ticket, !preparation.isCancelled else { return }
        frames = result
        self.preparation = nil
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        envelope.bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        envelope.position = CGPoint(x: bounds.midX, y: bounds.midY)
        symbol.frame = envelope.bounds
        symbol.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
    func show(title: String) {
        window?.contentView?.layoutSubtreeIfNeeded()
        generation = UUID()
        let ticket = generation
        active = true
        setAccessibilityLabel(title)
        let opacity = layer?.presentation()?.opacity ?? layer?.opacity ?? 0
        layer?.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.opacity = 1
        envelope.opacity = 1
        envelope.removeAllAnimations()
        CATransaction.commit()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduced {
            fade(layer, from: opacity, to: 1, duration: 1)
            fade(envelope, from: 0, to: 1, duration: 0.3, delay: 0.1)
            let reveal = CABasicAnimation(keyPath: "transform.scale")
            reveal.fromValue = 0.95; reveal.toValue = 1
            reveal.duration = 0.3; reveal.beginTime = CACurrentMediaTime() + 0.1
            reveal.fillMode = .backwards
            reveal.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
            envelope.add(reveal, forKey: "reveal")
        }
        if frames != nil { play(reduced: reduced) }
        else {
            Task { [weak self] in
                guard let self else { return }
                await self.prepareAnimation()
                guard self.active, self.generation == ticket else { return }
                self.play(reduced: reduced)
            }
        }
    }
    private func play(reduced: Bool) {
        guard let frames, let first = frames.images.first else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        symbol.removeAllAnimations()
        symbol.contents = first
        CATransaction.commit()
        guard !reduced else { return }
        let morph = CAKeyframeAnimation(keyPath: "contents")
        morph.values = frames.images + [first]
        morph.keyTimes = frames.times + [1]
        morph.calculationMode = .discrete
        morph.duration = frames.duration; morph.repeatCount = .infinity
        symbol.add(morph, forKey: "morph")
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [0.95, 1.05, 0.95]; pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = 2; pulse.repeatCount = .infinity
        pulse.timingFunctions = Array(repeating: CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1), count: 2)
        symbol.add(pulse, forKey: "pulse")
    }
    private func fade(_ target: CALayer?, from: Float, to: Float, duration: Double, delay: Double = 0) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from; animation.toValue = to
        animation.duration = duration; animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
        target?.add(animation, forKey: "visibility")
    }
    func hide() {
        guard active else { return }
        active = false
        generation = UUID()
        let ticket = generation
        let opacity = layer?.presentation()?.opacity ?? 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.opacity = 0
        envelope.opacity = 0
        CATransaction.commit()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            releaseAnimation()
        } else {
            fade(layer, from: opacity, to: 0, duration: 1)
            fade(envelope, from: envelope.presentation()?.opacity ?? 1, to: 0, duration: 0.8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.generation == ticket, !self.active else { return }
                self.releaseAnimation()
            }
        }
    }
    private func releaseAnimation() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.removeAllAnimations(); envelope.removeAllAnimations(); symbol.removeAllAnimations()
        symbol.contents = nil; frames = nil
        CATransaction.commit()
        preparationID = UUID()
        preparation?.cancel(); preparation = nil
    }
}
