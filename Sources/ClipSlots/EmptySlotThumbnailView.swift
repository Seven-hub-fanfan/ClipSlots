import SwiftUI
import ClipSlotsKit

/// A fixed-height empty slot placeholder that never has any @State image to leak.
struct EmptySlotThumbnailView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.04))

            // v2.9.22: 空槽占位收紧——缩小图标、说明并为一行，减少高度浪费，让 10 个槽位少滚动。
            VStack(spacing: 4) {
                Image(systemName: "tray")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary.opacity(0.4))
                Text("空槽位 · 复制后按保存键存入")
                    .font(AppTheme.Fonts.footnote)
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 8)
        }
        // v2.9.22: 空槽占位高度从 120/160 收紧到 68/78，配合有内容卡片一起降低整体卡片高度。
        .frame(minHeight: 68, idealHeight: 78, maxHeight: .infinity)
    }
}
