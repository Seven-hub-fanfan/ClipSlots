import Foundation

/// Crate CLI 生图链路的**纯逻辑层**（v2.11.17）。
///
/// 这里只做三件不碰 IO 的事：拼命令行参数、解析 CLI 的 JSON、把 Crate 的任务状态翻译成
/// `CanvasNodeState` 能表达的语义。`Process` 启动、超时看门狗、下载落盘全在 App 层的
/// `CrateGenerationService`。
///
/// ★ 为什么要把纯逻辑单独拆出来
///
/// 本机只有 Command Line Tools（无完整 Xcode），XCTest 跑不起来，日常自测靠
/// `swift run ClipSlotsKitSmokeTests`——而 smoke 跑在 Kit 上。参数拼接与 JSON 解析恰好是
/// 这条链路里最容易出静默错误的部分（少一个 `--no-wait` 就变成阻塞 10 分钟、状态码看反了就
/// 把成功当失败），所以它们必须待在能被断言覆盖的那一侧。
///
/// ★ 口径来源
///
/// 下面每一个字段名都来自本机实测（crate v0.6.1，2026-09-18），不是照文档猜的：
///   - 提交：`crate generate image --model M --prompt P --ratio R --no-wait --json`
///     → stdout `{"input":{…,"extra_params_json":"{\"seed\":625766}"},"success":true,"taskId":"768…"}`
///   - 轮询：`crate task get <id> --json`
///     → 运行中 `{"taskInfo":{"queue_ahead_count":"0","queue_phase":"RUNNING","task_status":1}}`
///     → 成功  `{"taskInfo":{"results":[{"content":"https://…jpeg","content_type":0,"media_type":0}],"task_status":2}}`
///   - 批查：`crate task query --ids a,b` → `{"taskInfos":[…]}`
///
/// 注意 `--json` 下进度提示（"Submitting generation..."）走 **stderr**，stdout 是纯 JSON，
/// 所以解析时不必做"跳过前导非 JSON 行"的容错——但为了不被将来的 CLI 版本打回原形，
/// `firstJSONObject` 仍保留了一层宽容裁剪。

// MARK: - 请求

/// 一次图像生成请求（对应画布上一个节点的一次「生成」）。
public struct CrateImageRequest: Equatable {
    /// 模型 stable id，如 `seedream45`。
    public var model: String
    /// 提示词。当场从槽位正文读，不缓存（节点不持有内容，见 `CanvasNode` 注释）。
    public var prompt: String
    /// 已发布的比例，如 `1:1`。空串表示不传，交给模型默认值。
    public var ratio: String
    /// 张数。v2.11.17 只支持 1，见 `submitArguments` 的校验。
    public var count: Int
    /// 入参图片的**本地绝对路径**（图生图）。CLI 的 `--image` 可重复传。
    public var imagePaths: [String]
    /// 复现用 seed。nil = 让服务端随机。
    public var seed: Int?

    public init(model: String,
                prompt: String,
                ratio: String = "",
                count: Int = 1,
                imagePaths: [String] = [],
                seed: Int? = nil) {
        self.model = model
        self.prompt = prompt
        self.ratio = ratio
        self.count = count
        self.imagePaths = imagePaths
        self.seed = seed
    }
}

/// 一次视频生成请求（v2.11.19）。
///
/// ★ 为什么不复用 `CrateImageRequest` 加几个可选字段
///
/// 两条链路的**必填与拒绝条件不同**：视频这边 `duration` / `resolution` 各模型区间不一样
/// （2~12 / 4~15 / 4~30，veo 还是 4/6/8 枚举），`veo-3.1-generate-preview` 更是**必须带图**
/// （`inputs.image.required = true`）。把这些挤进同一个结构，`submitArguments` 就得靠
/// `if isVideo` 分叉，而那正是"图像链路改一行把视频链路带崩"的经典形态。两个结构 + 两个
/// 拼参数函数，各自被 smoke 钉死，反而是更小的维护面。
///
/// ★ 首帧 / 尾帧 / 参考图的分工
///
/// 槽位里的图片附件按顺序映射：第 1 张 → `--first-frame`，第 2 张 → `--last-frame`
/// （模型声明了 `last_frame` 角色才给），再往后 → `--reference-image`（按模型的
/// `reference_image.maxCount` 截断）。刻意不用 `--image`：视频模型的 `inputs.image` 只是
/// 一个"总数上限"的声明，真正决定语义的是 references 里的角色名，把 9 张图一股脑
/// `--image` 传进去，服务端怎么理解它们是不确定的。
public struct CrateVideoRequest: Equatable {
    /// 模型 stable id，如 `seedance2`。
    public var model: String
    /// 提示词。
    public var prompt: String
    /// 已发布的比例，如 `16:9` / `adaptive`。空串 = 不传。
    public var ratio: String
    /// 已发布的分辨率档，如 `720p` / `4k` / `768P`。空串 = 不传。
    ///
    /// **大小写按 CLI 原样传**：实测同一个概念在不同模型里写法不同（seedance2 是 `4k`，
    /// minimax 是 `2K` / `768P`），CLI 的校验是精确匹配（`resolution must be one of: …`），
    /// 顺手 `.lowercased()` 会把 minimax 的选项全部打成非法值。
    public var resolution: String
    /// 时长（秒）。nil = 不传，用模型默认值。`-1` 是部分模型（seedance2 / seedance25）声明的
    /// 特殊值，语义是"让服务端自己定"，因此不做正数校验。
    public var duration: Int?
    /// 要不要生成配音。nil = 不传（模型不声明这个参数时必须是 nil，否则 CLI 当场拒收）。
    public var generateAudio: Bool?
    /// 首帧图本地路径。
    public var firstFramePath: String?
    /// 尾帧图本地路径。
    public var lastFramePath: String?
    /// 参考图本地路径（已按模型上限截断）。
    public var referenceImagePaths: [String]
    /// 复现用 seed。nil = 让服务端随机。
    public var seed: Int?

    public init(model: String,
                prompt: String,
                ratio: String = "",
                resolution: String = "",
                duration: Int? = nil,
                generateAudio: Bool? = nil,
                firstFramePath: String? = nil,
                lastFramePath: String? = nil,
                referenceImagePaths: [String] = [],
                seed: Int? = nil) {
        self.model = model
        self.prompt = prompt
        self.ratio = ratio
        self.resolution = resolution
        self.duration = duration
        self.generateAudio = generateAudio
        self.firstFramePath = firstFramePath
        self.lastFramePath = lastFramePath
        self.referenceImagePaths = referenceImagePaths
        self.seed = seed
    }
}

/// 参数层面的拒绝原因。刻意区分得这么细，是因为每一种对应用户完全不同的下一步动作：
/// 空提示词要去填正文，张数不支持要去改参数栏，模型空是 UI 出了 bug。
public enum CrateRequestError: Error, Equatable {
    case emptyPrompt
    case emptyModel
    case unsupportedCount(Int)
    /// 模型要求必须带输入图，但槽位里没有可用图片（实测只有 `veo-3.1-generate-preview`）。
    case missingRequiredImage(model: String)

    public var userMessage: String {
        switch self {
        case .emptyPrompt: return "槽位正文是空的，先写提示词再生成"
        case .emptyModel: return "没有选择模型"
        case .unsupportedCount(let n): return "当前版本一次只出 1 张（现在是 \(n) 张）"
        case .missingRequiredImage(let model):
            return "\(model) 必须带一张输入图，先往这个槽位挂张图片"
        }
    }
}

/// CLI 输出解析失败。`detail` 一律保留原文片段，不做归纳——归纳过的报错在排查时等于没有。
public enum CrateResponseError: Error, Equatable {
    case notJSON(String)
    case submissionRejected(String)
    case missingTaskId
    case unknownTaskStatus(Int)

    public var userMessage: String {
        switch self {
        case .notJSON(let raw):
            return "CLI 返回的不是 JSON：\(CrateGeneration.clip(raw))"
        case .submissionRejected(let detail):
            return "提交被拒绝：\(CrateGeneration.clip(detail))"
        case .missingTaskId:
            return "CLI 没有返回 taskId"
        case .unknownTaskStatus(let code):
            return "未知任务状态码 \(code)"
        }
    }
}

// MARK: - 任务进展

/// Crate 任务的一次观测结果。与 `CanvasNodeState` 不是同一个类型：状态机里的
/// `running(startedAt:)` 需要"本地开始时刻"，那是 App 层的事，这里只负责说「服务端现在什么样」。
public enum CrateTaskProgress: Equatable {
    case queued(ahead: Int)
    case running
    /// 成功。`assetURLs` 是可直接下载的 CDN 地址（实测 `results[].content`）。
    case succeeded(assetURLs: [String])
    case failed(reason: String)
}

// MARK: - 纯逻辑门面

public enum CrateGeneration {

    // MARK: 常量

    /// 节点参数栏的默认模型。与 `CanvasNode.model` 的默认值保持一致。
    public static let defaultModel = "seedream45"
    /// 视频节点的默认模型（v2.11.19）。
    ///
    /// 选 `seedance2` 而不是更新的 `seedance25`：2.0 的时长上限 15s、分辨率到 4k，已经覆盖绝大多数
    /// 用法，而 2.5 的卖点（30s 长视频 / 50 份参考素材 / edit+extend）目前在本 App 里都还没有入口，
    /// 默认给它只会让每次出片都更慢更贵。
    public static let defaultVideoModel = "seedance2"
    /// 提交进程的超时。提交本身只是一次 HTTP，给 120s 是为了容忍 Node 冷启动 + 网络抖动。
    public static let submitTimeout: TimeInterval = 120
    /// 单次轮询进程的超时。
    public static let pollProcessTimeout: TimeInterval = 60
    /// 轮询间隔 / 总时限：与 CLI 自己的默认值（5s / 600s）对齐，避免两套节奏。
    public static let pollInterval: TimeInterval = 5
    public static let pollTimeout: TimeInterval = 600
    /// 视频任务的总时限（v2.11.19）。
    ///
    /// 图像那 600s 对视频是**不够的**：实测 seedance2-mini 480p/4s 这种最便宜的组合就要 ~80s，
    /// 而 seedance25 允许 30s 时长、seedance2 允许 4k，排队高峰时十几分钟是正常的。600s 超时的
    /// 症状特别恶劣——任务在服务端**已经成功并扣了额度**，App 这边却报"超时失败"，用户只会再点
    /// 一次重跑，于是扣两份。给 1800s 是"宁可等久点也别误判"，用户想放弃随时能取消。
    public static let videoPollTimeout: TimeInterval = 1800
    /// 模型参数表查询（`model describe`）的超时。它只是一次元数据请求，超时也不致命（有重试兜底）。
    public static let describeTimeout: TimeInterval = 20
    /// 前置体检（`auth status`）的超时。它只读本地 session + 一次轻请求，超过 20s 基本是网络挂了。
    public static let authCheckTimeout: TimeInterval = 20

    /// 实测状态码。只认这两个，其余一律按失败处理——猜一张完整枚举表不如把原文交给用户。
    public static let statusRunning = 1
    public static let statusSucceeded = 2

    // MARK: 命令行参数

    /// 提交一次生成。
    ///
    /// 刻意始终带 `--no-wait`：阻塞模式把提交、轮询、下载揉进一个进程，App 拿不到中间的排队
    /// 信息，进程被杀掉连 taskId 都留不下——那等于放弃 `queued(ahead:)` 与「复制 taskId」。
    public static func submitArguments(_ req: CrateImageRequest) throws -> [String] {
        let prompt = req.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw CrateRequestError.emptyPrompt }
        let model = req.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw CrateRequestError.emptyModel }
        guard req.count == 1 else { throw CrateRequestError.unsupportedCount(req.count) }

        var args = ["generate", "image", "--model", model, "--prompt", prompt]
        let ratio = req.ratio.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ratio.isEmpty {
            args += ["--ratio", ratio]
        }
        for path in req.imagePaths where !path.isEmpty {
            args += ["--image", path]
        }
        if let seed = req.seed {
            args += ["--param", "seed=\(seed)"]
        }
        args += ["--no-wait", "--json"]
        return args
    }

    /// 提交一次**视频**生成（v2.11.19）。
    ///
    /// ★ 只用"被 CLI 校验过"的旗标
    ///
    /// 实测（crate v0.6.1，2026-09-20）：**未知旗标不会报错，而是被静默忽略并照常提交**——
    /// `crate generate video --model seedance2-mini --prompt test --bogus-xyz 1 --no-wait` 直接
    /// 提交成功。这意味着"拼错参数名"的症状不是报错，而是**参数默默不生效**（用户选了 4k 拿回
    /// 720p，选了 10s 拿回 5s，而且额度已经扣了）。所以这里每一个旗标都用"传非法值看 CLI 报不报"
    /// 的方式验证过其真实存在：
    ///
    ///   - `--ratio` → `ratio must be one of: adaptive, 16:9, …`
    ///   - `--resolution` → `resolution must be one of: 480p, 720p`
    ///   - `--duration` → `duration must be at most 15`
    ///   - `--generate-audio` → `--generate-audio must be true or false`
    ///   - `--param seed=N` → 模型不声明时 `does not publish parameter "seed"`
    ///
    /// 新增旗标前请照这个方式验一遍，别照文档抄。
    ///
    /// ★ 为什么 `generateAudio` 是 `Bool?` 而不是 `Bool`
    ///
    /// `generate_audio` 只有 Seedance 2.x 家族声明。对 Pro 1 / VEO / MiniMax 传它，CLI 当场拒收
    /// （`Model seedancePro1 does not publish parameter "generate_audio"`），整次生成失败。
    /// 所以"不传"必须是可表达的状态，判断"该不该传"的责任在调用方（按模型目录的 `supportsAudio`）。
    public static func submitArguments(_ req: CrateVideoRequest) throws -> [String] {
        let prompt = req.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw CrateRequestError.emptyPrompt }
        let model = req.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw CrateRequestError.emptyModel }

        var args = ["generate", "video", "--model", model, "--prompt", prompt]
        let ratio = req.ratio.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ratio.isEmpty {
            args += ["--ratio", ratio]
        }
        let resolution = req.resolution.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolution.isEmpty {
            args += ["--resolution", resolution]
        }
        if let duration = req.duration {
            args += ["--duration", "\(duration)"]
        }
        if let audio = req.generateAudio {
            args += ["--generate-audio", audio ? "true" : "false"]
        }
        // 首帧 / 尾帧 / 参考图的顺序就是 CLI 的语义顺序，不能靠"反正都是图"随便排。
        if let first = req.firstFramePath, !first.isEmpty {
            args += ["--first-frame", first]
        }
        if let last = req.lastFramePath, !last.isEmpty {
            args += ["--last-frame", last]
        }
        for path in req.referenceImagePaths where !path.isEmpty {
            args += ["--reference-image", path]
        }
        if let seed = req.seed {
            args += ["--param", "seed=\(seed)"]
        }
        args += ["--no-wait", "--json"]
        return args
    }

    public static func taskGetArguments(taskId: String) -> [String] {
        ["task", "get", taskId, "--json"]
    }

    /// 批量查询。多节点同时生成时用它，而不是每个节点各起一条 `task get`。
    public static func taskQueryArguments(taskIds: [String]) -> [String] {
        ["task", "query", "--ids", taskIds.joined(separator: ","), "--json"]
    }

    public static func authStatusArguments() -> [String] {
        ["auth", "status", "--json"]
    }

    /// 查询模型自己声明的参数表。
    ///
    /// 为什么需要它：`--param seed=N` 不是所有模型都收。实测 `seedream45` 的 `parameters` 只有
    /// prompt / ratio / width / height，传 seed 会被 CLI 当场拒掉
    /// （`Model seedream45 does not publish parameter "seed"`）—— 而**第一次生成是不带 seed 的、
    /// 会成功**，于是这个坑只在「重跑」（刻意复用 seed）时才炸，看起来像"重跑坏了"。
    /// `--param seed=N` 里那个参数名，模型参数表比对用。
    public static let seedParameterName = "seed"

    public static func modelDescribeArguments(model: String) -> [String] {
        ["model", "describe", model, "--json"]
    }

    /// 从 `model describe --json` 里取参数名集合。
    public static func parseModelParameterNames(_ output: String) throws -> Set<String> {
        let root = try jsonObject(output)
        guard let list = root["parameters"] as? [[String: Any]] else { return [] }
        return Set(list.compactMap { stringValue($0["name"]) })
    }

    /// CLI 拒收 seed 的报错识别。
    ///
    /// 参数表查询失败（离线 / 新版 CLI 改了字段）时的第二道保险：提交报这个错就去掉 seed 重试一次，
    /// 而不是把一个纯锦上添花的参数升级成"整次重跑失败"。
    public static func isUnsupportedParameterError(_ text: String, parameter: String = "seed") -> Bool {
        let lower = text.lowercased()
        guard lower.contains(parameter.lowercased()) else { return false }
        return lower.contains("does not publish parameter")
            || lower.contains("unknown parameter")
            || lower.contains("unsupported parameter")
    }

    /// 去掉 seed 的同一份请求。
    public static func droppingSeed(_ req: CrateImageRequest) -> CrateImageRequest {
        var out = req
        out.seed = nil
        return out
    }

    /// 去掉 ratio 的同一份请求。
    ///
    /// 与 seed 那道保险同构，但触发路径不同：ratio 是**用户在尺寸选择器里选的**，正常情况下一定
    /// 来自该模型自己声明的选项（见 `CrateModelCatalog.resolvedRatio`）。这条退路是给两种落差
    /// 兜底：画布里存着老模型时代的比例（换机 / 导入的画布 / 模型下线换了选项集），以及模型目录
    /// 一时问不出来时 UI 只能原样保留旧值。宁可"少一个比例参数但图出来了"，也不要整次生成硬失败。
    public static func droppingRatio(_ req: CrateImageRequest) -> CrateImageRequest {
        var out = req
        out.ratio = ""
        return out
    }

    /// 视频请求的两道同构退路（v2.11.19）。
    ///
    /// 语义与图像那两个完全一致，但**必须分开写**：`CrateVideoRequest` 多了 resolution / duration /
    /// generateAudio 三个字段，用泛型或协议把两者统一起来的收益只是省掉这十行，代价是把
    /// "退哪个参数"这件事从编译期可见变成运行时可见。
    public static func droppingSeed(_ req: CrateVideoRequest) -> CrateVideoRequest {
        var out = req
        out.seed = nil
        return out
    }

    public static func droppingRatio(_ req: CrateVideoRequest) -> CrateVideoRequest {
        var out = req
        out.ratio = ""
        return out
    }

    /// 去掉 resolution 的同一份请求。
    ///
    /// 比图像那两道更容易被触发：视频模型的分辨率选项集**互不兼容且大小写不一致**
    /// （seedance 是 `480p/720p/1080p/4k`，minimax 是 `768P/2K`，veo 的 1080p/4K 还只在 8s 时长下
    /// 可用）。画布里存着换模型前的旧值、或模型目录问不出来时 UI 原样保留旧值，都会走到这里。
    public static func droppingResolution(_ req: CrateVideoRequest) -> CrateVideoRequest {
        var out = req
        out.resolution = ""
        return out
    }

    /// 去掉 generate_audio 的同一份请求。
    ///
    /// 专治 `Model X does not publish parameter "generate_audio"`：模型目录问不出来时 UI 可能把
    /// 音频开关当成"所有视频模型都有"，这条退路保证那种情况下只是"没有配音"而不是整次失败。
    public static func droppingAudio(_ req: CrateVideoRequest) -> CrateVideoRequest {
        var out = req
        out.generateAudio = nil
        return out
    }

    // MARK: 可执行文件与 PATH

    /// crate 可执行文件的候选位置，按优先级。
    ///
    /// 本机实测装在 `~/.local/bin/crate`（软链到 npm 全局包）。**必须走绝对路径**：App 从
    /// Finder/Dock 启动时继承的是 launchd 的精简 PATH，里面没有 `~/.local/bin`，
    /// `/usr/bin/env crate` 会直接 not found。这个坑在 `~/bin/gh` 上已经踩过一次。
    public static func binaryCandidates(homeDirectory home: String) -> [String] {
        [
            "\(home)/.local/bin/crate",
            "\(home)/bin/crate",
            "/opt/homebrew/bin/crate",
            "/usr/local/bin/crate",
        ]
    }

    /// 传给子进程的 PATH。
    ///
    /// crate 的入口是 `#!/usr/bin/env node` 的 JS 脚本，所以**光有 crate 绝对路径不够**，
    /// 还得让子进程自己找得到 node。而 node 的位置没有任何可靠的静态猜法：本机实测
    /// `~/.local/bin/node` 是一条**断链软链**（指向已删除的 `~/.hermes/node/bin/node`），真正
    /// 可用的 node 在 `~/bin/node-v22/bin/node` —— 只靠写死目录列表这里必然 exit 127。
    /// 所以 `inherited` 由 App 层传入**登录 shell 的真实 PATH**，静态列表只作兜底。
    public static func searchPath(homeDirectory home: String,
                                 inherited: String? = nil) -> String {
        var dirs: [String] = []
        if let inherited, !inherited.isEmpty {
            // 登录 shell 的 PATH 排在前面：它才是"用户自己用 crate 时"的环境。
            dirs += inherited.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        }
        dirs += [
            "\(home)/.local/bin",
            "\(home)/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        // 去重但保持顺序：重复目录会让每次 exec 多做几次无谓的 stat。
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// 在 PATH 里找出第一个真正装着某个可执行文件的目录。
    ///
    /// `probe` 由调用方注入（App 层传 `FileManager.isExecutableFile`），这样这段查找逻辑能被
    /// smoke 覆盖——它守的是"断链软链"这种最容易让人误判的情况：路径存在、软链存在，但目标
    /// 已经没了，`isExecutableFile` 会如实返回 false。
    public static func resolveDirectory(containing executable: String,
                                        in searchPath: String,
                                        probe: (String) -> Bool) -> String? {
        for dir in searchPath.split(separator: ":").map(String.init) where !dir.isEmpty {
            if probe("\(dir)/\(executable)") { return dir }
        }
        return nil
    }

    // MARK: 解析

    /// 提交响应。`seed` 从 `input.extra_params_json` 里掏——实测 CLI 把它放在那个转义过的字符串里，
    /// 顶层没有。拿到它「重跑」才能复现同一张图。
    public struct SubmitResult: Equatable {
        public let taskId: String
        public let seed: Int?
        public init(taskId: String, seed: Int?) {
            self.taskId = taskId
            self.seed = seed
        }
    }

    public static func parseSubmitResponse(_ output: String) throws -> SubmitResult {
        let root = try jsonObject(output)
        // success 字段存在且为 false 时明确拒绝；字段缺失不当作失败（别的 CLI 版本可能不给）。
        if let success = root["success"] as? Bool, success == false {
            throw CrateResponseError.submissionRejected(output)
        }
        guard let taskId = stringValue(root["taskId"]) ?? stringValue(root["task_id"]),
              !taskId.isEmpty else {
            throw CrateResponseError.missingTaskId
        }
        return SubmitResult(taskId: taskId, seed: extractSeed(from: root))
    }

    /// 解析 `task get` 的单任务响应。
    public static func parseTaskStatus(_ output: String) throws -> CrateTaskProgress {
        let root = try jsonObject(output)
        guard let info = root["taskInfo"] as? [String: Any] else {
            throw CrateResponseError.notJSON(output)
        }
        return progress(fromTaskInfo: info)
    }

    /// 解析 `task query` 的批量响应，返回 taskId → 进展。
    public static func parseBatchTaskStatus(_ output: String) throws -> [String: CrateTaskProgress] {
        let root = try jsonObject(output)
        guard let infos = root["taskInfos"] as? [[String: Any]] else {
            throw CrateResponseError.notJSON(output)
        }
        var result: [String: CrateTaskProgress] = [:]
        for info in infos {
            guard let id = stringValue(info["task_id"]) ?? stringValue(info["taskId"]) else { continue }
            result[id] = progress(fromTaskInfo: info)
        }
        return result
    }

    /// 把一个 `taskInfo` 翻成进展。
    ///
    /// 映射口径：
    ///   - `task_status == 1` + `queue_ahead_count > 0` → 排队（`ahead` 是 CLI 真字段，不是估算）
    ///   - `task_status == 1` 其余情况 → 生成中
    ///   - `task_status == 2` + 有 `results[].content` → 成功
    ///   - `task_status == 2` 但没有产物 → 失败（服务端说成了却没给图，按失败报比显示一张空白诚实）
    ///   - 其他状态码 → 失败，原因里带上状态码与服务端给的文案
    public static func progress(fromTaskInfo info: [String: Any]) -> CrateTaskProgress {
        let status = intValue(info["task_status"]) ?? -1
        switch status {
        case statusRunning:
            let ahead = intValue(info["queue_ahead_count"]) ?? 0
            return ahead > 0 ? .queued(ahead: ahead) : .running
        case statusSucceeded:
            let urls = assetURLs(fromTaskInfo: info)
            if urls.isEmpty {
                return .failed(reason: "任务已完成但没有返回产物")
            }
            return .succeeded(assetURLs: urls)
        default:
            if let message = failureMessage(fromTaskInfo: info) {
                return .failed(reason: message)
            }
            return .failed(reason: "任务失败（状态码 \(status)）")
        }
    }

    /// 从 `results[]` 里取出可下载的媒体地址。只认 http(s)，因为下游是 `URLSession`。
    public static func assetURLs(fromTaskInfo info: [String: Any]) -> [String] {
        guard let results = info["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
            guard let content = stringValue(item["content"]) else { return nil }
            let lower = content.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
            return content
        }
    }

    /// 服务端失败文案的候选字段。CLI 文档没写全，实测也没抓到失败样本（见调研文档 📌 待确认），
    /// 所以这里按常见命名逐个试，取到什么用什么。
    public static func failureMessage(fromTaskInfo info: [String: Any]) -> String? {
        let keys = ["fail_reason", "failure_reason", "error_msg", "error_message", "message", "msg"]
        for key in keys {
            if let text = stringValue(info[key]),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return clip(text)
            }
        }
        return nil
    }

    // MARK: 入参筛选

    /// 从槽位附件里挑出「这次要当入参上传」的图片路径。
    ///
    /// 放在 Kit 而不是 View 扩展里，是因为这条规则有两个**静默失败**的分支，必须能被测试盯住：
    ///
    /// 1. **产物剔除**：生成结果也写在槽位附件里（那才是用户资产该待的地方），不剔的话重跑会把
    ///    上一轮的出图当成这一轮的入参 —— 文生图无声变成图生图，而 UI 上没有任何一处会提示。
    /// 2. **断链剔除**：附件可能只有一个指向用户原始文件的路径引用，而原文件已被移走/删除。
    ///    把不存在的路径交给 CLI，换回来的是一句上传失败，用户读不出到底哪张图没了。
    ///
    /// ★ 产物有**两个**独立标记，缺一不可
    ///
    /// 一个是节点上的 `outputAttachmentIds`（精确），另一个是产物文件名（`crate_<taskId>.<ext>`，
    /// 兜底）。为什么需要兜底：画布文档会被**不认识这个字段的版本**读写 —— Codable 遇到未知 key
    /// 只会丢掉，于是"用旧版本打开一次画布"就足以把全部产物标记抹掉，下一次重跑立刻退化成
    /// 图生图（实测发生过：迁移前的 v2.11.17 打开过画布，三张历史产物就全被当成入参上传了）。
    /// 文件名是我们自己在 `assetFileName` 里定的，跟着字节走进槽位，不受画布文档往返影响。
    ///
    /// 路径优先级 `storagePath > path > originalPath`：`storagePath` 是存储层自有的字节副本
    /// （`attachments/{id}.bin`），它不会因为用户整理桌面而失效。`.bin` 扩展名不影响 CLI 上传，
    /// 服务端按内容判类型。
    ///
    /// - Parameters:
    ///   - outputs: 本节点历史产物的附件 id（`CanvasNode.outputAttachmentIds`）。
    ///   - fileExists: 文件存在性探针，注入以便测试不碰真实磁盘。
    public static func inputImagePaths(from attachments: [SlotContent.SlotAttachment],
                                      excludingAttachmentIds outputs: Set<String>,
                                      fileExists: (String) -> Bool) -> [String] {
        attachments.compactMap { att -> String? in
            guard att.type == .image else { return nil }
            guard !outputs.contains(att.id.uuidString) else { return nil }
            guard !isGeneratedAssetName(att.name) else { return nil }
            for candidate in [att.storagePath, att.path, att.originalPath] {
                if let path = candidate, !path.isEmpty, fileExists(path) { return path }
            }
            return nil
        }
    }

    // MARK: 文件命名

    /// 产物落盘用的文件名。带 taskId 是为了出问题时能从文件名反查到任务。
    ///
    /// `fallbackExtension` 只在 URL 里认不出扩展名时才用得上，但它**必须跟着链路类型走**：
    /// 视频产物兜底成 `.jpg` 的后果不是"名字难看"，而是 `CanvasAttachmentKind` 按扩展名判类别时
    /// 把一个 mp4 认成图片，于是卡片拿 `NSImage` 去读它、读不出来、预览区空白（v2.11.19）。
    public static func assetFileName(taskId: String,
                                    index: Int,
                                    urlString: String,
                                    fallbackExtension: String = "jpg") -> String {
        let ext = fileExtension(forURL: urlString) ?? fallbackExtension
        let safeId = taskId.filter { $0.isNumber || $0.isLetter || $0 == "-" || $0 == "_" }
        let id = safeId.isEmpty ? "task" : safeId
        return index == 0 ? "crate_\(id).\(ext)" : "crate_\(id)_\(index + 1).\(ext)"
    }

    /// 这个附件名是不是我们自己生成出来的产物？
    ///
    /// 与 `assetFileName` **成对维护**：改了那边的命名就必须改这里，否则兜底标记会静默失效。
    /// 刻意只认 `crate_` 前缀 + 图片扩展名这一种极窄形态，宁可漏判（还有 id 那道精确标记）
    /// 也不误判用户自己拖进来的图 —— 误判的后果是"用户明明挂了参考图，却被当产物忽略"。
    public static func isGeneratedAssetName(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasPrefix("crate_") else { return false }
        guard let ext = fileExtension(forURL: lower) else { return false }
        // crate_<taskId>[_序号].<ext>：中段只允许数字 / 字母 / - / _（assetFileName 过滤后的形态）。
        let stem = String(lower.dropFirst("crate_".count).dropLast(ext.count + 1))
        guard !stem.isEmpty else { return false }
        return stem.allSatisfy { $0.isNumber || $0.isLetter || $0 == "-" || $0 == "_" }
    }

    /// 从 URL 猜扩展名。只认白名单，避免把查询串里的垃圾当扩展名（`?x=a.php` 这种）。
    public static func fileExtension(forURL urlString: String) -> String? {
        let allowed: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "bmp", "tiff", "svg"]
        // 掐掉 query / fragment 再取最后一段。
        let pathPart = urlString.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? urlString
        guard let last = pathPart.split(separator: "/").last,
              let ext = last.split(separator: ".").last,
              last.contains(".") else { return nil }
        let lower = ext.lowercased()
        return allowed.contains(lower) ? lower : nil
    }

    // MARK: - 内部工具

    /// 把可能带前后噪声的输出裁成第一个 JSON 对象再解析。
    public static func jsonObject(_ output: String) throws -> [String: Any] {
        guard let slice = firstJSONObject(output),
              let data = slice.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CrateResponseError.notJSON(output)
        }
        return root
    }

    /// 取出第一个花括号配平的片段。`--json` 下 stdout 本来就是纯 JSON，这是给将来的 CLI 变动留的余量。
    public static func firstJSONObject(_ output: String) -> String? {
        guard let start = output.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < output.endIndex {
            let ch = output[index]
            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(output[start...index])
                    }
                }
            }
            index = output.index(after: index)
        }
        return nil
    }

    /// CLI 的数值字段时而是数字、时而是字符串（实测 `task_status` 是数字、
    /// `queue_ahead_count` 是 `"0"`），所以一律走这两个宽容取值器。
    static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let n as Int: return n
        case let n as Double: return Int(n)
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let n as Int: return String(n)
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// seed 藏在 `input.extra_params_json` 这个**被转义的 JSON 字符串**里，需要二次解析。
    static func extractSeed(from root: [String: Any]) -> Int? {
        guard let input = root["input"] as? [String: Any] else { return nil }
        if let raw = input["extra_params_json"] as? String,
           let data = raw.data(using: .utf8),
           let extra = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let seed = intValue(extra["seed"]) {
            return seed
        }
        if let extra = input["extra_params"] as? [String: Any], let seed = intValue(extra["seed"]) {
            return seed
        }
        return intValue(input["seed"])
    }

    /// 报错里嵌原始输出时的截断，避免把整页 JSON 塞进 Toast。
    public static func clip(_ text: String, limit: Int = 200) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}
