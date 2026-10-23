import SwiftUI
import AppKit
import QuartzCore
import ClipSlotsKit

struct CanvasIdleTextSlot: NSViewRepresentable {
    let node: CanvasNode
    let text: String
    let pathLabel: String
    let renderScale: CGFloat
    let viewZoom: CGFloat
    let onOpenInputFiles: () -> Void
    let registry: CanvasLocalControlRegistry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.update(node: node, text: text, path: pathLabel, scale: renderScale, zoom: viewZoom,
                    dark: scheme == .dark, reducedMotion: reducedMotion,
                    registry: registry, open: onOpenInputFiles)
    }

    final class Surface: NSView {
        private static let symbols = NSCache<NSString, NSImage>()
        override var isFlipped: Bool { true }
        private var nodeID = ""
        private var signature = ""
        private var entry = false
        private var footer = CGRect.zero
        private var open: () -> Void = {}
        private weak var registry: CanvasLocalControlRegistry?
        private var button: NSButton?
        private let contentLayer = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            layer?.addSublayer(contentLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? {
            footer.contains(point) ? button : nil
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, entry else { return }
            entry = false
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.2; scale.toValue = 1; scale.duration = 0.23
            scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.39, 0.575, 0.565, 1)
            let alpha = CABasicAnimation(keyPath: "opacity")
            alpha.fromValue = 0; alpha.toValue = 1; alpha.duration = 0.0575
            let rate = Float(window?.screen?.maximumFramesPerSecond ?? 60)
            let cadence = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            scale.preferredFrameRateRange = cadence
            alpha.preferredFrameRateRange = cadence
            contentLayer.add(scale, forKey: "entry-scale"); contentLayer.add(alpha, forKey: "entry-alpha")
        }

        func update(node: CanvasNode, text: String, path: String, scale rs: CGFloat, zoom: CGFloat,
                    dark: Bool, reducedMotion: Bool, registry: CanvasLocalControlRegistry, open: @escaping () -> Void) {
            self.open = open; self.registry = registry; nodeID = node.id
            let plan = CanvasCardLayout.verticalPlan(nodeHeight: node.height, renderScale: rs,
                                                     headerFontSize: 9.5, footerFontSize: 9.5)
            let preview = CGRect(x: 12 * rs, y: 34 * rs, width: (node.width - 24) * rs, height: plan.previewHeight)
            let prompt = CGRect(x: preview.minX, y: preview.maxY + 12 * rs, width: preview.width,
                                height: plan.promptMaxHeight)
            footer = CGRect(x: preview.minX, y: (node.height - 38) * rs, width: preview.width, height: 26 * rs)
            registry.nativeNodes[node.id] = ["slot-input-\(node.id)": footer,
                                      "slot-prompt-\(node.id)": prompt, "slot-fan-\(node.id)": preview]
            let visible = CanvasScreenText.textVisible(nodeSize: node.frame.size, zoom: zoom) && plan.fitsText
            let cardSize = CanvasFanGeometry.fanCardSize(boxHeight: plan.previewHeight1x)
            let fanVisible = CanvasScreenText.cardTextVisible(cardSize: cardSize, zoom: zoom)
            let key = "\(node.width)|\(node.height)|\(node.fontName)|\(node.resolvedBodyFontSize)|\(text)|\(path)|\(dark)|\(CanvasSkin.colorful)|\(visible)|\(fanVisible)|\(rs)"
            guard signature != key, layer != nil else { return }
            let root = contentLayer
            let first = signature.isEmpty
            signature = key
            entry = first && !reducedMotion && Date().timeIntervalSince(node.createdAt) < 2
            CATransaction.begin(); CATransaction.setDisableActions(true)
            root.sublayers = []
            let size = CGSize(width: node.width * rs, height: node.height * rs)
            root.frame = CGRect(origin: .zero, size: size)
            func color(_ light: UInt32, _ night: UInt32, _ alpha: CGFloat = 1) -> CGColor {
                let hex = dark ? night : light
                return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                               green: CGFloat((hex >> 8) & 255) / 255,
                               blue: CGFloat(hex & 255) / 255, alpha: alpha).cgColor
            }
            func shape(_ rect: CGRect, radius: CGFloat, fill: CGColor, stroke: CGColor, width: CGFloat,
                       parent: CALayer = root) -> CAShapeLayer {
                let layer = CAShapeLayer()
                layer.frame = rect
                layer.path = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size),
                                    cornerWidth: radius, cornerHeight: radius, transform: nil)
                layer.fillColor = fill; layer.strokeColor = stroke; layer.lineWidth = width
                parent.addSublayer(layer)
                return layer
            }
            func label(_ string: String, frame: CGRect, font: NSFont, ink: CGColor,
                       parent: CALayer = root, wrap: Bool = false) {
                let layer = CATextLayer()
                layer.frame = frame; layer.contentsScale = window?.backingScaleFactor ?? 2
                layer.drawsAsynchronously = true
                layer.string = NSAttributedString(string: string, attributes: [.font: font,
                    .foregroundColor: NSColor(cgColor: ink) ?? .labelColor])
                layer.isWrapped = wrap; layer.truncationMode = wrap ? .end : .middle
                parent.addSublayer(layer)
            }
            func symbol(_ name: String, frame: CGRect, pointSize: CGFloat, ink: CGColor) {
                let layer = CALayer()
                layer.frame = frame
                let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
                    .applying(.init(paletteColors: [NSColor(cgColor: ink) ?? .labelColor]))
                let key = "\(name)|\(pointSize)|\(ink.components ?? [])" as NSString
                if let image = Self.symbols.object(forKey: key) {
                    layer.contents = image
                } else if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) {
                    Self.symbols.countLimit = 64
                    Self.symbols.setObject(image, forKey: key)
                    layer.contents = image
                }
                layer.contentsGravity = .resizeAspect
                layer.contentsScale = window?.backingScaleFactor ?? 2
                root.addSublayer(layer)
            }
            let fill = color(0xffffff, 0x1f1f1f), border = color(0xd4d6dd, 0x3b3e47)
            _ = shape(CGRect(origin: .zero, size: size), radius: 16 * rs,
                      fill: fill, stroke: color(0xd4d6dd, 0x3b3e47, 0.65), width: rs)
            _ = shape(preview, radius: 10 * rs, fill: color(0xedeef2, 0x292c33),
                      stroke: color(0xd4d6dd, 0x3b3e47, 0.6), width: 0.5 * rs)
            let texts = CanvasFanGeometry.allCardSources(attachmentIndices: [], text: text).compactMap { source -> String? in
                if case .textSegment(let body) = source { return body }; return nil
            }
            for layout in CanvasFanGeometry.layouts(count: texts.count, expanded: false).sorted(by: { $0.zIndex < $1.zIndex }) {
                guard texts.indices.contains(layout.index) else { continue }
                let rect = CGRect(origin: .zero, size: CGSize(width: cardSize.width * rs, height: cardSize.height * rs))
                let fan = shape(rect, radius: 17 * rs, fill: fill, stroke: border, width: rs)
                fan.anchorPoint = CGPoint(x: 0.5, y: 1)
                fan.position = CGPoint(x: preview.midX + layout.offset.width * rs,
                                       y: preview.midY + rect.height / 2 + layout.offset.height * rs)
                fan.transform = CATransform3DMakeRotation(layout.angle * .pi / 180, 0, 0, 1)
                fan.shadowColor = NSColor.black.cgColor; fan.shadowOpacity = dark ? 0.14 : 0.04
                fan.shadowRadius = 2 * rs; fan.shadowOffset = CGSize(width: 0, height: rs)
                fan.shadowPath = fan.path
                if fanVisible {
                    label(texts[layout.index], frame: rect.insetBy(dx: 8 * rs, dy: 8 * rs),
                          font: .systemFont(ofSize: 10.5 * rs), ink: color(0x25262b, 0xf0f1f4), parent: fan, wrap: true)
                    fan.masksToBounds = true; fan.cornerRadius = 17 * rs
                }
            }
            if visible {
                let referencePlan = CanvasCardLayout.verticalPlan(nodeHeight: node.height, renderScale: 1,
                                                                  headerFontSize: 9.5, footerFontSize: 9.5)
                let font = CanvasFontCatalog.nsFont(family: node.fontName, size: node.resolvedBodyFontSize)
                let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
                let boxHeight = max(1, referencePlan.promptMaxHeight - 16)
                let limit = min(CanvasCardText.previewLineCap, max(1, Int(boxHeight / lineHeight) + 1))
                let bodyLayer = CALayer()
                bodyLayer.frame = prompt.insetBy(dx: 0, dy: 8 * rs)
                root.addSublayer(bodyLayer)
                bodyLayer.masksToBounds = true
                label(CanvasCardText.previewText(text, limit: limit),
                      frame: bodyLayer.bounds,
                      font: CanvasFontCatalog.nsFont(family: node.fontName, size: node.resolvedBodyFontSize * rs),
                      ink: color(0x25262b, 0xf0f1f4, 0.88), parent: bodyLayer, wrap: true)
                let fade = CAGradientLayer()
                fade.frame = bodyLayer.bounds
                fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
                fade.locations = [0, NSNumber(value: Double(max(0, 1 - min(0.28, 10 / boxHeight)))), 1]
                bodyLayer.mask = fade
                let tagInk = CanvasSkin.colorful ? color(0xa86b18, 0xf0f1f4) : color(0x666970, 0xb0b3bc)
                symbol(node.kind.symbolName, frame: CGRect(x: 0, y: -20 * rs, width: 10.5 * rs, height: 14 * rs),
                       pointSize: 10.5 * rs, ink: tagInk)
                label(path, frame: CGRect(x: 14.5 * rs, y: -20 * rs, width: size.width - 14.5 * rs, height: 16 * rs),
                      font: .systemFont(ofSize: 11 * rs), ink: tagInk)
            }
            _ = shape(footer, radius: 8 * rs, fill: color(0xedeef2, 0x292c33),
                      stroke: color(0xd4d6dd, 0x3b3e47, 0.7), width: 0.5 * rs)
            let control = button ?? NSButton(frame: footer)
            control.target = self; control.action = #selector(openFiles)
            control.isBordered = false; control.frame = footer
            control.title = ""
            symbol("tray", frame: CGRect(x: footer.minX + 9 * rs, y: footer.midY - 5 * rs,
                                         width: 9 * rs, height: 10 * rs),
                   pointSize: 9 * rs, ink: color(0x666970, 0xb0b3bc))
            symbol("chevron.right", frame: CGRect(x: footer.maxX - 16 * rs, y: footer.midY - 4 * rs,
                                                   width: 7 * rs, height: 8 * rs),
                   pointSize: 7 * rs, ink: color(0x666970, 0xb0b3bc, 0.6))
            if visible {
                label("入参文件", frame: CGRect(x: footer.minX + 23 * rs, y: footer.midY - 6 * rs,
                                              width: footer.width - 48 * rs, height: 13 * rs),
                      font: .systemFont(ofSize: 9.5 * rs, weight: .medium), ink: color(0x666970, 0xb0b3bc))
            }
            control.setAccessibilityIdentifier("slot-input-\(node.id)")
            control.setAccessibilityLabel("入参文件")
            if button == nil { addSubview(control); button = control }
            CATransaction.commit()
        }
        @objc private func openFiles() { open() }
    }
}
