import SwiftUI
import AppKit
import ClipSlotsKit

/// 画布右侧属性面板（v2.11.7 hotfix19）。
///
/// ## 为什么现在才有它
///
/// 用户反馈「无法保存字体」。在此之前画布**根本没有字体入口** —— 节点正文写死
/// `.font(.system(size: 10))`。所以这个 bug 的修复是两件事叠在一起：给模型加可持久化的
/// `fontName / fontSize`（`CanvasNode`），再给一个真正写回 store 的面板（本文件）。
///
/// ## 只在单选时出现
///
/// 多选时改字体只有两种可能：只改一个（用户会以为没生效），或者全改（等于偷偷批量改）。
/// 两种都比「面板不出现」更糟，所以由 `CanvasStore.soleSelectedNode` 把关。
///
/// ## 写回路径
///
/// 一律走 `canvas.updateNodeStyle`（内部 `commit`，进撤销栈），**不碰 `updateNode`** ——
/// 后者只落盘不记历史，用它改字体的症状是「改完 Cmd+Z 撤不掉」。
struct CanvasInspectorPanel: View {
    @ObservedObject var canvas: CanvasStore
    let node: CanvasNode

    /// 模型目录。进程级共享（理由见 `CrateModelCatalogStore` 的类型注释：面板随选中节点重建，
    /// 状态放这里才不会每点一个节点就重跑一次 `crate model list`）。
    @ObservedObject private var catalog = CrateModelCatalogStore.shared

    /// 数据里存着、但本机没装的字体。单独列出来是为了给它一个 tag ——
    /// 否则 Picker 找不到匹配 selection 的 tag 会**显示空白**，看起来正好像「设置没保存」。
    private var missingCurrentFamily: String? {
        guard let current = node.fontName, !current.isEmpty,
              !CanvasFontCatalog.isAvailable(current) else { return nil }
        return current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.6)

            VStack(alignment: .leading, spacing: 10) {
                // 出图参数放最上面：它是这类节点最常改的东西（字体是一次性设定，模型/尺寸是每次
                // 出图前都要看一眼的）。非出图节点（文本节点）没有这一段。
                // 只给图像节点：生图链路目前只实现了 image（视频节点的 model/ratio 还没有对应的
                // 提交路径，给它一个能改但改了不生效的选择器是负收益）。
                if node.kind == .image {
                    generationSection
                    Divider().opacity(0.4)
                }
                fontSection
                Divider().opacity(0.4)
                infoSection
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .frame(width: 208)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.canvasChromeSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.subtleBorder, lineWidth: 1)
        )
        .shadow(color: AppTheme.cardShadow(isEmpty: false), radius: 12, x: 0, y: 4)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppTheme.chromeAccentInk)
            Text("节点属性")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.canvasChromeInk)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: 出图参数（v2.11.18）
    //
    // 在此之前模型写死 seedream45、比例写死 1:1，参数栏是只读的两行字 —— 也就是"能生图，但只能
    // 生一种图"。这一段把它们变成选择器，选项**全部来自 CLI 现问的模型目录**，理由见
    // `CrateModelCatalog`（各模型的比例选项互不相同，还有一类模型压根不吃 ratio）。

    private var generationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                sectionTitle("出图模型")
                Spacer(minLength: 0)
                if catalog.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                } else {
                    // 手动刷新的用途很具体：用户刚在终端 `crate auth login` 完，或者刚上线了新模型。
                    // 没有它，只能等 10 分钟软过期或重启 App。
                    Button { catalog.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(AppTheme.chromeAccentInk)
                    }
                    .buttonStyle(.plain)
                    .help("重新读取模型列表")
                }
            }

            Picker("", selection: modelBinding) {
                // 数据里存着、但目录里没有的模型（已下线 / 目录没加载出来）必须自带一个 tag，
                // 否则 Picker 匹配不到 selection 会**显示空白** —— 那个症状看起来正好像"设置丢了"。
                // 与上面字体那段的 `missingCurrentFamily` 是同一个坑。
                if needsUnlistedModelTag {
                    Text(node.model).tag(node.model)
                }
                ForEach(modelFamilies, id: \.name) { family in
                    if family.name.isEmpty {
                        ForEach(family.models) { m in
                            Text(m.displayName).tag(m.id)
                        }
                    } else {
                        Section(family.name) {
                            ForEach(family.models) { m in
                                Text(m.displayName).tag(m.id)
                            }
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)

            if let note = modelNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundColor(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            sectionTitle("尺寸")

            Picker("", selection: ratioBinding) {
                if ratioOptions.isEmpty {
                    // 没有可选项时也要有一个能匹配 selection 的 tag（空白 Picker 同上）。
                    Text(node.ratio.isEmpty ? "模型默认" : node.ratio).tag(node.ratio)
                } else {
                    if unlistedRatio {
                        Text("\(node.ratio)（当前）").tag(node.ratio)
                    }
                    // 比例与分辨率档分组：`2K` / `4K` 不是宽高比，混在一列里会让人以为选了 2K
                    // 就还是方图（实际构图比例由模型自己定）。
                    let ratios = ratioOptions.filter { !$0.isResolutionPreset }
                    let presets = ratioOptions.filter { $0.isResolutionPreset }
                    if presets.isEmpty {
                        ForEach(ratios) { opt in Text(opt.label).tag(opt.value) }
                    } else {
                        Section("比例") {
                            ForEach(ratios) { opt in Text(opt.label).tag(opt.value) }
                        }
                        Section("分辨率") {
                            ForEach(presets) { opt in Text(opt.label).tag(opt.value) }
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(ratioOptions.isEmpty)

            if let note = ratioNote {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundColor(AppTheme.canvasChromeTertiaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { catalog.loadIfNeeded() }
    }

    /// 按系列分组，**组内与组间都保持 CLI 原序**（那是策划过的顺序，重排成字母序会把 seedream
    /// 家族打散）。这里不用 `Dictionary(grouping:)`：它的 key 顺序是随机的，会导致每次打开面板
    /// 菜单里的分组顺序都不一样。
    private struct ModelFamily { let name: String; let models: [CrateModelCatalog.ModelInfo] }

    private var modelFamilies: [ModelFamily] {
        var order: [String] = []
        var buckets: [String: [CrateModelCatalog.ModelInfo]] = [:]
        for m in catalog.imageModels {
            if buckets[m.family] == nil { order.append(m.family) }
            buckets[m.family, default: []].append(m)
        }
        return order.map { ModelFamily(name: $0, models: buckets[$0] ?? []) }
    }

    /// 当前模型在目录里的条目。`nil` = 目录没加载出来，或这个模型已经不在目录里了。
    private var currentModel: CrateModelCatalog.ModelInfo? { catalog.model(id: node.model) }

    /// 要不要给"目录里没有的当前模型"补一个 tag。目录未加载 / 加载失败时也为 true —— 那两种情况下
    /// 列表是空的，不补 tag 的话 Picker 会显示空白。
    private var needsUnlistedModelTag: Bool { currentModel == nil }

    private var ratioOptions: [CrateModelCatalog.RatioOption] { currentModel?.ratioOptions ?? [] }

    /// 当前比例不在选项里（老画布 / 换了模型但值还没落定）。
    private var unlistedRatio: Bool {
        !node.ratio.isEmpty && !ratioOptions.contains { $0.value == node.ratio }
    }

    private var modelNote: String? {
        switch catalog.state {
        case .failed(let reason): return "模型列表读取失败：\(reason)"
        case .loaded where currentModel == nil: return "「\(node.model)」不在当前可用模型里，建议换一个"
        default: return nil
        }
    }

    private var ratioNote: String? {
        if ratioOptions.isEmpty {
            guard let model = currentModel else { return "模型列表未加载，暂时沿用当前尺寸" }
            return model.supportsRatio ? "该模型未提供预设比例" : "该模型按宽高出图，不接受比例预设"
        }
        if unlistedRatio { return "当前值不在该模型的预设里，生成时可能被忽略" }
        return nil
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { node.model },
            set: { picked in
                // 换模型时顺带把比例落到新模型真的接受的值上 —— 各模型选项不同，留着旧值会在提交
                // 时被拒。两个字段**一次写进撤销栈**（理由见 `updateNodeGeneration`）。
                let ratio = catalog.model(id: picked).map {
                    CrateModelCatalog.resolvedRatio(current: node.ratio, for: $0)
                }
                canvas.updateNodeGeneration(id: node.id, model: picked, ratio: ratio)
            }
        )
    }

    private var ratioBinding: Binding<String> {
        Binding(
            get: { node.ratio },
            set: { canvas.updateNodeGeneration(id: node.id, ratio: $0) }
        )
    }

    // MARK: 字体

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("正文字体")

            Picker("", selection: fontFamilyBinding) {
                // 「跟随系统」用空串当哨兵值而不是 nil：SwiftUI 的 `Picker` 对 `Optional` 选中值
                // 的 tag 匹配非常容易写错（tag 类型必须与 selection 完全一致，`String?` 与
                // `String` 不匹配时 Picker 会静默显示空白）。空串在 binding 里被归一成 nil。
                Text("跟随系统").tag("")

                if let missing = missingCurrentFamily {
                    Text(CanvasFontCatalog.displayName(missing)).tag(missing)
                }

                // 常用分组只列**本机真的装了的**（`commonFamilies` 已按可用性过滤）——
                // 列一堆装不上的字体、用户选了却没效果，等于把刚修掉的 bug 又造回去。
                Section("常用") {
                    ForEach(CanvasFontCatalog.commonFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Section("全部字体") {
                    ForEach(CanvasFontCatalog.otherFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)

            if missingCurrentFamily != nil {
                Label("本机未安装，暂以系统字体显示", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundColor(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                sectionTitle("字号")
                Spacer(minLength: 0)
                Text("\(Int(node.resolvedBodyFontSize))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.canvasChromeInk)
                    .frame(width: 20, alignment: .trailing)
                Stepper("") {
                    canvas.updateNodeStyle(id: node.id, fontSize: .some(node.resolvedBodyFontSize + 1))
                } onDecrement: {
                    canvas.updateNodeStyle(id: node.id, fontSize: .some(node.resolvedBodyFontSize - 1))
                }
                .labelsHidden()
                .controlSize(.small)
            }

            // 实时预览。字体解析失败会静默回落系统字体（`Font.custom` 的老坑），有了这一行
            // 用户能立刻看出「到底换了没有」，不必去画布上比对 10pt 的小字。
            Text("永远相信美好的事情即将发生 Aa 123")
                .font(CanvasFontCatalog.font(family: node.fontName,
                                            size: max(11, node.resolvedBodyFontSize)))
                .foregroundColor(AppTheme.canvasChromeSecondaryInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppTheme.chipBackground)
                )

            if node.hasCustomFont {
                Button {
                    canvas.updateNodeStyle(id: node.id, fontName: .some(nil), fontSize: .some(nil))
                } label: {
                    Text("恢复默认")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(AppTheme.chromeAccentInk)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Picker 的双向绑定。空串 ⇄ nil 的归一在这里做，store 只接受「已归一」的值。
    private var fontFamilyBinding: Binding<String> {
        Binding(
            get: { node.fontName ?? "" },
            set: { canvas.updateNodeStyle(id: node.id, fontName: .some($0.isEmpty ? nil : $0)) }
        )
    }

    // MARK: 只读信息

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            infoRow("类型", node.kind.displayName)
            // 模型 / 比例不再列在只读区 —— 它们上面已经是选择器了，同一个值在一个面板里出现两次
            // 只会让人怀疑哪个才算数。
            // ★ hotfix20：节点 = 槽位，「未绑定」这一档在数据结构层面就不存在了
            // （`CanvasNode` 的 groupId/slot 是非可选的）。名字当场问槽位，见 `CanvasStore.nodeTitle`。
            infoRow("槽位", slotDescription)
        }
    }

    private var slotDescription: String {
        let fallback = "槽位 \(node.slot)"
        let name = canvas.nodeTitle(node)
        return name == fallback ? fallback : "\(name)（\(node.slot)）"
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(AppTheme.canvasChromeTertiaryInk)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(AppTheme.canvasChromeSecondaryInk)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(AppTheme.canvasChromeTertiaryInk)
    }
}
