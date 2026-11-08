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
    var keepsNavigationVisible = false
    func makeNSView(context: Context) -> WorkspaceLoadingView {
        let view = WorkspaceLoadingView()
        view.keepsNavigationVisible = keepsNavigationVisible
        transition.surface = view
        return view
    }
    func updateNSView(_ view: WorkspaceLoadingView, context: Context) {
        view.keepsNavigationVisible = keepsNavigationVisible
    }
    static func dismantleNSView(_ view: WorkspaceLoadingView, coordinator: ()) {
        view.hide()
    }
}

/// Keep the single navigation instance above both the loading cover and its
/// exit fade. The native cover also leaves these SwiftUI buttons reachable.
struct WorkspaceLoadingOverlay<Navigation: View>: ViewModifier {
    let transition: WorkspaceTransition
    let navigation: Navigation
    func body(content: Content) -> some View {
        content
            .overlay { WorkspaceLoadingSurface(transition: transition, keepsNavigationVisible: true) }
            .overlay(alignment: .top) { navigation }
    }
}

final class WorkspaceLoadingView: NSView {
    struct Frames: @unchecked Sendable {
        let images: [CGImage]
        let lightImages: [CGImage]
        let times: [NSNumber]
        let duration: Double
    }
    private static var animationURL: URL? {
        AgentBackgroundResources.pageURL?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TapNowMotion/workspace-loading.webp")
    }
    // Prepare the complete loop once, before this surface is shown. Sharing
    // display-sized frames makes every switch start the actual morph immediately.
    private static let animationFrames: Frames? = {
        guard let url = animationURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var images: [CGImage] = [], lightImages: [CGImage] = [], durations: [Double] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                  let webp = properties["{WebP}"] as? [String: Any],
                  let delay = (webp["UnclampedDelayTime"] ?? webp["DelayTime"]) as? NSNumber,
                  let light = adaptedLightFrame(image) else { return nil }
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
    }()
    private static func adaptedLightFrame(_ image: CGImage) -> CGImage? {
        // #ececec backdrop, #444444 glyph, preserving every intermediate shade.
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for index in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            let alpha = Int(pixels[index + 3])
            for channel in 0..<3 {
                let value = (236 * alpha - 168 * Int(pixels[index + channel]) + 127) / 255
                pixels[index + channel] = UInt8(clamping: value)
            }
        }
        return context.makeImage()
    }
    let symbol = CALayer()
    let envelope = CALayer()
    private(set) var frames: Frames?
    private var active = false
    private var playbackStart: CFTimeInterval = 0
    private var playbackReduced = false
    private var generation = UUID()
    private weak var readyBlurView: NSView?
    private weak var readyBlurLayer: CALayer?
    private var readyBlurFilter: CIFilter?
    private var previousWantsLayer = false
    private var previousUsesFilters = false
    private var previousFilters: [Any]?
    var keepsNavigationVisible = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard active else { return nil }
        if keepsNavigationVisible {
            let navigation = CGRect(x: bounds.midX - WorkspaceModeSwitcher.preferredWidth / 2,
                y: bounds.minY + WorkspaceModeSwitcher.pinnedTopInset,
                width: WorkspaceModeSwitcher.preferredWidth, height: WorkspaceModeSwitcher.preferredHeight)
            if navigation.contains(point) { return nil }
        }
        return self
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.opacity = 0
        layer?.masksToBounds = true
        layer?.addSublayer(envelope)
        envelope.addSublayer(symbol)
        symbol.contentsGravity = .resizeAspect
        frames = Self.animationFrames
        updateAppearance()
        setAccessibilityIdentifier("workspace-loading")
        setAccessibilityRole(.progressIndicator)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if readyBlurView !== window?.contentView { clearReadyBlur() }
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
    func prepareAnimation() async {
        frames = Self.animationFrames
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
        active = true
        frames = Self.animationFrames
        setAccessibilityLabel(title)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Cover the destination before preparation or mounting can begin.
        // Only the ready workspace is revealed by hide().
        layer?.removeAllAnimations()
        layer?.opacity = 1
        envelope.opacity = 1
        envelope.removeAllAnimations()
        clearReadyBlur()
        CATransaction.commit()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        play(reduced: reduced)
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
        guard let frames else { return }
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
            revealReadyWorkspace()
            fade(layer, from: opacity, to: 0, duration: 0.18)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.generation == ticket, !self.active else { return }
                self.releaseAnimation()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.generation == ticket, !self.active else { return }
                self.clearReadyBlur()
            }
        }
    }
    private func revealReadyWorkspace() {
        clearReadyBlur()
        guard let root = window?.contentView, root !== self,
              let filter = CIFilter(name: keepsNavigationVisible ? "CIMaskedVariableBlur" : "CIGaussianBlur") else { return }
        // The destination is already fully mounted. Animate its native composite,
        // including the fading glyph, without rebuilding the SwiftUI subtree.
        previousWantsLayer = root.wantsLayer
        previousUsesFilters = root.layerUsesCoreImageFilters
        root.wantsLayer = true
        root.layerUsesCoreImageFilters = true
        guard let target = root.layer else {
            root.layerUsesCoreImageFilters = previousUsesFilters
            root.wantsLayer = previousWantsLayer
            return
        }
        readyBlurView = root
        readyBlurLayer = target
        readyBlurFilter = filter
        previousFilters = target.filters
        if keepsNavigationVisible {
            // Core Animation maps this mask from layer points to backing pixels.
            // Applying contentsScale here would scale the exclusion twice.
            let extent = CGRect(origin: .zero, size: root.bounds.size)
            let width = WorkspaceModeSwitcher.preferredWidth + 16
            let height = WorkspaceModeSwitcher.preferredHeight + 16
            let navigationY = target.isGeometryFlipped
                ? WorkspaceModeSwitcher.pinnedTopInset - 8
                : root.bounds.height - WorkspaceModeSwitcher.pinnedTopInset
                    - WorkspaceModeSwitcher.preferredHeight - 8
            let navigation = CGRect(x: (root.bounds.width - width) / 2,
                y: navigationY, width: width, height: height)
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: navigation)
            filter.setValue(black.composited(over: white), forKey: "inputMask")
        }
        filter.name = "workspaceReadyBlur"
        filter.setValue(0, forKey: kCIInputRadiusKey)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        target.filters = (previousFilters ?? []) + [filter]
        CATransaction.commit()
        let blur = CAKeyframeAnimation(keyPath: "filters.workspaceReadyBlur.inputRadius")
        blur.values = [0, 6, 0]; blur.keyTimes = [0, 0.18, 1]
        blur.duration = 0.28
        blur.beginTime = target.convertTime(CACurrentMediaTime(), from: nil)
        blur.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1),
            CAMediaTimingFunction(controlPoints: 0.22, 0.1, 0.25, 1)
        ]
        target.add(blur, forKey: "workspace-ready-blur")
    }
    private func clearReadyBlur() {
        guard let filter = readyBlurFilter else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let target = readyBlurLayer {
            target.removeAnimation(forKey: "workspace-ready-blur")
            let remaining = (target.filters ?? []).filter { ($0 as AnyObject) !== filter }
            target.filters = remaining.isEmpty && previousFilters == nil ? nil : remaining
            if let root = readyBlurView, root.layer === target {
                root.layerUsesCoreImageFilters = previousUsesFilters
                root.wantsLayer = previousWantsLayer
            }
        }
        readyBlurFilter = nil
        readyBlurLayer = nil
        readyBlurView = nil
        previousFilters = nil
        CATransaction.commit()
    }
    private func releaseAnimation() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.removeAllAnimations(); envelope.removeAllAnimations(); symbol.removeAllAnimations()
        symbol.contents = nil; frames = nil
        CATransaction.commit()
    }
}
