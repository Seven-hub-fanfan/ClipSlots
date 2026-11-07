#if DEBUG
import AppKit
import SwiftUI
import WebKit
import ClipSlotsKit

@MainActor
enum AgentOnboardingRegression {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CLIPSLOTS_ONBOARDING_REGRESSION"] else { return }
        guard path.hasPrefix("/private/tmp/clipslots-agent-background-"),
              env["CLIPSLOTS_DATA_DIR"] == path + "/data",
              env["CLIPSLOTS_CONFIG_PATH"] == path + "/config.toml",
              Bundle.main.bundleIdentifier == "com.clipslots.app.agent-onboarding-regression",
              Bundle.main.object(forInfoDictionaryKey: "ClipSlotsIsolatedCandidate") as? Bool == true else { exit(2) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            await run(root: URL(fileURLWithPath: path))
        }
    }

    private static func run(root: URL) async {
        var passes = 0, failures: [String] = [], diagnostics: [[String: Any]] = []
        func check(_ condition: Bool, _ name: String) {
            if condition { passes += 1 } else { failures.append(name) }
        }
        func settle(_ seconds: Double = 0.2) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        }
        func wait(_ condition: () -> Bool) async {
            for _ in 0..<200 { if condition() { return }; await settle(0.02) }
        }
        do {
            NativeAccessibilityProbe.enable()
            try await AgentFollowupRegression.run(root: root, check: check)
            if ProcessInfo.processInfo.environment["CLIPSLOTS_FOLLOWUP_STATIC_ONLY"] == "1" {
                let result: [String: Any] = ["passed": failures.isEmpty, "passes": passes, "failures": failures,
                    "fixtureOnly": true, "liveProviderCredentialsUsed": false,
                    "scope": "connector-state-and-static-presentation", "live_ui_verified": false]
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("followup-static-regression.json"))
                print("Static follow-up: \(passes) passed; \(failures.count) failed")
                exit(failures.isEmpty ? 0 : 1)
            }
            let prefs = UserDefaults(suiteName: "agent-onboarding-fixture-\(UUID().uuidString)")!
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.setColor(.red, atX: 0, y: 0)
            let png = bitmap.representation(using: .png, properties: [:])!
            let editorAttachments = (0..<7).map {
                SlotContent.SlotAttachment(name: "image-\($0).png", type: .file, data: png)
            }
            try await ManagedImagePathRegression.run(root: root, png: png, check: check)
            for provider in AgentAPIProvider.allCases {
                let base = provider == .custom ? "https://fixture.example/v1" : provider.baseURL
                let profile = try provider.profile(baseURL: base, model: "fixture-model")
                let http = OnboardingWireFixture(contract: provider.contract)
                let transport = AgentProviderTransport(profile: profile, http: http, streaming: http)
                try await transport.verify(apiKey: "fixture-secret")
                let requests = await http.requests
                let request = requests[0]
                check(request.value(forHTTPHeaderField: profile.authHeader) == profile.authPrefix + "fixture-secret", "\(provider.rawValue): native authentication header")
                check(!request.url!.absoluteString.contains("fixture-secret"), "\(provider.rawValue): key excluded from URL")
                let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
                check(body["stream"]?.boolValue != true && body["tools"] == nil, "\(provider.rawValue): verification has no tools or streaming")
                switch provider {
                case .claude:
                    check(request.url!.path.hasSuffix("/messages") && body["messages"] != nil &&
                          request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Claude Messages request")
                case .gemini:
                    check(request.url!.path.hasSuffix("/models/fixture-model:generateContent") &&
                          body["contents"] != nil && body["model"] == nil, "Gemini native generateContent request")
                default:
                    check(request.url!.path.hasSuffix("/chat/completions") && body["model"]?.stringValue == "fixture-model", "\(provider.rawValue): Chat request")
                }
                let chatHTTP = OnboardingWireFixture(contract: provider.contract, toolRound: true)
                let service = AgentService(transport: AgentProviderTransport(profile: profile, http: chatHTTP, streaming: chatHTTP),
                                           secretStore: AgentInMemorySecretStore(key: "fixture-secret"))
                let tools = OnboardingTools()
                let result = try await service.run(history: [.init(role: .user, content: "fixture")],
                    config: .init(endpoint: URL(string: profile.endpoint)!, model: profile.model), tools: tools, onEvent: { _ in })
                check(result.last?.content == "完成🙂" && result.contains(where: { $0.role == .tool }), "\(provider.rawValue): real adapter completes tool round and Unicode reply")
                check(tools.executions == 1, "\(provider.rawValue): tool executes exactly once")
                let rounds = await chatHTTP.requests
                check(rounds.count == 2, "\(provider.rawValue): tool result submitted on second round")
                if provider == .gemini {
                    let second = try JSONDecoder().decode(JSONValue.self, from: rounds[1].httpBody!)
                    check(second["contents"]?.arrayValue?.last?["parts"]?.arrayValue?.first?["functionResponse"]?["name"]?.stringValue == "fixture_read", "Gemini retains original tool name")
                }
                let imageHTTP = OnboardingWireFixture(contract: provider.contract)
                let imageService = AgentService(transport: AgentProviderTransport(profile: profile, http: imageHTTP, streaming: imageHTTP),
                    secretStore: AgentInMemorySecretStore(key: "fixture-secret"))
                let edited = try await SlotEditorAI.rewrite(text: "保留正文", instruction: "比较附件", html: false,
                    attachments: editorAttachments, service: imageService)
                let imageRequests = await imageHTTP.requests
                let imageBody = try JSONDecoder().decode(JSONValue.self, from: imageRequests[0].httpBody!)
                let parts = provider == .gemini
                    ? imageBody["contents"]?.arrayValue?.last?["parts"]?.arrayValue
                    : imageBody["messages"]?.arrayValue?.last?["content"]?.arrayValue
                check(edited == "完成🙂" && imageRequests.count == 1, "\(provider.rawValue): editor seven attachments use actual adapter")
                check(parts?.count == 8 && parts?.dropFirst().allSatisfy {
                    $0["image_url"] != nil || $0["inlineData"] != nil || $0["source"] != nil
                } == true, "\(provider.rawValue): unknown capability preserves all seven image parts")
                check(editorAttachments.allSatisfy { $0.data == png }, "\(provider.rawValue): editor preserves source attachments")
            }
            let errorProfile = try AgentAPIProvider.gpt.profile(baseURL: AgentAPIProvider.gpt.baseURL, model: "fixture")
            let gatewaySelection = AgentBackendSelection(scope: .sidebar, kind: .gateway,
                backend: OnboardingNoKeyBackend(), requiresAPIKey: false, supportsCanvasReadTools: true,
                gatewayConfiguration: AgentConfig(model: "deepseek-v4-pro"),
                gatewayBaseURL: URL(string: "https://proxy.example/v1")!)
            check(gatewaySelection.normalized(AgentConfig(model: "deepseek-v4-pro")).resolvedImageSupport == nil,
                  "gateway uses its actual endpoint rather than official DeepSeek capability assumptions")
            let errorHTTP = OnboardingWireFixture(contract: .chatCompletions, status: 400,
                errorBody: ["error": ["message": "maximum 3 images; credential fixture-secret", "code": "image_limit"]])
            let rejectedService = AgentService(transport: AgentProviderTransport(profile: errorProfile, http: errorHTTP, streaming: errorHTTP),
                secretStore: AgentInMemorySecretStore(key: "fixture-secret"))
            do {
                _ = try await SlotEditorAI.rewrite(text: "保留正文", instruction: "比较图片", html: false,
                    attachments: editorAttachments, service: rejectedService)
                check(false, "provider image limit rejected")
            } catch {
                let message = error.localizedDescription
                check(message.contains("maximum 3 images") && !message.contains("fixture-secret"),
                      "editor displays provider image count error and redacts credential")
            }
            let p = try AgentAPIProvider.claude.profile(baseURL: AgentAPIProvider.claude.baseURL, model: "fixture")
            let denied = AgentProviderTransport(profile: p, http: OnboardingWireFixture(contract: .anthropicMessages, status: 401))
            do { try await denied.verify(apiKey: "fixture-secret"); check(false, "401 rejected") }
            catch { check((error as? AgentError) == .http(status: 401, message: nil, code: nil), "401 rejected before save") }
            let malformed = AgentProviderTransport(profile: p, http: OnboardingWireFixture(contract: .anthropicMessages, malformed: true))
            do { try await malformed.verify(apiKey: "fixture-secret"); check(false, "Malformed response rejected") }
            catch { check(true, "Malformed response rejected") }
            check((try? AgentAPIProvider.custom.profile(baseURL: "http://remote.example/v1", model: "x")) == nil, "remote plaintext endpoint rejected")
            check((try? AgentAPIProvider.gpt.profile(baseURL: "https://a:b@api.example/v1", model: "x")) == nil, "credential in endpoint rejected")
            let legacy = try AgentAPIProvider.deepseek.profile(baseURL: AgentAPIProvider.deepseek.baseURL, model: "fixture")
            check(legacy.keyAccount == AgentKeychain.account, "default DeepSeek reuses legacy Keychain account")
            let other = try AgentAPIProvider.deepseek.profile(baseURL: "https://other.example/v1", model: "fixture")
            check(other.keyAccount != legacy.keyAccount, "different endpoint uses separate credential account")
            let grok = try AgentAPIProvider.grok.profile(baseURL: AgentAPIProvider.grok.baseURL, model: "grok-4.7")
            let kimi = try AgentAPIProvider.kimi.profile(baseURL: AgentAPIProvider.kimi.baseURL, model: "kimi-k3")
            check(Set([grok.keyAccount, kimi.keyAccount, legacy.keyAccount]).count == 3,
                  "Grok, Kimi and DeepSeek credentials have separate accounts")
            let alternateGrok = try AgentAPIProvider.grok.profile(baseURL: "https://other.example/v1", model: "fixture")
            check(alternateGrok.keyAccount != grok.keyAccount, "Grok endpoint changes isolate credentials")
            let selection = AgentConnectionController(scope: .sidebar, defaults: prefs)
            selection.select(.grok); selection.modelID = "edited-grok"; selection.keyDraft = "fixture-secret"
            selection.select(.kimi)
            check(selection.baseURL == AgentAPIProvider.kimi.baseURL && selection.modelID == "kimi-k3" &&
                  selection.keyDraft.isEmpty, "switching to Kimi resets endpoint, model and key draft")
            selection.select(.grok)
            check(selection.baseURL == AgentAPIProvider.grok.baseURL && selection.modelID == "grok-4.7",
                  "switching to Grok restores its own defaults")
            try AgentConnectionPreferences.save(kimi, scope: "sidebar", defaults: prefs)
            selection.select(.kimi)
            check(AgentConnectionPreferences.provider(AgentConnectionPreferences.profile(scope: "sidebar", defaults: prefs)) == .kimi &&
                  selection.modelID == kimi.model && selection.baseURL == kimi.endpoint,
                  "saved Kimi profile reopens with its own configuration")
            prefs.removeObject(forKey: AgentConnectionPreferences.key(scope: "sidebar"))

            var stored = false
            var probeReleased = false
            var probeError: AgentKeychainError?
            var probeCount = 0
            var verificationFails = false
            let controller = AgentConnectionController(scope: .sidebar, defaults: prefs,
                verify: { profile, key in
                    if verificationFails { throw AgentError.http(status: 401, message: nil, code: nil) }
                    try await AgentProviderTransport(profile: profile, http: OnboardingWireFixture(contract: profile.contract)).verify(apiKey: key)
                },
                saveKey: { _, _ in stored = true })
            let model = AgentChatModel(displayName: "新对话",
                service: AgentService(transport: AgentScriptedTransport(steps: []), secretStore: AgentInMemorySecretStore(key: "fixture")),
                persistenceURL: root.appendingPathComponent("session.json"))
            UserDefaults.standard.set(440.0, forKey: "agent.panel.requestedWidth")
            let view = HStack(spacing: 0) {
                Spacer(minLength: 0)
                AgentSidebarView(model: model, isVisible: .constant(true),
                    credentialStateProvider: {
                        probeCount += 1
                        while !probeReleased && !Task.isCancelled { await settle(0.02) }
                        return (stored, probeError)
                    }, connectionController: controller)
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 30, width: 1600, height: 840),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.title = "ClipSlots · Agent 实际接入面板回归"
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            func webViews(_ view: NSView) -> [WKWebView] {
                (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
            }
            func editors(_ view: NSView) -> [AgentDraftEditor.Editor] {
                (view as? AgentDraftEditor.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
            }
            func element(_ id: String, in root: NSView? = nil) -> AnyObject? {
                NativeAccessibilityProbe.elements(root ?? host).first { ($0.accessibilityIdentifier?() ?? "") == id }
            }
            func press(_ id: String) -> Bool { element(id)?.accessibilityPerformPress?() == true }
            func js(_ script: String) async -> Any? {
                guard let web = webViews(host).first else { return nil }
                return try? await web.evaluateJavaScript(script)
            }
            func screenshot(_ name: String) {
                let nodes: [[String: String]] = NativeAccessibilityProbe.elements(host).map {
                    ["id": $0.accessibilityIdentifier?() ?? "", "label": $0.accessibilityLabel?() ?? "",
                     "value": (($0 as? NSAccessibilityProtocol)?.accessibilityValue() as? String) ?? ""]
                }
                try? JSONSerialization.data(withJSONObject: nodes, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent(name + ".ax.json"))
                guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                    CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { check(false, name + ": capture"); return }
                let width = UserDefaults.standard.double(forKey: "agent.panel.requestedWidth")
                let factor = Double(image.width) / window.frame.width
                let cropWidth = min(Double(image.width), width * factor)
                let cropped = image.cropping(to: CGRect(x: Double(image.width) - cropWidth, y: 0, width: cropWidth, height: Double(image.height))) ?? image
                let rep = NSBitmapImageRep(cgImage: cropped)
                try? rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(name + ".png"))
            }
            await wait { !webViews(host).isEmpty }
            await settle(1)
            check(!probeReleased && probeCount == 1 && webViews(host).count == 1 &&
                  editors(host).isEmpty && element("agent-welcome-greeting") == nil,
                  "pending credential lookup shows inline setup without welcome or composer")
            probeReleased = true
            await settle(0.2)
            check(webViews(host).count == 1 && editors(host).isEmpty, "missing credentials directly mount setup without settings click")
            for (label, appearance) in [("浅色", NSAppearance.Name.aqua), ("深色", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                await settle(0.3)
                let initialDOM = await js("({ready:document.readyState,cards:document.querySelectorAll('#picker .brand-heading').length})")
                    as? [String: Any] ?? [:]
                var documentReady = false
                for _ in 0..<200 {
                    if webViews(host).first?.isLoading == false,
                       await js("document.readyState === 'complete' && document.querySelectorAll('#picker .brand-heading').length === 6")
                            as? Bool == true {
                        documentReady = true
                        break
                    }
                    await settle(0.02)
                }
                check(documentReady, "\(label): provider document ready before palette assertions")
                let heading = await js("getComputedStyle(document.querySelector('.claude .brand-heading')).color") as? String
                let icon = await js("getComputedStyle(document.querySelector('.claude .brand-icon svg')).fill") as? String
                check(heading == "rgb(191, 104, 76)" && icon == heading, "\(label): Claude heading and icon match terracotta logo")
                let colors = await js("['gemini','gpt','deepseek','grok','kimi'].map(b=>getComputedStyle(document.querySelector('.'+b+' .brand-heading')).color).join('|')") as? String
                check(colors == "rgb(241, 246, 255)|rgb(21, 21, 21)|rgb(22, 51, 116)|rgb(244, 244, 242)|rgb(32, 37, 46)", "\(label): six approved brand heading colors")
                let backgrounds = await js("['gpt','grok','kimi'].map(b=>getComputedStyle(document.querySelector('.'+b)).backgroundColor).join('|')") as? String
                check(backgrounds == "rgb(255, 255, 255)|rgb(13, 14, 16)|rgb(237, 240, 244)", "\(label): GPT white and Grok deep black backgrounds")
                diagnostics.append(["paletteTheme": label, "initialDOM": initialDOM,
                    "documentReady": documentReady, "heading": heading ?? "unavailable",
                    "icon": icon ?? "unavailable", "colors": colors ?? "unavailable",
                    "backgrounds": backgrounds ?? "unavailable"])
                screenshot("实际侧栏-" + label + "-首次接入")
                for width in [360, 440, 600, 380, 600, 360, 440] {
                    UserDefaults.standard.set(Double(width), forKey: "agent.panel.requestedWidth")
                    await settle(0.13)
                    let diag = await js("window.lineDiagnostics()") as? [String: Any]
                    let visible = (diag?["fields"] as? [[String: Any]] ?? []).filter { $0["visible"] as? Bool == true }
                    check(visible.count == 6, "\(label)/\(width): all six logos visible")
                    // 48 pt native padding + 12 px grid gap + two 1 px
                    // card borders. Diagnostics measure the inner canvas.
                    check(abs(((visible.first?["viewportCSS"] as? [Double])?.first ?? 0) - (Double(width - 60) / 2 - 2)) < 1, "\(label)/\(width): actual card viewport follows requested sidebar width")
                    check(visible.allSatisfy { abs(($0["logoSizeCSS"] as? Double ?? 0) - 112.32) < 0.001 && ($0["frames"] as? Int ?? 0) > 0 }, "\(label)/\(width): fixed scale and painted backing")
                    if let diag { diagnostics.append(diag) }
                }
                screenshot("实际侧栏-" + label + "-窄侧栏")
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await wait { window.occlusionState.contains(.visible) }
            await settle(0.2)
            check(window.occlusionState.contains(.visible), "pointer fixture is visible before animation input")
            _ = await js("""
                (() => { const c=document.querySelector('#picker button'),r=c.getBoundingClientRect();
                c.dispatchEvent(new PointerEvent('pointermove',{clientX:r.left+r.width/2+12,clientY:r.top+r.height/2,pointerType:'mouse'})); })()
                """)
            await settle(0.2)
            let displaced = await js("window.lineDiagnostics().fields[0].displacementCSS") as? Double ?? 0
            if displaced <= 0.5, let diag = await js("window.lineDiagnostics()") {
                print("POINTER \(diag)")
            }
            check(displaced > 0.5, "native pointer displaces logo lines")
            screenshot("实际侧栏-鼠标拨动")
            _ = await js("document.querySelector('#picker button').dispatchEvent(new PointerEvent('pointerleave'))")
            await settle(1.2)
            let released = await js("window.lineDiagnostics().fields[0].displacementCSS") as? Double ?? 100
            check(released < displaced * 0.15, "native logo springs back after pointer leaves")
            for error in [AgentKeychainError.readCancelled, .authorizationTimedOut] {
                let theme = error == .readCancelled ? "浅色" : "深色"
                window.appearance = NSAppearance(named: error == .readCancelled ? .aqua : .darkAqua)
                probeError = error
                AgentBackendCoordinator.broadcastChange(for: .sidebar)
                await wait { element("agent-sidebar-reauthorize") != nil }
                check(webViews(host).count == 1 && editors(host).isEmpty &&
                      element("agent-welcome-greeting") == nil && element("agent-sidebar-reauthorize") != nil,
                      "\(error): unknown credentials keep inline setup and recovery")
                await settle(0.3)
                screenshot("实际侧栏-授权恢复")
                screenshot("实际侧栏-授权提示-" + theme)
                let previousCount = probeCount
                probeError = nil
                check(press("agent-sidebar-reauthorize"), "native credential recovery action responds")
                await wait { probeCount > previousCount && element("agent-sidebar-reauthorize") == nil }
                check(probeCount == previousCount + 1 && webViews(host).count == 1 && editors(host).isEmpty,
                      "reauthorization retries once and confirmed missing key keeps setup")
            }
            for provider in [AgentAPIProvider.claude, .grok, .kimi] {
                if stored {
                    stored = false
                    controller.back()
                    AgentBackendCoordinator.broadcastChange(for: .sidebar)
                    await wait { !webViews(host).isEmpty && editors(host).isEmpty }
                    await settle(0.4)
                }
                let previousProfile = prefs.data(forKey: AgentConnectionPreferences.key(scope: "sidebar"))
                _ = await js("document.querySelector('#picker [data-brand=\"\(provider.rawValue)\"]').click()")
                await wait { controller.provider == provider }
                check(controller.provider == provider, "\(provider.name): native selection bridge opens form")
                check(controller.baseURL == provider.baseURL && controller.modelID == provider.defaultModel,
                      "\(provider.name): correct endpoint and default model without inheritance")
                await settle(0.4)
                screenshot("实际侧栏-深色-\(provider.name)接入")
                controller.modelID = provider.defaultModel.isEmpty ? "fixture" : provider.defaultModel
                controller.keyDraft = "fixture-secret"
                verificationFails = true
                check(press("agent-api-connect"), "\(provider.name): native connect starts verification")
                await wait { !controller.busy }
                await settle(0.4)
                check(controller.error != nil && !stored && !webViews(host).isEmpty && editors(host).isEmpty &&
                      previousProfile == prefs.data(forKey: AgentConnectionPreferences.key(scope: "sidebar")),
                      "\(provider.name): rejected credentials preserve profile and stay in form")
                verificationFails = false
                check(press("agent-api-connect"), "\(provider.name): retry uses native sidebar callback")
                await wait { !controller.busy }
                await wait { element("agent-welcome-greeting") != nil && editors(host).count == 1 }
                await settle(0.5)
                check(stored && controller.error == nil && controller.keyDraft.isEmpty, "\(provider.name): verified save clears key input")
                check(AgentConnectionPreferences.provider(AgentConnectionPreferences.profile(scope: "sidebar", defaults: prefs)) == provider,
                      "\(provider.name): profile persists only after success")
                check(webViews(host).isEmpty && editors(host).count == 1 &&
                      element("agent-welcome-greeting") != nil, "\(provider.name): success restores welcome and composer")
                screenshot("实际侧栏-\(provider.name)接入后正常界面")
            }
            let rawPrefs = prefs.dictionaryRepresentation()
            check(!String(describing: rawPrefs).contains("fixture-secret"), "API key never persisted in UserDefaults")
            check(webViews(host).isEmpty && editors(host).count == 1 &&
                  element("agent-welcome-greeting") != nil,
                  "successful connection restores Hi welcome and one normal composer")
            screenshot("实际侧栏-接入后正常界面")
            let oldSaved = prefs.data(forKey: AgentConnectionPreferences.key(scope: "sidebar"))
            let failure = AgentConnectionController(scope: .sidebar, defaults: prefs,
                verify: { _, _ in throw AgentError.http(status: 401, message: nil, code: nil) },
                saveKey: { _, _ in check(false, "failed verification must not save key") })
            failure.select(.gpt); failure.modelID = "fixture"; failure.keyDraft = "bad-fixture"
            failure.connect {}
            await wait { !failure.busy }
            check(failure.error != nil && failure.keyDraft == "bad-fixture", "failed connection stays editable with error")
            check(oldSaved == prefs.data(forKey: AgentConnectionPreferences.key(scope: "sidebar")), "failed connection preserves previous profile")
            window.close()
            let reopen = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 440, height: 800),
                styleMask: [.titled], backing: .buffered, defer: false)
            reopen.isReleasedWhenClosed = false
            let reopenedHost = NSHostingView(rootView: AgentSidebarView(model: model, isVisible: .constant(true),
                credentialStateProvider: { (true, nil) }))
            reopen.contentView = reopenedHost; reopen.makeKeyAndOrderFront(nil); await settle(0.5)
            check(webViews(reopenedHost).isEmpty && editors(reopenedHost).count == 1, "configured reopen skips onboarding")
            reopen.close()
            for (name, readonly, noKey) in [("未配置再次打开", false, false), ("只读历史", true, false), ("无需密钥后端", false, true)] {
                if noKey { model.setBackend(OnboardingNoKeyBackend()) }
                let fixture = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 440, height: 800),
                    styleMask: [.titled], backing: .buffered, defer: false)
                fixture.isReleasedWhenClosed = false
                let fixtureHost = NSHostingView(rootView: AgentSidebarView(model: model, isVisible: .constant(true),
                    isReadOnly: readonly, credentialStateProvider: { (false, nil) }))
                fixture.contentView = fixtureHost; fixture.makeKeyAndOrderFront(nil); await settle(0.5)
                check((!webViews(fixtureHost).isEmpty) == (!readonly && !noKey) &&
                      editors(fixtureHost).count == (readonly || noKey ? 1 : 0),
                      name + ": correct onboarding admission")
                fixture.close()
            }
            let settingsWindow = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 460, height: 640),
                styleMask: [.titled], backing: .buffered, defer: false)
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.level = .floating
            let settingsHost = NSHostingView(rootView: AgentConfigView())
            settingsWindow.contentView = settingsHost; settingsWindow.makeKeyAndOrderFront(nil); await settle(0.5)
            check(!webViews(settingsHost).isEmpty && element("agent-backend-selector", in: settingsHost) == nil,
                  "API settings initially show brands with backend selector collapsed in advanced")
            check(element("agent-settings-done", in: settingsHost) != nil, "settings use shared neutral Done control")
            if let web = webViews(settingsHost).first as? AgentLineHostWebView {
                await settle(0.5)
                await AgentFollowupRegression.settings(window: settingsWindow, web: web, root: root, check: check)
            } else { check(false, "settings artwork available for scroll verification") }
            settingsWindow.close()
            let advancedWindow = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 460, height: 640),
                styleMask: [.titled], backing: .buffered, defer: false)
            advancedWindow.isReleasedWhenClosed = false
            let advancedHost = NSHostingView(rootView: AgentConfigView(openAdvanced: true))
            advancedWindow.contentView = advancedHost; advancedWindow.makeKeyAndOrderFront(nil); await settle(0.5)
            check(element("agent-backend-selector", in: advancedHost) != nil,
                  "other connection methods remain available in explicitly opened advanced settings")
            advancedWindow.close()
        } catch { failures.append(error.localizedDescription) }
        let result: [String: Any] = ["passed": failures.isEmpty, "passes": passes, "failures": failures,
            "fixtureOnly": true, "liveProviderCredentialsUsed": false, "diagnostics": diagnostics]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("app-regression.json"))
        print("Agent onboarding: \(passes) passed; \(failures.count) failed")
        failures.forEach { print("FAIL: " + $0) }
        exit(failures.isEmpty ? 0 : 1)
    }
}

private final class OnboardingNoKeyBackend: AgentBackend, @unchecked Sendable {
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] { [] }
}

actor OnboardingWireFixture: ModelHTTPTransport, AgentTransport {
    let contract: ModelAPIContract
    let toolRound: Bool
    let status: Int
    let malformed: Bool
    let errorBody: JSONValue?
    var requests: [URLRequest] = []
    init(contract: ModelAPIContract, toolRound: Bool = false, status: Int = 200, malformed: Bool = false,
         errorBody: JSONValue? = nil) {
        self.contract = contract; self.toolRound = toolRound; self.status = status; self.malformed = malformed
        self.errorBody = errorBody
    }
    func response() -> JSONValue {
        let tool = toolRound && requests.count == 1
        switch contract {
        case .anthropicMessages:
            return ["content": tool ? [["type": "tool_use", "id": "call1", "name": "fixture_read", "input": .object([:])]] : [["type": "text", "text": "完成🙂"]]]
        case .geminiContent:
            return ["candidates": [["content": ["parts": tool ? [["functionCall": ["name": "fixture_read", "args": .object([:])]]] : [["text": "完成🙂"]]]]]]
        default:
            let message: JSONValue = tool
                ? ["role": "assistant", "content": "", "tool_calls": [["id": "call1", "type": "function", "function": ["name": "fixture_read", "arguments": "{}"]]]]
                : ["role": "assistant", "content": "完成🙂"]
            return ["choices": [["message": message]]]
        }
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        return (malformed ? Data("{}".utf8) : try JSONEncoder().encode(errorBody ?? response()), status)
    }
    func stream(request: URLRequest) async throws -> AgentHTTPStream {
        requests.append(request)
        if !(200...299).contains(status) {
            let bytes = try JSONEncoder().encode(errorBody ?? response())
            return .init(statusCode: status, chunks: .init { $0.yield(bytes); $0.finish() })
        }
        var fields = response()["choices"]?.arrayValue?.first?["message"]?.objectValue ?? [:]
        if let calls = fields["tool_calls"]?.arrayValue {
            fields["tool_calls"] = .array(calls.map { call in var c = call.objectValue!; c["index"] = 0; return .object(c) })
        }
        let chunk: JSONValue = ["choices": [["delta": .object(fields), "finish_reason": fields["tool_calls"] == nil ? "stop" : "tool_calls"]]]
        let text = "data: \(try chunk.encodedText())\n\ndata: [DONE]\n\n"
        return .init(statusCode: status, chunks: .init { $0.yield(Data(text.utf8)); $0.finish() })
    }
}
private final class OnboardingTools: AgentToolExecuting {
    var executions = 0
    func specs() -> [AgentToolSpec] { [.init(name: "fixture_read", description: "fixture", parameters: ["type": "object", "properties": .object([:])], originLabel: "fixture")] }
    func execute(call: AgentToolCall) async -> AgentToolResult {
        executions += 1
        return .init(content: "fixture-read", summary: "fixture")
    }
}
#endif
