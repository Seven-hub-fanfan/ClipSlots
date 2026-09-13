import Foundation

/// 新拟物（Neumorphism）工具栏 / 开关面板的调色板与几何常量（v2.11.8）。
///
/// 为什么这些值放在 Kit 而不是直接写进 SwiftUI 视图里：新拟物风格的成立**完全依赖数值关系**，
/// 而这些关系恰恰是截图里最难用眼睛验的东西：
///
///   1. **凸起（raised）要比承载面亮，内凹（well）要比承载面暗**。这是「光源在左上」这条约定的
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
///   - 简洁模式：纯中性灰阶，白面板 + 浅灰内凹 + 黑色选中滑块。
///   - 多彩模式：同样的凹凸结构，但面板与凸起带极淡的蓝紫倾向，选中滑块用品牌渐变。
public enum NeumorphicPalette {

    public typealias RGB = SlotAccentPalette.RGB

    /// 一套明暗档位下的新拟物表面色。
    public struct Surfaces: Equatable {
        /// 面板背后的画布（窗口底）。面板浮在它上面。
        public let ground: RGB
        /// 浮动面板本体。
        public let panel: RGB
        /// 凸起控件（图标按钮 / 操作按钮）的表面主色。
        public let raised: RGB
        /// 凸起控件顶部的高光（光源在左上，所以高光压在上沿）。
        public let raisedHighlight: RGB
        /// 内凹容器（搜索框 / 开关滑道）的底色。
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

        public init(ground: RGB, panel: RGB, raised: RGB, raisedHighlight: RGB,
                    well: RGB, wellShade: RGB, sliderFill: RGB, sliderInk: RGB,
                    ink: RGB, subtleInk: RGB, dangerFill: RGB, dangerInk: RGB) {
            self.ground = ground
            self.panel = panel
            self.raised = raised
            self.raisedHighlight = raisedHighlight
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
            [ground, panel, raised, raisedHighlight, well, wellShade, sliderFill, sliderInk, ink, subtleInk]
        }
    }

    // MARK: - 简洁模式（纯中性）

    /// 简洁模式 · 浅色。取值围着设计稿的「白面板 + #ECECEF 内凹 + 近黑滑块」走。
    public static let minimalLight = Surfaces(
        ground: RGB(0.925, 0.925, 0.933),          // #ECECEE 画布
        // 浅色档的面板刻意不是纯白（#F8F8FA），而把纯白留给**凸起**。
        // 原因很物理：光源在左上，凸起的顶面受光最多，必须是全场最亮的面。如果面板先占了
        // 纯白，凸起就只能往下调，于是按钮变成「比面板暗」= 视觉上塌进面板里，凹凸关系当场翻面。
        // 差 2.7% 亮度肉眼几乎读不出「面板不是纯白」，但凹凸的方向立刻就对了。
        panel: RGB(0.973, 0.973, 0.980),           // #F8F8FA 浮动面板
        raised: RGB(1.0, 1.0, 1.0),                // #FFFFFF 凸起（全场最亮）
        raisedHighlight: RGB(1.0, 1.0, 1.0),       // #FFFFFF 上沿高光
        well: RGB(0.914, 0.914, 0.925),            // #E9E9EC 内凹底
        wellShade: RGB(0.792, 0.792, 0.808),       // #CACACE 内凹暗边
        sliderFill: RGB(0.110, 0.110, 0.118),      // #1C1C1E 选中滑块
        sliderInk: RGB(1.0, 1.0, 1.0),             // #FFFFFF
        ink: RGB(0.129, 0.129, 0.137),             // #212123
        subtleInk: RGB(0.475, 0.475, 0.494),       // #79797E
        dangerFill: RGB(0.996, 0.925, 0.925),      // #FEECEC 淡红底
        dangerInk: RGB(0.788, 0.180, 0.180)        // #C92E2E
    )

    /// 简洁模式 · 深色。整套关系镜像翻转：面板比画布亮、凸起再亮一档、内凹比面板暗、滑块反相成近白。
    public static let minimalDark = Surfaces(
        ground: RGB(0.086, 0.086, 0.094),          // #161618
        panel: RGB(0.145, 0.145, 0.153),           // #252527
        raised: RGB(0.184, 0.184, 0.196),          // #2F2F32
        raisedHighlight: RGB(0.259, 0.259, 0.275),  // #424246
        well: RGB(0.106, 0.106, 0.114),            // #1B1B1D
        wellShade: RGB(0.043, 0.043, 0.047),       // #0B0B0C
        sliderFill: RGB(0.949, 0.949, 0.969),      // #F2F2F7 深色下滑块反相
        sliderInk: RGB(0.106, 0.106, 0.114),       // #1B1B1D
        ink: RGB(0.949, 0.949, 0.969),
        subtleInk: RGB(0.616, 0.616, 0.635),
        dangerFill: RGB(0.216, 0.106, 0.114),      // #371B1D
        dangerInk: RGB(1.0, 0.514, 0.494)          // #FF837E
    )

    // MARK: - 多彩模式（同几何、带品牌倾向）

    /// 多彩模式 · 浅色。凹凸结构与简洁模式逐值同构，只是每个面都掺了一点蓝紫。
    /// 掺色幅度刻意压得很小（0.5%～3%）：再多一点，面板就会从「白里透紫」变成「紫色面板」，
    /// 而卡片区仍是白的，两者会打起来。
    public static let colorfulLight = Surfaces(
        ground: RGB(0.933, 0.933, 0.960),          // #EEEEF5 画布（微紫）
        panel: RGB(0.969, 0.973, 0.996),           // #F7F8FE 面板（同上：纯白留给凸起）
        raised: RGB(0.996, 0.998, 1.0),            // #FEFFFF
        raisedHighlight: RGB(1.0, 1.0, 1.0),
        well: RGB(0.918, 0.925, 0.965),            // #EAECF6 内凹（更明显的蓝紫）
        wellShade: RGB(0.769, 0.784, 0.878),       // #C4C8E0
        sliderFill: RGB(0.357, 0.373, 0.898),      // #5B5FE5 品牌蓝紫（渐变起点）
        sliderInk: RGB(1.0, 1.0, 1.0),
        ink: RGB(0.114, 0.118, 0.180),             // #1D1E2E
        subtleInk: RGB(0.435, 0.447, 0.545),
        dangerFill: RGB(0.996, 0.914, 0.925),
        dangerInk: RGB(0.760, 0.130, 0.260)
    )

    /// 多彩模式 · 深色。
    public static let colorfulDark = Surfaces(
        ground: RGB(0.078, 0.082, 0.114),          // #14151D
        panel: RGB(0.141, 0.149, 0.196),           // #242632
        raised: RGB(0.184, 0.192, 0.251),          // #2F3140
        raisedHighlight: RGB(0.267, 0.278, 0.357),  // #44475B
        well: RGB(0.098, 0.102, 0.145),            // #191A25
        wellShade: RGB(0.035, 0.039, 0.063),
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
    /// 浮动工具栏面板圆角。
    public static let panelRadius: CGFloat = 18
    /// 面板与窗口边缘的留白（面板「浮」起来靠的就是这圈留白 + 外阴影）。
    public static let panelInset: CGFloat = 12
    /// 面板内边距。
    public static let panelPadding: CGFloat = 12

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
    public static let dropShadowRadius: CGFloat = 5
    public static let dropShadowOffsetY: CGFloat = 3
    public static let highlightShadowRadius: CGFloat = 4
    public static let highlightShadowOffsetY: CGFloat = -2

    /// 按下时凸起「压平」：阴影收敛到这个比例。
    public static let pressedShadowScale: CGFloat = 0.3
}
