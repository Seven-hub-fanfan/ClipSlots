import Foundation
import ClipSlotsKit

private struct AdapterChecks {
    var results: [(Bool, String)] = []
    mutating func check(_ value: Bool, _ name: String) { results.append((value, "ADAPTER \(name)")) }
    mutating func rejects(_ name: String, _ expected: GenerationAdapterError? = nil,
                         _ operation: () async throws -> Void) async {
        do { try await operation(); check(false, name) }
        catch {
            if let expected { check((error as? GenerationAdapterError) == expected, name) }
            else { check(error is GenerationAdapterError, name) }
        }
    }
}

/// Explicit CLI contract fixtures. No shell, network, login or generation occurs here.
private actor AdapterFixture {
    var calls: [GenerationCLIInvocation] = []
    var reference: String
    var models: [JSONValue]
    var submission = ToolProcess.Output(status: 0, stdout: #"{"event":"task_created","task_id":"123456789012345678"}"#, stderr: "")
    var observation: JSONValue = ["task_id": "123456789012345678", "status": "waiting"]
    var loggedIn = true
    var version = "1.1.5"

    init(reference: String = "", models: [JSONValue] = []) {
        self.reference = reference; self.models = models
    }
    func setSubmission(_ value: ToolProcess.Output) { submission = value }
    func setObservation(_ value: JSONValue) { observation = value }
    func setReference(_ value: String) { reference = value }
    func setModels(_ value: [JSONValue]) { models = value }
    func setLoggedIn(_ value: Bool) { loggedIn = value }
    func setVersion(_ value: String) { version = value }
    func execute(_ invocation: GenerationCLIInvocation) throws -> ToolProcess.Output {
        calls.append(invocation)
        let a = invocation.arguments
        if invocation.submitting { return submission }
        let value: JSONValue
        if a == ["--version"] { return .init(status: 0, stdout: version, stderr: "") }
        if a.contains("auth") {
            value = a.contains("--output") ? ["loggedIn": .bool(loggedIn)]
                : ["username": .string(loggedIn ? "fixture-user" : "")]
        } else if a.contains("references") {
            let directory = invocation.environment["BA_REFERENCES_DIR"]!
            value = .array([["workflow_id": "123456789012345678", "title": "Fixture",
                             "file_path": .string(directory + "/fixture.md"), "content": .string(reference)]])
        } else if a.contains("skill") {
            value = ["markdown": .string(reference)]
        } else if a.starts(with: ["model", "list"]) {
            value = .array(models)
        } else if a.starts(with: ["model", "describe"]) {
            guard let model = models.first(where: { $0["id"]?.stringValue == a[2] }) else {
                throw GenerationAdapterError.invalidResponse
            }
            value = model
        } else { value = observation }
        return .init(status: 0, stdout: try value.encodedText(), stderr: "")
    }
    var executor: GenerationCLIExecutor { { try await self.execute($0) } }
}

private func adapterReference(schema: JSONValue? = nil, upload: Bool = false) throws -> String {
    let input: JSONValue = schema ?? ["type": "object", "additionalProperties": false,
        "required": ["prompt"], "properties": ["prompt": ["type": "string", "minLength": 1],
            "negative": ["type": "string", "default": ""],
            "source": ["type": "string", "default": "https://example.test/input.png"]]]
    return """
    # Fixture

    ## 输入
    | 名称 | internal_name | format | 输入描述 | 默认值 | 限制 | 节点来源 |
    | --- | --- | --- | --- | --- | --- | --- |
    | prompt | prompt | input | | | | Test:prompt |
    | source | internal_source | \(upload ? "image_upload" : "input") | | | | Test:image |

    ## 输出
    | 名称 | internal_name | format | 节点来源 |
    | --- | --- | --- | --- |
    | images | images | image | Test:images |

    ## 输入 Schema
    ```json
    \(try input.encodedText())
    ```
    """
}

private func adapterImageModel(seed: Bool = true) -> JSONValue {
    var parameters: [JSONValue] = [
        ["name": "ratio", "options": [["value": "1:1"], ["value": "16:9"]]],
        ["name": "width", "min": 16, "max": 16384], ["name": "height", "min": 16, "max": 16384]]
    if seed { parameters.append(["name": "seed", "min": 0, "max": 999999]) }
    return ["id": "fixture-image", "name": "Image", "enabled": true,
        "generationTypes": ["text-2-image", "image-2-image"], "parameters": .array(parameters),
        "inputs": ["image": ["maxCount": 2]], "dimensions": ["minimumPixels": 4096]]
}

private func adapterVideoModel() -> JSONValue {
    ["id": "fixture-video", "name": "Video", "enabled": true,
     "generationTypes": ["text-2-video", "image-to-video"],
     "parameters": [["name": "ratio", "options": [["value": "16:9"]]],
        ["name": "resolution", "options": [["value": "720p"], ["value": "4k"]]],
        ["name": "duration", "min": 4, "max": 15, "specialValues": [-1]],
        ["name": "generate_audio"], ["name": "seed", "min": 0, "max": 999999]],
     "references": ["roles": [["role": "first_frame", "maxCount": 1],
        ["role": "last_frame", "maxCount": 1], ["role": "reference_image", "maxCount": 2]],
        "constraints": [
            ["type": "mutually-exclusive-groups", "groups": [["first_frame", "last_frame"], ["reference_image"]]],
            ["type": "requires-any", "whenAny": ["last_frame"], "fields": ["first_frame"]]]]]
}

func runGenerationAdapterTests(_ t: TestRunner, live: Bool = false) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("adapter test '\(UUID())")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let results: [(Bool, String)] = smokeAwait {
        var c = AdapterChecks()
        do {
            let bindings = [GenerationOutputBinding(name: "images", kind: .image,
                path: [.each, .key("images"), .each])]
            let ref = try adapterReference()
            let baFixture = AdapterFixture(reference: ref)
            let ba = try ByteArtistGenerationAdapter(root: root.appendingPathComponent("ba"),
                outputBindings: ["123456789012345678": bindings], executor: await baFixture.executor)
            try FileManager.default.createDirectory(at: ba.referenceDirectory, withIntermediateDirectories: true)
            let refFile = ba.referenceDirectory.appendingPathComponent("fixture.md")
            try Data(ref.utf8).write(to: refFile)
            try await ba.preflight()
            c.check(true, "BA version and authenticated identity checked")
            for version in ["1.1.5", "v1.1.6", "ba 1.2.0", "ba 1.1.5\n---\nlatest: 1.1.5 (up to date)"] {
                c.check(ByteArtistGenerationAdapter.supportsVersion(version), "BA accepts \(version)")
            }
            for version in ["1.1.4", "2.1.5", "11.1.5", "1.1.5-beta", "noise 1.1.5"] {
                c.check(!ByteArtistGenerationAdapter.supportsVersion(version), "BA rejects \(version)")
            }
            await baFixture.setLoggedIn(false)
            await c.rejects("BA auth false blocked", .authenticationRequired) { try await ba.preflight() }
            await baFixture.setLoggedIn(true)
            let capabilities = try await ba.discover()
            c.check(capabilities.count == 1 && capabilities[0].kind == .image, "BA local reference discovery")
            let capability = capabilities[0]
            let prompt = " 原样 ' \\ $(touch /tmp/forbidden) `echo hi`\n中文"
            let prepared = try await ba.prepare(.init(values: ["prompt": .string(prompt)]), capability: capability)
            c.check(prepared.input.values["negative"] == .string(""), "BA schema default populated")
            c.check(prepared.input.values["prompt"] == .string(prompt), "BA prompt preserved as JSON value")
            let submitted = try await ba.submit(prepared)
            c.check(submitted.task.taskID == "123456789012345678" && !submitted.needsQuery, "BA accepted ID stays a decimal string")
            let invocations = await baFixture.calls
            let call = invocations.last!
            c.check(call.submitting && call.arguments.contains("--no-wait") && call.arguments.contains("--use-limit")
                    && call.arguments.contains("ndjson"), "BA submits without blocking, with limits and NDJSON")
            let jsonIndex = call.arguments.firstIndex(of: "--inputs")!
            let sent = try JSONValue.decode(jsonText: call.arguments[jsonIndex + 1])
            c.check(sent["prompt"] == .string(prompt), "BA JSON argv does not interpolate shell syntax")
            c.check(call.arguments.suffix(4) == ["-c", "cn", "--as", "default"], "BA scope explicit")
            c.check(call.environment["CRATE_BASE_URL"] == nil && call.environment["CRATE_TOKEN"] == nil
                    && call.environment["BA_CLI_TASK_CACHE_FILE"]?.hasPrefix(call.directory.path + "/") == true,
                    "BA provider environment and task cache isolated")
            await c.rejects("BA output count does not silently downgrade") {
                _ = try await ba.prepare(.init(values: ["prompt": "x"], outputCount: 2), capability: capability)
            }
            await c.rejects("BA unknown parameters blocked") {
                _ = try await ba.prepare(.init(values: ["prompt": "x", "seed": 1]), capability: capability)
            }
            await c.rejects("BA required prompt blocked") {
                _ = try await ba.prepare(.init(values: [:]), capability: capability)
            }
            await baFixture.setReference(ref + "\nchanged")
            await c.rejects("BA remote reference drift blocked", .capabilityChanged) {
                _ = try await ba.prepare(.init(values: ["prompt": "x"]), capability: capability)
            }
            await baFixture.setReference(ref)
            try Data((ref + "\nlocal edit").utf8).write(to: refFile)
            await c.rejects("BA local reference changed before submit", .capabilityChanged) {
                _ = try await ba.submit(prepared)
            }
            try Data(ref.utf8).write(to: refFile)
            let accepted = #"{"event":"task_created","task_id":"123456789012345678"}"#
            for (name, output) in [
                ("error after ID", ToolProcess.Output(status: 1, stdout: accepted + "\n" + #"{"code":"BA_CLI_INTERNAL_ERROR"}"#, stderr: "")),
                ("cut final line", ToolProcess.Output(status: 0, stdout: accepted + "\n{\"event\":", stderr: "")),
                ("timeout after ID", ToolProcess.Output(status: 15, stdout: accepted, stderr: "", stopped: true)),
                ("truncated after ID", ToolProcess.Output(status: 0, stdout: accepted, stderr: "", truncated: true))] {
                let result = try ByteArtistGenerationAdapter.parseSubmission(output, capability: capability)
                c.check(result.task == submitted.task && result.needsQuery, "BA \(name) retains task for query")
            }
            for text in ["{broken", #"{"event":"task_created","task_id":9007199254740992}"#,
                         accepted + "\n" + #"{"event":"task_created","task_id":"other"}"#] {
                await c.rejects("BA ambiguous acceptance is unknown", .submissionUnknown(.byteartist)) {
                    _ = try ByteArtistGenerationAdapter.parseSubmission(.init(status: 1, stdout: text, stderr: ""), capability: capability)
                }
            }
            await c.rejects("BA preflight rejection remains definite", .commandFailed(code: "BA_CLI_INPUT_INVALID", phase: "validate")) {
                _ = try ByteArtistGenerationAdapter.parseSubmission(.init(status: 1,
                    stdout: #"{"code":"BA_CLI_INPUT_INVALID","phase":"validate"}"#, stderr: ""), capability: capability)
            }
            for (status, expected) in [("waiting", GenerationStatus.queued(ahead: nil)),
                                      ("running", .running), ("failed", .failed), ("new-state", .unknown("new-state"))] {
                await baFixture.setObservation(["task_id": .string(submitted.task.taskID), "status": .string(status)])
                let result = try await ba.query(submitted.task)
                c.check(result.status == expected, "BA \(status) status including failed exit zero")
            }
            let output: JSONValue = .array([["images": ["https://example.test/1.png", "https://example.test/2.png"]]])
            await baFixture.setObservation(["task_id": .string(submitted.task.taskID), "status": "finished", "output_result": output])
            let media = try await ba.query(submitted.task)
            c.check(media.status == .succeeded && media.artifacts.count == 2
                    && media.artifacts.allSatisfy({ $0.remoteURL != nil }), "BA all explicitly mapped media preserved")
            let noBindings = try GenerationTaskHandle(context: .byteartist, taskID: submitted.task.taskID, capabilityID: capability.id, kind: .image)
            let mismatch = try await ba.query(noBindings)
            c.check(mismatch.status == .outputMismatch && mismatch.rawOutput == output, "BA unmapped outputs require mapping and retain raw data")
            await baFixture.setObservation(["task_id": "other", "status": "finished"])
            await c.rejects("BA response for wrong task blocked", .invalidResponse) { _ = try await ba.query(submitted.task) }

            let alias = try GenerationProviderContext(provider: .byteartist, endpoint: GenerationProviderContext.byteartist.endpoint,
                                                       controlPlane: "cn", accountAlias: "secondary")
            let baAlias = try ByteArtistGenerationAdapter(context: alias, root: root.appendingPathComponent("ba"),
                                                          executor: await baFixture.executor)
            c.check(baAlias.referenceDirectory != ba.referenceDirectory, "BA account aliases have separate reference roots")
            await c.rejects("BA task cannot be queried as another account", .providerMismatch) {
                _ = try await baAlias.query(submitted.task)
            }
            let roundTrip = try JSONDecoder().decode(GenerationTaskHandle.self, from: JSONEncoder().encode(submitted.task))
            c.check(roundTrip == submitted.task, "task handle round trip preserves context and output paths")
            let legacy = try JSONDecoder().decode(GenerationTaskHandle.self, from: Data(#"{"taskId":"legacy-1"}"#.utf8))
            c.check(legacy.context == .crate && legacy.taskID == "legacy-1", "old taskId defaults to Crate")
            await c.rejects("context decoder validates remote endpoint") {
                _ = try JSONDecoder().decode(GenerationProviderContext.self, from: Data(
                    #"{"provider":"byteartist","endpoint":"file:///tmp/x","controlPlane":"cn","accountAlias":"default"}"#.utf8))
            }

            // Schema audit through the public preparation boundary, including absent fields.
            for field: JSONValue in [
                ["type": "string", "format": "email", "default": ""],
                ["type": "array", "items": ["type": "integer", "unknownRule": true], "default": []],
                ["type": "string", "pattern": "\\p{L}", "default": ""],
                ["type": "string", "minLength": "bad", "default": "x"]] {
                let schema: JSONValue = ["type": "object", "properties": ["optional": field]]
                let reference = try adapterReference(schema: schema)
                await baFixture.setReference(reference)
                try Data(reference.utf8).write(to: refFile)
                let cap = try await ba.discover()[0]
                await c.rejects("unsupported nested Schema blocked before command") {
                    _ = try await ba.prepare(.init(values: [:]), capability: cap)
                }
            }
            let unicodeSchema: JSONValue = ["type": "object", "properties": ["prompt": ["type": "string", "maxLength": 1]]]
            let unicodeRef = try adapterReference(schema: unicodeSchema)
            await baFixture.setReference(unicodeRef)
            try Data(unicodeRef.utf8).write(to: refFile)
            let unicodeCap = try await ba.discover()[0]
            await c.rejects("Schema counts Unicode scalars rather than graphemes") {
                _ = try await ba.prepare(.init(values: ["prompt": "e\u{301}"]), capability: unicodeCap)
            }

            let file = root.appendingPathComponent("source ' $(text).png")
            try Data("fixture".utf8).write(to: file)
            let uploadRef = try adapterReference(upload: true)
            await baFixture.setReference(uploadRef)
            try Data(uploadRef.utf8).write(to: refFile)
            let uploadCap = try await ba.discover()[0]
            let upload = try await ba.prepare(.init(values: ["prompt": "x", "source": .string(file.absoluteString)]), capability: uploadCap)
            c.check(upload.inputFiles.count == 1 && upload.input.values["source"] == .string(file.path), "BA upload visible slot key and file URL normalized")
            try Data("file was changed".utf8).write(to: file)
            await c.rejects("BA upload snapshot drift blocked", .inputChanged) { _ = try await ba.submit(upload) }
            await c.rejects("BA missing upload blocked") {
                _ = try await ba.prepare(.init(values: ["prompt": "x", "source": "/missing/image.png"]), capability: uploadCap)
            }
            let beforeCancel = await baFixture.calls.count
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await ba.submit(prepared)
            }
            do { _ = try await cancelled.value; c.check(false, "BA pre-submit cancellation") }
            catch is CancellationError { c.check(true, "BA pre-submit cancellation") }
            c.check(await baFixture.calls.count == beforeCancel, "cancelled BA never invokes executor")

            let crateFixture = AdapterFixture(models: [adapterImageModel(), adapterVideoModel()])
            let crate = try CrateGenerationAdapter(directory: root.appendingPathComponent("crate"), executor: await crateFixture.executor)
            try await crate.preflight()
            let catalog = try await crate.discover()
            c.check(catalog.count == 2, "Crate discovers image and video contracts")
            let imageCap = catalog.first(where: { $0.kind == .image })!
            let videoCap = catalog.first(where: { $0.kind == .video })!
            let image = try await crate.prepare(.init(values: ["prompt": .string(prompt), "ratio": "16:9", "seed": 42,
                                                              "width": 64, "height": 64]), capability: imageCap)
            await crateFixture.setSubmission(.init(status: 0, stdout:
                #"{"success":true,"taskId":"987654321098765432","input":{"extra_params_json":"{\"seed\":42}"}}"#, stderr: ""))
            let imageResult = try await crate.submit(image)
            let crateCall = await crateFixture.calls.last!
            c.check(crateCall.arguments.contains(prompt) && crateCall.arguments.contains("seed=42")
                    && crateCall.arguments.contains("ratio=16:9"), "Crate prompt, seed and ratio transmitted exactly")
            c.check(crateCall.environment["BA_REFERENCES_DIR"] == nil
                    && crateCall.environment["CRATE_BASE_URL"] == crate.context.endpoint.absoluteString, "Crate endpoint and provider environment isolated")
            c.check(imageResult.task.seed == 42 && imageResult.task.context == .crate, "Crate seed and context retained")
            for values: [String: JSONValue] in [
                ["prompt": "x", "ratio": "4:3"], ["prompt": "x", "bogus": 1],
                ["prompt": "x", "width": 16, "height": 16], ["prompt": "   "],
                ["prompt": "x", "images": [.string(file.path), .string(file.path), .string(file.path)]]] {
                await c.rejects("Crate invalid values blocked instead of dropped") {
                    _ = try await crate.prepare(.init(values: values), capability: imageCap)
                }
            }
            await c.rejects("Crate rejects count greater than one") {
                _ = try await crate.prepare(.init(values: ["prompt": "x"], outputCount: 2), capability: imageCap)
            }
            await crateFixture.setModels([adapterImageModel(seed: false), adapterVideoModel()])
            await c.rejects("Crate metadata change requires prepare again", .capabilityChanged) {
                _ = try await crate.prepare(.init(values: ["prompt": "x"]), capability: imageCap)
            }
            let noSeed = try await crate.discover().first(where: { $0.kind == .image })!
            await c.rejects("Crate undeclared seed is blocked") {
                _ = try await crate.prepare(.init(values: ["prompt": "x", "seed": 42]), capability: noSeed)
            }
            await crateFixture.setModels([adapterImageModel(), adapterVideoModel()])
            let video = try await crate.prepare(.init(values: ["prompt": "x", "ratio": "16:9", "resolution": "4k",
                "duration": -1, "generate_audio": false, "first_frame": .string(file.path), "seed": 88]), capability: videoCap)
            _ = try await crate.submit(video)
            let videoCall = await crateFixture.calls.last!
            c.check(videoCall.arguments.contains("--first-frame") && videoCall.arguments.contains("4k")
                    && videoCall.arguments.contains("duration=-1") && videoCall.arguments.contains("false")
                    && videoCall.arguments.contains("seed=88"), "Crate video roles, case and duration special value retained")
            for values: [String: JSONValue] in [
                ["prompt": "x", "last_frame": .string(file.path)],
                ["prompt": "x", "first_frame": .string(file.path), "reference_images": [.string(file.path)]],
                ["prompt": "x", "resolution": "4K"],
                ["prompt": "x", "duration": 2],
                ["prompt": "x", "reference_images": [.string(file.path), .string(file.path), .string(file.path)]]] {
                await c.rejects("Crate video constraint blocked") {
                    _ = try await crate.prepare(.init(values: values), capability: videoCap)
                }
            }
            let fileImage = try await crate.prepare(.init(values: ["prompt": "x", "images": [.string(file.path)]]), capability: imageCap)
            try Data("next version".utf8).write(to: file)
            await c.rejects("Crate input drift blocked", .inputChanged) { _ = try await crate.submit(fileImage) }
            let id = imageResult.task.taskID
            for (status, ahead, expected) in [(1, 5, GenerationStatus.queued(ahead: 5)), (1, 0, .running),
                                              (3, 0, .failed), (99, 0, .unknown("99"))] {
                await crateFixture.setObservation(["taskInfo": ["task_id": .string(id), "task_status": .number(Double(status)),
                                                               "queue_ahead_count": .number(Double(ahead))]])
                let result = try await crate.query(imageResult.task)
                c.check(result.status == expected, "Crate raw state \(status), queue \(ahead)")
            }
            await crateFixture.setObservation(["taskInfo": ["task_id": .string(id), "task_status": 2,
                "results": [["content": "https://example.test/1.png"], ["content": "https://example.test/2.png"]]]])
            let crateMedia = try await crate.query(imageResult.task)
            c.check(crateMedia.status == .succeeded && crateMedia.artifacts.count == 2, "Crate preserves all outputs")
            await crateFixture.setObservation(["taskInfo": ["task_status": 2, "results": [["content": "file:///tmp/x"]]]])
            let invalidMedia = try await crate.query(imageResult.task)
            c.check(invalidMedia.status == .outputMismatch, "Crate completed nonremote output flagged")
            let registry = try GenerationProviderRegistry([ba, crate])
            _ = try await registry.query(imageResult.task)
            c.check(await crateFixture.calls.last?.arguments == ["task", "get", id, "--json"], "registry routes historic task to its own provider")
            await c.rejects("registry rejects missing account", .providerMismatch) { _ = try registry.provider(for: alias) }
            await c.rejects("registry rejects duplicate context") { _ = try GenerationProviderRegistry([ba, ba]) }
            await c.rejects("Crate cannot query BA handle", .providerMismatch) { _ = try await crate.query(submitted.task) }
            let otherEndpoint = try GenerationProviderContext(provider: .crate, endpoint: URL(string: "https://example.test/api")!,
                                                              controlPlane: "i18n-tt")
            let otherCrate = try CrateGenerationAdapter(context: otherEndpoint, directory: root,
                                                        executor: await crateFixture.executor)
            await c.rejects("historic task cannot move to another endpoint", .providerMismatch) {
                _ = try await otherCrate.query(imageResult.task)
            }
            await c.rejects("BA unverified control plane blocked") {
                let context = try GenerationProviderContext(provider: .byteartist, endpoint: GenerationProviderContext.byteartist.endpoint,
                                                             controlPlane: "us")
                _ = try ByteArtistGenerationAdapter(context: context, root: root, executor: await baFixture.executor)
            }
            for (name, output) in [
                ("stopped", ToolProcess.Output(status: 15, stdout: #"{"taskId":"987654321098765432"}"#, stderr: "", stopped: true)),
                ("cut tail", ToolProcess.Output(status: 0, stdout: #"{"taskId":"987654321098765432"}"# + "\n{bad", stderr: ""))] {
                await crateFixture.setSubmission(output)
                let result = try await crate.submit(image)
                c.check(result.task.taskID == id && result.needsQuery, "Crate \(name) retains confirmed ID")
            }
            await crateFixture.setSubmission(.init(status: 1, stdout: "{lost", stderr: "private details"))
            let submitsBefore = await crateFixture.calls.filter(\.submitting).count
            await c.rejects("Crate unknown submit never retried", .submissionUnknown(.crate)) { _ = try await crate.submit(image) }
            c.check(await crateFixture.calls.filter(\.submitting).count == submitsBefore + 1, "Crate unknown submission executes only once")
            await baFixture.setSubmission(.init(status: 1, stdout: "{lost", stderr: "private details"))
            let baSubmits = await baFixture.calls.filter(\.submitting).count
            let freshBA = try await ba.prepare(.init(values: ["prompt": "x"]), capability: uploadCap)
            await c.rejects("BA unknown submit never retried", .submissionUnknown(.byteartist)) {
                _ = try await ba.submit(freshBA)
            }
            c.check(await baFixture.calls.filter(\.submitting).count == baSubmits + 1, "BA unknown submission executes only once")
        } catch { c.check(false, "unexpected fixture failure: \(error)") }
        await adapterProcessChecks(&c, root: root)
        return c.results
    }
    for (ok, label) in results { t.check(ok, label) }
    if live { runGenerationAdapterLiveTests(t) }
}

private actor AdapterGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { continuation = $0; entered = true }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private func adapterProcessChecks(_ c: inout AdapterChecks, root: URL) async {
    do {
        guard let node = LocalToolchain().resolve(.node) else {
            c.check(false, "process boundary requires local Node runtime"); return
        }
        let script = root.appendingPathComponent("capture.js")
        try Data("console.log(JSON.stringify({argv:process.argv.slice(2),cwd:process.cwd()}));".utf8).write(to: script)
        let transport = try GenerationCLITransport(nodePath: node,
                                                   entryPath: script.path, limiter: AsyncWorkLimiter(limit: 1))
        let literal = "$(touch /tmp/forbidden) ' `echo nope`"
        let actual = try await transport.execute(.init(arguments: [literal], environment: ["PATH": "/usr/bin:/bin"],
                                                      directory: root, timeout: 5))
        let object = try JSONValue.decode(jsonText: actual.stdout)
        let cwd = object["cwd"]?.stringValue.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
        c.check(object["argv"] == .array([.string(literal)])
                && cwd?.path == root.standardizedFileURL.resolvingSymlinksInPath().path,
                "real Node transport preserves argv and cwd under restricted PATH: \(object)")
        let stopped = try await ToolProcess.run("/bin/sh", ["-c", "printf '%s\\n' '{\"event\":\"task_created\",\"task_id\":\"known\"}'; exec /bin/sleep 5"],
                                               timeout: 0.15, captureStoppedOutput: true)
        c.check(stopped.stopped && stopped.stdout.contains("known"), "real subprocess timeout preserves accepted output")
        let marker = root.appendingPathComponent("started")
        let cancelTask = Task {
            try await ToolProcess.run("/bin/sh", ["-c",
                "printf '%s\\n' '{\"event\":\"task_created\",\"task_id\":\"known\"}'; /usr/bin/touch \"$1\"; exec /bin/sleep 5", "fixture", marker.path],
                timeout: 10, captureStoppedOutput: true)
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        cancelTask.cancel()
        let cancelled = try await cancelTask.value
        c.check(cancelled.stopped && cancelled.stdout.contains("known"), "real subprocess cancellation preserves accepted output")
        do {
            _ = try await ToolProcess.run("/bin/sleep", ["5"], timeout: 0.05)
            c.check(false, "default timeout still throws")
        } catch ToolProcess.Failure.timeout { c.check(true, "default timeout still throws") }
        let limiter = AsyncWorkLimiter(limit: 1)
        let gate = AdapterGate()
        let holding = Task { try await limiter.withPermit { await gate.hold() } }
        while !(await gate.entered) { try await Task.sleep(for: .milliseconds(10)) }
        let limited = try GenerationCLITransport(nodePath: node,
                                                 entryPath: script.path, limiter: limiter)
        let waiting = Task { try await limited.execute(.init(arguments: [], environment: [:], directory: root, timeout: 5, submitting: true)) }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        do { _ = try await waiting.value; c.check(false, "cancelled permit never starts process") }
        catch is CancellationError { c.check(true, "cancelled permit never starts process") }
        await gate.release()
        try await holding.value
        let next = try await limited.execute(.init(arguments: [], environment: [:], directory: root, timeout: 5))
        c.check(next.status == 0, "cancelled waiter returns process budget")
        let missing = try GenerationCLITransport(nodePath: node, entryPath: "/missing/entry.js", limiter: limiter)
        await c.rejects("missing CLI definitively not submitted", .processNotStarted) {
            _ = try await missing.execute(.init(arguments: [], environment: [:], directory: root, timeout: 1, submitting: true))
        }
        let blockedDirectory = root.appendingPathComponent("capture.js/invalid")
        await c.rejects("invalid cwd definitively not submitted", .processNotStarted) {
            _ = try await limited.execute(.init(arguments: [], environment: [:], directory: blockedDirectory, timeout: 1, submitting: true))
        }
        let slow = root.appendingPathComponent("slow.js")
        try Data("setTimeout(()=>{},5000);".utf8).write(to: slow)
        let queryTransport = try GenerationCLITransport(nodePath: node, entryPath: slow.path, limiter: limiter)
        await c.rejects("query process timeout has resumable adapter error", .timeout) {
            _ = try await queryTransport.execute(.init(arguments: [], environment: [:], directory: root, timeout: 0.1))
        }
    } catch { c.check(false, "process boundary: \(error)") }
}

/// Opt-in read-only CLI verification. A guard rejects every submission invocation.
private func runGenerationAdapterLiveTests(_ t: TestRunner) {
    let env = ProcessInfo.processInfo.environment
    guard let node = env["CLIPSLOTS_ADAPTER_TEST_NODE"], let baEntry = env["CLIPSLOTS_ADAPTER_TEST_BA"],
          let crateEntry = env["CLIPSLOTS_ADAPTER_TEST_CRATE"], let path = env["CLIPSLOTS_ADAPTER_TEST_ROOT"],
          let referenceSource = env["CLIPSLOTS_ADAPTER_TEST_REFERENCE"] else {
        t.check(false, "ADAPTER LIVE requires explicit Node, CLI paths, evidence root and original reference JSON"); return
    }
    let result: String? = smokeAwait {
        do {
            let root = URL(fileURLWithPath: path)
            let limiter = AsyncWorkLimiter(limit: 2)
            let baTransport = try GenerationCLITransport(nodePath: node, entryPath: baEntry, limiter: limiter)
            let crateTransport = try GenerationCLITransport(nodePath: node, entryPath: crateEntry, limiter: limiter)
            let guardedBA: GenerationCLIExecutor = {
                guard !$0.submitting, !$0.arguments.contains("run") else { throw GenerationAdapterError.invalidInput("live verification forbids submission") }
                return try await baTransport.execute($0)
            }
            let guardedCrate: GenerationCLIExecutor = {
                guard !$0.submitting, !$0.arguments.contains("generate") else { throw GenerationAdapterError.invalidInput("live verification forbids submission") }
                return try await crateTransport.execute($0)
            }
            let ba = try ByteArtistGenerationAdapter(root: root.appendingPathComponent("ba"), executor: guardedBA)
            let raw = try JSONValue.decode(jsonText: String(contentsOfFile: referenceSource))
            let original = raw.arrayValue!.first!
            try FileManager.default.createDirectory(at: ba.referenceDirectory, withIntermediateDirectories: true)
            try Data(original["content"]!.stringValue!.utf8).write(to: ba.referenceDirectory.appendingPathComponent("original.md"))
            try await ba.preflight()
            let capabilities = try await ba.discover()
            let selected = capabilities.first(where: { $0.id == original["workflow_id"]?.stringValue })!
            _ = try await ba.prepare(.init(values: ["prompt": "只读适配验证，不执行生成"]), capability: selected)
            let crate = try CrateGenerationAdapter(directory: root.appendingPathComponent("crate"), executor: guardedCrate)
            try await crate.preflight()
            let catalog = try await crate.discover()
            for (id, values) in [
                ("seedream45", ["prompt": JSONValue.string("只读参数检查"), "ratio": "16:9"]),
                ("seedance2-mini", ["prompt": "只读参数检查", "resolution": "720p", "duration": 4, "generate_audio": false]),
                ("seedance2", ["prompt": "只读参数检查", "duration": -1])] {
                let model = catalog.first(where: { $0.id == id })!
                _ = try await crate.prepare(.init(values: values), capability: model)
            }
            let summary: JSONValue = ["baPreflight": true, "baDiscoveryCount": .number(Double(capabilities.count)),
                "baFreshReferenceMatched": true, "cratePreflight": true,
                "crateCapabilityCount": .number(Double(catalog.count)),
                "cratePreparedModels": ["seedream45", "seedance2-mini", "seedance2"],
                "generationSubmitted": false, "guardForbidsSubmission": true]
            try Data(summary.encodedText(pretty: true).utf8).write(to: root.appendingPathComponent("read-only-verification.json"))
            return nil
        } catch { return error.localizedDescription }
    }
    t.check(result == nil, "ADAPTER LIVE real BA/Crate preflight, discovery and preparation: \(result ?? "PASS")")
}
