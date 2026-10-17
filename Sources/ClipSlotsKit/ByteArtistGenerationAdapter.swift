import Foundation

public struct ByteArtistGenerationAdapter: GenerationProvider {
    public let context: GenerationProviderContext
    private let root: URL
    private let references: URL
    private let executor: GenerationCLIExecutor
    private let bindings: [String: [GenerationOutputBinding]]

    public init(context: GenerationProviderContext = .byteartist, root: URL,
                outputBindings: [String: [GenerationOutputBinding]] = [:],
                executor: @escaping GenerationCLIExecutor) throws {
        guard context.provider == .byteartist, context.controlPlane == "cn",
              context.endpoint == GenerationProviderContext.byteartist.endpoint else {
            throw GenerationAdapterError.invalidConfiguration("当前 BA 适配器仅支持已验证的 cn 官方业务接口。")
        }
        self.context = context
        self.root = root.appendingPathComponent("cn").appendingPathComponent(
            GenerationWire.revision(context.accountAlias), isDirectory: true)
        references = self.root.appendingPathComponent("references", isDirectory: true)
        self.executor = executor; bindings = outputBindings
    }

    private func invoke(_ args: [String], submitting: Bool = false, globalReferences: Bool = false) async throws -> ToolProcess.Output {
        var env = GenerationAdapterRuntime.environment()
        if !globalReferences { env["BA_REFERENCES_DIR"] = references.path }
        env["BA_CLI_TASK_CACHE_FILE"] = root.appendingPathComponent("task-cache.json").path
        // Retain the user's SDK/Keychain login, while isolating task and reference caches.
        // Switching auth roots requires a separate explicit login and is not done here.
        return try await executor(.init(
            arguments: args, environment: env, directory: root,
            timeout: submitting ? 300 : 30, submitting: submitting))
    }
    private var scope: [String] { ["-c", context.controlPlane, "--as", context.accountAlias] }

    /// Import selected official reference Markdown here before discovery.
    public var referenceDirectory: URL { references }

    public func workflows(page: Int = 1, pageSize: Int = 100, query: String = "") async throws -> ByteArtistWorkflowPage {
        guard page > 0, (1...1000).contains(pageSize), query.utf8.count <= 512 else {
            throw GenerationAdapterError.invalidInput("工作流查询参数不合法。")
        }
        var args = ["--output", "json", "app", "list", "--page", String(page), "--page-size", String(pageSize)]
        if !query.isEmpty { args += ["--name", query] }
        let value = try GenerationWire.decode(GenerationAdapterRuntime.output(await invoke(args + scope)))
        if let error = GenerationWire.error(value) { throw error }
        guard let rows = value["data"]?["workflows"]?.arrayValue,
              let total = value["data"]?["total"]?.intValue, total >= 0 else { throw GenerationAdapterError.invalidResponse }
        var seen = Set<String>()
        let items = rows.compactMap { row -> ByteArtistWorkflowSummary? in
            guard let id = try? GenerationWire.identifier(row["id"]), id.allSatisfy(\.isNumber),
                  seen.insert(id).inserted else { return nil }
            return .init(id: id, title: row["name"]?.stringValue ?? id,
                         description: row["description"]?.stringValue ?? "")
        }
        return .init(workflows: items, total: total, page: page, pageSize: pageSize)
    }

    public func removeReference(id: String) throws {
        guard !id.isEmpty, id.allSatisfy(\.isNumber), id.count < 40 else {
            throw GenerationAdapterError.invalidInput("工作流 ID 不合法。")
        }
        let file = references.appendingPathComponent("workflow-\(id).md")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    /// Read available local references through the CLI's discovery rules.
    public func localReferences() async throws -> [(id: String, title: String)] {
        let raw = try GenerationWire.decode(GenerationAdapterRuntime.output(await invoke(
            ["--output", "json", "app", "references", "list", "--absolute"], globalReferences: true)))
        guard let list = raw.arrayValue else { throw GenerationAdapterError.invalidResponse }
        return try list.map {
            let id = try GenerationWire.identifier($0["workflow_id"])
            return (id, $0["title"]?.stringValue ?? id)
        }
    }

    /// Explicit selection refreshes a reference into the application's own catalog.
    public func refreshReference(id: String) async throws {
        guard !id.isEmpty, id.allSatisfy(\.isNumber), id.count < 40 else {
            throw GenerationAdapterError.invalidInput("请输入数字形式的 BA 工作流 ID。")
        }
        let raw = try GenerationWire.decode(GenerationAdapterRuntime.output(await invoke(
            ["--output", "json", "app", "skill", id, "--stdout"] + scope)))
        guard let markdown = raw["markdown"]?.stringValue,
              markdown.contains("> workflow id: `\(id)`"), markdown.utf8.count < 1_048_576 else {
            throw GenerationAdapterError.invalidResponse
        }
        _ = try Self.schema(markdown, heading: "输入 Schema")
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: references.appendingPathComponent("workflow-\(id).md"), options: .atomic)
    }

    public func preflight() async throws {
        let version = try GenerationAdapterRuntime.output(await invoke(["--version"]))
        guard Self.supportsVersion(version) else {
            throw GenerationAdapterError.invalidConfiguration("BA 需使用 1.1.5 或经验证兼容的 1.x 版本。")
        }
        let auth = try GenerationWire.decode(GenerationAdapterRuntime.output(
            await invoke(["--output", "json", "auth", "status"] + scope)))
        guard auth["loggedIn"] == .bool(true) else { throw GenerationAdapterError.authenticationRequired }
    }

    public static func supportsVersion(_ output: String) -> Bool {
        // BA appends registry update information after "---"; parse the installed version line.
        let first = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init) ?? ""
        guard let regex = try? NSRegularExpression(pattern: #"^(?:ba\s+)?v?1\.([0-9]+)\.([0-9]+)$"#),
              let match = regex.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)),
              let minorRange = Range(match.range(at: 1), in: first),
              let patchRange = Range(match.range(at: 2), in: first),
              let minor = Int(first[minorRange]), let patch = Int(first[patchRange]) else { return false }
        return minor > 1 || (minor == 1 && patch >= 5)
    }

    /// The host generates/imports selected references into this directory.
    /// Discovery itself never creates references or submits a workflow.
    public func discover() async throws -> [GenerationCapability] {
        let result = try await discoverCatalog()
        if result.capabilities.isEmpty, let issue = result.issues.first {
            throw GenerationAdapterError.invalidConfiguration(issue)
        }
        return result.capabilities
    }
    public func discoverCatalog() async throws -> ByteArtistCatalogDiscovery {
        let raw = try GenerationWire.decode(GenerationAdapterRuntime.output(await invoke(
            ["--output", "json", "app", "references", "list", "--absolute", "--skill-dir", references.path])))
        guard let list = raw.arrayValue else { throw GenerationAdapterError.invalidResponse }
        var capabilities: [GenerationCapability] = []
        var issues: [String] = []
        for value in list {
          do {
            let id = try GenerationWire.identifier(value["workflow_id"])
            guard id.allSatisfy(\.isNumber), let content = value["content"]?.stringValue,
                  let path = value["file_path"]?.stringValue else { throw GenerationAdapterError.invalidResponse }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let safeRoot = references.resolvingSymlinksInPath().path + "/"
            guard url.path.hasPrefix(safeRoot) else {
                throw GenerationAdapterError.invalidConfiguration("BA 能力说明必须位于 App 专用目录。")
            }
            let schema = try Self.schema(content, heading: "输入 Schema")
            let kinds = ByteArtistContract.outputKinds(content)
            let metadata: JSONValue = .object(["reference": .string(content),
                "description": .string(ByteArtistContract.summary(content)),
                "outputKinds": .array(kinds.map { .string($0.rawValue) })])
            capabilities.append(GenerationCapability(context: context, id: id,
                title: value["title"]?.stringValue ?? id, revision: GenerationWire.revision(content),
                kind: Self.outputKind(content), inputSchema: schema, outputBindings: bindings[id] ?? [],
                metadata: metadata, referencePath: url.path))
          } catch {
            issues.append("能力「\(value["title"]?.stringValue ?? value["workflow_id"]?.stringValue ?? "未知")」暂不可用：\(error.localizedDescription)")
          }
        }
        var seen = Set<String>()
        return .init(capabilities: capabilities.filter { seen.insert($0.id).inserted }, issues: issues)
    }

    public func prepare(_ input: GenerationInput,
                        capability: GenerationCapability) async throws -> PreparedGenerationRequest {
        guard capability.context == context else { throw GenerationAdapterError.providerMismatch }
        try GenerationWire.validateIdentifier(capability.id)
        guard capability.id.allSatisfy(\.isNumber), input.outputCount == 1 else {
            throw GenerationAdapterError.invalidInput("BA 首期每个画布任务只请求一份输出；批量由画布独立调度。")
        }
        guard let path = capability.referencePath, let reference = capability.metadata["reference"]?.stringValue,
              GenerationWire.revision(reference) == capability.revision,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(
                references.resolvingSymlinksInPath().path + "/"),
              (try? String(contentsOfFile: path)) == reference else { throw GenerationAdapterError.capabilityChanged }
        // Read current remote metadata through the official reference generator,
        // without writing globally or executing an app. Changes require re-selection.
        let fresh = try GenerationWire.decode(GenerationAdapterRuntime.output(await invoke(
            ["--output", "json", "app", "skill", capability.id, "--stdout"] + scope)))
        guard let freshContent = fresh["markdown"]?.stringValue,
              GenerationWire.revision(freshContent) == capability.revision else {
            throw GenerationAdapterError.capabilityChanged
        }
        let schema = try Self.schema(reference, heading: "输入 Schema")
        guard schema == capability.inputSchema else { throw GenerationAdapterError.capabilityChanged }
        let properties = schema["properties"]?.objectValue ?? [:]
        let extra = Set(input.values.keys).subtracting(properties.keys)
        guard extra.isEmpty else {
            throw GenerationAdapterError.invalidInput("BA 工作流未公开参数：\(extra.sorted().joined(separator: "、"))。")
        }
        var values = input.values
        // Match the CLI's documented slot defaults. Missing slots without a
        // default are blocked, even when a generated Schema omits "required".
        for (key, rule) in properties where values[key] == nil {
            guard let defaultValue = rule["default"], defaultValue != .null else {
                throw GenerationAdapterError.invalidInput("BA 工作流缺少输入 \(key)。")
            }
            values[key] = defaultValue
        }
        try GenerationSchema.validate(.object(values), schema: schema)
        var files: [GenerationInputFile] = []
        for key in Self.uploadKeys(reference, keys: Set(values.keys)) {
            guard let raw = values[key]?.stringValue, !raw.isEmpty else {
                throw GenerationAdapterError.invalidInput("BA 上传输入 \(key) 需为单个文件路径或 URL。")
            }
            if GenerationWire.mediaURL(raw) != nil { continue }
            let local: String
            if let url = URL(string: raw), url.isFileURL { local = url.path }
            else { local = raw }
            files.append(try GenerationAdapterRuntime.file(local))
            values[key] = .string(local)
        }
        let json = try JSONValue.object(values).encodedText()
        guard json.utf8.count <= 131_072 else {
            throw GenerationAdapterError.invalidInput("BA 输入过大，请将大内容作为受支持的文件输入。")
        }
        let args = ["--output", "ndjson", "app", "run", capability.id, "--inputs", json,
                    "--skill-dir", references.path, "--num-out-img", "1", "--no-wait", "--use-limit"] + scope
        return PreparedGenerationRequest(capability: capability, input: .init(values: values),
                                         inputFiles: files, arguments: args, referenceVersion: capability.revision)
    }

    public func submit(_ request: PreparedGenerationRequest) async throws -> GenerationSubmission {
        guard request.capability.context == context else { throw GenerationAdapterError.providerMismatch }
        try Task.checkCancellation()
        guard request.inputFiles.allSatisfy(\.isCurrent) else { throw GenerationAdapterError.inputChanged }
        guard let path = request.capability.referencePath, let content = try? String(contentsOfFile: path),
              GenerationWire.revision(content) == request.referenceVersion else {
            throw GenerationAdapterError.capabilityChanged
        }
        let output: ToolProcess.Output
        do { output = try await invoke(request.arguments, submitting: true) }
        catch is CancellationError { throw CancellationError() } // No process permit was used.
        catch let error as GenerationAdapterError where error == .processNotStarted { throw error }
        catch { throw GenerationAdapterError.submissionUnknown(.byteartist) }
        return try Self.parseSubmission(output, capability: request.capability)
    }

    public static func parseSubmission(_ output: ToolProcess.Output,
                                       capability: GenerationCapability) throws -> GenerationSubmission {
        // Incremental events already written remain useful when a final line is cut short.
        let lines = output.stdout.split(separator: "\n").compactMap { try? GenerationWire.decode(String($0)) }
        let whole = try? GenerationWire.decode(output.stdout)
        let objects = whole?.objectValue != nil ? [whole!] : lines
        let created = objects.filter { $0["event"]?.stringValue == "task_created" || $0["event"] == nil }
        guard let ids = try? created.filter({ $0["task_id"] != nil }).map({ try GenerationWire.identifier($0["task_id"]) })
        else { throw GenerationAdapterError.submissionUnknown(.byteartist) }
        if let id = ids.first {
            guard Set(ids).count == 1 else { throw GenerationAdapterError.submissionUnknown(.byteartist) }
            let task = try GenerationTaskHandle(context: capability.context, taskID: id,
                capabilityID: capability.id, capabilityRevision: capability.revision, kind: capability.kind,
                outputBindings: capability.outputBindings)
            let interrupted = output.status != 0 || output.stopped || output.truncated
                || (whole == nil && output.stdout.split(separator: "\n").count != lines.count)
                || objects.contains(where: { GenerationWire.error($0) != nil })
            return GenerationSubmission(task: task, needsQuery: interrupted,
                detail: interrupted ? "已保存任务 ID；提交后的本地错误不应触发重提。" : nil)
        }
        if let error = objects.reversed().compactMap(GenerationWire.error).first {
            switch error {
            case .authenticationRequired: throw error
            case .commandFailed(let code, _)
                where ["BA_CLI_INPUT_INVALID", "BA_CLI_INPUT_LIMIT_BLOCKED", "BA_CLI_PRECONDITION_FAILED",
                       "BA_CLI_RESOURCE_NOT_FOUND"].contains(code): throw error
            default: break
            }
        }
        throw GenerationAdapterError.submissionUnknown(.byteartist)
    }

    public func query(_ task: GenerationTaskHandle) async throws -> GenerationObservation {
        guard task.context == context else { throw GenerationAdapterError.providerMismatch }
        try GenerationWire.validateIdentifier(task.taskID)
        let raw = try GenerationWire.decode(GenerationAdapterRuntime.output(await invoke(
            ["--output", "json", "app", "task", task.taskID] + scope)))
        if let error = GenerationWire.error(raw) { throw error }
        if let returned = raw["task_id"], try GenerationWire.identifier(returned) != task.taskID {
            throw GenerationAdapterError.invalidResponse
        }
        let status = raw["status"]?.stringValue ?? "unknown"
        let outputs = raw["output_result"] ?? .array([])
        func observation(_ state: GenerationStatus, stage: String, artifacts: [GenerationArtifact] = [],
                         detail: String? = nil) -> GenerationObservation {
            .init(task: task, status: state, rawStatus: status, artifacts: artifacts,
                  rawOutput: ["finished", "failed"].contains(status) ? outputs : nil, detail: detail,
                  diagnostic: .init(stage: stage, rawStatus: status,
                      requestID: raw["request_id"]?.stringValue, logID: raw["log_id"]?.stringValue, message: detail))
        }
        switch status {
        case "waiting":
            return observation(.queued(ahead: nil), stage: "queued")
        case "running":
            return observation(.running, stage: "running")
        case "finished":
            let artifacts = task.outputBindings.isEmpty
                ? ByteArtistContract.mediaArtifacts(outputs, kind: task.kind)
                : GenerationWire.artifacts(outputs, bindings: task.outputBindings)
            let empty = outputs.arrayValue?.isEmpty == true
            return observation(artifacts.isEmpty ? .outputMismatch : .succeeded,
                stage: artifacts.isEmpty ? (empty ? "empty-output" : "awaiting-output") : "downloading", artifacts: artifacts,
                detail: artifacts.isEmpty ? (empty ? "BA 已完成，但尚未返回产物；可继续查询原任务。"
                    : "BA 已完成，需要确认产物；打开「任务与产物」即可取回。") : nil)
        case "failed":
            // User-facing detail never blindly copies remote diagnostic strings.
            return observation(.failed, stage: "failed", detail: "BA 工作流执行失败。")
        default:
            return observation(.unknown(status), stage: "unknown", detail: "正在确认 BA 任务状态，不会重复提交。")
        }
    }

    static func schema(_ reference: String, heading: String) throws -> JSONValue {
        let marker = "## " + heading
        guard let start = reference.range(of: marker) else { throw GenerationAdapterError.invalidResponse }
        let section = reference[start.upperBound...].components(separatedBy: "\n## ").first ?? ""
        guard let fence = section.range(of: "```json"),
              let end = section[fence.upperBound...].range(of: "```") else { throw GenerationAdapterError.invalidResponse }
        return try GenerationWire.decode(String(section[fence.upperBound..<end.lowerBound]))
    }
    public static func uploadKeys(_ reference: String, keys: Set<String>) -> [String] {
        guard let start = reference.range(of: "\n## 输入\n") else { return [] }
        let section = reference[start.upperBound...].components(separatedBy: "\n## ").first ?? ""
        return section.split(separator: "\n").compactMap { line in
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 5, ["image_upload", "video_upload", "audio_upload"].contains(cells[3]) else { return nil }
            // CLI accepts both visible slot name and internal_name; Schema chooses the input key.
            return [cells[1], cells[2]].first(where: { keys.contains($0) }) ?? cells[1]
        }
    }
    static func outputKind(_ reference: String) -> GenerationArtifactKind {
        guard let start = reference.range(of: "\n## 输出\n") else { return .data }
        let section = reference[start.upperBound...].components(separatedBy: "\n## ").first ?? ""
        for line in section.split(separator: "\n") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 5 else { continue }
            if let kind = GenerationArtifactKind(rawValue: cells[3]) { return kind }
        }
        return .data
    }
}
