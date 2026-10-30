import Foundation

/// Deliberately cannot accept arbitrary log messages, URLs, headers or payloads.
/// Business journals retain recovery state; this bounded ring is only telemetry.
public struct AgentRunDiagnostics: Codable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case submission, receipt, status, stream, event, retry, tool, control, terminal
    }
    public enum Outcome: String, Codable, Sendable {
        case started, committed, completed, rejected, failed, cancelled, unknown
    }
    public enum Failure: String, Codable, Sendable {
        case http, transport, malformed, scopeMismatch, storage, expired, toolUnknown, decisionUnknown, cancelled, other
        static func classify(_ error: Error) -> Self {
            if error is CancellationError { return .cancelled }
            if error is URLError { return .transport }
            guard let gateway = error as? AgentGatewayError else { return .other }
            switch gateway {
            case .http: return .http
            case .malformedPayload, .requestTooLarge, .invalidConfiguration: return .malformed
            case .originMismatch: return .scopeMismatch
            case .journalUnavailable, .decisionNotSaved, .decisionStorageUnknown: return .storage
            case .toolRequestExpired: return .expired
            case .toolOutcomeUnknown: return .toolUnknown
            case .decisionOutcomeUnknown: return .decisionUnknown
            case .interrupted: return .transport
            default: return .other
            }
        }
    }
    public struct Record: Codable, Sendable {
        public let sequence: Int
        public let stage: Stage
        public let outcome: Outcome
        public let run: String?
        public let request: String?
        public let event: String?
        public let call: String?
        public let durationMilliseconds: Double?
        public let byteCount: Int?
        public let httpStatus: Int?
        public let retry: Int?
        public let failure: Failure?
    }
    public static let maximumRecords = 128
    public static let maximumExportBytes = 128 * 1024
    public let schemaVersion = 1
    public let scope: String
    public private(set) var records: [Record] = []
    public private(set) var dropped = 0
    private var sequence = 0

    init(binding: AgentRunBinding) {
        scope = AgentGatewayJournalStore.digest((try? JSONEncoder().encode(binding)) ?? Data())
    }

    mutating func append(stage: Stage, outcome: Outcome, run: String? = nil,
                         request: String? = nil, event: String? = nil, call: String? = nil,
                         elapsed: TimeInterval? = nil, bytes: Int? = nil,
                         status: Int? = nil, retry: Int? = nil, failure: Failure? = nil) {
        func token(_ value: String?) -> String? {
            value.map { AgentGatewayJournalStore.digest(Data($0.utf8)) }
        }
        sequence += 1
        records.append(.init(sequence: sequence, stage: stage, outcome: outcome,
            run: token(run), request: token(request), event: token(event), call: token(call),
            durationMilliseconds: elapsed.flatMap {
                $0.isFinite ? (min(86_400, max(0, $0)) * 1_000).rounded() : nil
            },
            byteCount: bytes.map { min(1_073_741_824, max(0, $0)) },
            httpStatus: status.flatMap { (-1...599).contains($0) ? $0 : nil },
            retry: retry.map { min(1_000, max(0, $0)) }, failure: failure))
        if records.count > Self.maximumRecords {
            dropped += records.count - Self.maximumRecords
            records.removeFirst(records.count - Self.maximumRecords)
        }
    }

    /// Encoding telemetry never reads business journals or invokes a provider.
    public func export() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maximumExportBytes else { throw AgentGatewayError.requestTooLarge }
        return bytes
    }
}
