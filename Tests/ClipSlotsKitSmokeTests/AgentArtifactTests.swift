import Foundation
import ClipSlotsKit

private func artifactThrows(_ check: (Bool, String) -> Void, _ name: String, _ body: () throws -> Void) {
    do { try body(); check(false, name + " must throw") }
    catch { check(true, name) }
}

private func artifactRepositoryTests(_ check: (Bool, String) -> Void) {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("artifact-tests-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    do {
        let scope = try AgentArtifactScope(projectID: "project", canvasID: "canvas")
        let key = try AgentArtifactKey(scope: scope, path: "./reports//result.html")
        let catalog = try AgentModelCatalog.parse(Data(#"{"data":[{"id":"actual-model","context_window":128000,"capabilities":{"image_input":true}},{"id":"vision-named-but-unknown"}]}"#.utf8))
        check(catalog.count == 2 && catalog[0].contextWindow == 128000 && catalog[0].supportsImages == true,
              "model discovery preserves explicitly reported capacity and image support")
        check(catalog[1].supportsImages == nil && catalog[1].contextWindow == nil,
              "model discovery never guesses capability from model name")
        check(try AgentModelCatalog.modelsURL(endpoint: URL(string: "https://example.test/v1/chat/completions")!).absoluteString
              == "https://example.test/v1/models", "model discovery respects configured API prefix")
        artifactThrows(check, "model discovery rejects insecure remote origin") {
            _ = try AgentModelCatalog.modelsURL(endpoint: URL(string: "http://example.test/v1")!)
        }
        artifactThrows(check, "model discovery rejects duplicate IDs") {
            _ = try AgentModelCatalog.parse(Data(#"{"data":[{"id":"same"},{"id":"same"}]}"#.utf8))
        }
        let widgets = try AgentWidgetStateStore(directory: root.appendingPathComponent("widgets"))
        let conversation = UUID()
        let state: JSONValue = ["counter": 9, "label": "保存🙂"]
        try widgets.save(state, key: key, conversationID: conversation, revision: 2)
        let reopenedWidgets = try AgentWidgetStateStore(directory: root.appendingPathComponent("widgets"))
        check(try reopenedWidgets.load(key: key, conversationID: conversation, revision: 2) == state,
              "widget state survives reopening with unicode and numeric values")
        check(try widgets.load(key: key, conversationID: UUID(), revision: 2) == .null,
              "widget state cannot leak across conversations")
        check(try widgets.load(key: key, conversationID: conversation, revision: 3) == .null,
              "widget state cannot leak across content revisions")
        let foreignWidget = try AgentArtifactKey(projectID: "other", canvasID: "canvas", path: key.path)
        check(try widgets.load(key: foreignWidget, conversationID: conversation, revision: 2) == .null,
              "widget state cannot leak across projects")
        artifactThrows(check, "widget store rejects oversized state") {
            try widgets.save(.string(String(repeating: "a", count: 65537)), key: key,
                             conversationID: conversation, revision: 2)
        }
        check(try widgets.load(key: key, conversationID: conversation, revision: 2) == state,
              "rejected widget update preserves prior state")
        check(key.path == "reports/result.html", "path normalizes dot and repeated separators")
        check(try AgentArtifactKey(scope: scope, path: "reports\\result.html") == key, "backslash normalization")
        check(try AgentArtifactKey(scope: scope, path: "cafe\u{301}.txt").path == "caf\u{E9}.txt", "NFC path normalization")
        for path in ["../x", "a/../x", "/tmp/x", "~/.ssh/key", "file:///x", "C:\\x", ".", "a/\u{0}/b", String(repeating: "x", count: 1025)] {
            artifactThrows(check, "reject unsafe path \(path.debugDescription)") { _ = try AgentArtifactKey(scope: scope, path: path) }
        }
        artifactThrows(check, "reject empty project") { _ = try AgentArtifactScope(projectID: " ", canvasID: "canvas") }
        artifactThrows(check, "reject control in canvas") { _ = try AgentArtifactScope(projectID: "p", canvasID: "c\n") }
        let invalidKey = Data(#"{"scope":{"projectID":"p","canvasID":"c"},"path":"../escape"}"#.utf8)
        artifactThrows(check, "Codable cannot bypass key validation") { _ = try JSONDecoder().decode(AgentArtifactKey.self, from: invalidKey) }

        let store = try AgentArtifactRepository(directory: root.appendingPathComponent("repository"))
        let bytes = Data("<h1>Revision 2</h1>".utf8)
        let original = try store.merge(.init(key: key, revision: 2, content: bytes, mimeType: "text/html"))
        check(original.resourceState == .ready && original.hasCurrentContent, "initial content ready at its revision")
        let stale = try store.merge(.init(key: key, revision: 1, content: Data("stale".utf8)))
        check(stale == original, "older revision ignored")
        let metadata = try store.merge(.init(key: key, revision: 2, title: "Renamed"))
        check(metadata.content == bytes && metadata.resourceState == .ready, "same revision missing content retains bytes and ready state")
        artifactThrows(check, "same revision different bytes conflicts") {
            _ = try store.merge(.init(key: key, revision: 2, content: Data("conflict".utf8)))
        }
        check(try store.record(for: key)?.content == bytes, "conflict does not touch disk")
        let later = try store.merge(.init(key: key, revision: 3))
        check(later.content == bytes && later.contentRevision == 2 && !later.hasCurrentContent, "new revision missing content retains old bytes without relabeling")
        check(later.resourceState == .missing, "new content remains explicitly missing")
        let token1 = try store.beginFetch(for: key)
        check(try store.record(for: key)?.resourceState == .loading, "fetch publishes loading")
        _ = try store.merge(.init(key: key, revision: 4, content: Data("four".utf8)))
        check(try !store.completeFetch(token1, content: Data("late three".utf8)), "stale fetch cannot overwrite newer revision")
        check(try !store.failFetch(token1, message: "late failure"), "stale failure cannot poison newer revision")
        check(try store.record(for: key)?.text == "four", "newer content survives stale completion")

        _ = try store.merge(.init(key: key, revision: 5))
        let first = try store.beginFetch(for: key)
        let second = try store.beginFetch(for: key)
        check(try !store.completeFetch(first, content: Data("first".utf8)), "older fetch at same revision ignored")
        check(try store.completeFetch(second, content: Data("five".utf8)), "latest same revision fetch applies")
        check(try !store.completeFetch(second, content: Data("duplicate".utf8)), "duplicate completion ignored")
        check(try store.record(for: key)?.text == "five", "same revision fetch winner retained")
        let failure = try store.beginFetch(for: key)
        check(try store.failFetch(failure, message: "fixture download failure"), "fetch failure applies")
        let failed = try store.record(for: key)
        check(failed?.resourceState == .error("fixture download failure") && failed?.text == "five", "failure retains downloaded content and error separately")
        let failedMetadata = try store.merge(.init(key: key, revision: 5))
        check(failedMetadata.resourceState == failed?.resourceState, "contentless same revision preserves error too")

        let cancelled = try store.beginFetch(for: key)
        check(try store.cancelFetch(cancelled), "fetch can be explicitly cancelled")
        check(try !store.completeFetch(cancelled, content: Data("late".utf8)), "cancelled fetch cannot apply")
        let interrupted = try store.beginFetch(for: key)
        let restarted = try AgentArtifactRepository(directory: store.directory)
        let recovered = try restarted.record(for: key)
        if case .error = recovered?.resourceState { check(true, "restart reports interrupted fetch instead of indefinite loading") }
        else { check(false, "restart reports interrupted fetch instead of indefinite loading") }
        check(try !restarted.completeFetch(interrupted, content: bytes), "fetch tokens belong to originating instance")
        _ = try restarted.merge(.init(key: key, revision: 6, content: Data("six".utf8)))
        check(try !store.completeFetch(interrupted, content: bytes), "cross-instance revision change invalidates old fetch")
        check(try store.record(for: key)?.revision == 6, "repository rereads other instance changes")

        let otherCanvas = try AgentArtifactKey(projectID: "project", canvasID: "canvas2", path: key.path)
        let otherProject = try AgentArtifactKey(projectID: "other-project", canvasID: "canvas", path: key.path)
        let otherPath = try AgentArtifactKey(scope: scope, path: "reports/another.html")
        for isolated in [otherCanvas, otherProject, otherPath] {
            _ = try store.merge(.init(key: isolated, revision: 1, content: Data(isolated.path.utf8)))
        }
        check(try store.records(in: scope).count == 2, "listing isolates project and canvas")
        check(try store.record(for: otherCanvas)?.revision == 1, "same path on another canvas remains separate")
        check(try store.record(for: otherProject)?.revision == 1, "same path in another project remains separate")
        check(try restarted.record(for: key)?.text == "six", "fresh repository restores durable contents")
        let filenames = try fm.contentsOfDirectory(atPath: store.directory.path).filter { $0.hasSuffix(".json") }
        check(filenames.allSatisfy { $0.count == 69 && !$0.contains("reports") }, "disk names never use untrusted paths")
        check(try AgentArtifactKey(scope: scope, path: "%2e%2e/literal.txt").path.hasPrefix("%2e"), "percent sequences remain literal keys, never URL-decoded paths")

        artifactThrows(check, "same revision delete conflicts") { _ = try store.delete(key, revision: 6) }
        let beforeDeletion = try store.beginFetch(for: key)
        let deleted = try store.delete(key, revision: 7)
        check(deleted.isDeleted && deleted.content == nil, "deletion writes tombstone and removes local bytes")
        check(try !store.completeFetch(beforeDeletion, content: bytes), "delete invalidates in-flight fetch")
        check(try store.merge(.init(key: key, revision: 7, content: bytes)).isDeleted, "same revision cannot resurrect tombstone")
        check(try store.merge(.init(key: key, revision: 6, content: bytes)).isDeleted, "older revision cannot resurrect tombstone")
        check(try restarted.record(for: key)?.isDeleted == true, "tombstone survives restart")
        check(try store.records(in: scope).count == 1, "deleted records excluded from normal listing")
        check(try store.records(in: scope, includeDeleted: true).count == 2, "tombstones available explicitly")
        artifactThrows(check, "deleted artifact cannot begin fetch") { _ = try store.beginFetch(for: key) }
        check(try store.merge(.init(key: key, revision: 8, content: Data())).hasCurrentContent, "higher revision can recreate and empty bytes count as content")

        let tiny = try AgentArtifactRepository(directory: root.appendingPathComponent("tiny"),
            limits: .init(maximumContentBytes: 16, maximumRecords: 1, maximumRepositoryBytes: 4096))
        _ = try tiny.merge(.init(key: key, revision: 1, content: Data([1])))
        artifactThrows(check, "bounded content") { _ = try tiny.merge(.init(key: key, revision: 2, content: Data(repeating: 0, count: 17))) }
        artifactThrows(check, "bounded record count") { _ = try tiny.merge(.init(key: otherPath, revision: 1)) }
        check(try tiny.record(for: key)?.revision == 1, "quota failure preserves existing artifact")
        let overFetch = try tiny.beginFetch(for: key)
        artifactThrows(check, "fetch content limit") { _ = try tiny.completeFetch(overFetch, content: Data(repeating: 0, count: 17)) }
        _ = try tiny.failFetch(overFetch, message: "Oversized response.")
        check(try tiny.record(for: key)?.resourceState == .error("Oversized response."), "caller can report bounded fetch errors")
        let noSpace = try AgentArtifactRepository(directory: root.appendingPathComponent("no-space"),
            limits: .init(maximumRepositoryBytes: 1))
        artifactThrows(check, "repository byte quota") { _ = try noSpace.merge(.init(key: key, revision: 1, content: bytes)) }
        check(try noSpace.record(for: key) == nil, "byte quota failure does not create a record")
    } catch { check(false, "artifact repository suite: \(error)") }

    do {
        let authorized = root.appendingPathComponent("authorized", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: authorized, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let allowed = authorized.appendingPathComponent("allowed.txt")
        let forbidden = outside.appendingPathComponent("forbidden.txt")
        let bytes = Data("local \u{4E2D}\u{6587}".utf8)
        try bytes.write(to: allowed)
        try bytes.write(to: forbidden)
        check(try AgentArtifactFileAccess.read(allowed, within: authorized) == bytes, "explicit granted local read")
        artifactThrows(check, "outside grant rejected") { _ = try AgentArtifactFileAccess.read(forbidden, within: authorized) }
        let link = authorized.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: link, withDestinationURL: forbidden)
        artifactThrows(check, "symlink escape rejected") { _ = try AgentArtifactFileAccess.read(link, within: authorized) }
        artifactThrows(check, "directory is not content") { _ = try AgentArtifactFileAccess.read(authorized, within: root) }
        artifactThrows(check, "file read bounded") { _ = try AgentArtifactFileAccess.read(allowed, within: authorized, maximumBytes: 2) }
        artifactThrows(check, "network URL not a file grant") { _ = try AgentArtifactFileAccess.read(URL(string: "https://example.com")!, within: authorized) }
        let html = AgentArtifactPreviewPolicy.sandboxedHTML("<script>hidden()</script><img src=\"file:///etc/passwd\">")
        check(html.contains("script-src 'none'") && html.contains("connect-src 'none'") && html.contains("default-src 'none'"), "HTML policy denies scripts and external resources")
        check(html.range(of: "Content-Security-Policy")!.lowerBound < html.range(of: "<script>")!.lowerBound, "CSP precedes untrusted content")
        let interactive = AgentArtifactPreviewPolicy.sandboxedHTML("<button onclick=\"run()\">run</button>", allowsScripts: true)
        check(interactive.contains("script-src 'unsafe-inline'") && interactive.contains("connect-src 'none'")
            && interactive.contains("frame-src 'none'"), "interactive HTML permits inline behavior while retaining network and frame isolation")
        for address in ["file:///tmp/x", "javascript:alert(1)", "http://example.com", "https://u:p@example.com"] {
            check(AgentArtifactPreviewPolicy.externalURL(URL(string: address)!) == nil, "preview blocks unsafe navigation \(address)")
        }
        check(AgentArtifactPreviewPolicy.externalURL(URL(string: "https://example.com/path")!) != nil, "HTTPS link can be explicitly proposed to parent")
        check(AgentArtifactKind.detect(mimeType: "text/html; charset=utf-8", path: "a.bin") == .html, "HTML MIME classification")
        check(AgentArtifactKind.detect(mimeType: "application/octet-stream", path: "clip.mp4") == .video, "media fallback classification")
        let copy = try AgentArtifactLocalCopy(content: bytes, path: "reports/local \u{4E2D}.txt", temporaryRoot: root)
        check(copy.fileURL.lastPathComponent == "local \u{4E2D}.txt", "share copy preserves local basename")
        check(try Data(contentsOf: copy.fileURL) == bytes, "native share copy contains exact artifact bytes")
        try copy.remove()
        check(!fm.fileExists(atPath: copy.directory.path), "share copy can be cleaned after completion or cancellation")
        check(try Data(contentsOf: allowed) == bytes, "share cleanup never removes original artifact/source")
        artifactThrows(check, "share copy rejects traversal") {
            _ = try AgentArtifactLocalCopy(content: bytes, path: "../escape", temporaryRoot: root)
        }
    } catch { check(false, "artifact file/policy suite: \(error)") }
}

@MainActor
private final class ArtifactFakeOpener: AgentExternalHandoffOpening {
    var available = true
    var desktopOutcome: AgentExternalOpenOutcome = .opened
    var webOutcome: AgentExternalOpenOutcome = .opened
    var clipboardWorks = true
    var events: [String] = []
    var copied: [String] = []
    var beforeDesktopReturn: (() async -> Void)?
    func applicationAvailable(bundleID: String) -> Bool { available }
    func openApplication(bundleID: String) async -> AgentExternalOpenOutcome {
        events.append("desktop")
        await beforeDesktopReturn?()
        return desktopOutcome
    }
    func openURL(_ url: URL) async -> AgentExternalOpenOutcome {
        events.append("url:" + (url.scheme ?? ""))
        return webOutcome
    }
    func copyPrompt(_ prompt: String) -> Bool {
        events.append("copy")
        if clipboardWorks { copied.append(prompt) }
        return clipboardWorks
    }
}

@MainActor
private func artifactExternalTests(_ check: @escaping (Bool, String) -> Void) async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("handoff-tests-\(UUID())")
    let suite = "clipslots.artifact.tests.\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite) else { check(false, "isolated preferences"); return }
    defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
    do {
        let scope = try AgentArtifactScope(projectID: "p + & \u{4E2D}", canvasID: "canvas?/\u{6587}")
        let selected = "Hello \u{4E2D}\u{6587} + space & ? # % / \n\u{1F680}"
        let doc = URL(fileURLWithPath: "/tmp/project guide \u{4E2D}.md")
        let context = AgentExternalProjectContext(scope: scope, projectTitle: "Project", selectedContext: selected, documentationURLs: [doc])
        let provider = AgentExternalProvider(id: "fixture", name: "Fixture", desktopBundleID: "test.client",
            webTarget: .init(baseURL: URL(string: "https://example.com/chat?existing=a%2Bb")!))
        let plan = try AgentExternalHandoffCoordinator.prepare(provider: provider, context: context)
        check(plan.context.scope == scope && plan.prompt.contains(selected), "plan retains scoped Unicode context")
        check(plan.prompt.contains(doc.absoluteString), "project docs included without reading or uploading them")
        let config = try context.mcpConfiguration()["mcpServers"]?["clipslots-project"]
        check(config?["command"]?.stringValue == "/usr/local/bin/clipslots", "MCP uses own local CLI")
        check(config?["args"]?.arrayValue == ["--mcp", "--project-id", .string(scope.projectID), "--canvas-id", .string(scope.canvasID)], "MCP args are exact project/canvas values, not shell quoting")
        check(config?["env"]?["CLIPSLOTS_PROJECT_ID"]?.stringValue == scope.projectID, "project scope exposed in MCP environment")
        check(plan.prompt.contains("NOT connected/available"), "client MCP readiness is not labeled connected")
        check(plan.targets.map(\.promptTransport) == [.clipboard, .clipboard], "conservative defaults use copy/paste")
        let endpoint = AgentExternalURLTarget(baseURL: URL(string: "https://example.com/?existing=a%2Bb&prompt=old")!, promptQueryItem: "prompt")
        let encoded = try endpoint.url(prompt: selected)
        let items = URLComponents(url: encoded, resolvingAgainstBaseURL: false)?.queryItems ?? []
        check(items.first { $0.name == "prompt" }?.value == selected, "Unicode and reserved URL characters round-trip")
        check(items.first { $0.name == "existing" }?.value == "a+b", "existing URL query preserved")
        check(encoded.absoluteString.contains("%2B") && !encoded.absoluteString.contains(" "), "literal plus and spaces are percent encoded")
        check((URLComponents(url: try endpoint.url(prompt: nil), resolvingAgainstBaseURL: false)?.queryItems ?? []).allSatisfy { $0.name != "prompt" }, "clipboard fallback removes stale prompt query")
        let longContext = AgentExternalProjectContext(scope: scope, projectTitle: "P", selectedContext: String(repeating: "\u{4E2D}", count: 4000))
        let queryProvider = AgentExternalProvider(id: "query", name: "Query", webTarget: endpoint)
        let longPlan = try AgentExternalHandoffCoordinator.prepare(provider: queryProvider, context: longContext)
        check(longPlan.targets.first?.promptTransport == .clipboard, "long prompt URL falls back to clipboard")
        check((longPlan.targets.first?.url?.absoluteString.utf8.count ?? 0) < 8192, "fallback URL is bounded")
        artifactThrows(check, "oversized context rejected") {
            _ = try AgentExternalProjectContext(scope: scope, projectTitle: "P", selectedContext: String(repeating: "x", count: 65537)).prompt()
        }

        let desktop = ArtifactFakeOpener()
        let desktopResult = await AgentExternalHandoffCoordinator.execute(plan, using: desktop)
        check(desktopResult.status == .openedDesktop && desktopResult.promptCopied, "desktop open and copied status separate")
        check(desktop.events == ["copy", "desktop"] && desktop.copied == [plan.prompt], "explicit launch copies then opens only")
        check(desktopResult.message.contains("No message was sent"), "desktop open does not claim sent")
        let web = ArtifactFakeOpener(); web.available = false
        let webResult = await AgentExternalHandoffCoordinator.execute(plan, using: web)
        check(webResult.status == .openedWeb && webResult.attempts == [.unsupported, .opened], "unavailable desktop falls back to web")
        let failedDesktop = ArtifactFakeOpener(); failedDesktop.desktopOutcome = .failed("fixture launch failure")
        let retryResult = await AgentExternalHandoffCoordinator.execute(plan, using: failedDesktop)
        check(retryResult.status == .openedWeb && failedDesktop.copied.count == 1, "desktop failure falls back without duplicate clipboard mutation")
        let copy = ArtifactFakeOpener(); copy.available = false; copy.webOutcome = .unsupported
        let copyResult = await AgentExternalHandoffCoordinator.execute(plan, using: copy)
        check(copyResult.status == .copiedOnly && copyResult.promptCopied, "unsupported clients yield copy-only, never sent")
        let noClipboard = ArtifactFakeOpener(); noClipboard.clipboardWorks = false
        let clipboardFailure = await AgentExternalHandoffCoordinator.execute(plan, using: noClipboard)
        check(clipboardFailure.status == .failed && noClipboard.events == ["copy"], "clipboard failure cannot pretend scoped client opened")
        let noFallbackPlan = try AgentExternalHandoffCoordinator.prepare(provider: provider, context: context, copyFallback: false)
        let unsupported = ArtifactFakeOpener(); unsupported.available = false; unsupported.webOutcome = .unsupported
        check(await AgentExternalHandoffCoordinator.execute(noFallbackPlan, using: unsupported).status == .unsupported, "unsupported outcome without copy fallback")
        let failedOpener = ArtifactFakeOpener(); failedOpener.desktopOutcome = .failed("desktop"); failedOpener.webOutcome = .failed("web")
        check(await AgentExternalHandoffCoordinator.execute(noFallbackPlan, using: failedOpener).status == .failed, "failed outcome distinguished from unsupported")
        let queryPlan = try AgentExternalHandoffCoordinator.prepare(provider: queryProvider, context: context)
        let queryOpener = ArtifactFakeOpener()
        let queryResult = await AgentExternalHandoffCoordinator.execute(queryPlan, using: queryOpener)
        check(queryResult.status == .openedWeb && !queryResult.promptCopied && queryOpener.copied.isEmpty, "configured URL transport does not silently copy")
        check(queryResult.message.contains("unverified"), "URL launch delivery remains unverified")
        let noTarget = AgentExternalProvider(id: "copy", name: "Copy Only")
        let copyOnly = try AgentExternalHandoffCoordinator.prepare(provider: noTarget, context: context)
        let copyOnlyOpener = ArtifactFakeOpener()
        check(await AgentExternalHandoffCoordinator.execute(copyOnly, using: copyOnlyOpener).status == .copiedOnly, "copy-only provider supported")

        let localized = AgentExternalProvider(id: "localized", name: "Localized", regions: ["CN"], languages: ["zh"])
        let catalog = try AgentExternalProviderCatalog(providers: [provider, localized])
        check(catalog.visibleProviders(region: "cn", language: "zh-CN").count == 2, "catalog region/language visibility")
        check(catalog.visibleProviders(region: "US", language: "en").map(\.id) == ["fixture"], "hidden region providers excluded")
        artifactThrows(check, "duplicate provider IDs rejected") { _ = try AgentExternalProviderCatalog(providers: [provider, provider]) }
        artifactThrows(check, "unsafe web scheme rejected") {
            _ = try AgentExternalProviderCatalog(providers: [.init(id: "bad", name: "Bad", webTarget: .init(baseURL: URL(string: "file:///tmp/run")!))])
        }
        artifactThrows(check, "unsafe desktop execution scheme rejected") {
            _ = try AgentExternalProviderCatalog(providers: [.init(id: "bad", name: "Bad", desktopTarget: .init(baseURL: URL(string: "terminal://run")!))])
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("providers.json")
        try JSONEncoder().encode(catalog.providers).write(to: file)
        check(try AgentExternalProviderCatalog.load(from: file, within: root).providers == catalog.providers, "controlled local config loads through bounded grant")
        check(AgentExternalProviderCatalog.localDefaults.providers.allSatisfy { $0.webTarget?.promptQueryItem == nil }, "default providers never assume prompt/auto-send URL protocols")

        let builtins = AgentExternalProviderCatalog.localDefaults
        check(builtins.providers.map(\.id) == ["claude", "chatgpt", "deepseek", "workbuddy", "qwenwork"],
              "DeepSeek Harness appears between ChatGPT and WorkBuddy")
        let harness = builtins.providers.first { $0.id == "deepseek" }!
        check(harness.name == "DeepSeek Harness" && harness.desktopBundleID == "com.deepseek.dsh"
            && harness.desktopTarget?.baseURL.absoluteString == "dsh://open" && harness.webTarget == nil,
              "Harness uses installed client identity and verified open URI")
        check(harness.desktopTarget?.promptQueryItem == nil,
              "Harness open URI never receives prompt or auto-send parameters")
        check(try AgentExternalProviderCatalog(providers: builtins.providers).providers == builtins.providers,
              "all built-in providers pass controlled catalog validation")
        let harnessPlan = try AgentExternalHandoffCoordinator.prepare(provider: harness, context: context)
        let harnessOpener = ArtifactFakeOpener()
        let harnessResult = await AgentExternalHandoffCoordinator.execute(harnessPlan, using: harnessOpener)
        check(harnessResult.status == .openedDesktop && harnessOpener.events == ["copy", "url:dsh"],
              "explicit Harness launch copies scoped prompt then opens desktop URI")
        check(harnessPlan.targets.count == 1 && harnessOpener.copied == [harnessPlan.prompt],
              "Harness launch preserves current project with no unrelated web target")
        let missingHarness = ArtifactFakeOpener(); missingHarness.available = false
        let missingResult = await AgentExternalHandoffCoordinator.execute(harnessPlan, using: missingHarness)
        check(missingResult.status == .copiedOnly && missingHarness.events == ["copy"],
              "missing Harness copies prompt without opening a different product")
        let failedHarness = ArtifactFakeOpener(); failedHarness.webOutcome = .failed("dsh fixture failure")
        let failedHarnessResult = await AgentExternalHandoffCoordinator.execute(harnessPlan, using: failedHarness)
        check(failedHarnessResult.status == .copiedOnly && failedHarness.events == ["copy", "url:dsh"],
              "failed Harness URI leaves exactly one copied prompt")
        check(AgentBrandResources.usesTemplateRendering(for: "deepseek")
            && AgentBrandResources.usesTemplateRendering(for: "chatgpt")
            && !AgentBrandResources.usesTemplateRendering(for: "claude"),
              "Harness follows theme ink while existing colored artwork stays original")
        let harnessPreferences = AgentExternalHandoffPreferences(defaults: defaults, key: "harness-last-used")
        let harnessSession = AgentExternalHandoffSession(catalog: builtins, context: context,
            preferences: harnessPreferences)
        harnessSession.present(); harnessSession.select("deepseek")
        harnessSession.close(); harnessSession.present()
        check(harnessSession.selectedProviderID == "deepseek" && harnessSession.result == nil,
              "Harness choice survives reopen without persisting transient launch result")

        defaults.set("invalid-provider", forKey: "last-used")
        let preferences = AgentExternalHandoffPreferences(defaults: defaults, key: "last-used")
        let localizedContext = AgentExternalProjectContext(scope: scope, projectTitle: "P", region: "CN", language: "zh-CN")
        let session = AgentExternalHandoffSession(catalog: catalog, context: localizedContext, preferences: preferences)
        let lifecycleOpener = ArtifactFakeOpener()
        session.present()
        check(session.selectedProviderID == "fixture" && defaults.string(forKey: "last-used") == "fixture", "invalid persisted provider is corrected")
        check(lifecycleOpener.events.isEmpty, "opening dialog does not launch/copy")
        session.select("localized")
        check(session.selectedProviderID == "localized", "valid selection persisted")
        session.select("not-visible")
        check(session.selectedProviderID == "localized", "invalid selection ignored")
        _ = try session.copy(context: localizedContext, using: lifecycleOpener)
        check(session.result?.status == .copiedOnly, "copy result is explicit")
        session.close()
        check(!session.isPresented && session.result == nil && session.selectedProviderID == nil && !session.isExecuting, "close clears all transient state")
        session.present()
        check(session.selectedProviderID == "localized" && session.result == nil, "reopen restores last-used but not prior result")
        session.update(context: context)
        check(session.providers.map(\.id) == ["fixture"] && session.selectedProviderID == "fixture", "region/context change revalidates visible persisted provider")
        check(try session.copy(context: localizedContext, using: lifecycleOpener) == nil, "stale context cannot be copied")
        let closingOpener = ArtifactFakeOpener()
        closingOpener.desktopOutcome = .failed("fixture delayed failure")
        closingOpener.beforeDesktopReturn = {
            check(session.isExecuting, "launch shows executing")
            let duplicate = try? await session.launch(context: context, using: closingOpener)
            check(duplicate == nil, "duplicate launch while executing ignored")
            session.close()
            session.present()
        }
        let staleResult = try await session.launch(context: context, using: closingOpener)
        check(staleResult == nil && session.result == nil, "late launch response cannot restore result after close/reopen")
        check(closingOpener.events == ["copy", "desktop"], "closed generation cannot perform web or copy fallback")
        check(defaults.dictionaryRepresentation().keys.filter { $0 == "last-used" }.count == 1,
              "test preference persists provider only")
    } catch { check(false, "external handoff suite: \(error)") }
}

private func artifactMCPTests(_ check: @escaping (Bool, String) -> Void) async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("artifact-mcp-\(UUID())")
    defer { try? fm.removeItem(at: root) }
    do {
        let project = "project + \u{4E2D}/literal"
        let scope = try AgentArtifactScope(projectID: project, canvasID: "canvas")
        let node = CanvasNode(pageId: "p", groupId: "g", slot: 1, kind: .text, x: 0, y: 0)
        let graph = CanvasWorkflowSnapshot(projectID: project, facts: [
            .init(node: node, title: "Node", body: "fixed snapshot body", bodyRevision: "v1")
        ], edges: [], selectionIDs: [node.id])
        let snapshot = CanvasAgentSnapshot(graph: graph, runs: [], canvasID: scope.canvasID)
        try CanvasAgentSnapshotStore(root: root).save(snapshot)
        let sessionID = UUID()
        let context = AgentExternalProjectContext(scope: scope, projectTitle: "P", snapshotID: graph.snapshotID, sessionID: sessionID)
        let args = try context.mcpConfiguration()["mcpServers"]?["clipslots-project"]?["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let parsed = try AgentExternalReadOnlyMCPConfiguration.parse(arguments: Array(args.dropFirst()))
        check(parsed.scope == scope && parsed.snapshotID == graph.snapshotID && parsed.sessionID == sessionID, "handoff MCP settings parse as actual CLI scoped route")
        let originalArgs = ["--project-id", project, "--canvas-id", "canvas"]
        let latest = try AgentExternalReadOnlyMCPConfiguration.parse(arguments: originalArgs)
        check(latest.scope == scope && latest.snapshotID == nil, "original exact project/canvas route supported")
        let invalidArguments: [[String]] = [
            ["--project-id", project], ["--canvas-id", "canvas"],
            originalArgs + ["--project", "different"],
            originalArgs + ["--snapshot-id", "invalid"],
            originalArgs + ["--session-id", "invalid"],
            originalArgs + ["--skills", "write"], originalArgs + ["--read-only", "--read-only"]
        ]
        for invalid in invalidArguments {
            artifactThrows(check, "MCP rejects missing, conflicting or unsafe options") {
                _ = try AgentExternalReadOnlyMCPConfiguration.parse(arguments: invalid)
            }
        }
        let artifacts = try AgentArtifactRepository(directory: root.appendingPathComponent("agent_artifacts"))
        let key = try AgentArtifactKey(scope: scope, path: "output.txt")
        let exactRevision: UInt64 = 9_007_199_254_740_993
        _ = try artifacts.merge(.init(key: key, revision: exactRevision, content: Data("Hello \u{4E2D}\u{6587}".utf8), mimeType: "text/plain"))
        _ = try artifacts.merge(.init(key: AgentArtifactKey(projectID: "foreign", canvasID: "canvas", path: key.path),
                                     revision: 1, content: Data("foreign secret".utf8)))
        _ = try artifacts.merge(.init(key: AgentArtifactKey(projectID: project, canvasID: "other-canvas", path: "hidden.txt"),
                                     revision: 1, content: Data("other canvas secret".utf8)))
        let tools = try AgentExternalReadOnlyMCPTools(configuration: parsed, dataRoot: root)
        let latestTools = try AgentExternalReadOnlyMCPTools(configuration: latest, dataRoot: root)
        check(latestTools.snapshotID == graph.snapshotID, "un-pinned route binds saved project snapshot")
        let names = Set(tools.specs().map(\.name))
        check(names.contains("canvas_read_node") && names.contains("canvas_read_group")
              && names.contains("artifact_read") && names.count == 12, "read-only catalog exposes real snapshot and artifact tools")
        check(!names.contains("write_slot") && !names.contains("run_skill_script"), "read-only handoff never includes normal mutations/scripts")
        func call(_ name: String, _ fields: JSONValue = [:]) async throws -> AgentToolResult {
            await tools.execute(call: .init(id: "test", name: name, argumentsJSON: try fields.encodedText()))
        }
        func json(_ result: AgentToolResult) throws -> JSONValue { try JSONValue.decode(jsonText: result.content) }
        let identity = try json(await call("clipslots_context"))
        check(identity["project_id"]?.stringValue == project && identity["read_only"]?.boolValue == true, "context exposes immutable project read-only scope")
        check(identity["session_id"]?.stringValue == sessionID.uuidString && identity["snapshot_id"]?.stringValue == graph.snapshotID.uuidString, "context exposes session correlation and exact fixed snapshot")
        let list = try await call("artifact_list")
        let items = try json(list)["artifacts"]?.arrayValue ?? []
        check(items.count == 1 && !list.content.contains("secret") && !list.content.contains("Hello"), "artifact list is scoped metadata only")
        let read = try json(await call("artifact_read", ["path": "output.txt", "revision": .string(String(exactRevision)), "limit": 2]))
        check(read["chunk"]?.stringValue == "He" && read["next_offset"]?.intValue == 2, "artifact content paged and exact UInt64 revision accepted")
        check(try json(await call("artifact_metadata", ["path": "output.txt"]))["artifact"]?["revision"]?.stringValue == String(exactRevision),
              "revision metadata never loses precision to JSON Double")
        check(try await call("artifact_read", ["path": "output.txt", "revision": .string(String(exactRevision - 1))]).isFailure, "stale artifact revision rejected")
        check(try await call("artifact_read", ["path": "output.txt", "revision": .number(Double(exactRevision))]).isFailure, "lossy numeric revision rejected")
        check(try await call("artifact_metadata", ["path": "../foreign"]).isFailure, "artifact traversal rejected by MCP")
        check(try await call("artifact_metadata", ["path": "output.txt", "project_id": "foreign"]).isFailure, "caller cannot change immutable artifact scope")
        check(try await call("artifact_read", ["path": "output.txt", "revision": .string(String(exactRevision)), "offset": -1]).isFailure,
              "artifact page bounds enforced")
        let rejectedWrite = try await call("write_slot")
        let rejectedShell = try await call("shell")
        check(rejectedWrite.isFailure && rejectedShell.isFailure, "read-only tools reject invented writes and shell")
        let canvasFields: JSONValue = ["snapshot_id": .string(graph.snapshotID.uuidString), "node_id": .string(node.id), "field": "body"]
        check(try json(await call("canvas_read_node", canvasFields))["chunk"]?.stringValue == "fixed snapshot body", "real canvas reader delivers saved snapshot body")
        check(try await call("canvas_overview", ["snapshot_id": .string(UUID().uuidString)]).isFailure, "foreign snapshot ID rejected")
        check(try await call("canvas_read_node", ["snapshot_id": .string(graph.snapshotID.uuidString), "node_id": "foreign", "field": "body"]).isFailure, "foreign canvas node rejected")
        let binaryKey = try AgentArtifactKey(scope: scope, path: "data.bin")
        _ = try artifacts.merge(.init(key: binaryKey, revision: 1, content: Data([255, 254, 0])))
        let binary = try json(await call("artifact_read", ["path": "data.bin", "revision": "1", "limit": 2]))
        check(binary["encoding"]?.stringValue == "base64" && binary["chunk"]?.stringValue == Data([255, 254]).base64EncodedString(),
              "binary artifact read is bounded base64, not a file URL")
        _ = try artifacts.merge(.init(key: key, revision: exactRevision + 1))
        check(try await call("artifact_read", ["path": "output.txt", "revision": .string(String(exactRevision + 1))]).isFailure, "old retained bytes cannot pretend to be current MCP content")
        let wrongScope = try AgentArtifactScope(projectID: "foreign", canvasID: "canvas")
        artifactThrows(check, "snapshot construction rejects wrong project binding") {
            _ = try AgentExternalReadOnlyMCPTools(configuration: .init(scope: wrongScope), snapshot: snapshot, artifacts: artifacts)
        }
        let wrongCanvas = try AgentArtifactScope(projectID: project, canvasID: "other-canvas")
        artifactThrows(check, "MCP rejects another canvas in the same project") {
            _ = try AgentExternalReadOnlyMCPTools(configuration: .init(scope: wrongCanvas, snapshotID: graph.snapshotID), dataRoot: root)
        }
        var legacyJSON = try JSONValue.decode(jsonText: String(decoding: JSONEncoder().encode(snapshot), as: UTF8.self)).objectValue!
        legacyJSON.removeValue(forKey: "canvasID")
        let legacy = try JSONDecoder().decode(CanvasAgentSnapshot.self, from: JSONEncoder().encode(JSONValue.object(legacyJSON)))
        check(legacy.canvasID == graph.projectID, "legacy native snapshot binds its original project canvas")
        artifactThrows(check, "missing project snapshot does not fall back to normal tools") {
            _ = try AgentExternalReadOnlyMCPTools(configuration: .init(scope: wrongScope), dataRoot: root)
        }
        let protocolList = await AgentMCPServer.response(to: ["id": 1, "method": "tools/list"], tools: tools)
        check(protocolList?["result"]?["tools"]?.arrayValue?.count == 12, "actual MCP response advertises scoped catalog")
        let denied = await AgentMCPServer.response(to: ["id": 2, "method": "tools/call", "params": ["name": "write_slot", "arguments": [:]]], tools: tools)
        check(denied?["result"]?["isError"]?.boolValue == true, "actual MCP rejects unadvertised mutation")
        let normal = AgentToolRegistry()
        check(normal.specs().contains { $0.name == "write_slot" }, "normal enabled registry behavior remains unchanged")
        var nextGraph = graph
        nextGraph.snapshotID = UUID()
        nextGraph.nodes[0].bodyText = "later snapshot body"
        try CanvasAgentSnapshotStore(root: root).save(.init(graph: nextGraph, runs: [], canvasID: scope.canvasID))
        let folder = root.appendingPathComponent("agent-canvas-snapshots")
            .appendingPathComponent(CanvasWorkflowSnapshot.digest(Data(project.utf8)))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                             ofItemAtPath: folder.appendingPathComponent(nextGraph.snapshotID.uuidString + ".json").path)
        check(try AgentExternalReadOnlyMCPTools(configuration: latest, dataRoot: root).snapshotID == nextGraph.snapshotID, "new process binds newest saved project snapshot")
        check(try json(await call("canvas_read_node", canvasFields))["chunk"]?.stringValue == "fixed snapshot body", "existing MCP scope keeps immutable startup snapshot")
    } catch { check(false, "project read-only MCP suite: \(error)") }
}

#if AGENT_ARTIFACT_STANDALONE
@main
private struct AgentArtifactStandaloneTests {
    @MainActor
    static func main() async {
        var passed = 0
        var failed = 0
        let check: (Bool, String) -> Void = { ok, name in
            if ok { passed += 1 }
            else { failed += 1; print("FAIL: \(name)") }
        }
        artifactRepositoryTests(check)
        await artifactExternalTests(check)
        await artifactMCPTests(check)
        print("Artifact / external handoff: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
#else
func runAgentArtifactTests(_ t: TestRunner) {
    artifactRepositoryTests(t.check)
    smokeAwait {
        await artifactExternalTests(t.check)
        await artifactMCPTests(t.check)
    }
}
#endif
