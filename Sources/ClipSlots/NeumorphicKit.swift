import SwiftUI
import AppKit
import ClipSlotsKit

// MARK: - 新拟物组件套件（v2.11.8）
//
// 工具栏（搜索行 + 操作行）与自动存储/粘贴开关面板按新拟物（Neumorphism）设计稿重做。
// 这里只放**可复用的表面**：浮动面板、凸起、内凹，以及基于它们的两个复合控件
// （分段范围选择器、垂直开关）。业务视图只负责往上挂内容，不再各自手写渐变和阴影。
//
// 三条实现约定，改之前请先看完：
//
// 1) **光源固定在左上。** 凸起 = 右下投深影 + 左上打亮；内凹 = 上沿压暗 + 下沿透亮。
//    整个界面只允许有一个光源方向，否则新拟物会立刻显出「贴纸感」。所有偏移量都写死在
//    `NeumorphicMetrics`，不要在调用点各自传 offset。
//
// 2) **内凹的内阴影是手搓的。** SwiftUI 到 macOS 14 才有 `.fill(style.shadow(.inner))`，
//    本项目最低支持 macOS 13（见 Package.swift），所以内阴影用「描边 + 模糊 + 渐变遮罩」
//    的老办法实现：沿形状描一圈粗边，模糊后用上→下的渐变遮罩只留上半，就得到从上沿
//    渗进来的暗影；再反向来一次得到下沿的亮边。这比叠两个半透明矩形稳，因为它天然贴合圆角。
//
// 3) **颜色全部走 `NeumorphicPalette`，几何全部走 `NeumorphicMetrics`。** 两种皮肤共用几何、
//    只分颜色（多彩模式在同样的凹凸上掺品牌蓝紫、选中态用渐变）。皮肤差异不允许改尺寸——
//    v2.11.7 hotfix2d 已经因为「两种皮肤几何不一致」返工过一次。

enum Neu {

    // MARK: - 颜色

    /// 当前皮肤 + 明暗下的一套表面色。
    ///
    /// 注意这里返回的是**当次求值时**的静态取值，而不是动态色：`AppSkinCenter.current` 是
    /// App 自己的状态，NSColor 的动态解析回调只感知系统 appearance、感知不到它
    /// （v2.11.7 踩过这个坑）。皮肤切换靠 ContentView 上的 `.id(appSkinRaw)` 整树重建，
    /// 明暗切换则由下面每个 token 各自的 `dyn` 动态色负责。
    private static var skin: AppSkin { AppSkinCenter.current }

    private static func dyn(_ keyPath: KeyPath<NeumorphicPalette.Surfaces, NeumorphicPalette.RGB>) -> Color {
        let lightNS = NSColor(color(NeumorphicPalette.surfaces(skin: skin, dark: false)[keyPath: keyPath]))
        let darkNS = NSColor(color(NeumorphicPalette.surfaces(skin: skin, dark: true)[keyPath: keyPath]))
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkNS : lightNS
        })
    }

    private static func color(_ rgb: NeumorphicPalette.RGB) -> Color {
        Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }

    /// 画布 = 工具栏的承载面（hotfix4 起工具栏不再有自己的面板底）。
    static var ground: Color { dyn(\.ground) }
    /// 凸起控件表面。hotfix5 起与 `ground` 同色——边界由双色投影定义，不由色差定义。
    static var raised: Color { dyn(\.raised) }
    static var well: Color { dyn(\.well) }
    static var wellShade: Color { dyn(\.wellShade) }
    static var sliderFill: Color { dyn(\.sliderFill) }
    static var sliderInk: Color { dyn(\.sliderInk) }
    static var ink: Color { dyn(\.ink) }
    static var subtleInk: Color { dyn(\.subtleInk) }
    static var dangerFill: Color { dyn(\.dangerFill) }
    static var dangerInk: Color { dyn(\.dangerInk) }

    /// 右下柔和投影。设计稿：黑 8%～10%、大模糊。浅色档取 9%——再深就从「柔和阴影」
    /// 变成「深色描边」，按钮又浮起来了；深色档环境本身就黑，必须给到 55% 才看得出层次。
    static var dropShadow: Color {
        AppTheme.isDarkAppearance ? Color.black.opacity(0.55) : Color.black.opacity(0.09)
    }

    /// 左上高光。设计稿：白 80%。深色档没有「更亮的白」可用，用低透明白点一下边缘即可。
    static var lightShadow: Color {
        AppTheme.isDarkAppearance ? Color.white.opacity(0.07) : Color.white.opacity(0.8)
    }

    /// 内凹的**上/左内阴影**（设计稿：黑 8%）与**下/右内高光**（设计稿：白 60%）。
    /// 深色档同样要放大：黑底上 8% 的黑等于什么都没有。
    static var wellInnerShadow: Color {
        AppTheme.isDarkAppearance ? Color.black.opacity(0.65) : Color.black.opacity(0.08)
    }
    static var wellInnerGlow: Color {
        AppTheme.isDarkAppearance ? Color.white.opacity(0.06) : Color.white.opacity(0.6)
    }

    /// 凸起控件的**极弱**收边。
    ///
    /// 设计稿里按钮没有描边，边界纯靠光影。浅色档给到黑 3%（低于用户要求的 0.05 上限）只为
    /// 在纯白系统背景等极端情况下不至于完全化开；深色档必须留 8% 白——那里可用的「白高光」
    /// 只有 7%，光靠黑投影压不出边缘，去掉描边按钮会直接消失在黑底里。
    static var raisedEdge: Color {
        AppTheme.isDarkAppearance ? Color.white.opacity(0.08) : Color.black.opacity(0.03)
    }

    /// 面板描边。浅色档几乎不可见，只用来收边；深色档承担主要的轮廓感。
    static var hairline: Color {
        AppTheme.isDarkAppearance ? Color.white.opacity(0.07) : Color.black.opacity(0.045)
    }

    /// 面板**内部**的分区细线。比 `hairline` 实一档：收边线可以近乎隐形，
    /// 但「把一块面板分成左右两区」这件事必须真的看得见，否则两组开关会读成一堆四个控件。
    static var hairlineStrong: Color {
        AppTheme.isDarkAppearance ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }

    /// 选中滑块的填充。简洁模式是单色近黑（深色档反相），多彩模式换成品牌渐变。
    static var selectedFill: AnyShapeStyle {
        if AppTheme.isMinimalSkin {
            return AnyShapeStyle(sliderFill)
        }
        return AnyShapeStyle(LinearGradient(
            colors: [sliderFill, sliderFill.opacity(0.82)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
    }

    /// 凸起表面的填充。hotfix5 起是**纯色**且与画布同色。
    ///
    /// 原来这里是「高光色 → 主色」的竖向渐变，想靠渐变造体积感。但渐变的上端是纯白，
    /// 等于又把色差请回来了：按钮顶部比画布亮一大截，仍然读成「叠在上面的薄片」。
    /// 体积感现在完全交给双色投影，填充必须老老实实与底板同色。
    static var raisedFill: Color { raised }
}

// MARK: - 表面 1/2：凸起
//
// v2.11.7 hotfix4: 原来这里还有第三种表面 `NeuPanelBackground`（白色大圆角浮动面板 +
// 外阴影），工具栏和开关簇都挂在它上面。用户的判断很准：那块面板把工具栏做成了一个
// **独立悬浮块**，和下面的卡片区分成两层，界面被生生切开。新拟物本来就有两种读法——
// 「一块浮起来的板」和「同一张面上凹下去 / 凸起来」——设计稿走的其实是后者，
// 我照着做成了前者。现在整块面板连同它的外阴影一起删掉：工具栏直接坐在画布上，
// 只保留控件自身的凹凸（内凹搜索框 / 微凸按钮），层级感由控件表达，而不是由一块板表达。

// MARK: - 表面 1/2：凸起

/// 微凸表面：**与底板同色**的填充 + 左上白高光 + 右下柔投影。按下时两道投影一起收敛（“压平”）。
///
/// v2.11.7 hotfix5 把这里从「白薄片 + 灰描边 + 垂直投影」改成真正的新拟物：
///   - 填充与画布同色（见 `NeumorphicPalette.Surfaces.raised` 的注释）
///   - 描边从 0.8pt 的 `hairline` 降到 0.5pt 的 `raisedEdge`（浅色 3% 黑，几乎不可见）
///   - 投影从 (0, 3)/radius 5 改成 (4, 4)/radius 6，高光补上 (-2, -2)/radius 2 的白 80%
/// 这三件事缺任何一件，按钮都会退回「浮在上面」的观感。
struct NeuRaisedBackground: View {
    var radius: CGFloat = NeumorphicMetrics.actionRadius
    var pressed: Bool = false
    var hovering: Bool = false
    /// 传入非 nil 时用它替换默认的凸起填充（例如危险操作的淡红底）。
    var fill: AnyShapeStyle? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let scale = pressed ? NeumorphicMetrics.pressedShadowScale : 1
        let hoverBoost: CGFloat = hovering ? 1.25 : 1
        shape
            .fill(fill ?? AnyShapeStyle(Neu.raisedFill))
            .overlay(shape.strokeBorder(Neu.raisedEdge, lineWidth: 0.5))
            // 悬停时把投影推远一点点：新拟物里「浮得更高」比「变个颜色」更贴合材质语言。
            .shadow(color: Neu.dropShadow,
                    radius: NeumorphicMetrics.dropShadowRadius * scale * hoverBoost,
                    x: NeumorphicMetrics.dropShadowOffsetX * scale * hoverBoost,
                    y: NeumorphicMetrics.dropShadowOffsetY * scale * hoverBoost)
            .shadow(color: Neu.lightShadow,
                    radius: NeumorphicMetrics.highlightShadowRadius * scale,
                    x: NeumorphicMetrics.highlightShadowOffsetX * scale,
                    y: NeumorphicMetrics.highlightShadowOffsetY * scale)
    }
}

// MARK: - 表面 3/3：内凹

/// 内凹容器：左上渗入暗影、右下透出亮边，看起来像陷进底板里。
///
/// 实现见文件头第 2 条约定（macOS 13 没有原生 inner shadow）：用「描边 + 高斯模糊 + 方向渐变
/// mask」手搓。hotfix5 按设计稿把方向从「纯上/纯下」改成**左上 / 右下对角**，和按钮的双色投影
/// 共用同一个光源；同时去掉外圈那道 `hairline` 描边——内凹的边界应该由内阴影自己交代，
/// 描一圈灰边等于把「凹陷」画成「一个有边框的浅色块」，这正是之前搜索框没有内陷感的原因。
struct NeuWellBackground: View {
    var radius: CGFloat = NeumorphicMetrics.searchRadius

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let d = NeumorphicMetrics.wellInnerOffset
        shape
            .fill(Neu.well)
            // 左上内阴影：黑 8%、offset (+2, +2)、blur 5。offset 为正 = 阴影从左上边缘往内渗。
            .overlay(
                shape
                    .stroke(Neu.wellInnerShadow, lineWidth: d * 2)
                    .blur(radius: NeumorphicMetrics.wellInnerRadius)
                    .offset(x: d, y: d)
                    .mask(shape.fill(LinearGradient(colors: [.black, .clear],
                                                    startPoint: .topLeading,
                                                    endPoint: .center)))
            )
            // 右下内高光：白 60%、offset (-2, -2)、blur 5。凹陷的下沿正对着光源的反射面。
            .overlay(
                shape
                    .stroke(Neu.wellInnerGlow, lineWidth: d * 2)
                    .blur(radius: NeumorphicMetrics.wellInnerRadius)
                    .offset(x: -d, y: -d)
                    .mask(shape.fill(LinearGradient(colors: [.clear, .black],
                                                    startPoint: .center,
                                                    endPoint: .bottomTrailing)))
            )
            // 只保留最内圈那条极暗的收口（wellShade），它是「凹进去的那道坎」，不是描边：
            // 宽 0.6pt 且只出现在上半圈，不会形成闭合边框。
            .overlay(
                shape
                    .stroke(Neu.wellShade.opacity(AppTheme.isDarkAppearance ? 0.5 : 0.35),
                            lineWidth: 0.6)
                    .mask(shape.fill(LinearGradient(colors: [.black, .clear],
                                                    startPoint: .topLeading,
                                                    endPoint: .center)))
            )
            .clipShape(shape)
    }
}

// MARK: - 便捷修饰器

extension View {
    /// 挂成微凸控件。
    func neuRaised(radius: CGFloat = NeumorphicMetrics.actionRadius,
                   pressed: Bool = false,
                   hovering: Bool = false,
                   fill: AnyShapeStyle? = nil) -> some View {
        background(NeuRaisedBackground(radius: radius, pressed: pressed, hovering: hovering, fill: fill))
    }

    /// 挂成内凹容器。
    func neuWell(radius: CGFloat = NeumorphicMetrics.searchRadius) -> some View {
        background(NeuWellBackground(radius: radius))
    }

    /// 图标按钮：固定边长的凸起圆角方块。
    func neuIconTile(hovering: Bool = false) -> some View {
        frame(width: NeumorphicMetrics.iconTileSize, height: NeumorphicMetrics.iconTileSize)
            .neuRaised(radius: NeumorphicMetrics.iconTileRadius, hovering: hovering)
    }
}

// MARK: - 复合控件 1/2：分段范围选择器

/// 分段控件的一项。刻意用 struct 而不是元组：Swift 至今不支持指向元组成员的 KeyPath，
/// 而 `ForEach(_:id:)` 需要的正是一个 KeyPath。
struct NeuSegment<T: Hashable>: Identifiable {
    let value: T
    let title: String
    var id: T { value }
}

/// 「组内 / 全局」分段控件的新拟物版：内凹轨道 + 黑色（多彩模式：品牌渐变）凸起滑块。
///
/// 顺带解决一个性能旧账：原实现是 `Picker(.segmented)`，即 AppKit 的 NSSegmentedControl。
/// SlotSearchBar 的文件头注释里记着——`ViewThatFits` 测量 AppKit 控件时会真的实例化 platform view，
/// 是当年「窗口 resize 跟不上鼠标」的元凶之一。换成纯 SwiftUI 后，这一格的测量成本降为常数。
struct NeuSegmentedControl<T: Hashable>: View {
    let options: [NeuSegment<T>]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = option.value == selection
                Text(option.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? Neu.sliderInk : Neu.subtleInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: NeumorphicMetrics.segmentHeight - NeumorphicMetrics.segmentInset * 2)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: (NeumorphicMetrics.segmentHeight - NeumorphicMetrics.segmentInset * 2) / 2,
                                             style: .continuous)
                                .fill(Neu.selectedFill)
                                .shadow(color: Neu.dropShadow, radius: 3, y: 1.5)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Anim.interactive) { selection = option.value }
                    }
            }
        }
        .padding(NeumorphicMetrics.segmentInset)
        .frame(height: NeumorphicMetrics.segmentHeight)
        .neuWell(radius: NeumorphicMetrics.segmentHeight / 2)
    }
}

// MARK: - 复合控件 2/2：垂直开关

/// 垂直滑块开关：内凹滑道 + 黑色圆角滑块（中心一道白横杠），向上为开、向下为关。
///
/// 这是 v2.10.0 起沿用的「金属拨杆」的替代品。语义完全一致（点击切换、两档、上开下关），
/// 换的只是材质：金属拨杆的高光/斜面在新拟物的哑光面板上显得格外突兀，是当前工具栏里
/// 唯一还带「拟真金属」质感的元素。
struct NeuVerticalSwitch: View {
    @Binding var isOn: Bool
    /// 开启时状态点的颜色（绿 = 自动存储、蓝 = 自动粘贴，与游标角标同色）。
    let statusColor: Color
    let label: String
    var help: String? = nil

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isOn ? statusColor : Neu.subtleInk.opacity(0.45))
                    .frame(width: 5, height: 5)
                    .shadow(color: isOn ? statusColor.opacity(0.7) : .clear, radius: 2.5)
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isOn ? Neu.ink : Neu.subtleInk)
                    .fixedSize()
            }

            ZStack {
                RoundedRectangle(cornerRadius: NeumorphicMetrics.switchTrackWidth / 2, style: .continuous)
                    .fill(Color.clear)
                    .frame(width: NeumorphicMetrics.switchTrackWidth,
                           height: NeumorphicMetrics.switchTrackHeight)
                    .neuWell(radius: NeumorphicMetrics.switchTrackWidth / 2)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn ? Neu.selectedFill : AnyShapeStyle(Neu.raisedFill))
                    .frame(width: NeumorphicMetrics.switchKnobWidth,
                           height: NeumorphicMetrics.switchKnobHeight)
                    .overlay(
                        // 滑块中心的横杠：开时用滑块的反相色，关时用次要墨色——它是「滑块朝哪」之外
                        // 第二个可读的开关信号，弱光下比位移更容易被注意到。
                        Capsule()
                            .fill(isOn ? Neu.sliderInk : Neu.subtleInk)
                            .frame(width: 9, height: 2)
                    )
                    .shadow(color: Neu.dropShadow, radius: 3, y: 1.5)
                    .offset(y: isOn ? -NeumorphicMetrics.switchTravel : NeumorphicMetrics.switchTravel)
                    .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isOn)
            }
        }
        .contentShape(Rectangle())
        .scaleEffect(isHovering ? 1.03 : 1)
        .animation(Anim.interactive, value: isHovering)
        .onHover { isHovering = $0 }
        .onTapGesture { isOn.toggle() }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "开" : "关")
        .accessibilityAddTraits(.isButton)
        .help(help ?? label)
    }
}

// MARK: - 迷你按钮（回退 / 重置）

/// 开关面板底部的小凸起按钮。
struct NeuMiniButton: View {
    let title: String
    let icon: String
    var tint: Color? = nil
    var enabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    // 截图里「回退」被压成了「…」：这两颗按钮的可用宽度由上方开关那一列决定
                    // （滑道只有 26pt 宽），不锁住理想宽度就会被 SwiftUI 判定为可截断的文本。
                    .fixedSize()
            }
            // 简洁模式下按钮文字一律走中性墨色：状态色只保留在顶部状态点上（功能性），
            // 「回退 / 重置」的字色属于装饰性上色，简洁模式必须收掉。
            .foregroundColor(enabled ? ((AppTheme.isMinimalSkin ? nil : tint) ?? Neu.ink)
                                     : Neu.subtleInk.opacity(0.6))
            .padding(.horizontal, 7)
            .frame(height: 20)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .neuRaised(radius: 7, hovering: isHovering && enabled)
        .onHover { isHovering = $0 }
    }
}
