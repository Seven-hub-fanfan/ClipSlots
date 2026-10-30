import Foundation
import CryptoKit
import Darwin
import SQLite3

/// Byte lengths make missing or truncated child chunks a recovery failure.
private struct AgentGatewayTaskEntryRow: Codable {
    let entry: AgentTaskSubagentProjection.Entry
    let textBytes: [String: Int]
}

private struct AgentGatewayTaskPresenceRow: Codable {
    let receiptCount: Int
    let receiptFingerprint: Data
}

private struct AgentGatewayToolOriginPresence: Codable {
    struct Execution: Codable {
        let origin: AgentToolMessageOrigin
        let resultMessageID: UUID?
    }
    var messages: [String: AgentToolMessageOrigin] = [:]
    var executions: [String: Execution] = [:]
}

/// Durable session state, not a rebuildable cache. Each event and its cursor,
/// message delta and tool reservation share one SQLite transaction.
final class AgentGatewayJournalStore {
    let file: URL // Legacy v1 snapshot; retained unchanged after migration.
    let databaseFile: URL
    let origin: String
    let binding: AgentRunBinding
    private let root: URL
    private var database: AgentGatewayJournalDatabase?
    private var revision: Int64?
    private var rows: [String: Data] = [:]
    private var texts: [Int: (content: String, reasoning: String?)] = [:]
    private var taskTexts: [String: String] = [:]
    private var steerBodies: [String: AgentGatewaySteerSubmission] = [:]
    private var decisionCache: [String: AgentGatewayDecisionRecord] = [:]
    private var legacyDecisionCache: [String: AgentGatewayLegacyDecisionRecord] = [:]
    private var taskReceiptCount = 0
    private var taskReceiptFingerprint = Data(repeating: 0, count: 32)
    private var cursor: String?
    private var ordinal = 0
    private(set) var payloadBytesWritten: UInt64 = 0
    #if DEBUG
    /// Explicit injection only in a linked isolated test process. Release has
    /// neither an environment switch nor a callback for crash injection.
    var testBoundary: ((String) -> Void)?
    var testQuotaBytes: Int64?
    #endif

    private func boundary(_ name: String) {
        #if DEBUG
        testBoundary?(name)
        #endif
    }

    private var quotaBytes: Int64 {
        #if DEBUG
        return testQuotaBytes ?? (512 * 1024 * 1024)
        #else
        return 512 * 1024 * 1024
        #endif
    }

    var storageFile: URL {
        FileManager.default.fileExists(atPath: databaseFile.path) ? databaseFile : file
    }

    init(baseURL: URL, binding: AgentRunBinding, root: URL) {
        self.root = root
        self.binding = binding
        origin = baseURL.absoluteString
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedBinding = (try? encoder.encode(binding)) ?? Data()
        let digest = Self.digest(Data(origin.utf8) + encodedBinding)
        file = root.appendingPathComponent("gateway-\(digest).json")
        databaseFile = root.appendingPathComponent("gateway-\(digest).sqlite3")
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validate(_ journal: AgentGatewayJournal, usingCache: Bool = true) throws {
        guard journal.schemaVersion == 1, journal.origin == origin, journal.binding == binding,
              !journal.clientInstanceID.isEmpty, journal.ordinal >= 0,
              journal.contextUsage?.snapshot.map({ $0.conversationID == binding.sessionID }) ?? true,
              journal.messages.allSatisfy({
                  $0.content.utf8.count <= 128 * 1024 * 1024 &&
                  ($0.reasoning?.utf8.count ?? 0) <= 128 * 1024 * 1024
              }),
              journal.taskSubagents?.entries.allSatisfy({
                  if case .subagent(let child) = $0.content {
                      return child.text.utf8.count <= 8_388_608 && child.timeline.count <= 2048
                          && child.tools.count <= 1024
                  }
                  return true
              }) ?? true,
              journal.cursor.map({ journal.eventDigests[$0] != nil }) ?? true else {
            throw AgentGatewayError.journalUnavailable
        }
        let decisions = journal.decisionRecords ?? [:]
        let messagesByID = Dictionary(journal.messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard messagesByID.count == journal.messages.count else { throw AgentGatewayError.journalUnavailable }
        for message in journal.messages {
            guard let origin = message.toolOrigin else { continue }
            guard message.role == .tool, let callID = message.toolCallId,
                  message.runID == origin.runID, message.executionScope == origin.scope,
                  let assistant = messagesByID[origin.assistantID], assistant.role == .assistant,
                  assistant.runID == origin.runID, assistant.executionScope == origin.scope,
                  assistant.toolCalls.contains(where: {
                      $0.id == callID && (message.toolName == nil || $0.name == message.toolName)
                  }) else { throw AgentGatewayError.journalUnavailable }
        }
        for (id, record) in journal.tools {
            guard let origin = record.messageOrigin else { continue }
            guard origin.executionID == id, id == record.request.executionID,
                  origin.runID == journal.runID, record.resultMessageID != nil,
                  origin.scope == record.submissionKey.flatMap({ journal.toolSnapshots?[$0]?.scope }),
                  let assistant = messagesByID[origin.assistantID], assistant.role == .assistant,
                  assistant.runID == origin.runID, assistant.executionScope == origin.scope,
                  assistant.toolCalls.contains(record.request.call) else { throw AgentGatewayError.journalUnavailable }
            if ["completed", "reported"].contains(record.phase) {
                guard let messageID = record.resultMessageID, let message = messagesByID[messageID],
                      message.toolOrigin == origin, message.toolCallId == record.request.callID,
                      message.content == record.content, message.isFailure == record.isFailure else {
                    throw AgentGatewayError.journalUnavailable
                }
            }
        }
        guard (journal.artifactToolContexts?.count ?? 0) <= 256 else {
            throw AgentGatewayError.journalUnavailable
        }
        for (key, context) in journal.artifactToolContexts ?? [:] {
            try context.validate()
            guard key == context.key, context.authority.binding == binding,
                  context.authority.originRunID == journal.runID,
                  context.clientInstanceID == journal.clientInstanceID else {
                throw AgentGatewayError.journalUnavailable
            }
        }
        if let context = journal.appReplyToolContext {
            try context.validate()
            guard context.authority == journal.appReply?.submission.origin.authority,
                  context.clientInstanceID == journal.clientInstanceID else {
                throw AgentGatewayError.journalUnavailable
            }
            if let key = journal.toolSubmissionKey, let reply = journal.appReply {
                let scope = AgentAppReplyToolContext.executionScope(binding: binding, replyID: reply.submission.replyID)
                guard key == scope.turnID, let snapshot = journal.toolSnapshots?[key],
                      snapshot.scope == scope, snapshot.declarations == context.declarations,
                      journal.toolNames == Set(context.declarations.map(\.name)),
                      journal.toolLimit > 0, journal.toolLimit <= context.toolLimit else {
                    throw AgentGatewayError.journalUnavailable
                }
            }
        }
        if let reply = journal.appReply {
            do {
                try reply.submission.validate()
                guard let receipt = reply.receipt, reply.state == .accepted,
                      receipt.runID == journal.runID, receipt.binding == binding,
                      reply.submission.origin.endpoint.absoluteString == origin else {
                    throw AgentGatewayError.journalUnavailable
                }
                try receipt.validate(for: reply.submission, readback: receipt.state != nil)
            } catch { throw AgentGatewayError.journalUnavailable }
        }
        guard decisions.count <= 128 else { throw AgentGatewayError.journalUnavailable }
        for (id, record) in decisions {
            guard id == record.identity.interactionID, record.identity.binding == binding,
                  record.identity.runID == journal.runID,
                  record.identity.clientInstanceID == journal.clientInstanceID else {
                throw AgentGatewayError.journalUnavailable
            }
            if !usingCache || decisionCache[id] != record { try record.validate() }
        }
        let legacy = journal.legacyDecisionRecords ?? [:]
        guard legacy.count <= 128, legacy.allSatisfy({ id, record in
            id == record.interactionID && record.runID == journal.runID
                && record.expiresAt.isFinite && record.params.objectValue != nil
                && (record.acceptedKey == nil || record.acceptedKey == record.submissionKey)
        }) else { throw AgentGatewayError.journalUnavailable }
    }

    private func toolOriginPresence(_ journal: AgentGatewayJournal) throws -> String {
        var presence = AgentGatewayToolOriginPresence()
        for message in journal.messages {
            if let origin = message.toolOrigin { presence.messages[message.id.uuidString] = origin }
        }
        for (id, record) in journal.tools {
            if let origin = record.messageOrigin {
                presence.executions[id] = .init(origin: origin, resultMessageID: record.resultMessageID)
            }
        }
        return Self.digest(try encode(presence))
    }

    private func legacy() throws -> AgentGatewayJournal {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return AgentGatewayJournal(origin: origin, binding: binding,
                                       clientInstanceID: UUID().uuidString)
        }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AgentGatewayError.journalUnavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= 32_000_000 else { throw AgentGatewayError.journalUnavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let journal = try JSONDecoder().decode(AgentGatewayJournal.self, from: handle.readToEnd() ?? Data())
        try validate(journal, usingCache: false)
        return journal
    }

    func load() throws -> AgentGatewayJournal {
        do {
            steerBodies.removeAll()
            decisionCache.removeAll(); legacyDecisionCache.removeAll()
            database = nil
            revision = nil; rows.removeAll(); texts.removeAll()
            taskTexts.removeAll(); taskReceiptCount = 0
            taskReceiptFingerprint = Data(repeating: 0, count: 32)
            cursor = nil; ordinal = 0
            guard FileManager.default.fileExists(atPath: databaseFile.path) else { return try legacy() }
            let db = try AgentGatewayJournalDatabase(file: databaseFile, create: false)
            try db.execute("BEGIN")
            do {
                let version = try db.scalar("PRAGMA user_version")
                guard [2, 3, 4, 5, 6, 7].contains(version),
                      try db.textScalar("PRAGMA quick_check") == "ok",
                      let data = try db.value("header"),
                      let revisionData = try db.value("revision"),
                      let savedRevision = Int64(String(decoding: revisionData, as: UTF8.self)) else {
                    throw AgentGatewayError.journalUnavailable
                }
                var journal = try JSONDecoder().decode(AgentGatewayJournal.self, from: data)
                // A database is authoritative once installed. Never fall back
                // to the frozen legacy cursor after a database failure.
                for (key, value) in try db.allValues() { rows[key] = value }
                journal.eventDigests = try db.events()
                for (position, metadata) in try db.messages() {
                    guard position == journal.messages.count else { throw AgentGatewayError.journalUnavailable }
                    var message = try JSONDecoder().decode(AgentMessage.self, from: metadata)
                    let content = try db.chunks(position: position, kind: "content")
                    let reasoning = try db.chunks(position: position, kind: "reasoning")
                    guard let body = String(data: content, encoding: .utf8),
                          let thought = String(data: reasoning, encoding: .utf8) else {
                        throw AgentGatewayError.journalUnavailable
                    }
                    message.content = body
                    // nil and an explicitly empty reasoning string differ.
                    if message.reasoning != nil { message.reasoning = thought }
                    else if !reasoning.isEmpty { throw AgentGatewayError.journalUnavailable }
                    journal.messages.append(message)
                    rows["message:\(position)"] = metadata
                    texts[position] = (body, message.reasoning)
                }
                journal.tools = try db.tools()
                for (key, tool) in journal.tools { rows["tool:\(key)"] = try encode(tool) }
                journal.toolSnapshots = try optional("snapshots", db: db)
                journal.artifactUpdates = try optional("artifacts", db: db)
                journal.artifactToolContexts = try optional("artifactTools", db: db)
                journal.appReplyToolContext = try optional("appReplyTools", db: db)
                journal.canvasMutations = try optional("mutations", db: db)
                journal.canvasReadbacks = try optional("readbacks", db: db)
                if let reply: AgentAppReplySnapshot = try optional("appReply", db: db) {
                    guard journal.appReply == nil else { throw AgentGatewayError.journalUnavailable }
                    journal.appReply = reply
                }
                guard version != 5 || journal.appReply != nil else { throw AgentGatewayError.journalUnavailable }
                if version >= 6 {
                    let nativeRows = Set(rows.keys.filter { $0 == "artifactTools" || $0 == "appReplyTools" })
                    guard (version == 7 || !nativeRows.isEmpty),
                          journal.nativeToolContextRows == (nativeRows.isEmpty ? nil : nativeRows) else {
                        throw AgentGatewayError.journalUnavailable
                    }
                }
                if version == 7 {
                    guard journal.nativeToolMessagePresence == (try toolOriginPresence(journal)) else {
                        throw AgentGatewayError.journalUnavailable
                    }
                }
                if let ids: [String] = try optional("decision_index", db: db) {
                    guard ids.count <= 128, Set(ids).count == ids.count,
                          journal.decisionRecords == nil,
                          Set(rows.keys.filter { $0.hasPrefix("decision:") }) == Set(ids.map { "decision:\($0)" }) else {
                        throw AgentGatewayError.journalUnavailable
                    }
                    var records: [String: AgentGatewayDecisionRecord] = [:]
                    for id in ids {
                        guard let record: AgentGatewayDecisionRecord = try optional("decision:\(id)", db: db) else {
                            throw AgentGatewayError.journalUnavailable
                        }
                        records[id] = record
                    }
                    journal.decisionRecords = records
                    decisionCache = records
                } else if rows.keys.contains(where: { $0.hasPrefix("decision:") }) {
                    throw AgentGatewayError.journalUnavailable
                }
                if let ids: [String] = try optional("legacy_decision_index", db: db) {
                    guard ids.count <= 128, Set(ids).count == ids.count,
                          journal.legacyDecisionRecords == nil,
                          Set(rows.keys.filter { $0.hasPrefix("legacy_decision:") }) == Set(ids.map { "legacy_decision:\($0)" }) else {
                        throw AgentGatewayError.journalUnavailable
                    }
                    var records: [String: AgentGatewayLegacyDecisionRecord] = [:]
                    for id in ids {
                        guard let record: AgentGatewayLegacyDecisionRecord = try optional("legacy_decision:\(id)", db: db) else {
                            throw AgentGatewayError.journalUnavailable
                        }
                        records[id] = record
                    }
                    journal.legacyDecisionRecords = records; legacyDecisionCache = records
                } else if rows.keys.contains(where: { $0.hasPrefix("legacy_decision:") }) {
                    throw AgentGatewayError.journalUnavailable
                }
                if let ids: [String] = try optional("steer_index", db: db) {
                    guard ids.count <= 64, Set(ids).count == ids.count else {
                        throw AgentGatewayError.journalUnavailable
                    }
                    var states: [String: AgentGatewaySteerLocalState] = [:]
                    for id in ids {
                        guard let body: AgentGatewaySteerSubmission = try optional("steer_body:\(id)", db: db),
                              let state: AgentGatewaySteerLocalState = try optional("steer_state:\(id)", db: db),
                              body.submissionID == id, body.binding == binding,
                              body.runID == journal.runID,
                              body.clientInstanceID == journal.clientInstanceID,
                              try body.message.id.uuidString == id,
                              body.requestBody.count <= 8 * 1024 * 1024 else {
                            throw AgentGatewayError.journalUnavailable
                        }
                        if let receipt = state.receipt { try body.validate(receipt) }
                        guard !state.eventApplied || state.receipt != nil else {
                            throw AgentGatewayError.journalUnavailable
                        }
                        steerBodies[id] = body; states[id] = state
                    }
                    guard Set(rows.keys.filter { $0.hasPrefix("steer_body:") })
                        == Set(ids.map { "steer_body:\($0)" }),
                          Set(rows.keys.filter { $0.hasPrefix("steer_state:") })
                        == Set(ids.map { "steer_state:\($0)" }) else {
                        throw AgentGatewayError.journalUnavailable
                    }
                    journal.steerSubmissions = steerBodies; journal.steerStates = states
                } else if rows.keys.contains(where: { $0.hasPrefix("steer_body:") || $0.hasPrefix("steer_state:") }) {
                    throw AgentGatewayError.journalUnavailable
                }
                if version >= 3 {
                    guard journal.taskSubagents == nil else { throw AgentGatewayError.journalUnavailable }
                    let entries = try db.taskEntries()
                    let receipts = try db.taskReceipts()
                    if let presence = try db.value("task_presence") {
                        let summary = try JSONDecoder().decode(AgentGatewayTaskPresenceRow.self, from: presence)
                        var restored: [AgentTaskSubagentProjection.Entry] = []
                        for (position, metadata) in entries {
                            guard position == restored.count else { throw AgentGatewayError.journalUnavailable }
                            let row = try JSONDecoder().decode(AgentGatewayTaskEntryRow.self, from: metadata)
                            var entry = row.entry
                            var expectedKinds: Set<String> = []
                            var expectedTextKeys: Set<String> = []
                            rows["task:\(position)"] = metadata
                            if case .subagent(var state) = entry.content {
                                guard state.text.isEmpty else { throw AgentGatewayError.journalUnavailable }
                                state.text = try db.taskChunks(position: position, kind: "body")
                                guard row.textBytes["body"] == state.text.utf8.count,
                                      state.text.utf8.count <= 8_388_608 else { throw AgentGatewayError.journalUnavailable }
                                if !state.text.isEmpty { expectedKinds.insert("body") }
                                taskTexts["\(position):body"] = state.text
                                expectedTextKeys.insert("body")
                                for index in state.timeline.indices {
                                    if case .text(let empty) = state.timeline[index] {
                                        guard empty.isEmpty else { throw AgentGatewayError.journalUnavailable }
                                        let kind = "timeline:\(index)"
                                        let text = try db.taskChunks(position: position, kind: kind)
                                        guard row.textBytes[kind] == text.utf8.count else {
                                            throw AgentGatewayError.journalUnavailable
                                        }
                                        if !text.isEmpty { expectedKinds.insert(kind) }
                                        state.timeline[index] = .text(text)
                                        taskTexts["\(position):\(kind)"] = text
                                        expectedTextKeys.insert(kind)
                                    }
                                }
                                entry.content = .subagent(state)
                            }
                            guard Set(row.textBytes.keys) == expectedTextKeys,
                                  try db.taskTextKinds(position: position) == expectedKinds else {
                                throw AgentGatewayError.journalUnavailable
                            }
                            restored.append(entry)
                        }
                        journal.taskSubagents = try .init(journalEntries: restored, receipts: receipts)
                        guard try db.scalar("SELECT COUNT(*) FROM task_chunks WHERE position < 0 OR position >= \(restored.count)") == 0,
                              summary.receiptCount == receipts.count,
                              summary.receiptFingerprint == journal.taskSubagents!.journalReceiptFingerprint else {
                            throw AgentGatewayError.journalUnavailable
                        }
                        taskReceiptCount = receipts.count
                        taskReceiptFingerprint = summary.receiptFingerprint
                    } else {
                        guard entries.isEmpty, receipts.isEmpty,
                              try db.scalar("SELECT COUNT(*) FROM task_chunks") == 0 else {
                            throw AgentGatewayError.journalUnavailable
                        }
                    }
                }
                try validate(journal, usingCache: false)
                try db.execute("COMMIT")
                database = db; revision = savedRevision
                cursor = journal.cursor; ordinal = journal.ordinal
                return journal
            } catch {
                try? db.execute("ROLLBACK")
                throw error
            }
        } catch { throw AgentGatewayError.journalUnavailable }
    }

    private func optional<T: Decodable>(_ key: String, db: AgentGatewayJournalDatabase) throws -> T? {
        guard let value = try db.value(key) else { return nil }
        return try JSONDecoder().decode(T.self, from: value)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func taskEntryRow(_ entry: AgentTaskSubagentProjection.Entry) throws
        -> (metadata: Data, texts: [(String, String)]) {
        var metadata = entry
        var values: [(String, String)] = []
        if case .subagent(var child) = metadata.content {
            values.append(("body", child.text))
            child.text = ""
            for index in child.timeline.indices {
                if case .text(let text) = child.timeline[index] {
                    values.append(("timeline:\(index)", text))
                    child.timeline[index] = .text("")
                }
            }
            metadata.content = .subagent(child)
        }
        let sizes = Dictionary(uniqueKeysWithValues: values.map { ($0.0, $0.1.utf8.count) })
        return (try encode(AgentGatewayTaskEntryRow(entry: metadata, textBytes: sizes)), values)
    }

    /// A parent-only control checkpoint must not duplicate a long child's
    /// history. Metadata, exact UTF-8 and the receipt ledger all participate;
    /// Unicode canonical equivalence is insufficient for committed bytes.
    private func taskCheckpointUnchanged(_ projection: AgentTaskSubagentProjection?) throws -> Bool {
        guard let projection else { return rows["task_presence"] == nil }
        guard rows["task_presence"] != nil,
              projection.journalReceiptCount == taskReceiptCount,
              projection.journalReceiptFingerprint == taskReceiptFingerprint,
              rows.keys.filter({ $0.hasPrefix("task:") }).count == projection.entries.count else { return false }
        var keys: Set<String> = []
        for (position, entry) in projection.entries.enumerated() {
            let row = try taskEntryRow(entry)
            guard row.metadata == rows["task:\(position)"] else { return false }
            for (kind, value) in row.texts {
                let key = "\(position):\(kind)"
                guard Self.taskBytesEqual(taskTexts[key] ?? "", value) else { return false }
                keys.insert(key)
            }
        }
        return keys == Set(taskTexts.keys)
    }

    /// v2 has no task rows to validate against yet. Apply the same event
    /// append/receipt rules to its embedded projection before upgrading.
    private func validateTaskUpgradeEvent(_ oldHeader: Data, journal: AgentGatewayJournal,
                                          event: (String, String)) throws {
        let old = try JSONDecoder().decode(AgentGatewayJournal.self, from: oldHeader).taskSubagents
        guard let projection = journal.taskSubagents else {
            guard old == nil else { throw AgentGatewayError.journalUnavailable }
            return
        }
        let before = old ?? AgentTaskSubagentProjection()
        guard before.entries.count <= projection.entries.count else { throw AgentGatewayError.journalUnavailable }
        for (position, entry) in before.entries.enumerated() {
            let next = projection.entries[position]
            if case .subagent = next.content {
                guard entry.id == next.id else { throw AgentGatewayError.journalUnavailable }
            }
            let priorTexts = try taskEntryRow(entry).texts
            let nextTexts = Dictionary(uniqueKeysWithValues: try taskEntryRow(next).texts)
            for (kind, text) in priorTexts {
                guard let after = nextTexts[kind], Self.taskIncrement(before: text, after: after) != nil else {
                    throw AgentGatewayError.journalUnavailable
                }
            }
        }
        if let runID = journal.runID, projection.journalReceipt(runID: runID, eventID: event.0) != nil,
           projection.journalReceiptCount == before.journalReceiptCount + 1 {
            guard projection.journalPriorReceiptFingerprint(runID: runID, eventID: event.0)
                == before.journalReceiptFingerprint else { throw AgentGatewayError.journalUnavailable }
        } else {
            guard projection.journalReceiptCount == before.journalReceiptCount,
                  projection.journalReceiptFingerprint == before.journalReceiptFingerprint else {
                throw AgentGatewayError.journalUnavailable
            }
        }
    }

    func save(_ journal: AgentGatewayJournal) throws {
        try commit(journal, event: nil, delta: nil)
    }

    /// The caller has already validated the event against the current run.
    /// Streaming text is written as UTF-8 chunks, never as the growing body.
    func saveEvent(_ journal: AgentGatewayJournal, eventID: String, digest: String,
                   delta: (messageID: UUID, kind: String, text: String)? = nil) throws {
        try commit(journal, event: (eventID, digest), delta: delta)
    }

    private func commit(_ journal: AgentGatewayJournal, event: (String, String)?,
                        delta: (messageID: UUID, kind: String, text: String)?) throws {
        do {
            try validate(journal)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if database == nil {
                if FileManager.default.fileExists(atPath: databaseFile.path) { _ = try load() }
                else {
                    if FileManager.default.fileExists(atPath: file.path) {
                        let prior = try legacy()
                        guard journal.clientInstanceID == prior.clientInstanceID else {
                            throw AgentGatewayError.journalUnavailable
                        }
                    }
                    // Build the complete migrated state under an unreferenced
                    // temporary name. A killed migration leaves v1 usable.
                    let temporary = root.appendingPathComponent(".gateway-migration-\(UUID().uuidString).sqlite3")
                    let db = try AgentGatewayJournalDatabase(file: temporary, create: true)
                    database = db; revision = 0
                    rows.removeAll(); texts.removeAll(); cursor = nil; ordinal = 0
                    taskTexts.removeAll(); taskReceiptCount = 0
                    taskReceiptFingerprint = Data(repeating: 0, count: 32)
                    do {
                        try write(journal, event: nil, delta: nil, db: db)
                        try db.close()
                        database = nil
                        boundary("migration-before-install")
                        guard rename(temporary.path, databaseFile.path) == 0 else {
                            throw AgentGatewayError.journalUnavailable
                        }
                        let directory = open(root.path, O_RDONLY)
                        guard directory >= 0 else { throw AgentGatewayError.journalUnavailable }
                        defer { Darwin.close(directory) }
                        guard fsync(directory) == 0 else { throw AgentGatewayError.journalUnavailable }
                        boundary("migration-after-install")
                        // Reload from the installed database, checking the
                        // same path used by a future process.
                        _ = try load()
                        return
                    } catch {
                        database = nil; revision = nil; rows.removeAll(); texts.removeAll()
                        taskTexts.removeAll(); taskReceiptCount = 0
                        taskReceiptFingerprint = Data(repeating: 0, count: 32)
                        // Leave interrupted migration evidence for diagnosis.
                        throw error
                    }
                }
            }
            guard let db = database else { throw AgentGatewayError.journalUnavailable }
            try write(journal, event: event, delta: delta, db: db)
        } catch {
            // In-memory caches never acknowledge an uncertain transaction.
            database = nil; revision = nil; rows.removeAll(); texts.removeAll()
            taskTexts.removeAll(); taskReceiptCount = 0
            taskReceiptFingerprint = Data(repeating: 0, count: 32)
            throw AgentGatewayError.journalUnavailable
        }
    }

    private func write(_ journal: AgentGatewayJournal, event: (String, String)?,
                       delta: (messageID: UUID, kind: String, text: String)?,
                       db: AgentGatewayJournalDatabase) throws {
        let bytesBefore = db.payloadBytesWritten
        defer { payloadBytesWritten += db.payloadBytesWritten - bytesBefore }
        guard let revision, revision < Int64.max else { throw AgentGatewayError.journalUnavailable }
        let nextRevision = revision + 1
        let reset = journal.ordinal < ordinal || (journal.cursor == nil && cursor != nil)
        var updatedRows = rows
        var updatedTexts = texts
        var updatedSteerBodies = steerBodies
        var updatedTaskTexts = taskTexts
        var updatedReceiptCount = taskReceiptCount
        var updatedReceiptFingerprint = taskReceiptFingerprint
        try db.execute("BEGIN IMMEDIATE")
        do {
            boundary("transaction-begin")
            guard try db.value("revision").map({ Int64(String(decoding: $0, as: UTF8.self)) }) ?? 0 == revision else {
                throw AgentGatewayError.journalUnavailable
            }
            let version = try db.scalar("PRAGMA user_version")
            guard [2, 3, 4, 5, 6, 7].contains(version) else { throw AgentGatewayError.journalUnavailable }
            let upgrading = version == 2
            if upgrading, let event, let oldHeader = updatedRows["header"] {
                try validateTaskUpgradeEvent(oldHeader, journal: journal, event: event)
            }
            if upgrading { try db.createTaskTables() }
            boundary("task-schema-written")
            if reset {
                // Preserve the old generation in the same transaction. In
                // particular, terminal projection cannot erase an unreported
                // tool result or a receipt. No retention deletion is automatic.
                try db.execute("""
                    INSERT INTO archive(revision, kind, identity, payload)
                    SELECT \(revision), 'value', key, payload FROM state;
                    INSERT INTO archive(revision, kind, identity, payload)
                    SELECT \(revision), 'event', id, CAST(digest AS BLOB) FROM events;
                    INSERT INTO archive(revision, kind, identity, payload)
                    SELECT \(revision), 'message', CAST(position AS TEXT), payload FROM messages;
                    INSERT INTO archive(revision, kind, identity, payload)
                    SELECT \(revision), 'chunk', position || ':' || kind || ':' || sequence, body FROM chunks;
                    INSERT INTO archive(revision, kind, identity, payload)
                    SELECT \(revision), 'tool', id, payload FROM tools;
                    INSERT INTO archive(revision, kind, identity, payload)
                    SELECT \(revision), 'task_entry', CAST(position AS TEXT), payload FROM task_entries;
                    INSERT INTO archive(revision, kind, identity, payload)
                    SELECT \(revision), 'task_chunk', position || ':' || kind || ':' || sequence, body FROM task_chunks;
                    INSERT INTO archive(revision, kind, identity, payload)
                    SELECT \(revision), 'task_receipt', id, CAST(digest AS BLOB) FROM task_receipts;
                    DELETE FROM state; DELETE FROM events; DELETE FROM messages;
                    DELETE FROM chunks; DELETE FROM tools;
                    DELETE FROM task_entries; DELETE FROM task_chunks; DELETE FROM task_receipts;
                    """)
                updatedRows.removeAll(); updatedTexts.removeAll()
                updatedSteerBodies.removeAll()
                updatedTaskTexts.removeAll(); updatedReceiptCount = 0
                updatedReceiptFingerprint = Data(repeating: 0, count: 32)
            }
            if let event {
                guard !reset, journal.ordinal == ordinal + 1, journal.cursor == event.0,
                      journal.eventDigests[event.0] == event.1,
                      try db.eventDigest(event.0) == nil else { throw AgentGatewayError.journalUnavailable }
                try db.putEvent(event.0, digest: event.1)
            } else {
                let current = try db.events()
                // General control commits keep the full contract, including
                // fixtures/legacy snapshots that contain several events.
                guard reset || current.keys.allSatisfy({ journal.eventDigests[$0] == current[$0] }) else {
                    throw AgentGatewayError.journalUnavailable
                }
                for (key, digest) in journal.eventDigests where current[key] == nil {
                    try db.putEvent(key, digest: digest)
                }
            }
            boundary("event-written")
            let retainTasks = try event == nil && !reset && !upgrading
                && taskCheckpointUnchanged(journal.taskSubagents)
            if upgrading, !reset, let oldHeader = updatedRows["header"],
               try JSONDecoder().decode(AgentGatewayJournal.self, from: oldHeader).taskSubagents != nil {
                // v2 embeds child bodies and receipts in header. Preserve that
                // exact predecessor before any control replacement or upgrade.
                try db.execute("""
                    INSERT INTO archive(revision,kind,identity,payload)
                    SELECT \(revision), 'value', key, payload FROM state WHERE key='header';
                    """)
            }
            if event == nil, !reset, !upgrading, !retainTasks, updatedRows["task_presence"] != nil {
                // A control checkpoint may replace, reorder, retain or clear
                // display state. Keep its exact predecessor, including
                // unknown children, rather than deleting unresolved history.
                try db.archiveTasks(revision: revision)
            }
            boundary("tasks-archived")
            var header = journal
            header.messages = []; header.eventDigests = [:]; header.tools = [:]
            header.toolSnapshots = nil; header.artifactUpdates = nil
            header.canvasMutations = nil; header.canvasReadbacks = nil
            header.taskSubagents = nil
            header.steerSubmissions = nil; header.steerStates = nil
            header.decisionRecords = nil
            header.legacyDecisionRecords = nil
            header.appReply = nil
            header.artifactToolContexts = nil; header.appReplyToolContext = nil
            let nativeRows = Set((journal.artifactToolContexts == nil ? [] : ["artifactTools"])
                + (journal.appReplyToolContext == nil ? [] : ["appReplyTools"]))
            header.nativeToolContextRows = nativeRows.isEmpty ? nil : nativeRows
            let toolProvenance = version == 7 || journal.messages.contains { $0.toolOrigin != nil }
                || journal.tools.values.contains { $0.messageOrigin != nil }
            header.nativeToolMessagePresence = toolProvenance ? try toolOriginPresence(journal) : nil
            func state(_ key: String, _ data: Data?) throws {
                if data != updatedRows[key] {
                    try db.putValue(key, data: data)
                    updatedRows[key] = data
                }
            }
            try state("header", encode(header))
            try state("snapshots", journal.toolSnapshots.map(encode))
            try state("artifacts", journal.artifactUpdates.map(encode))
            try state("mutations", journal.canvasMutations.map(encode))
            try state("readbacks", journal.canvasReadbacks.map(encode))
            // Immutable reply bytes are written once, independently of each event cursor.
            try state("appReply", journal.appReply.map(encode))
            try state("artifactTools", journal.artifactToolContexts.map(encode))
            if let old = updatedRows["appReplyTools"] {
                guard let context = journal.appReplyToolContext,
                      try JSONDecoder().decode(AgentAppReplyToolContext.self, from: old) == context else {
                    throw AgentGatewayError.journalUnavailable
                }
            }
            try state("appReplyTools", journal.appReplyToolContext.map(encode))
            let decisions = journal.decisionRecords ?? [:]
            guard Set(updatedRows.keys.filter { $0.hasPrefix("decision:") })
                .isSubset(of: Set(decisions.keys.map { "decision:\($0)" })) else {
                throw AgentGatewayError.journalUnavailable
            }
            try state("decision_index", decisions.isEmpty ? nil : encode(decisions.keys.sorted()))
            for (id, record) in decisions {
                if !reset, decisionCache[id] == record { continue }
                if let previous = updatedRows["decision:\(id)"] {
                    let old = try JSONDecoder().decode(AgentGatewayDecisionRecord.self, from: previous)
                    guard old.localID == record.localID, old.identity == record.identity,
                          old.params == record.params, !old.attempted || record.attempted,
                          old.submission == nil || old.submission == record.submission,
                          old.receipt?.state != "resolved" ||
                            (record.receipt?.state == "resolved" && old.receipt?.decision == record.receipt?.decision) else {
                        throw AgentGatewayError.journalUnavailable
                    }
                }
                try state("decision:\(id)", encode(record))
            }
            let legacy = journal.legacyDecisionRecords ?? [:]
            guard Set(updatedRows.keys.filter { $0.hasPrefix("legacy_decision:") })
                .isSubset(of: Set(legacy.keys.map { "legacy_decision:\($0)" })) else {
                throw AgentGatewayError.journalUnavailable
            }
            try state("legacy_decision_index", legacy.isEmpty ? nil : encode(legacy.keys.sorted()))
            for (id, record) in legacy {
                if !reset, legacyDecisionCache[id] == record { continue }
                try state("legacy_decision:\(id)", encode(record))
            }
            boundary("decisions-written")
            if toolProvenance {
                try db.execute("PRAGMA user_version=7")
            } else if journal.appReplyToolContext != nil || journal.artifactToolContexts != nil {
                try db.execute("PRAGMA user_version=6")
            } else if journal.appReply != nil {
                // Older readers must fail closed instead of dropping the accepted identity.
                try db.execute("PRAGMA user_version=5")
            } else if !decisions.isEmpty || !legacy.isEmpty {
                // Pre-decision readers accept only v2/v3. Reject downgrade
                // rather than silently ignoring a durable unknown answer.
                try db.execute("PRAGMA user_version=4")
            }
            let submissions = journal.steerSubmissions ?? [:]
            let steerStates = journal.steerStates ?? [:]
            guard submissions.count <= 64, Set(submissions.keys) == Set(steerStates.keys),
                  Set(updatedSteerBodies.keys).isSubset(of: Set(submissions.keys)) else {
                throw AgentGatewayError.journalUnavailable
            }
            try state("steer_index", submissions.isEmpty ? nil : encode(submissions.keys.sorted()))
            for (id, submission) in submissions {
                if let old = updatedSteerBodies[id] {
                    guard old == submission else { throw AgentGatewayError.journalUnavailable }
                } else {
                    try state("steer_body:\(id)", encode(submission))
                    updatedSteerBodies[id] = submission
                }
                try state("steer_state:\(id)", steerStates[id].map(encode))
            }
            boundary("steers-written")
            try state("task_presence", journal.taskSubagents.map {
                try encode(AgentGatewayTaskPresenceRow(receiptCount: $0.journalReceiptCount,
                                                       receiptFingerprint: $0.journalReceiptFingerprint))
            })
            if let projection = journal.taskSubagents, !retainTasks {
                // Only changed entry metadata is encoded. Growing body and
                // timeline text have independent UTF-8 chunk streams.
                let oldPositions = updatedRows.keys.filter { $0.hasPrefix("task:") }
                guard event == nil || upgrading || oldPositions.count <= projection.entries.count else {
                    throw AgentGatewayError.journalUnavailable
                }
                if oldPositions.count > projection.entries.count {
                    try db.execute("DELETE FROM task_entries WHERE position >= \(projection.entries.count); DELETE FROM task_chunks WHERE position >= \(projection.entries.count)")
                    for key in oldPositions {
                        if let position = Int(key.dropFirst(5)), position >= projection.entries.count {
                            updatedRows[key] = nil
                            updatedTaskTexts = updatedTaskTexts.filter { !$0.key.hasPrefix("\(position):") }
                        }
                    }
                }
                for (position, entry) in projection.entries.enumerated() {
                    let row = try taskEntryRow(entry)
                    if case .subagent = entry.content {
                        let values = row.texts
                        let prior = updatedRows["task:\(position)"].flatMap {
                            try? JSONDecoder().decode(AgentGatewayTaskEntryRow.self, from: $0).entry
                        }
                        let sameEntry = prior?.id == entry.id
                        guard event == nil || upgrading || prior == nil || sameEntry else {
                            throw AgentGatewayError.journalUnavailable
                        }
                        if !sameEntry {
                            try db.execute("DELETE FROM task_chunks WHERE position=\(position)")
                            updatedTaskTexts = updatedTaskTexts.filter { !$0.key.hasPrefix("\(position):") }
                        }
                        for (kind, text) in values {
                            let key = "\(position):\(kind)"
                            let before = updatedTaskTexts[key] ?? ""
                            if !Self.taskBytesEqual(before, text) {
                                let chunk = sameEntry ? Self.taskIncrement(before: before, after: text) : nil
                                guard event == nil || upgrading || !sameEntry || chunk != nil else {
                                    throw AgentGatewayError.journalUnavailable
                                }
                                try db.putTaskText(position, kind: kind, sequence: nextRevision,
                                                   body: chunk ?? Data(text.utf8), replace: chunk == nil)
                                updatedTaskTexts[key] = text
                            }
                        }
                        let validKeys = Set(values.map { "\(position):\($0.0)" })
                        for key in updatedTaskTexts.keys.filter({ $0.hasPrefix("\(position):") && !validKeys.contains($0) }) {
                            guard event == nil || upgrading else { throw AgentGatewayError.journalUnavailable }
                            try db.removeTaskText(position, kind: String(key.dropFirst("\(position):".count)))
                            updatedTaskTexts[key] = nil
                        }
                    } else {
                        // Control checkpoints can reorder or replace entries.
                        guard event == nil || upgrading || !updatedTaskTexts.keys.contains(where: { $0.hasPrefix("\(position):") }) else {
                            throw AgentGatewayError.journalUnavailable
                        }
                        try db.execute("DELETE FROM task_chunks WHERE position=\(position)")
                        updatedTaskTexts = updatedTaskTexts.filter { !$0.key.hasPrefix("\(position):") }
                    }
                    let encoded = row.metadata
                    if updatedRows["task:\(position)"] != encoded {
                        try db.putTaskEntry(position, data: encoded)
                        updatedRows["task:\(position)"] = encoded
                    }
                }
                if let event, !upgrading, !reset {
                    if let runID = journal.runID, let digest = projection.journalReceipt(runID: runID, eventID: event.0),
                       projection.journalReceiptCount == updatedReceiptCount + 1 {
                        guard projection.journalPriorReceiptFingerprint(runID: runID, eventID: event.0) == updatedReceiptFingerprint else {
                            throw AgentGatewayError.journalUnavailable
                        }
                        try db.putTaskReceipt(runID + "\u{0}" + event.0, digest: digest)
                        updatedReceiptCount += 1
                    } else {
                        guard projection.journalReceiptCount == updatedReceiptCount else {
                            throw AgentGatewayError.journalUnavailable
                        }
                        guard projection.journalReceiptFingerprint == updatedReceiptFingerprint else {
                            throw AgentGatewayError.journalUnavailable
                        }
                    }
                } else {
                    let old = try db.taskReceipts()
                    let receipts = projection.journalReceipts
                    guard old.allSatisfy({ receipts[$0.key] == $0.value }) else {
                        throw AgentGatewayError.journalUnavailable
                    }
                    for (key, digest) in receipts where old[key] == nil {
                        try db.putTaskReceipt(key, digest: digest)
                    }
                    updatedReceiptCount = projection.journalReceiptCount
                }
                updatedReceiptFingerprint = projection.journalReceiptFingerprint
            } else if !retainTasks {
                guard event == nil || upgrading || rows["task_presence"] == nil else {
                    throw AgentGatewayError.journalUnavailable
                }
                try db.execute("DELETE FROM task_entries; DELETE FROM task_chunks; DELETE FROM task_receipts")
                updatedRows = updatedRows.filter { !$0.key.hasPrefix("task:") }
                updatedTaskTexts.removeAll(); updatedReceiptCount = 0
                updatedReceiptFingerprint = Data(repeating: 0, count: 32)
            }
            boundary("tasks-written")
            boundary("state-written")
            guard journal.messages.count >= updatedTexts.count else { throw AgentGatewayError.journalUnavailable }
            var usedDelta = false
            for (position, message) in journal.messages.enumerated() {
                var metadata = message
                metadata.content = ""; metadata.reasoning = message.reasoning.map { _ in "" }
                let encoded = try encode(metadata)
                if updatedRows["message:\(position)"] != encoded {
                    try db.putMessage(position, data: encoded)
                    updatedRows["message:\(position)"] = encoded
                }
                let previous = updatedTexts[position]
                if let delta, delta.messageID == message.id {
                    guard ["content", "reasoning"].contains(delta.kind),
                          previous != nil, !usedDelta else { throw AgentGatewayError.journalUnavailable }
                    let before = delta.kind == "content" ? previous!.content : (previous!.reasoning ?? "")
                    let after = delta.kind == "content" ? message.content : (message.reasoning ?? "")
                    guard after.utf8.count == before.utf8.count + delta.text.utf8.count,
                          after.utf8.suffix(delta.text.utf8.count).elementsEqual(delta.text.utf8),
                          delta.kind == "content" ? previous!.reasoning == message.reasoning :
                                                   previous!.content == message.content else {
                        throw AgentGatewayError.journalUnavailable
                    }
                    try db.appendChunk(position, kind: delta.kind, sequence: nextRevision, body: Data(delta.text.utf8))
                    usedDelta = true
                } else {
                    if previous?.content != message.content {
                        try db.replaceChunks(position, kind: "content", sequence: nextRevision, body: Data(message.content.utf8))
                    }
                    if previous?.reasoning != message.reasoning {
                        try db.replaceChunks(position, kind: "reasoning", sequence: nextRevision,
                                             body: Data((message.reasoning ?? "").utf8))
                    }
                }
                updatedTexts[position] = (message.content, message.reasoning)
            }
            guard delta == nil || usedDelta else { throw AgentGatewayError.journalUnavailable }
            boundary("messages-written")
            let oldTools = Set(updatedRows.keys.filter { $0.hasPrefix("tool:") }.map { String($0.dropFirst(5)) })
            guard oldTools.isSubset(of: Set(journal.tools.keys)) else { throw AgentGatewayError.journalUnavailable }
            for (key, record) in journal.tools {
                let data = try encode(record)
                if updatedRows["tool:\(key)"] != data {
                    try db.putTool(key, data: data)
                    updatedRows["tool:\(key)"] = data
                }
            }
            boundary("tools-written")
            try db.putValue("revision", data: Data(String(nextRevision).utf8))
            // A quota failure rolls back the cursor and every corresponding
            // payload. It never evicts unresolved work to make room.
            guard try db.scalar("PRAGMA page_count") * db.scalar("PRAGMA page_size") <= quotaBytes else {
                throw AgentGatewayError.journalUnavailable
            }
            boundary("before-commit")
            try db.execute("COMMIT")
            boundary("after-commit")
            self.revision = nextRevision; self.rows = updatedRows; self.texts = updatedTexts
            self.steerBodies = updatedSteerBodies
            self.decisionCache = journal.decisionRecords ?? [:]
            self.legacyDecisionCache = journal.legacyDecisionRecords ?? [:]
            self.taskTexts = updatedTaskTexts; self.taskReceiptCount = updatedReceiptCount
            self.taskReceiptFingerprint = updatedReceiptFingerprint
            self.cursor = journal.cursor; self.ordinal = journal.ordinal
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    /// Exact UTF-8 prefix comparison in native memory. The fallback preserves
    /// correctness for strings without contiguous storage; normalization or
    /// grapheme equality cannot certify the bytes already committed to disk.
    private static func taskIncrement(before: String, after: String) -> Data? {
        let prefixCount = before.utf8.count, totalCount = after.utf8.count
        guard prefixCount <= totalCount else { return nil }
        if prefixCount == 0 { return Data(after.utf8) }
        if let result = before.utf8.withContiguousStorageIfAvailable({ prefix in
            after.utf8.withContiguousStorageIfAvailable { bytes -> Data? in
                guard memcmp(prefix.baseAddress!, bytes.baseAddress!, prefixCount) == 0 else { return nil }
                return Data(bytes: bytes.baseAddress!.advanced(by: prefixCount), count: totalCount - prefixCount)
            }
        }), let result { return result }
        guard after.utf8.starts(with: before.utf8) else { return nil }
        return Data(after.utf8.dropFirst(prefixCount))
    }

    private static func taskBytesEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.count == rhs.utf8.count && taskIncrement(before: lhs, after: rhs) != nil
    }

    /// Held over async work. A second controller/process cannot create a run
    /// using a stale snapshot for the same service root and binding.
    func acquire() throws -> Int32 {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw AgentGatewayError.journalUnavailable }
        let fd = open(file.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AgentGatewayError.journalUnavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw AgentGatewayError.busy
        }
        return fd
    }

    func release(_ fd: Int32) {
        database = nil
        flock(fd, LOCK_UN)
        Darwin.close(fd)
    }
}
