import SwiftUI
import ClipSlotsKit

// MARK: - v2.10.93 · 按可用宽度二选一的布局（替代嵌套 ViewThatFits）
//
// ★ 这是本轮「窗口 resize 跟不上鼠标」的真凶所在，务必读完再改：
//
// 原实现用了**三层嵌套** `ViewThatFits`（外层选「筛选条 / 筛选菜单」、searchField 内层再选
// 「分段范围选择器 / 图标菜单」）。ViewThatFits 的工作方式是**逐个把每个候选子树完整测量一遍**
// （sizeThatFits），嵌套后测量次数是相乘关系；更致命的是这些候选里含 AppKit 控件
// （`.pickerStyle(.segmented)` = NSSegmentedControl、`Menu` = NSMenu/NSPopUpButton、
// `TextField` = NSTextField），**测量即实例化 platform view**。
//
// 实测（v2.10.93 单帧布局探针，release 构建，本机 1380×700 窗口、10 张卡片）：
//   • 一次窗口尺寸变化的同步布局总耗时 ≈ 104ms（≈10fps，这就是「拖得越快越跟不上」）
//   • 把 SlotSearchBar 整块摘掉 → 34ms（即这一个搜索栏占 ≈70ms）
//   • 只把嵌套 ViewThatFits 换成固定布局、其余不动 → 38ms（即嵌套测量本身 ≈66ms）
//   • 对照：整窗 4 层大高斯模糊氛围层全部关掉 → 96ms（几乎没变，**背景不是瓶颈**）
// 这解释了为什么 v2.10.69/70/75 三轮围绕「列宽量化 / 冻结布局 / 背景降级」的优化都没让用户觉得变好——
// 它们优化的都不是真正的成本所在。
//
// 本布局与 ViewThatFits 的差别：只用一次**算术比较**决定用哪个候选，然后只测量/放置被选中的那一个；
// 未选中的候选以零尺寸放到视图外，不参与测量。视觉结果与原先一致（阈值取自实测切换点），
// 但每帧成本从「N 个含 AppKit 控件的子树各测一遍」降为「一个子树测一遍」。
struct WidthThresholdLayout: Layout {
    /// 可用宽度 ≥ threshold 用第一个候选，否则用第二个。
    let threshold: CGFloat

    private func chosenIndex(_ subviews: Subviews, width: CGFloat?) -> Int {
        guard subviews.count > 1 else { return 0 }
        // 宽度未指定（父容器在问「理想尺寸」）时按宽版本回答，与 ViewThatFits 的既有观感一致。
        guard let width else { return 0 }
        return width >= threshold ? 0 : 1
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        return subviews[chosenIndex(subviews, width: proposal.width)].sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let chosen = chosenIndex(subviews, width: proposal.width)
        for (index, subview) in subviews.enumerated() {
            if index == chosen {
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.midY),
                              anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            } else {
                // 未选中的候选：零尺寸 + 放到视图外，既不显示也不参与测量成本。
                subview.place(at: CGPoint(x: bounds.minX - 10_000, y: bounds.minY - 10_000),
                              proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
    }
}

// MARK: - Compact slot search bar

struct SlotSearchBar: View {
    @Binding var searchText: String
    @Binding var selectedFilter: SlotFilterType
    @Binding var searchScope: SlotSearchScope

    // v2.11.8: 原 `ScopeControlStyle` 枚举已删除。范围选择器挪到搜索框外侧后，宽窄两版
    // 各自直接写在 body 的两个候选分支里（宽版 = NeuSegmentedControl、窄版 = 图标菜单），
    // 不再需要把形态当参数透进 searchField。

    /// 切换阈值。取值依据：本栏外层 `.frame(maxWidth: 400)`，默认窗口下拿到 400pt（渲染分段控件）；
    /// 窗口收到 760pt 时本栏被压到约 260pt（渲染图标菜单）。340 落在两者之间且留足余量，
    /// 保证与原 ViewThatFits 的切换点观感一致。
    private static let scopeSegmentedMinWidth: CGFloat = 340

    var body: some View {
        WidthThresholdLayout(threshold: Self.scopeSegmentedMinWidth) {
            HStack(alignment: .center, spacing: AppTheme.spacingSmall) {
                searchField
                    .layoutPriority(2)
                // v2.11.8: 范围选择器从「搜索框内部」挪到搜索框**右侧**，与新设计稿一致。
                // 内凹的搜索框里再嵌一个凹轨道会出现「凹中凹」，两层内阴影叠在一起谁也读不出来。
                NeuSegmentedControl(
                    options: SlotSearchScope.allCases.map { NeuSegment(value: $0, title: $0.title) },
                    selection: $searchScope
                )
                .frame(width: 108)
                .help("搜索范围：\(searchScope.title)")
                filterMenu
            }
            HStack(alignment: .center, spacing: AppTheme.spacingTight) {
                searchField
                    .layoutPriority(2)
                scopeCompactMenu
                filterMenu
            }
        }
    }

    /// 内凹搜索框：椭圆形（圆角 = 半高）well，左侧放大镜、右侧清除按钮。
    private var searchField: some View {
        HStack(alignment: .center, spacing: AppTheme.spacingSmall) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Neu.subtleInk)
                .font(.system(size: 12, weight: .medium))

            TextField("搜索槽位…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(Neu.ink)
                .frame(minWidth: 90)

            if !searchText.isEmpty || selectedFilter != .all {
                Button {
                    if !searchText.isEmpty { searchText = "" } else { selectedFilter = .all }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Neu.subtleInk)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: NeumorphicMetrics.searchHeight)
        .neuWell()
    }

    private var scopeCompactMenu: some View {
        Menu {
            ForEach(SlotSearchScope.allCases) { scope in
                Button {
                    searchScope = scope
                } label: {
                    Label(scope.title, systemImage: searchScope == scope ? "checkmark" : scope.systemImage)
                }
            }
        } label: {
            Image(systemName: searchScope.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Neu.ink)
                .frame(width: 26, height: NeumorphicMetrics.segmentHeight)
                .neuRaised(radius: NeumorphicMetrics.segmentHeight / 2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("搜索范围：\(searchScope.title)")
    }

    // 注：v2.10.93 删除了 `filterStrip`（横向筛选 chip 条）及其 `filterChip`。
    // 原因：它只是原外层 ViewThatFits 的第一候选，而本栏被 `.frame(maxWidth: 400)` 限宽，
    // chip 条的理想宽度（330）加上搜索框理想宽度永远超过 400 → **在任何窗口尺寸下都从未被选中**
    // （已用进程内窗口截图在 1380pt 与 760pt 两档确认渲染的都是下面的紧凑 filterMenu）。
    // 留着它只会让每次布局多测量一条含 ScrollView + 6 个 chip 按钮的子树。
    private var filterMenu: some View {
        Menu {
            ForEach(SlotFilterType.allCases) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    Label(filter.title, systemImage: selectedFilter == filter ? "checkmark" : filter.systemImage)
                }
            }
        } label: {
            Label(selectedFilter.title, systemImage: "line.3.horizontal.decrease.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Neu.ink)
                .padding(.horizontal, 9)
                .frame(height: NeumorphicMetrics.segmentHeight)
                .neuRaised(radius: NeumorphicMetrics.segmentHeight / 2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("筛选槽位类型")
    }
}
