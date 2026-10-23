import SwiftUI

/// The workspace fills the remaining window rectangle. Its cards and sidebars
/// do not contribute an intrinsic size to the window's header/footer layout.
struct WorkspaceViewportBoundary: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { _ in
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
