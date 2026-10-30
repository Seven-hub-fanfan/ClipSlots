import Foundation
import AppKit
import Darwin
#if !CLIPSLOTS_STAGED_CLOUD
@testable import ClipSlotsKit
#endif

private final class CloudContractProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((CloudContractProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        handler?(self)
    }
    override func stopLoading() {}
    static func install(_ callback: @escaping (CloudContractProtocol) -> Void) {
        lock.lock(); handler = callback; lock.unlock()
    }
    func respond(_ data: Data, status: Int = 200, headers: [String: String] = [:], error: Error? = nil, finish: Bool = true) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let error {
            // Delivery must occur before the simulated broken tail; failing
            // during response negotiation does not establish an observed ID.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                self.client?.urlProtocol(self, didLoad: data)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                    self.client?.urlProtocol(self, didFailWithError: error)
                }
            }
        } else {
            client?.urlProtocol(self, didLoad: data)
            if finish { client?.urlProtocolDidFinishLoading(self) }
        }
    }
}

private final class CloudRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var request: CloudContractProtocol?
    private var waiter: CheckedContinuation<CloudContractProtocol, Never>?
    func received(_ request: CloudContractProtocol) {
        lock.lock(); let waiter = waiter; self.waiter = nil; self.request = request; lock.unlock()
        waiter?.resume(returning: request)
    }
    func next() async -> CloudContractProtocol {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let request { lock.unlock(); continuation.resume(returning: request) }
            else { waiter = continuation; lock.unlock() }
        }
    }
}

private final class CloudBrokenSocket: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var connection: Int32 = -1
    init(body: Data) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        guard descriptor >= 0 else { throw URLError(.cannotConnectToHost) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0, Darwin.listen(descriptor, 1) == 0 else { throw URLError(.cannotConnectToHost) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global().async {
            let socket = Darwin.accept(self.listener, nil, nil)
            guard socket >= 0 else { return }
            self.lock.lock(); self.connection = socket; self.lock.unlock()
            var buffer = [UInt8](repeating: 0, count: 8192)
            guard Darwin.read(socket, &buffer, buffer.count) > 0 else { self.closeConnection(); return }
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count + 100)\r\n\r\n".utf8)
            response.append(body)
            _ = response.withUnsafeBytes { Darwin.write(socket, $0.baseAddress!, $0.count) }
            // The observer closes this socket only after URLSession has delivered
            // the valid receipt bytes. Thus acceptance evidence is explicit.
        }
    }
    func closeConnection() {
        lock.lock(); let socket = connection; connection = -1; lock.unlock()
        if socket >= 0 { _ = Darwin.shutdown(socket, SHUT_RDWR); Darwin.close(socket) }
    }
    deinit { closeConnection(); Darwin.close(listener) }
}

@main
struct CloudContractsMain {
    static var passed = 0
    static var failures: [String] = []
    static func check(_ value: Bool, _ name: String) {
        if value { passed += 1; print("PASS: \(name)") }
        else { failures.append(name); print("FAIL: \(name)") }
        fflush(stdout)
    }
    static func rejects(_ name: String, _ body: () throws -> Void) {
        do { try body(); check(false, name) }
        catch { check(true, name) }
    }
    static func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    static func image(_ format: NSBitmapImageRep.FileType) throws -> Data {
        let context = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        return bitmap.representation(using: format, properties: [:])!
    }
    static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    static func allModes(_ client: CanvasCloudClient, root: URL) async throws {
        for mode in [CanvasCloudConfiguration.Mode.music, .sound] {
            var config = CanvasCloudConfiguration(); config.mode = mode; config.prompt = "fixture"; config.duration = 3
            for model in config.supportedModels {
                config.model = model
                CloudContractProtocol.install { fixture in
                    let request = fixture.request, object = body(request)
                    check(request.url?.path == (mode == .music ? "/v1/music" : "/v1/sound-generation") &&
                          request.url?.query == "output_format=mp3_44100_128", "ElevenLabs \(model) route")
                    check(object["model_id"] as? String == model &&
                          (mode == .music ? object["music_length_ms"] as? Int == 3000 :
                            object["duration_seconds"] as? Double == 3), "ElevenLabs \(model) body")
                    fixture.respond(Data(repeating: 42, count: 64), headers: ["Content-Type": "audio/mpeg"])
                }
                _ = try await client.audio(config, key: "fixture-key")
            }
        }
        var config = CanvasCloudConfiguration(); config.provider = .miniMax; config.prompt = "fixture"
        for model in config.supportedModels {
            config.model = model
            CloudContractProtocol.install { fixture in
                let object = body(fixture.request)
                check(object["model"] as? String == model && object["stream"] as? Bool == false &&
                      object["output_format"] as? String == "hex", "MiniMax \(model) body")
                fixture.respond(json(["base_resp": ["status_code": 0], "data": ["status": 2, "audio": String(repeating: "aB", count: 32)]]))
            }
            check(try await client.audio(config, key: "fixture-key").data == Data(repeating: 0xab, count: 32),
                  "MiniMax \(model) exact mixed-case hex")
        }
        config = .init(); config.provider = .tripo; config.mode = .image3D; config.inputAttachmentID = "image"
        let reference = root.appendingPathComponent("upload-mislabeled.jpg"); try image(.png).write(to: reference)
        CloudContractProtocol.install { fixture in
            check(fixture.request.url?.path == "/v3/files", "image reference upload route")
            let stream = fixture.request.httpBodyStream
            let data: Data
            if let bytes = fixture.request.httpBody { data = bytes }
            else if let stream {
                stream.open(); var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
                }
                stream.close(); data = bytes
            } else { data = Data() }
            let text = String(decoding: data, as: UTF8.self)
            check(text.contains("filename=\"input.png\"") && text.contains("Content-Type: image/png"),
                  "upload uses verified encoding MIME and filename")
            fixture.respond(json(["code": 0, "data": ["file_token": "uploaded-image"]]))
        }
        let token = try await client.uploadImage(reference, key: "fixture-key")
        CloudContractProtocol.install { fixture in
            let object = body(fixture.request)
            check(fixture.request.url?.path == "/v3/generation/image-to-model" && object["input"] as? String == token &&
                  object["pbr"] as? Bool == true, "Tripo image reference token and route")
            fixture.respond(json(["code": 0, "data": ["task_id": "image-task"]]))
        }
        check(try await client.submit(config, key: "fixture-key", imageToken: token).id == "image-task", "image task receipt")
        config.mode = .animate; config.sourceTaskID = "rigged-source"; config.inputAttachmentID = nil
        for action in ["idle", "walk", "run", "jump"] {
            config.animation = action; config.inPlace = false
            CloudContractProtocol.install { fixture in
                let object = body(fixture.request)
                check(fixture.request.url?.path == "/v3/animations/retarget" &&
                      object["input"] as? String == "rigged-source" &&
                      object["animation"] as? String == "preset:\(action)" &&
                      object["animate_in_place"] as? Bool == false && object["model"] == nil, "Tripo \(action) retarget contract")
                fixture.respond(json(["code": 0, "data": ["task_id": "action-\(action)"]]))
            }
            _ = try await client.submit(config, key: "fixture-key")
        }
        config = .init(); config.provider = .worldLabs; config.mode = .world; config.prompt = "fixture"
        for model in config.supportedModels {
            config.model = model
            CloudContractProtocol.install { fixture in
                let object = body(fixture.request), permission = object["permission"] as? [String: Any]
                check(fixture.request.url?.path == "/marble/v1/worlds:generate" &&
                      object["model"] as? String == model && permission?["public"] as? Bool == false &&
                      permission?["allow_id_access"] as? Bool == false, "World Labs \(model) original private contract")
                fixture.respond(json(["operation_id": "world-operation"]))
            }
            _ = try await client.submit(config, key: "fixture-key")
        }
        for provider in [CanvasCloudConfiguration.Provider.tripo, .worldLabs] {
            var task = CanvasCloudTask(provider: provider, mode: provider == .tripo ? .text3D : .world, id: "old-id", state: .pending)
            task.model = "original-model-no-longer-default"
            task.service = .init(baseURL: provider == .tripo ? "https://openapi.tripo3d.com/v2/" : "https://api.worldlabs.ai/marble/v0/",
                                 submissionPath: "original-submission", statusPrefix: provider == .tripo ? "tasks/" : "operations/")
            let expected = provider == .tripo ? "/v2/tasks/old-id" : "/marble/v0/operations/old-id"
            CloudContractProtocol.install { fixture in
                check(fixture.request.url?.path == expected && fixture.request.httpMethod == "GET", "\(provider) query pins original API version")
                fixture.respond(provider == .tripo ? json(["code": 0, "data": ["task_id": "old-id", "status": "running"]]) :
                    json(["operation_id": "old-id", "done": false]))
            }
            check(try await !client.status(task, key: "fixture-key").done, "\(provider) old model does not validate against new defaults")
            task.service = .init(baseURL: "https://attacker.invalid/v1/", submissionPath: "submit", statusPrefix: nil)
            do { _ = try await client.status(task, key: "fixture-key"); check(false, "foreign service rejected") }
            catch CanvasCloudError.invalid { check(true, "foreign service rejected before auth I/O") }
        }
        let worldTask = CanvasCloudTask(provider: .worldLabs, mode: .world, id: "world-operation", state: .pending)
        let packedWorld = Data([0x1f, 0x8b] + [UInt8](repeating: 1, count: 14))
        for quality in ["100k", "500k"] {
            CloudContractProtocol.install { fixture in
                if fixture.request.url?.path.hasPrefix("/marble/v1/operations/") == true {
                    fixture.respond(json(["operation_id": "world-operation", "done": true, "response": ["world_id": "world-id"]]))
                } else if fixture.request.url?.host == "cdn.example.com" {
                    check(fixture.request.value(forHTTPHeaderField: "WLT-Api-Key") == nil &&
                          fixture.request.value(forHTTPHeaderField: "Authorization") == nil, "World \(quality) CDN download strips credentials")
                    fixture.respond(packedWorld)
                } else {
                    check(fixture.request.url?.path == "/marble/v1/worlds/world-id", "World \(quality) follows original world ID")
                    fixture.respond(json(["world_id": "world-id", "assets": [
                        "splats": ["spz_urls": ["100k": "https://cdn.example.com/100k.spz", "500k": "https://cdn.example.com/500k.spz"]],
                        "semantics_metadata": ["metric_scale_factor": 2, "ground_plane_offset": 0.5]]]))
                }
            }
            let status = try await client.status(worldTask, quality: quality, key: "fixture-key")
            check(status.url?.path == "/\(quality).spz" && status.metadata.taskID == worldTask.id &&
                  status.metadata.marbleCoordinates && status.metadata.metricScale == 2 && status.metadata.groundOffset == 0.5,
                  "World \(quality) selected artifact and processing metadata preserved")
            check(try await client.download(status).data == packedWorld, "World \(quality) download preserves protocol bytes")
        }
        CloudContractProtocol.install { $0.respond(json(["operation_id": "wrong-id", "done": false])) }
        do { _ = try await client.status(worldTask, key: "fixture-key"); check(false, "world ID mismatch") }
        catch { check(true, "world operation ID mismatch is rejected") }
        let tripoTask = CanvasCloudTask(provider: .tripo, mode: .text3D, id: "model-id", state: .pending)
        CloudContractProtocol.install { $0.respond(json(["code": 0, "data": ["task_id": "wrong-id", "status": "running"]])) }
        do { _ = try await client.status(tripoTask, key: "fixture-key"); check(false, "Tripo ID mismatch") }
        catch { check(true, "Tripo status ID mismatch is rejected") }
        for address in ["http://cdn.example.com/a", "https://127.0.0.1/a", "https://user:secret@cdn.example.com/a"] {
            CloudContractProtocol.install { $0.respond(json(["code": 0, "data": ["task_id": "model-id", "status": "success",
                "output": ["model_url": address]]])) }
            do { _ = try await client.status(tripoTask, key: "fixture-key"); check(false, "unsafe result URL") }
            catch { check(true, "Tripo rejects unsafe result URL before download") }
        }
        var invalids: [CanvasCloudConfiguration] = []
        for (provider, mode) in [(CanvasCloudConfiguration.Provider.elevenLabs, CanvasCloudConfiguration.Mode.music),
                                  (.elevenLabs, .sound), (.miniMax, .music), (.tripo, .text3D), (.worldLabs, .world)] {
            var value = CanvasCloudConfiguration(); value.provider = provider; value.mode = mode
            value.prompt = String(repeating: "a", count: provider == .miniMax ? 2001 : provider == .worldLabs ? 10001 :
                provider == .tripo ? 1025 : 4101); invalids.append(value)
            value.prompt = "fixture"; value.model = "unsupported"; invalids.append(value)
            value.model = ""; value.duration = .nan; invalids.append(value)
        }
        for mode in [CanvasCloudConfiguration.Mode.image3D, .rig, .animate] {
            var value = CanvasCloudConfiguration(); value.provider = .tripo; value.mode = mode; invalids.append(value)
        }
        var requests = 0
        CloudContractProtocol.install { fixture in requests += 1; fixture.respond(Data(), status: 400) }
        for (index, value) in invalids.enumerated() {
            do {
                if value.provider == .elevenLabs || value.provider == .miniMax { _ = try await client.audio(value, key: "fixture-key") }
                else { _ = try await client.submit(value, key: "fixture-key") }
                check(false, "invalid configuration \(index)")
            } catch CanvasCloudError.invalid { check(true, "invalid configuration \(index) rejected before I/O") }
        }
        check(requests == 0, "all modes reject invalid required inputs and budgets before I/O")
        var large = CanvasCloudConfiguration(); large.prompt = "x" + String(repeating: "\u{301}", count: 40_000)
        check(large.prompt.count == 1 && large.validationError != nil, "byte budget rejects oversized single grapheme")
        for provider in [CanvasCloudConfiguration.Provider.elevenLabs, .miniMax] {
            var value = CanvasCloudConfiguration(); value.provider = provider; value.prompt = "fixture"
            for (status, expected) in [(401, "auth"), (402, "balance"), (422, "reject"), (503, "unknown")] {
                CloudContractProtocol.install { $0.respond(Data(), status: status) }
                do { _ = try await client.audio(value, key: "fixture-key"); check(false, "\(provider) HTTP \(status)") }
                catch let error as CanvasCloudError {
                    let actual: String
                    switch error {
                    case .unauthorized: actual = "auth"
                    case .balance: actual = "balance"
                    case .rejected: actual = "reject"
                    case .unknownSubmission: actual = "unknown"
                    default: actual = "other"
                    }
                    check(actual == expected, "\(provider) HTTP \(status) explicit acceptance classification")
                }
            }
        }
    }
    static func rigRecovery(_ client: CanvasCloudClient, root: URL) async throws {
        let runs = CanvasCloudRunStore(root: root)
        var config = CanvasCloudConfiguration(); config.provider = .tripo; config.mode = .rig; config.sourceTaskID = "source-model"
        let created = Date(timeIntervalSince1970: 5)
        let original = try runs.begin(project: "p", node: "rig", createdAt: created, configuration: config)
        let gate = CloudRequestGate()
        CloudContractProtocol.install { gate.received($0) }
        let operation = Task {
            try await client.submit(config, key: "fixture-key", checkpoint: {
                _ = try runs.checkpointRig(original, check: $0)
            }, beforeSubmission: { _ = try runs.startSubmission(original) })
        }
        let request = await gate.next(); operation.cancel()
        request.respond(json(["code": 0, "data": ["task_id": "check-id"]]))
        do { _ = try await operation.value; check(false, "rig preflight cancellation") }
        catch { check(true, "rig preflight cancellation stops before final submission") }
        let saved = try runs.finishWaiting(original)
        check(saved.task.id == nil && saved.task.rigCheck?.id == "check-id" && saved.task.canResumeRigCheck,
              "rig check has independent durable ID and recoverable phase")
        let restarted = CanvasCloudRunStore(root: root)
        let restored = try restarted.latest(project: "p", node: "rig", createdAt: created)!
        check(restored.task.rigCheck == saved.task.rigCheck, "rig-check identity survives store restart")
        var routes: [String] = []
        CloudContractProtocol.install { fixture in
            routes.append(fixture.request.url!.path)
            if fixture.request.httpMethod == "GET" {
                fixture.respond(json(["code": 0, "data": ["task_id": "check-id", "status": "success",
                    "output": ["riggable": true, "rig_type": "quadruped"]]]))
            } else {
                check(body(fixture.request)["rig_type"] as? String == "quadruped", "resumed check output used for final rig")
                fixture.respond(json(["code": 0, "data": ["task_id": "final-rig"]]))
            }
        }
        let task = try await client.submit(config, key: "fixture-key", rigCheck: restored.task.rigCheck,
            checkpoint: { _ = try restarted.checkpointRig(restored, check: $0) },
            beforeSubmission: { _ = try restarted.startSubmission(restored) })
        let accepted = try restarted.accept(restored, task: task)
        check(routes == ["/v3/tasks/check-id", "/v3/animations/rig"] && accepted.task.id == "final-rig" &&
              accepted.task.rigCheck?.id == "check-id", "resume queries check then submits final once without rechecking")
        do { _ = try restarted.startSubmission(restored); check(false, "rig final duplicate guard") }
        catch { check(true, "final submission cannot restart from old preflight receipt") }
        do { _ = try restarted.checkpointRig(restored, check: saved.task.rigCheck!); check(false, "late preflight guard") }
        catch { check(true, "late rig-check progress cannot downgrade final receipt") }
        let unknown = try runs.begin(project: "p", node: "rig-unknown", createdAt: created, configuration: config)
        var complete = CanvasCloudRigCheck(sourceTaskID: "source-model",
            service: .init(baseURL: "https://openapi.tripo3d.com/v3/", submissionPath: "animations/rig-check", statusPrefix: "tasks/"))
        complete.state = .complete; complete.riggable = true; complete.rigType = "biped"
        _ = try runs.checkpointRig(unknown, check: complete)
        _ = try runs.startSubmission(unknown)
        let stopped = try runs.finishWaiting(unknown)
        check(stopped.task.state == .unknown && !stopped.task.canResumeRigCheck,
              "crash after final submission reservation remains unknown and cannot reuse completed check")
        do { _ = try runs.begin(project: "p", node: "rig-unknown", createdAt: created, configuration: config); check(false, "rig unknown guard") }
        catch { check(true, "unknown rig final submission blocks automatic new task") }
        var old = CanvasCloudTask(configuration: config)
        old.model = "original-rig-model"
        old.service = .init(baseURL: "https://openapi.tripo3d.com/v2/", submissionPath: "animations/rig", statusPrefix: "tasks/")
        CloudContractProtocol.install { fixture in
            check(fixture.request.url?.path == "/v2/animations/rig" &&
                  body(fixture.request)["model"] as? String == "original-rig-model",
                  "resumed rig final submission uses original API version and saved model")
            fixture.respond(json(["code": 0, "data": ["task_id": "old-rig"]]))
        }
        let oldAccepted = try await client.submit(config, key: "fixture-key", rigCheck: complete, originalTask: old)
        check(oldAccepted.service == old.service && oldAccepted.model == old.model, "resumed rig receipt retains original identity")
    }
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else { exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard root.path.hasPrefix("/private/tmp/clipslots-cloud-contracts-")
                || root.path.hasPrefix("/tmp/clipslots-cloud-contracts-") else { exit(2) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            fputs("Cloud contract runner exceeded bounded 20-second deadline\n", stderr)
            exit(2)
        }
        if CommandLine.arguments.last == "--crash" {
            let runs = CanvasCloudRunStore(root: root)
            var config = CanvasCloudConfiguration(); config.prompt = "fixture"
            let record = try runs.begin(project: "p", node: "crash", createdAt: Date(timeIntervalSince1970: 1), configuration: config)
            runs.afterResultInstall = { kill(getpid(), SIGKILL) }
            _ = try runs.cache(record, result: .init(data: Data(repeating: 37, count: 64), fileExtension: "mp3",
                metadata: .init(provider: .elevenLabs, taskID: "song-crash")))
            exit(3)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CloudContractProtocol.self]
        let client = CanvasCloudClient(http: .init(configuration: configuration))
        var config = CanvasCloudConfiguration(); config.provider = .tripo; config.mode = .text3D; config.prompt = "fixture"
        let receipt = json(["code": 0, "data": ["task_id": "accepted-task"]])
        let gate = CloudRequestGate()
        CloudContractProtocol.install { gate.received($0) }
        let submit = Task { try await client.submit(config, key: "fixture-key") }
        let request = await gate.next(); submit.cancel()
        request.respond(receipt)
        let task = try await submit.value
        check(task.id == "accepted-task", "submit cancellation after start retains observed ID")
        check(task.model == config.effectiveModel && task.service == config.serviceIdentity,
              "task records original model and full service route")
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.submit(config, key: "fixture-key")
        }
        do { _ = try await preCancelled.value; check(false, "pre-start cancellation is known not submitted") }
        catch CanvasCloudError.notSubmitted { check(true, "pre-start cancellation is known not submitted") }
        catch { check(false, "pre-start cancellation classification") }

        let nativeHTTP = CanvasCloudHTTP()
        let broken = try CloudBrokenSocket(body: receipt + Data("broken tail".utf8))
        nativeHTTP.didReceiveDataForTest = { _ in broken.closeConnection() }
        var nativeRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(broken.port)/fixture")!)
        nativeRequest.httpMethod = "POST"; nativeRequest.timeoutInterval = 2
        let (nativeData, _) = try await nativeHTTP.send(nativeRequest, limit: 1000, cancellation: .receiveSubmission,
            acceptedResponse: { data, response in
                response.statusCode == 200 &&
                    ((CanvasCloudClient.responseObject(data)?["data"] as? [String: Any])?["task_id"] as? String) == "accepted-task"
            })
        check(((CanvasCloudClient.responseObject(nativeData)?["data"] as? [String: Any])?["task_id"] as? String) == "accepted-task",
              "native socket failure after observed receipt retains ID")
        nativeHTTP.didReceiveDataForTest = nil
        CloudContractProtocol.install { $0.respond(receipt + Data("broken tail".utf8)) }
        check(try await client.submit(config, key: "fixture-key").id == "accepted-task", "valid receipt survives malformed bytes after root")
        CloudContractProtocol.install { $0.respond(Data("{\"code\":0,\"data\":{\"task_id\":\"accepted-task\"".utf8), error: URLError(.networkConnectionLost)) }
        do { _ = try await client.submit(config, key: "fixture-key"); check(false, "incomplete JSON is unknown") }
        catch CanvasCloudError.unknownSubmission { check(true, "incomplete JSON is unknown") }
        catch { check(false, "incomplete JSON classification") }
        CloudContractProtocol.install { $0.respond(Data(), status: 401) }
        do { _ = try await client.submit(config, key: "fixture-key"); check(false, "authentication is explicit rejection") }
        catch CanvasCloudError.unauthorized { check(true, "authentication is explicit rejection") }
        catch { check(false, "authentication classification") }
        CloudContractProtocol.install { $0.respond(Data(), status: 503) }
        do { _ = try await client.submit(config, key: "fixture-key"); check(false, "server failure is unknown acceptance") }
        catch CanvasCloudError.unknownSubmission { check(true, "server failure is unknown acceptance") }
        catch { check(false, "server failure classification") }

        let queryGate = CloudRequestGate()
        CloudContractProtocol.install { queryGate.received($0) }
        let query = Task { try await client.status(task, key: "fixture-key") }
        _ = await queryGate.next(); let tick = ProcessInfo.processInfo.systemUptime; query.cancel()
        do { _ = try await query.value; check(false, "query cancellation stops local waiting") }
        catch { check(ProcessInfo.processInfo.systemUptime - tick < 1, "query cancellation stops local waiting") }
        for limit in [0, -1, Int.min, Int.max, 150 * 1024 * 1024 + 1] {
            do { _ = try await client.http.send(URLRequest(url: URL(string: "https://fixture.invalid/")!), limit: limit); check(false, "invalid limit \(limit)") }
            catch CanvasCloudError.invalid { check(true, "invalid limit \(limit)") }
            catch { check(false, "invalid limit classification") }
        }
        var bounded = URLRequest(url: URL(string: "https://fixture.invalid/timeout")!)
        bounded.timeoutInterval = 0.1
        CloudContractProtocol.install { _ in }
        let timeoutStart = ProcessInfo.processInfo.systemUptime
        do { _ = try await client.http.send(bounded, limit: 100, cancellation: .receiveSubmission); check(false, "absolute deadline bounds local cancellation deferral") }
        catch { check(ProcessInfo.processInfo.systemUptime - timeoutStart < 1, "absolute deadline bounds local cancellation deferral") }

        for provider in [CanvasCloudConfiguration.Provider.elevenLabs, .miniMax] {
            var audio = CanvasCloudConfiguration(); audio.provider = provider; audio.prompt = "fixture"
            let gate = CloudRequestGate()
            CloudContractProtocol.install { gate.received($0) }
            let output = Task { try await client.audio(audio, key: "fixture-key") }
            let request = await gate.next(); output.cancel()
            if provider == .elevenLabs { request.respond(Data(repeating: 42, count: 64), headers: ["Content-Type": "audio/mpeg", "song-id": "fixture-song"]) }
            else { request.respond(json(["base_resp": ["status_code": 0], "data": ["status": 2, "audio": String(repeating: "ab", count: 32)]])) }
            let result = try await output.value
            check(result.data.count == (provider == .elevenLabs ? 64 : 32), "cancelled \(provider) response completes decode")
        }
        let png = try image(.png), jpeg = try image(.jpeg)
        let file = root.appendingPathComponent("reference.jpg")
        try png.write(to: file)
        check(try CanvasCloudClient.referenceImage(file).mime == "image/png", "actual PNG type overrides JPG extension")
        try jpeg.write(to: file)
        check(try CanvasCloudClient.referenceImage(file).mime == "image/jpeg", "actual JPEG type accepted")
        try Data("plain text".utf8).write(to: file)
        rejects("fake image extension rejected") { _ = try CanvasCloudClient.referenceImage(file) }
        try Data().write(to: file)
        rejects("empty image rejected") { _ = try CanvasCloudClient.referenceImage(file) }
        try png.prefix(24).write(to: file)
        rejects("truncated encoded image rejected") { _ = try CanvasCloudClient.referenceImage(file) }
        try png.write(to: file)
        rejects("growth after fstat rejected at byte budget") {
            _ = try CanvasCloudClient.referenceImage(file, afterOpen: {
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 0, count: 21 * 1024 * 1024))
            })
        }
        try png.write(to: file)
        rejects("path replacement during read rejected") {
            _ = try CanvasCloudClient.referenceImage(file, afterOpen: { try jpeg.write(to: file, options: .atomic) })
        }
        let link = root.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        rejects("symlink reference rejected") { _ = try CanvasCloudClient.referenceImage(link) }

        let runs = CanvasCloudRunStore(root: root)
        let created = Date(timeIntervalSince1970: 42)
        let record = try runs.begin(project: "p", node: "n", createdAt: created, configuration: config)
        rejects("unfinished record blocks resubmission even after graph clears task") {
            _ = try runs.begin(project: "p", node: "n", createdAt: created, configuration: config)
        }
        let accepted = try runs.accept(record, task: task)
        let afterFailure = try runs.finishWaiting(record)
        check(afterFailure.task.id == task.id && afterFailure.task.state == .pending, "late waiting failure cannot erase ID")
        check(try CanvasCloudRunStore(root: root).latest(project: "p", node: "n", createdAt: created)?.task == accepted.task,
              "independent receipt survives new store and graph deletion")
        var replacement = config; replacement.replacesReceiptID = record.id
        let next = try runs.begin(project: "p", node: "n", createdAt: created, configuration: replacement)
        let previous = try runs.record(project: "p", node: "n", createdAt: created, id: record.id)
        check(next.id != record.id && previous.task.id == task.id,
              "explicit replacement preserves old pending receipt")
        _ = try runs.finishWaiting(next, rejected: true)
        rejects("explicit rejection cannot be reopened by late acceptance") { _ = try runs.accept(next, task: task) }
        check(try runs.finishWaiting(next).task.state == .failed, "late waiting failure preserves explicit rejection terminal state")
        var audio = CanvasCloudConfiguration(); audio.prompt = "fixture"
        let audioRecord = try runs.begin(project: "p", node: "audio", createdAt: created, configuration: audio)
        let result = CanvasCloudClient.Result(data: Data(repeating: 42, count: 64), fileExtension: "mp3",
            metadata: .init(provider: .elevenLabs, taskID: "fixture-song"))
        let cached = try runs.cache(audioRecord, result: result)
        check(try runs.cachedResult(audioRecord)?.data == result.data, "audio cache exact byte recovery")
        check(try runs.finishWaiting(audioRecord).task.state == .complete, "waiting failure cannot downgrade cached audio")
        check(try runs.markProjected(cached).projected, "result projection recorded separately")
        var bad = result; bad.data.append(1)
        rejects("conflicting result rejected") { _ = try runs.cache(audioRecord, result: bad) }
        var foreign = result; foreign.metadata.receiptID = UUID()
        rejects("foreign receipt result rejected") { _ = try runs.cache(audioRecord, result: foreign) }
        foreign = result; foreign.fileExtension = "glb"
        rejects("provider result type mismatch rejected") { _ = try runs.cache(audioRecord, result: foreign) }
        let legacy = CanvasCloudTask(provider: .tripo, mode: .text3D, id: "old-task", state: .pending)
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyTask = try JSONDecoder().decode(CanvasCloudTask.self, from: legacyData)
        check(legacyTask.model == nil && legacyTask.service == nil && legacyTask.receiptID == nil,
              "legacy missing identity remains unknown")
        let adopted = try runs.adopt(project: "p", node: "legacy", createdAt: created, configuration: config, task: legacyTask)
        check(adopted.task.model == nil && adopted.task.service == nil, "legacy adoption does not invent current defaults")

        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [root.path, "--crash"]; try child.run(); child.waitUntilExit()
        check(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL, "real kill at result bundle install boundary")
        let recovered = try runs.latest(project: "p", node: "crash", createdAt: Date(timeIntervalSince1970: 1))!
        check(recovered.task.state == .complete && recovered.task.id == "song-crash",
              "installed result bundle restores receipt after kill before base record update")
        check(try runs.cachedResult(recovered)?.data == Data(repeating: 37, count: 64), "killed audio cache restores exact complete bytes")
        try await allModes(client, root: root)
        try await rigRecovery(client, root: root)
        #if CLIPSLOTS_STAGED_CLOUD
        let staged = true
        #else
        let staged = false
        #endif
        let report: [String: Any] = ["passed": passed, "failed": failures.count, "failures": failures,
            "providerRequests": 0, "stagedSource": staged, "productionRestarted": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("report.json"), options: .atomic)
        print("Cloud contracts: \(passed) passed, \(failures.count) failed")
        if !failures.isEmpty { exit(1) }
    }
}
