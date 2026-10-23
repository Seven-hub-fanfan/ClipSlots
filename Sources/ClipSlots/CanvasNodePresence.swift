import SwiftUI
import AppKit
import ClipSlotsKit

final class CanvasPresenceMirror: ObservableObject {
    var nodes: [CanvasNode] = []
}

struct CanvasRetiringNode: Identifiable {
    let id = UUID()
    let node: CanvasNode
    let text: String
    let path: String
    let attachments: [SlotContent.SlotAttachment]
}

/// Animate the local surface, before its canvas offset. The frame used by
/// layout, node measurements and pointer routing remains the final rectangle.
struct CanvasNodePresence: ViewModifier {
    let createdAt: Date
    var exiting = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var visible = false
    init(createdAt: Date, exiting: Bool = false) {
        self.createdAt = createdAt
        self.exiting = exiting
        _visible = State(initialValue: !exiting && Date().timeIntervalSince(createdAt) >= 2)
    }
    func body(content: Content) -> some View {
        content
            .scaleEffect(reducedMotion ? 1 : exiting ? (visible ? 0.2 : 1) : (visible ? 1 : 0.2))
            .animation(scaleAnimation, value: visible)
            .opacity(reducedMotion ? 1 : exiting ? (visible ? 0 : 1) : (visible ? 1 : 0))
            .animation(opacityAnimation, value: visible)
            .onAppear {
                guard exiting || Date().timeIntervalSince(createdAt) < 2, !reducedMotion else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { visible = true }
                    return
                }
                visible = true
            }
    }
    private var scaleAnimation: Animation? {
        guard !reducedMotion else { return nil }
        return exiting ? .timingCurve(0.435, 0, 0.61, 0.425, duration: 0.23)
                       : .timingCurve(0.39, 0.575, 0.565, 1, duration: 0.23)
    }
    private var opacityAnimation: Animation? {
        guard !reducedMotion else { return nil }
        // Preserve the first-quarter entry and last-quarter exit keyframes.
        return exiting ? .timingCurve(0.435, 0, 0.61, 0.425, duration: 0.0575).delay(0.1725)
                       : .timingCurve(0.39, 0.575, 0.565, 1, duration: 0.0575)
    }
}

struct CanvasMenuPresence: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var visible = false
    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: reducedMotion ? 0.08 : 0.15)) { visible = true }
            }
    }
}

struct CanvasFloatingPresence: ViewModifier {
    let bottom: Bool
    var presented: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var visible = false
    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .animation(opacityAnimation, value: visible)
            .offset(y: visible || reducedMotion ? 0 : bottom ? 14 : -10)
            .animation(positionAnimation, value: visible)
            .onAppear { visible = presented }
            .onChange(of: presented) { visible = $0 }
    }
    private var opacityAnimation: Animation {
        if reducedMotion { return .linear(duration: visible ? 0.1 : 0.08) }
        return visible ? .timingCurve(0.42, 0, 0.58, 1, duration: bottom ? 0.21 : 0.18)
            : .timingCurve(bottom ? 0.45 : 0.4, 0, 1, 1, duration: bottom ? 0.19 : 0.16)
    }
    private var positionAnimation: Animation {
        if reducedMotion { return .linear(duration: visible ? 0.1 : 0.08) }
        if !visible { return opacityAnimation }
        return bottom ? .timingCurve(0.25, 1, 0.5, 1, duration: 0.25)
                      : .timingCurve(0.16, 1, 0.3, 1, duration: 0.22)
    }
}

struct CanvasFloatingSnapshot: Equatable {
    let project: String
    let node: CanvasNode
    let frame: CGRect
}

/// SwiftUI conditionals otherwise unmount the view before its exit can draw.
/// Retained controls are visual only and immediately relinquish pointer input.
struct CanvasFloatingRetainer<Item: Equatable, Content: View>: View {
    let item: Item?
    let bottom: Bool
    @ViewBuilder let content: (Item) -> Content
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var retained: Item?
    @State private var removal: UUID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let value = item ?? retained {
                content(value)
                    .modifier(CanvasFloatingPresence(bottom: bottom, presented: item != nil))
                    .allowsHitTesting(item != nil)
                    .accessibilityHidden(item == nil)
            }
        }
        .onAppear { retained = item }
        .onChange(of: item) { next in
            let token = UUID()
            removal = token
            if let next { retained = next; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + (reducedMotion ? 0.08 : bottom ? 0.19 : 0.16)) {
                if removal == token { retained = nil }
            }
        }
    }
}
