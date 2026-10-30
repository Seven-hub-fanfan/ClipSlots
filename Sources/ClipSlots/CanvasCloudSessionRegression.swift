#if DEBUG
import Foundation
import AppKit
import Darwin
import ClipSlotsKit

private final class NativeCloudProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var callback: ((NativeCloudProtocol) -> Void)?
    static func install(_ callback: @escaping (NativeCloudProtocol) -> Void) {
        lock.lock(); self.callback = callback; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let callback = Self.callback; Self.lock.unlock(); callback?(self)
    }
    override func stopLoading() {}
    func respond(_ data: Data, status: Int = 200, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}

private final class NativeCloudGate: @unchecked Sendable {
    private let lock = NSLock()
    private var request: NativeCloudProtocol?
    private var waiter: CheckedContinuation<NativeCloudProtocol, Never>?
    func received(_ request: NativeCloudProtocol) {
        lock.lock(); let waiter = waiter; self.waiter = nil; self.request = request; lock.unlock()
        waiter?.resume(returning: request)
    }
    func next() async -> NativeCloudProtocol {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let request { lock.unlock(); continuation.resume(returning: request) }
            else { waiter = continuation; lock.unlock() }
        }
    }
}

/// Actual App sessions, graph transactions, media decoder and attachment store.
/// The guarded pre-startup hook uses temporary roots and opens no window.
@MainActor
func runCloudSessionRegression(directory: URL) async -> [String: Any] {
    var checks: [String] = [], failures: [String] = []
    func check(_ value: Bool, _ name: String) {
        if value { checks.append(name) } else { failures.append(name) }
        print("\(value ? "PASS" : "FAIL"): \(name)"); fflush(stdout)
    }
    func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    // Valid local PCM audio exercises AVFoundation decode and exact cache bytes;
    // the fixture does not claim that a provider returned this codec.
    func wave() -> Data {
        var data = Data("RIFF".utf8)
        func word<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        let samples = 1600
        word(UInt32(36 + samples * 2)); data.append(Data("WAVEfmt ".utf8)); word(UInt32(16))
        word(UInt16(1)); word(UInt16(1)); word(UInt32(8000)); word(UInt32(16000)); word(UInt16(2)); word(UInt16(16))
        data.append(Data("data".utf8)); word(UInt32(samples * 2))
        for index in 0..<samples { word(Int16(sin(Double(index) * 0.3) * 20000)) }
        return data
    }
    func model() -> Data {
        var bytes = json(["asset": ["version": "2.0"], "scene": 0, "scenes": [["nodes": [0]]], "nodes": [["name": "fixture"]]])
        while !bytes.count.isMultiple(of: 4) { bytes.append(32) }
        var data = Data()
        for value in [UInt32(0x46546c67), 2, UInt32(20 + bytes.count), UInt32(bytes.count), 0x4e4f534a] {
            var word = value.littleEndian; withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
        }
        data.append(bytes); return data
    }
    var heldLock: Int32 = -1
    defer { if heldLock >= 0 { _ = flock(heldLock, LOCK_UN); close(heldLock) } }
    do {
        _ = NSApplication.shared
        let store = SlotStoreObservable()
        check(store.ensureCanvasUnfiledGroup(), "native isolated private group created")
        let runs = CanvasCloudRunStore(root: directory)
        let transport = URLSessionConfiguration.ephemeral; transport.protocolClasses = [NativeCloudProtocol.self]
        let client = CanvasCloudClient(http: .init(configuration: transport))
        let audio = wave(), glb = model()
        var slot = 0
        func session(_ name: String, provider: CanvasCloudConfiguration.Provider = .tripo,
                     mode: CanvasCloudConfiguration.Mode = .text3D) throws -> CanvasToolSession {
            slot += 1
            let root = directory.appendingPathComponent(name), storage = CanvasStorage(rootOverride: root)
            let projects = CanvasProjectStorage(rootOverride: root), project = projects.load().activeProjectId
            var config = CanvasCloudConfiguration(); config.provider = provider; config.mode = mode; config.prompt = "fixture"
            if mode == .rig { config.sourceTaskID = "source-model" }
            var node = CanvasNode(pageId: "fixture", groupId: SpecialSlotStorage.unfiledGroupId, slot: slot,
                                  kind: provider == .elevenLabs ? .audio : .threeD, x: 10, y: 20)
            var tools = CanvasToolConfiguration(); tools.cloudGeneration = config; node.tools = tools
            guard storage.save(.init(nodes: [node]), projectId: project),
                  store.canvasStorage(groupId: node.groupId).set(slot, content: SlotContent(), in: node.groupId)
            else { throw CanvasCloudError.invalid("Fixture seed failed") }
            let canvas = CanvasStore(storage: storage, projectStorage: projects)
            canvas.installAttachmentBridge(id: UUID(), apply: { group, index, attachments, token, away, restore in
                _ = store.applyCanvasAttachmentEdit(groupId: group, slot: index, attachments: attachments,
                    stashToken: token, stashAwayIds: away, restoreIds: restore)
                canvas.noteSlotDataChanged()
            }, discard: { store.discardCanvasAttachmentStash(token: $0) })
            return CanvasToolSession(canvas: canvas, store: store, node: node, attachments: [], cloudClient: client, cloudRuns: runs)
        }
        for action in ["edit", "delete", "switch", "cancel", "projection-failure"] {
            let current = try session(action), gate = NativeCloudGate()
            NativeCloudProtocol.install { gate.received($0) }
            let operation = Task { try await current.performCloud(key: "fixture-key", resume: false) }
            let request = await gate.next()
            check(current.configuration.cloudGeneration?.task?.state == .submitting, "\(action): reservation saved before HTTP starts")
            var edited = current.configuration
            if action == "edit" {
                edited.cloudGeneration?.prompt = "latest user draft"
                current.canvas.editTool(id: current.nodeID, configuration: edited, detail: "user edit")
            } else if action == "delete" { current.canvas.removeNodes(ids: [current.nodeID]) }
            else if action == "switch" { _ = current.canvas.createProject(name: "next project") }
            else if action == "cancel" { operation.cancel() }
            else { current.canvas.flushTextDocuments = { false } }
            request.respond(json(["code": 0, "data": ["task_id": "task-\(action)"]]))
            do { try await operation.value; check(false, "\(action): stops before result projection") }
            catch { check(true, "\(action): stops before result projection") }
            let record = try CanvasCloudRunStore(root: directory).latest(project: current.project, node: current.nodeID, createdAt: current.createdAt)
            check(record?.task.id == "task-\(action)" && record?.task.state == .pending,
                  "\(action): independent receipt retains accepted ID and original provider")
            check(current.attachments.isEmpty, "\(action): no unrequested attachment import")
            if action == "edit" { check(current.configuration == edited, "user edit remains byte-equivalent after remote acceptance") }
            if action == "delete" { check(current.node == nil && current.canvas.nodes.isEmpty, "cloud acceptance never resurrects deleted node") }
            if action == "switch" { check(current.node == nil && current.canvas.nodes.isEmpty, "cloud acceptance never writes into new project") }
            if action == "projection-failure" { current.canvas.flushTextDocuments = nil }
            if action == "edit" {
                NativeCloudProtocol.install { fixture in
                    if fixture.request.httpMethod == "GET", fixture.request.url?.host != "cdn.example.com" {
                        fixture.respond(json(["code": 0, "data": ["task_id": "task-edit", "status": "success",
                            "output": ["model_url": "https://cdn.example.com/edited.glb"]]]))
                    } else { fixture.respond(glb) }
                }
                try await current.performRecoveredCloud(key: "fixture-key")
                check(current.configuration.cloudGeneration == edited.cloudGeneration && current.attachments.count == 1,
                      "explicit original-task recovery imports result while preserving latest user draft")
            }
        }
        let unknown = try session("unknown"), unknownGate = NativeCloudGate()
        NativeCloudProtocol.install { unknownGate.received($0) }
        let unknownOperation = Task { try await unknown.performCloud(key: "fixture-key", resume: false) }
        let unknownRequest = await unknownGate.next(); unknownRequest.respond(Data("bad response".utf8))
        do { try await unknownOperation.value; check(false, "unknown response stops") } catch { check(true, "unknown response stops") }
        var cleared = unknown.configuration; cleared.cloudGeneration?.task = nil
        unknown.canvas.editTool(id: unknown.nodeID, configuration: cleared, detail: "clear task projection")
        var requestCount = 0
        NativeCloudProtocol.install { requestCount += 1; $0.respond(Data(), status: 503) }
        do { try await unknown.performCloud(key: "fixture-key", resume: false); check(false, "unknown independent guard") }
        catch { check(requestCount == 0, "clearing graph cannot resubmit an independent unknown run") }

        let song = try session("cancelled-audio", provider: .elevenLabs, mode: .music), songGate = NativeCloudGate()
        NativeCloudProtocol.install { songGate.received($0) }
        let music = Task { try await song.performCloud(key: "fixture-key", resume: false) }
        let songRequest = await songGate.next(); music.cancel()
        songRequest.respond(audio, headers: ["Content-Type": "audio/mpeg", "song-id": "local-song-fixture"])
        do { try await music.value; check(false, "audio local cancellation") } catch { check(true, "audio local cancellation") }
        check(song.hasCloudResult && song.attachments.isEmpty, "cancelled audio is cached before import and remains recoverable")
        requestCount = 0; NativeCloudProtocol.install { requestCount += 1; $0.respond(Data(), status: 503) }
        try await song.performRecoveredCloud(key: "")
        check(song.attachments.count == 1 && song.waveform.count == 160 && requestCount == 0, "audio recovery decodes actual media with zero remote requests")
        let persisted = song.attachments[0]
        check(try Data(contentsOf: URL(fileURLWithPath: persisted.storagePath!)) == audio, "native recovered audio exact bytes")
        let history = song.canvas.history.cursor
        try await song.performRecoveredCloud(key: "")
        check(song.attachments.count == 1 && song.canvas.history.cursor == history, "repeated result recovery does not import or add undo entry")
        _ = song.canvas.undo()
        song.attachments = store.canvasSlotAttachments(groupId: song.node!.groupId, slot: song.node!.slot)
        check(song.attachments.isEmpty && song.configuration.resourceAttachmentID == nil, "native cloud result undo removes graph resource and attachment together")
        _ = song.canvas.redo()
        song.attachments = store.canvasSlotAttachments(groupId: song.node!.groupId, slot: song.node!.slot)
        check(try song.attachments.count == 1 && Data(contentsOf: URL(fileURLWithPath: song.attachments[0].storagePath!)) == audio,
              "native cloud result redo restores exact audio bytes")

        let failure = try session("write-failure", provider: .elevenLabs, mode: .music), failureGate = NativeCloudGate()
        NativeCloudProtocol.install { failureGate.received($0) }
        let failedWrite = Task { try await failure.performCloud(key: "fixture-key", resume: false) }
        let failedRequest = await failureGate.next()
        let root = directory.appendingPathComponent("cloud-generation-runs")
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let record = failure.cloudRecovery!
        let lockedDirectory = dirs.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(record.id.uuidString + ".json").path) }!
        heldLock = open(lockedDirectory.appendingPathComponent("record.lock").path, O_RDWR | O_CLOEXEC)
        guard heldLock >= 0, flock(heldLock, LOCK_EX | LOCK_NB) == 0 else { throw CanvasCloudError.remote }
        failedRequest.respond(audio, headers: ["Content-Type": "audio/mpeg", "song-id": "write-failure-song"])
        do { try await failedWrite.value; check(false, "locked result write explicitly fails") }
        catch { check(failure.hasCloudResult && failure.cloudRecovery?.task.id == "write-failure-song",
                      "failed durable audio save keeps observed ID and full result in memory") }
        _ = flock(heldLock, LOCK_UN); close(heldLock); heldLock = -1
        requestCount = 0; NativeCloudProtocol.install { requestCount += 1; $0.respond(Data(), status: 503) }
        try await failure.performRecoveredCloud(key: "")
        check(try failure.attachments.count == 1 && requestCount == 0 &&
              runs.cachedResult(failure.cloudRecovery!)?.data == audio, "audio save recovery retries persistence without regenerating")

        let receiptFailure = try session("receipt-write-failure"), receiptGate = NativeCloudGate()
        NativeCloudProtocol.install { receiptGate.received($0) }
        let receiptWrite = Task { try await receiptFailure.performCloud(key: "fixture-key", resume: false) }
        let receiptRequest = await receiptGate.next(), reservation = receiptFailure.cloudRecovery!
        let receiptDirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let receiptDirectory = receiptDirs.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(reservation.id.uuidString + ".json").path)
        }!
        heldLock = open(receiptDirectory.appendingPathComponent("record.lock").path, O_RDWR | O_CLOEXEC)
        guard heldLock >= 0, flock(heldLock, LOCK_EX | LOCK_NB) == 0 else { throw CanvasCloudError.remote }
        receiptRequest.respond(json(["code": 0, "data": ["task_id": "observed-unsaved-id"]]))
        do { try await receiptWrite.value; check(false, "locked task receipt write") }
        catch { check(receiptFailure.cloudRecovery?.task.id == "observed-unsaved-id",
                      "failed independent receipt save retains observed remote ID in memory") }
        _ = flock(heldLock, LOCK_UN); close(heldLock); heldLock = -1
        var recoveryMethods: [String] = []
        NativeCloudProtocol.install { fixture in
            recoveryMethods.append(fixture.request.httpMethod ?? "")
            if fixture.request.url?.host == "cdn.example.com" { fixture.respond(glb) }
            else { fixture.respond(json(["code": 0, "data": ["task_id": "observed-unsaved-id", "status": "success",
                "output": ["model_url": "https://cdn.example.com/recovered.glb"]]])) }
        }
        try await receiptFailure.performRecoveredCloud(key: "fixture-key")
        check(recoveryMethods == ["GET", "GET"] && receiptFailure.attachments.count == 1,
              "receipt persistence retry and result recovery never resubmit accepted task")

        let rig = try session("rig-resume", mode: .rig), rigGate = NativeCloudGate()
        NativeCloudProtocol.install { rigGate.received($0) }
        let rigOperation = Task { try await rig.performCloud(key: "fixture-key", resume: false) }
        let rigRequest = await rigGate.next(); rigOperation.cancel()
        rigRequest.respond(json(["code": 0, "data": ["task_id": "rig-check-native"]]))
        do { try await rigOperation.value; check(false, "native rig cancellation") }
        catch { check(rig.configuration.cloudGeneration?.task?.canResumeRigCheck == true, "native pending rig-check survives local cancellation") }
        var paths: [String] = []
        NativeCloudProtocol.install { fixture in
            let path = fixture.request.url!.path; paths.append(path)
            if path.hasSuffix("rig-check-native") {
                fixture.respond(json(["code": 0, "data": ["task_id": "rig-check-native", "status": "success",
                    "output": ["riggable": true, "rig_type": "biped"]]]))
            } else if path.hasSuffix("/rig") { fixture.respond(json(["code": 0, "data": ["task_id": "rig-final-native"]])) }
            else if path.hasSuffix("rig-final-native") {
                fixture.respond(json(["code": 0, "data": ["task_id": "rig-final-native", "status": "success",
                    "output": ["model_url": "https://cdn.example.com/native.glb"]]]))
            } else { fixture.respond(glb) }
        }
        try await rig.performCloud(key: "fixture-key", resume: true)
        check(paths == ["/v3/tasks/rig-check-native", "/v3/animations/rig", "/v3/tasks/rig-final-native", "/native.glb"] &&
              rig.attachments.count == 1, "actual session resumes check and imports final model without duplicate preflight")
        let rigHistory = rig.canvas.history.cursor
        try await rig.performCloud(key: "fixture-key", resume: true)
        check(paths.count == 4 && rig.attachments.count == 1 && rig.canvas.history.cursor == rigHistory,
              "async result normalizes receipt metadata for idempotent native recovery")
    } catch { check(false, "native cloud fixture: \(error.localizedDescription)") }
    return ["passed": checks.count, "checks": checks, "failures": failures, "providerRequests": 0,
            "foregroundRequired": false, "instrument": "actual CanvasToolSession + CanvasStore + SlotStoreObservable + AVFoundation",
            "fixtureAudioCodec": "local generated PCM WAV; no provider codec validation"]
}
#endif
