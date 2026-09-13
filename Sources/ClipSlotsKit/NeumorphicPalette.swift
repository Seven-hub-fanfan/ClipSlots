import Foundation

/// 新拟物（Neumorphism）工具栏 / 开关面板的调色板与几何常量（v2.11.8）。
///
/// 为什么这些值放在 Kit 而不是直接写进 SwiftUI 视图里：新拟物风格的成立**完全依赖数值关系**，
/// 而这些关系恰恰是截图里最难用眼睛验的东西：
///
///   1. **凸起（raised）要比承载面亮，内凹（well）要比承载面暗**。v2.11.7 hotfix4 起，
///      承载面就是**画布本身**（`ground`）——工具栏不再是一块浮动面板，见下面 `ground` 的注释。这是「光源在左上」这条约定的
///      唯一硬约束。一旦某个档位反过来（比如深色模式下把 well 调得比面板亮），按钮看着就会
///      从「凸起」翻转成「凹陷」，整屏光影语言瞬间崩塌——但单看一张截图，人往往只觉得
///      「有点怪」，说不出哪怕一处具体错误。
///   2. **凸起与内凹之间必须留出可辨的明度差**，否则新拟物就退化成「一片白」：控件边界消失，
///      用户不知道哪里能点。
///   3. **选中滑块（黑底白字 / 品牌渐变白字）与轨道之间要有足够对比度**，这是唯一承载
///      「当前选的是哪个」的信号。
///
/// 这三条都能写成断言，见 `Tests/ClipSlotsKitSmokeTests` 的 NEU 段落。
///
/// 两种皮肤共用**同一套几何**（`NeumorphicMetrics`），只有颜色不同：
///   - 简洁模式：纯中性灰阶，白色凸起 + 浅灰内凹 + 黑色选中滑块。
///   - 多彩模式：同样的凹凸结构，但凸起与内凹带极淡的蓝紫倾向，选中滑块用品牌渐变。
public enum NeumorphicPalette {

    public typealias RGB = SlotAccentPalette.RGB

    /// 一套明暗档位下的新拟物表面色。
    public struct Surfaces: Equatable {
        /// 画布（窗口底）。**同时也是工具栏的承载面**。
        ///
        /// v2.11.7 hotfix4 去掉了「工具栏浮动面板」这一层：工具栏与卡片区共用同一张底，
        /// 所以凹凸关系的参照物从原来的 `panel` 换成了这里的 `ground`。这个值必须与 App 层
        /// 的窗口底色逐值一致（简洁模式 = `MinimalSkinPalette.window`，多彩模式 = `AppTheme`
        /// 的窗口底），否则工具栏会重新变成一块「颜色略不同的方块」压在内容上——
        /// smoke 里有断言钉住这条等式。
        public let ground: RGB
        /// 凸起控件（图标按钮 / 操作按钮）的表面色。
        ///
        /// v2.11.7 hotfix5：这个值**必须等于 `ground`**。
        ///
        /// 之前它是纯白、画布是浅灰，于是按钮读成「一片白薄片叠在灰底上」——色差本身就成了
        /// 边界，光影反而成了配角，这正是「浮」的来源。设计稿里按钮和底板是**同一块材质**，
        /// 边界完全由「左上白高光 + 右下柔投影」这对双色投影定义，按钮像从底板上鼓起来的一块。
        /// 一旦这里和 `ground` 拉开色差，双色投影做得再准也救不回来。
        public let raised: RGB
        // hotfix5: 原来这里还有个 `raisedHighlight`（凸起表面的渐变高光色）。凸起既然与画布同色，
        // 顶面渐变就必须取消——渐变上端是纯白，等于把「白薄片」的色差换个形式请回来。
        // 高光现在是一道**投影**（左上、白 80%、blur 4），归 App 层的 `Neu.lightShadow`。
        /// 内凹容器（搜索框 / 开关滑道）的底色。必须比 `ground` 暗（浅色 / 深色档都是）。
        public let well: RGB
        /// 内凹容器上沿的暗边（内阴影的主要成分）。
        public let wellShade: RGB
        /// 选中滑块 / 主行动块的底色（简洁模式近黑，深色档反相成近白）。
        public let sliderFill: RGB
        /// 选中滑块上的文字 / 图标色。
        public let sliderInk: RGB
        /// 面板上的正文色。
        public let ink: RGB
        /// 次要文字 / 占位符色。
        public let subtleInk: RGB
        /// 危险操作（清空）的淡底色。
        public let dangerFill: RGB
        /// 危险操作的文字 / 图标色。
        public let dangerInk: RGB

        public init(ground: RGB, raised: RGB,
                    well: RGB, wellShade: RGB, sliderFill: RGB, sliderInk: RGB,
                    ink: RGB, subtleInk: RGB, dangerFill: RGB, dangerInk: RGB) {
            self.ground = ground
            self.raised = raised
            self.well = well
            self.wellShade = wellShade
            self.sliderFill = sliderFill
            self.sliderInk = sliderInk
            self.ink = ink
            self.subtleInk = subtleInk
            self.dangerFill = dangerFill
            self.dangerInk = dangerInk
        }

        /// 参与「必须是中性灰」断言的成员（简洁模式专用；危险色与品牌色天然带色相，不在其中）。
        public var neutralMembers: [RGB] {
            [ground, raised, well, wellShade, sliderFill, sliderInk, ink, subtleInk]
        }
    }

    // MARK: - 简洁模式（纯中性）

    /// 简洁模式 · 浅色。取值围着设计稿的「白色凸起 + 浅灰内凹 + 近黑滑块」走。
    public static let minimalLight = Surfaces(
        // 与 MinimalSkinPalette.light.window 完全相同（#F2F2F3）：工具栏与卡片区同底，
        // 才不会出现「工具栏是一块颜色略不同的方块」。
        ground: RGB(0.949, 0.949, 0.953),          // #F2F2F3 画布 = 工具栏承载面
        raised: RGB(0.949, 0.949, 0.953),          // #F2F2F3 与画布同色（hotfix5：边界靠双色投影）
        // 内凹要在**画布**上读得出来。hotfix4 去掉浮动面板后承载面从 #F8F8FA 降到 #F2F2F3，
        // 原来的 #E9E9EC 只比它暗 3.5%，搜索框几乎消失，所以一并压深到 #E5E5E8。
        well: RGB(0.898, 0.898, 0.910),            // #E5E5E8 内凹底
        wellShade: RGB(0.776, 0.776, 0.792),       // #C6C6CA 内凹暗边
        sliderFill: RGB(0.110, 0.110, 0.118),      // #1C1C1E 选中滑块
        sliderInk: RGB(1.0, 1.0, 1.0),             // #FFFFFF
        ink: RGB(0.129, 0.129, 0.137),             // #212123
        subtleInk: RGB(0.475, 0.475, 0.494),       // #79797E
        dangerFill: RGB(0.996, 0.925, 0.925),      // #FEECEC 淡红底
        dangerInk: RGB(0.788, 0.180, 0.180)        // #C92E2E
    )

    /// 简洁模式 · 深色。整套关系镜像翻转：凸起比画布亮、内凹比画布暗、滑块反相成近白。
    public static let minimalDark = Surfaces(
        ground: RGB(0.086, 0.086, 0.094),          // #161618 = MinimalSkinPalette.dark.window
        raised: RGB(0.086, 0.086, 0.094),          // #161618 与画布同色
        // 深色档同理：承载面从原面板 #252527 变成画布 #161618，内凹必须跟着压到画布**之下**，
        // 否则「凹陷」会翻成「凸起」（原值 #1B1B1D 比画布还亮）。
        well: RGB(0.055, 0.055, 0.063),            // #0E0E10
        wellShade: RGB(0.024, 0.024, 0.028),       // #060607
        sliderFill: RGB(0.949, 0.949, 0.969),      // #F2F2F7 深色下滑块反相
        sliderInk: RGB(0.106, 0.106, 0.114),       // #1B1B1D
        ink: RGB(0.949, 0.949, 0.969),
        subtleInk: RGB(0.616, 0.616, 0.635),
        dangerFill: RGB(0.216, 0.106, 0.114),      // #371B1D
        dangerInk: RGB(1.0, 0.514, 0.494)          // #FF837E
    )

    // MARK: - 多彩模式（同几何、带品牌倾向）

    /// 多彩模式 · 浅色。凹凸结构与简洁模式逐值同构，只是每个面都掺了一点蓝紫。
    /// 掺色幅度刻意压得很小（0.5%～3%）：再多一点，凸起就会从「白里透紫」变成「紫色块」，
    /// 而卡片区仍是白的，两者会打起来。
    public static let colorfulLight = Surfaces(
        // 与 AppTheme 的多彩窗口底同值（AppTheme 直接引用这里，见 windowBackground）。
        ground: RGB(0.965, 0.970, 0.980),          // #F6F7FA 画布 = 工具栏承载面
        raised: RGB(0.965, 0.970, 0.980),          // #F6F7FA 与画布同色
        well: RGB(0.906, 0.914, 0.960),            // #E7E9F5 内凹（更明显的蓝紫）
        wellShade: RGB(0.757, 0.773, 0.871),       // #C1C5DE
        sliderFill: RGB(0.357, 0.373, 0.898),      // #5B5FE5 品牌蓝紫（渐变起点）
        sliderInk: RGB(1.0, 1.0, 1.0),
        ink: RGB(0.114, 0.118, 0.180),             // #1D1E2E
        subtleInk: RGB(0.435, 0.447, 0.545),
        dangerFill: RGB(0.996, 0.914, 0.925),
        dangerInk: RGB(0.760, 0.130, 0.260)
    )

    /// 多彩模式 · 深色。
    public static let colorfulDark = Surfaces(
        ground: RGB(0.075, 0.078, 0.088),          // #131416 画布 = AppTheme 多彩深色窗口底
        raised: RGB(0.075, 0.078, 0.088),          // #131416 与画布同色
        // hotfix5：凸起改成与画布同色后，「凸起 vs 内凹」的明度差全靠内凹自己撑（原来还有
        // 纯白凸起帮忙）。多彩深色这档原值只剩 1.044 对比度，搜索框在黑底上彻底消失，压深一档。
        well: RGB(0.035, 0.039, 0.063),            // #090A10
        wellShade: RGB(0.020, 0.024, 0.043),
        sliderFill: RGB(0.404, 0.384, 0.918),      // #6762EA（比浅色档亮一档，但仍压得住白字：白字对比 4.66:1）
        sliderInk: RGB(1.0, 1.0, 1.0),
        ink: RGB(0.945, 0.949, 0.980),
        subtleInk: RGB(0.612, 0.624, 0.706),
        dangerFill: RGB(0.239, 0.106, 0.145),
        dangerInk: RGB(1.0, 0.529, 0.596)
    )

    /// 按皮肤 + 明暗取一套表面色。
    public static func surfaces(skin: AppSkin, dark: Bool) -> Surfaces {
        switch (skin, dark) {
        case (.minimal, false): return minimalLight
        case (.minimal, true): return minimalDark
        case (.colorful, false): return colorfulLight
        case (.colorful, true): return colorfulDark
        }
    }

    /// 全部四套（皮肤 × 明暗），供断言遍历。
    public static var allSurfaces: [(name: String, surfaces: Surfaces)] {
        [("简洁·浅色", minimalLight), ("简洁·深色", minimalDark),
         ("多彩·浅色", colorfulLight), ("多彩·深色", colorfulDark)]
    }
}

/// 新拟物组件的几何常量。**两种皮肤共用**——皮肤只改颜色，不改骨架
/// （v2.11.7 hotfix2d 已经为此付过一次代价：几何分叉会让切皮肤时文字左右跳）。
public enum NeumorphicMetrics {
    // v2.11.7 hotfix4: 原来的 panelRadius / panelInset / panelPadding 随「浮动工具栏面板」
    // 一起删除。工具栏现在直接坐在画布上，左右留白复用 App 层的 `AppTheme.pagePadding`
    // ——和卡片区同一个值，工具栏里的控件才会与下面的卡片左右对齐。

    /// 搜索框（内凹）高度与圆角。圆角取高度的一半 = 设计稿里的椭圆形。
    public static let searchHeight: CGFloat = 34
    public static var searchRadius: CGFloat { searchHeight / 2 }

    /// 图标按钮（凸起圆角方块）边长与圆角。
    public static let iconTileSize: CGFloat = 32
    public static let iconTileRadius: CGFloat = 10

    /// 操作按钮（凸起圆角矩形）高度与圆角。
    public static let actionHeight: CGFloat = 30
    public static let actionRadius: CGFloat = 10

    /// 范围分段控件（组内 / 全局）：轨道高度、滑块内缩。
    public static let segmentHeight: CGFloat = 26
    public static let segmentInset: CGFloat = 3

    /// 垂直开关：滑道尺寸、滑块尺寸、滑块行程。
    public static let switchTrackWidth: CGFloat = 26
    public static let switchTrackHeight: CGFloat = 40
    public static let switchKnobWidth: CGFloat = 20
    public static let switchKnobHeight: CGFloat = 17
    /// 滑块从「关」到「开」的垂直位移（正负各一半）。
    public static var switchTravel: CGFloat {
        (switchTrackHeight - switchKnobHeight) / 2 - segmentInset
    }

    /// 阴影：外阴影（右下，光源左上）与高光（左上）。
    // v2.11.7 hotfix5：阴影参数按设计稿 1:1 对齐。
    //
    // SwiftUI 的 `.shadow(radius:)` 是**高斯 sigma**，不是设计稿里的 blur 直径，两者差一半——
    // 设计稿标 blur 12 就要写 radius 6。这个 2 倍关系搞错，阴影要么生硬要么糊成一团。
    //
    // 右下投影：offset (4, 4)、blur 12（= radius 6）、黑 9%。之前是 (0, 3) + radius 5：
    // 纯垂直偏移让按钮读成「向下坠」而不是「左上有光」，而且太近太实，像描了一圈深边。
    public static let dropShadowRadius: CGFloat = 6
    public static let dropShadowOffsetX: CGFloat = 4
    public static let dropShadowOffsetY: CGFloat = 4
    /// 左上高光：offset (-2, -2)、blur 4（= radius 2）、白 80%。它承担「材质厚度」那一半观感，
    /// 缺了按钮就只有一团投影、边缘发平。
    public static let highlightShadowRadius: CGFloat = 2
    public static let highlightShadowOffsetX: CGFloat = -2
    public static let highlightShadowOffsetY: CGFloat = -2
    /// 内凹的内阴影 / 内高光：offset ±2、blur 5（= radius 2.5）。
    public static let wellInnerOffset: CGFloat = 2
    public static let wellInnerRadius: CGFloat = 2.5

    // MARK: - 双侧描边（v2.11.7 hotfix6，按设计稿 image-a4ad5438）
    //
    // 光影只交代「按钮周围的空气」，交代不了「按钮本身有多厚」。设计稿里每颗按钮都有两条边：
    // 左上一条锐利白亮边（受光面），右下一条更宽的灰边（凸起物的侧面厚度）。这两条边叠起来
    // 才有「从画布里冲压出来」的实体感——只有内外阴影时，按钮看着像一块贴纸。
    //
    // 关键是**两条边宽度不同**：厚度边必须比高光边宽（1.5 vs 1），因为它模拟的是有体积的侧面，
    // 而高光只是一条反光。等宽会退化成「描了一圈双色边框」。
    public static let edgeThicknessWidth: CGFloat = 1.5
    public static let edgeHighlightWidth: CGFloat = 1
    /// 高光边整体往左上挪半像素，让它压在形状轮廓外侧一点，边缘才「锐」。
    public static let edgeHighlightOffset: CGFloat = -0.5

    /// 按下时凸起「压平」：阴影收敛到这个比例。
    public static let pressedShadowScale: CGFloat = 0.3
}
