import SwiftUI

/// v2.7.10: reusable preview panel for the radial menu.
/// v2.7.11: independent NSPanel handles drag/resize — no more SwiftUI offset/gesture.
struct RadialPreviewPanel: View {
    let title: String
    let subtitle: String
    let content: AnyView
    @Binding var isPinned: Bool
    @State private var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Button { scale = max(0.75, scale - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { scale = min(1.6, scale + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                Button { isPinned.toggle() } label: { Image(systemName: isPinned ? "pin.fill" : "pin") }
            }
            .buttonStyle(.plain)

            content
                .scaleEffect(scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(12)
        .frame(minWidth: 260, minHeight: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(radius: 18)
    }
}

// MARK: - v2.7.11 Live Preview Content

struct RadialLivePreviewContent: View {
    @ObservedObject var store: SlotStoreObservable
    @State private var hoveredSlot: Int?

    var body: some View {
        Group {
            if let slot = hoveredSlot, let content = store.slots[slot], !content.isEmpty {
                SlotPreviewView(content: content)
                    .id(slot)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "eye")
                        .font(.system(size: 34))
                        .foregroundColor(.secondary)
                    Text("悬停槽位查看预览")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .radialMenuHoveredSlotChanged)) { note in
            hoveredSlot = note.object as? Int
        }
    }
}
