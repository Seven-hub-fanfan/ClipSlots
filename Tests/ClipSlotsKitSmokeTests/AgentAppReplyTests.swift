import Foundation
@testable import ClipSlotsKit

func runAgentAppReplyTests(_ t: TestRunner) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipslots-reply-smoke-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let scope = try AgentArtifactScope(projectID: "project", canvasID: "canvas")
        let binding = AgentRunBinding(sessionID: "session", projectID: "project", canvasID: "canvas")
        let endpoint = URL(string: "https://gateway.fixture.invalid/original/v1")!
        let authorityJSON: JSONValue = ["schemaVersion": 1,
            "binding": ["sessionID": "session", "projectID": "project", "canvasID": "canvas"],
            "originRunID": "run/汉字+opaque", "artifactID": "app/opaque", "path": "apps/board.html",
            "artifactRevision": 1, "manifestRevision": .string(String(repeating: "a", count: 64)),
            "actions": ["previs_reply"]]
        let authority = try JSONDecoder().decode(AgentAppReplyAuthority.self, from: JSONEncoder().encode(authorityJSON))
        let origin = try AgentAppReplyOrigin(endpoint: endpoint, authority: authority)
        let raw = #"{"reply_id":"55b901e4-0ed9-400f-8a55-562fdf17f233","action":"previs_reply","payload":{"x":1e0,"text":"e\u0301"}}"#
        let submission = try AgentAppReplySubmission(origin: origin, replyJSON: raw)
        t.equal(submission.replyJSON, raw, "reply keeps raw escape and numeric representation")
        t.check(Data(submission.replyJSON.utf8) == Data(raw.utf8), "reply compares exact original UTF8")
        var body = try JSONValue.decode(jsonText: String(decoding: submission.requestBody, as: UTF8.self))
        t.equal(body["replyJSON"], .string(raw), "wire wraps original reply string")
        t.equal(body["originRunID"], "run/汉字+opaque", "opaque origin ID retained")
        let store = try AgentAppReplyStore(directory: root.appendingPathComponent("ledger"))
        let saved = try store.prepare(submission)
        t.equal(saved.state, .saved, "initial reply durable before attempted")
        t.equal(try AgentAppReplyStore(directory: root.appendingPathComponent("ledger")).load(submission.replyID), saved,
                "independent store restores unattempted reply")
        for changed in [raw + " ", raw.replacingOccurrences(of: "1e0", with: "1")] {
            t.expectThrows("same reply UUID cannot change original bytes") {
                _ = try store.prepare(.init(origin: origin, replyJSON: changed))
            }
        }
        let claimed = try store.claim(submission.replyID, expectedAttempt: 0, explicitRetry: false)
        t.equal(claimed.state, .unknown, "committed attempt is unknown until proven accepted")
        t.equal(try store.records(binding: binding), [claimed], "native recovery discovers unknown identity without page UUID")
        t.check(try store.records(binding: .init(sessionID: "foreign", projectID: "project", canvasID: "canvas")).isEmpty,
                "reply recovery never exposes a foreign session")
        t.expectThrows("duplicate initial claim cannot POST twice") {
            _ = try store.claim(submission.replyID, expectedAttempt: 0, explicitRetry: false)
        }
        let retried = try store.claim(submission.replyID, expectedAttempt: 1, explicitRetry: true)
        t.equal(retried.submission.requestBody, submission.requestBody, "explicit retry captures original HTTP bytes")
        t.expectThrows("old retry generation cannot consume newer attempt") {
            _ = try store.claim(submission.replyID, expectedAttempt: 1, explicitRetry: true)
        }
        var receiptJSON: [String: JSONValue] = ["schemaVersion": 1, "appReplySchemaVersion": 1,
            "binding": authorityJSON["binding"]!, "originRunID": .string(authority.originRunID),
            "artifactID": .string(authority.artifactID), "artifactRevision": 1,
            "manifestRevision": .string(authority.manifestRevision), "replyID": .string(submission.replyID),
            "replySHA256": .string(submission.replySHA256), "requestKey": .string(submission.replyID),
            "runID": "child/run+opaque", "acceptedAt": 123, "deduped": false,
            "phase": "completed", "state": "terminal"]
        func receipt() throws -> AgentAppReplyReceipt {
            try JSONDecoder().decode(AgentAppReplyReceipt.self, from: JSONEncoder().encode(JSONValue.object(receiptJSON)))
        }
        let accepted = try store.accept(submission.replyID, receipt: receipt(), readback: true)
        t.equal(accepted.state, .accepted, "receipt proves accepted independently of business state")
        receiptJSON["phase"] = "streaming"; receiptJSON["state"] = "running"
        t.equal(try store.accept(submission.replyID, receipt: receipt(), readback: true), accepted,
                "late running readback cannot undo terminal")
        receiptJSON["phase"] = "failed"; receiptJSON["state"] = "terminal"
        t.expectThrows("conflicting business terminals rejected") {
            _ = try store.accept(submission.replyID, receipt: receipt(), readback: true)
        }
        receiptJSON["runID"] = "different"
        t.expectThrows("reply receipt cannot change accepted run identity") {
            _ = try store.accept(submission.replyID, receipt: receipt(), readback: true)
        }
        t.equal(try store.reject(submission.replyID, attempt: 2, status: 409), accepted,
                "late explicit rejection never erases saved acceptance")
        let artifact: JSONValue = ["artifactID": "app/opaque", "path": "apps/board.html", "revision": 1,
                                  "content": "<p>board</p>", "appReplyAuthority": authorityJSON]
        let update = try AgentArtifactGatewayPayload.update(artifact, scope: scope, binding: binding,
            originRunID: authority.originRunID, gatewayURL: endpoint)
        let repository = try AgentArtifactRepository(directory: root.appendingPathComponent("artifacts"))
        t.equal(try repository.merge(update).appReplyOrigin, origin, "verified artifact persists original gateway authority")
        t.equal(try AgentArtifactRepository(directory: root.appendingPathComponent("artifacts")).record(for: update.key)?.appReplyOrigin,
                origin, "artifact authority survives repository restart")
        t.expectThrows("page-supplied authority without actual transport context rejected") {
            _ = try AgentArtifactGatewayPayload.update(artifact, scope: scope)
        }
        t.expectThrows("artifact authority cannot select foreign run") {
            _ = try AgentArtifactGatewayPayload.update(artifact, scope: scope, binding: binding,
                originRunID: "foreign", gatewayURL: endpoint)
        }
        let different = try AgentAppReplyOrigin(endpoint: URL(string: "https://different.fixture.invalid/v1")!, authority: authority)
        t.expectThrows("same revision cannot replace authority endpoint") {
            _ = try repository.merge(.init(key: update.key, revision: 1, appReplyOrigin: different,
                                          replacesAppReplyAuthority: true))
        }
        t.equal(try repository.merge(.init(key: update.key, revision: 1)).appReplyOrigin, origin,
                "non-authority metadata update keeps current original authority")
        let newer = try repository.merge(.init(key: update.key, revision: 2, content: Data("new".utf8)))
        t.check(newer.appReplyOrigin == nil, "new revision without manifest revokes old page permission")
        t.check(try repository.merge(update).appReplyOrigin == nil, "old artifact event cannot restore revoked authority")
        t.equal(try store.load(submission.replyID)?.receipt?.runID, accepted.receipt?.runID,
                "artifact revocation retains independent accepted reply")
        t.equal(try AgentAppReplyStore(directory: root.appendingPathComponent("ledger")).records(binding: binding), [accepted],
                "restarted recovery keeps accepted reply after page authority revocation")
        // Decode a legacy artifact without the newly optional authority field.
        var encoded = try JSONValue.decode(jsonText: String(decoding: JSONEncoder().encode(newer), as: UTF8.self)).objectValue!
        encoded.removeValue(forKey: "appReplyOrigin")
        t.check(try JSONDecoder().decode(AgentArtifactRecord.self, from: JSONEncoder().encode(JSONValue.object(encoded))).appReplyOrigin == nil,
                "legacy record does not invent manifest authority")
        let largeID = UUID().uuidString.lowercased()
        let largeRaw: JSONValue = ["reply_id": .string(largeID), "action": "previs_reply",
                                  "payload": ["text": .string(String(repeating: "x", count: 30_000))]]
        let large = try AgentAppReplySubmission(origin: origin, replyJSON: largeRaw.encodedText())
        let largeLedger = try AgentAppReplyStore(directory: root.appendingPathComponent("large-ledger"))
        _ = try largeLedger.prepare(large)
        _ = try largeLedger.claim(largeID, expectedAttempt: 0, explicitRetry: false)
        receiptJSON["replyID"] = .string(largeID); receiptJSON["requestKey"] = .string(largeID)
        receiptJSON["replySHA256"] = .string(large.replySHA256); receiptJSON["runID"] = "large-reply-run"
        receiptJSON["phase"] = "completed"; receiptJSON["state"] = "terminal"
        let largeRecord = try largeLedger.accept(largeID, receipt: receipt(), readback: true)
        let journalRoot = root.appendingPathComponent("reply-run")
        let journalStore = AgentGatewayJournalStore(baseURL: endpoint, binding: binding, root: journalRoot)
        var journal = AgentGatewayJournal(origin: endpoint.absoluteString, binding: binding, clientInstanceID: "original-owner")
        journal.runID = largeRecord.receipt?.runID; journal.phase = "streaming"; journal.appReply = largeRecord
        let assistant = UUID()
        journal.messages = [.init(id: assistant, role: .assistant, content: "")]
        journal.currentAssistantID = assistant
        try journalStore.save(journal)
        let initialBytes = journalStore.payloadBytesWritten
        for index in 0..<100 {
            let event = "event-\(index)"
            let digest = AgentGatewayJournalStore.digest(Data(event.utf8))
            journal.messages[0].content += "x"
            journal.ordinal += 1; journal.cursor = event; journal.eventDigests[event] = digest
            try journalStore.saveEvent(journal, eventID: event, digest: digest,
                                       delta: (assistant, "content", "x"))
        }
        let increment = journalStore.payloadBytesWritten - initialBytes
        print("AppReply journal: 100 events, incremental SQLite bound payload bytes \(increment)")
        t.check(increment < 600_000, "large reply body is not duplicated with each stream cursor")
        let independent = AgentGatewayJournalStore(baseURL: endpoint, binding: binding, root: journalRoot)
        let restored = try independent.load()
        t.equal(restored.appReply, largeRecord, "independent reply run journal restores complete immutable acceptance")
        t.equal(restored.messages[0].content, String(repeating: "x", count: 100), "reply run journal restores all stream chunks")
        let database = try AgentGatewayJournalDatabase(file: journalStore.databaseFile, create: false)
        t.equal(try database.scalar("PRAGMA user_version"), 5, "accepted reply run prevents silent downgrade")
        let header = try JSONValue.decode(jsonText: String(decoding: database.value("header")!, as: UTF8.self))
        let storedReply = try database.value("appReply")
        t.check(header["appReply"] == nil && storedReply != nil, "immutable reply has independent authoritative SQLite row")
        // Recover the earlier embedded-header layout without dropping original bytes.
        var embeddedHeader = journal
        embeddedHeader.messages = []; embeddedHeader.eventDigests = [:]; embeddedHeader.tools = [:]
        try database.putValue("header", data: JSONEncoder().encode(embeddedHeader))
        try database.putValue("appReply", data: nil); try database.execute("PRAGMA user_version=4")
        let migration = AgentGatewayJournalStore(baseURL: endpoint, binding: binding, root: journalRoot)
        let embedded = try migration.load()
        t.equal(embedded.appReply, largeRecord, "embedded reply run header migrates without byte changes")
        try migration.save(embedded)
        t.equal(try database.scalar("PRAGMA user_version"), 5, "migrated reply run retains downgrade guard")
        try database.putValue("appReply", data: nil)
        t.expectThrows("missing authoritative reply row cannot fall back to legacy header") {
            _ = try AgentGatewayJournalStore(baseURL: endpoint, binding: binding, root: journalRoot).load()
        }
        try database.close()
        let declaration = AgentToolSpec(name: "local_write_file", description: String(repeating: "native", count: 8000),
            parameters: ["type": "object", "properties": [:]], originLabel: "native-directory")
        let toolContext = AgentAppReplyToolContext(authority: authority, clientInstanceID: "original-owner",
            submissionKey: "original-command", sourceScope: .init(sessionID: binding.sessionID,
                projectID: binding.projectID, turnID: "original-user"),
            declarations: [.init(declaration)], toolLimit: 8)
        let toolUpdate = try AgentArtifactGatewayPayload.update(artifact, scope: scope, binding: binding,
            originRunID: authority.originRunID, gatewayURL: endpoint, toolContext: toolContext)
        let toolRepositoryRoot = root.appendingPathComponent("tool-artifacts")
        let toolRepository = try AgentArtifactRepository(directory: toolRepositoryRoot)
        t.equal(try toolRepository.merge(toolUpdate).appReplyToolContext, toolContext,
                "artifact stores native declarations separately from page reply bytes")
        t.equal(try AgentArtifactRepository(directory: toolRepositoryRoot).record(for: toolUpdate.key)?.appReplyToolContext,
                toolContext, "native original declarations survive independent artifact repository restart")
        t.expectThrows("same artifact revision cannot replace native declarations") {
            _ = try toolRepository.merge(update)
        }
        t.check(try toolRepository.merge(.init(key: toolUpdate.key, revision: 2)).appReplyToolContext == nil,
                "advanced artifact without authority revokes old tool provenance")
        t.equal(try JSONDecoder().decode(JSONValue.self, from: submission.requestBody)["replyJSON"], .string(raw),
                "native context never changes original reply HTTP body")
        let contextualRoot = root.appendingPathComponent("contextual-reply")
        let contextualStore = AgentGatewayJournalStore(baseURL: endpoint, binding: binding, root: contextualRoot)
        var contextual = AgentGatewayJournal(origin: endpoint.absoluteString, binding: binding, clientInstanceID: "original-owner")
        contextual.appReply = largeRecord; contextual.runID = largeRecord.receipt?.runID
        contextual.phase = "streaming"; contextual.appReplyToolContext = toolContext
        let replyScope = AgentAppReplyToolContext.executionScope(binding: binding, replyID: largeID)
        contextual.toolSubmissionKey = replyScope.turnID
        contextual.toolSnapshots = [replyScope.turnID: .init(instanceID: UUID(), scope: replyScope,
                                                            declarations: toolContext.declarations)]
        contextual.toolNames = [declaration.name]; contextual.allowsTools = true; contextual.toolLimit = 8
        contextual.messages = [.init(id: assistant, role: .assistant, content: "")]
        contextual.currentAssistantID = assistant
        try contextualStore.save(contextual)
        let contextInitialBytes = contextualStore.payloadBytesWritten
        for index in 0..<100 {
            let event = "context-event-\(index)", digest = AgentGatewayJournalStore.digest(Data("context-\(index)".utf8))
            contextual.messages[0].content += "x"
            contextual.ordinal += 1; contextual.cursor = event; contextual.eventDigests[event] = digest
            try contextualStore.saveEvent(contextual, eventID: event, digest: digest, delta: (assistant, "content", "x"))
        }
        let contextIncrement = contextualStore.payloadBytesWritten - contextInitialBytes
        print("AppReply tools journal: 100 events, incremental SQLite bound payload bytes \(contextIncrement)")
        t.check(contextIncrement < 200_000, "48k original declarations and 30k reply are not copied per event")
        let contextReloaded = try AgentGatewayJournalStore(baseURL: endpoint, binding: binding, root: contextualRoot).load()
        t.equal(contextReloaded.appReplyToolContext, toolContext, "reply journal restores exact original native provenance")
        t.equal(contextReloaded.toolSnapshots?[replyScope.turnID]?.scope, replyScope,
                "new reply execution scope does not reuse original user turn")
        var changedContext = contextReloaded
        changedContext.toolSnapshots?[replyScope.turnID] = .init(instanceID: UUID(), scope: toolContext.sourceScope,
                                                                 declarations: toolContext.declarations)
        t.expectThrows("reply authorization cannot persist original user execution scope") {
            try contextualStore.save(changedContext)
        }
        let contextDB = try AgentGatewayJournalDatabase(file: contextualStore.databaseFile, create: false)
        t.equal(try contextDB.scalar("PRAGMA user_version"), 6, "native App declaration provenance prevents reader downgrade")
        let contextHeader = try JSONValue.decode(jsonText: String(decoding: contextDB.value("header")!, as: UTF8.self))
        t.check(contextHeader["appReplyToolContext"] == nil
                && contextHeader["nativeToolContextRows"] == ["appReplyTools"],
                "reply tool provenance has independent authoritative row with presence marker")
        try contextDB.putValue("appReplyTools", data: nil)
        t.expectThrows("missing native declaration row fails closed without silently reducing capabilities") {
            _ = try AgentGatewayJournalStore(baseURL: endpoint, binding: binding, root: contextualRoot).load()
        }
        try contextDB.close()
        let corrupt = try AgentGatewayJournalDatabase(file: store.file, create: false)
        body = ["submission": ["foreign": true]]
        try corrupt.putValue("reply:" + submission.replyID, data: JSONEncoder().encode(body))
        t.expectThrows("corrupt authoritative reply record fails without legacy fallback") {
            _ = try store.load(submission.replyID)
        }
        try corrupt.close()
    } catch { t.check(false, "APP REPLY fixture setup: \(error)") }
}
