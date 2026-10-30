import Foundation
@testable import ClipSlotsKit

func runAgentToolMessageHistoryTests(_ t: TestRunner) {
    let call = AgentToolCall(id: "same-call-id", name: "fixture", argumentsJSON: "{}")
    let scopes = ["user", "app-reply:first", "app-reply:second"].map {
        AgentExecutionScope(sessionID: "session", projectID: "project", turnID: $0)
    }
    let assistants = scopes.enumerated().map {
        AgentMessage(role: .assistant, content: "", toolCalls: [call],
                     runID: "run-\($0.offset)", executionScope: $0.element)
    }
    func result(_ assistant: AgentMessage, content: String, executionID: String? = nil,
                failed: Bool = false) -> AgentMessage {
        .init(role: .tool, content: content, toolCallId: call.id, toolName: call.name, isFailure: failed,
              runID: assistant.runID, executionScope: assistant.executionScope,
              toolOrigin: .init(assistantID: assistant.id, runID: assistant.runID,
                                scope: assistant.executionScope, executionID: executionID))
    }
    let results = assistants.enumerated().map { result($0.element, content: "result-\($0.offset)") }
    // Results can arrive late, in reverse order, after every assistant.
    let history = assistants + results.reversed()
    let index = AgentToolMessageHistory.resultIndices(history)
    for (ordinal, assistant) in assistants.enumerated() {
        t.equal(index[assistant.id]?[call.id].map { history[$0].content }, "result-\(ordinal)",
                "run/scope/assistant selects original result despite repeated call ID and reverse delivery")
        let replay = result(assistant, content: "replacement")
        t.equal(AgentToolMessageHistory.matchingIndex(replay, in: history), index[assistant.id]?[call.id],
                "duplicate replay only merges its original execution")
    }
    let interrupted = result(assistants[2], content: #"{"error_code":"interrupted"}"#, failed: true)
    var pending = [assistants[0], results[0], assistants[2], interrupted]
    t.equal(AgentToolMessageHistory.resultIndices(pending)[assistants[2].id]?[call.id], 3,
            "original success cannot settle a stopped reply with the same call ID")
    let final = result(assistants[2], content: "durable completion", executionID: "execution")
    t.equal(AgentToolMessageHistory.matchingIndex(final, in: pending), 3,
            "durable receipt upgrades its own interrupted placeholder")
    pending[3] = final
    pending.append(interrupted)
    t.equal(AgentToolMessageHistory.resultIndices(pending)[assistants[2].id]?[call.id], 3,
            "late interrupted projection cannot hide a known completion")
    t.equal(AgentToolMessageHistory.merging(interrupted, preserving: final), final,
            "late unknown hydration cannot overwrite a known result")
    let replacement = AgentToolMessageHistory.merging(final, preserving: interrupted)
    t.equal(replacement.id, interrupted.id, "receipt reconciliation retains original message identity")
    t.equal(replacement.createdAt, interrupted.createdAt, "receipt reconciliation retains original message creation time")
    let conflicting = result(assistants[2], content: "another execution", executionID: "alien")
    t.check(AgentToolMessageHistory.matchingIndex(conflicting, in: pending) == nil,
            "different execution identity is never substituted for the completed one")
    let foreign = AgentMessage(role: .tool, content: "foreign", toolCallId: call.id, toolName: call.name,
        toolOrigin: .init(assistantID: assistants[0].id, runID: assistants[1].runID, scope: scopes[1]))
    t.check(AgentToolMessageHistory.resultIndices(assistants + [foreign]).isEmpty,
            "scope/run mismatch cannot project a tool result under an unrelated assistant")

    let oldA = AgentMessage(role: .assistant, content: "", toolCalls: [call])
    let oldB = AgentMessage(role: .assistant, content: "", toolCalls: [call])
    let oldResultA = AgentMessage(role: .tool, content: "legacy-A", toolCallId: call.id)
    let oldResultB = AgentMessage(role: .tool, content: "legacy-B", toolCallId: call.id)
    let legacy = [oldA, oldResultA, oldB, oldResultB]
    let oldIndex = AgentToolMessageHistory.resultIndices(legacy)
    t.equal(oldIndex[oldA.id]?[call.id], 1, "legacy sequential transcript pairs first result by position")
    t.equal(oldIndex[oldB.id]?[call.id], 3, "legacy sequential transcript pairs second result by position")
    t.check(AgentToolMessageHistory.resultIndices([oldResultA, oldA, oldB]).isEmpty,
            "ambiguous legacy result before multiple assistants is preserved without fabricated pairing")
    t.equal(AgentToolMessageHistory.resultIndices([oldResultA, oldA])[oldA.id]?[call.id], 0,
            "single legacy pre-assistant result remains readable")
    t.check(AgentToolMessageHistory.matchingIndex(oldResultA, in: [oldResultB]) == nil,
            "untagged hydration never replaces another row by call ID")
    do {
        let decoded = try JSONDecoder().decode([AgentMessage].self, from: JSONEncoder().encode(history))
        t.equal(decoded, history, "message provenance persists byte-equivalent values")
        let oldDecoded = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(oldA))
        t.check(oldDecoded.runID == nil && oldDecoded.executionScope == nil && oldDecoded.toolOrigin == nil,
                "pre-provenance records decode without inventing run or scope")
        let body = AgentService.requestBody(history: history, config: .init(), tools: [], stream: false)
        let wire = try body.encodedText()
        t.check(!wire.contains("toolOrigin") && !wire.contains("executionScope") && !wire.contains("runID"),
                "local message identities never alter provider message protocol")
        t.equal(body["messages"]?.arrayValue?.filter { $0["tool_call_id"] == "same-call-id" }.count, 3,
                "all original provider call IDs remain unchanged on the wire")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipslots-tool-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binding = AgentRunBinding(sessionID: "session", projectID: "project", canvasID: "project")
        let endpoint = URL(string: "http://127.0.0.1:19191/v1")!
        let store = AgentGatewayJournalStore(baseURL: endpoint, binding: binding, root: root)
        var journal = try store.load()
        journal.messages = history
        try store.save(journal)
        t.equal(try AgentGatewayJournalStore(baseURL: endpoint, binding: binding, root: root).load().messages,
                history, "independent SQLite reader retains every original assistant/result identity")
        let db = try AgentGatewayJournalDatabase(file: store.databaseFile, create: false)
        t.equal(try db.scalar("PRAGMA user_version"), 7, "old readers refuse journal with native message provenance")
        let header = try JSONDecoder().decode(AgentGatewayJournal.self, from: db.value("header")!)
        t.check(header.nativeToolMessagePresence != nil, "journal header fingerprints authoritative message provenance")
        var stripped = results[2]
        stripped.content = ""
        stripped.toolOrigin = nil
        try db.putMessage(3, data: JSONEncoder().encode(stripped))
        t.expectThrows("missing provenance in a schema7 row cannot silently degrade to legacy call-ID matching") {
            _ = try AgentGatewayJournalStore(baseURL: endpoint, binding: binding, root: root).load()
        }
        try db.close()
    } catch { t.check(false, "tool message provenance round trip: \(error)") }
}
