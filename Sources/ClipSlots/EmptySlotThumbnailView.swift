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

            // 空槽保存与提示文案恢复计划 P1：托盘图标下方补回简短动作提示，帮助发现「复制→保存」。
            // 纯展示，不进入正文/剪贴板/搜索/导出；次级色小字号，窄卡片自动缩小，最多两行。
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.42))
                Text("复制后，点击保存\n剪贴板为空也能先保存再编辑")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("empty-slot-hint")
            }
            .allowsHitTesting(false)
        }
        .frame(minHeight: 76, idealHeight: 88, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("空槽位")
        .help("保存剪贴板内容；剪贴板为空时创建可编辑的空白文本")
    }
}

/// 空槽保存计划 P2（v2.17.107）：「空白文本」占用态的预览——区别于未占用空槽，
/// 提示用户点击编辑开始填写。纯展示，不进入正文/剪贴板/搜索/导出。
struct BlankTextSlotThumbnailView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(.secondary.opacity(0.5))
            Text("还没有文字\n点击编辑，开始填写")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 8)
                .accessibilityIdentifier("blank-text-slot-hint")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("空白文本槽位，可编辑")
    }
}
