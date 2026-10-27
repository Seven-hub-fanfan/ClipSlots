#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit
import Vision

private actor ModelWorkspaceFixtureHTTP: ModelHTTPTransport {
    var count = 0
    var active = 0
    var peak = 0
    func resetPeak() { peak = 0 }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        count += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(30))
        return (Data(#"{"choices":[{"message":{"content":"本地 fixture 测评结果"}}]}"#.utf8), 200)
    }
}

@MainActor enum ModelWorkspaceRegression {
    private static var started = false
    static func schedule(store: SlotStoreObservable) {
        guard !started, let path = ProcessInfo.processInfo.environment["CLIPSLOTS_MODEL_REGRESSION"] else { return }
        started = true
        Task { await run(store: store, root: URL(fileURLWithPath: path)) }
    }
    private static func run(store: SlotStoreObservable, root: URL) async {
        var passed: [String] = [], failed: [String] = []
        func check(_ value: Bool, _ name: String) { if value { passed.append(name) } else { failed.append(name) } }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = ModelWorkspaceFixtureHTTP()
            let models = ModelWorkspaceStore(repository: .init(root: root.appendingPathComponent("repository")),
                service: .init(transport: fixture))
            await models.load()
            var question = ModelQuestion(); question.title = "遵循指令"; question.prompt = "只回答本地测试"
            var bank = ModelQuestionBank(); bank.name = "隔离测评题库"; bank.questions = [question]
            models.document.banks = [bank]
            let profiles = (0..<14).map { index -> ModelProfile in
                var p = ModelProfile(); p.id = "fixture-\(index)"; p.name = "测试模型 \(index + 1)"
                p.model = p.id; p.endpoint = "http://127.0.0.1:1/chat"; p.requiresKey = false; return p
            }
            models.document.profiles = profiles
            await models.persist()
            await models.start(bankID: bank.id, selectedIDs: Set(profiles.map(\.id)))
            for _ in 0..<100 {
                if models.document.runs.last?.cells.allSatisfy({ $0.state == .succeeded }) == true { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            check(models.document.runs.last?.cells.count == 14 && models.document.runs.last?.cells.allSatisfy({ $0.state == .succeeded }) == true,
                "14 models complete a real scheduled result matrix")
            check(models.catalog?.entries.count == 119, "full bundled catalog loaded into native workspace")
            // Put the sensitive catalog entry on screen in every theme and width.
            models.catalog?.entries.sort {
                let left = $0.displayName.localizedCaseInsensitiveContains("tapnow")
                let right = $1.displayName.localizedCaseInsensitiveContains("tapnow")
                return left && !right
            }
            let peak = await fixture.peak
            check(peak <= 4 && peak > 1, "global concurrency bounded at four with parallel dispatch")
            let requests = await fixture.count
            if let cell = models.document.runs.last?.cells.first {
                await models.retry(cell.id)
                check(await fixture.count == requests, "successful cell cannot resubmit")
                await models.score(cell.id, scores: ["response": 86])
            }
            check(models.document.runs.last.map { ModelRanking.entries(run: $0, kind: .llm).first?.total == 86 } == true,
                "manual scores produce actual ranking")
            await models.start(bankID: bank.id, selectedIDs: [profiles[0].id], questionIDs: [])
            check(models.document.runs.count == 1, "empty subset rejected without a request")
            let storedFile = root.appendingPathComponent("repository/workspace.json")
            let storedBytes = try Data(contentsOf: storedFile)
            let reloaded = ModelWorkspaceStore(repository: .init(root: root.appendingPathComponent("repository")))
            await reloaded.load()
            check(reloaded.document.runs == models.document.runs, "completed results restore byte-equivalent values")
            check(try Data(contentsOf: storedFile) == storedBytes, "unchanged launch preserves exact model workspace bytes")
            await models.setDefault(.agent, id: profiles[0].id)
            let preferences = UserDefaults(suiteName: "com.clipslots.model-fixture-\(UUID().uuidString)")!
            for scope in [AgentBackendScope.sidebar, .workspace] {
                preferences.set(AgentBackendKind.deepseek.rawValue, forKey: scope.preferenceKey)
                let selection = AgentBackendCoordinator.selection(for: scope, defaults: preferences)
                check(!selection.requiresAPIKey && selection.normalized(AgentConfig()).model == profiles[0].model,
                    "\(scope.rawValue) uses the selected unauthenticated LLM without legacy key requirements")
            }
            var disabled = profiles[0]; disabled.enabled = false
            let disabledSaved = await models.saveProfile(disabled, key: "")
            check(!disabledSaved && models.document.profiles[0].enabled, "a default model cannot be disabled silently")
            models.document.defaults[ModelPurpose.agent.rawValue] = "missing-profile"
            ModelConfigurationBridge.update(models.document)
            let missing = AgentBackendCoordinator.selection(for: .sidebar, defaults: preferences)
            check(!(missing.backend is AgentService) && !missing.requiresAPIKey,
                "missing configured LLM never falls back to legacy provider or credentials")
            await models.setDefault(.agent, id: "")
            var shared = ModelServiceConnection(); shared.name = "本地共享服务"; shared.baseURL = "http://127.0.0.1:1/v1"
            shared.requiresKey = false; shared.concurrency = 1; shared.discoveryURL = "models"
            _ = await models.saveService(shared, key: "")
            for index in 0..<3 {
                var profile = profiles[index]; profile.serviceID = shared.id; profile.endpoint = "chat/completions"
                _ = await models.saveProfile(profile, key: "")
            }
            let beforeShared = await fixture.count
            await fixture.resetPeak()
            await models.start(bankID: bank.id, selectedIDs: Set(profiles.prefix(3).map(\.id)))
            for _ in 0..<100 {
                if models.document.runs.last?.cells.allSatisfy({ $0.state == .succeeded }) == true { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            check(await fixture.count == beforeShared + 3 && models.document.runs.last?.cells.allSatisfy({ $0.state == .succeeded }) == true,
                "three bound models dispatch via shared connection")
            check(await fixture.peak == 1, "shared service concurrency accumulates across three different models")
            if let snapshot = models.document.runs.last?.models.first {
                shared.baseURL = "http://127.0.0.1:2/v1"
                _ = await models.saveService(shared, key: "")
                check(snapshot.endpoint.hasPrefix("http://127.0.0.1:1/") && models.profiles.first?.endpoint.hasPrefix("http://127.0.0.1:2/") == true,
                    "native service switch preserves previous run and updates next request")
            }
            if let group = SpecialSlotStorage.shared.loadIndex().specialSlots.first,
               let content = SpecialSlotStorage.shared.getOrUnknown(1, in: group.id) {
                let revision = BatchGenerationSource.revision(of: content)
                let saved = try store.writeModelQuestion(groupID: group.id, slot: 1, expectedRevision: revision, text: "同步正文")
                check(saved.plainText == "同步正文", "question write reaches authoritative slot")
                do {
                    _ = try store.writeModelQuestion(groupID: group.id, slot: 1, expectedRevision: revision, text: "过期正文")
                    check(false, "stale slot edit is rejected")
                } catch { check(SpecialSlotStorage.shared.getOrUnknown(1, in: group.id)?.plainText == "同步正文", "stale slot edit is rejected") }
            } else { check(false, "isolated fixture slot is available") }
            NativeAccessibilityProbe.enable()
            models.message = nil
            await runWorkspaceBeatProbe(directory: root, check: check)
            let original = AppSkinCenter.current
            defer { AppSkinCenter.apply(original) }
            for colorful in [false, true] {
                AppSkinCenter.apply(colorful ? .colorful : .minimal)
                for dark in [false, true] {
                    for width in [920, 1280] {
                        let host = NSHostingView(rootView: ModelWorkspaceView(store: store, models: models).id("initial"))
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false; window.contentView = host
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        window.makeKeyAndOrderFront(nil)
                        for tab in ["测评", "排行榜", "配置中心", "AI 日报"] {
                            models.document.newsRefreshedAt = Date()
                            host.rootView = ModelWorkspaceView(store: store, models: models, initialTab: tab).id(tab)
                            try await Task.sleep(for: .milliseconds(120))
                            // Remount the host to exercise each tab's actual state, since
                            // in-process SwiftUI AX press does not dispatch an external click.
                            try await Task.sleep(for: .milliseconds(120))
                            host.layoutSubtreeIfNeeded()
                            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                                host.cacheDisplay(in: host.bounds, to: bitmap)
                                guard let cg = bitmap.cgImage else { throw ModelWorkspaceError.response }
                                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                                request.recognitionLanguages = ["zh-Hans", "en-US"]
                                try VNImageRequestHandler(cgImage: cg).perform([request])
                                let text = (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? [])
                                    .joined().filter { !$0.isWhitespace }
                                check(["测评", "排行榜", "配置中心", "AI日报"].allSatisfy { text.contains($0) },
                                    "\(width)/\(colorful)/\(dark) all native tabs visibly rendered")
                                let expected = ["测评": "配置模型", "排行榜": "本地测评能力榜", "配置中心": "API模型", "AI 日报": "暂无新闻"][tab] ?? ""
                                check(!expected.isEmpty && text.contains(expected), "\(width)/\(colorful)/\(dark) actual section \(tab) rendered")
                                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(
                                    "\(width)-\(colorful ? "colorful" : "minimal")-\(dark ? "dark" : "light")-\(tab).png"))
                            } else { check(false, "native bitmap unavailable") }
                        }
                        for section in ["模型目录", "已接入", "服务连接", "用途路由"] {
                            host.rootView = ModelWorkspaceView(store: store, models: models, initialTab: "配置中心", initialConfigurationSection: section).id(section)
                            try await Task.sleep(for: .milliseconds(240))
                            host.layoutSubtreeIfNeeded()
                            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                                host.cacheDisplay(in: host.bounds, to: bitmap)
                                guard let cg = bitmap.cgImage else { throw ModelWorkspaceError.response }
                                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans","en-US"]
                                try VNImageRequestHandler(cgImage: cg).perform([request])
                                let text = (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined().filter { !$0.isWhitespace }
                                let expected = ["模型目录": "内置模型目录", "已接入": "测试模型", "服务连接": "本地共享服务", "用途路由": "画布文本润色"][section] ?? ""
                                check(text.contains(expected), "\(width)/\(colorful)/\(dark) hub section \(section) native content rendered")
                                check(!text.localizedCaseInsensitiveContains("tapnow"),
                                    "\(width)/\(colorful)/\(dark) hub section \(section) has no source brand in visible text")
                                if section == "模型目录" {
                                    check(text.contains("图像极速模型") && (width < 1280 || text.contains("内置服务")),
                                        "\(width)/\(colorful)/\(dark) branded catalog row uses neutral display aliases")
                                }
                                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(
                                    "\(width)-\(colorful ? "colorful" : "minimal")-\(dark ? "dark" : "light")-hub-\(section).png"))
                            } else { check(false, "hub bitmap unavailable") }
                        }
                        window.close()
                    }
                }
            }
        } catch { failed.append(error.localizedDescription) }
        let report: [String: Any] = ["ok": failed.isEmpty, "passed": passed, "failed": failed, "realPaidRequests": 0]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}
#endif
