import Foundation
import ClipSlotsKit

func runAgentArtifactResourceTests(_ t: TestRunner) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipslots-resource-storage-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let repository = try AgentArtifactRepository(directory: root)
        let key = try AgentArtifactKey(projectID: "fixture", canvasID: "fixture", path: "page.html")
        let conversation = UUID()
        let projection = try AgentArtifactPageData(revision: .init(messageSequence: 1, partIndex: 0),
                                                   toolInput: [:], toolResult: [:])
        let update = AgentArtifactUpdate(key: key, revision: 1, content: Data("<p>fixture</p>".utf8),
            pageProjection: projection, pageProjectionConversationID: conversation, pageResourceURI: "ui://tapnow/previs@v3")
        let stored = try repository.merge(update)
        t.equal(try AgentArtifactRepository(directory: root).record(for: key)?.pageResourceURI,
                "ui://tapnow/previs@v3", "resource identity survives independent repository restart")
        t.equal(stored.pageProjectionConversationID, conversation, "resource identity retains native conversation owner")
        let bytes = try JSONEncoder().encode(stored)
        var legacy = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
        legacy.removeValue(forKey: "pageResourceURI")
        let decoded = try JSONDecoder().decode(AgentArtifactRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        t.check(decoded.pageResourceURI == nil && decoded.pageProjection == projection,
                "legacy snapshot without resource identity preserves old projection")
        t.expectThrows("same artifact revision cannot change existing resource identity") {
            _ = try repository.merge(.init(key: key, revision: 1, pageProjection: projection,
                pageProjectionConversationID: conversation, pageResourceURI: "ui://tapnow/animatic@v1"))
        }
        t.equal(try repository.record(for: key), stored, "resource identity conflict preserves exact prior snapshot")
        let base: JSONValue = ["artifactID": "fixture", "path": "page.html", "revision": 1,
            "pageProjection": try JSONValue.decode(jsonText: String(decoding: JSONEncoder().encode(projection), as: UTF8.self))]
        for invalid: JSONValue in [true, .null, "https://example.com", "ui://other/previs@v3"] {
            var fields = base.objectValue ?? [:]; fields["pageResourceURI"] = invalid
            t.expectThrows("gateway rejects malformed resource identity") {
                _ = try AgentArtifactGatewayPayload.update(.object(fields), scope: key.scope, conversationID: conversation)
            }
        }
        t.expectThrows("resource identity cannot arrive without a native projection owner") {
            _ = try repository.merge(.init(key: key, revision: 2, pageResourceURI: "ui://tapnow/previs@v3"))
        }
        _ = try repository.merge(.init(key: key, revision: 2, content: Data("<p>new</p>".utf8)))
        t.check(try repository.record(for: key)?.pageResourceURI == nil, "higher content revision clears old resource identity")
        let tombstone = try repository.delete(key, revision: 3)
        t.check(tombstone.pageResourceURI == nil && tombstone.pageProjection == nil,
                "deletion does not retain page resource authority")
    } catch { t.check(false, "resource storage fixture: \(error)") }
}
