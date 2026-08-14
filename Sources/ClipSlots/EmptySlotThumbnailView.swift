import SwiftUI
import ClipSlotsKit

/// A fixed-height empty slot placeholder that never has any @State image to leak.
struct EmptySlotThumbnailView: View {

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.slotPreviewCornerRadius, style: .continuous)
                .fill(AppTheme.previewBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.slotPreviewCornerRadius, style: .continuous)
                        .strokeBorder(AppTheme.subtleBorder.opacity(0.65), lineWidth: 1)
                )
                .allowsHitTesting(false)

            VStack(spacing: 7) {
                Image(systemName: "tray")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.42))
                Text("空槽位 · 复制后按保存键存入")
                    .font(AppTheme.Fonts.footnote)
                    .foregroundColor(.secondary.opacity(0.64))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 12)
        }
        .frame(minHeight: 76, idealHeight: 88, maxHeight: .infinity)
    }
}
