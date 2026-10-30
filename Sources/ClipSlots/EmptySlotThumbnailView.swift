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

            Image(systemName: "tray")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(.secondary.opacity(0.42))
        }
        .frame(minHeight: 76, idealHeight: 88, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("空槽位")
        .help("复制内容后，点击保存或使用保存快捷键存入")
    }
}
