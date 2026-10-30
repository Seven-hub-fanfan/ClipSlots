import Foundation

@main
struct ArtifactPageResourceMain {
    static func main() async throws {
        var checks: [String] = [], failures: [String] = []
        func check(_ value: Bool, _ name: String) { (value ? checks.append(name) : failures.append(name)) }
        guard CommandLine.arguments.count == 2, let base = URL(string: CommandLine.arguments[1]) else { exit(2) }
        let endpoint = AgentArtifactPageResourceEndpoint(channelURL: base.appendingPathComponent("mcp-apps/channels/current.json"),
            proxyURL: base.appendingPathComponent("82b3c69f76/mcp-app-proxy.html"), allowsLoopback: true)!
        let local = AgentArtifactPageResourceEndpoint(channelURL: nil,
            proxyURL: base.appendingPathComponent("usercontent-proxy/mcp-app-proxy.html"), allowsLoopback: true)!
        check(URLComponents(url: endpoint.appsURL, resolvingAgainstBaseURL: false)?.path == "/apps/", "hashed proxy uses bucket-root apps")
        check(URLComponents(url: local.appsURL, resolvingAgainstBaseURL: false)?.path == "/usercontent-proxy/apps/", "local proxy uses its own apps directory")
        check(AgentArtifactPageResourceEndpoint(channelURL: nil, proxyURL: base) == nil, "loopback requires explicit test capability")
        for text in ["https://u:p@example.com/proxy.html", "https://example.com/proxy.html?x=1", "file:///proxy.html"] {
            check(AgentArtifactPageResourceEndpoint(channelURL: nil, proxyURL: URL(string: text)!) == nil, "invalid proxy endpoint rejected")
        }
        let client = AgentArtifactResourceHTTPClient(allowsLoopback: true)
        let loader = AgentArtifactPageResourceLoader(resolver: .init(client: client), allowsLoopback: true)
        let template = try await loader.load(resourceURI: "ui://tapnow/previs@v3", endpoint: endpoint)
        check(template.source == "<!doctype html><title>页面🙂</title><p id='remote'>已发布模板</p>", "HTML UTF-8 bytes preserved")
        check(template.hash == "0123abcd" && template.releaseID == "r-0123456789abcdef", "template belongs to exact release")
        check(template.resourceDescription == ["name": "previs", "version": "v3", "hash": "0123abcd"], "ready description uses actual loaded template")
        check(template.csp == ["imgDomains": ["https://files.tapnow.art"]], "release CSP filters forbidden origins")
        check(template.presentation.maxInlineHeight == 520 && template.presentation.allowExpanded, "release presentation overrides defaults")
        let fallback = try await loader.load(resourceURI: "ui://tapnow/animatic@v1", endpoint: endpoint)
        check(fallback.hash == "fedcba98" && fallback.releaseID == nil, "missing release widget uses legacy manifest")
        check(fallback.csp == AgentArtifactPageResourceLoader.sourceDefaultCSP(name: "animatic"), "legacy CSP is source default")
        let localPage = try await loader.load(resourceURI: "ui://tapnow/previs@v3", endpoint: local)
        check(localPage.hash == "0123abcd" && localPage.releaseID == nil, "no channel uses local legacy manifest")
        for uri in ["bad", "ui://tapnow/../previs@v3", "ui://tapnow/previs@v3?x=1"] {
            do {
                _ = try await loader.load(resourceURI: uri, endpoint: endpoint)
                check(false, "invalid resource URI fails before HTTP")
            } catch AgentArtifactPageResourceError.invalidIdentity { check(true, "invalid resource URI fails before HTTP") }
        }
        do {
            _ = try await loader.load(resourceURI: "ui://tapnow/malformed@v1", endpoint: endpoint)
            check(false, "manifest hash cannot inject a path")
        } catch AgentArtifactPageResourceError.invalidManifest { check(true, "manifest hash cannot inject a path") }
        for (name, status) in [("redirect", 302), ("auth", 401), ("missing", 404)] {
            do {
                _ = try await loader.load(resourceURI: "ui://tapnow/\(name)@v1", endpoint: endpoint)
                check(false, "template \(name) is a terminal load failure")
            } catch AgentArtifactResourceFetchError.http(let value) {
                check(value == status, "template \(name) is a terminal load failure")
            }
        }
        do {
            _ = try await loader.load(resourceURI: "ui://tapnow/invalid-utf8@v1", endpoint: endpoint)
            check(false, "invalid UTF-8 cannot silently replace template bytes")
        } catch AgentArtifactResourceFetchError.invalidResponse { check(true, "invalid UTF-8 cannot silently replace template bytes") }
        let limited = AgentArtifactPageResourceLoader(resolver: .init(client: client), allowsLoopback: true, maximumHTMLBytes: 64)
        for name in ["oversize", "stream-oversize"] {
            do {
                _ = try await limited.load(resourceURI: "ui://tapnow/\(name)@v1", endpoint: endpoint)
                check(false, "template \(name) respects response limit")
            } catch AgentArtifactResourceFetchError.responseLimit { check(true, "template \(name) respects response limit") }
        }
        let slow = AgentArtifactPageResourceLoader(resolver: .init(client: client), allowsLoopback: true, timeout: 0.05)
        do {
            _ = try await slow.load(resourceURI: "ui://tapnow/slow@v1", endpoint: endpoint)
            check(false, "template transfer has a timeout")
        } catch { check(true, "template transfer has a timeout") }
        let cancelled = Task { try await loader.load(resourceURI: "ui://tapnow/previs@v3", endpoint: endpoint) }
        cancelled.cancel()
        do { _ = try await cancelled.value; check(false, "cancelled page cannot deliver content") }
        catch is CancellationError { check(true, "cancelled page cannot deliver content") }
        let policy = AgentArtifactPageResourceLoader.cspPolicy(["imgDomains": ["https://files.tapnow.art", "https://x'; connect-src *"],
                                                              "mediaDomains": ["https://files.tapnow.media"]])
        check(policy.contains("connect-src 'none'") && !policy.contains("connect-src *"), "CSP cannot inject extra directives")
        check(policy.contains("img-src data: blob: https://files.tapnow.art;") &&
              policy.contains("media-src blob: https://files.tapnow.media;") && policy.contains("font-src data:"),
              "source CSP keeps distinct image media and font rules")
        let report: [String: Any] = ["passed": checks.count, "checks": checks, "failures": failures,
            "CSP": policy, "remoteProviderRequests": 0, "remotePageRendered": false, "M06Accepted": false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
