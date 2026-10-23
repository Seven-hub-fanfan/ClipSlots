import SwiftUI

/// Mount one card per display turn behind the native loading layer.
/// Observing the admission here keeps each turn out of ContentView's body.
struct EditorCardAdmission: View {
    @ObservedObject var admission: CanvasNodeAdmission
    private let content: () -> AnyView
    init<Content: View>(admission: CanvasNodeAdmission, @ViewBuilder content: @escaping () -> Content) {
        self.admission = admission
        self.content = { AnyView(content()) }
    }
    var body: some View {
        if admission.ready {
            content()
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.cardBackground(isEmpty: true))
                .frame(height: 270)
                .accessibilityHidden(true)
        }
    }
}
