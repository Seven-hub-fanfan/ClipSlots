import SwiftUI
import ClipSlotsKit
import CoreImage

/// The legacy raw route is retained for saved-data compatibility.
enum WorkspaceMode: String, CaseIterable, Identifiable, Equatable {
    case edit
    case canvas
    case agent

    var id: String { rawValue }
    var title: String {
        switch self {
        case .edit: return "编辑"
        case .canvas: return "画布"
        case .agent: return "模型"
        }
    }
    var symbolName: String {
        switch self {
        case .edit: return "rectangle.stack"
        case .canvas: return "viewfinder"
        case .agent: return "cube"
        }
    }
    var isSelectable: Bool { true }
}

/// One pinned instance for both workspaces. Only the contour, dot and button
/// contents animate; the window and page layout do not participate.
struct WorkspaceModeSwitcher: View {
    @Binding var selection: WorkspaceMode
    var animationsEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered: WorkspaceMode?
    @State private var contourMotion = WorkspaceContourMotion()

    static let preferredWidth: CGFloat = WindowLayoutMetrics.workspaceSwitcherWidth
    static let preferredHeight: CGFloat = 40
    static let pinnedTopInset: CGFloat = 20
    private static let inset: CGFloat = 8
    private static let ornamentWidth: CGFloat = 42
    private static var segmentWidth: CGFloat { (preferredWidth - inset * 2 - ornamentWidth) / 3 }
    static var contourHalfWidth: CGFloat { segmentWidth * 0.64 }
    static func center(for mode: WorkspaceMode) -> CGFloat {
        let index: CGFloat = mode == .edit ? 0 : mode == .canvas ? 1 : 2
        return inset + ornamentWidth + segmentWidth * (index + 0.5)
    }
    private var ink: Color { TapSkin.tone(0x303034, 0xffffff) }

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceBrandMark()
                .frame(width: 22, height: 25)
                .frame(width: Self.ornamentWidth, height: Self.preferredHeight)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(LinearGradient(
                        colors: [.clear, TapSkin.tone(0xd6d7dc, 0x44464c), .clear],
                        startPoint: .top, endPoint: .bottom))
                        .frame(width: 0.5, height: 18).padding(.trailing, 3)
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            ForEach(WorkspaceMode.allCases) { mode in segment(mode) }
        }
        .padding(.horizontal, Self.inset)
        .frame(width: Self.preferredWidth, height: Self.preferredHeight)
        .background { navigationSurface }
        .overlay(alignment: .leading) {
            WorkspaceContourSurface(center: Self.center(for: selection),
                halfWidth: Self.contourHalfWidth,
                animated: animationsEnabled && !reduceMotion,
                highContrast: contrast == .increased, motion: contourMotion)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// A uniform, subdued rim keeps the whole capsule visually balanced.
    private var navigationSurface: some View {
        Capsule(style: .continuous)
            .fill(TapSkin.tone(0xfafafb, 0x1e1f22))
            .overlay {
                Capsule(style: .continuous).strokeBorder(
                    contrast == .increased
                        ? TapSkin.tone(0xaeb2bc, 0x828894)
                        : TapSkin.tone(0xd9dbe0, 0x383b41),
                    lineWidth: contrast == .increased ? 1.5 : 1)
            }
    }

    private func segment(_ mode: WorkspaceMode) -> some View {
        let selected = selection == mode
        return Button {
            guard mode.isSelectable else { return }
            // Submit the layer animation before preparing or mounting the page.
            contourMotion.select(center: Self.center(for: mode),
                                 animated: animationsEnabled && !reduceMotion)
            selection = mode
        } label: {
            VStack(spacing: 2) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16, height: 14)
                Text(mode.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .fixedSize()
            }
            .foregroundColor(ink.opacity(selected ? 1 : hovered == mode ? 0.78 : 0.50))
            .frame(width: Self.segmentWidth, height: Self.preferredHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(WorkspacePressStyle(animationsEnabled: animationsEnabled))
        .onHover { hovered = $0 && mode.isSelectable ? mode : nil }
        .disabled(!mode.isSelectable)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(mode == .agent ? "workspace-models" : "workspace-\(mode.rawValue)")
        .help(mode.title)
    }
}

/// The app icon's original central artwork, without its white plate.
/// Decorative only: no focus, action, selection or tracking area.
private struct WorkspaceBrandMark: NSViewRepresentable {
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) { view.needsDisplay = true }

    final class Host: NSView {
        private static let artwork = WorkspaceBrandResources.markURL.flatMap { NSImage(contentsOf: $0) }
        private static let darkArtwork: NSImage? = {
            guard let image = artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let inverse = CIImage(cgImage: image).applyingFilter("CIColorInvert")
            guard let rendered = CIContext().createCGImage(inverse, from: inverse.extent) else { return nil }
            return NSImage(cgImage: rendered, size: NSSize(width: image.width, height: image.height))
        }()
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            let image = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? Self.darkArtwork : Self.artwork
            if let image {
                let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
                let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: NSRect(x: bounds.midX - size.width / 2,
                                     y: bounds.midY - size.height / 2, width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
    }
}

/// A continuous shoulder joins the active arch to the base line.
struct WorkspaceSelectionContour: Shape {
    var center: CGFloat
    var halfWidth: CGFloat
    var animatableData: CGFloat {
        get { center }
        set { center = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let bottom = rect.maxY - 1.5, top = rect.minY + 1.5
        let shoulder = halfWidth, crown = halfWidth * 0.34
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: bottom))
        path.addLine(to: CGPoint(x: center - shoulder, y: bottom))
        path.addCurve(to: CGPoint(x: center - crown, y: top),
            control1: CGPoint(x: center - shoulder * 0.52, y: bottom),
            control2: CGPoint(x: center - shoulder * 0.78, y: top))
        path.addLine(to: CGPoint(x: center + crown, y: top))
        path.addCurve(to: CGPoint(x: center + shoulder, y: bottom),
            control1: CGPoint(x: center + shoulder * 0.78, y: top),
            control2: CGPoint(x: center + shoulder * 0.52, y: bottom))
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom))
        return path
    }
}

private struct WorkspacePressStyle: ButtonStyle {
    var animationsEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .offset(y: configuration.isPressed ? 1.5 : 0)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(reduceMotion || !animationsEnabled ? nil : .spring(response: 0.20, dampingFraction: 0.66),
                       value: configuration.isPressed)
            .transaction { $0.disablesAnimations = false }
    }
}
