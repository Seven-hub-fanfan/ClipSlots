import Foundation
import ClipSlotsKit

actor FixtureHTTP: ModelHTTPTransport {
    var replies: [(String, Int)]
    var requests: [URLRequest] = []
    var networkFailure = false
    init(_ replies: [(String, Int)] = []) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if networkFailure { throw URLError(.timedOut) }
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        return (Data(reply.0.utf8), reply.1)
    }
    func fail() { networkFailure = true }
    func count() -> Int { requests.count }
    func lastBody() -> JSONValue? {
        guard let body = requests.last?.httpBody else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: body)
    }
}

actor ConfirmedID {
    var value: String?
    func set(_ value: String) { self.value = value }
}

actor BudgetFixture {
    var active = 0
    var peak = 0
    func request() async throws -> Int {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(30))
        return 1
    }
}

@main struct ModelWorkspaceSmokeTests {
    static func main() async {
        var passed: [String] = [], failed: [String] = []
        func check(_ condition: Bool, _ name: String) {
            if condition { passed.append(name) } else { failed.append(name) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-smoke-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            var profile = ModelProfile(); profile.name = "fixture"; profile.model = "fixture-llm"
            profile.endpoint = "http://127.0.0.1:1/chat/completions"; profile.requiresKey = false
            var bank = ModelQuestionBank(); bank.name = "fixture-bank"
            var question = ModelQuestion(); question.prompt = "只回答 fixture"; question.title = "fixture题"
            bank.questions = [question]
            let models = (0..<14).map { index -> ModelProfile in var p = profile; p.id = "model-\(index)"; return p }
            let run = try ModelEvaluationRun(bank: bank, models: models)
            check(run.cells.count == 14, "14 models form one comparison matrix")
            do { _ = try ModelEvaluationRun(bank: bank, models: models + [profile]); check(false, "15 models rejected") }
            catch { check(true, "15 models rejected") }
            do { _ = try ModelEvaluationRun(bank: bank, models: [models[0], models[0]]); check(false, "duplicate models rejected") }
            catch { check(true, "duplicate models rejected") }
            check(ModelRanking.entries(run: run, kind: .llm).isEmpty, "unscored results never rank")
            var scored = run
            scored.cells[0].state = .succeeded; scored.cells[0].scores = ["response": 80]; scored.cells[0].scoredAt = Date()
            let ranking = ModelRanking.entries(run: scored, kind: .llm)
            check(ranking.count == 1 && ranking[0].total == 80, "actual complete score enters ranking")
            check(ranking[0].scores["motion"] == nil, "not applicable is absent, not zero")
            scored.cells[0].scores = ["beauty": 100]
            check(ModelRanking.entries(run: scored, kind: .llm).isEmpty, "missing applicable score excludes ranking")
            var bad = profile; bad.endpoint = "https://secret:password@example.com/chat"
            check((try? bad.validate()) == nil, "URL credential rejected")
            bad = profile; bad.parameters = ["nested": ["api_key": "fixture-secret"]]
            check((try? bad.validate()) == nil, "nested credentials rejected before persistence")
            bad.cliContext = .crate; bad.cliCapabilityID = "fixture"; bad.cliInputSchema = .object([:])
            check((try? bad.validate()) == nil, "CLI parameters cannot bypass nested credential protection")
            var node = CanvasNode(pageId: "p", groupId: "g", slot: 1, kind: .image, x: 0, y: 0)
            node.modelProfileID = "fixture"; node.modelEvaluationCellID = "cell-fixture"
            let restoredNode = try JSONDecoder().decode(CanvasNode.self, from: JSONEncoder().encode(node))
            check(restoredNode.modelProfileID == node.modelProfileID && restoredNode.modelEvaluationCellID == node.modelEvaluationCellID,
                "canvas API selection and recovery association survive coding")
            let repository = ModelWorkspaceRepository(root: root.appendingPathComponent("store"))
            var doc = ModelWorkspaceDocument(); doc.profiles = [profile]; doc.banks = [bank]; doc.runs = [run]
            let first = try await repository.save(doc, expectedRevision: nil)
            let loaded = try await repository.load()
            check(loaded == first, "model bank config and result snapshots round trip")
            do { _ = try await repository.save(doc, expectedRevision: "stale"); check(false, "stale write rejected") }
            catch { check(true, "stale write rejected") }
            let file = root.appendingPathComponent("store/workspace.json")
            let broken = Data("broken-original".utf8)
            try broken.write(to: file)
            do { _ = try await repository.save(doc, expectedRevision: first.revision); check(false, "corrupt data not overwritten") }
            catch { check(try Data(contentsOf: file) == broken, "corrupt data not overwritten") }
            let transport = FixtureHTTP([(#"{"choices":[{"message":{"content":"fixture output"}}]}"#, 200)])
            let service = ModelEvaluationService(transport: transport)
            let output = try await service.submit(question: question, profile: profile, key: nil, didConfirmTask: { _ in })
            check(output?.text == "fixture output", "chat completion result decoded")
            let body = await transport.lastBody()
            check(body?["stream"] == .bool(false) && body?["model"] == .string("fixture-llm"), "fixed model request has no streaming tools")
            let timeout = FixtureHTTP(); await timeout.fail()
            do {
                _ = try await ModelEvaluationService(transport: timeout).submit(question: question, profile: profile, key: nil, didConfirmTask: { _ in })
                check(false, "timeout marked submission unknown")
            } catch ModelWorkspaceError.submissionUnknown { check(true, "timeout marked submission unknown") }
            check(await timeout.count() == 1, "unknown POST not retried")
            let rejected = FixtureHTTP([(#"{"error":"rejected"}"#, 429)])
            do { _ = try await ModelEvaluationService(transport: rejected).submit(question: question, profile: profile, key: nil, didConfirmTask: { _ in }); check(false, "429 explicitly rejected") }
            catch ModelWorkspaceError.http(429) { check(true, "429 explicitly rejected") }
            var video = profile; video.kind = .video; video.contract = .asyncMedia
            video.asynchronous.queryURL = "http://127.0.0.1:1/tasks/{id}"
            var videoQuestion = question; videoQuestion.kind = .video
            let asyncHTTP = FixtureHTTP([
                (#"{"id":"task/123"}"#, 200), (#"{"status":"running"}"#, 200),
                (#"{"status":"completed","output":{"url":"https://example.com/real.mp4"}}"#, 200)
            ])
            let asyncService = ModelEvaluationService(transport: asyncHTTP)
            let holder = ConfirmedID()
            let pending = try await asyncService.submit(question: videoQuestion, profile: video, key: nil, didConfirmTask: { await holder.set($0) })
            let confirmedID = await holder.value
            check(pending == nil && confirmedID == "task/123", "async task confirmed before polling")
            let queued = try await asyncService.query(profile: video, key: nil, taskID: "task/123")
            let completed = try await asyncService.query(profile: video, key: nil, taskID: "task/123")
            check(queued == nil && completed?.urls == ["https://example.com/real.mp4"], "async running and completed obey output mapping")
            let badOutput = FixtureHTTP([(#"{"status":"completed","unmapped":"https://example.com/guess.mp4"}"#, 200)])
            do { _ = try await ModelEvaluationService(transport: badOutput).query(profile: video, key: nil, taskID: "id"); check(false, "unmapped URLs never guessed") }
            catch { check(true, "unmapped URLs never guessed") }
            let rss = Data("""
            <rss version="2.0"><channel><item><title>AI &amp; model</title><link>https://example.com/a</link>
            <description><![CDATA[<p>Source summary</p>]]></description><pubDate>Tue, 27 Oct 2026 08:00:00 +0000</pubDate></item>
            <item><title>Undated</title><link>https://example.com/b</link></item></channel></rss>
            """.utf8)
            let source = ModelNewsSource(name: "Fixture RSS", url: "https://example.com/feed")
            let news = try ModelNewsService.parse(rss, source: source)
            check(news.count == 2 && news[0].title == "AI & model", "RSS parsed with entities")
            check(news[0].summary == "Source summary" && news[0].publishedAt != nil, "source summary and original publish date separated")
            check(news[1].publishedAt == nil, "undated news never assigned today")
            let atom = Data(#"<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Atom</title><link rel="alternate" href="/article"/><published>2026-10-27T08:00:00.000Z</published><summary>Real summary</summary></entry></feed>"#.utf8)
            let atomNews = try ModelNewsService.parse(atom, source: source)
            check(atomNews.first?.url == "https://example.com/article" && atomNews.first?.publishedAt != nil, "Atom alternate relative link and fractional timestamp")
            let newsService = ModelNewsService(transport: FixtureHTTP([(String(data: rss, encoding: .utf8) ?? "", 200)]))
            let refresh = await newsService.refresh(sources: [source, .init(name: "Offline", url: "https://example.com/offline")])
            check(refresh.items.count == 2 && refresh.errors.count == 1 && refresh.successfulSources.count == 1, "partial source failure preserves successful news")
            let input = root.appendingPathComponent("fixture.txt"); try Data("version1".utf8).write(to: input)
            let ref = ModelReference(path: input.path)
            check(ref.isCurrent, "reference captured with file version")
            try Data("version2-changed".utf8).write(to: input)
            check(!ref.isCurrent, "reference change detected")
            var conflict = bank; conflict.questions[0].conflict = true
            do { _ = try ModelEvaluationRun(bank: conflict, models: [profile]); check(false, "conflicted question blocks evaluation") }
            catch { check(true, "conflicted question blocks evaluation") }
            let catalog = try TapNowModelCatalog.load()
            check(catalog.entries.count == 119 && catalog.counts == ["llm":17, "image":31, "video":57, "audio":14], "bundled complete TapNow catalog has exact type counts")
            check(Set(catalog.entries.map(\.id)).count == 119, "catalog identities unique")
            check(catalog.entries.reduce(0) { $0 + ($1.config["variants"]?.arrayValue?.count ?? 0) } == 155, "all 155 media variants retained")
            check(catalog.entries.filter { $0.visibility == "hidden" }.count == 18, "hidden models retained in catalog")
            check(catalog.entries.allSatisfy { $0.draft().model.isEmpty }, "TapNow gateway IDs never prefilled as upstream IDs")
            let catalogEncoder = JSONEncoder(); catalogEncoder.outputFormatting = .sortedKeys
            let catalogBeforeDisplay = try catalogEncoder.encode(catalog)
            check(catalog.entries.allSatisfy { entry in
                let visible = [entry.presentationName, entry.presentationModel, entry.presentationProvider,
                    entry.presentationDescription, (try? entry.presentationConfig.encodedText()) ?? "", entry.draft().name].joined(separator: "\n")
                return !visible.localizedCaseInsensitiveContains("tapnow")
            }, "all 119 catalog display fields and draft names are neutral")
            check(try catalogEncoder.encode(catalog) == catalogBeforeDisplay,
                "display redaction preserves original catalog identities parameters and references")
            if let branded = catalog.entries.first(where: { $0.model == "tapnow-image-turbo" }) {
                check(branded.presentationName == "图像极速模型" && branded.presentationModel == "builtin-image-turbo"
                    && branded.presentationProvider == "内置服务" && branded.draft().catalogID == branded.id,
                    "neutral aliases retain the original catalog binding")
            }
            var connection = ModelServiceConnection(); connection.name = "shared"; connection.baseURL = "http://127.0.0.1:1/v1"
            connection.requiresKey = false; connection.discoveryURL = "models"; connection.concurrency = 1
            var bound = profile; bound.serviceID = connection.id; bound.endpoint = "chat/completions"
            let snapshot = try ModelHubResolver.resolve(bound, services: [connection])
            connection.baseURL = "http://127.0.0.1:2/v1"; connection.keyAccount = "new-identity"
            let next = try ModelHubResolver.resolve(bound, services: [connection])
            check(snapshot.endpoint == "http://127.0.0.1:1/v1/chat/completions" && next.endpoint == "http://127.0.0.1:2/v1/chat/completions", "connection switch updates next request and leaves old snapshot pinned")
            check(snapshot.keyAccount != next.keyAccount && snapshot.serviceConcurrency == 1, "snapshot keeps credential identity and shared concurrency")
            connection.enabled = false
            check((try? ModelHubResolver.resolve(bound, services: [connection])) == nil, "disabled shared service blocks requests")
            connection.enabled = true
            let discoveryHTTP = FixtureHTTP([(#"{"data":[{"id":"upstream-model"}]}"#,200)])
            let discovered = try await ModelEvaluationService(transport: discoveryHTTP).discover(service: connection, key: nil)
            let discoveryMethod = await discoveryHTTP.requests.first?.httpMethod
            check(discovered.first?.id == "upstream-model" && discoveryMethod == "GET", "model discovery only sends GET")
            for (contract, reply, bodyField) in [
                (ModelAPIContract.responses, #"{"output":[{"type":"message","content":[{"type":"output_text","text":"native"}]}]}"#, "input"),
                (.anthropicMessages, #"{"content":[{"type":"text","text":"native"}]}"#, "messages"),
                (.geminiContent, #"{"candidates":[{"content":{"parts":[{"text":"native"}]}}]}"#, "contents")
            ] {
                var p = profile; p.contract = contract
                let http = FixtureHTTP([(reply, 200)])
                let result = try await ModelEvaluationService(transport: http).submit(question: question, profile: p, key: nil, didConfirmTask: { _ in })
                let nativeBody = await http.lastBody()
                check(result?.text == "native" && nativeBody?[bodyField] != nil, "\(contract.rawValue) request and response follow native contract")
            }
            let function = try ModelTextWire.assistant(try JSONValue.decode(jsonText: #"{"content":[{"type":"tool_use","id":"call1","name":"read","input":{"path":"x"}}]}"#), contract: .anthropicMessages)
            check(function["tool_calls"]?.arrayValue?.first?["function"]?["name"] == "read", "native tool calls convert into existing Agent policy path")
            let imageFile = root.appendingPathComponent("input.png"), videoFile = root.appendingPathComponent("input.mp4"), audioFile = root.appendingPathComponent("input.wav")
            for file in [imageFile,videoFile,audioFile] { try Data("fixture-media".utf8).write(to: file) }
            var mapped = video; mapped.mapping = ModelInputMapping()
            mapped.mapping?.referenceFields = ["firstFrame":"first_frame", "video":"videos", "audio":"audios"]
            mapped.mapping?.parameterFields = ["duration":"duration_s", "aspectRatio":"aspect_ratio", "generateAudio":"generate_audio"]
            var multimodal = videoQuestion
            var imageRef = ModelReference(path: imageFile.path); imageRef.role = "firstFrame"
            multimodal.references = [imageRef, .init(path: videoFile.path), .init(path: audioFile.path)]
            multimodal.nodeParameters = ["duration":5, "aspectRatio":"16:9", "generateAudio":false]
            let multimodalBody = try ModelEvaluationService().input(question: multimodal, profile: mapped)
            check(multimodalBody["first_frame"]?.arrayValue?.count == 1 && multimodalBody["videos"]?.arrayValue?.count == 1 && multimodalBody["audios"]?.arrayValue?.count == 1, "typed image video audio references map to separate wire fields")
            check(multimodalBody["duration_s"] == 5 && multimodalBody["generate_audio"] == false && multimodalBody["aspectRatio"] == nil, "node duration ratio and audio use explicit wire keys")
            mapped.mapping?.referenceFields["audio"] = nil
            check((try? ModelEvaluationService().input(question: multimodal, profile: mapped)) == nil, "unmapped audio input is blocked before POST")
            var sound = profile; sound.kind = .audio; sound.contract = .audioSpeech
            sound.mapping = ModelInputMapping(); sound.mapping?.promptField = "input"; sound.mapping?.parameterFields = ["voice":"voice","speed":"speed"]
            var speechQuestion = question; speechQuestion.kind = .audio; speechQuestion.nodeParameters = ["voice":"alloy","speed":1.2]
            let speechBody = try ModelEvaluationService().input(question: speechQuestion, profile: sound)
            check(speechBody["input"] == .string(question.prompt) && speechBody["voice"] == "alloy" && speechBody["speed"] == 1.2, "speech input voice speed reach native wire fields")
            var legacyDocJSON = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(doc)).objectValue ?? [:]
            legacyDocJSON.removeValue(forKey: "services")
            let legacyDoc = try JSONDecoder().decode(ModelWorkspaceDocument.self, from: JSONEncoder().encode(JSONValue.object(legacyDocJSON)))
            check(legacyDoc.services == nil && legacyDoc.runs == doc.runs, "existing workspace decodes without new fields")
            let seedance = catalog.entries.first { $0.model == "seedance-2.0" }
            multimodal.generationMode = "reference"
            mapped.mapping?.referenceFields["audio"] = "audios"
            check((try? seedance?.validate(question: multimodal, profile: mapped)) != nil, "catalog validates supported multi-reference variant")
            multimodal.nodeParameters?["duration"] = 99
            check((try? seedance?.validate(question: multimodal, profile: mapped)) == nil, "catalog rejects invalid declared duration before submit")
            let budgetFixture = BudgetFixture()
            try await withThrowingTaskGroup(of: Int.self) { group in
                for index in 0..<4 {
                    var p = profile; p.id = "budget-\(index)"; p.serviceID = "budget-shared"; p.serviceConcurrency = 1
                    let snapshot = p
                    group.addTask { try await ModelRequestBudget.shared.withPermit(profile: snapshot) { try await budgetFixture.request() } }
                }
                for try await _ in group {}
            }
            check(await budgetFixture.peak == 1, "transport budget enforces shared concurrency across distinct profiles")
            let syncHTTP = FixtureHTTP([(#"{"result":{"urls":["https://example.com/output.mp4"]}}"#,200)])
            var sync = video; sync.contract = .syncMedia; sync.outputPath = "result.urls"
            let syncOutput = try await ModelEvaluationService(transport: syncHTTP).submit(question: videoQuestion, profile: sync, key: nil, didConfirmTask: { _ in })
            check(syncOutput?.urls == ["https://example.com/output.mp4"], "sync video media uses configured JSON output path")
            check(ModelEvaluationService.validAudio(Data("ID3".utf8) + Data(repeating: 0, count: 24), extension: "mp3"), "binary speech accepts matching audio header")
            check(!ModelEvaluationService.validAudio(Data("<html>error body</html>".utf8), extension: "mp3"), "binary speech rejects HTML error masquerading as audio")
            check((try? ModelProfile.validateURL("https://example.com/deployments/a/chat/completions?api-version=2024-10-21")) != nil, "Azure public API version query supported")
            check((try? ModelProfile.validateURL("https://example.com/models?api_key=secret")) == nil, "credential query never accepted")
            let chatBody: [String: JSONValue] = ["model":"upstream", "messages":[["role":"user","content":"test"]], "stream":true, "stream_options":["include_usage":true]]
            check([ModelAPIContract.responses, .anthropicMessages, .geminiContent].allSatisfy {
                let value = ModelTextWire.body(chatBody, contract: $0); return value["stream"] == nil && value["stream_options"] == nil
            }, "native Agent protocols omit Chat streaming options")
            var target = CanvasNode(pageId:"p", groupId:"target", slot:1, kind:.video, x:0, y:0)
            target.ratio = "16:9"; target.duration = 5; target.generateAudio = true
            let videoSource = CanvasNode(pageId:"p", groupId:"video-source", slot:1, kind:.video, x:0, y:0)
            let audioSource = CanvasNode(pageId:"p", groupId:"audio-source", slot:1, kind:.audio, x:0, y:0)
            let facts: [CanvasWorkflowFacts] = [
                .init(node:target, title:"target", body:"生成视频", bodyRevision:"1"),
                .init(node:videoSource, title:"video", body:"video prompt", bodyRevision:"1", primaryAssetPath:videoFile.path),
                .init(node:audioSource, title:"audio", body:"audio prompt", bodyRevision:"1", primaryAssetPath:audioFile.path)
            ]
            let edges = [CanvasEdge(fromNodeId:videoSource.id,toNodeId:target.id),
                         CanvasEdge(fromNodeId:audioSource.id,toNodeId:target.id)]
            let captured = try ModelCanvasInput.question(node: target, facts: facts, edges: edges)
            check(captured.references.map(\.mediaKind).contains(.video) && captured.references.map(\.mediaKind).contains(.audio),
                "canvas API edges capture actual video and audio instead of CLI image rules")
            check(captured.nodeParameters?["duration"] == 5 && captured.generationMode == "reference", "canvas parameter and reference mode captured together")
            var unavailable = facts; unavailable[1].bodyAvailable = false
            check((try? ModelCanvasInput.question(node: target, facts: unavailable, edges: edges)) == nil, "unknown upstream slot state blocks API capture")
            var generated = facts[0]; generated.node.outputAttachmentIds = ["out"]
            generated.media = [.init(id:"media-out",attachmentID:"out",name:"output.mp4",kind:"video",role:"output",revision:"1",availability:"local")]
            generated.resourcePaths = ["media-out": videoFile.path]
            let clean = try ModelCanvasInput.question(node: generated.node, facts:[generated], edges:[])
            check(clean.references.isEmpty, "previous generated node output is not silently used as a new reference")
            let toolBody: [String: JSONValue] = ["model":"native", "messages":[
                ["role":"assistant", "content":"", "tool_calls":[["id":"t","function":["name":"read","arguments":"{}"]]]]
            ]]
            let nativeToolBody = ModelTextWire.body(toolBody, contract:.anthropicMessages)
            check(nativeToolBody["messages"]?.arrayValue?.first?["content"]?.arrayValue?.count == 1,
                "native tool-only turn omits invalid empty text blocks")
        } catch { failed.append("unexpected: \(error.localizedDescription)") }
        let result: [String: Any] = ["ok": failed.isEmpty, "passed": passed, "failed": failed]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        exit(failed.isEmpty ? 0 : 1)
    }
}
