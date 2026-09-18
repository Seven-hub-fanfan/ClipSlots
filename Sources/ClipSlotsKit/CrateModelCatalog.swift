import Foundation

/// Crate 模型目录（v2.11.18）。
///
/// ## 为什么不写死一张模型/比例表
///
/// 节点的 `model` 与 `ratio` 从一开始就是可持久化字段，缺的只是选择入口。而"选什么"这件事
/// **不能由 App 猜**：
///
///   - 模型目录是线上的，会增会删（`enabled` 字段就是为下线准备的）。写死列表的后果是用户在
///     picker 里选了一个已经下线的模型，点生成才报错。
///   - **比例选项是每个模型各自声明的，且互不相同**。实测：`seedream45` 给
///     `2K / 4K / 1:1 / 4:3 / …`（`1K` 在 seedream4 有、45 没有），`gpt-image-1.5` 只给
///     `1:1 / 3:2 / 2:3` 三档，`gpt-image-2` 还有 `16:9 4K` 这种"比例+分辨率"的复合值。
///     用一张统一的常用比例表去喂所有模型，等于把"选项看着能选、提交就被拒"做成默认体验。
///   - 更要命的一类：**有些出图模型压根没有 `ratio` 参数**（`t2i_qwen_image`、`t2i_z_image`、
///     `seed3_tt_aoc`、`seededit_v16` 走的是 `width`/`height`）。对它们必须**不传** `--ratio`，
///     所以尺寸选择器要能进入"该模型不吃比例"这一档，而不是硬塞一个 1:1。
///
/// 所以目录一律现问 CLI：`crate model list --json`。这个 enum 只做**解析与筛选**（纯函数、
/// 有 smoke 覆盖），进程调用在 `CrateModelCatalogStore`（App 层）。
///
/// ## 与 seed 那道门禁的关系
///
/// `CrateGeneration.parseModelParameterNames` 读的是 `model describe`（单个模型），用于提交前
/// 决定要不要带 `--param seed=N`。这里读的是 `model list`（全量），用于**填 picker**。两者字段
/// 口径一致（都是 `parameters[].name`），但请求次数与时机不同，刻意不合并：填 picker 不该为了
/// 一次展示去串行 describe 十几个模型。
public enum CrateModelCatalog {

    // MARK: - 数据

    /// 一个比例选项。`value` 直接交给 `--ratio`，`label` 是 CLI 给的人类可读名。
    public struct RatioOption: Equatable, Hashable, Identifiable {
        public let value: String
        public let label: String

        public var id: String { value }

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }

        /// 是不是"纯分辨率档"（`1K` / `2K` / `4K`）而不是宽高比。
        ///
        /// 用来在 picker 里把两类分开显示：它们混在一个扁平列表里时，用户会以为选了 `2K` 就
        /// 还是方图 —— 实际上分辨率档的构图比例由模型自己定。
        public var isResolutionPreset: Bool { !value.contains(":") }
    }

    /// 一个模型。字段只取 UI 与提交真正用得到的，其余（provider / canonicalId / protocolVersion）
    /// 刻意不带：它们对用户选择没有影响，带进来只会让这个结构跟着 CLI 的字段变动一起抖。
    public struct ModelInfo: Equatable, Identifiable {
        /// 稳定 id（如 `seedream45`），也是 `--model` 的取值。
        public let id: String
        /// CLI 给的展示名（如 `Seedream 4.5`）。缺失时回落 id。
        public let displayName: String
        /// 系列名（如 `Seed3.0`），picker 里分组用。可能为空。
        public let family: String
        public let generationTypes: [String]
        public let parameterNames: Set<String>
        /// 该模型声明的比例选项，**顺序保持 CLI 原序**（那是策划过的推荐顺序）。
        public let ratioOptions: [RatioOption]
        public let enabled: Bool

        public init(id: String,
                    displayName: String,
                    family: String,
                    generationTypes: [String],
                    parameterNames: Set<String>,
                    ratioOptions: [RatioOption],
                    enabled: Bool) {
            self.id = id
            self.displayName = displayName
            self.family = family
            self.generationTypes = generationTypes
            self.parameterNames = parameterNames
            self.ratioOptions = ratioOptions
            self.enabled = enabled
        }

        /// 能不能出图。`text-2-image`（文生图）或 `image-2-image`（图生图）任一即可 —— 本 App 的
        /// 图像节点两种都会走：槽位挂了参考图就是后者。
        public var isImageGenerator: Bool {
            generationTypes.contains { CrateModelCatalog.imageGenerationTypes.contains($0) }
        }

        /// 吃不吃参考图。槽位挂了图但模型只会文生图时，用它给一句提前告知。
        public var acceptsImageInput: Bool { generationTypes.contains("image-2-image") }

        /// 吃不吃 `--ratio`。**按参数表判定而不是"有没有选项"**：参数在、选项空（CLI 只给自由
        /// 输入）时仍然应该允许把已有比例传下去。
        public var supportsRatio: Bool { parameterNames.contains(CrateModelCatalog.ratioParameterName) }

        public var supportsSeed: Bool { parameterNames.contains(CrateGeneration.seedParameterName) }
    }

    /// 出图类型白名单。
    public static let imageGenerationTypes: Set<String> = ["text-2-image", "image-2-image"]

    public static let ratioParameterName = "ratio"

    /// 目录查询的超时。比 describe 略宽：一次要返回四十来个模型。
    public static let listTimeout: TimeInterval = 25

    // MARK: - 命令行

    public static func listArguments() -> [String] {
        ["model", "list", "--json"]
    }

    // MARK: - 解析

    /// 解析 `model list --json`。
    ///
    /// 与其它响应不同，这里的根是**数组**，所以不能复用 `CrateGeneration.jsonObject`。
    /// 单个模型条目缺 `id` 时**跳过而不是整批失败**：一个新字段/坏条目不该让整个 picker 空掉。
    public static func parse(_ output: String) throws -> [ModelInfo] {
        guard let slice = firstJSONArray(output),
              let data = slice.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw CrateResponseError.notJSON(output)
        }
        return list.compactMap { entry -> ModelInfo? in
            guard let dict = entry as? [String: Any] else { return nil }
            guard let id = (dict["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else { return nil }

            let params = (dict["parameters"] as? [[String: Any]]) ?? []
            let names = Set(params.compactMap { $0["name"] as? String })
            let ratioParam = params.first { ($0["name"] as? String) == ratioParameterName }
            let options = ((ratioParam?["options"] as? [[String: Any]]) ?? []).compactMap { opt -> RatioOption? in
                guard let value = (opt["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { return nil }
                let label = (opt["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value
                return RatioOption(value: value, label: label)
            }

            let name = (dict["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return ModelInfo(id: id,
                             displayName: name,
                             family: (dict["family"] as? String) ?? "",
                             generationTypes: (dict["generationTypes"] as? [String]) ?? [],
                             parameterNames: names,
                             ratioOptions: options,
                             // 缺字段按可用处理：漏掉一个能用的模型，比凭空多显示一个更难被发现。
                             enabled: (dict["enabled"] as? Bool) ?? true)
        }
    }

    /// 可选进 picker 的出图模型。
    ///
    /// 过滤 `enabled == false`（已下线，选了只会在提交时报错），并按 id 去重（CLI 理论上不会重复，
    /// 但 picker 的 tag 重复会导致选中项显示空白 —— 那个症状看起来正好像"设置没保存"）。
    /// **顺序保持 CLI 原序**：那是按系列排好的，重排成字母序反而把 seedream 家族打散。
    public static func imageModels(_ all: [ModelInfo]) -> [ModelInfo] {
        var seen = Set<String>()
        return all.filter { $0.enabled && $0.isImageGenerator && seen.insert($0.id).inserted }
    }

    /// 换模型后，把比例落到一个**该模型真的接受**的值上。
    ///
    /// 换模型时保留旧比例是最自然的期望（"我只是换了个模型，构图别变"），但旧比例经常不在新模型
    /// 的选项里（`1K` 只有 seedream4 有；gpt-image-1.5 只有三档）。所以按这个顺序退让：
    ///
    ///   1. 新模型不吃 ratio → 返回空串（提交时就不会带 `--ratio`）；
    ///   2. 旧值仍在选项里 → 原样保留；
    ///   3. 选项里有 `1:1` → 用它（方图是最中性的兜底，不会把用户的横图悄悄变成竖图）；
    ///   4. 否则取第一个选项（CLI 的推荐首项）；
    ///   5. 连选项都没有（只有自由输入）→ 保留旧值，让 CLI 自己裁决。
    public static func resolvedRatio(current: String, for model: ModelInfo) -> String {
        guard model.supportsRatio else { return "" }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.ratioOptions.isEmpty else { return trimmed }
        if model.ratioOptions.contains(where: { $0.value == trimmed }) { return trimmed }
        if let square = model.ratioOptions.first(where: { $0.value == "1:1" }) { return square.value }
        return model.ratioOptions[0].value
    }

    /// 取出第一个方括号配平的片段。理由同 `CrateGeneration.firstJSONObject`：`--json` 下 stdout
    /// 本来就是纯 JSON，这是给将来 CLI 往前面加提示行留的余量。字符串里的 `]` 不参与配平。
    public static func firstJSONArray(_ output: String) -> String? {
        guard let start = output.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < output.endIndex {
            let ch = output[idx]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "[": depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 { return String(output[start...idx]) }
                default: break
                }
            }
            idx = output.index(after: idx)
        }
        return nil
    }
}
