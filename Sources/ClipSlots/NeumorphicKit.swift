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
// 2) **这里一个外部 Drop Shadow 都不许有（v2.11.7 hotfix8）。** 整套凹凸只用「长在形状边界上的
//    描边」表达：凸起 = 右下暗边（侧面厚度）+ 左上白亮边（受光棱）；内凹 = 上/左内暗边 + 下/右内亮边。
//    外投影表达的是「物体离背后的平面有一段距离」，也就是**悬浮**——hotfix5/6/7 三轮都在调它的
//    浓度 / blur / 对称性，用户三次的反馈都是「还是漂浮」，因为那是手段本身的语义，不是参数问题。
//    改这个文件时如果手又伸向 `.shadow(...)`，先回头看这条。
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

    /// 把「浅色一档 / 深色一档」包成**动态色**（NSColor dynamicProvider）。
    ///
    /// ⚠️ v2.11.7 hotfix6 的核心修复点。原来这些半透明的阴影 / 描边 token 写成
    /// `AppTheme.isDarkAppearance ? A : B`，也就是在**body 求值那一刻**读 `NSApp.effectiveAppearance`
    /// 把结果**烘死**进视图里。两个后果，正好对上用户报的两个现象：
    ///
    ///   1. **新开 App 工具栏漂浮**：SwiftUI 的第一帧比 `applicationDidFinishLaunching` 里的
    ///      `applyAppAppearance()` 更早发生，此时 `NSApp.effectiveAppearance` 还不是用户设定的浅色
    ///      （App 默认主题是深色）。于是首帧按钮拿到的是**深色档的投影**：黑 55% / radius 6 / (4,4)
    ///      ——在浅色画布上就是一坨浓重的外投影，正是「悬浮漂浮」的观感。
    ///   2. **手动切一次皮肤就正常、但阴影变少**：切皮肤会让 `.id(skin)` 整树重建，重建时
    ///      appearance 已经正确，token 重新算成浅色档的黑 9%——「正常了」和「阴影少了一些」
    ///      其实是同一件事：前者是错的（55%），后者才是设计值（9%）。
    ///
    /// 包成动态色后，明暗解析交给 AppKit 在**绘制时**做，与 body 何时求值彻底解耦：首帧就是对的，
    /// 也不会因为重建而改变。表面色（ground/raised/well…）一直走的就是这条路，所以它们从来没出过这个问题。
    private static func dynAlpha(light: Color, dark: Color) -> Color {
        let lightNS = NSColor(light)
        let darkNS = NSColor(dark)
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

    // v2.11.7 hotfix8: `dropShadow` / `lightShadow` 两个**外部投影**色 token 已删除。
    // 理由见 `NeumorphicMetrics` 的「纯描边浮雕」注释：外投影表达的是「离底板有一段距离」，
    // 也就是悬浮；无论怎么调浓度 / blur / 对称性，都改不掉这层语义。凸起感现在完全由
    // `edgeThickness`（右下暗边）+ `edgeHighlight`（左上白亮边）表达，它们长在形状边界上，
    // 不占形状之外任何一个像素，所以只能读成「厚度」。

    /// 内凹的**上/左内暗边**与**下/右内亮边**。hotfix8 起不再模糊：
    /// 描边直接画在形状内沿，凹陷靠「上暗下亮」这对方向相反的硬边表达。
    static var wellInnerShadow: Color {
        dynAlpha(light: Color.black.opacity(0.16), dark: Color.black.opacity(0.7))
    }
    static var wellInnerGlow: Color {
        dynAlpha(light: Color.white.opacity(0.9), dark: Color.white.opacity(0.10))
    }
    /// 内凹最内圈那道收口的浓度（深色档要更实）。同样必须是动态色，理由见 `dynAlpha`。
    static var wellRimOpacity: Color {
        dynAlpha(light: wellShade.opacity(0.35), dark: wellShade.opacity(0.5))
    }

    /// 凸起控件的**右下暗边**：凸起物背光那一侧的侧面。设计稿 image-ec308b07 = 黑 18%。
    /// 这是 hotfix8 起「体积感」的主要承载者（外部投影已全部删除）。
    static var edgeThickness: Color {
        dynAlpha(light: Color.black.opacity(0.18), dark: Color.black.opacity(0.6))
    }

    /// 凸起控件的**左上白亮边**：受光的棱。设计稿 = 白 85%、比暗边细、内缩压在轮廓内侧。
    /// 深色档没有「纯白受光面」可言，压到 16% 只留一线，否则按钮会像描了圈白框。
    static var edgeHighlight: Color {
        dynAlpha(light: Color.white.opacity(0.85), dark: Color.white.opacity(0.16))
    }

    /// 面板描边。浅色档几乎不可见，只用来收边；深色档承担主要的轮廓感。
    static var hairline: Color {
        dynAlpha(light: Color.black.opacity(0.045), dark: Color.white.opacity(0.07))
    }

    /// 面板**内部**的分区细线。比 `hairline` 实一档：收边线可以近乎隐形，
    /// 但「把一块面板分成左右两区」这件事必须真的看得见，否则两组开关会读成一堆四个控件。
    static var hairlineStrong: Color {
        dynAlpha(light: Color.black.opacity(0.10), dark: Color.white.opacity(0.12))
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

/// 微凸表面：**与画布严格同色**的填充 + 右下暗边（侧面厚度）+ 左上白亮边（受光棱）。
/// 没有任何外部投影。
///
/// v2.11.7 hotfix8 —— 第四次返工，这次换的是**手段**而不是参数。
/// hotfix5/6/7 分别调过投影浓度、补过描边、把双色投影改成严格镜像，用户三次的判断都一样：
/// 「还是漂浮」。因为外部投影的语义就是「物体和它背后的平面之间有距离」；只要它在，缝隙就在。
/// 设计稿 image-ec308b07 里按钮周围一片干净，凸起完全由两条长在边界上的边表达。
///
/// 按下时两条边一起收敛到 `pressedEdgeScale`（= 压平），悬停时暗边略微加宽（= 抬高一点点）。
struct NeuRaisedBackground: View {
    var radius: CGFloat = NeumorphicMetrics.actionRadius
    var pressed: Bool = false
    var hovering: Bool = false
    /// 传入非 nil 时用它替换默认的凸起填充（例如危险操作的淡红底）。
    var fill: AnyShapeStyle? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let scale = pressed ? NeumorphicMetrics.pressedEdgeScale : 1
        let hoverBoost: CGFloat = hovering ? 1.35 : 1
        shape
            .fill(fill ?? AnyShapeStyle(Neu.raisedFill))
            // 顶面极微弱的受光渐变（上亮下暗，幅度 2.5%）。它是可选项，量不出来才算对：
            // 一旦看得出深浅，按钮就重新变成「一块颜色不同的薄片」。
            .overlay(
                shape.fill(LinearGradient(
                    colors: [Color.white.opacity(NeumorphicMetrics.raisedSheenOpacity),
                             Color.black.opacity(NeumorphicMetrics.raisedSheenOpacity)],
                    startPoint: .top, endPoint: .bottom))
            )
            // 右下暗边：凸起物背光的**侧面**。用方向渐变 mask 限制在右下半圈——
            // 描满一圈就成了边框，边框没有方向、也就没有光源。
            .overlay(
                shape
                    .strokeBorder(Neu.edgeThickness,
                                  lineWidth: NeumorphicMetrics.edgeDarkWidth * scale * hoverBoost)
                    .mask(shape.fill(LinearGradient(colors: [.clear, .black],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing)))
            )
            // 左上白亮边：**受光的棱**。比暗边细，且往内缩 0.5pt 压在轮廓内侧——
            // 往外挪就会溢到画布上变成一圈白晕，那还是「浮」。
            .overlay(
                shape
                    .inset(by: NeumorphicMetrics.edgeLightInset)
                    .strokeBorder(Neu.edgeHighlight,
                                  lineWidth: NeumorphicMetrics.edgeLightWidth * scale)
                    .mask(shape.fill(LinearGradient(colors: [.black, .clear],
                                                    startPoint: .topLeading,
                                                    endPoint: .center)))
            )
            .animation(Anim.interactive, value: pressed)
    }
}

// MARK: - 表面 2/2：内凹

/// 内凹容器：上/左内暗边、下/右内亮边，看起来像陷进底板里。**没有内阴影、没有模糊。**
///
/// hotfix8 之前这里是「描边 + 高斯模糊 + 方向渐变 mask」手搓的内阴影（macOS 13 没有原生
/// inner shadow）。问题和按钮的外投影同源：模糊出来的是一圈灰晕，在 34pt 高的窄条搜索框上
/// 会糊掉小半个高度，读成「脏」而不是「凹」。现在只在形状内沿画两条方向相反的硬边，
/// 与按钮那两条边共用同一个左上光源，只是明暗对调（凹陷的上沿背光、下沿受光）。
struct NeuWellBackground: View {
    var radius: CGFloat = NeumorphicMetrics.searchRadius

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(Neu.well)
            // 上/左内暗边：光被凹槽的上沿挡住，这里是凹陷最深的一侧。
            .overlay(
                shape
                    .strokeBorder(Neu.wellInnerShadow,
                                  lineWidth: NeumorphicMetrics.wellEdgeDarkWidth)
                    .mask(shape.fill(LinearGradient(colors: [.black, .clear],
                                                    startPoint: .topLeading,
                                                    endPoint: .center)))
            )
            // 下/右内亮边：凹陷的下沿正对光源，是反射面。比暗边细。
            .overlay(
                shape
                    .strokeBorder(Neu.wellInnerGlow,
                                  lineWidth: NeumorphicMetrics.wellEdgeLightWidth)
                    .mask(shape.fill(LinearGradient(colors: [.clear, .black],
                                                    startPoint: .center,
                                                    endPoint: .bottomTrailing)))
            )
            // 最内圈那道极暗的收口（wellShade）——「凹进去的那道坎」，只出现在上半圈，
            // 不会形成闭合边框。
            .overlay(
                shape
                    .inset(by: NeumorphicMetrics.wellEdgeDarkWidth)
                    .strokeBorder(Neu.wellRimOpacity, lineWidth: 0.6)
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
