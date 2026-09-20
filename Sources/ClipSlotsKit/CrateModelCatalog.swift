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

    /// 时长的可选形态（v2.11.19）。
    ///
    /// 必须是"两种形态"而不是一个 min/max：实测 6 个 Seedance/MiniMax 模型给的是
    /// `min/max/step`（连续区间），而 `veo-3.1-generate-preview` 给的是 `options: [4, 6, 8]`
    /// （离散枚举）。用 min/max 去套 veo 会让 UI 允许选 5s、提交才被拒；用枚举去套 seedance 会
    /// 把 4~30 秒砍成几个档。
    public enum DurationSpec: Equatable {
        /// 连续区间。`specialValues` 是区间外仍然合法的值（实测只有 `-1` = 交给服务端定）。
        case range(min: Int, max: Int, step: Int, specialValues: [Int])
        /// 离散枚举。
        case options([Int])

        /// 这个时长合法吗。
        public func allows(_ value: Int) -> Bool {
            switch self {
            case .range(let min, let max, let step, let special):
                if special.contains(value) { return true }
                guard value >= min, value <= max else { return false }
                guard step > 1 else { return true }
                return (value - min) % step == 0
            case .options(let list):
                return list.contains(value)
            }
        }

        /// 把一个值夹到合法范围内。换模型时用（30s 的 seedance25 换成 12s 上限的 Pro 1）。
        public func clamped(_ value: Int) -> Int {
            switch self {
            case .range(let min, let max, let step, let special):
                if special.contains(value) { return value }
                let bounded = Swift.min(Swift.max(value, min), max)
                guard step > 1 else { return bounded }
                // 向下取到步长格点：向上可能越过 max。
                return min + ((bounded - min) / step) * step
            case .options(let list):
                guard !list.isEmpty else { return value }
                if list.contains(value) { return value }
                // 取最接近的档，平手时取小的（少花钱那侧）。
                return list.min { abs($0 - value) == abs($1 - value) ? $0 < $1
                                                                     : abs($0 - value) < abs($1 - value) } ?? value
            }
        }

        /// 给 UI 枚举用的候选值。连续区间按步长展开（最长 30 项，不会爆）。
        /// `specialValues` **不进这个列表**：`-1` 在 stepper/picker 里显示成"-1 秒"毫无意义，
        /// 它属于"自动"这个语义，由 UI 单独给入口。
        public var selectableValues: [Int] {
            switch self {
            case .range(let min, let max, let step, _):
                let s = Swift.max(1, step)
                return Array(stride(from: min, through: max, by: s))
            case .options(let list):
                return list
            }
        }
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
        /// 分辨率档选项（视频模型用），顺序同上。图像模型这里通常是空的——它们把分辨率混在
        /// `ratio` 里给（`2K` / `16:9 4K`），那种复合值仍然走 `ratioOptions`。
        public let resolutionOptions: [RatioOption]
        /// 时长规格。非视频模型为 nil。
        public let durationSpec: DurationSpec?
        /// 时长默认值（CLI 的 `defaultValue`）。
        public let durationDefault: Int?
        /// 必须带输入图吗（实测只有 `veo-3.1-generate-preview`）。
        public let requiresImageInput: Bool
        /// 声明了 `last_frame` 角色吗。
        public let supportsLastFrame: Bool
        /// `reference_image` 角色的数量上限（0 = 不支持参考图）。
        public let referenceImageMaxCount: Int
        /// 首帧/尾帧与参考图**互斥**吗（v2.11.19）。
        ///
        /// 实测 7 个视频模型里有 5 个声明了这条约束（seedance25 / seedance2 / minimax-h3 /
        /// veo：`First/last frames cannot be combined with multimodal references.`），只有
        /// seedance2-mini 和两个 Pro 没有。它直接决定"槽位里挂了 3 张图"该怎么拆：
        /// 互斥的模型只能拿前两张当首尾帧、余下的必须丢掉，硬凑成
        /// `--first-frame + --reference-image` 会被整次拒收。
        public let framesExcludeReferences: Bool
        public let enabled: Bool

        public init(id: String,
                    displayName: String,
                    family: String,
                    generationTypes: [String],
                    parameterNames: Set<String>,
                    ratioOptions: [RatioOption],
                    resolutionOptions: [RatioOption] = [],
                    durationSpec: DurationSpec? = nil,
                    durationDefault: Int? = nil,
                    requiresImageInput: Bool = false,
                    supportsLastFrame: Bool = false,
                    referenceImageMaxCount: Int = 0,
                    framesExcludeReferences: Bool = false,
                    enabled: Bool) {
            self.id = id
            self.displayName = displayName
            self.family = family
            self.generationTypes = generationTypes
            self.parameterNames = parameterNames
            self.ratioOptions = ratioOptions
            self.resolutionOptions = resolutionOptions
            self.durationSpec = durationSpec
            self.durationDefault = durationDefault
            self.requiresImageInput = requiresImageInput
            self.supportsLastFrame = supportsLastFrame
            self.referenceImageMaxCount = referenceImageMaxCount
            self.framesExcludeReferences = framesExcludeReferences
            self.enabled = enabled
        }

        /// 能不能出图。`text-2-image`（文生图）或 `image-2-image`（图生图）任一即可 —— 本 App 的
        /// 图像节点两种都会走：槽位挂了参考图就是后者。
        public var isImageGenerator: Bool {
            generationTypes.contains { CrateModelCatalog.imageGenerationTypes.contains($0) }
        }

        /// 能不能出视频。`text-2-video` 或 `image-to-video` 任一即可，理由同 `isImageGenerator`：
        /// 视频节点两种都会走，槽位挂了图就是图生视频。
        ///
        /// 注意**不能把 `video-remove-bg` / `video-to-storyboard` 算进来**：那两类是"吃视频吐
        /// 视频/文本"的加工模型，走的是 `generate transform`，提交参数完全不同（没有 prompt/时长）。
        public var isVideoGenerator: Bool {
            generationTypes.contains { CrateModelCatalog.videoGenerationTypes.contains($0) }
        }

        /// 吃不吃参考图。槽位挂了图但模型只会文生图时，用它给一句提前告知。
        public var acceptsImageInput: Bool { generationTypes.contains("image-2-image") }

        /// 视频模型吃不吃输入图（图生视频）。
        public var acceptsVideoImageInput: Bool { generationTypes.contains("image-to-video") }

        /// 吃不吃 `--ratio`。**按参数表判定而不是"有没有选项"**：参数在、选项空（CLI 只给自由
        /// 输入）时仍然应该允许把已有比例传下去。
        public var supportsRatio: Bool { parameterNames.contains(CrateModelCatalog.ratioParameterName) }

        /// 吃不吃 `--resolution` / `--duration` / `--generate-audio`。判定口径同 `supportsRatio`：
        /// 看参数表，不看选项是否为空。传模型没声明的参数会被 CLI 当场拒收（整次生成失败），
        /// 所以这三个开关是"能不能传"的唯一依据。
        public var supportsResolution: Bool {
            parameterNames.contains(CrateModelCatalog.resolutionParameterName)
        }

        public var supportsDuration: Bool {
            parameterNames.contains(CrateModelCatalog.durationParameterName)
        }

        public var supportsAudio: Bool {
            parameterNames.contains(CrateModelCatalog.audioParameterName)
        }

        public var supportsSeed: Bool { parameterNames.contains(CrateGeneration.seedParameterName) }
    }

    /// 出图类型白名单。
    public static let imageGenerationTypes: Set<String> = ["text-2-image", "image-2-image"]

    /// 出视频类型白名单。
    public static let videoGenerationTypes: Set<String> = ["text-2-video", "image-to-video"]

    public static let ratioParameterName = "ratio"
    public static let resolutionParameterName = "resolution"
    public static let durationParameterName = "duration"
    public static let audioParameterName = "generate_audio"

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

            // 分辨率档与比例同构解析（v2.11.19）。注意**不做大小写归一**：CLI 的校验是精确匹配，
            // 而同一概念在不同模型里写法不同（seedance 的 `4k` vs minimax 的 `2K`）。
            let resolutionParam = params.first { ($0["name"] as? String) == resolutionParameterName }
            let resolutions = ((resolutionParam?["options"] as? [[String: Any]]) ?? []).compactMap { opt -> RatioOption? in
                guard let value = (opt["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { return nil }
                let label = (opt["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value
                return RatioOption(value: value, label: label)
            }

            let durationParam = params.first { ($0["name"] as? String) == durationParameterName }
            let durationSpec = parseDurationSpec(durationParam)
            let durationDefault = (durationParam?["defaultValue"]).flatMap { intValue($0) }

            let refs = (dict["references"] as? [String: Any]) ?? [:]
            let roles = (refs["roles"] as? [[String: Any]]) ?? []
            let requiresImage = (((dict["inputs"] as? [String: Any])?["image"] as? [String: Any])?["required"] as? Bool) ?? false
            let hasLastFrame = roles.contains { ($0["role"] as? String) == "last_frame" }
            let refImageMax = roles.first { ($0["role"] as? String) == "reference_image" }
                .flatMap { intValue($0["maxCount"]) } ?? 0
            let exclusive = parseFramesExcludeReferences((refs["constraints"] as? [[String: Any]]) ?? [])

            let name = (dict["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return ModelInfo(id: id,
                             displayName: name,
                             family: (dict["family"] as? String) ?? "",
                             generationTypes: (dict["generationTypes"] as? [String]) ?? [],
                             parameterNames: names,
                             ratioOptions: options,
                             resolutionOptions: resolutions,
                             durationSpec: durationSpec,
                             durationDefault: durationDefault,
                             requiresImageInput: requiresImage,
                             supportsLastFrame: hasLastFrame,
                             referenceImageMaxCount: refImageMax,
                             framesExcludeReferences: exclusive,
                             // 缺字段按可用处理：漏掉一个能用的模型，比凭空多显示一个更难被发现。
                             enabled: (dict["enabled"] as? Bool) ?? true)
        }
    }

    /// 从 duration 参数条目里解析出时长规格。
    ///
    /// `options` 优先于 `min/max`：veo 同时给不出两者，但如果将来某个模型两者都给，枚举是更严格的
    /// 那一侧，按它走不会产生"UI 允许、提交被拒"。
    static func parseDurationSpec(_ param: [String: Any]?) -> DurationSpec? {
        guard let param else { return nil }
        if let opts = param["options"] as? [[String: Any]] {
            let values = opts.compactMap { intValue($0["value"]) }
            if !values.isEmpty { return .options(values) }
        }
        guard let min = intValue(param["min"]), let max = intValue(param["max"]) else { return nil }
        let step = intValue(param["step"]) ?? 1
        let special = (param["specialValues"] as? [Any])?.compactMap { intValue($0) } ?? []
        return .range(min: min, max: max, step: Swift.max(1, step), specialValues: special)
    }

    /// 首尾帧与参考图互斥吗。
    ///
    /// 只认 `mutually-exclusive-groups` 这一种约束，且只认"一组里有 first_frame、另一组里有
    /// reference_image"这一种形状 —— 其余约束（`requires-any` / `aggregate-max` /
    /// `combined-max`）要么由我们的分配规则天然满足（尾帧永远伴随首帧），要么只在参考视频/音频
    /// 上生效（本版不传那两类）。**只解析用得到的那一条**：把整套约束系统搬进 App 等于把服务端的
    /// 校验逻辑抄一遍，抄漏一条比不抄更危险（会理直气壮地拦掉合法请求）。
    static func parseFramesExcludeReferences(_ constraints: [[String: Any]]) -> Bool {
        for c in constraints where (c["type"] as? String) == "mutually-exclusive-groups" {
            let groups = (c["groups"] as? [[String]]) ?? []
            let hasFrameGroup = groups.contains { $0.contains("first_frame") }
            let hasRefGroup = groups.contains { $0.contains("reference_image") }
            if hasFrameGroup && hasRefGroup { return true }
        }
        return false
    }

    /// JSON 数字的宽容读取。CLI 里同一个字段有时是 `5`、有时是 `"5"`（`queue_ahead_count` 就是
    /// 字符串），所以两种都收——只认 Int 的代价是某个模型的时长规格静默变成 nil，UI 上表现为
    /// "时长选择器凭空消失"。
    static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
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

    /// 可选进 picker 的出视频模型（v2.11.19）。口径与 `imageModels` 完全一致。
    public static func videoModels(_ all: [ModelInfo]) -> [ModelInfo] {
        var seen = Set<String>()
        return all.filter { $0.enabled && $0.isVideoGenerator && seen.insert($0.id).inserted }
    }

    /// 换模型后，把分辨率落到一个**该模型真的接受**的值上（v2.11.19）。
    ///
    /// 退让顺序与 `resolvedRatio` 同构，但兜底项不同：比例的中性兜底是 `1:1`（方图不改变构图倾向），
    /// 分辨率没有"中性档"，所以**兜底取第一个选项**——实测各模型的首项都是最低档
    /// （480p / 768P / 720p），这正好让"换模型"这个动作不会悄悄把成本翻几倍。
    public static func resolvedResolution(current: String, for model: ModelInfo) -> String {
        guard model.supportsResolution else { return "" }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.resolutionOptions.isEmpty else { return trimmed }
        if model.resolutionOptions.contains(where: { $0.value == trimmed }) { return trimmed }
        return model.resolutionOptions[0].value
    }

    /// 换模型后，把时长落到一个该模型真的接受的值上（v2.11.19）。
    ///
    /// nil 进 nil 出：「没设过时长」是一个要保留的状态（提交时不传 `--duration`，用模型默认值），
    /// 不能在换模型时被"顺手补成 5"——那会让 veo 这种默认 8s 的模型悄悄变成 8s 以外的值。
    public static func resolvedDuration(current: Int?, for model: ModelInfo) -> Int? {
        guard model.supportsDuration, let spec = model.durationSpec else { return nil }
        guard let current else { return nil }
        return spec.allows(current) ? current : spec.clamped(current)
    }

    /// 把槽位里的图片附件按角色分配给视频模型（v2.11.19）。
    ///
    /// 规则（顺序即语义，见 `CrateVideoRequest` 的类型注释）：
    ///   1. 第 1 张 → 首帧；
    ///   2. 第 2 张 → 尾帧，**仅当模型声明了 `last_frame` 角色**；否则这张退回参考图队列；
    ///   3. 其余 → 参考图，按 `referenceImageMaxCount` 截断；**模型声明首尾帧与参考图互斥时
    ///      这一步整个跳过**（见 `framesExcludeReferences`）。
    ///
    /// 模型压根不吃图（纯文生视频）时返回全空——那种情况下把图传上去要么被拒、要么被忽略，
    /// 两种都不如在 UI 上明确告诉用户"这个模型不吃图"。
    public static func assignVideoFrames(imagePaths: [String],
                                        model: ModelInfo) -> (first: String?, last: String?, references: [String]) {
        guard model.acceptsVideoImageInput, !imagePaths.isEmpty else { return (nil, nil, []) }
        var rest = imagePaths
        let first = rest.removeFirst()
        var last: String?
        if model.supportsLastFrame, !rest.isEmpty {
            last = rest.removeFirst()
        }
        // 互斥的模型：已经出了首/尾帧，剩下的图**必须丢掉**（见 `framesExcludeReferences`）。
        // 丢图比整次被拒好——用户看到的是"只用了前两张"，而不是一条服务端英文报错。
        guard !model.framesExcludeReferences else { return (first, last, []) }
        let refs = model.referenceImageMaxCount > 0 ? Array(rest.prefix(model.referenceImageMaxCount)) : []
        return (first, last, refs)
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
