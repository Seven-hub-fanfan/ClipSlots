import SwiftUI

/// Keep a leaf's type and field layout out of its parent's view graph.
/// This does not create another hosting view or retain offscreen controls.
struct WorkspaceContentBoundary: View {
    private let content: () -> AnyView

    init<Content: View>(@ViewBuilder content: @escaping () -> Content) {
        self.content = { AnyView(content()) }
    }

    var body: some View { content() }
}

/// A docked panel owns its width; asking its entire transcript and composer
/// for a minimum width only repeats work during each admission and page change.
struct WorkspaceDockLayout: Layout {
    let width: CGFloat?
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: width ?? proposal.width ?? 0, height: proposal.height ?? 0)
    }
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect,
                           proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect,
                           proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}
