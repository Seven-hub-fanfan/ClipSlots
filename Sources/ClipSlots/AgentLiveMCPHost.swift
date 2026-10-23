import Foundation
import ClipSlotsKit

@MainActor
final class AgentLiveMCPHost {
    let lease: AgentLiveMCPLease
    private weak var context: CanvasAgentContext?
    private let conversationID: UUID
    private var timer: Timer?
    private var proposals: [String: (digest: String, payload: JSONValue)] = [:]

    init(context: CanvasAgentContext, scope: AgentArtifactScope, conversationID: UUID, snapshotID: UUID, root: URL) throws {
        self.context = context; self.conversationID = conversationID
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        lease = .init(directory: directory, token: UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            runID: UUID().uuidString, expiresAt: Date().addingTimeInterval(30 * 60),
            scope: scope, sessionID: conversationID, snapshotID: snapshotID)
        try AgentLiveMCPMailbox.write(lease, to: directory.appendingPathComponent("lease.json"))
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func cancel() {
        timer?.invalidate(); timer = nil
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
            let response: JSONValue
            do {
                guard let context, let args = request.arguments.objectValue else { throw AgentCanvasError.staleTarget }
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
            try? AgentLiveMCPMailbox.write(response,
                to: lease.directory.appendingPathComponent(id.uuidString + ".response"))
        }
    }

    deinit {
        timer?.invalidate()
        try? FileManager.default.removeItem(at: lease.directory)
    }
}
