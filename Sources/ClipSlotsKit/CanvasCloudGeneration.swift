import Foundation
import Darwin
import ImageIO

public struct CanvasCloudConfiguration: Codable, Equatable {
    public enum Provider: String, Codable, CaseIterable {
        case elevenLabs, miniMax, tripo, worldLabs
        public var title: String {
            switch self { case .elevenLabs: return "ElevenLabs"; case .miniMax: return "MiniMax"
            case .tripo: return "Tripo"; case .worldLabs: return "World Labs" }
        }
    }
    public enum Mode: String, Codable { case music, sound, text3D, image3D, world, rig, animate }
    public var provider: Provider = .elevenLabs
    public var mode: Mode = .music
    public var prompt = ""
    public var lyrics = ""
    public var duration: Double = 30
    public var instrumental = true
    public var model = ""
    public var inputAttachmentID: String?
    public var sourceTaskID: String?
    public var animation = "walk"
    public var inPlace = true
    public var detailedTexture = false
    public var worldQuality = "100k"
    public var task: CanvasCloudTask?
    /// Set only by the explicit "new task" action, never by changing a picker.
    public var replacesReceiptID: UUID?
    public init() {}
    public var effectiveModel: String {
        model.isEmpty ? (supportedModels.first ?? "") : model
    }
    public var serviceIdentity: CanvasCloudServiceIdentity {
        .init(provider: provider, mode: mode)
    }
    public var supportedModels:[String] {
        switch provider {
        case .elevenLabs:return mode == .sound ? ["eleven_text_to_sound_v2","eleven_text_to_sound_v3"] : ["music_v1","music_v2","music_v2_5"]
        case .miniMax:return ["music-2.6","music-3.0"]
        case .tripo:return mode == .rig ? ["v3.0-20260909"] : mode == .animate ? [] : ["v3.1-20260211"]
        case .worldLabs:return ["marble-1.1","marble-1.1-plus"]
        }
    }
    public var validationError: String? {
        guard prompt.utf8.count <= 65_536, lyrics.utf8.count <= 32_768, model.utf8.count <= 256,
              (inputAttachmentID?.utf8.count ?? 0) <= 256, (sourceTaskID?.utf8.count ?? 0) <= 256 else {
            return "提示词、歌词或任务标识超过本地字节预算"
        }
        if !model.isEmpty && !supportedModels.contains(model) {return "模型与所选服务或生成类型不匹配"}
        guard duration.isFinite else { return "时长无效" }
        switch (provider, mode) {
        case (.elevenLabs, .music):
            if prompt.isEmpty || prompt.count > 4100 || !(3...600).contains(duration) { return "音乐提示词需为 1–4100 字，时长 3–600 秒" }
        case (.elevenLabs, .sound):
            if prompt.isEmpty || prompt.count > 4100 || !(0.5...30).contains(duration) { return "音效提示词需为 1–4100 字，时长 0.5–30 秒" }
        case (.miniMax, .music):
            if prompt.isEmpty || prompt.count > 2000 || lyrics.count > 3500 { return "MiniMax 提示词最多 2000 字，歌词最多 3500 字" }
            if !instrumental && lyrics.isEmpty { return "请填写歌词，或选择纯音乐" }
        case (.tripo, .text3D):
            if prompt.isEmpty || prompt.count > 1024 { return "3D 提示词需为 1–1024 字" }
        case (.tripo, .image3D):
            if inputAttachmentID?.isEmpty != false { return "请先选择参考图片" }
        case (.tripo, .rig), (.tripo, .animate):
            if sourceTaskID?.isEmpty != false { return "请先选择已完成的 Tripo 模型任务" }
            if mode == .animate && !["idle","walk","run","jump"].contains(animation) { return "请选择支持的动作" }
        case (.worldLabs, .world):
            if prompt.isEmpty || prompt.count > 10000 || !["100k","500k"].contains(worldQuality) { return "世界提示词或质量档位无效" }
        default: return "此服务不支持当前生成类型"
        }
        if let task, task.provider != provider || task.mode != mode { return "任务与当前服务不匹配，请新建任务" }
        return nil
    }
}

/// Submission route is captured before I/O. It contains no account or key.
public struct CanvasCloudServiceIdentity: Codable, Equatable {
    public let baseURL: String
    public let submissionPath: String
    public let statusPrefix: String?
    public init(baseURL: String, submissionPath: String, statusPrefix: String?) {
        self.baseURL = baseURL; self.submissionPath = submissionPath; self.statusPrefix = statusPrefix
    }
    public init(provider: CanvasCloudConfiguration.Provider, mode: CanvasCloudConfiguration.Mode) {
        switch provider {
        case .elevenLabs:
            baseURL = "https://api.elevenlabs.io/v1/"
            submissionPath = mode == .sound ? "sound-generation?output_format=mp3_44100_128"
                : "music?output_format=mp3_44100_128"
            statusPrefix = nil
        case .miniMax:
            baseURL = "https://api.minimax.io/v1/"
            submissionPath = "music_generation"; statusPrefix = nil
        case .tripo:
            baseURL = "https://openapi.tripo3d.com/v3/"
            switch mode {
            case .image3D: submissionPath = "generation/image-to-model"
            case .rig: submissionPath = "animations/rig"
            case .animate: submissionPath = "animations/retarget"
            default: submissionPath = "generation/text-to-model"
            }
            statusPrefix = "tasks/"
        case .worldLabs:
            baseURL = "https://api.worldlabs.ai/marble/v1/"
            submissionPath = "worlds:generate"; statusPrefix = "operations/"
        }
    }
}

/// A rig check is a separate remote operation, never the final model task.
public struct CanvasCloudRigCheck: Codable, Equatable {
    public enum State: String, Codable { case submitting, pending, complete }
    public let sourceTaskID: String
    public let service: CanvasCloudServiceIdentity
    public var id: String?
    public var state: State
    public var riggable: Bool?
    public var rigType: String?
    public init(sourceTaskID: String, service: CanvasCloudServiceIdentity) {
        self.sourceTaskID = sourceTaskID; self.service = service; state = .submitting
    }
}

/// IDs and public processing state only. Credentials never enter graph JSON.
public struct CanvasCloudTask: Codable, Equatable {
    public enum State: String, Codable { case submitting, pending, complete, failed, unknown }
    public var provider: CanvasCloudConfiguration.Provider
    public var mode: CanvasCloudConfiguration.Mode
    public var id: String?
    public var state: State
    public var createdAt = Date()
    /// Missing fields in legacy records stay unknown.
    public var model: String?
    public var service: CanvasCloudServiceIdentity?
    public var receiptID: UUID?
    public var rigCheck: CanvasCloudRigCheck?
    /// Persisted before the final submission. A crash at this boundary is
    /// unknown, even if the preceding rig check is recoverable.
    public var submissionStarted: Bool?
    public var canResumeRigCheck: Bool {
        state != .failed && mode == .rig && id == nil && submissionStarted == false &&
            ((rigCheck?.state == .complete && rigCheck?.riggable == true &&
              ["biped", "quadruped"].contains(rigCheck?.rigType ?? "")) ||
             (rigCheck?.state == .pending && rigCheck?.id != nil))
    }
    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 256 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
        }
    }
    public init(provider: CanvasCloudConfiguration.Provider, mode: CanvasCloudConfiguration.Mode,
                id: String? = nil, state: State = .submitting) {
        self.provider = provider; self.mode = mode; self.id = id; self.state = state
    }
    public init(configuration: CanvasCloudConfiguration, receiptID: UUID? = nil,
                id: String? = nil, state: State = .submitting) {
        provider = configuration.provider; mode = configuration.mode; self.id = id; self.state = state
        model = configuration.effectiveModel; service = configuration.serviceIdentity
        self.receiptID = receiptID
        if configuration.provider == .tripo && configuration.mode == .rig { submissionStarted = false }
    }
}

public struct CanvasCloudResourceMetadata: Codable, Equatable {
    public var provider: CanvasCloudConfiguration.Provider
    public var taskID: String?
    public var receiptID: UUID?
    public var metricScale: Double = 1
    public var groundOffset: Double = 0
    public var marbleCoordinates = false
    public init(provider: CanvasCloudConfiguration.Provider, taskID: String?) {
        self.provider = provider; self.taskID = taskID
    }
}

public enum CanvasCloudError: LocalizedError {
    case invalid(String), unauthorized, balance, remote, rejected, notSubmitted, unknownSubmission, expired, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        case .unauthorized: return "云服务密钥无效或权限不足"
        case .balance: return "云服务额度不足"
        case .remote: return "云服务返回失败，请到服务控制台查看任务"
        case .rejected: return "云服务明确拒绝了此次请求，请修正参数后重试"
        case .notSubmitted: return "提交前已取消，未开始云端生成"
        case .unknownSubmission: return "提交结果未知。为避免重复扣费，未自动重试；请先在服务控制台确认"
        case .expired: return "任务尚未完成，已保留任务 ID，可继续查询"
        case .cancelled: return "已停止本地等待；服务端任务可能仍在运行，可继续查询"
        }
    }
}

/// Per-request streaming bound, including error bodies. Redirected API requests
/// never forward credentials to a different host. Tests inject URLProtocol via
/// the configuration; production uses an ephemeral URLSession.
public final class CanvasCloudHTTP {
    public enum CancellationPolicy { case immediate, receiveSubmission }
    public let configuration: URLSessionConfiguration
    #if DEBUG
    var didReceiveDataForTest: ((Int) -> Void)?
    #endif
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }
    public func send(_ request: URLRequest, limit: Int,
                     cancellation: CancellationPolicy = .immediate,
                     acceptedResponse: ((Data, HTTPURLResponse) -> Bool)? = nil) async throws -> (Data, HTTPURLResponse) {
        guard limit > 0, limit <= 150 * 1024 * 1024, request.timeoutInterval.isFinite,
              request.timeoutInterval > 0, request.timeoutInterval <= 300 else {
            throw CanvasCloudError.invalid("响应预算或等待时限无效")
        }
        let transfer = Transfer(configuration: configuration, request: request, limit: limit,
                                cancellation: cancellation, acceptedResponse: acceptedResponse)
        #if DEBUG
        transfer.dataObserver = didReceiveDataForTest
        #endif
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { transfer.start($0) }
        }, onCancel: { transfer.cancel() })
    }
    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let configuration: URLSessionConfiguration, request: URLRequest, limit: Int
        let cancellation: CancellationPolicy
        let acceptedResponse: ((Data, HTTPURLResponse) -> Bool)?
        #if DEBUG
        var dataObserver: ((Int) -> Void)?
        #endif
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var bytes = Data()
        private var response: HTTPURLResponse?
        private var finished = false
        private var stopped = false
        private var deadline: DispatchWorkItem?
        init(configuration: URLSessionConfiguration, request: URLRequest, limit: Int,
             cancellation: CancellationPolicy, acceptedResponse: ((Data, HTTPURLResponse) -> Bool)?) {
            self.configuration = configuration; self.request = request; self.limit = limit
            self.cancellation = cancellation; self.acceptedResponse = acceptedResponse
        }
        func start(_ continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
            lock.lock()
            if stopped { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session; let task = session.dataTask(with: request); self.task = task
            let deadline = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock(); let task = self.task; self.lock.unlock()
                task?.cancel()
            }
            self.deadline = deadline
            DispatchQueue.global().asyncAfter(deadline: .now() + request.timeoutInterval, execute: deadline)
            task.resume(); lock.unlock()
        }
        func cancel() {
            lock.lock(); stopped = true
            let task = cancellation == .immediate ? task : nil
            lock.unlock(); task?.cancel()
        }
        func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true; let continuation = continuation; self.continuation = nil
            deadline?.cancel(); deadline = nil
            let session = session; self.session = nil
            lock.unlock(); continuation?.resume(with: result); session?.invalidateAndCancel()
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let response = response as? HTTPURLResponse, response.expectedContentLength <= Int64(limit) else {
                completionHandler(.cancel); finish(.failure(CanvasCloudError.invalid("云端响应超过大小限制"))); return
            }
            self.response = response; completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard bytes.count <= limit - data.count else {
                bytes.append(contentsOf: data.prefix(max(0, limit - bytes.count)))
                if let response, cancellation == .receiveSubmission,
                   acceptedResponse?(bytes, response) == true {
                    dataTask.cancel(); finish(.success((bytes, response))); return
                }
                dataTask.cancel(); finish(.failure(CanvasCloudError.invalid("云端响应超过大小限制"))); return
            }
            bytes.append(data)
            #if DEBUG
            dataObserver?(bytes.count)
            #endif
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let authenticated = request.value(forHTTPHeaderField: "Authorization") != nil
                || request.value(forHTTPHeaderField: "xi-api-key") != nil || request.value(forHTTPHeaderField: "WLT-Api-Key") != nil
            guard let url = newRequest.url, CanvasCloudClient.allowedDownloadURL(url),
                  !authenticated || url.host == request.url?.host else {
                completionHandler(nil); finish(.failure(CanvasCloudError.invalid("云服务重定向被拒绝"))); return
            }
            completionHandler(newRequest)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                if let response, cancellation == .receiveSubmission,
                   acceptedResponse?(bytes, response) == true { finish(.success((bytes, response))) }
                else { finish(.failure(error)) }
            }
            else if let response { finish(.success((bytes, response))) }
            else { finish(.failure(CanvasCloudError.remote)) }
        }
    }
}

public final class CanvasCloudClient {
    public struct Result {
        public var data: Data
        public var fileExtension: String
        public var metadata: CanvasCloudResourceMetadata
        public init(data:Data,fileExtension:String,metadata:CanvasCloudResourceMetadata) {
            self.data=data;self.fileExtension=fileExtension;self.metadata=metadata
        }
    }
    public struct Status {
        public var done: Bool
        public var url: URL?
        public var metadata: CanvasCloudResourceMetadata
        public var rigType: String?
    }
    public let http: CanvasCloudHTTP
    public init(http: CanvasCloudHTTP = .init()) { self.http = http }
    public static func allowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host.contains(":") { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            if octets[0] == 0 || octets[0] == 10 || octets[0] == 127 || octets[0] >= 224
                || (octets[0] == 169 && octets[1] == 254) || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 172 && (16...31).contains(octets[1])) { return false }
        }
        return true
    }
    private func request(_ provider: CanvasCloudConfiguration.Provider, path: String,
                         key: String, body: [String: Any]? = nil,
                         service: CanvasCloudServiceIdentity? = nil) throws -> URLRequest {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              key.utf8.count <= 4096, !key.contains("\r"), !key.contains("\n") else { throw CanvasCloudError.unauthorized }
        let base: String, header: String, value: String
        switch provider {
        case .elevenLabs: base = "https://api.elevenlabs.io/v1/"; header = "xi-api-key"; value = key
        case .miniMax: base = "https://api.minimax.io/v1/"; header = "Authorization"; value = "Bearer \(key)"
        case .tripo: base = "https://openapi.tripo3d.com/v3/"; header = "Authorization"; value = "Bearer \(key)"
        case .worldLabs: base = "https://api.worldlabs.ai/marble/v1/"; header = "WLT-Api-Key"; value = key
        }
        // Persisted routes may use an older API version, but always the same
        // provider origin. A changed global default cannot redirect an old task.
        let origin = service?.baseURL ?? base
        guard let oldURL = URL(string: origin), let currentURL = URL(string: base),
              oldURL.scheme == "https", oldURL.host == currentURL.host, oldURL.port == currentURL.port,
              oldURL.user == nil, oldURL.password == nil, oldURL.query == nil, oldURL.fragment == nil,
              origin.hasSuffix("/"), !oldURL.path.contains(".."),
              !path.hasPrefix("/"), !path.contains(".."),
              let url = URL(string: origin + path), url.host == currentURL.host else {
            throw CanvasCloudError.invalid("保存的云服务身份无效")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
        request.setValue(value, forHTTPHeaderField: header)
        if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
    private func checked(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 || response.statusCode == 403 { throw CanvasCloudError.unauthorized }
        if response.statusCode == 402 { throw CanvasCloudError.balance }
        guard (200...299).contains(response.statusCode) else { throw CanvasCloudError.remote }
    }
    private func checkedSubmission(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 || response.statusCode == 403 { throw CanvasCloudError.unauthorized }
        if response.statusCode == 402 { throw CanvasCloudError.balance }
        if (400...499).contains(response.statusCode) { throw CanvasCloudError.rejected }
        guard (200...299).contains(response.statusCode) else { throw CanvasCloudError.unknownSubmission }
    }
    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await http.send(request, limit: 4 * 1024 * 1024); try checked(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CanvasCloudError.remote }
        if let code = object["code"] as? Int, code != 0 {
            if code == 2010 { throw CanvasCloudError.balance }; throw CanvasCloudError.remote
        }
        return object
    }
    /// Only a complete first JSON object can carry an accepted receipt. A
    /// truncated object is unknown; malformed bytes after it cannot erase its ID.
    static func responseObject(_ data: Data) -> [String: Any]? {
        let bytes = [UInt8](data)
        guard let start = bytes.firstIndex(where: { ![9, 10, 13, 32].contains($0) }),
              bytes[start] == 123 else { return nil }
        var depth = 0, quoted = false, escaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1 }
            else if byte == 125 || byte == 93 {
                depth -= 1
                if depth == 0 {
                    return (try? JSONSerialization.jsonObject(with: Data(bytes[start...index]))) as? [String: Any]
                }
            }
        }
        return nil
    }
    private func submissionJSON(_ request: URLRequest,
                                receipt: @escaping ([String: Any]) -> String?) async throws -> [String: Any] {
        do {
            let (data, response) = try await http.send(request, limit: 4 * 1024 * 1024,
                cancellation: .receiveSubmission, acceptedResponse: { data, response in
                    guard (200...299).contains(response.statusCode),
                          let object = Self.responseObject(data),
                          (object["code"] as? Int ?? 0) == 0,
                          let id = receipt(object), self.validID(id) else { return false }
                    return true
                })
            if response.statusCode == 401 || response.statusCode == 403 { throw CanvasCloudError.unauthorized }
            if response.statusCode == 402 { throw CanvasCloudError.balance }
            if (400...499).contains(response.statusCode) { throw CanvasCloudError.rejected }
            guard (200...299).contains(response.statusCode),
                  let object = Self.responseObject(data) else { throw CanvasCloudError.unknownSubmission }
            if let code = object["code"] as? Int, code != 0 {
                if code == 2010 { throw CanvasCloudError.balance }
                throw CanvasCloudError.rejected
            }
            guard let id = receipt(object), validID(id) else { throw CanvasCloudError.unknownSubmission }
            return object
        } catch is CancellationError { throw CanvasCloudError.notSubmitted }
        catch let error as CanvasCloudError {
            switch error {
            case .unauthorized, .balance, .rejected: throw error
            default: throw CanvasCloudError.unknownSubmission
            }
        } catch { throw CanvasCloudError.unknownSubmission }
    }
    private func taskID(_ object: [String: Any]) throws -> String {
        guard let id = object["task_id"] as? String, validID(id) else { throw CanvasCloudError.remote }; return id
    }
    private func validID(_ id: String) -> Bool {
        CanvasCloudTask.validID(id)
    }
    static func referenceImage(_ url: URL, afterOpen: (() throws -> Void)? = nil) throws -> (data: Data, mime: String) {
        let failure = CanvasCloudError.invalid("参考图需为完整 PNG / JPEG，最多 20 MiB；解码最多 6400 万像素")
        guard url.isFileURL else { throw failure }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure }
        defer { close(fd) }
        var before = stat(), after = stat(), path = stat()
        let limit = 20 * 1024 * 1024
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= limit else { throw failure }
        try afterOpen?()
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw failure }
            if count == 0 { break }
            guard count <= limit - data.count else { throw failure }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(fd, &after) == 0, lstat(url.path, &path) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, data.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              path.st_mode & S_IFMT == S_IFREG, path.st_dev == after.st_dev, path.st_ino == after.st_ino,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg"].contains(type),
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768, width <= 64_000_000 / height,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw failure }
        return (data, type == "public.png" ? "image/png" : "image/jpeg")
    }
    public func audio(_ config: CanvasCloudConfiguration, key: String) async throws -> Result {
        if let error = config.validationError { throw CanvasCloudError.invalid(error) }
        guard config.task == nil else { throw CanvasCloudError.invalid("已有任务，请先取回结果或明确新建任务") }
        guard config.provider == .elevenLabs || config.provider == .miniMax else { throw CanvasCloudError.invalid("请选择音频服务") }
        do { return try await audioResponse(config, key: key) }
        catch is CancellationError { throw CanvasCloudError.notSubmitted }
        catch let error as CanvasCloudError {
            switch error {
            case .unauthorized, .balance, .rejected, .notSubmitted: throw error
            default: throw CanvasCloudError.unknownSubmission
            }
        } catch { throw CanvasCloudError.unknownSubmission }
    }
    private func audioResponse(_ config: CanvasCloudConfiguration, key: String) async throws -> Result {
        if config.provider == .elevenLabs {
            let sound = config.mode == .sound
            let body: [String: Any] = sound
                ? ["text":config.prompt,"duration_seconds":config.duration,"loop":false,"prompt_influence":0.3,
                   "model_id":config.model.isEmpty ? "eleven_text_to_sound_v2" : config.model]
                : ["prompt":config.prompt,"music_length_ms":Int(config.duration * 1000),"force_instrumental":config.instrumental,
                   "model_id":config.model.isEmpty ? "music_v1" : config.model]
            let route = sound ? "sound-generation?output_format=mp3_44100_128" : "music?output_format=mp3_44100_128"
            let (data,response) = try await http.send(request(.elevenLabs, path: route, key: key, body: body),
                limit: 64 * 1024 * 1024, cancellation: .receiveSubmission)
            try checkedSubmission(response)
            guard data.count > 16, !(response.value(forHTTPHeaderField:"Content-Type") ?? "").lowercased().contains("json") else { throw CanvasCloudError.remote }
            return Result(data: data, fileExtension: "mp3",
                metadata: .init(provider: .elevenLabs, taskID: response.value(forHTTPHeaderField:"song-id")))
        }
        let body: [String: Any] = ["model":config.model.isEmpty ? "music-2.6" : config.model,
            "prompt":config.prompt,"lyrics":config.lyrics,"is_instrumental":config.instrumental,
            "stream":false,"output_format":"hex",
            "audio_setting":["sample_rate":44100,"bitrate":128000,"format":"mp3"]]
        let (data,response) = try await http.send(request(.miniMax,path:"music_generation",key:key,body:body),
            limit:128 * 1024 * 1024, cancellation: .receiveSubmission)
        try checkedSubmission(response)
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let base = object["base_resp"] as? [String:Any], let code = base["status_code"] as? Int else { throw CanvasCloudError.remote }
        if code == 1004 || code == 2049 { throw CanvasCloudError.unauthorized }
        if code == 1008 { throw CanvasCloudError.balance }
        guard code == 0 else { throw CanvasCloudError.rejected }
        guard let output = object["data"] as? [String:Any], output["status"] as? Int == 2,
              let hex = output["audio"] as? String, hex.count > 32, hex.count.isMultiple(of:2),
              hex.utf8.count <= 128 * 1024 * 1024 else { throw CanvasCloudError.remote }
        let bytes = Array(hex.utf8); var audio = Data(); audio.reserveCapacity(bytes.count / 2)
        func digit(_ byte: UInt8) -> UInt8? {
            switch byte { case 48...57:return byte-48; case 65...70:return byte-55; case 97...102:return byte-87; default:return nil }
        }
        for index in stride(from:0,to:bytes.count,by:2) {
            guard let a=digit(bytes[index]),let b=digit(bytes[index+1]) else { throw CanvasCloudError.remote }
            audio.append(a * 16 + b)
        }
        return Result(data:audio,fileExtension:"mp3",metadata:.init(provider:.miniMax,taskID:nil))
    }
    public func uploadImage(_ url: URL, key: String) async throws -> String {
        try Task.checkCancellation()
        let image = try Self.referenceImage(url)
        let ext = image.mime == "image/png" ? "png" : "jpg"
        let boundary = "ClipSlots\(UUID().uuidString)"
        var request = try request(.tripo,path:"files",key:key)
        request.httpMethod = "POST"; request.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type")
        var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"input.\(ext)\"\r\nContent-Type: \(image.mime)\r\n\r\n".utf8)
        data.append(image.data); data.append(Data("\r\n--\(boundary)--\r\n".utf8)); request.httpBody = data
        let object = try await json(request)
        guard let output=object["data"] as? [String:Any],let token=output["file_token"] as? String,
              validID(token) else { throw CanvasCloudError.remote }; return token
    }
    public func submit(_ config: CanvasCloudConfiguration, key: String, imageToken: String? = nil,
                       rigCheck: CanvasCloudRigCheck? = nil,
                       originalTask: CanvasCloudTask? = nil,
                       checkpoint: ((CanvasCloudRigCheck) async throws -> Void)? = nil,
                       beforeSubmission: (() async throws -> Void)? = nil) async throws -> CanvasCloudTask {
        var validation = config
        if let originalTask {
            guard originalTask.provider == .tripo, originalTask.mode == .rig, config.provider == .tripo,
                  config.mode == .rig, originalTask.id == nil, originalTask.state != .failed,
                  originalTask.submissionStarted == false, originalTask.model?.isEmpty == false,
                  (originalTask.model?.utf8.count ?? 0) <= 256,
                  originalTask.service?.submissionPath == "animations/rig" else {
                throw CanvasCloudError.invalid("原骨骼任务提交身份无效")
            }
            validation.model = "" // A saved model must not be replaced by today's catalog default.
        }
        if let error=validation.validationError { throw CanvasCloudError.invalid(error) }
        guard config.task == nil else { throw CanvasCloudError.invalid("已有任务，请先继续查询或明确新建任务") }
        if config.provider == .worldLabs {
            let object = try await submissionJSON(request(.worldLabs,path:"worlds:generate",key:key,body:[
                "display_name":"ClipSlots world","model":config.model.isEmpty ? "marble-1.1" : config.model,
                "world_prompt":["type":"text","text_prompt":config.prompt],
                "permission":["public":false,"allow_id_access":false,"allowed_readers":[],"allowed_writers":[]]]),
                receipt: { $0["operation_id"] as? String })
            guard let id=object["operation_id"] as? String,validID(id) else { throw CanvasCloudError.unknownSubmission }
            return .init(configuration:config,id:id,state:.pending)
        }
        guard config.provider == .tripo else { throw CanvasCloudError.invalid("请选择 3D 服务") }
        var body: [String:Any], route: String
        var completedCheck: CanvasCloudRigCheck?
        switch config.mode {
        case .text3D,.image3D:
            body=["model":config.model.isEmpty ? "v3.1-20260211" : config.model,"texture":true,"pbr":true,
                  "texture_quality":config.detailedTexture ? "detailed" : "standard","face_limit":80000]
            if config.mode == .text3D { route="generation/text-to-model";body["prompt"]=config.prompt }
            else { guard let imageToken,validID(imageToken) else { throw CanvasCloudError.invalid("参考图尚未上传") }
                route="generation/image-to-model";body["input"]=imageToken }
        case .rig:
            guard let source=config.sourceTaskID,validID(source) else { throw CanvasCloudError.invalid("模型任务 ID 无效") }
            let checked = try await prepareRig(source: source, key: key, previous: rigCheck,
                baseURL: originalTask?.service?.baseURL, checkpoint: checkpoint)
            completedCheck = checked
            guard checked.riggable == true, let rigType = checked.rigType, ["biped","quadruped"].contains(rigType) else {
                throw CanvasCloudError.invalid("该模型尚不能自动绑定支持的骨骼类型")
            }
            route="animations/rig";body=["input":source,"model":originalTask?.model ?? config.effectiveModel,
                "rig_type":rigType,"spec":"mixamo","out_format":"glb"]
        case .animate:
            guard let source=config.sourceTaskID,validID(source) else { throw CanvasCloudError.invalid("骨骼任务 ID 无效") }
            route="animations/retarget";body=["input":source,"animation":"preset:\(config.animation)",
                "out_format":"glb","animate_in_place":config.inPlace]
        default: throw CanvasCloudError.invalid("Tripo 生成类型无效")
        }
        let submission = try request(.tripo,path:route,key:key,body:body,service:originalTask?.service)
        if Task.isCancelled { throw CanvasCloudError.notSubmitted }
        try await beforeSubmission?()
        let object=try await submissionJSON(submission,
            receipt: { ($0["data"] as? [String: Any])?["task_id"] as? String })
        guard let output=object["data"] as? [String:Any] else { throw CanvasCloudError.unknownSubmission }
        var task = CanvasCloudTask(configuration:config,id:try taskID(output),state:.pending)
        if let originalTask { task.model = originalTask.model; task.service = originalTask.service }
        task.rigCheck = completedCheck
        if completedCheck != nil { task.submissionStarted = true }
        return task
    }
    private func prepareRig(source: String, key: String, previous: CanvasCloudRigCheck?, baseURL: String?,
                            checkpoint: ((CanvasCloudRigCheck) async throws -> Void)?) async throws -> CanvasCloudRigCheck {
        var check = previous ?? .init(sourceTaskID: source,
            service: .init(baseURL: baseURL ?? "https://openapi.tripo3d.com/v3/",
                           submissionPath: "animations/rig-check", statusPrefix: "tasks/"))
        guard check.sourceTaskID == source, check.service.submissionPath == "animations/rig-check",
              check.service.statusPrefix == "tasks/" else { throw CanvasCloudError.invalid("骨骼检查回执身份不一致") }
        // Validate the saved origin even when the saved output is already complete.
        _ = try request(.tripo, path: check.service.submissionPath, key: key, service: check.service)
        if previous == nil {
            try Task.checkCancellation()
            try await checkpoint?(check)
            let object = try await submissionJSON(
                request(.tripo, path: check.service.submissionPath, key: key, body: ["input": source], service: check.service),
                receipt: { object in
                    guard let data = object["data"] as? [String: Any] else { return nil }
                    if let id = data["task_id"] as? String { return id }
                    return data["riggable"] is Bool ? "synchronous-rig-check" : nil
                })
            guard let output = object["data"] as? [String: Any] else { throw CanvasCloudError.unknownSubmission }
            if let id = output["task_id"] as? String {
                guard validID(id) else { throw CanvasCloudError.unknownSubmission }
                check.id = id; check.state = .pending
            } else {
                check.state = .complete; check.riggable = output["riggable"] as? Bool
                check.rigType = output["rig_type"] as? String
            }
            // Local cancellation cannot bypass this durable receipt handoff.
            try await checkpoint?(check)
        } else if check.state == .submitting {
            throw CanvasCloudError.unknownSubmission
        }
        if check.state == .pending {
            guard let id = check.id, validID(id) else { throw CanvasCloudError.invalid("骨骼检查任务 ID 无效") }
            for _ in 0..<150 {
                try Task.checkCancellation()
                if let output = try await tripoOutput(id, key: key, service: check.service) {
                    guard let riggable = output["riggable"] as? Bool else { throw CanvasCloudError.remote }
                    check.state = .complete; check.riggable = riggable; check.rigType = output["rig_type"] as? String
                    try await checkpoint?(check)
                    break
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard check.state == .complete else { throw CanvasCloudError.expired }
        }
        return check
    }
    private func tripoOutput(_ id: String,key: String, service: CanvasCloudServiceIdentity? = nil) async throws -> [String:Any]? {
        guard validID(id) else { throw CanvasCloudError.invalid("任务 ID 无效") }
        guard service?.statusPrefix == nil || service?.statusPrefix == "tasks/" else {
            throw CanvasCloudError.invalid("保存的任务查询路由无效")
        }
        let object=try await json(request(.tripo,path:"tasks/\(id)",key:key,service:service))
        guard let data=object["data"] as? [String:Any],try taskID(data) == id,
              let status=data["status"] as? String else { throw CanvasCloudError.remote }
        switch status {
        case "queued","running":return nil
        case "success":guard let output=data["output"] as? [String:Any] else { throw CanvasCloudError.remote };return output
        default:throw CanvasCloudError.remote
        }
    }
    public func status(_ task: CanvasCloudTask, quality: String = "100k", key: String) async throws -> Status {
        guard let id=task.id,validID(id),task.state == .pending || task.state == .complete else { throw CanvasCloudError.invalid("无可恢复的云端任务 ID") }
        var metadata=CanvasCloudResourceMetadata(provider:task.provider,taskID:id)
        if task.provider == .tripo {
            guard let output=try await tripoOutput(id,key:key,service:task.service) else { return Status(done:false,url:nil,metadata:metadata,rigType:nil) }
            guard let string=output["model_url"] as? String,let url=URL(string:string),Self.allowedDownloadURL(url) else { throw CanvasCloudError.remote }
            return Status(done:true,url:url,metadata:metadata,rigType:nil)
        }
        guard task.provider == .worldLabs,["100k","500k"].contains(quality) else { throw CanvasCloudError.invalid("世界任务无效") }
        guard task.service?.statusPrefix == nil || task.service?.statusPrefix == "operations/" else {
            throw CanvasCloudError.invalid("保存的任务查询路由无效")
        }
        let operation=try await json(request(.worldLabs,path:"operations/\(id)",key:key,service:task.service))
        guard operation["operation_id"] as? String == id,let done=operation["done"] as? Bool else { throw CanvasCloudError.remote }
        guard done else { return Status(done:false,url:nil,metadata:metadata,rigType:nil) }
        if let error=operation["error"],!(error is NSNull) { throw CanvasCloudError.remote }
        guard var world=operation["response"] as? [String:Any] else { throw CanvasCloudError.remote }
        if world["assets"] == nil,let worldID=world["world_id"] as? String,validID(worldID) {
            world=try await json(request(.worldLabs,path:"worlds/\(worldID)",key:key,service:task.service))
            guard world["world_id"] as? String == worldID else { throw CanvasCloudError.remote }
        }
        guard let assets=world["assets"] as? [String:Any],let splats=assets["splats"] as? [String:Any],
              let urls=splats["spz_urls"] as? [String:String],let string=urls[quality],
              let url=URL(string:string),Self.allowedDownloadURL(url) else { throw CanvasCloudError.remote }
        if let semantics=assets["semantics_metadata"] as? [String:Any] {
            metadata.metricScale=(semantics["metric_scale_factor"] as? NSNumber)?.doubleValue ?? 1
            metadata.groundOffset=(semantics["ground_plane_offset"] as? NSNumber)?.doubleValue ?? 0
        }
        guard metadata.metricScale.isFinite,(0.00001...100000).contains(metadata.metricScale),
              metadata.groundOffset.isFinite,abs(metadata.groundOffset)<=100000 else { throw CanvasCloudError.remote }
        metadata.marbleCoordinates=true
        return Status(done:true,url:url,metadata:metadata,rigType:nil)
    }
    public func download(_ status: Status) async throws -> Result {
        guard status.done,let url=status.url,Self.allowedDownloadURL(url) else { throw CanvasCloudError.remote }
        // Deliberately construct a fresh request with no provider headers.
        let request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:300)
        let (data,response)=try await http.send(request,limit:150 * 1024 * 1024);try checked(response)
        let world=status.metadata.provider == .worldLabs
        guard data.count>=16,world ? (data[0]==0x1f && data[1]==0x8b)
            : Array(data.prefix(4)) == [0x67,0x6c,0x54,0x46] else { throw CanvasCloudError.invalid("云端返回的文件不是预期的 GLB / SPZ") }
        return Result(data:data,fileExtension:world ? "spz" : "glb",metadata:status.metadata)
    }
}
