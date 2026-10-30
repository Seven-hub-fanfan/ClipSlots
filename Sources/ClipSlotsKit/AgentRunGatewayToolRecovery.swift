import Foundation

/// The scope must be the original immutable submission, including on restart.
/// This adapter exposes only confirmed results from the host execution journal.
public final class AgentGatewayRecoverableTools: AgentGatewayScopedToolRecovering, @unchecked Sendable {
    private let executor: AgentJournaledTools
    private let journal: AgentExecutionJournal
    private let scope: AgentExecutionScope
    public var executionScope: AgentExecutionScope { scope }

    public init(base: AgentToolExecuting, journal: AgentExecutionJournal, scope: AgentExecutionScope) {
        executor = AgentJournaledTools(base: base, journal: journal, scope: scope)
        self.journal = journal
        self.scope = scope
    }

    public func specs() -> [AgentToolSpec] { executor.specs() }

    public func execute(call: AgentToolCall) async -> AgentToolResult {
        await executor.execute(call: call)
    }

    public func recoveredResult(call: AgentToolCall) async throws -> AgentToolResult? {
        try await recoveredResult(call: call, scope: scope)
    }

    public func recoveredResult(call: AgentToolCall, scope original: AgentExecutionScope) async throws -> AgentToolResult? {
        guard original.sessionID == scope.sessionID, original.projectID == scope.projectID else {
            throw AgentGatewayError.originMismatch
        }
        // Reading a confirmed receipt is distinct from executing a currently
        // enabled tool. Rebinding/removing that tool must not lose the receipt.
        guard let record = try journal.records(scope: original).first(where: { $0.callID == call.id }) else {
            return nil
        }
        guard record.scope == original, record.tool == call.name,
              record.argumentsDigest == CanvasWorkflowSnapshot.digest(Data(call.argumentsJSON.utf8)) else {
            throw AgentGatewayError.malformedPayload
        }
        return record.phase == .completed ? record.result : nil
    }
}
