import Foundation
import Darwin
@testable import ClipSlotsKit

private actor Permission {
    private var checks = 0
    private var revoked = false
    let revokedAfter: Int?
    init(_ limit: Int?) { revokedAfter = limit }
    func validate() throws {
        checks += 1
        if revoked { throw AgentAppReplyError.preflight }
        if let revokedAfter, checks > revokedAfter { throw AgentAppReplyError.preflight }
    }
    func revoke() { revoked = true }
}

private struct PostRevokeTransport: AgentGatewayTransport {
    let permission: Permission
    let network = URLSessionAgentGatewayTransport()
    func send(request: URLRequest) async throws -> AgentGatewayHTTPResponse {
        let result = try await network.send(request: request)
        if request.httpMethod == "POST" { await permission.revoke() }
        return result
    }
    func stream(request: URLRequest) async throws -> AgentHTTPStream {
        try await network.stream(request: request)
    }
}

private struct Config: Decodable {
    let mode: String
    let directory: URL
    let origin: AgentAppReplyOrigin
    let replyJSON: String
    let replyID: String
    let expectedAttempt: UInt64?
    let revokedAfter: Int?
    let revokedAfterPost: Bool?
    let quota: Int64?
    let cancellationMarker: URL?
}

@main private enum Main {
    static func main() async throws {
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        guard path.path.contains("clipslots-app-reply-native-") else { exit(2) }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: path))
        let store = try AgentAppReplyStore(directory: config.directory)
        if let quota = config.quota { store.testQuotaBytes = quota }
        var boundaries = 0
        if config.mode == "crash-claim" || config.mode == "crash-after-claim" {
            store.testBoundary = { boundary in
                if boundary == (config.mode == "crash-claim" ? "rows-written" : "committed") {
                    kill(getpid(), SIGKILL)
                }
            }
        } else if config.mode == "crash-accept" || config.mode == "fail-accept" {
            store.testBoundary = { boundary in
                if boundary == "rows-written" {
                    boundaries += 1
                    if boundaries == 3 {
                        if config.mode == "crash-accept" { kill(getpid(), SIGKILL) }
                        else { store.testQuotaBytes = 0 }
                    }
                }
            }
        }
        let permission = Permission(config.revokedAfter)
        let token = ProcessInfo.processInfo.environment["APP_REPLY_TEST_TOKEN"] ?? ""
        let transport: any AgentGatewayTransport = config.revokedAfterPost == true
            ? PostRevokeTransport(permission: permission) : URLSessionAgentGatewayTransport()
        let client = AgentAppReplyClient(store: store, transport: transport,
                                       credential: { _ in token })
        var outcomeError: AgentAppReplyError?
        var record: AgentAppReplySnapshot?
        do {
            switch config.mode {
            case "snapshot":
                record = try store.load(config.replyID)
            case "prepare":
                record = try store.prepare(.init(origin: config.origin, replyJSON: config.replyJSON))
            case "crash-claim", "crash-after-claim":
                record = try store.claim(config.replyID, expectedAttempt: 0, explicitRetry: false)
                exit(3)
            case "reconcile":
                record = try await client.reconcile(replyID: config.replyID) { try await permission.validate() }
            case "retry":
                record = try await client.retry(replyID: config.replyID,
                    expectedAttempt: config.expectedAttempt ?? 0) { try await permission.validate() }
            case "cancel":
                guard let marker = config.cancellationMarker else { exit(4) }
                let submission = try AgentAppReplySubmission(origin: config.origin, replyJSON: config.replyJSON)
                let task = Task { try await client.submit(submission) { try await permission.validate() } }
                for _ in 0..<500 {
                    if FileManager.default.fileExists(atPath: marker.path) { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard FileManager.default.fileExists(atPath: marker.path) else { exit(5) }
                task.cancel()
                record = try await task.value
            default:
                record = try await client.submit(.init(origin: config.origin, replyJSON: config.replyJSON)) {
                    try await permission.validate()
                }
            }
        } catch let value as AgentAppReplyError { outcomeError = value }
        catch { outcomeError = .preflight }
        if record == nil { record = try? store.load(config.replyID) }
        var result: [String: JSONValue] = ["mode": .string(config.mode),
                                         "errorCode": outcomeError.map { .number(Double($0.rpcError.code)) } ?? .null]
        if let record {
            result["record"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record))
        }
        print(try JSONValue.object(result).encodedText())
    }
}
