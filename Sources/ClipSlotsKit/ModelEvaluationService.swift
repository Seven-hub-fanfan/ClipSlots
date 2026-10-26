import Foundation

public protocol ModelHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct ModelURLSessionTransport: ModelHTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        // Disallow cross-origin redirects carrying custom authentication headers.
        let session = URLSession(configuration: .ephemeral, delegate: ModelNoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 32 * 1024 * 1024, let http = response as? HTTPURLResponse else {
            throw ModelWorkspaceError.response
        }
        return (data, http.statusCode)
    }
}

private final class ModelNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum ModelJSONPath {
    public static func value(_ root: JSONValue, path: String) -> JSONValue? {
        var current: JSONValue? = root
        for part in path.split(separator: ".").map(String.init) {
            if let index = Int(part), let array = current?.arrayValue {
                guard array.indices.contains(index) else { return nil }
                current = array[index]
            } else { current = current?[part] }
        }
        return current
    }
    public static func media(_ value: JSONValue?) -> [String] {
        let values = value?.arrayValue ?? value.map { [$0] } ?? []
        return values.compactMap(\.stringValue).filter { GenerationWire.mediaURL($0) != nil }
    }
}

public struct ModelEvaluationOutput: Sendable {
    public var text = ""
    public var urls: [String] = []
    public var paths: [String] = []
    public init(text: String = "", urls: [String] = [], paths: [String] = []) {
        self.text = text; self.urls = urls; self.paths = paths
    }
}

/// The HTTP adapter never retries POST or silently changes a selected provider.
public struct ModelEvaluationService: Sendable {
    private let transport: any ModelHTTPTransport
    public init(transport: any ModelHTTPTransport = ModelURLSessionTransport()) { self.transport = transport }
    private func request(profile: ModelProfile, key: String?, url: String, method: String,
                         body: JSONValue? = nil) throws -> URLRequest {
        try ModelProfile.validateURL(url)
        guard let target = URL(string: url) else { throw ModelWorkspaceError.invalid("接口地址无效。") }
        var request = URLRequest(url: target, timeoutInterval: profile.timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if profile.requiresKey {
            guard let key, !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw ModelWorkspaceError.credential }
            request.setValue(profile.authPrefix + key, forHTTPHeaderField: profile.authHeader)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    public func input(question: ModelQuestion, profile: ModelProfile) throws -> JSONValue {
        try profile.validate()
        guard question.kind == profile.kind, !question.conflict, !question.prompt.isEmpty,
              question.references.allSatisfy(\.isCurrent) else {
            throw ModelWorkspaceError.invalid("题目类型、内容或参考素材无效。")
        }
        var fields = profile.parameters
        // Authentication must not be smuggled into exportable default parameters.
        guard !fields.keys.contains(where: { ["api_key", "apikey", "authorization", "access_token", "token"].contains($0.lowercased()) }) else {
            throw ModelWorkspaceError.invalid("密钥只能保存在认证字段，不能放入默认参数。")
        }
        fields["model"] = .string(profile.model)
        if profile.contract == .chatCompletions {
            var content: JSONValue = .string(question.prompt)
            if !question.references.isEmpty {
                guard profile.supportsImages else { throw ModelWorkspaceError.invalid("该 LLM 未声明图像输入能力。") }
                var parts: [JSONValue] = [["type": "text", "text": .string(question.prompt)]]
                for ref in question.references {
                    let url = URL(fileURLWithPath: ref.path)
                    let ext = URL(fileURLWithPath: ref.name ?? ref.path).pathExtension.lowercased()
                    let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp"][ext]
                    guard let mime, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= 12 * 1024 * 1024 else { throw ModelWorkspaceError.invalid("LLM 参考输入需要 12MB 内的 PNG/JPEG/WebP。") }
                    let encoded = try Data(contentsOf: url).base64EncodedString()
                    parts.append(["type": "image_url", "image_url": ["url": .string("data:\(mime);base64,\(encoded)")]])
                }
                content = .array(parts)
            }
            fields["messages"] = [["role": "user", "content": content]]
            fields["stream"] = false
        } else {
            fields["prompt"] = .string(question.prompt)
            // Never silently ignore references for an unsupported generation contract.
            if !question.references.isEmpty {
                guard profile.contract == .asyncMedia, let field = profile.referenceInputField else {
                    throw ModelWorkspaceError.invalid("此 API 契约未配置参考输入字段。请在模型配置中声明接口的参考输入方式。")
                }
                fields[field] = .array(try question.references.map { ref in
                    let url = URL(fileURLWithPath: ref.path)
                    let ext = URL(fileURLWithPath: ref.name ?? ref.path).pathExtension.lowercased()
                    let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp"][ext]
                    guard let mime, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= 12 * 1024 * 1024 else {
                        throw ModelWorkspaceError.invalid("异步参考输入需要 12MB 内的 PNG/JPEG/WebP。")
                    }
                    return .string("data:\(mime);base64," + (try Data(contentsOf: url)).base64EncodedString())
                })
            }
        }
        return .object(fields)
    }

    public func submit(question: ModelQuestion, profile: ModelProfile, key: String?,
                       didConfirmTask: @Sendable (String) async throws -> Void) async throws -> ModelEvaluationOutput? {
        let body = try input(question: question, profile: profile)
        let request = try request(profile: profile, key: key, url: profile.endpoint, method: "POST", body: body)
        try Task.checkCancellation()
        let data: Data; let status: Int
        do { (data, status) = try await transport.send(request) }
        catch { throw ModelWorkspaceError.submissionUnknown }
        if (400...499).contains(status) { throw ModelWorkspaceError.http(status) }
        guard (200...299).contains(status) else { throw ModelWorkspaceError.submissionUnknown }
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ModelWorkspaceError.submissionUnknown }
        switch profile.contract {
        case .chatCompletions:
            guard let text = root["choices"]?.arrayValue?.first?["message"]?["content"]?.stringValue, !text.isEmpty else {
                throw ModelWorkspaceError.submissionUnknown
            }
            return .init(text: text)
        case .imageGenerations:
            let urls = root["data"]?.arrayValue?.compactMap { $0["url"]?.stringValue }.filter { GenerationWire.mediaURL($0) != nil } ?? []
            var paths: [String] = []
            for encoded in root["data"]?.arrayValue?.compactMap({ $0["b64_json"]?.stringValue }) ?? [] {
                guard let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= 24 * 1024 * 1024 else {
                    throw ModelWorkspaceError.submissionUnknown
                }
                let root = ClipSlotsPaths.dataRoot.appendingPathComponent("models/media")
                do {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let path = root.appendingPathComponent(UUID().uuidString + ".png")
                    try bytes.write(to: path, options: .atomic); paths.append(path.path)
                } catch { throw ModelWorkspaceError.submissionUnknown }
            }
            guard !urls.isEmpty || !paths.isEmpty else { throw ModelWorkspaceError.submissionUnknown }
            return .init(urls: urls, paths: paths)
        case .asyncMedia:
            guard let id = ModelJSONPath.value(root, path: profile.asynchronous.taskIDPath)?.stringValue,
                  !id.isEmpty, id.utf8.count < 512 else { throw ModelWorkspaceError.submissionUnknown }
            try await didConfirmTask(id)
            return nil
        }
    }

    public func query(profile: ModelProfile, key: String?, taskID: String) async throws -> ModelEvaluationOutput? {
        let encoded = taskID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let url = profile.asynchronous.queryURL.replacingOccurrences(of: "{id}", with: encoded)
        let req = try request(profile: profile, key: key, url: url, method: "GET")
        let (data, status) = try await transport.send(req)
        guard (200...299).contains(status) else { throw ModelWorkspaceError.http(status) }
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let state = ModelJSONPath.value(root, path: profile.asynchronous.statusPath)?.stringValue else {
            throw ModelWorkspaceError.response
        }
        if profile.asynchronous.failureValues.contains(state) {
            throw ModelWorkspaceError.remoteFailed
        }
        guard profile.asynchronous.successValues.contains(state) else { return nil }
        let urls = ModelJSONPath.media(ModelJSONPath.value(root, path: profile.asynchronous.outputPath))
        guard !urls.isEmpty else { throw ModelWorkspaceError.response }
        return .init(urls: urls)
    }

    public func generateQuestions(profile: ModelProfile, key: String?, topic: String,
                                  kind: ModelKind, count: Int, dimensions: [ModelDimension]) async throws -> [ModelQuestion] {
        guard profile.kind == .llm, (1...50).contains(count) else { throw ModelWorkspaceError.invalid("出题需要 LLM，数量范围 1–50。") }
        var question = ModelQuestion(); question.kind = .llm
        question.prompt = """
        为\(kind.title)模型测评出\(count)道不同题，主题：\(topic)。
        考察：\(dimensions.map(\.title).joined(separator: "、"))。
        每题给出可观察的评分标准，不能把模型自答当标准答案。避免依赖未提供的参考文件。
        仅返回 JSON 数组，每个元素包含 title、prompt、criteria、tags 字符串，不要 Markdown。
        """
        guard let result = try await submit(question: question, profile: profile, key: key, didConfirmTask: { _ in }),
              let raw = result.text.data(using: .utf8),
              let rows = try? JSONDecoder().decode(JSONValue.self, from: raw).arrayValue,
              !rows.isEmpty, rows.count <= count else { throw ModelWorkspaceError.response }
        var seen = Set<String>()
        return try rows.map { row in
            guard let prompt = row["prompt"]?.stringValue, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(prompt).inserted, let criteria = row["criteria"]?.stringValue, !criteria.isEmpty else {
                throw ModelWorkspaceError.response
            }
            var q = ModelQuestion(); q.kind = kind; q.prompt = prompt
            q.title = row["title"]?.stringValue ?? String(prompt.prefix(32))
            q.criteria = criteria; q.tags = row["tags"]?.stringValue ?? ""; q.dimensions = dimensions
            return q
        }
    }
}
