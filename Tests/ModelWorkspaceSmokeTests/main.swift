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
        } catch { failed.append("unexpected: \(error.localizedDescription)") }
        let result: [String: Any] = ["ok": failed.isEmpty, "passed": passed, "failed": failed]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        exit(failed.isEmpty ? 0 : 1)
    }
}
