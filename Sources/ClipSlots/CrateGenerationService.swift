import Foundation
import ClipSlotsKit

/// Crate CLI 的**进程边界**（v2.11.17）。
///
/// 职责就三件：找到 crate 可执行文件、把命令跑起来并拿回 stdout、把产物 URL 下载成本地文件。
/// 参数拼接与 JSON 解析全在 `ClipSlotsKit.CrateGeneration`（那边能被 smoke 测试覆盖）；
/// 节点状态写回与 Toast 全在 `CanvasWorkspaceView+Generation`。这一层刻意不认识 `CanvasNode`。
///
/// ★ 为什么走 CLI 而不是直连 BFF
///
/// 认证是 bytedcli 签发的 JWT（约 2 小时过期），绕开 CLI 只是把 token 获取与刷新这件最麻烦的
/// 事搬进 App，收益仅是省掉一个 Node 进程。等 CLI 成为瓶颈（流式 / 高并发）再谈直连。
///
/// ★ 为什么不用 `--output-dir` 让 CLI 自己下载
///
/// 那是阻塞模式（不带 `--no-wait`）的能力，而我们需要中途的排队信息。另外下载进度、失败重试、
/// 「写进哪个槽位」这几件事本来就在 App 手里，交给 CLI 反而多一层不可观测的文件落点。
final class CrateGenerationService {

    static let shared = CrateGenerationService()

    private init() {}

    // MARK: - 错误

    enum ServiceError: Error {
        /// 所有候选路径上都没有 crate。
        case cliMissing(candidates: [String])
        /// 找得到 crate 但找不到 node。crate 的入口是 `#!/usr/bin/env node`，缺 node 时子进程
        /// 以 exit 127 + "env: node: No such file or directory" 死掉，那个报错对用户毫无意义，
        /// 所以这里提前拦住并说清楚缺的是什么。
        case nodeMissing(searchPath: String)
        /// `auth status` 失败：未登录或 JWT 过期。GUI 内无法代劳（登录走 bytedcli），只能引导去终端。
        case notAuthenticated(detail: String)
        case processFailed(stage: String, detail: String)
        case processTimeout(stage: String, seconds: Int)
        case request(CrateRequestError)
        case response(CrateResponseError)
        case taskFailed(reason: String)
        /// 轮询到时限还没终态。刻意带上 taskId：节点右键的「复制 taskId」还要用它去 Crate 网页端查。
        case pollTimeout(taskId: String)
        case downloadFailed(detail: String)

        /// 给用户看的一句话。每一种失败对应的下一步动作都不同，所以不合并成一句通用文案。
        var userMessage: String {
            switch self {
            case .cliMissing:
                return "没找到 crate 命令，先装好 Crate CLI（npm i -g @byted-opero/crate-cli）"
            case .nodeMissing:
                return "没找到 node，Crate CLI 需要 Node.js 运行时"
            case .notAuthenticated:
                return "Crate 未登录或登录已过期，去终端跑一次 crate auth login"
            case .processFailed(let stage, let detail):
                return "\(stage)失败：\(detail)"
            case .processTimeout(let stage, let seconds):
                return "\(stage)超时（>\(seconds)s）"
            case .request(let err):
                return err.userMessage
            case .response(let err):
                return err.userMessage
            case .taskFailed(let reason):
                return reason
            case .pollTimeout(let taskId):
                return "等待超时（\(Int(CrateGeneration.pollTimeout))s），任务仍在跑：\(taskId)"
            case .downloadFailed(let detail):
                return "产物下载失败：\(detail)"
            }
        }

        /// 排查用的完整原文（写进日志，不进 Toast）。
        var logDetail: String {
            switch self {
            case .cliMissing(let candidates):
                return "crate not found in: \(candidates.joined(separator: ", "))"
            case .nodeMissing(let searchPath):
                return "node not found in PATH: \(searchPath)"
            case .notAuthenticated(let detail):
                return detail
            case .processFailed(let stage, let detail):
                return "\(stage): \(detail)"
            case .processTimeout(let stage, let seconds):
                return "\(stage) timeout \(seconds)s"
            case .request(let err):
                return "\(err)"
            case .response(let err):
                return "\(err)"
            case .taskFailed(let reason):
                return reason
            case .pollTimeout(let taskId):
                return "poll timeout, taskId=\(taskId)"
            case .downloadFailed(let detail):
                return detail
            }
        }
    }

    // MARK: - 可执行文件解析

    private let binaryLock = NSLock()
    private var cachedBinary: String?

    /// 找到 crate 可执行文件。结果缓存，找不到时不缓存（用户装完不必重启 App）。
    func resolveBinary() throws -> String {
        binaryLock.lock()
        let cached = cachedBinary
        binaryLock.unlock()
        if let cached, FileManager.default.isExecutableFile(atPath: cached) { return cached }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = CrateGeneration.binaryCandidates(homeDirectory: home)
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            binaryLock.lock(); cachedBinary = path; binaryLock.unlock()
            return path
        }
        throw ServiceError.cliMissing(candidates: candidates)
    }

    // MARK: - 环境（PATH / node）

    /// 模型参数表缓存（`model describe` 的结果）。模型的参数表在一次会话里不会变，而每次重跑都问
    /// 一遍要多等一个 Node 冷启动。
    private var modelParameterCache: [String: Set<String>] = [:]

    private let envLock = NSLock()
    private var cachedSearchPath: String?

    /// 子进程用的 PATH，带缓存（登录 shell 要起一个进程，不该每次轮询都付这个成本）。
    ///
    /// ★ 为什么非得问登录 shell
    ///
    /// App 从 Finder / Dock 启动时继承的是 launchd 的精简 PATH，用户在终端里那套 nvm / hermes /
    /// 自建目录一个都不在。而 node 的真实位置无法静态猜：本机 `~/.local/bin/node` 是一条**断链
    /// 软链**（指向已删掉的 `~/.hermes/node/bin/node`），能用的 node 在 `~/bin/node-v22/bin`。
    /// 实测只用写死目录列表跑 `crate task get` → `env: node: No such file or directory`（exit 127）。
    /// 所以这里先问一次登录 shell 的 PATH，静态列表只作兜底。
    func searchPath() -> String {
        envLock.lock()
        if let cached = cachedSearchPath { envLock.unlock(); return cached }
        envLock.unlock()

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inherited = Self.loginShellPath() ?? ProcessInfo.processInfo.environment["PATH"]
        let path = CrateGeneration.searchPath(homeDirectory: home, inherited: inherited)

        envLock.lock(); cachedSearchPath = path; envLock.unlock()
        return path
    }

    /// 问登录 shell 要 PATH。失败（shell 不存在 / 超时 / 用户配置有交互式提示）时返回 nil，
    /// 让调用方退回到进程自身的 PATH —— 宁可少几条目录，也不要在这里卡住生成流程。
    private static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        // `-l` 才会加载 ~/.zprofile / ~/.bash_profile 这类真正写 PATH 的文件。
        task.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()      // 别让 shell 的启动噪声混进 stdout

        var collected = Data()
        let lock = NSLock()
        let group = DispatchGroup()
        do { try task.run() } catch { return nil }

        group.enter()
        DispatchQueue.global().async {
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); collected = d; lock.unlock()
            group.leave()
        }

        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            if sema.wait(timeout: .now() + 8) == .timedOut, task.isRunning { task.terminate() }
        }
        task.waitUntilExit()
        sema.signal()
        group.wait()

        guard task.terminationStatus == 0 else { return nil }
        lock.lock(); let raw = String(data: collected, encoding: .utf8) ?? ""; lock.unlock()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// node 在不在。crate 是 JS 脚本，没有 node 就只会给出一句无从下手的 exit 127。
    private func assertNodeAvailable() throws {
        let path = searchPath()
        let found = CrateGeneration.resolveDirectory(containing: "node", in: path) {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        if found == nil {
            throw ServiceError.nodeMissing(searchPath: path)
        }
    }

    // MARK: - 对外流程

    /// 前置体检：CLI 在不在、登录还有效没有。点「生成」时先跑一次，把「未登录」拦在节点进
    /// running 之前——否则用户看到的是一个转了半天然后失败的节点，而真正的动作是去终端登录。
    func preflight() async throws {
        _ = try resolveBinary()
        try assertNodeAvailable()
        let output = try await run(CrateGeneration.authStatusArguments(),
                                  timeout: CrateGeneration.authCheckTimeout,
                                  stage: "登录检查")
        // `auth status --json` 成功时返回 {username, email, employee_id}；未登录时退出码非零
        // （已被 run 转成 processFailed），这里再兜一层「退出码 0 但没有 username」。
        guard let root = try? CrateGeneration.jsonObject(output),
              let username = root["username"] as? String,
              !username.isEmpty else {
            throw ServiceError.notAuthenticated(detail: CrateGeneration.clip(output))
        }
    }

    /// 提交结果 + 「seed 被丢掉了吗」。
    ///
    /// 丢 seed 必须让调用方知道：用户点的是「重跑」，语义是"同一个种子再来一次"。悄悄换成随机种子
    /// 会让人以为模型不稳定，所以要在 Toast 里说明是模型不收 seed。
    struct Submission {
        let result: CrateGeneration.SubmitResult
        let droppedSeed: Bool
        /// 比例被 CLI 拒收、已去掉重试。出图尺寸与用户在选择器里选的不一致，必须说一声。
        let droppedRatio: Bool
    }

    /// 取回模型目录（`model list --json`）。
    ///
    /// 刻意**不做 preflight**：目录查询本身就是"还能不能用"的探针，先跑一遍 auth status 只是把
    /// 一次进程调用变成两次，而失败原因（缺 crate / 未登录）在这一次里同样会说清楚。
    /// 缓存与状态在 `CrateModelCatalogStore`（App/UI 层），这一层每次都真跑。
    func fetchModelCatalog() async throws -> [CrateModelCatalog.ModelInfo] {
        let output = try await run(CrateModelCatalog.listArguments(),
                                  timeout: CrateModelCatalog.listTimeout,
                                  stage: "查询模型目录")
        do {
            let models = try CrateModelCatalog.parse(output)
            // 顺手把参数表喂进 seed 门禁的缓存：目录里已经带了完整 parameters，再为同一个模型
            // 单独 describe 一次纯属浪费（也是"点生成要等两次进程"的一个来源）。
            for m in models where !m.parameterNames.isEmpty {
                modelParameterCache[m.id] = m.parameterNames
            }
            return models
        } catch let err as CrateResponseError {
            throw ServiceError.response(err)
        }
    }

    /// 提交一次生成。
    ///
    /// seed 走**两道保险**：先查模型参数表（`model describe`，结果缓存），不支持就别传；查不到时
    /// 照常传，提交真被拒了再去掉 seed 重试一次。单靠任何一道都不够 —— 只查表的话，CLI 改字段
    /// 或离线就会把重跑变成硬失败；只靠重试的话，每次重跑都要先白跑一次失败的提交。
    func submit(_ request: CrateImageRequest) async throws -> Submission {
        var effective = request
        var dropped = false
        if request.seed != nil, await modelRejectsSeed(model: request.model) == true {
            effective = CrateGeneration.droppingSeed(request)
            dropped = true
        }

        do {
            return Submission(result: try await submitOnce(effective), droppedSeed: dropped, droppedRatio: false)
        } catch let err as ServiceError {
            guard case .processFailed(_, let detail) = err else { throw err }

            // 两个参数各有一条退路，且可能同时命中（老画布 + 重跑）。挨个摘掉再试，最多一次重试。
            var retry = effective
            var retriedSeed = false
            var retriedRatio = false
            if retry.seed != nil, CrateGeneration.isUnsupportedParameterError(detail) {
                retry = CrateGeneration.droppingSeed(retry)
                retriedSeed = true
            }
            if !retry.ratio.isEmpty,
               CrateGeneration.isUnsupportedParameterError(detail, parameter: CrateModelCatalog.ratioParameterName) {
                retry = CrateGeneration.droppingRatio(retry)
                retriedRatio = true
            }
            guard retriedSeed || retriedRatio else { throw err }

            NSLog("[ClipSlots][crate] model \(effective.model) rejected"
                  + (retriedSeed ? " seed" : "") + (retriedRatio ? " ratio" : "")
                  + "; retrying without it")
            let result = try await submitOnce(retry)
            return Submission(result: result, droppedSeed: dropped || retriedSeed, droppedRatio: retriedRatio)
        }
    }

    private func submitOnce(_ request: CrateImageRequest) async throws -> CrateGeneration.SubmitResult {
        let args: [String]
        do {
            args = try CrateGeneration.submitArguments(request)
        } catch let err as CrateRequestError {
            throw ServiceError.request(err)
        }
        let output = try await run(args, timeout: CrateGeneration.submitTimeout, stage: "提交任务")
        do {
            return try CrateGeneration.parseSubmitResponse(output)
        } catch let err as CrateResponseError {
            throw ServiceError.response(err)
        }
    }

    /// 这个模型是不是不收 seed？`nil` = 问不出来（不确定时不做任何取舍，交给重试兜底）。
    private func modelRejectsSeed(model: String) async -> Bool? {
        if let cached = modelParameterCache[model] {
            return !cached.contains(CrateGeneration.seedParameterName)
        }
        do {
            let output = try await run(CrateGeneration.modelDescribeArguments(model: model),
                                       timeout: CrateGeneration.describeTimeout,
                                       stage: "查询模型参数")
            let names = try CrateGeneration.parseModelParameterNames(output)
            // 空表按"问不出来"处理：宁可让提交去试，也不要因为解析口径变了就默默阉掉 seed。
            guard !names.isEmpty else { return nil }
            modelParameterCache[model] = names
            return !names.contains(CrateGeneration.seedParameterName)
        } catch {
            NSLog("[ClipSlots][crate] model describe \(model) failed: \(error)")
            return nil
        }
    }

    /// 轮询到终态，返回产物 URL 列表。
    ///
    /// 每次观测都回调 `onProgress`（在**调用方线程**，节点状态的 MainActor 跳转由调用方负责），
    /// 这样卡片能实时显示「前方 N 个」→「生成中 12s」。
    func waitForCompletion(taskId: String,
                           onProgress: @escaping (CrateTaskProgress) -> Void) async throws -> [String] {
        let deadline = Date().addingTimeInterval(CrateGeneration.pollTimeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(CrateGeneration.pollInterval * 1_000_000_000))
            if Task.isCancelled { throw CancellationError() }

            let output = try await run(CrateGeneration.taskGetArguments(taskId: taskId),
                                       timeout: CrateGeneration.pollProcessTimeout,
                                       stage: "查询任务")
            let progress: CrateTaskProgress
            do {
                progress = try CrateGeneration.parseTaskStatus(output)
            } catch let err as CrateResponseError {
                throw ServiceError.response(err)
            }
            onProgress(progress)

            switch progress {
            case .queued, .running:
                continue
            case .succeeded(let urls):
                return urls
            case .failed(let reason):
                throw ServiceError.taskFailed(reason: reason)
            }
        }
        throw ServiceError.pollTimeout(taskId: taskId)
    }

    /// 把产物下载到临时目录。返回的文件由调用方负责搬进槽位附件后删除。
    func download(urlString: String, taskId: String, index: Int) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw ServiceError.downloadFailed(detail: "URL 非法：\(CrateGeneration.clip(urlString))")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw ServiceError.downloadFailed(detail: error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ServiceError.downloadFailed(detail: "HTTP \(http.statusCode)")
        }
        guard !data.isEmpty else {
            throw ServiceError.downloadFailed(detail: "内容为空")
        }

        let name = CrateGeneration.assetFileName(taskId: taskId, index: index, urlString: urlString)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipslots_crate_\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            throw ServiceError.downloadFailed(detail: error.localizedDescription)
        }
    }

    // MARK: - 进程

    /// 跑一条 crate 子命令，返回 stdout。
    ///
    /// 三个必须这么写的点：
    ///   1. **绝对路径**启动。App 从 Finder 启动时 PATH 是 launchd 的精简版，没有 `~/.local/bin`。
    ///   2. 子进程 PATH 要**显式重建**。crate 的入口是 `#!/usr/bin/env node`，光有 crate 的绝对
    ///      路径不够，它自己还得找到 node。
    ///   3. stdout / stderr **并发抽干**。crate 的 `model list --json` 能有几十 KB，顺序读会在
    ///      pipe 缓冲区满时死锁（这个坑 `UpdateInstaller` 已经踩过，此处沿用同一套 DispatchGroup）。
    private func run(_ arguments: [String], timeout: TimeInterval, stage: String) async throws -> String {
        let binary = try resolveBinary()
        let path = searchPath()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try Self.runSync(binary: binary,
                                                  arguments: arguments,
                                                  searchPath: path,
                                                  timeout: timeout,
                                                  stage: stage)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runSync(binary: String,
                                arguments: [String],
                                searchPath: String,
                                timeout: TimeInterval,
                                stage: String) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = searchPath
        env["HOME"] = home              // crate 要读 ~/.crate/{config,session}.json
        env["NO_COLOR"] = "1"           // 别把 ANSI 转义塞进要解析的 stdout
        task.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        let dataLock = NSLock()
        var outData = Data()
        var errData = Data()
        let drainGroup = DispatchGroup()

        do {
            try task.run()
        } catch {
            throw ServiceError.processFailed(stage: stage, detail: error.localizedDescription)
        }

        drainGroup.enter()
        DispatchQueue.global().async {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            dataLock.lock(); outData = d; dataLock.unlock()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global().async {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            dataLock.lock(); errData = d; dataLock.unlock()
            drainGroup.leave()
        }

        let sema = DispatchSemaphore(value: 0)
        let timedOutLock = NSLock()
        var timedOut = false
        DispatchQueue.global().async {
            if sema.wait(timeout: .now() + timeout) == .timedOut {
                timedOutLock.lock(); timedOut = true; timedOutLock.unlock()
                if task.isRunning { task.terminate() }
            }
        }
        task.waitUntilExit()
        sema.signal()
        drainGroup.wait()

        timedOutLock.lock(); let didTimeOut = timedOut; timedOutLock.unlock()
        if didTimeOut {
            throw ServiceError.processTimeout(stage: stage, seconds: Int(timeout))
        }

        dataLock.lock()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        dataLock.unlock()

        guard task.terminationStatus == 0 else {
            // stderr 优先：`--json` 下进度提示与错误都走 stderr，出错时那里才是有用的一行。
            let detail = CrateGeneration.clip(err.isEmpty ? out : err)
            NSLog("[ClipSlots][crate] \(stage) exit=\(task.terminationStatus) stderr=\(err)")
            // 登录态失效的表征在退出码里分辨不出来，只能看文案。命中关键词就升级成
            // notAuthenticated，因为这一类的下一步动作（去终端登录）和别的失败完全不同。
            if Self.looksLikeAuthFailure(err + " " + out) {
                throw ServiceError.notAuthenticated(detail: detail)
            }
            throw ServiceError.processFailed(stage: stage, detail: detail.isEmpty ? "退出码 \(task.terminationStatus)" : detail)
        }
        return out
    }

    /// 登录失效的关键词。📌 待确认：本机没抓到过期样本（JWT 还有效），所以这里覆盖的是
    /// `auth login` / 401 / unauthorized 这几种常见表征，命不中时会退化成普通 processFailed，
    /// 用户仍能看到 CLI 原文，不会静默。
    private static func looksLikeAuthFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        let needles = ["auth login", "not logged in", "unauthorized", "401", "jwt", "token expired", "login expired"]
        return needles.contains { lower.contains($0) }
    }
}
