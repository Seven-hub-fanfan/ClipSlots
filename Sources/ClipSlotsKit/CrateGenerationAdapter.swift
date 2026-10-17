import Foundation

/// Provider boundary for new callers. Existing CrateGenerationService stays intact
/// until the canvas is explicitly wired to the registry.
public struct CrateGenerationAdapter: GenerationProvider {
    public let context: GenerationProviderContext
    private let directory: URL
    private let executor: GenerationCLIExecutor

    public init(context: GenerationProviderContext = .crate, directory: URL,
                executor: @escaping GenerationCLIExecutor) throws {
        guard context.provider == .crate, context.controlPlane == "i18n-tt",
              context.accountAlias == "default" else {
            throw GenerationAdapterError.invalidConfiguration("当前 Crate CLI 适配器使用 i18n-tt 默认登录身份。")
        }
        self.context = context; self.directory = directory; self.executor = executor
    }
    private func invoke(_ args: [String], submitting: Bool = false) async throws -> ToolProcess.Output {
        var env = GenerationAdapterRuntime.environment()
        env["CRATE_BASE_URL"] = context.endpoint.absoluteString
        return try await executor(.init(arguments: args, environment: env, directory: directory,
            timeout: submitting ? CrateGeneration.submitTimeout : CrateGeneration.pollProcessTimeout,
            submitting: submitting))
    }
    public func preflight() async throws {
        let auth = try GenerationWire.decode(GenerationAdapterRuntime.output(await invoke(
            CrateGeneration.authStatusArguments())))
        guard auth["username"]?.stringValue?.isEmpty == false else {
            throw GenerationAdapterError.authenticationRequired
        }
    }
    public func discover() async throws -> [GenerationCapability] {
        let value = try GenerationWire.decode(GenerationAdapterRuntime.output(await invoke(["model", "list", "--json"])))
        guard let list = value.arrayValue else { throw GenerationAdapterError.invalidResponse }
        return try list.flatMap { item -> [GenerationCapability] in
            guard item["enabled"] != .bool(false) else { return [] }
            let types = item["generationTypes"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var kinds: [GenerationArtifactKind] = []
            if types.contains(where: { ["text-2-image", "image-2-image", "text-to-image", "image-to-image"].contains($0) }) {
                kinds.append(.image)
            }
            if types.contains(where: { ["text-2-video", "image-to-video", "text-to-video"].contains($0) }) {
                kinds.append(.video)
            }
            return try kinds.map { try capability(from: item, kind: $0) }
        }
    }
    private func capability(from manifest: JSONValue, kind: GenerationArtifactKind) throws -> GenerationCapability {
        let id = try GenerationWire.identifier(manifest["id"])
        let types = manifest["generationTypes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let supported = kind == .image ? ["text-2-image", "image-2-image", "text-to-image", "image-to-image"]
            : kind == .video ? ["text-2-video", "image-to-video", "text-to-video"] : []
        guard manifest["enabled"] != .bool(false), types.contains(where: { supported.contains($0) }) else {
            throw GenerationAdapterError.capabilityChanged
        }
        let parameters = manifest["parameters"]?.arrayValue ?? []
        var fields: [String: JSONValue] = ["prompt": ["type": "string", "minLength": 1]]
        let names = Set(parameters.compactMap { $0["name"]?.stringValue })
        for parameter in parameters {
            guard let name = parameter["name"]?.stringValue,
                  ["ratio", "width", "height", "resolution", "duration", "seed", "generate_audio"].contains(name) else { continue }
            let integer = ["width", "height", "duration", "seed"].contains(name)
            var rule: [String: JSONValue] = ["type": .string(name == "generate_audio" ? "boolean" : integer ? "integer" : "string")]
            if let options = parameter["options"]?.arrayValue, !options.isEmpty {
                let values = options.compactMap { option -> JSONValue? in
                    guard let value = option["value"] else { return nil }
                    if integer, let n = value.intValue { return .number(Double(n)) }
                    return value
                }
                if !values.isEmpty { rule["enum"] = .array(values) }
            } else {
                if let min = parameter["min"] { rule["minimum"] = min }
                if let max = parameter["max"] { rule["maximum"] = max }
                if let special = parameter["specialValues"]?.arrayValue, !special.isEmpty {
                    let range = JSONValue.object(rule.filter { $0.key != "type" })
                    rule = ["type": rule["type"]!, "anyOf": .array([range, ["enum": .array(special)]])]
                }
            }
            fields[name] = .object(rule)
        }
        let pathArray: JSONValue = ["type": "array", "items": ["type": "string", "minLength": 1]]
        let roles = manifest["references"]?["roles"]?.arrayValue ?? []
        let refs = roles.compactMap { $0["role"]?.stringValue }
        if kind == .image {
            fields["images"] = pathArray
            fields.removeValue(forKey: "duration"); fields.removeValue(forKey: "generate_audio")
        } else {
            fields["reference_images"] = pathArray
            if refs.contains("first_frame") { fields["first_frame"] = ["type": "string", "minLength": 1] }
            if refs.contains("last_frame") { fields["last_frame"] = ["type": "string", "minLength": 1] }
            fields.removeValue(forKey: "width"); fields.removeValue(forKey: "height")
            if !names.contains("generate_audio") { fields.removeValue(forKey: "generate_audio") }
        }
        let schema: JSONValue = ["type": "object", "additionalProperties": false,
            "required": ["prompt"], "properties": .object(fields)]
        return GenerationCapability(context: context, id: id, title: manifest["name"]?.stringValue ?? id,
            revision: GenerationWire.revision(try manifest.encodedText()), kind: kind,
            inputSchema: schema, metadata: manifest)
    }

    public func prepare(_ input: GenerationInput,
                        capability: GenerationCapability) async throws -> PreparedGenerationRequest {
        guard capability.context == context else { throw GenerationAdapterError.providerMismatch }
        guard input.outputCount == 1 else {
            throw GenerationAdapterError.invalidInput("每个 Crate 画布任务只提交一张，批量由画布独立调度。")
        }
        try GenerationWire.validateIdentifier(capability.id)
        let fresh = try GenerationWire.decode(GenerationAdapterRuntime.output(await invoke(
            CrateGeneration.modelDescribeArguments(model: capability.id))))
        let current = try self.capability(from: fresh, kind: capability.kind)
        guard current.id == capability.id, current.revision == capability.revision,
              current.inputSchema == capability.inputSchema else { throw GenerationAdapterError.capabilityChanged }
        try GenerationSchema.validate(.object(input.values), schema: current.inputSchema)
        let v = input.values
        let prompt = v["prompt"]?.stringValue ?? ""
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GenerationAdapterError.invalidInput("提示词不能为空。")
        }
        let paths: [String]
        var args: [String]
        if capability.kind == .image {
            paths = v["images"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard paths.isEmpty || fresh["generationTypes"]?.arrayValue?.contains(where: {
                ["image-2-image", "image-to-image"].contains($0.stringValue ?? "")
            }) == true else {
                throw GenerationAdapterError.invalidInput("该 Crate 模型不支持图片参考。")
            }
            if let cap = fresh["inputs"]?["image"]?["maxCount"]?.intValue, paths.count > cap {
                throw GenerationAdapterError.invalidInput("参考图片数量超出模型声明上限。")
            }
            if fresh["inputs"]?["image"]?["required"] == .bool(true), paths.isEmpty {
                throw GenerationAdapterError.invalidInput("该模型要求输入图片。")
            }
            let width = v["width"]?.intValue, height = v["height"]?.intValue
            if let min = fresh["dimensions"]?["minimumPixels"]?.intValue, let width, let height,
               Double(width) * Double(height) < Double(min) {
                throw GenerationAdapterError.invalidInput("图片面积小于模型声明的最低像素要求。")
            }
            let request = CrateImageRequest(model: capability.id, prompt: prompt,
                ratio: v["ratio"]?.stringValue ?? "", imagePaths: paths, seed: v["seed"]?.intValue,
                width: width, height: height)
            args = try CrateGeneration.submitArguments(request)
            if let resolution = v["resolution"]?.stringValue {
                args += ["--param", "resolution=\(resolution)"]
            }
        } else if capability.kind == .video {
            let first = v["first_frame"]?.stringValue, last = v["last_frame"]?.stringValue
            let reference = v["reference_images"]?.arrayValue?.compactMap(\.stringValue) ?? []
            paths = [first, last].compactMap { $0 } + reference
            let roles = fresh["references"]?["roles"]?.arrayValue ?? []
            let cap = roles.first { $0["role"] == .string("reference_image") }?["maxCount"]?.intValue ?? 0
            guard reference.count <= cap else { throw GenerationAdapterError.invalidInput("参考图片数量超出模型声明上限。") }
            let parsed = try CrateModelCatalog.parse("[" + fresh.encodedText() + "]").first
            if parsed?.framesExcludeReferences == true, !reference.isEmpty, first != nil || last != nil {
                throw GenerationAdapterError.invalidInput("该模型的首尾帧与参考图不能混用。")
            }
            if parsed?.requiresImageInput == true, paths.isEmpty {
                throw GenerationAdapterError.invalidInput("该模型要求输入图片。")
            }
            let present = Set(["first_frame": first != nil, "last_frame": last != nil,
                               "reference_image": !reference.isEmpty].filter(\.value).map(\.key))
            for constraint in fresh["references"]?["constraints"]?.arrayValue ?? [] {
                if constraint["type"] == .string("requires-any") {
                    let when = constraint["whenAny"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    let fields = constraint["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    if !present.isDisjoint(with: when), present.isDisjoint(with: fields) {
                        throw GenerationAdapterError.invalidInput("参考素材未满足模型声明的依赖关系。")
                    }
                }
            }
            args = try CrateGeneration.submitArguments(CrateVideoRequest(model: capability.id, prompt: prompt,
                ratio: v["ratio"]?.stringValue ?? "", resolution: v["resolution"]?.stringValue ?? "",
                duration: v["duration"]?.intValue, generateAudio: v["generate_audio"]?.boolValue,
                firstFramePath: first, lastFramePath: last, referenceImagePaths: reference, seed: v["seed"]?.intValue))
        } else { throw GenerationAdapterError.invalidInput("Crate 首期仅适配图片与视频模型。") }
        let files = try paths.map(GenerationAdapterRuntime.file)
        return .init(capability: capability, input: input, inputFiles: files, arguments: args)
    }

    public func submit(_ request: PreparedGenerationRequest) async throws -> GenerationSubmission {
        guard request.capability.context == context else { throw GenerationAdapterError.providerMismatch }
        try Task.checkCancellation()
        guard request.inputFiles.allSatisfy(\.isCurrent) else { throw GenerationAdapterError.inputChanged }
        let output: ToolProcess.Output
        do { output = try await invoke(request.arguments, submitting: true) }
        catch is CancellationError { throw CancellationError() }
        catch let error as GenerationAdapterError where error == .processNotStarted { throw error }
        catch { throw GenerationAdapterError.submissionUnknown(.crate) }
        let complete = try? GenerationWire.objects(output.stdout)
        let objects = complete ?? output.stdout.split(separator: "\n").compactMap {
            try? GenerationWire.decode(String($0))
        }
        let accepted = objects.filter { $0["taskId"] != nil || $0["task_id"] != nil }
        if let response = accepted.first {
            guard let ids = try? accepted.map({ try GenerationWire.identifier($0["taskId"] ?? $0["task_id"]) }),
                  Set(ids).count == 1 else { throw GenerationAdapterError.submissionUnknown(.crate) }
            let seed = (try? CrateGeneration.parseSubmitResponse(response.encodedText()))?.seed
            let task = try GenerationTaskHandle(context: context, taskID: ids[0],
                capabilityID: request.capability.id, capabilityRevision: request.capability.revision,
                kind: request.capability.kind, seed: seed)
            return .init(task: task, needsQuery: output.status != 0 || output.stopped || output.truncated
                || complete == nil || objects.contains(where: { $0["success"] == .bool(false) }))
        }
        if objects.contains(where: { $0["success"] == .bool(false) }) {
            throw GenerationAdapterError.commandFailed(code: "SUBMISSION_REJECTED", phase: "submit")
        }
        throw GenerationAdapterError.submissionUnknown(.crate)
    }

    public func query(_ task: GenerationTaskHandle) async throws -> GenerationObservation {
        guard task.context == context else { throw GenerationAdapterError.providerMismatch }
        try GenerationWire.validateIdentifier(task.taskID)
        let text = try GenerationAdapterRuntime.output(await invoke(CrateGeneration.taskGetArguments(taskId: task.taskID)))
        let raw = try GenerationWire.decode(text)
        guard let info = raw["taskInfo"] else { throw GenerationAdapterError.invalidResponse }
        if let returned = info["task_id"] ?? info["taskId"], try GenerationWire.identifier(returned) != task.taskID {
            throw GenerationAdapterError.invalidResponse
        }
        let status = info["task_status"]?.intValue ?? -1
        let rawStatus = String(status)
        switch status {
        case 1:
            let ahead = info["queue_ahead_count"]?.intValue ?? 0
            return .init(task: task, status: ahead > 0 ? .queued(ahead: ahead) : .running, rawStatus: rawStatus)
        case 2:
            let bindings = [GenerationOutputBinding(name: "media", kind: task.kind,
                path: [.key("results"), .each, .key("content")])]
            let artifacts = GenerationWire.artifacts(info, bindings: bindings)
            return .init(task: task, status: artifacts.isEmpty ? .outputMismatch : .succeeded,
                         rawStatus: rawStatus, artifacts: artifacts, rawOutput: info["results"])
        case 3: return .init(task: task, status: .failed, rawStatus: rawStatus, detail: "Crate 生成任务失败。")
        default: return .init(task: task, status: .unknown(rawStatus), rawStatus: rawStatus)
        }
    }
}
