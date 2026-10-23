import SwiftUI
import ClipSlotsKit

// MARK: - Group Tab Button
//
// 顶部「页面选择行」下方那排槽位组切换 tab（如「prompt」「📁1」）。
//
// v2.11.7 hotfix9：并入新拟物体系。这一行是 hotfix3～hotfix8 那几轮重做里**唯一被漏掉**的控件，
// 于是整个顶部 chrome 只有它还是老皮：半透明灰底 + 0.8pt 灰描边，选中态是裸写的
// `Color.accentColor.opacity(0.20)`。两个后果：
//   1. 简洁模式下冒出一块浅蓝——v2.11.7 hotfix1 定的规矩是「简洁模式里出现彩色 = 这里有状态」，
//      而选中态该用的是 `Neu.selectedFill`（近黑胶囊，与搜索行的「组内 / 全局」选中态同一语言），
//      不是品牌色。裸写 accentColor 也绕过了 AppTheme，皮肤切换根本管不到它。
//   2. 材质不一致：同一屏里「凸起 = 与画布同色 + 双层描边」，它却是「灰色薄片 + 一圈闭合描边」，
//      离得近时特别明显（它正下方就是卡片区、正上方就是新拟物页面选择器）。
//
// 交互反馈（按压微缩 / hover / 选中过渡，v2.10.77 起）与切组语义（store.switchSpecialSlot）不变，
// 只把材质换成 `neuRaised`；按压手势不消费点击，因此不阻塞 Button 响应。
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
            // 选中 = 近黑胶囊上的反相字（多彩模式是品牌渐变上的白字），静息 = 画布同色上的正文墨色。
            .foregroundColor(isCurrent ? Neu.sliderInk : Neu.ink)
            .padding(.horizontal, 10)
            .frame(height: NeumorphicMetrics.actionHeight)
            .contentShape(RoundedRectangle(cornerRadius: NeumorphicMetrics.actionRadius,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .neuRaised(radius: NeumorphicMetrics.actionRadius,
                   pressed: isPressing,
                   hovering: isHovering,
                   fill: isCurrent ? Neu.selectedFill : nil)
        .scaleEffect(isPressing ? 0.96 : 1)
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
}
