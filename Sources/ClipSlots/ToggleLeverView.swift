import SwiftUI

// MARK: - Toggle Lever View (v2.10.0)
//
// 金属拨杆控件：物理摇杆质感，向上拨为开、向下拨为关（两档），顶部圆形指示灯
// （开 = 绿色发光，关 = 暗灰）。点击整块底座切换，带弹性 rotation 动画。
//
// 用法：
//   ToggleLeverView(isOn: $store.autoStoreEnabled, label: "自动存储")
struct ToggleLeverView: View {
    @Binding var isOn: Bool
    let label: String
    /// 可选副标题/提示（当前用于无障碍描述）。
    var help: String? = nil
    /// v2.10.1: 指示灯颜色（开启时发光色）。默认绿色；toolbar 里按拨杆语义分别传入
    /// 绿色（自动存储，与写游标角标一致）/ 蓝色（自动粘贴，与读游标角标一致）/ 黄色（自动切换）。
    var indicatorColor: Color = .green

    // 尺寸常量（紧凑，适配 toolbar）。
    private let baseWidth: CGFloat = 26
    private let baseHeight: CGFloat = 34
    private let leverWidth: CGFloat = 9
    private let leverHeight: CGFloat = 22

    var body: some View {
        VStack(spacing: 3) {
            indicatorLight

            leverBase

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(isOn ? .primary : .secondary)
                .fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
                isOn.toggle()
            }
        }
        .help(help ?? (isOn ? "\(label)：已开启" : "\(label)：已关闭"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "开启" : "关闭")
        .accessibilityAddTraits(.isButton)
    }

    // 顶部圆形指示灯：开 = indicatorColor 发光，关 = 暗灰。
    private var indicatorLight: some View {
        Circle()
            .fill(
                isOn
                    ? AnyShapeStyle(RadialGradient(
                        colors: [indicatorColor.opacity(0.8), indicatorColor],
                        center: .center, startRadius: 0, endRadius: 5))
                    : AnyShapeStyle(Color.gray.opacity(0.35))
            )
            .frame(width: 7, height: 7)
            .overlay(
                Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: isOn ? indicatorColor.opacity(0.8) : .clear, radius: isOn ? 4 : 0)
            .animation(.easeInOut(duration: 0.2), value: isOn)
    }

    // 金属底座 + 拨杆主体。
    private var leverBase: some View {
        ZStack {
            // 圆角矩形金属底座（灰白渐变）。
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: 0.92),
                            Color(white: 0.72),
                            Color(white: 0.85),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.black.opacity(0.22), lineWidth: 0.75)
                )
                .frame(width: baseWidth, height: baseHeight)
                .shadow(color: Color.black.opacity(0.18), radius: 1.5, x: 0, y: 1)

            // 拨杆主体：金属渐变小长条，绕底座中心旋转（上拨 +，下拨 -）。
            RoundedRectangle(cornerRadius: leverWidth / 2, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: 0.98),
                            Color(white: 0.78),
                            Color(white: 0.6),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: leverWidth / 2, style: .continuous)
                        .stroke(Color.black.opacity(0.28), lineWidth: 0.6)
                )
                .frame(width: leverWidth, height: leverHeight)
                // 让长条一端固定在底座中心，另一端摆动：先把锚点下移半个身位再旋转。
                .offset(y: -leverHeight / 2 + 3)
                .rotationEffect(.degrees(isOn ? -20 : 20), anchor: .bottom)
                .offset(y: leverHeight / 2 - 3)
                .shadow(color: Color.black.opacity(0.25), radius: 1, x: 0, y: 0.5)
        }
        .frame(width: baseWidth, height: baseHeight)
    }
}
