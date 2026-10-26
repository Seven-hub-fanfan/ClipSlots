import Foundation
import ClipSlotsKit

@MainActor
final class AgentLiveMCPHost {
    let lease: AgentLiveMCPLease
    private weak var context: CanvasAgentContext?
    private let conversationID: UUID
    private let initialTurn: CanvasAgentTurn
    private var cachedTurn: CanvasAgentTurn?
    private var cachedFingerprint: String?
    private var timer: Timer?
    private var proposals: [String: (digest: String, payload: JSONValue)] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var interactions: [AgentInteraction] = []
    private let onInteraction: @Sendable (AgentInteraction) async -> Void

    init(context: CanvasAgentContext, scope: AgentArtifactScope, conversationID: UUID, snapshotID: UUID, root: URL,
         accessMode: AgentAccessMode = .selectedDirectories,
         onInteraction: @escaping @Sendable (AgentInteraction) async -> Void = { _ in }) throws {
        self.context = context; self.conversationID = conversationID
        initialTurn = CanvasAgentTurn(snapshot: try CanvasAgentSnapshotStore().load(project: scope.projectID, id: snapshotID).graph,
                                      supportsTools: true)
        self.onInteraction = onInteraction
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        lease = .init(directory: directory, token: UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            runID: UUID().uuidString, expiresAt: Date().addingTimeInterval(30 * 60),
            scope: scope, sessionID: conversationID, snapshotID: snapshotID, accessMode: accessMode)
        try AgentLiveMCPMailbox.write(lease, to: directory.appendingPathComponent("lease.json"))
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        tasks.values.forEach { $0.cancel() }; tasks = [:]
        interactions.forEach { $0.invalidate() }; interactions = []
        try? FileManager.default.removeItem(at: lease.directory)
        context?.pendingExternalConnectionCancelled(runID: lease.runID)
    }

    private func poll() {
        guard Date() < lease.expiresAt, context?.isActive == true else { cancel(); return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: lease.directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { cancel(); return }
        for file in files.filter({ $0.pathExtension == "request" }).prefix(8) {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let request = try? AgentLiveMCPMailbox.read(AgentLiveMCPRequest.self,
                    from: file, within: lease.directory),
                  request.id == id, request.token == lease.token, request.deadline > Date(),
                  request.deadline <= lease.expiresAt else { continue }
            guard tasks.count < 8 else {
                try? AgentLiveMCPMailbox.write(JSONValue.object(["ok": false, "error": "本连接调用过多，请稍后重试。"]),
                    to: lease.directory.appendingPathComponent(id.uuidString + ".response"))
                continue
            }
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                defer { self.tasks.removeValue(forKey: id) }
                let response = await self.handle(request)
                guard !Task.isCancelled, Date() < request.deadline, context?.isActive == true else { return }
                try? AgentLiveMCPMailbox.write(response, to: lease.directory.appendingPathComponent(id.uuidString + ".response"))
            }
        }
    }

    private func handle(_ request: AgentLiveMCPRequest) async -> JSONValue {
            let response: JSONValue
            do {
                guard let context, let args = request.arguments.objectValue else { throw AgentCanvasError.staleTarget }
                if request.name == "clipslots_context" {
                    let turn = try freshTurn()
                    return ["ok": true, "read_only": .bool(lease.accessMode == .allDirectoriesReadOnly),
                        "writes_require_native_confirmation": true, "cli_required": false,
                        "project_id": .string(lease.projectID), "canvas_id": .string(lease.canvasID),
                        "session_id": .string(conversationID.uuidString), "live_run_id": .string(lease.runID),
                        "snapshot_id": .string(turn.snapshotID.uuidString), "graph_revision": .string(turn.graphRevision),
                        "expires_at": .string(ISO8601DateFormatter().string(from: lease.expiresAt)),
                        "access_mode": .string(lease.accessMode.rawValue)]
                }
                if request.name != "preview_canvas_mutation", request.name != "canvas_mutation_status" {
                    let snapshotRead = request.name.hasPrefix("canvas_")
                        && !CanvasAgentActionTools.readers.contains(request.name)
                        && !CanvasAgentActionTools.writers.contains(request.name)
                    let turn = snapshotRead ? try freshTurn() : initialTurn
                    let current: @MainActor @Sendable () -> Bool = { [weak self, weak context] in
                        guard let self, let context else { return false }
                        return self.timer != nil && context.isActive && Date() < request.deadline
                            && Date() < self.lease.expiresAt
                    }
                    let approval: @Sendable (AgentInteraction) async -> Void = { [weak self] interaction in
                        guard let self else { interaction.invalidate(); return }
                        await self.addInteraction(interaction)
                    }
                    let actions = try context.actionTools(for: turn, mode: lease.accessMode,
                        automaticApproval: false, conversationID: conversationID,
                        isCurrent: current, onInteraction: approval)
                    let tools = AgentSharedSidebarTools(canvas: actions,
                        library: AgentAccessTools(base: AgentNativeSlotTools(), mode: lease.accessMode),
                        pageID: context.store?.currentPageId, groupID: context.store?.currentSpecialSlotId,
                        automaticApproval: false, isCurrent: current, onInteraction: approval)
                    var input = args
                    if let spec = tools.specs().first(where: { $0.name == request.name }),
                       spec.parameters["properties"]?["snapshot_id"] != nil {
                        input["snapshot_id"] = .string(turn.snapshotID.uuidString)
                    }
                    let result = await tools.execute(call: .init(id: request.id.uuidString,
                        name: request.name, argumentsJSON: try JSONValue.object(input).encodedText()))
                    return try JSONValue.decode(jsonText: result.content)
                }
                guard lease.accessMode != .allDirectoriesReadOnly else { throw AgentOperationError("此连接为只读模式。") }
                let mutationID: String
                let state: String
                if request.name == "preview_canvas_mutation" {
                    guard Set(args.keys) == ["mutation"], let payload = args["mutation"],
                          let id = payload["mutation_id"]?.stringValue, !id.isEmpty else {
                        throw AgentExternalHandoffError.invalidConfiguration
                    }
                    mutationID = id
                    let digest = CanvasWorkflowSnapshot.digest(try CanvasWorkflowSnapshot.jsonData(payload))
                    if let prior = proposals[id], prior.digest != digest {
                        throw AgentOperationError("mutation_id 已用于另一份变更，请使用新的身份。")
                    }
                    guard proposals[id] != nil || proposals.count < 100 else {
                        throw AgentOperationError("本连接变更数量已达上限，请重新连接。")
                    }
                    state = try context.submitMutation(payload, conversationID: conversationID, runID: lease.runID)
                    proposals[id] = (digest, payload)
                } else {
                    guard request.name == "canvas_mutation_status", Set(args.keys) == ["mutation_id"],
                          let id = args["mutation_id"]?.stringValue, let proposal = proposals[id] else {
                        throw AgentExternalHandoffError.invalidConfiguration
                    }
                    mutationID = id
                    state = try context.mutationStatus(proposal.payload, conversationID: conversationID, runID: lease.runID)
                }
                response = ["ok": true, "mutation_id": .string(mutationID), "status": .string(state),
                            "requires_confirmation": .bool(state == "pending")]
            } catch {
                response = ["ok": false, "error": .string(error.localizedDescription)]
            }
            return response
    }

    private func addInteraction(_ interaction: AgentInteraction) async {
        interactions.removeAll { !$0.isPending }
        interactions.append(interaction)
        await onInteraction(interaction)
    }

    /// Keep paginated reads on one identity until the actual canvas or run records change.
    private func freshTurn() throws -> CanvasAgentTurn {
        guard let context, context.isActive, let canvas = context.canvas, let store = context.store else {
            throw AgentCanvasError.staleTarget
        }
        let runs = GenerationRunStore.shared.runs(project: lease.projectID)
        let (graph, _) = CanvasWorkflowCapture.snapshot(canvas: canvas, store: store, runs: runs)
        let snapshot = CanvasAgentSnapshot(graph: graph, runs: runs)
        var normalized = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(snapshot)).objectValue ?? [:]
        var fields = normalized["graph"]?.objectValue ?? [:]
        fields.removeValue(forKey: "snapshotID"); fields.removeValue(forKey: "capturedAt")
        normalized["graph"] = .object(fields)
        let fingerprint = CanvasWorkflowSnapshot.digest(try CanvasWorkflowSnapshot.jsonData(JSONValue.object(normalized)))
        if fingerprint == cachedFingerprint, let cachedTurn { return cachedTurn }
        try CanvasAgentSnapshotStore().save(snapshot)
        let turn = CanvasAgentTurn(snapshot: graph, supportsTools: true)
        cachedFingerprint = fingerprint; cachedTurn = turn
        return turn
    }

    deinit {
        timer?.invalidate()
        tasks.values.forEach { $0.cancel() }
        interactions.forEach { $0.invalidate() }
        try? FileManager.default.removeItem(at: lease.directory)
    }
}
