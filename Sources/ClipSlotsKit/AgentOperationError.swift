import Foundation

/// Shared validation failure for Agent, canvas and workflow operations.
public struct AgentOperationError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
