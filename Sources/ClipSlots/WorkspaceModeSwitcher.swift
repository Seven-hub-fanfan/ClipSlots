import SwiftUI
import ClipSlotsKit

/// 工作区切换（v2.11.7 hotfix17）。
///
/// 两个工作区是**并列的一级视图**，不是弹窗也不是抽屉：
///   - `.edit`   槽位卡片主界面（默认）
///   - `.canvas` 无限画布（生图工作台）
///
/// ★ 为什么删掉了 Agent 段：Agent 不是第三个页面，而是要**嵌进每个页面的侧边栏**。放在这里当第三段
/// 会把它误传达成「和编辑/画布并列的另一块工作区」，而且一个永远点不动的灰段在顶栏正中央只是噪声。
/// 等侧边栏落地时它会出现在两个页面各自的右侧，而不是回到这个控件里。
enum WorkspaceMode: String, CaseIterable, Identifiable, Equatable {
    case edit
    case canvas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit: return "编辑"
        case .canvas: return "画布"
        }
    }

    var symbolName: String {
        switch self {
        case .edit: return "rectangle.stack"
        case .canvas: return "square.grid.3x3.topleft.filled"
        }
    }
}

/// 两段切换控件。
///
/// 刻意**没有**复用 `NeuSegmentedControl`：那个控件跟槽位业务（自动切换/范围）绑得比较死，
/// 而这里只需要一个纯粹的视图路由器；两边各自演化互不牵连。
struct WorkspaceModeSwitcher: View {
    @Binding var selection: WorkspaceMode

    /// 控件的固定宽度。
    ///
    /// v2.11.7 hotfix20：顶栏改成「流内放等宽透明占位 + overlay 里放真控件」来实现几何真居中，
    /// 两处必须**用同一个数**，否则占位与实体不等宽，居中就会差出那点差值。所以这里把宽度从
    /// 「由内容自然撑开」改成一个显式常量：段宽 62 × 2 + 段间距 2 + 外圈 padding 3 × 2。
    static let preferredWidth: CGFloat = 62 * 2 + 2 + 3 * 2

    /// 单段的固定尺寸（v2.11.7 hotfix21）。
    ///
    /// ★ 为什么必须写死、不能让内容自然撑开：两段用的 SF Symbol 字形盒子不一样高
    /// （`rectangle.stack` 偏扁，`square.grid.3x3.topleft.filled` 是个满格方块），
    /// 而 `Image(systemName:)` 的固有高度是跟着字形盒子走的。段高一旦随字形变化，两段里
    /// 「图标 + 文字」这组内容的垂直居中基准就各算各的，观感就是**「画布」整段往下沉一两个点**
    /// ——正是用户反馈的那个对不齐。把段高、图标绘制盒都钉成常量后，两段的几何完全一致，
    /// 换 symbol 也不会再把对齐带歪。
    private static let segmentHeight: CGFloat = 26
    private static let segmentWidth: CGFloat = 62
    private static let iconBox: CGFloat = 13

    /// 控件总高（段高 + 外圈 padding × 2）。外层要按它算落位，所以必须公开且是常量。
    static let preferredHeight: CGFloat = segmentHeight + 3 * 2

    /// 切换器在**内容区顶边**下方的固定落位（pt，到胶囊顶边）。
    ///
    /// ★ v2.11.7 hotfix22：这颗胶囊全 App 只存在**一份**，挂在内容区根节点的
    /// `.overlay(alignment: .top)` 上，编辑 / 画布共用同一个实例、同一个 inset —— 位置在数学上
    /// 不可能随模式变化。此前是「编辑模式挂在 titleBar 的 .center、画布模式挂在内容区的 .top」
    /// 两份实例：水平方向恰好都落在窗口中线（实测两模式 x 完全一致），但垂直方向差了 27.5pt，
    /// 于是切页时胶囊上下窜一下 —— 用户看到的「按钮会跑，不像切换按钮」就是这个。
    ///
    /// 数值不是随手取的：编辑模式 titleBar 第一行（logo 50pt + 上下 padding）的垂直中心，
    /// 实测（2x 截图量胶囊 ink 包围盒）距内容区顶边 53.5pt，减去半高 16pt = 37.5pt。
    /// 以编辑模式为基准而不是反过来，是因为编辑模式那一行有 logo / 拨杆 / 搜索框做参照，
    /// 胶囊必须与它们同一水平线；画布模式四周是空网格，跟过去反而更自然。
    /// 改动 titleBar 的行高时必须重量这个值（改完跑一次两模式截图比对）。
    static let pinnedTopInset: CGFloat = 37.5

    @Namespace private var indicator

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(WorkspaceMode.allCases) { mode in
                segment(mode)
            }
        }
        .padding(3)
        // 控件自身高度也固定：外层（titleBar / 画布浮动层）拿它去做垂直居中时，
        // 高度若随内容浮动，居中结果就会跟着一起浮动。
        .frame(width: Self.preferredWidth, height: Self.segmentHeight + 3 * 2)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.chipBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.subtleBorder, lineWidth: 1)
        )
    }

    private func segment(_ mode: WorkspaceMode) -> some View {
        let isSelected = selection == mode
        return Button {
            guard selection != mode else { return }
            withAnimation(Anim.transition) { selection = mode }
        } label: {
            HStack(alignment: .center, spacing: 5) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    // 钉死绘制盒子 + 盒内居中：图标的视觉中心从此与文字的视觉中心同高，
                    // 与具体 symbol 的字形高度无关。
                    .frame(width: Self.iconBox, height: Self.iconBox, alignment: .center)
                Text(mode.title)
                    .font(.system(size: 11, weight: .semibold))
                    // 不允许被压缩/换行：一旦文字进入多行或省略号路径，它的基线会整体偏移。
                    .fixedSize()
            }
            .foregroundColor(isSelected ? AppTheme.chromeAccentInk : .secondary.opacity(0.85))
            .frame(width: Self.segmentWidth, height: Self.segmentHeight, alignment: .center)
            .background {
                if isSelected {
                    // matchedGeometryEffect 让选中背景在两段之间**滑动**而不是闪现。
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.elevatedBackground)
                        .shadow(color: AppTheme.cardShadow(isEmpty: true), radius: 3, x: 0, y: 1)
                        .matchedGeometryEffect(id: "workspaceModeIndicator", in: indicator)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.title)
    }
}
