#if DEBUG
import AppKit
import SwiftUI
import WebKit
import ClipSlotsKit

/// Real NSHostingView, current Panel, real HTTP release and opaque iframe.
/// In-process AX actions are instrumentation; no foreground or physical input claim.
@MainActor
func runArtifactRemotePanelRegression(directory: URL) async -> [String: Any] {
    var checks: [String] = [], failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        (condition ? checks.append(name) : failures.append(name))
        try? JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks,
            "failures": failures, "partial": true], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("partial-report.json"), options: .atomic)
    }
    NativeAccessibilityProbe.enable()
    func widgetState(_ report: JSONValue?) -> JSONValue? {
        let result = report?["notifications"]?.arrayValue?.first { $0["method"] == "ui/notifications/tool-result" }
        return result?["params"]?["_meta"]?["tapnow/widgetState"]
    }
    do {
        let config = try JSONDecoder().decode(JSONValue.self,
            from: Data(contentsOf: directory.appendingPathComponent("fixture-config.json")))
        let key = try AgentArtifactKey(projectID: "fixture", canvasID: "fixture", path: "remote-panel.html")
        let projection = try AgentArtifactPageData(revision: .init(messageSequence: 1, partIndex: 0),
            toolInput: ["prompt": "fixture"], toolResult: ["summary": "panel"])
        func record(_ owner: UUID, revision: UInt64 = 1) throws -> AgentArtifactRecord {
            let repository = try AgentArtifactRepository(directory:
                directory.appendingPathComponent("records").appendingPathComponent(owner.uuidString))
            return try repository.merge(.init(key: key, revision: revision, content: Data("<p>LOCAL_CACHE</p>".utf8),
                mimeType: "text/html", pageProjection: projection, pageProjectionConversationID: owner,
                pageResourceURI: "ui://tapnow/previs@v3"))
        }
        func endpoint(_ variant: String) throws -> AgentArtifactPageResourceEndpoint {
            guard let base = config[variant]?.stringValue,
                  let result = AgentArtifactPageResourceEndpoint(
                    channelURL: URL(string: base + "/mcp-apps/channels/current.json"),
                    proxyURL: URL(string: base + "/012345abcd/mcp-app-proxy.html")!, allowsLoopback: true)
            else { throw AgentArtifactRPCError.invalid }
            return result
        }
        let driver = RemotePanelDriver(directory: directory)
        defer { driver.close(); driver.releasePending(); try? driver.writeEvidence() }
        let owner = UUID()
        let first = try record(owner)
        func mount(_ variant: String, owner: UUID = owner, revision: UInt64 = 1,
                   enabled: Bool = true, replaceRecord: AgentArtifactRecord? = nil) throws {
            let value = try replaceRecord ?? record(owner, revision: revision)
            let page = AgentArtifactPageIdentity(key: key, conversationID: owner, revision: revision)
            driver.mount(record: value, identity: page, endpoint: try endpoint(variant), enabled: enabled)
        }

        try mount("manual", replaceRecord: first)
        check(await driver.ready(), "remote native panel initializes actual opaque iframe")
        check(driver.operations.filter { $0["operation"] == "get_state" }.count == 1,
              "remote native panel reads initial persisted state exactly once")
        let initial = await driver.probe("manual-initial")
        check(initial?["initialized"]?["result"]?["protocolVersion"] == "2026-01-26",
              "remote native panel completes standard initialize")
        check(widgetState(initial) == ["owner": .string(owner.uuidString)],
              "remote native panel sends current owner widget state")
        check(await driver.expanded() == false && driver.height <= 300,
              "release disables source previs auto-expand and clamps initial height")
        check(driver.press("agent-artifact-expand"), "native expand button invokes real panel action")
        check(await driver.wait { await driver.expanded() == true && driver.height >= 520 },
              "manual native expand changes remote host state and actual height")
        let nonce = await driver.value("window.__clipslotsNativeInstance")
        await driver.send("fixture/draft", ["tag": "draft", "text": "保留远端草稿🙂"])
        _ = await driver.report("draft")
        check(driver.press("agent-artifact-expand"), "native collapse button invokes real panel action")
        check(await driver.wait { await driver.expanded() == false && driver.height <= 300 },
              "native collapse restores release inline height")
        let draft = await driver.probe("collapsed")
        let collapsedNonce = await driver.value("window.__clipslotsNativeInstance")
        check(draft?["draft"] == "保留远端草稿🙂" && nonce == collapsedNonce,
              "remote native collapse retains iframe instance and draft")
        for (height, expected) in [(45.0, 100.0), (240.0, 240.0), (900.0, 300.0)] {
            let response = await driver.rpc("ui/notifications/size-changed", ["height": .number(height)])
            let resized = await driver.wait { abs(driver.height - expected) < 1 }
            check(response?["error"] == nil && resized,
                  "remote native size \(height) obeys release cap \(expected)")
        }
        let beforeInvalid = driver.height
        let invalid = await driver.rpc("ui/notifications/size-changed", ["height": "240"])
        check(invalid?["error"]?["code"] == -32602 && driver.height == beforeInvalid,
              "remote native invalid size cannot change mounted layout")
        let set = await driver.rpc("tapnow/setWidgetState", ["state": ["draft": "持久🙂"]])
        check(set?["error"] == nil && driver.widgetStates[owner.uuidString] == ["draft": "持久🙂"],
              "remote native state setter persists to original owner")
        let context: JSONValue = ["content": [["type": "text", "text": "当前页面上下文🙂"]]]
        let model = await driver.rpc("ui/update-model-context", context)
        check(model?["error"] == nil && driver.contexts.last?["owner"] == .string(owner.uuidString)
            && driver.contexts.last?["arguments"] == context,
              "remote native model_context reaches current owner with exact arguments")
        driver.web?.reload()
        check(await driver.wait {
            let next = await driver.value("window.__clipslotsNativeInstance")
            return next != nil && next != nonce && driver.states.last == .ready
        }, "real remote native WebKit reload rotates page identity")
        let afterReload = await driver.probe("reload")
        check(widgetState(afterReload) == ["draft": "持久🙂"],
              "real remote native reload reads latest persisted state")
        driver.contextSuspended = true
        await driver.send("fixture/rpc", ["tag": "old-context", "method": "ui/update-model-context",
            "arguments": context, "id": "late-context"])
        check(await driver.wait { driver.pendingContexts.count == 1 },
              "remote native old model_context starts before owner replacement")
        let secondOwner = UUID()
        try mount("manual", owner: secondOwner)
        check(await driver.ready(), "remote native replacement owner initializes")
        driver.releasePending()
        let second = await driver.probe("new-owner")
        check(widgetState(second) == ["owner": .string(secondOwner.uuidString)]
            && driver.contexts.count == 1,
              "late cancelled model_context cannot commit or report to replacement owner")
        driver.contextSuspended = false
        try mount("manual", owner: secondOwner, enabled: false)
        check(await driver.ready(), "remote native permission revocation replaces page")
        let deniedContext = await driver.rpc("ui/update-model-context", context)
        check(deniedContext?["error"]?["code"] == -32601 && driver.contexts.count == 1,
              "remote native revoked model_context never reaches handler")

        driver.close()
        driver.stateMode = .normal
        try mount("auto", owner: secondOwner)
        let autoReady = await driver.ready()
        let autoExpanded = await driver.wait { await driver.expanded() == true }
        check(autoReady && autoExpanded,
              "release automatic expansion reaches real remote native panel")
        check(driver.height >= 520, "automatic expansion grows actual mounted WKWebView")
        let openNonce = await driver.value("window.__clipslotsNativeInstance")
        check(driver.press("agent-artifact-close") && driver.closeRequests == 1,
              "native close action reaches panel owner")
        driver.close()
        try mount("auto", owner: secondOwner)
        check(await driver.ready(), "remote native panel reopens same owner")
        let reopenNonce = await driver.value("window.__clipslotsNativeInstance")
        check(reopenNonce != nil && reopenNonce != openNonce,
              "remote native close and reopen rotate page identity")
        driver.close()

        // Before the manifest resolves, source previs permits the button.
        try mount("deny", owner: secondOwner)
        check(await driver.wait { driver.find("agent-artifact-expand") != nil },
              "source fallback expand button exists before remote release resolution")
        check(driver.press("agent-artifact-expand"), "native early expansion occurs before denying release")
        check(await driver.ready(), "denying release still initializes opaque remote page")
        let denied = await driver.probe("denying-release")
        check(driver.find("agent-artifact-expand") == nil && driver.height <= 240,
              "denying release clears early expansion and clamps actual native height")
        check(denied?["initialized"]?["result"]?["hostContext"]?["displayMode"] == "inline"
            && denied?["initialized"]?["result"]?["hostContext"]?["availableDisplayModes"] == ["inline"],
              "denying release advertises only supported inline host mode")
        driver.close()

        for (mode, label) in [(RemotePanelDriver.StateMode.failure, "throw"),
                              (.invalid, "invalid object"), (.oversize, "oversize")] {
            driver.stateMode = mode
            try mount("manual", owner: secondOwner)
            check(await driver.wait { driver.isError }, "remote native state \(label) produces explicit error")
            check(driver.findByLabel("重新加载预览") != nil,
                  "remote native state \(label) exposes preview retry")
            driver.stateMode = .normal
            check(driver.pressLabel("重新加载预览"), "native preview retry after state \(label) invokes action")
            check(await driver.ready(), "native preview retry after state \(label) recovers current page")
            driver.close()
        }
        driver.stateMode = .suspended
        let timeoutStart = ProcessInfo.processInfo.systemUptime
        try mount("manual", owner: secondOwner)
        check(await driver.wait(seconds: 18) { driver.isError },
              "hung remote native get_state has explicit bounded initialization timeout")
        check(driver.web != nil && driver.findByLabel("重新加载预览") != nil,
              "hung remote native get_state keeps mounted preview and retry available")
        driver.snapshots.append(["tag": "hang-timeout", "elapsed": .number(ProcessInfo.processInfo.systemUptime - timeoutStart),
            "webMounted": .bool(driver.web != nil), "error": .bool(driver.isError)])
        driver.stateMode = .normal
        let retryPressed = driver.pressLabel("重新加载预览")
        let retryReady = await driver.ready()
        check(retryPressed && retryReady, "native explicit retry recovers after hung state timeout")
        let stableNonce = await driver.value("window.__clipslotsNativeInstance")
        driver.releasePending()
        let afterLate = await driver.probe("late-state")
        let lateNonce = await driver.value("window.__clipslotsNativeInstance")
        check(stableNonce != nil && stableNonce == lateNonce && afterLate != nil && driver.states.last == .ready,
              "late timed-out state completion cannot replace retried remote page")
        driver.close()

        driver.stateMode = .suspended
        try mount("manual", owner: secondOwner)
        check(await driver.wait { !driver.pendingStates.isEmpty }, "old owner state read is actually suspended")
        driver.stateMode = .normal
        let thirdOwner = UUID()
        try mount("manual", owner: thirdOwner, revision: 2)
        check(await driver.ready(), "new owner and revision initialize during old pending state")
        driver.releasePending()
        let current = await driver.probe("revision-replaced")
        check(widgetState(current) == ["owner": .string(thirdOwner.uuidString)],
              "late old-owner state cannot overwrite replacement revision")
        driver.close()
        try driver.writeEvidence()
    } catch { failures.append("fixture error: \(error)") }
    return ["passed": checks.count, "checks": checks, "failures": failures,
            "foregroundAccepted": false, "systemIMEAccepted": false, "M06Accepted": false, "goalComplete": false]
}

@MainActor
private final class RemotePanelDriver {
    enum StateMode { case normal, failure, invalid, oversize, suspended }
    let directory: URL
    var host: NSHostingView<AgentArtifactPanel>?
    var window: NSWindow?
    var stateMode: StateMode = .normal
    var states: [AgentArtifactResourceState] = []
    var operations: [JSONValue] = [], contexts: [JSONValue] = [], snapshots: [JSONValue] = []
    var widgetStates: [String: JSONValue] = [:]
    var pendingStates: [(CheckedContinuation<JSONValue, Error>, JSONValue)] = []
    var pendingContexts: [CheckedContinuation<JSONValue, Error>] = []
    var contextSuspended = false
    var closeRequests = 0
    init(directory: URL) { self.directory = directory }
    var web: WKWebView? {
        func find(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            for child in view.subviews { if let web = find(child) { return web } }
            return nil
        }
        host?.layoutSubtreeIfNeeded()
        return host.flatMap(find)
    }
    var height: Double { Double(web?.frame.height ?? -1) }
    var isError: Bool { if case .error = states.last { return true }; return false }
    func find(_ id: String) -> AnyObject? {
        guard let host else { return nil }
        host.layoutSubtreeIfNeeded()
        return NativeAccessibilityProbe.elements(host).first { $0.accessibilityIdentifier?() == id }
    }
    func findByLabel(_ label: String) -> AnyObject? {
        guard let host else { return nil }
        host.layoutSubtreeIfNeeded()
        return NativeAccessibilityProbe.elements(host).first { $0.accessibilityLabel?() == label }
    }
    func press(_ id: String) -> Bool { find(id)?.accessibilityPerformPress?() == true }
    func pressLabel(_ label: String) -> Bool { findByLabel(label)?.accessibilityPerformPress?() == true }
    func mount(record: AgentArtifactRecord, identity: AgentArtifactPageIdentity,
               endpoint: AgentArtifactPageResourceEndpoint, enabled: Bool) {
        states = []
        let owner = identity.conversationID.uuidString
        let request: ((String, String, JSONValue) async throws -> JSONValue)? = enabled ? { [self] operation, _, args in
            operations.append(["owner": .string(owner), "operation": .string(operation), "arguments": args])
            switch operation {
            case "get_state":
                let state = widgetStates[owner] ?? ["owner": .string(owner)]
                switch stateMode {
                case .normal: return state
                case .failure: throw AgentArtifactRPCError.failed
                case .invalid: return ["invalid"]
                case .oversize: return ["large": .string(String(repeating: "x", count: 65 * 1024))]
                case .suspended:
                    return try await withCheckedThrowingContinuation { pendingStates.append(($0, state)) }
                }
            case "set_state": try Task.checkCancellation(); widgetStates[owner] = args; return [:]
            case "model_context":
                if contextSuspended {
                    _ = try await withCheckedThrowingContinuation { pendingContexts.append($0) }
                }
                try Task.checkCancellation()
                contexts.append(["owner": .string(owner), "arguments": args]); return [:]
            default: throw AgentArtifactRPCError.unsupported
            }
        } : nil
        let panel = AgentArtifactPanel(record: record, pageIdentity: identity, onAction: { _ in },
            onClose: { [self] in closeRequests += 1 }, onPreviewState: { [self] in states.append($0) }, onRequest: request)
            .loadingPageResources(using: .init(allowsLoopback: true), endpoint: endpoint)
        if let host { host.rootView = panel }
        else {
            let view = NSHostingView(rootView: panel)
            let next = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 1000),
                styleMask: [.titled], backing: .buffered, defer: false)
            next.isReleasedWhenClosed = false; next.contentView = view
            host = view; window = next
        }
    }
    func close() {
        if let host { snapshots.append(["tag": "close", "axLabels": .array(
            NativeAccessibilityProbe.elements(host).compactMap { $0.accessibilityLabel?() }.map(JSONValue.string))]) }
        window?.contentView = nil; window?.close(); window = nil; host = nil; states = []
    }
    func releasePending() {
        let states = pendingStates; pendingStates = []
        states.forEach { $0.0.resume(returning: $0.1) }
        let contexts = pendingContexts; pendingContexts = []
        contexts.forEach { $0.resume(returning: [:]) }
    }
    func value(_ code: String) async -> JSONValue? {
        guard let web else { return nil }
        return await withCheckedContinuation { continuation in
            web.evaluateJavaScript(code) { value, error in
                guard error == nil, let value,
                      let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                      let json = try? JSONDecoder().decode(JSONValue.self, from: bytes) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: json)
            }
        }
    }
    func instrument() async {
        _ = await value("""
            if(!window.__remotePanelObserver){
              window.__remotePanelObserver=true;window.fixtureReports=[];
              addEventListener('message',e=>{
                if(e.source===document.querySelector('iframe')?.contentWindow&&e.data?.method==='fixture/report')
                  window.fixtureReports.push(e.data.params);
              });
            } null
            """)
    }
    func wait(seconds: Double = 4, _ predicate: () async -> Bool) async -> Bool {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < until {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
    func ready() async -> Bool {
        await wait {
            let mounted = await value("!!document.querySelector('iframe')")
            return states.last == .ready && mounted == true
        }
    }
    func send(_ method: String, _ params: JSONValue) async {
        await instrument()
        let body: JSONValue = ["jsonrpc": "2.0", "method": .string(method), "params": params]
        guard let text = try? AgentArtifactTemplateHTML.literal(body) else { return }
        _ = await value("document.querySelector('iframe').contentWindow.postMessage(\(text),'*');null")
    }
    func report(_ tag: String) async -> JSONValue? {
        let literal = (try? AgentArtifactTemplateHTML.literal(.string(tag))) ?? "null"
        let query = "window.fixtureReports?.find(x=>x.tag===\(literal))"
        guard await wait({ await value(query) != nil }) else { return nil }
        let result = await value(query)
        snapshots.append(["tag": .string(tag), "height": .number(height), "report": result ?? .null])
        return result
    }
    func probe(_ tag: String) async -> JSONValue? {
        await send("fixture/probe", ["tag": .string(tag)])
        return await report(tag)
    }
    func expanded() async -> JSONValue? {
        let tag = "expanded-" + UUID().uuidString
        return await probe(tag)?["notifications"]?.arrayValue?.last { $0["method"] == "tapnow/presentationState" }?["params"]?["expanded"]
    }
    func rpc(_ method: String, _ params: JSONValue) async -> JSONValue? {
        let tag = UUID().uuidString
        await send("fixture/rpc", ["tag": .string(tag), "method": .string(method), "arguments": params, "id": .string(tag)])
        return await report(tag)?["responses"]?[tag]
    }
    func writeEvidence() throws {
        let raw: JSONValue = ["operations": .array(operations), "contexts": .array(contexts), "snapshots": .array(snapshots),
            "states": .array(states.map { .string(String(describing: $0)) })]
        try JSONEncoder().encode(raw).write(to: directory.appendingPathComponent("remote-panel-webkit.json"))
    }
}
#endif
