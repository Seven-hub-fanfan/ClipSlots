import SwiftUI
import ClipSlotsKit

/// 画布节点卡片（v2.11.7 · 版本 C2 极简浮动）。
///
/// 结构自上而下：类型标签行 → 预览区 → prompt → 参数芯片栏。对应架构文档 9.2。
///
/// 关于尺寸：卡片在**画布空间**是固定尺寸（`CanvasNode.defaultSize`），缩放由外层 `scaleEffect`
/// 统一施加。所以这里所有数值都按 1x 写，不要在内部再乘 zoom —— 那会导致文字与边框的缩放比例
/// 不一致（`scaleEffect` 是位图级缩放，内部再算一遍等于缩放两次）。
struct CanvasNodeCardView: View {
    let node: CanvasNode
    let isSelected: Bool

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    private var isEmptyPreview: Bool {
        if case .succeeded = node.state { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            typeRow
            previewArea
            promptArea
            paramChips
        }
        .padding(12)
        .frame(width: node.width, height: node.height, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardBackground(isEmpty: false))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor, lineWidth: isSelected ? 1.6 : 1)
        )
        .shadow(color: AppTheme.cardShadow(isEmpty: false),
                radius: isSelected ? 12 : 7,
                x: 0, y: isSelected ? 5 : 3)
        .onHover { isHovering = $0 }
    }

    private var borderColor: Color {
        if isSelected { return AppTheme.chromeAccentInk.opacity(0.85) }
        if isHovering { return AppTheme.minimalCardHoverBorder }
        return AppTheme.subtleBorder
    }

    // MARK: - 类型标签行

    private var typeRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: node.kind.symbolName)
                    .font(.system(size: 9, weight: .semibold))
                Text(node.kind.displayName)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(AppTheme.chromeAccentInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous).fill(AppTheme.chromeAccentSoftFill)
            )

            Spacer(minLength: 0)

            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch node.state {
        case .idle:
            Text("未生成")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary.opacity(0.7))
        case .queued(let ahead):
            // 「前方 N 个」用的是 CLI 真字段 queue_ahead_count，不是估算。
            Label(ahead > 0 ? "排队 · 前方 \(ahead)" : "排队中", systemImage: "clock")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
        case .running(let startedAt):
            // 刻意不给百分比：CLI 不提供，编出来的进度在 10~20s 量级会明显失真。
            RunningBadge(startedAt: startedAt)
        case .succeeded:
            Label("已生成", systemImage: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.green.opacity(0.85))
        case .failed:
            Label("失败", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.red.opacity(0.85))
        }
    }

    // MARK: - 预览区

    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.previewBackground)

            if isEmptyPreview {
                // 斜纹占位（对齐 C2 设计稿）：未生成状态一眼可辨，且不像「加载失败」。
                DiagonalHatch()
                    .stroke(AppTheme.subtleBorder.opacity(0.55), lineWidth: 1)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if case .failed(let reason) = node.state {
                    VStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 14, weight: .semibold))
                        Text(reason)
                            .font(.system(size: 9))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.red.opacity(0.75))
                    .padding(.horizontal, 8)
                } else {
                    Image(systemName: node.kind == .video ? "film" : "photo")
                        .font(.system(size: 18, weight: .light))
                        .foregroundColor(.secondary.opacity(0.35))
                }
            } else if case .succeeded(let path) = node.state,
                      let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(height: 148)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.subtleBorder.opacity(0.6), lineWidth: 0.5)
        )
    }

    // MARK: - prompt

    private var promptArea: some View {
        Group {
            if node.prompt.isEmpty {
                Text("点击填写提示词…")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.5))
            } else {
                Text(node.prompt)
                    .font(.system(size: 10))
                    .foregroundColor(.primary.opacity(0.82))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 参数芯片栏

    private var paramChips: some View {
        HStack(spacing: 4) {
            chip(node.model)
            chip(node.ratio)
            if node.count > 1 { chip("×\(node.count)") }
            Spacer(minLength: 0)
            if let label = node.sourceLabel, !label.isEmpty {
                // 溯源标记：这个节点来自哪个槽位。只读，不产生任何写回。
                HStack(spacing: 2) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 7, weight: .semibold))
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(.secondary.opacity(0.6))
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(AppTheme.chipBackground)
            )
    }
}

// MARK: - 生成中角标

/// 已用秒数会自己走字。用独立小视图承载 `TimelineView`，避免每秒重绘整张卡片。
private struct RunningBadge: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(spacing: 3) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 8, height: 8)
                Text("生成中 \(elapsed)s")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - 斜纹占位

/// 45° 斜纹填充。用 Shape 而不是贴图，缩放时始终清晰。
struct DiagonalHatch: Shape {
    var spacing: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard spacing > 0, rect.width > 0, rect.height > 0 else { return p }
        var x = -rect.height
        var guardCount = 0
        while x < rect.width && guardCount < 600 {
            p.move(to: CGPoint(x: rect.minX + x, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + x + rect.height, y: rect.minY))
            x += spacing
            guardCount += 1
        }
        return p
    }
}
