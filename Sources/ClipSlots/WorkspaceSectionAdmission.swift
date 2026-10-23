import SwiftUI

/// Each chrome section mounts independently while the native veil is visible.
/// Deferred sections have no controls, observers, media or event handlers.
struct WorkspaceSectionAdmission: View {
    @ObservedObject var admission: CanvasNodeAdmission
    var width: CGFloat?
    var height: CGFloat?
    var fillsViewport: Bool
    private let traceLabel: String?
    private let content: () -> AnyView
    init<Content: View>(admission: CanvasNodeAdmission, width: CGFloat? = nil,
                       height: CGFloat? = nil, fillsViewport: Bool = false,
                       traceLabel: String? = nil,
                       @ViewBuilder content: @escaping () -> Content) {
        self.admission = admission
        self.width = width
        self.height = height
        self.fillsViewport = fillsViewport
        self.traceLabel = traceLabel
        self.content = { AnyView(content()) }
    }
    var body: some View {
        if fillsViewport, let width, let height {
            WorkspaceSectionLayout(size: CGSize(width: width, height: height)) {
                admittedContent
            }
        } else {
            admittedContent
        }
    }
    @ViewBuilder private var admittedContent: some View {
        if admission.ready {
            WorkspaceMountTrace.measure("body:\(traceLabel ?? admission.label)", content)
        } else {
            Color.clear.frame(width: width, height: height)
                .accessibilityHidden(true)
        }
    }
}

/// Viewport sections already own their rectangle. Parent layout never needs
/// to ask every button and node for its ideal size when one section changes.
private struct WorkspaceSectionLayout: Layout {
    let size: CGSize
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { size }
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect,
                           proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect,
                           proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
}
