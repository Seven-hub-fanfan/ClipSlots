import Foundation
import ClipSlotsKit

@MainActor
final class AgentModelCatalogStore: ObservableObject {
    #if DEBUG
    static var debugCredentials: (@Sendable (URL, Bool) async throws -> String?)?
    #endif
    @Published private(set) var models: [AgentDiscoveredModel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var sourceEndpoint: URL?
    private var sourceGateway = false
    private let credentials: @Sendable (URL, Bool) async throws -> String?

    init(credentials: @escaping @Sendable (URL, Bool) async throws -> String? = { endpoint, gateway in
        let store = gateway ? AgentGatewayPreferences.keychain(url: endpoint) : AgentKeychain.shared
        return try await AgentCredentialAccess.readAPIKey(from: store)
    }) {
        self.credentials = credentials
    }

    func supportsImages(model: String, endpoint: URL?, gateway: Bool) -> Bool {
        endpoint == sourceEndpoint && gateway == sourceGateway
            && models.first(where: { $0.id == model })?.supportsImages == true
    }

    func refresh(endpoint: URL, gateway: Bool) {
        task?.cancel()
        let ticket = UUID(); generation = ticket
        let sameSource = sourceEndpoint == endpoint && sourceGateway == gateway
        sourceEndpoint = endpoint; sourceGateway = gateway
        if !sameSource { models = [] }
        error = nil; isLoading = true
        task = Task {
            do {
                let url = try AgentModelCatalog.modelsURL(endpoint: endpoint)
                #if DEBUG
                let credentialReader = Self.debugCredentials ?? credentials
                #else
                let credentialReader = credentials
                #endif
                let key = try await credentialReader(endpoint, gateway)
                try Task.checkCancellation()
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                if let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
                let delegate = CatalogRedirectPolicy()
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let (stream, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw AgentOperationError("模型发现失败，请检查服务连接。")
                }
                var bytes = Data()
                for try await byte in stream {
                    guard bytes.count < 1024 * 1024 else { throw AgentArtifactError.tooLarge }
                    bytes.append(byte)
                }
                let found = try AgentModelCatalog.parse(bytes)
                try Task.checkCancellation()
                guard generation == ticket else { return }
                models = found; isLoading = false
                if found.isEmpty { error = "服务未提供可用模型。" }
            } catch {
                guard generation == ticket, !Task.isCancelled else { return }
                // Keep the current list while refreshing, but do not retain
                // unverified capabilities after a failed or malformed reply.
                models = []
                self.error = error.localizedDescription; isLoading = false
            }
        }
    }
}

private final class CatalogRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
