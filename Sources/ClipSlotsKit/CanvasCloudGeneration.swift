import Foundation

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
    public init() {}
    public var supportedModels:[String] {
        switch provider {
        case .elevenLabs:return mode == .sound ? ["eleven_text_to_sound_v2","eleven_text_to_sound_v3"] : ["music_v1","music_v2","music_v2_5"]
        case .miniMax:return ["music-2.6","music-3.0"]
        case .tripo:return mode == .rig ? ["v3.0-20260909"] : mode == .animate ? [] : ["v3.1-20260211"]
        case .worldLabs:return ["marble-1.1","marble-1.1-plus"]
        }
    }
    public var validationError: String? {
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
            if inputAttachmentID == nil { return "请先选择参考图片" }
        case (.tripo, .rig), (.tripo, .animate):
            if sourceTaskID == nil { return "请先选择已完成的 Tripo 模型任务" }
            if mode == .animate && !["idle","walk","run","jump"].contains(animation) { return "请选择支持的动作" }
        case (.worldLabs, .world):
            if prompt.isEmpty || prompt.count > 10000 || !["100k","500k"].contains(worldQuality) { return "世界提示词或质量档位无效" }
        default: return "此服务不支持当前生成类型"
        }
        if let task, task.provider != provider || task.mode != mode { return "任务与当前服务不匹配，请新建任务" }
        return nil
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
    public init(provider: CanvasCloudConfiguration.Provider, mode: CanvasCloudConfiguration.Mode,
                id: String? = nil, state: State = .submitting) {
        self.provider = provider; self.mode = mode; self.id = id; self.state = state
    }
}

public struct CanvasCloudResourceMetadata: Codable, Equatable {
    public var provider: CanvasCloudConfiguration.Provider
    public var taskID: String?
    public var metricScale: Double = 1
    public var groundOffset: Double = 0
    public var marbleCoordinates = false
    public init(provider: CanvasCloudConfiguration.Provider, taskID: String?) {
        self.provider = provider; self.taskID = taskID
    }
}

public enum CanvasCloudError: LocalizedError {
    case invalid(String), unauthorized, balance, remote, unknownSubmission, expired, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        case .unauthorized: return "云服务密钥无效或权限不足"
        case .balance: return "云服务额度不足"
        case .remote: return "云服务返回失败，请到服务控制台查看任务"
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
    public let configuration: URLSessionConfiguration
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }
    public func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let transfer = Transfer(configuration: configuration, request: request, limit: limit)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { transfer.start($0) }
        }, onCancel: { transfer.cancel() })
    }
    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let configuration: URLSessionConfiguration, request: URLRequest, limit: Int
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var bytes = Data()
        private var response: HTTPURLResponse?
        private var finished = false
        private var stopped = false
        init(configuration: URLSessionConfiguration, request: URLRequest, limit: Int) {
            self.configuration = configuration; self.request = request; self.limit = limit
        }
        func start(_ continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
            lock.lock()
            if stopped { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session; let task = session.dataTask(with: request); self.task = task
            lock.unlock(); task.resume()
        }
        func cancel() {
            lock.lock(); stopped = true; let task = task; lock.unlock()
            task?.cancel()
        }
        func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true; let continuation = continuation; self.continuation = nil
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
                dataTask.cancel(); finish(.failure(CanvasCloudError.invalid("云端响应超过大小限制"))); return
            }
            bytes.append(data)
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
            if let error { finish(.failure(error)) }
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
                         key: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              key.utf8.count <= 4096, !key.contains("\r"), !key.contains("\n") else { throw CanvasCloudError.unauthorized }
        let base: String, header: String, value: String
        switch provider {
        case .elevenLabs: base = "https://api.elevenlabs.io/v1/"; header = "xi-api-key"; value = key
        case .miniMax: base = "https://api.minimax.io/v1/"; header = "Authorization"; value = "Bearer \(key)"
        case .tripo: base = "https://openapi.tripo3d.com/v3/"; header = "Authorization"; value = "Bearer \(key)"
        case .worldLabs: base = "https://api.worldlabs.ai/marble/v1/"; header = "WLT-Api-Key"; value = key
        }
        guard let url = URL(string: base + path) else { throw CanvasCloudError.remote }
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
    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await http.send(request, limit: 4 * 1024 * 1024); try checked(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CanvasCloudError.remote }
        if let code = object["code"] as? Int, code != 0 {
            if code == 2010 { throw CanvasCloudError.balance }; throw CanvasCloudError.remote
        }
        return object
    }
    private func taskID(_ object: [String: Any]) throws -> String {
        guard let id = object["task_id"] as? String, validID(id) else { throw CanvasCloudError.remote }; return id
    }
    private func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 256 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }
    }
    public func audio(_ config: CanvasCloudConfiguration, key: String) async throws -> Result {
        if let error = config.validationError { throw CanvasCloudError.invalid(error) }
        guard config.provider == .elevenLabs || config.provider == .miniMax else { throw CanvasCloudError.invalid("请选择音频服务") }
        if config.provider == .elevenLabs {
            let sound = config.mode == .sound
            let body: [String: Any] = sound
                ? ["text":config.prompt,"duration_seconds":config.duration,"loop":false,"prompt_influence":0.3,
                   "model_id":config.model.isEmpty ? "eleven_text_to_sound_v2" : config.model]
                : ["prompt":config.prompt,"music_length_ms":Int(config.duration * 1000),"force_instrumental":config.instrumental,
                   "model_id":config.model.isEmpty ? "music_v1" : config.model]
            let route = sound ? "sound-generation?output_format=mp3_44100_128" : "music?output_format=mp3_44100_128"
            let (data,response) = try await http.send(request(.elevenLabs, path: route, key: key, body: body), limit: 64 * 1024 * 1024)
            try checked(response)
            guard data.count > 16, !(response.value(forHTTPHeaderField:"Content-Type") ?? "").contains("json") else { throw CanvasCloudError.remote }
            return Result(data: data, fileExtension: "mp3",
                metadata: .init(provider: .elevenLabs, taskID: response.value(forHTTPHeaderField:"song-id")))
        }
        let body: [String: Any] = ["model":config.model.isEmpty ? "music-2.6" : config.model,
            "prompt":config.prompt,"lyrics":config.lyrics,"is_instrumental":config.instrumental,
            "stream":false,"output_format":"hex",
            "audio_setting":["sample_rate":44100,"bitrate":128000,"format":"mp3"]]
        let (data,response) = try await http.send(request(.miniMax,path:"music_generation",key:key,body:body),limit:128 * 1024 * 1024)
        try checked(response)
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let base = object["base_resp"] as? [String:Any], let code = base["status_code"] as? Int else { throw CanvasCloudError.remote }
        if code == 1004 || code == 2049 { throw CanvasCloudError.unauthorized }
        if code == 1008 { throw CanvasCloudError.balance }
        guard code == 0, let output = object["data"] as? [String:Any], output["status"] as? Int == 2,
              let hex = output["audio"] as? String, hex.count > 32, hex.count.isMultiple(of:2),
              hex.utf8.count <= 128 * 1024 * 1024 else { throw CanvasCloudError.remote }
        let bytes = Array(hex.utf8); var audio = Data(); audio.reserveCapacity(bytes.count / 2)
        func digit(_ byte: UInt8) -> UInt8? {
            switch byte { case 48...57:return byte-48; case 65...70:return byte-55; case 97...102:return byte-87; default:return nil }
        }
        for index in stride(from:0,to:bytes.count,by:2) {
            if index % 8192 == 0 { try Task.checkCancellation() }
            guard let a=digit(bytes[index]),let b=digit(bytes[index+1]) else { throw CanvasCloudError.remote }
            audio.append(a * 16 + b)
        }
        return Result(data:audio,fileExtension:"mp3",metadata:.init(provider:.miniMax,taskID:nil))
    }
    public func uploadImage(_ url: URL, key: String) async throws -> String {
        let ext = url.pathExtension.lowercased()
        guard ["png","jpg","jpeg"].contains(ext),
              let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize,
              size > 0, size <= 20 * 1024 * 1024 else { throw CanvasCloudError.invalid("参考图需为 PNG / JPEG，最多 20 MB") }
        let boundary = "ClipSlots\(UUID().uuidString)"
        var request = try request(.tripo,path:"files",key:key)
        request.httpMethod = "POST"; request.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type")
        var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"input.\(ext)\"\r\nContent-Type: image/\(ext == "png" ? "png" : "jpeg")\r\n\r\n".utf8)
        data.append(try Data(contentsOf:url)); data.append(Data("\r\n--\(boundary)--\r\n".utf8)); request.httpBody = data
        let object = try await json(request)
        guard let output=object["data"] as? [String:Any],let token=output["file_token"] as? String,
              validID(token) else { throw CanvasCloudError.remote }; return token
    }
    public func submit(_ config: CanvasCloudConfiguration, key: String, imageToken: String? = nil) async throws -> CanvasCloudTask {
        if let error=config.validationError { throw CanvasCloudError.invalid(error) }
        guard config.task == nil else { throw CanvasCloudError.invalid("已有任务，请先继续查询或明确新建任务") }
        if config.provider == .worldLabs {
            let object = try await json(request(.worldLabs,path:"worlds:generate",key:key,body:[
                "display_name":"ClipSlots world","model":config.model.isEmpty ? "marble-1.1" : config.model,
                "world_prompt":["type":"text","text_prompt":config.prompt],
                "permission":["public":false,"allow_id_access":false,"allowed_readers":[],"allowed_writers":[]]]))
            guard let id=object["operation_id"] as? String,validID(id) else { throw CanvasCloudError.unknownSubmission }
            return .init(provider:.worldLabs,mode:.world,id:id,state:.pending)
        }
        guard config.provider == .tripo else { throw CanvasCloudError.invalid("请选择 3D 服务") }
        var body: [String:Any], route: String
        switch config.mode {
        case .text3D,.image3D:
            body=["model":config.model.isEmpty ? "v3.1-20260211" : config.model,"texture":true,"pbr":true,
                  "texture_quality":config.detailedTexture ? "detailed" : "standard","face_limit":80000]
            if config.mode == .text3D { route="generation/text-to-model";body["prompt"]=config.prompt }
            else { guard let imageToken,validID(imageToken) else { throw CanvasCloudError.invalid("参考图尚未上传") }
                route="generation/image-to-model";body["input"]=imageToken }
        case .rig:
            guard let source=config.sourceTaskID,validID(source) else { throw CanvasCloudError.invalid("模型任务 ID 无效") }
            let check=try await json(request(.tripo,path:"animations/rig-check",key:key,body:["input":source]))
            guard let checked=check["data"] as? [String:Any] else { throw CanvasCloudError.remote }
            var rigType = checked["rig_type"] as? String
            var riggable = checked["riggable"] as? Bool
            if let id=checked["task_id"] as? String {
                guard validID(id) else { throw CanvasCloudError.remote }
                for _ in 0..<150 {
                    try Task.checkCancellation()
                    let output=try await tripoOutput(id,key:key)
                    if let output { riggable=output["riggable"] as? Bool;rigType=output["rig_type"] as? String;break }
                    try await Task.sleep(nanoseconds:2_000_000_000)
                }
            }
            guard riggable == true,let rigType,["biped","quadruped"].contains(rigType) else {
                throw CanvasCloudError.invalid("该模型尚不能自动绑定支持的骨骼类型")
            }
            route="animations/rig";body=["input":source,"model":config.model.isEmpty ? "v3.0-20260909" : config.model,"rig_type":rigType,"spec":"mixamo","out_format":"glb"]
        case .animate:
            guard let source=config.sourceTaskID,validID(source) else { throw CanvasCloudError.invalid("骨骼任务 ID 无效") }
            route="animations/retarget";body=["input":source,"animation":"preset:\(config.animation)",
                "out_format":"glb","animate_in_place":config.inPlace]
        default: throw CanvasCloudError.invalid("Tripo 生成类型无效")
        }
        let object=try await json(request(.tripo,path:route,key:key,body:body))
        guard let output=object["data"] as? [String:Any] else { throw CanvasCloudError.unknownSubmission }
        return .init(provider:.tripo,mode:config.mode,id:try taskID(output),state:.pending)
    }
    private func tripoOutput(_ id: String,key: String) async throws -> [String:Any]? {
        guard validID(id) else { throw CanvasCloudError.invalid("任务 ID 无效") }
        let object=try await json(request(.tripo,path:"tasks/\(id)",key:key))
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
            guard let output=try await tripoOutput(id,key:key) else { return Status(done:false,url:nil,metadata:metadata,rigType:nil) }
            guard let string=output["model_url"] as? String,let url=URL(string:string),Self.allowedDownloadURL(url) else { throw CanvasCloudError.remote }
            return Status(done:true,url:url,metadata:metadata,rigType:nil)
        }
        guard task.provider == .worldLabs,["100k","500k"].contains(quality) else { throw CanvasCloudError.invalid("世界任务无效") }
        let operation=try await json(request(.worldLabs,path:"operations/\(id)",key:key))
        guard operation["operation_id"] as? String == id,let done=operation["done"] as? Bool else { throw CanvasCloudError.remote }
        guard done else { return Status(done:false,url:nil,metadata:metadata,rigType:nil) }
        if let error=operation["error"],!(error is NSNull) { throw CanvasCloudError.remote }
        guard var world=operation["response"] as? [String:Any] else { throw CanvasCloudError.remote }
        if world["assets"] == nil,let worldID=world["world_id"] as? String,validID(worldID) {
            world=try await json(request(.worldLabs,path:"worlds/\(worldID)",key:key))
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
