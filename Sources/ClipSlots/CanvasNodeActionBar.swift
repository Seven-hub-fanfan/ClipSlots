import SwiftUI
import ClipSlotsKit

/// 出图参数的**写入规则**（v2.12.0）。
///
/// 抽出来的原因：v2.12.0 起同一组参数有**两个**入口 —— 右侧属性面板（完整版）与节点上的操作条
/// （常用项）。换模型时要顺带把比例/分辨率/时长落到新模型接受的档位上（见
/// `CrateModelCatalog.resolvedRatio`），这条规则一旦在两个入口各写一份，迟早会分叉：
/// 从面板换模型比例自动跟随、从操作条换模型却留下一个非法比例，然后在提交时被 CLI 拒收。
@MainActor
enum CanvasGenerationParamEdits {

    /// 该节点类型可选的模型清单。
    static func models(for kind: CanvasNodeKind,
                       catalog: CrateModelCatalogStore) -> [CrateModelCatalog.ModelInfo] {
        kind == .video ? catalog.videoModels : catalog.imageModels
    }

    /// 换模型。
    ///
    /// 目录里查不到新模型时只写 model 字段、其余参数原样保留：那是"目录没加载出来但用户手上有个
    /// 能用的模型名"的情况，替他把比例清空反而是帮倒忙。
    static func applyModel(_ picked: String,
                           node: CanvasNode,
                           canvas: CanvasStore,
                           catalog: CrateModelCatalogStore) {
        guard let info = catalog.model(id: picked) else {
            canvas.updateNodeGeneration(id: node.id, model: picked)
            return
        }
        let ratio = CrateModelCatalog.resolvedRatio(current: node.ratio, for: info)
        // 分辨率与时长：新模型不吃就清空/归零（0 = 交给模型默认），吃但当前值不在档位里也清掉。
        let resolution: String = {
            guard info.supportsResolution else { return "" }
            if node.resolution.isEmpty { return "" }
            guard info.resolutionOptions.isEmpty
                    || info.resolutionOptions.contains(where: { $0.value == node.resolution }) else { return "" }
            return node.resolution
        }()
        let duration: Int = {
            guard info.supportsDuration,
                  let spec = info.durationSpec,
                  let current = node.duration, current > 0 else { return 0 }
            return spec.allows(current) ? current : 0
        }()
        let audio: Bool? = info.supportsAudio ? node.generateAudio : nil
        canvas.updateNodeGeneration(id: node.id,
                                    model: picked,
                                    ratio: ratio,
                                    resolution: resolution,
                                    duration: duration,
                                    generateAudio: .some(audio))
    }
}

/// 节点操作条（v2.12.0 · 第二档「节点即执行单元」）。
///
/// ## 它解决什么
///
/// v2.11.x 里跑一个节点要在三个地方来回跳：选中节点（画布中央）→ 右上角「生成」按钮（屏幕角落）
/// → 改参数得开右侧属性面板。用户的原话是用画布"很蹩脚"，这条路径就是其中一半原因 ——
/// **操作离对象太远**。TapNow 那类画布的心智是"节点自己就是执行单元"，参数与运行都长在节点上。
///
/// 所以这里把「跑 / 模型 / 比例 / 分辨率 / 时长 / 配音 / 产物动作」贴到卡片边上，hover 即现。
/// 属性面板不删：它仍然是唯一能看全部参数（含字体、只读信息、模型说明）的地方。
///
/// ## 为什么画在卡片外面（屏幕坐标层）而不是卡片里
///
/// 卡片内部的垂直预算被 `CanvasCardLayout` 逐像素算过、并且有 smoke 断言盯着（文本节点那套
/// 「按实测容器高度分配」就是为修"输入框与 + 区重叠"才做的）。往里再塞一行 30pt 的控件，
/// 等于把那套预算全部重推一遍，而且节点被拖矮时第一个被挤爆的就是它。
///
/// 放在外面还有一个好处：尺寸**不随 zoom 缩放**。25% 视图下跟着缩的按钮点不中，而"跑一下"
/// 是这条链路上最高频的动作 —— 操作把手属于"操作尺度"，不属于画布内容。
struct CanvasNodeActionBar: View {

    let node: CanvasNode
    @ObservedObject var canvas: CanvasStore
    @ObservedObject var catalog: CrateModelCatalogStore
    /// 上游连线给这个节点带来了什么（用来显示"来自上游"的小标记）。
    let upstreamCount: Int
    let onRun: () -> Void
    let onSpawnDownstream: () -> Void
    let onRevealAsset: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            runControl
            if node.kind.producesAsset {
                Divider().frame(height: 16).opacity(0.35)
                modelChip
                if currentModel?.supportsRatio ?? true { ratioChip }
                if isVideo {
                    if currentModel?.supportsResolution ?? false { resolutionChip }
                    if currentModel?.supportsDuration ?? false { durationChip }
                    if currentModel?.supportsAudio ?? false { audioChip }
                }
            }
            Divider().frame(height: 16).opacity(0.35)
            spawnButton
            if case .succeeded(let path) = node.state, !path.isEmpty {
                revealButton(path)
            }
            if upstreamCount > 0 { upstreamBadge }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(AppTheme.canvasChromeSurface)
                .overlay(Capsule(style: .continuous).stroke(AppTheme.subtleBorder.opacity(0.9), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.16), radius: 6, x: 0, y: 2)
        )
        .onAppear { catalog.loadIfNeeded() }
    }

    // MARK: 跑

    /// 运行 / 重跑 / 进行中。
    ///
    /// 进行中显示的是**状态**而不是一个禁用的按钮：禁用态按钮什么都不说，而用户此刻唯一想知道的
    /// 就是"它到底在跑吗、跑了多久"（节点状态里存的 `startedAt` 正是为此）。
    @ViewBuilder
    private var runControl: some View {
        if !node.kind.producesAsset {
            // 文本节点没有"跑"这件事。给一句说明而不是留空：空白会让人以为按钮没加载出来。
            Label("文本节点", systemImage: "text.alignleft")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.canvasCardMetaInk)
        } else {
            switch node.state {
            case .queued, .running:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                    Text(runningLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.chromeAccentInk)
                }
                .padding(.horizontal, 4)
            default:
                Button(action: onRun) {
                    Label(isRerun ? "重跑" : "生成",
                          systemImage: isRerun ? "arrow.clockwise" : "play.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(AppTheme.chromeAccentInk))
                }
                .buttonStyle(.plain)
                .help(isRerun ? "用当前参数重新生成" : "生成")
            }
        }
    }

    private var isRerun: Bool {
        switch node.state {
        case .succeeded, .failed: return true
        default: return false
        }
    }

    private var runningLabel: String {
        switch node.state {
        case .queued(let ahead): return ahead > 0 ? "排队 \(ahead)" : "排队中"
        case .running(let startedAt):
            let secs = max(0, Int(Date().timeIntervalSince(startedAt)))
            return "生成中 \(secs)s"
        default: return ""
        }
    }

    // MARK: 参数 chip

    private var modelChip: some View {
        Menu {
            if models.isEmpty {
                Text(catalog.isLoading ? "正在取模型清单…" : "模型清单不可用")
            }
            ForEach(models, id: \.id) { info in
                Button {
                    CanvasGenerationParamEdits.applyModel(info.id, node: node, canvas: canvas, catalog: catalog)
                } label: {
                    Label(info.displayName, systemImage: info.id == node.model ? "checkmark" : "cube")
                }
            }
        } label: {
            chipLabel(text: currentModel?.displayName ?? node.model, systemImage: "cube")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("模型")
    }

    private var ratioChip: some View {
        Menu {
            if ratioOptions.isEmpty { Text("该模型未公布比例档位") }
            ForEach(ratioOptions, id: \.value) { option in
                Button {
                    canvas.updateNodeGeneration(id: node.id, ratio: option.value)
                } label: {
                    Label(option.label, systemImage: option.value == node.ratio ? "checkmark" : "aspectratio")
                }
            }
        } label: {
            chipLabel(text: node.ratio.isEmpty ? "比例" : node.ratio, systemImage: "aspectratio")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("比例")
    }

    private var resolutionChip: some View {
        Menu {
            Button {
                canvas.updateNodeGeneration(id: node.id, resolution: "")
            } label: {
                Label("模型默认", systemImage: node.resolution.isEmpty ? "checkmark" : "sparkles")
            }
            ForEach(currentModel?.resolutionOptions ?? [], id: \.value) { option in
                Button {
                    canvas.updateNodeGeneration(id: node.id, resolution: option.value)
                } label: {
                    Label(option.label, systemImage: option.value == node.resolution ? "checkmark" : "arrow.up.left.and.arrow.down.right")
                }
            }
        } label: {
            chipLabel(text: node.resolution.isEmpty ? "默认" : node.resolution, systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("分辨率")
    }

    private var durationChip: some View {
        Menu {
            Button {
                canvas.updateNodeGeneration(id: node.id, duration: 0)
            } label: {
                Label("模型默认", systemImage: (node.duration ?? 0) == 0 ? "checkmark" : "sparkles")
            }
            ForEach(durationOptions, id: \.self) { secs in
                Button {
                    canvas.updateNodeGeneration(id: node.id, duration: secs)
                } label: {
                    Label("\(secs) 秒", systemImage: node.duration == secs ? "checkmark" : "timer")
                }
            }
        } label: {
            chipLabel(text: (node.duration ?? 0) > 0 ? "\(node.duration!)s" : "时长", systemImage: "timer")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("时长")
    }

    private var audioChip: some View {
        Button {
            canvas.updateNodeGeneration(id: node.id, generateAudio: .some(!audioOn))
        } label: {
            chipLabel(text: audioOn ? "配音开" : "配音关",
                      systemImage: audioOn ? "speaker.wave.2.fill" : "speaker.slash",
                      emphasized: audioOn)
        }
        .buttonStyle(.plain)
        .help("是否生成配音")
    }

    // MARK: 产物动作

    private var spawnButton: some View {
        Button(action: onSpawnDownstream) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.canvasChromeInk)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help("以它为输入新建下游节点")
    }

    private func revealButton(_ path: String) -> some View {
        Button {
            onRevealAsset(path)
        } label: {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.canvasChromeInk)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help("在访达中显示产物")
    }

    private var upstreamBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.right.to.line")
                .font(.system(size: 9, weight: .bold))
            Text("\(upstreamCount)")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(AppTheme.chromeAccentInk)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(AppTheme.chromeAccentSoftFill))
        .help("有 \(upstreamCount) 条上游连线参与这次生成")
    }

    // MARK: 零件

    private func chipLabel(text: String, systemImage: String, emphasized: Bool = false) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
        }
        .foregroundColor(emphasized ? AppTheme.chromeAccentInk : AppTheme.canvasChromeInk)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(emphasized ? AppTheme.chromeAccentSoftFill : AppTheme.previewBackground)
        )
    }

    /// 配音开关的当前值。`nil` 当 true —— 与属性面板同一口径（见 `CanvasInspectorPanel`）：
    /// 支持配音的模型默认就出声，把 nil 读成"关"会让第一次生成静音而 UI 上没人说过要关。
    private var audioOn: Bool { node.generateAudio ?? true }

    private var isVideo: Bool { node.kind == .video }

    private var models: [CrateModelCatalog.ModelInfo] {
        CanvasGenerationParamEdits.models(for: node.kind, catalog: catalog)
    }

    private var currentModel: CrateModelCatalog.ModelInfo? {
        catalog.model(id: node.model)
    }

    private var ratioOptions: [CrateModelCatalog.RatioOption] {
        currentModel?.ratioOptions ?? []
    }

    /// 时长档位。区间型模型按 step 列档（实测上限 15 秒，列表不会长到离谱）；枚举型直接列。
    private var durationOptions: [Int] {
        guard let spec = currentModel?.durationSpec else { return [] }
        switch spec {
        case .options(let values):
            return values.filter { $0 > 0 }.sorted()
        case .range(let lo, let hi, let step, _):
            guard hi >= lo else { return [] }
            return Array(stride(from: lo, through: hi, by: max(step, 1)))
        }
    }
}
