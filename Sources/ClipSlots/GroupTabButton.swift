import SwiftUI

// MARK: - Group Tab Button (v2.10.77)
//
// 顶部「页面选择行」下方那排槽位组切换 tab（如「默认槽位组」「📁1」）。在保持点击切组
// 语义不变（action 仍调用 store.switchSpecialSlot）的前提下，补齐三类交互反馈：
//   • 按压微缩：按下 scaleEffect 0.94、松手回弹，仿 ToggleLeverView（v2.10.76）的
//     simultaneousGesture(DragGesture(minimumDistance:0)) 写法，用 Anim.interactive。
//   • hover 高亮：指针悬停时底色 / 边框轻微加深，用 .onHover + Anim.interactive。
//   • 选中态过渡：当前选中组的高亮背景切换用 Anim.status 平滑过渡，避免生硬跳变。
//
// 手势只捕捉按下/松手状态驱动微缩（不消费点击），因此不阻塞或延迟 Button 的切组响应。
struct GroupTabButton: View {
    let name: String
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovering = false
    @GestureState private var isPressing = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isCurrent ? "folder.fill" : "folder")
                    .font(.system(size: 11, weight: .semibold))
                Text(name)
            }
            .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(strokeColor, lineWidth: isCurrent ? 1.2 : 0.8)
            )
            .scaleEffect(isPressing ? 0.94 : 1)
        }
        .buttonStyle(.plain)
        .animation(Anim.status, value: isCurrent)
        .animation(Anim.interactive, value: isHovering)
        .animation(Anim.interactive, value: isPressing)
        .onHover { isHovering = $0 }
        .simultaneousGesture(
            // 仅捕捉按下/松手以驱动按压微缩；minimumDistance 0 且不消费点击，
            // 不影响 Button(action:) 的切组行为。
            DragGesture(minimumDistance: 0)
                .updating($isPressing) { _, state, _ in state = true }
        )
    }

    private var backgroundFill: Color {
        if isCurrent { return Color.accentColor.opacity(0.20) }
        return Color.primary.opacity(isHovering ? 0.10 : 0.055)
    }

    private var strokeColor: Color {
        if isCurrent { return Color.accentColor.opacity(0.50) }
        return Color.secondary.opacity(isHovering ? 0.30 : 0.16)
    }
}
