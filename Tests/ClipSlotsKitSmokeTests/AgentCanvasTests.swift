import Foundation
import ClipSlotsKit

func runAgentCanvasTests(_ t: TestRunner) {
    let configPath = FileManager.default.temporaryDirectory.appendingPathComponent("agent-config-\(UUID()).toml")
    let previousConfig = ProcessInfo.processInfo.environment["CLIPSLOTS_CONFIG_PATH"]
    setenv("CLIPSLOTS_CONFIG_PATH", configPath.path, 1)
    var isolatedConfig = AppConfig()
    isolatedConfig.slots = 7
    isolatedConfig.save()
    t.check(AppConfig.load().slots == 7 && FileManager.default.fileExists(atPath: configPath.path),
            "candidate config override saves and loads independently")
    if let previousConfig { setenv("CLIPSLOTS_CONFIG_PATH", previousConfig, 1) }
    else { unsetenv("CLIPSLOTS_CONFIG_PATH") }
    try? FileManager.default.removeItem(at: configPath)
    t.withFreshStore("Agent body CAS") { storage in
        let group = try storage.createSpecialSlot(name: "Agent CAS").id
        let bytes = Data([1, 2, 3, 4, 5])
        var original = SlotContent(items: [[
            PasteboardItem(type: "public.utf8-plain-text", data: Data("原文".utf8)),
            PasteboardItem(type: "public.rtf", data: Data("{\\rtf1 bold}".utf8))
        ]], htmlSource: "<b>原文</b>", attachments: [
            .init(name: "参考.bin", type: .file, data: bytes),
            .init(name: "第二个.bin", type: .file, data: Data([9, 8]))
        ])
        original.manualThumbnailId = UUID().uuidString
        original.pendingManualThumbnailData = bytes
        t.check(storage.set(1, content: original, in: group), "CAS fixture written")
        t.check(storage.setLabel(1, label: "素材标签", in: group), "CAS label written")
        let before = AgentSlotBody(storage.get(1, in: group)), after = AgentSlotBody(text: "Agent 新正文")
        t.equal(AgentSlotBody(SpecialSlotStorage().get(1, in: group)), before,
                "fresh storage restores HTML and pasteboard format order before CAS")
        let ids = storage.get(1, in: group).attachments.map(\.id)
        let applied = try storage.exchangeAgentBody(1, in: group, expected: before, replacement: after)
        t.equal(applied.plainText, "Agent 新正文", "CAS body applied")
        t.check(applied.htmlSource == nil, "CAS clears stale HTML")
        t.equal(applied.attachments.map(\.id), ids, "CAS preserves attachment identity and order")
        t.equal(storage.get(1, in: group).attachments.first?.resolveData(), bytes, "CAS preserves media bytes")
        t.equal(storage.getLabel(1, in: group), "素材标签", "CAS preserves label")
        t.equal(try Data(contentsOf: storage.manualThumbnailURL(1, in: group)!), bytes, "CAS preserves manual cover bytes")
        t.expectThrows("CAS duplicate apply rejected") {
            _ = try storage.exchangeAgentBody(1, in: group, expected: before, replacement: after)
        }
        let undone = try storage.exchangeAgentBody(1, in: group, expected: after, replacement: before)
        t.equal(AgentSlotBody(undone), before, "CAS undo restores every pasteboard format and HTML")
        t.equal(AgentSlotBody(SpecialSlotStorage().get(1, in: group)), before,
                "CAS undo restores rich body on disk after restart, not only cached return")
        _ = try storage.exchangeAgentBody(1, in: group, expected: before, replacement: after)

        // A second storage instance models a writer outside the UI cache.
        let external = SpecialSlotStorage()
        t.check(external.set(1, content: SlotContent(text: "之后的手动编辑"), in: group), "external body edit")
        t.expectThrows("CAS never undoes a later external edit") {
            _ = try storage.exchangeAgentBody(1, in: group, expected: after, replacement: before)
        }
        t.equal(storage.get(1, in: group).plainText, "之后的手动编辑", "conflict retains newer text")
        t.expectThrows("CAS rejects nonexistent group") {
            _ = try storage.exchangeAgentBody(1, in: "deleted-group", expected: before, replacement: after)
        }
        StorageLock.forceUnlocked = true
        t.expectThrows("CAS rejects degraded cross-process locking") {
            _ = try storage.exchangeAgentBody(1, in: group,
                expected: AgentSlotBody(storage.get(1, in: group)), replacement: after)
        }
        StorageLock.forceUnlocked = false
        let privateStore = SpecialSlotStorage(baseDirectory: ClipSlotsPaths.canvasPrivateSlots, role: .canvasPrivate)
        let privateID = SpecialSlotStorage.canvasGroupPrefix + "agent-fixture"
        try privateStore.ensureReservedGroup(id: privateID, name: "画布素材")
        t.check(privateStore.set(35, content: SlotContent(text: "私有原文"), in: privateID), "private canvas fixture written")
        let privateBody = try privateStore.exchangeAgentBody(35, in: privateID,
            expected: AgentSlotBody(text: "私有原文"), replacement: after)
        t.equal(privateBody.plainText, after.plainText, "CAS supports private canvas slots beyond main capacity")
        let current = AgentSlotBody(storage.get(1, in: group))
        let folder = ClipSlotsPaths.specialSlots.appendingPathComponent(group)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        t.expectThrows("CAS disk failure is not reported as applied") {
            _ = try storage.exchangeAgentBody(1, in: group, expected: current, replacement: after)
        }
        t.equal(AgentSlotBody(storage.get(1, in: group)), current, "failed CAS preserves prior body")
    }

    let reference = AgentCanvasReference(projectID: "project", nodeID: "node", nodeCreatedAt: Date(),
        groupID: "group", slot: 1, title: "海边镜头", text: "明确选择的正文", attachmentNames: ["仅名称.png"])
    let user = AgentMessage(role: .user, content: "改写", canvasReferences: [reference])
    do {
        let restored = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(user))
        t.equal(restored.canvasReferences, [reference], "reference snapshots survive session persistence")
        t.check(restored.wireContent.contains(reference.text) && restored.wireContent.contains("仅名称.png"),
                "reference text and attachment names reach request")
        let body = AgentService.requestBody(history: [restored], config: AgentConfig(systemPrompt: ""), tools: [])
        t.check(body["messages"]?.arrayValue?.first?["content"]?.stringValue?.contains(reference.text) == true,
                "DeepSeek receives explicit reference")
    } catch { t.check(false, "reference roundtrip \(error)") }
    let rejected = smokeAwait { await AgentPreviewTools().execute(call: .init(id: "write", name: "write_slot", argumentsJSON: "{}")) }
    t.check(rejected.isFailure && AgentPreviewTools().specs().isEmpty, "preview capabilities deny direct writes")
    let executor = SmokeToolExecutor()
    let service = AgentService(transport: AgentScriptedTransport(steps: [
        .sse(#"""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"write","type":"function","function":{"name":"write_slot","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """#),
        .sse("data: {\"choices\":[{\"delta\":{\"content\":\"待预览正文\"}}]}\n\ndata: [DONE]\n\n")
    ]), secretStore: AgentInMemorySecretStore(key: "fixture"))
    let result: [AgentMessage] = smokeAwait {
        var config = AgentConfig()
        config.canvasPreviewOnly = true
        return (try? await service.run(history: [user], config: config, tools: executor, onEvent: { _ in })) ?? []
    }
    t.check(executor.calls.isEmpty && result.contains { $0.role == .tool && $0.isFailure },
            "DeepSeek preview refuses upstream write requests even with a full executor")
}
