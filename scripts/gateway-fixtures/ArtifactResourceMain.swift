import Foundation

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 0
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return time }
    func set(_ time: Double) { lock.lock(); self.time = time; lock.unlock() }
}

private actor Fixture {
    var channelCalls = 0, releaseCalls = 0
    var channelHTTP: Int?, releaseHTTP: Int?
    var invalidRelease = false
    let id = "r-0123456789abcdef"
    func counts() -> [Int] { [channelCalls, releaseCalls] }
    func channelFailure(_ status: Int?) { channelHTTP = status }
    func releaseFailure(_ status: Int?) { releaseHTTP = status }
    func invalid(_ value: Bool) { invalidRelease = value }
    func fetch(_ url: URL) async throws -> JSONValue {
        let isChannel = url.path.contains("/channels/")
        if isChannel { channelCalls += 1 } else { releaseCalls += 1 }
        try await Task.sleep(for: .milliseconds(5))
        if let status = isChannel ? channelHTTP : releaseHTTP { throw AgentArtifactResourceFetchError.http(status) }
        if isChannel { return ["schema_version": "mcp_app_channel.v1", "release_id": .string(id)] }
        return ["schema_version": "mcp_app_release.v1", "release_id": .string(invalidRelease ? "wrong" : id),
                "widgets": ["previs@v3": ["hash": "0123abcd", "csp": [
                    "img_domains": ["https://files.tapnow.art", "https://forbidden.example", "https://files.tapnow.art"],
                    "media_domains": ["https://files.tapnow.media"], "connect_domains": ["https://forbidden.example"]],
                    "presentation": ["allow_expanded": true, "auto_expand_on_ready": true, "max_inline_height": 520]]]]
    }
}

@main
struct ArtifactResourceMain {
    static func main() async throws {
        var passed = 0, failures: [String] = []
        func check(_ value: Bool, _ message: String) { if value { passed += 1 } else { failures.append(message) } }
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        let url = URL(string: "http://127.0.0.1:123/mcp-apps/channels/current.json")!
        for uri in ["ui://tapnow/previs@v3", "ui://tapnow/animatic@v1", "ui://tapnow/a-b@v012"] {
            check(AgentArtifactResourceIdentity(uri: uri) != nil, "valid resource identity \(uri)")
        }
        for uri in ["", "https://example.com", "ui://other/previs@v3", "ui://tapnow/Previs@v3",
                    "ui://tapnow/previs@3", "ui://tapnow/previs@v3\n", "ui://tapnow/previs@v3?x=1"] {
            check(AgentArtifactResourceIdentity(uri: uri) == nil, "invalid resource identity \(uri)")
        }
        let defaults = AgentArtifactPresentationPolicy.sourceDefault(resourceURI: "ui://tapnow/previs@v3")
        check(defaults.allowExpanded && defaults.autoExpandOnReady, "previs source presentation defaults")
        check(AgentArtifactPresentationPolicy.sourceDefault(resourceURI: "ui://tapnow/motion-picker@v2").maxInlineHeight == 520,
              "picker inline source height")
        check(!AgentArtifactPresentationPolicy.sourceDefault(resourceURI: "ui://tapnow/unknown@v1").allowExpanded,
              "unknown resource does not expand")
        for value: JSONValue in [.null, true, "520", 99, 100.5] {
            check(AgentArtifactPresentationPolicy.release(["max_inline_height": value]).maxInlineHeight == nil,
                  "release height type and lower bound")
        }
        check(AgentArtifactPresentationPolicy.release(["allow_expanded": "true"]).allowExpanded == false,
              "release boolean uses exact type")
        check(defaults.inlineHeight(.infinity) == 100 && defaults.inlineHeight(1e100) == 8192
              && AgentArtifactPresentationPolicy(allowExpanded: true, maxInlineHeight: 520).inlineHeight(900) == 520,
              "native geometry remains bounded without integer overflow")
        let f = Fixture(), clock = Clock()
        let resolver = AgentArtifactResourceResolver(now: { clock.now() }, fetch: { url, _ in try await f.fetch(url) })
        let first = await resolver.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url)
        check(first?.hash == "0123abcd" && first?.releaseID == "r-0123456789abcdef", "source release and hash contract")
        check(first?.csp == ["imgDomains": ["https://files.tapnow.art"], "mediaDomains": ["https://files.tapnow.media"]],
              "release CSP filters unsupported domains, credentials and duplicates")
        check(first?.presentation.maxInlineHeight == 520, "release presentation contract")
        clock.set(60)
        _ = await resolver.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url)
        check(await f.counts() == [1, 1], "channel remains cached at exact TTL boundary")
        clock.set(60.001)
        _ = await resolver.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url)
        check(await f.counts() == [2, 1], "channel refresh preserves successful infinite release cache")
        let concurrent = Fixture()
        let shared = AgentArtifactResourceResolver(fetch: { url, _ in try await concurrent.fetch(url) })
        let results = await withTaskGroup(of: AgentArtifactResolvedResource?.self, returning: [AgentArtifactResolvedResource?].self) { group in
            for _ in 0..<128 { group.addTask { await shared.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url) } }
            var results: [AgentArtifactResolvedResource?] = []
            for await value in group { results.append(value) }
            return results
        }
        check(results.count == 128 && results.allSatisfy { $0?.hash == first?.hash },
              "128 concurrent resolver consumers receive the same resource")
        check(await concurrent.counts() == [1, 1], "128 consumers share one channel and one release request")
        let cancellationFixture = Fixture()
        let cancellationResolver = AgentArtifactResourceResolver(fetch: { url, _ in try await cancellationFixture.fetch(url) })
        let cancelled = Task { await cancellationResolver.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url) }
        let survivor = Task { await cancellationResolver.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url) }
        for _ in 0..<1000 {
            if await cancellationFixture.counts()[0] > 0 { break }
            await Task.yield()
        }
        cancelled.cancel()
        let cancelledValue = await cancelled.value, survivorValue = await survivor.value
        check(cancelledValue == nil && survivorValue?.hash == first?.hash,
              "cancelled consumer cannot apply a resource or cancel its surviving peer")
        check(await cancellationFixture.counts() == [1, 1], "consumer cancellation retains shared request deduplication")
        let prefetchFixture = Fixture()
        let prefetchResolver = AgentArtifactResourceResolver(fetch: { url, _ in try await prefetchFixture.fetch(url) })
        await prefetchResolver.prefetch(channelURL: url)
        check(await prefetchResolver.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url) != nil,
              "prefetch resolves the same cached channel and release")
        check(await prefetchFixture.counts() == [1, 1], "prefetch adds no second release request")
        for status in [404, 500] {
            let fixture = Fixture(), timer = Clock()
            await fixture.channelFailure(status)
            let r = AgentArtifactResourceResolver(now: { timer.now() }, fetch: { url, _ in try await fixture.fetch(url) })
            check(await r.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url) == nil, "HTTP \(status) channel failure")
            let ttl: Double = status == 404 ? 60 : 5
            timer.set(ttl)
            _ = await r.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url)
            check(await fixture.counts() == [1, 0], "HTTP \(status) channel cache boundary")
            timer.set(ttl + 0.001); await fixture.channelFailure(nil)
            check(await r.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url) != nil, "HTTP \(status) channel recovers after TTL")
            check(await fixture.counts() == [2, 1], "HTTP \(status) channel retry request count")
        }
        for status in [404, 500] {
            let fixture = Fixture(), timer = Clock()
            await fixture.releaseFailure(status)
            let r = AgentArtifactResourceResolver(now: { timer.now() }, fetch: { url, _ in try await fixture.fetch(url) })
            _ = await r.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url)
            let ttl: Double = status == 404 ? 60 : 5
            timer.set(ttl)
            _ = await r.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url)
            check(await fixture.counts() == [1, 1], "HTTP \(status) release cache boundary")
            timer.set(ttl + 0.001); await fixture.releaseFailure(nil)
            check(await r.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url) != nil, "HTTP \(status) release recovers after TTL")
            check(await fixture.counts() == (status == 404 ? [2, 2] : [1, 2]), "HTTP \(status) release retry count")
        }
        let invalidFixture = Fixture(), invalidClock = Clock()
        await invalidFixture.invalid(true)
        let invalid = AgentArtifactResourceResolver(now: { invalidClock.now() }, fetch: { url, _ in try await invalidFixture.fetch(url) })
        check(await invalid.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url) == nil, "mismatched release identity cannot resolve")
        invalidClock.set(60.001); await invalidFixture.invalid(false)
        check(await invalid.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: url) != nil, "invalid release retries at channel TTL")
        let invalidIdentity = await resolver.resolve(resourceURI: "bad", channelURL: url)
        let missingChannel = await resolver.resolve(resourceURI: "ui://tapnow/previs@v3", channelURL: nil)
        check(invalidIdentity == nil && missingChannel == nil,
              "invalid identity and missing channel cause no requests")
        var oracleResults: [JSONValue] = []
        if let oraclePath = option("--oracle") {
            let cases = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: URL(fileURLWithPath: oraclePath)))
            for c in cases {
                let r = AgentArtifactResourceResolver(fetch: { url, _ in
                    url.path.contains("/channels/") ? c["channel"] ?? .null : c["release"] ?? .null
                })
                let value = await r.resolve(resourceURI: c["uri"]?.stringValue ?? "", channelURL: url)
                oracleResults.append(value.map {
                    ["releaseId": .string($0.releaseID), "hash": .string($0.hash), "csp": $0.csp,
                     "presentation": .object([
                        "allowExpanded": .bool($0.presentation.allowExpanded),
                        "autoExpandOnReady": .bool($0.presentation.autoExpandOnReady)].merging(
                            $0.presentation.maxInlineHeight.map { ["maxInlineHeight": .number($0)] } ?? [:],
                            uniquingKeysWith: { _, new in new }))]
                } ?? .null)
            }
        }
        if let endpoint = option("--url"), let base = URL(string: endpoint) {
            let client = AgentArtifactResourceHTTPClient(allowsLoopback: true)
            let r = AgentArtifactResourceResolver(client: client)
            let actual = await r.resolve(resourceURI: "ui://tapnow/previs@v3",
                                         channelURL: base.appendingPathComponent("mcp-apps/channels/ok.json"))
            check(actual?.hash == "0123abcd", "actual URLSession channel and release JSON roundtrip")
            do {
                _ = try await AgentArtifactResourceHTTPClient().fetch(base)
                check(false, "default HTTP client forbids loopback without explicit test capability")
            } catch { check(true, "default HTTP client forbids loopback without explicit test capability") }
            for (path, code) in [("redirect", 302), ("auth", 401)] {
                do {
                    _ = try await client.fetch(base.appendingPathComponent(path))
                    check(false, "actual \(path) rejected")
                } catch AgentArtifactResourceFetchError.http(let status) { check(status == code, "actual \(path) rejected without followup") }
                catch { check(false, "unexpected \(path) error classification") }
            }
            for path in ["oversize", "stream-oversize"] {
                do {
                    _ = try await AgentArtifactResourceHTTPClient(allowsLoopback: true, maximumBytes: 64).fetch(base.appendingPathComponent(path))
                    check(false, "actual \(path) body bound")
                } catch AgentArtifactResourceFetchError.responseLimit { check(true, "actual \(path) body bound") }
                catch { check(false, "unexpected \(path) error classification") }
            }
            do {
                _ = try await client.fetch(base.appendingPathComponent("slow"), timeout: 0.05)
                check(false, "actual request timeout")
            } catch { check(true, "actual request timeout") }
        }
        let report: [String: Any] = ["passed": passed, "failures": failures,
                                    "oracleResults": try JSONSerialization.jsonObject(with: JSONEncoder().encode(oracleResults)),
                                    "remoteProviderRequests": 0, "M06Accepted": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
