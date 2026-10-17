import Foundation

/// The scope must be the original immutable submission, including on restart.
/// This adapter exposes only confirmed results from the host execution journal.
public final class AgentGatewayRecoverableTools: AgentGatewayToolRecovering, @unchecked Sendable {
    private let executor: AgentJournaledTools
    private let journal: AgentExecutionJournal
    private let scope: AgentExecutionScope

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
        guard specs().contains(where: { $0.name == call.name }) else {
            throw AgentGatewayError.toolOutcomeUnknown
        }
        guard let record = try journal.records(scope: scope).first(where: { $0.callID == call.id }) else {
            return nil
        }
        guard record.scope == scope, record.tool == call.name,
              record.argumentsDigest == CanvasWorkflowSnapshot.digest(Data(call.argumentsJSON.utf8)) else {
            throw AgentGatewayError.malformedPayload
        }
        return record.phase == .completed ? record.result : nil
    }
}
