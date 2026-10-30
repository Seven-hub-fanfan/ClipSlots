import Foundation
import ClipSlotsKit

func runAgentArtifactPageDataTests(_ t: TestRunner) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-projection-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let key = try AgentArtifactKey(projectID: "projection-project", canvasID: "projection-canvas", path: "app.html")
        let repository = try AgentArtifactRepository(directory: root)
        let conversation = UUID()
        let input: JSONValue = ["prompt": "原文🙂e\u{301}", "media_ref": "transport-private",
                                "nested": [["poster_ref": "poster-private", "enabled": false, "n": .null]]]
        let result: JSONValue = ["summary": "结果🙂", "media_ref": "transport-private", "full": [1, 2, 3]]
        func projection(_ sequence: UInt64, _ part: UInt64, result: JSONValue? = result) throws -> AgentArtifactPageData {
            try .init(revision: .init(messageSequence: sequence, partIndex: part), toolInput: input, toolResult: result)
        }
        let initial = try projection(12, 3)
        let event: JSONValue = ["artifactID": "fixture-app", "path": "app.html", "revision": 5,
                               "content": "<p>fixture</p>", "mimeType": "text/html",
                               "pageProjection": try JSONValue.decode(jsonText: String(decoding: JSONEncoder().encode(initial), as: UTF8.self))]
        let update = try AgentArtifactGatewayPayload.update(event, scope: key.scope, conversationID: conversation)
        let saved = try repository.merge(update)
        t.equal(saved.pageProjection, initial, "source artifact event persists exact projection revision and tool bytes")
        t.equal(try AgentArtifactRepository(directory: root).record(for: key)?.pageProjection, initial,
                "independent repository restores full input and result projection")
        t.expectThrows("unbound event cannot persist page tool data without native conversation") {
            _ = try repository.merge(AgentArtifactGatewayPayload.update(event, scope: key.scope))
        }
        t.expectThrows("another conversation cannot replace same resource projection even with newer sequence") {
            _ = try repository.merge(.init(key: key, revision: 5, pageProjection: projection(99, 0),
                                           pageProjectionConversationID: UUID()))
        }
        t.expectThrows("another run cannot replace same resource tool projection") {
            _ = try repository.merge(.init(key: key, revision: 5, pageProjection: projection(99, 0),
                                           pageProjectionConversationID: conversation, pageProjectionRunID: "another-run"))
        }
        t.equal(try repository.record(for: key), saved, "rejected native owner changes preserve all durable original bytes")
        t.equal(initial.inputParams["arguments"]?["prompt"], input["prompt"], "page projection preserves decomposed user text")
        t.check(initial.inputParams["arguments"]?["media_ref"] == nil
                && initial.inputParams["arguments"]?["nested"]?.arrayValue?.first?["poster_ref"] == nil,
                "page projection recursively excludes source media transport references")
        t.equal(initial.resultParams()?["content"]?.arrayValue?.first?["text"], "结果🙂", "source result text uses summary")
        t.equal(initial.resultParams()?["structuredContent"]?["full"], [1, 2, 3], "structured tool result preserves complete arrays")
        t.equal(initial.resultParams(widgetState: ["counter": 9])?["_meta"]?["tapnow/widgetState"], ["counter": 9],
                "initial tool result carries explicit native widget state")
        t.check(initial.resultParams(widgetState: [1])?["_meta"] == nil, "initial widget metadata rejects array values")
        func apply(_ data: AgentArtifactPageData) throws -> AgentArtifactRecord {
            try repository.merge(.init(key: key, revision: 5, pageProjection: data,
                                       pageProjectionConversationID: conversation))
        }
        let stale = try apply(projection(11, 999))
        t.equal(stale, saved, "lower message sequence cannot replace newer projection despite larger part index")
        let same = try apply(projection(12, 3, result: ["summary": "wrong"]))
        t.equal(same, saved, "equal source revision cannot change tool result or trigger another write")
        let newerPart = try apply(projection(12, 4))
        t.equal(newerPart.pageProjection?.revision.partIndex, 4, "higher part index advances same message projection")
        let newerMessage = try apply(projection(13, 0, result: nil))
        t.equal(newerMessage.pageProjection?.revision.messageSequence, 13, "higher message sequence accepts lower part index")
        t.check(newerMessage.pageProjection?.toolResult == nil, "new input cannot inherit previous tool result")
        t.equal(newerMessage.content, saved.content, "tool projection changes preserve HTML resource bytes")
        let nextResource = try repository.merge(.init(key: key, revision: 6))
        t.check(nextResource.pageProjection == nil, "new HTML resource clears old source projection")
        t.check(!nextResource.hasCurrentContent, "old display bytes never become current tool authority")
        let reset = try repository.merge(.init(key: key, revision: 6, content: Data("<p>new</p>".utf8),
                                               pageProjection: projection(0, 0),
                                               pageProjectionConversationID: conversation))
        t.equal(reset.pageProjection?.revision.messageSequence, 0, "new resource can start fresh source sequence")
        let deleted = try repository.delete(key, revision: 7)
        t.check(deleted.pageProjection == nil, "durable deletion removes tool projection")
        t.equal(try repository.merge(.init(key: key, revision: 6, pageProjection: initial)), deleted,
                "late page data cannot resurrect deleted resource")
        let maximum = try AgentArtifactPageRevision(messageSequence: 9_007_199_254_740_991, partIndex: 9_007_199_254_740_991)
        let encoded = try JSONEncoder().encode(maximum)
        t.equal(try JSONDecoder().decode(AgentArtifactPageRevision.self, from: encoded), maximum,
                "source safe integer boundary roundtrips exactly")
        t.expectThrows("unsafe source message sequence rejected before WebKit") {
            _ = try AgentArtifactPageRevision(messageSequence: 9_007_199_254_740_992, partIndex: 0)
        }
        for value in ["-1", "true", "0.5", "9007199254740992", "\"1\""] {
            let data = Data("{\"message_sequence\":\(value),\"part_index\":0}".utf8)
            t.expectThrows("malformed source sequence cannot bypass Codable validation") {
                _ = try JSONDecoder().decode(AgentArtifactPageRevision.self, from: data)
            }
        }
        t.expectThrows("page projection UTF8 budget protects native notification size") {
            _ = try AgentArtifactPageData(revision: maximum, toolInput: [:],
                                         toolResult: ["summary": .string(String(repeating: "🙂", count: 8192))])
        }
        var deep: JSONValue = .null
        for _ in 0..<33 { deep = ["nested": deep] }
        t.expectThrows("deep source data rejected before recursive public projection") {
            _ = try AgentArtifactPageData(revision: maximum, toolInput: deep, toolResult: nil)
        }
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reset)) as? [String: Any] ?? [:]
        legacy.removeValue(forKey: "pageProjection")
        let restoredLegacy = try JSONDecoder().decode(AgentArtifactRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        t.check(restoredLegacy.pageProjection == nil && restoredLegacy.content == reset.content,
                "legacy artifact snapshot without projection remains readable with original bytes")
    } catch { t.check(false, "page data fixtures: \(error)") }
}
