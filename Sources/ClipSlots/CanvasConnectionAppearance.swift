import SwiftUI
import ClipSlotsKit

enum CanvasConnectionAppearance: Equatable {
    case idle, source, valid(reverse: Bool), invalid
}

extension CanvasWorkspaceView {
    func connectionAppearance(for node: CanvasNode) -> CanvasConnectionAppearance {
        guard let drag = linkDrag else { return .idle }
        if node.id == drag.fromNodeId { return .source }
        guard hoverHoldNodeId == node.id || drag.targetNodeId == node.id
                || screenFrame(of: node).contains(drag.cursor) else { return .idle }
        if linkCandidateCache.candidates(canvas: canvas, source: drag.fromNodeId, reverse: drag.fromInput).contains(node.id) {
            return .valid(reverse: drag.fromInput)
        }
        // A rejection explains the currently aimed-at surface. It must not
        // obscure unrelated cards across the workspace during every link drag.
        return screenFrame(of: node).contains(drag.cursor) ? .invalid : .idle
    }

    func generationBackdrop(for node: CanvasNode) -> SlotContent.SlotAttachment? {
        guard renderMedia(of: node) == nil else { return nil }
        for edge in canvas.incomingEdges(of: node.id) {
            if let parent = canvas.node(id: edge.fromNodeId),
               let media = renderMedia(of: parent), media.canvasIsImageLike || media.canvasIsVideoLike { return media }
        }
        return nil
    }
}

struct CanvasCandidateBorder: View {
    let scale: CGFloat
    let reverse: Bool
    let hovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var moving = false
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                band(size: proxy.size, outset: 6, shoulder: 0.24, peak: 0.58)
                    .blur(radius: 8 * scale)
                band(size: proxy.size, outset: 2, shoulder: 0.55, peak: 1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .opacity(hovered ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: hovered)
            .onAppear { start() }
            .onChange(of: hovered) { _ in start() }
            .onChange(of: reverse) { _ in start() }
        }
        .allowsHitTesting(false)
    }
    private func band(size: CGSize, outset: CGFloat, shoulder: Double, peak: Double) -> some View {
        let width = size.width + 2 * outset * scale
        let height = size.height + 2 * outset * scale
        return LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .clear, location: 0.2),
            .init(color: .white.opacity(shoulder), location: 0.4), .init(color: .white.opacity(peak), location: 0.5),
            .init(color: .white.opacity(shoulder), location: 0.6), .init(color: .clear, location: 0.8),
            .init(color: .clear, location: 1)
        ], startPoint: .leading, endPoint: .trailing)
        .frame(width: width * 2, height: height)
        .offset(x: reverse ? (moving ? -2 : 0) * width : (moving ? 1 : -1) * width)
        .frame(width: width, height: height, alignment: .leading)
        .mask(RoundedRectangle(cornerRadius: (16 + outset) * scale)
            .strokeBorder(lineWidth: outset * scale))
    }
    private func start() {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { moving = false }
        guard hovered, !reducedMotion else { return }
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { moving = true }
    }
}
