import AppKit
import SwiftUI
import QuartzCore
import ImageIO
import CoreImage
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
        let lightImages: [CGImage]
        let times: [NSNumber]
        let duration: Double
    }
    private struct Poster {
        let dark: CGImage
        let light: CGImage
    }
    private static var animationURL: URL? {
        AgentBackgroundResources.pageURL?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TapNowMotion/workspace-loading.webp")
    }
    // Retain only one frame per theme between switches. The complete animation
    // can still be released without leaving the next loading cover blank.
    private static let poster: Poster? = {
        guard let url = animationURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
        guard let light = adaptedLightFrame(image, context: context) else { return nil }
        return Poster(dark: image, light: light)
    }()
    nonisolated private static func adaptedLightFrame(_ image: CGImage, context: CIContext) -> CGImage? {
        // #ececec backdrop, #444444 glyph, preserving every intermediate shade.
        let scale = -168.0 / 255
        let adapted = CIImage(cgImage: image).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 236.0 / 255, y: 236.0 / 255, z: 236.0 / 255, w: 0)
        ])
        return context.createCGImage(adapted, from: adapted.extent,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
    let symbol = CALayer()
    let envelope = CALayer()
    private(set) var frames: Frames?
    private var preparation: Task<Frames?, Never>?
    private var preparationID = UUID()
    private var active = false
    private var playbackStart: CFTimeInterval = 0
    private var playbackReduced = false
    private var generation = UUID()
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { active ? self : nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.opacity = 0
        layer?.masksToBounds = true
        layer?.addSublayer(envelope)
        envelope.addSublayer(symbol)
        symbol.contentsGravity = .resizeAspect
        symbol.contents = Self.poster?.dark
        updateAppearance()
        setAccessibilityIdentifier("workspace-loading")
        setAccessibilityRole(.progressIndicator)
        startPreparing()
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearance()
    }
    private var isLight: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
    }
    private func updateAppearance() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = (isLight
            ? NSColor(srgbRed: 236.0 / 255, green: 236.0 / 255, blue: 236.0 / 255, alpha: 1)
            : NSColor.black).cgColor
        if active || symbol.contents != nil { updateMorph() }
        CATransaction.commit()
    }
    private func startPreparing() {
        guard frames == nil, preparation == nil else { return }
        preparationID = UUID()
        let url = Self.animationURL
        preparation = Task.detached(priority: .userInitiated) {
            guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
            var images: [CGImage] = [], lightImages: [CGImage] = [], durations: [Double] = []
            for index in 0..<CGImageSourceGetCount(source) {
                guard !Task.isCancelled,
                      let image = CGImageSourceCreateImageAtIndex(source, index,
                        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                      let webp = properties["{WebP}"] as? [String: Any],
                      let delay = (webp["UnclampedDelayTime"] ?? webp["DelayTime"]) as? NSNumber else { return nil }
                guard let light = Self.adaptedLightFrame(image, context: context) else { return nil }
                images.append(image); lightImages.append(light)
                durations.append(max(0.01, delay.doubleValue))
            }
            guard !images.isEmpty else { return nil }
            let total = durations.reduce(0, +)
            var elapsed = 0.0
            let times = durations.map { duration -> NSNumber in
                defer { elapsed += duration }
                return NSNumber(value: elapsed / total)
            }
            return Frames(images: images, lightImages: lightImages, times: times, duration: total)
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
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Cover the destination before preparation or mounting can begin.
        // Only the ready workspace is revealed by hide().
        layer?.removeAllAnimations()
        layer?.opacity = 1
        envelope.opacity = 1
        envelope.removeAllAnimations()
        CATransaction.commit()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        play(reduced: reduced)
        if frames == nil {
            Task { [weak self] in
                guard let self else { return }
                await self.prepareAnimation()
                guard self.active, self.generation == ticket else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.updateMorph()
                CATransaction.commit()
            }
        }
    }
    private func play(reduced: Bool) {
        playbackReduced = reduced
        playbackStart = symbol.convertTime(CACurrentMediaTime(), from: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        symbol.removeAllAnimations()
        updateAppearance()
        CATransaction.commit()
        guard !reduced else { return }
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [0.95, 1.05, 0.95]; pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = 2; pulse.repeatCount = .infinity
        pulse.beginTime = playbackStart
        pulse.timingFunctions = Array(repeating: CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1), count: 2)
        symbol.add(pulse, forKey: "pulse")
    }
    private func updateMorph() {
        guard let frames else {
            symbol.contents = isLight ? Self.poster?.light : Self.poster?.dark
            symbol.removeAnimation(forKey: "morph")
            return
        }
        let images = isLight ? frames.lightImages : frames.images
        guard let first = images.first else { return }
        symbol.contents = first
        symbol.removeAnimation(forKey: "morph")
        guard !playbackReduced else { return }
        let morph = CAKeyframeAnimation(keyPath: "contents")
        morph.values = images + [first]
        morph.keyTimes = frames.times + [1]
        morph.calculationMode = .discrete
        morph.duration = frames.duration; morph.repeatCount = .infinity
        // Theme changes replace colors without restarting the morph cycle.
        morph.beginTime = playbackStart
        symbol.add(morph, forKey: "morph")
    }
    private func fade(_ target: CALayer?, from: Float, to: Float, duration: Double) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from; animation.toValue = to
        animation.duration = duration; animation.beginTime = CACurrentMediaTime()
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
        CATransaction.commit()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            releaseAnimation()
        } else {
            fade(layer, from: opacity, to: 0, duration: 0.18)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
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
