import AppKit
import SwiftUI
import Combine

/// Coordinates are screen points, with the origin at the top left. The original
/// display pixels remain immutable; selection and annotations are rendered once.
@MainActor
final class AgentCaptureDocument: ObservableObject {
    enum Tool: String, CaseIterable {
        case rectangle, ellipse, arrow, pen, text, mosaic
        var symbol: String {
            switch self {
            case .rectangle: return "square"
            case .ellipse: return "circle"
            case .arrow: return "arrow.up.right"
            case .pen: return "pencil"
            case .text: return "textformat"
            case .mosaic: return "square.grid.3x3.fill"
            }
        }
        var title: String {
            switch self {
            case .rectangle: return "矩形"
            case .ellipse: return "圆形"
            case .arrow: return "箭头"
            case .pen: return "画笔"
            case .text: return "文本"
            case .mosaic: return "马赛克"
            }
        }
    }
    struct Mark {
        let tool: Tool
        var points: [CGPoint]
        let color: NSColor
        let width: CGFloat
        var text = ""
        var rect: CGRect {
            guard let a = points.first, let b = points.last else { return .zero }
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y))
        }
    }
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1, green: 0.12, blue: 0.29, alpha: 1),
        NSColor(srgbRed: 1, green: 0.66, blue: 0.08, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.48, blue: 1, alpha: 1),
        NSColor(srgbRed: 0.12, green: 0.82, blue: 0.30, alpha: 1), .white
    ]
    let image: CGImage
    let size: CGSize
    @Published var selection: CGRect = .zero
    @Published var tool: Tool?
    @Published var colorIndex = 0
    @Published var lineWidth: CGFloat = 2
    @Published var marks: [Mark] = []
    @Published var pending: Mark?
    var canCopy: Bool { selection.width >= 2 && selection.height >= 2 }

    init(image: CGImage, size: CGSize) { self.image = image; self.size = size }
    func bounded(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), size.width), y: min(max(0, point.y), size.height))
    }
    func undo() { pending = nil; if !marks.isEmpty { marks.removeLast() } }
    func mark(_ tool: Tool, points: [CGPoint], text: String = "") -> Mark {
        Mark(tool: tool, points: points, color: Self.colors[colorIndex], width: lineWidth, text: text)
    }
    func renderPNG() -> Data? {
        guard canCopy else { return nil }
        let sx = CGFloat(image.width) / size.width, sy = CGFloat(image.height) / size.height
        let region = CGRect(x: selection.minX * sx, y: selection.minY * sy,
                            width: selection.width * sx, height: selection.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cropped = image.cropping(to: region),
              let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        context.translateBy(x: 0, y: CGFloat(cropped.height))
        context.scaleBy(x: sx, y: -sy)
        context.translateBy(x: -region.minX / sx, y: -region.minY / sy)
        drawMarks(context, includePending: false)
        guard let output = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
    }
    func drawMarks(_ context: CGContext, includePending: Bool = true) {
        context.saveGState()
        context.clip(to: selection)
        for mark in marks + (includePending ? pending.map { [$0] } ?? [] : []) {
            guard let first = mark.points.first, let last = mark.points.last else { continue }
            context.setStrokeColor(mark.color.cgColor)
            context.setFillColor(mark.color.cgColor)
            context.setLineWidth(mark.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            switch mark.tool {
            case .rectangle: context.stroke(mark.rect)
            case .ellipse: context.strokeEllipse(in: mark.rect)
            case .pen:
                context.beginPath(); context.move(to: first)
                for point in mark.points.dropFirst() { context.addLine(to: point) }
                if mark.points.count == 1 { context.addLine(to: first) }
                context.strokePath()
            case .arrow:
                context.beginPath(); context.move(to: first); context.addLine(to: last)
                let angle = atan2(last.y - first.y, last.x - first.x)
                let length = max(10, mark.width * 5)
                for delta in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                    context.move(to: CGPoint(x: last.x - length * cos(angle + delta),
                                            y: last.y - length * sin(angle + delta)))
                    context.addLine(to: last)
                }
                context.strokePath()
            case .text:
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                (mark.text as NSString).draw(at: first, withAttributes: [
                    .foregroundColor: mark.color, .font: NSFont.systemFont(ofSize: 16 + mark.width * 2)
                ])
                NSGraphicsContext.restoreGraphicsState()
            case .mosaic:
                let r = mark.rect.intersection(selection)
                let sx = CGFloat(image.width) / size.width, sy = CGFloat(image.height) / size.height
                guard r.width >= 1, r.height >= 1,
                      let crop = image.cropping(to: CGRect(x: r.minX * sx, y: r.minY * sy,
                        width: r.width * sx, height: r.height * sy)),
                      let reduced = CGContext(data: nil, width: max(1, Int(r.width / 9)),
                        height: max(1, Int(r.height / 9)), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                reduced.interpolationQuality = .low
                reduced.draw(crop, in: CGRect(x: 0, y: 0, width: reduced.width, height: reduced.height))
                if let pixelated = reduced.makeImage() {
                    context.saveGState()
                    context.interpolationQuality = .none
                    context.translateBy(x: r.minX, y: r.maxY)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(pixelated, in: CGRect(origin: .zero, size: r.size))
                    context.restoreGState()
                }
            }
        }
        context.restoreGState()
    }
}

@MainActor
final class AgentCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init(frame: CGRect, document: AgentCaptureDocument, complete: @escaping (Data?) -> Void) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = false
        isReleasedWhenClosed = false
        let editor = AgentCaptureView(frame: CGRect(origin: .zero, size: frame.size),
                                      document: document, complete: complete)
        contentView = editor
        makeKeyAndOrderFront(nil)
        makeFirstResponder(editor)
    }
}

@MainActor
final class AgentCaptureView: NSView, NSTextFieldDelegate {
    let document: AgentCaptureDocument
    private let complete: (Data?) -> Void
    private var subscriptions: Set<AnyCancellable> = []
    private var toolbar: NSHostingView<AgentCaptureToolbar>!
    private var textField: NSTextField?
    private var textPoint = CGPoint.zero
    private var anchor = CGPoint.zero
    private var initialSelection = CGRect.zero
    private var initialMarks: [AgentCaptureDocument.Mark] = []
    private var resizeHandle: Int?
    private var moving = false
    private var selecting = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, document: AgentCaptureDocument, complete: @escaping (Data?) -> Void) {
        self.document = document; self.complete = complete
        super.init(frame: frame)
        setAccessibilityIdentifier("agent-capture-editor")
        setAccessibilityLabel("截图选区与标注")
        toolbar = NSHostingView(rootView: AgentCaptureToolbar(document: document,
            cancel: { [weak self] in self?.finish(nil) }, copy: { [weak self] in self?.copyImage() }))
        addSubview(toolbar)
        document.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true; self?.positionToolbar() }
        }.store(in: &subscriptions)
        positionToolbar()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    private var handles: [CGPoint] {
        let r = document.selection
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY),
                CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
                CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }
    private func positionToolbar() {
        toolbar.isHidden = !document.canCopy || selecting
        let width = min(bounds.width - 20, 650), height: CGFloat = 52
        let r = document.selection
        let y = r.maxY + 10 + height <= bounds.height ? r.maxY + 10 : max(48, r.minY - height - 10)
        toolbar.frame = CGRect(x: min(max(10, r.maxX - width), bounds.width - width - 10),
                               y: y, width: width, height: height)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        NSImage(cgImage: document.image, size: bounds.size).draw(in: bounds, from: .zero,
            operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        cg.saveGState()
        cg.addRect(bounds)
        if document.canCopy { cg.addRect(document.selection) }
        cg.setFillColor(NSColor.black.withAlphaComponent(0.63).cgColor)
        cg.drawPath(using: .eoFill)
        cg.restoreGState()
        if document.canCopy {
            document.drawMarks(cg)
            cg.setStrokeColor(NSColor(srgbRed: 0.48, green: 0.80, blue: 0.94, alpha: 1).cgColor)
            cg.setLineWidth(1); cg.stroke(document.selection)
            for point in handles {
                cg.setFillColor(NSColor.white.cgColor)
                cg.fill(CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
            }
            let label = "\(Int(document.selection.width)) × \(Int(document.selection.height))"
            drawBadge(label, at: CGPoint(x: document.selection.minX + 8, y: document.selection.minY + 8))
        }
        drawBadge("拖动选择区域 · 标注后复制 · Esc 取消",
                  at: CGPoint(x: bounds.midX - 145, y: 12))
    }
    private func drawBadge(_ text: String, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.8)
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        NSColor(white: 0.11, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: CGRect(origin: point, size: CGSize(width: size.width + 18, height: 28)),
                     xRadius: 7, yRadius: 7).fill()
        (text as NSString).draw(at: CGPoint(x: point.x + 9, y: point.y + 6), withAttributes: attrs)
    }
    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        anchor = document.bounded(convert(event.locationInWindow, from: nil))
        initialSelection = document.selection
        initialMarks = document.marks
        resizeHandle = document.canCopy ? handles.firstIndex(where: { hypot($0.x - anchor.x, $0.y - anchor.y) <= 8 }) : nil
        moving = resizeHandle == nil && document.tool == nil && document.selection.contains(anchor)
        selecting = resizeHandle == nil && !moving && (!document.canCopy || !document.selection.contains(anchor))
        if selecting {
            document.selection = .zero; document.marks = []; document.pending = nil
        } else if resizeHandle == nil, !moving, let tool = document.tool {
            if tool == .text { beginText(at: anchor) }
            else { document.pending = document.mark(tool, points: [anchor, anchor]) }
        }
        needsDisplay = true; positionToolbar()
    }
    override func mouseDragged(with event: NSEvent) {
        let p = document.bounded(convert(event.locationInWindow, from: nil))
        if selecting { document.selection = rect(anchor, p) }
        else if let handle = resizeHandle {
            var left = initialSelection.minX, right = initialSelection.maxX
            var top = initialSelection.minY, bottom = initialSelection.maxY
            if [0, 6, 7].contains(handle) { left = p.x }
            if [2, 3, 4].contains(handle) { right = p.x }
            if [0, 1, 2].contains(handle) { top = p.y }
            if [4, 5, 6].contains(handle) { bottom = p.y }
            document.selection = rect(CGPoint(x: left, y: top), CGPoint(x: right, y: bottom))
        } else if moving {
            let dx = min(max(p.x - anchor.x, -initialSelection.minX), bounds.width - initialSelection.maxX)
            let dy = min(max(p.y - anchor.y, -initialSelection.minY), bounds.height - initialSelection.maxY)
            document.selection = initialSelection.offsetBy(dx: dx, dy: dy)
            document.marks = initialMarks.map { old in
                var mark = old
                mark.points = old.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
                return mark
            }
        } else if var mark = document.pending {
            if mark.tool == .pen { mark.points.append(p) } else { mark.points[1] = p }
            document.pending = mark
        }
        needsDisplay = true; positionToolbar()
    }
    override func mouseUp(with event: NSEvent) {
        if let pending = document.pending { document.marks.append(pending); document.pending = nil }
        selecting = false; moving = false; resizeHandle = nil
        positionToolbar(); needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if document.canCopy, handles.contains(where: { hypot($0.x - p.x, $0.y - p.y) <= 8 }) {
            NSCursor.crosshair.set()
        } else if document.tool == nil, document.selection.contains(p) { NSCursor.openHand.set() }
        else { NSCursor.crosshair.set() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) }
        else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" { document.undo() }
        else if event.keyCode == 36 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c") {
            copyImage()
        } else { super.keyDown(with: event) }
    }
    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    private func beginText(at point: CGPoint) {
        textPoint = point
        let field = NSTextField(frame: CGRect(x: point.x, y: point.y,
            width: max(30, min(240, document.selection.maxX - point.x)),
            height: min(36, document.selection.maxY - point.y)))
        field.placeholderString = "输入文本"
        field.textColor = AgentCaptureDocument.colors[document.colorIndex]
        field.font = .systemFont(ofSize: 16 + document.lineWidth * 2)
        field.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        field.delegate = self
        field.setAccessibilityIdentifier("agent-capture-text-input")
        textField = field; addSubview(field); window?.makeFirstResponder(field)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { finish(nil); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitText(); window?.makeFirstResponder(self); return true
        }
        return false
    }
    private func commitText() {
        guard let field = textField else { return }
        if !field.stringValue.isEmpty { document.marks.append(document.mark(.text, points: [textPoint], text: field.stringValue)) }
        field.removeFromSuperview(); textField = nil
    }
    private func copyImage() { commitText(); if let data = document.renderPNG() { finish(data) } }
    private func finish(_ data: Data?) { textField?.removeFromSuperview(); textField = nil; complete(data) }
}

private struct AgentCaptureToolbar: View {
    @ObservedObject var document: AgentCaptureDocument
    let cancel: () -> Void
    let copy: () -> Void
    var body: some View {
        HStack(spacing: 5) {
            ForEach(AgentCaptureDocument.Tool.allCases, id: \.self) { tool in
                Button { document.tool = document.tool == tool ? nil : tool } label: {
                    Group {
                        if tool == .text { Text("A").font(.system(size: 19, design: .serif)) }
                        else { Image(systemName: tool.symbol).font(.system(size: 16)) }
                    }
                        .frame(width: 31, height: 32)
                        .background(document.tool == tool ? Color.white.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                }.help(tool.title).accessibilityLabel(tool.title)
                    .accessibilityIdentifier("agent-capture-tool-\(tool.rawValue)")
            }
            Divider().frame(height: 24).padding(.horizontal, 4)
            ForEach(AgentCaptureDocument.colors.indices, id: \.self) { index in
                Button { document.colorIndex = index } label: {
                    Circle().fill(Color(nsColor: AgentCaptureDocument.colors[index])).frame(width: 13, height: 13)
                        .padding(3).overlay(Circle().stroke(.white.opacity(document.colorIndex == index ? 0.8 : 0)))
                }.accessibilityLabel(["红色", "橙色", "蓝色", "绿色", "白色"][index])
                    .accessibilityIdentifier("agent-capture-color-\(index)")
            }
            Divider().frame(height: 24).padding(.horizontal, 4)
            ForEach([CGFloat(2), 4], id: \.self) { width in
                Button { document.lineWidth = width } label: {
                    Circle().fill(.white.opacity(0.65)).frame(width: width, height: width)
                        .frame(width: 25, height: 32)
                        .background(document.lineWidth == width ? Color.white.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                }.help(width == 2 ? "细线" : "粗线")
                    .accessibilityLabel(width == 2 ? "细线" : "粗线")
                    .accessibilityIdentifier("agent-capture-width-\(Int(width))")
            }
            Button { document.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 29, height: 32) }
                .help("撤销 · ⌘Z").disabled(document.marks.isEmpty)
                .accessibilityLabel("撤销").accessibilityIdentifier("agent-capture-undo")
            Button(action: cancel) { Image(systemName: "xmark").frame(width: 27, height: 32) }
                .help("取消 · Esc").accessibilityLabel("取消").accessibilityIdentifier("agent-capture-cancel")
            Button(action: copy) {
                Label("复制", systemImage: "checkmark").font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white).padding(.horizontal, 13).frame(height: 34)
                    .background(Color(red: 0.08, green: 0.63, blue: 0.81), in: RoundedRectangle(cornerRadius: 8))
            }.disabled(!document.canCopy).accessibilityIdentifier("agent-capture-copy")
        }.buttonStyle(.plain).foregroundColor(.white.opacity(0.6))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.16)))
            .environment(\.colorScheme, .dark)
    }
}
