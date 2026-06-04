import SwiftUI

/// v2.7.10: reusable preview panel for the radial menu.
/// Integrate it next to RadialMenuView in the radial window controller.
/// Default lifecycle should follow radial menu; when pinned, keep it visible after radial menu closes.
struct RadialPreviewPanel: View {
    let title: String
    let subtitle: String
    let content: AnyView
    @Binding var isPinned: Bool
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Button { scale = max(0.65, scale - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { scale = min(1.8, scale + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                Button { isPinned.toggle() } label: { Image(systemName: isPinned ? "pin.fill" : "pin") }
            }
            .buttonStyle(.plain)

            content
                .scaleEffect(scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(12)
        .frame(width: 260, height: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(radius: 18)
        .offset(offset)
        .gesture(DragGesture().onChanged { offset = $0.translation })
    }
}
