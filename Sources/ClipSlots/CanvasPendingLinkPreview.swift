import SwiftUI

/// Keep pending-menu iteration out of the canvas's conditional view metadata.
struct CanvasPendingLinkPreview: View {
    let starts: [CGPoint]
    let destination: CGPoint

    var body: some View {
        ZStack {
            ForEach(starts.indices, id: \.self) { index in
                CanvasLinkDragPreview(start: starts[index], cursor: destination, hasTarget: false)
            }
        }
    }
}
