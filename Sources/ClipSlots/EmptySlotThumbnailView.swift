import SwiftUI
import ClipSlotsKit

/// A fixed-height empty slot placeholder that never has any @State image to leak.
struct EmptySlotThumbnailView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.04))

            VStack(spacing: AppTheme.spacingSmall) {
                Image(systemName: "tray")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary.opacity(0.4))
                Text("空槽位")
                    .font(AppTheme.Fonts.caption)
                    .foregroundColor(.secondary)
                Text("复制内容后按保存快捷键存入")
                    .font(AppTheme.Fonts.footnote)
                    .foregroundColor(.secondary.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)
        }
        // v2.9.18: 空槽占位改自适应高度，与有内容卡片对齐，避免同排高度参差。
        .frame(minHeight: 120, idealHeight: 160, maxHeight: .infinity)
    }
}
