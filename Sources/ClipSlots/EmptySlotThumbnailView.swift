import SwiftUI

/// A fixed-height empty slot placeholder that never has any @State image to leak.
struct EmptySlotThumbnailView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))

            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary.opacity(0.4))
                Text("空槽位")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(height: 140)
    }
}
