import SwiftUI
import ClipSlotsKit
import AppKit

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
    var onNavigate: (Int) -> Void = { _ in }
    var onOpen: () -> Void = {}
    @AppStorage(AppInterfaceLanguage.preferenceKey) private var languageRaw = AppInterfaceLanguage.chinese.rawValue
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Neu.subtleInk)
                .font(.system(size: 12, weight: .medium))
            SearchInputField(text: $searchText, onNavigate: onNavigate, onOpen: onOpen,
                             onEscape: { searchText = ""; selectedFilter = .all })
                .frame(minWidth: 50)
                .layoutPriority(1)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Neu.subtleInk)
                }
                .buttonStyle(.plain)
                .localizedHelp("清除搜索")
                .localizedAccessibilityLabel("清除搜索")
            }
            Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 0.5, height: 16)
            filterMenu
            scopeControl
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .frame(height: 34)
        .frame(minWidth: 232)
        .background(TapSkin.tone(0xf6f7f9, 0x242529),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(TapSkin.tone(0xd9dce2, 0x3b3e45), lineWidth: 0.7))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slot-search-well")
    }

    private var scopeControl: some View {
        HStack(spacing: 0) {
            ForEach(SlotSearchScope.allCases) { scope in
                Button { searchScope = scope } label: {
                    AppLocalizedText(scope.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(searchScope == scope ? Neu.sliderInk : Neu.subtleInk)
                        .frame(width: 45, height: NeumorphicMetrics.segmentHeight)
                        .background {
                            if searchScope == scope {
                                Capsule(style: .continuous)
                                    .fill(Neu.selectedFill)
                                    .padding(.vertical, NeumorphicMetrics.segmentInset)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .localizedAccessibilityLabel(scope.title)
                .accessibilityIdentifier("slot-search-scope-\(scope.rawValue)")
                .accessibilityValue(AppInterfaceStrings.text(searchScope == scope ? "已选择" : "未选择", language: AppInterfaceLanguage.resolve(languageRaw)))
                .accessibilityAddTraits(searchScope == scope ? .isSelected : [])
                .help(AppInterfaceStrings.format("搜索范围：%@", language: AppInterfaceLanguage.resolve(languageRaw), arguments: [AppInterfaceStrings.text(scope.title, language: AppInterfaceLanguage.resolve(languageRaw))]))
            }
        }
        .padding(.horizontal, NeumorphicMetrics.segmentInset)
        .frame(height: NeumorphicMetrics.segmentHeight)
        .neuWell(radius: NeumorphicMetrics.segmentHeight / 2)
        .fixedSize()
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
                    Label(localized: filter.title, systemImage: selectedFilter == filter ? "checkmark" : filter.systemImage)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(selectedFilter == .all ? Neu.subtleInk : Neu.ink)
                .frame(width: 26, height: 24)
                .background(selectedFilter == .all ? Color.clear : TapSkin.tone(0xe7eaf0, 0x41434b),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("slot-search-filter")
        .localizedAccessibilityLabel("筛选槽位类型")
        .accessibilityValue(AppInterfaceStrings.text(selectedFilter.title, language: AppInterfaceLanguage.resolve(languageRaw)))
        .help(AppInterfaceStrings.format("筛选槽位类型：%@", language: AppInterfaceLanguage.resolve(languageRaw), arguments: [AppInterfaceStrings.text(selectedFilter.title, language: AppInterfaceLanguage.resolve(languageRaw))]))
    }
}

/// Delegate commands reach the result list while the insertion point stays in
/// the single search field. Marked text keeps all IME candidate navigation.
struct SearchInputField: NSViewRepresentable {
    @Binding var text: String
    var onNavigate: (Int) -> Void
    var onOpen: () -> Void
    var onEscape: () -> Void
    @AppStorage(AppInterfaceLanguage.preferenceKey) private var languageRaw = AppInterfaceLanguage.chinese.rawValue
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = AppInterfaceStrings.text("搜索槽位…", language: AppInterfaceLanguage.resolve(languageRaw))
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("slot-search-field")
        field.setAccessibilityLabel(AppInterfaceStrings.text("搜索槽位", language: AppInterfaceLanguage.resolve(languageRaw)))
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = AppInterfaceStrings.text("搜索槽位…", language: AppInterfaceLanguage.resolve(languageRaw))
        field.setAccessibilityLabel(AppInterfaceStrings.text("搜索槽位", language: AppInterfaceLanguage.resolve(languageRaw)))
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
        }
        field.textColor = .labelColor
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchInputField
        init(_ parent: SearchInputField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onNavigate(1)
            case #selector(NSResponder.moveUp(_:)): parent.onNavigate(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onOpen()
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape()
            default: return false
            }
            return true
        }
    }
}
