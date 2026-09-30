import Foundation
import SwiftUI
import ClipSlotsKit

// MARK: - Agent 会话（App 层状态）
//
// 这个文件是 Kit 层 AgentService 与 SwiftUI 之间的唯一桥。三个类型：
//   - `AgentPreferences`：@AppStorage 键与配置组装（API Key **不在此列**，只在 Keychain）。
//   - `AgentSkillLibrary`：Skill 目录扫描结果的共享缓存（两个页面共用一份）。
//   - `AgentChatModel`：一条会话的全部可观察状态；编辑页与画布页各持一个。
//
// ## 为什么会话对象不挂在 ContentView 的 @StateObject 上
// 本项目有个已知性能债：ContentView 的任一 @Published 变化都会重算整棵 body
// （10 张卡片的 LazyVGrid 一起重算）。流式回答每秒能推几十个 token，如果 ContentView
// 观察了会话对象，就等于每个 token 重绘一次主界面——这不是"稍微卡"，是直接不可用。
// 所以 ContentView 只用一个**不发布任何变化**的 `AgentSessionStore` 持有两个会话，
// 由 `AgentSidebarView` 自己 `@ObservedObject` 订阅。这样 token 级刷新被关在侧栏里。

// MARK: - 偏好

enum AgentPreferences {
    // @AppStorage 键。命名带 agent. 前缀，避免和历史键撞车。
    static let modelKey = "agent.model"
    static let systemPromptKey = "agent.systemPrompt"
    static let thinkingModeKey = "agent.thinkingMode"
    static let reasoningEffortKey = "agent.reasoningEffort"
    static let endpointKey = "agent.endpoint"
    static let enabledSkillsKey = "agent.enabledSkillSlugs"
    /// 侧栏是否默认展开（分别记编辑页/画布页，符合"两个页面各自独立"的预期）。
    static let editSidebarVisibleKey = "agent.sidebarVisible.edit"
    static let canvasSidebarVisibleKey = "agent.sidebarVisible.canvas"

    /// 启用的 Skill slug 用换行分隔存一个字符串。
    /// 用字符串而不是 Data/JSON：@AppStorage 只支持有限类型，字符串最省事，
    /// 而且用户在 defaults 里肉眼可读（排查"为什么这个 Skill 没上"时很有用）。
    static func decodeEnabledSlugs(_ raw: String) -> Set<String> {
        Set(raw.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    static func encodeEnabledSlugs(_ slugs: Set<String>) -> String {
        slugs.sorted().joined(separator: "\n")
    }

    static func config(model: String,
                       systemPrompt: String,
                       thinkingRaw: String,
                       reasoningEffort: String,
                       endpoint: String) -> AgentConfig {
        let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? AgentConfig.defaultEndpoint
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentConfig(
            endpoint: url,
            model: trimmedModel.isEmpty ? AgentConfig.defaultModel : trimmedModel,
            systemPrompt: systemPrompt.replacingOccurrences(of: "当前应用版本：v2.11.8。", with: "")
                + "\n当前应用版本：v\(AppVersion.current)。",
            thinkingMode: AgentThinkingMode(rawValue: thinkingRaw) ?? .serverDefault,
            // 空串表示"不发 reasoning_effort"，见 AgentService 文件头约定 2。
            reasoningEffort: reasoningEffort.isEmpty ? nil : reasoningEffort)
    }
}

// MARK: - Skill 库

@MainActor
final class AgentSkillLibrary: ObservableObject {
    static let shared = AgentSkillLibrary()

    @Published private(set) var skills: [AgentSkill] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScanAt: Date?

    private init() {}

    /// 扫盘放到后台：Agent 目录里可能有几十个 Skill，加上要读每个 SKILL.md，
    /// 在主线程做会让侧栏打开的那一帧掉帧。
    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let bundlePath = Bundle.main.bundlePath
        Task.detached(priority: .userInitiated) {
            let found = AgentSkillCatalog.discover(bundlePath: bundlePath)
            await MainActor.run {
                self.skills = found
                self.isScanning = false
                self.lastScanAt = Date()
            }
        }
    }

    func skills(withSlugs slugs: Set<String>) -> [AgentSkill] {
        skills.filter { slugs.contains($0.slug) }
    }
}

// MARK: - 工具执行状态（UI 用）

struct AgentToolActivity: Identifiable, Equatable {
    enum State: Equatable { case running, success, failure, stopped }
    let id: String          // tool_call id
    let name: String
    let argumentsPreview: String
    var state: State
    var summary: String?
}

// MARK: - 一条会话

@MainActor
final class AgentChatModel: ObservableObject {
    struct SavedConversation: Codable, Identifiable {
        var id: UUID
        var messages: [AgentMessage]
        var draft: String
        var updatedAt: Date
        var title: String { String((messages.first { $0.role == .user }?.content ?? draft).prefix(30)) }
    }
    private struct SavedSessions: Codable {
        var current: SavedConversation
        var recent: [SavedConversation]
    }
    private static let instances = NSHashTable<AgentChatModel>.weakObjects()
    static func flushAll() -> Bool { instances.allObjects.map { $0.flushSession() }.allSatisfy { $0 } }
    @Published private(set) var recentConversations: [SavedConversation] = []
    @Published private(set) var persistenceError: String?
    private var conversationId = UUID()
    private let persistenceURL: URL?
    private let persistenceQueue = DispatchQueue(label: "com.clipslots.agent.sessions", qos: .utility)
    private var persistenceTask: Task<Void, Never>?
    private var restoring = false
    private var unreadableHistory = false
    /// 完整线上下文（含 role=tool 的消息）。UI 渲染时再折叠成气泡 + 工具行。
    /// 刻意保存完整历史而不是"只留展示用的部分"：工具结果是模型下一轮的依据，
    /// 丢了它模型就会重复调用同一个工具。
    @Published private(set) var messages: [AgentMessage] = [] { didSet { schedulePersistence() } }
    @Published private(set) var streamingContent = ""
    @Published private(set) var streamingReasoning = ""
    @Published private(set) var liveActivities: [AgentToolActivity] = []
    @Published private(set) var isRunning = false
    /// 草稿跟随会话存活；收起侧栏、切换皮肤重建视图时保留。
    @Published var draft = "" { didSet { schedulePersistence() } }
    @Published var errorText: String?
    /// 上一轮 token 用量，显示在输入区上方（让用户对成本有感知）。
    @Published private(set) var usageLine: String?
    /// 触发配置页：没有 API Key 时第一次发送会把它置 true。
    @Published var needsConfiguration = false

    let displayName: String
    /// v2.17.7 起：具体后端由 `AgentBackendCoordinator` 决定，可运行时切换（DeepSeek / Tika）。
    /// UI 里选完保存会调 `setBackend(_:)`；测试 / smoke 直接从 init 注入。
    private var backend: any AgentBackend
    private let registry: AgentToolRegistry
    private var runTask: Task<Void, Never>?
    private var currentRunID: UUID?

    init(displayName: String,
         service: AgentService? = nil,
         backend: (any AgentBackend)? = nil,
         registry: AgentToolRegistry = AgentToolRegistry(),
         persistenceURL: URL? = nil) {
        self.displayName = displayName
        // 优先 backend；没给 backend 但给了 service 就用 service；都没给就走 Coordinator 读偏好。
        if let backend {
            self.backend = backend
        } else if let service {
            self.backend = service
        } else {
            self.backend = AgentBackendCoordinator.currentBackend()
        }
        self.registry = registry
        self.persistenceURL = persistenceURL
        restoring = true
        if let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) {
            do {
                let saved = try JSONDecoder().decode(SavedSessions.self, from: Data(contentsOf: persistenceURL))
                conversationId = saved.current.id
                messages = saved.current.messages
                draft = saved.current.draft
                recentConversations = saved.recent
                settleUnfinishedTools()
            } catch {
                unreadableHistory = true
                persistenceError = "会话历史读取失败，原文件已保留：\(error.localizedDescription)"
            }
        }
        restoring = false
        Self.instances.add(self)
    }

    private var snapshot: SavedConversation {
        .init(id: conversationId, messages: messages, draft: draft, updatedAt: Date())
    }

    private func schedulePersistence() {
        guard persistenceURL != nil, !restoring else { return }
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.flushSession()
        }
    }

    @discardableResult
    func flushSession() -> Bool {
        persistenceTask?.cancel()
        persistenceTask = nil
        guard let persistenceURL else { return true }
        do {
            let data = try JSONEncoder().encode(SavedSessions(current: snapshot, recent: recentConversations))
            let preserveUnreadable = unreadableHistory
            try persistenceQueue.sync {
                let fm = FileManager.default
                try fm.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if preserveUnreadable {
                    try fm.copyItem(at: persistenceURL, to: persistenceURL.appendingPathExtension("unreadable-\(UUID().uuidString)"))
                }
                try data.write(to: persistenceURL, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: persistenceURL.path)
            }
            unreadableHistory = false
            persistenceError = nil
            return true
        } catch {
            persistenceError = "会话尚未保存：\(error.localizedDescription)"
            return false
        }
    }

    private func archiveCurrent() {
        guard !messages.isEmpty || !draft.isEmpty else { return }
        recentConversations.removeAll { $0.id == conversationId }
        recentConversations.insert(snapshot, at: 0)
        recentConversations = Array(recentConversations.prefix(30))
    }

    func openConversation(id: UUID) {
        guard let saved = recentConversations.first(where: { $0.id == id }) else { return }
        stop()
        archiveCurrent()
        restoring = true
        recentConversations.removeAll { $0.id == id }
        conversationId = saved.id
        messages = saved.messages
        draft = saved.draft
        settleUnfinishedTools()
        liveActivities = []
        errorText = nil
        usageLine = nil
        restoring = false
        flushSession()
    }

    /// v2.17.7 起：只有 DeepSeek 后端需要 API Key；Tika 后端由 tikacli 自己管认证。
    var hasAPIKey: Bool {
        if let ds = backend as? AgentService { return ds.hasAPIKey }
        return true
    }

    var isEmpty: Bool { messages.isEmpty }

    // MARK: 发送

    func send(text: String, config: AgentConfig, enabledSkills: [AgentSkill]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        // DeepSeek 后端需要 API Key；Tika 后端 tikacli 自己管认证，先跳过这道检查
        // （若 tikacli 未登录，run() 内部会抛 notAuthenticated，走 failRun 显示提示）。
        if let ds = backend as? AgentService, !ds.hasAPIKey {
            needsConfiguration = true
            errorText = AgentError.missingAPIKey.errorDescription
            return
        }

        errorText = nil
        usageLine = nil
        messages.append(AgentMessage(role: .user, content: trimmed))
        registry.update(enabledSkills: enabledSkills)
        beginRun(config: config)
    }

    /// 重试：把最后一次失败之后的状态清掉，用同样的历史再跑一遍。
    func retryLast(config: AgentConfig, enabledSkills: [AgentSkill]) {
        guard !isRunning, messages.contains(where: { $0.role == .user }) else { return }
        // 去掉尾部的本地失败提示，避免它们一直堆在界面上。
        while let last = messages.last, last.role == .assistant, last.isFailure, last.toolCalls.isEmpty {
            messages.removeLast()
        }
        errorText = nil
        registry.update(enabledSkills: enabledSkills)
        beginRun(config: config)
    }

    private func beginRun(config: AgentConfig) {
        isRunning = true
        streamingContent = ""
        streamingReasoning = ""
        liveActivities = []

        let history = messages
        let runID = UUID()
        currentRunID = runID
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 事件回调是 @Sendable，且会在任意线程被调用，所以统一 hop 回主线程。
                try await self.backend.run(history: history,
                                           config: config,
                                           tools: self.registry) { event in
                    await self.apply(event, runID: runID)
                }
                await MainActor.run {
                    guard self.currentRunID == runID else { return }
                    self.completeRun()
                }
            } catch let error as AgentError {
                await MainActor.run {
                    guard self.currentRunID == runID else { return }
                    self.failRun(error)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.currentRunID == runID else { return }
                    self.failRun(AgentError.cancelled)
                }
            } catch {
                await MainActor.run {
                    guard self.currentRunID == runID else { return }
                    self.failRun(AgentError.network(error.localizedDescription))
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        // Some transports finish their stream normally on cancellation. Settle here
        // and invalidate queued callbacks so a stopped answer cannot resume.
        currentRunID = nil
        runTask?.cancel()
        failRun(.cancelled)
    }

    func clearHistory() {
        currentRunID = nil
        stop()
        archiveCurrent()
        restoring = true
        conversationId = UUID()
        messages = []
        streamingContent = ""
        streamingReasoning = ""
        liveActivities = []
        errorText = nil
        usageLine = nil
        draft = ""
        isRunning = false
        restoring = false
        flushSession()
    }

    // MARK: 事件

    private func apply(_ event: AgentRunEvent, runID: UUID) async {
        await MainActor.run {
            guard self.currentRunID == runID else { return }
            switch event {
            case .reasoningDelta(let text):
                streamingReasoning += text
            case .contentDelta(let text):
                streamingContent += text
            case .assistantCompleted(let message):
                // 历史完全由事件构建（service 的返回值被丢弃），保证只有一个真相来源。
                messages.append(message)
                streamingContent = ""
                streamingReasoning = ""
            case .toolStarted(let call):
                liveActivities.append(AgentToolActivity(id: call.id,
                                                        name: call.name,
                                                        argumentsPreview: Self.preview(call.argumentsJSON),
                                                        state: .running,
                                                        summary: nil))
            case .toolCompleted(let callId, let name, let result):
                if let index = liveActivities.firstIndex(where: { $0.id == callId }) {
                    liveActivities[index].state = result.isFailure ? .failure : .success
                    liveActivities[index].summary = result.summary
                }
                messages.append(AgentMessage(role: .tool,
                                             content: result.content,
                                             toolCallId: callId,
                                             toolName: name,
                                             isFailure: result.isFailure))
            case .usage(let usage):
                usageLine = "输入 \(usage.promptTokens) · 输出 \(usage.completionTokens) tokens"
                    + (usage.cachedTokens.map { " · 命中缓存 \($0)" } ?? "")
            case .note(let text):
                messages.append(AgentMessage(role: .assistant, content: text, isFailure: true))
            }
        }
    }

    private func completeRun() {
        settleUnfinishedTools()
        isRunning = false
        runTask = nil
        streamingContent = ""
        streamingReasoning = ""
        flushSession()
    }

    private func failRun(_ error: AgentError) {
        settleUnfinishedTools()
        isRunning = false
        runTask = nil
        // 已经流出来的半截回答保留成一条消息，不要连同错误一起丢——
        // 用户等了半天的内容不能因为收尾失败就人间蒸发。
        if !streamingContent.isEmpty || !streamingReasoning.isEmpty {
            messages.append(AgentMessage(role: .assistant,
                                         content: streamingContent,
                                         reasoning: streamingReasoning.isEmpty ? nil : streamingReasoning))
        }
        streamingContent = ""
        streamingReasoning = ""
        if error == .cancelled {
            messages.append(AgentMessage(role: .assistant, content: "已停止本次回答。", isFailure: true))
        } else {
            errorText = error.errorDescription
            if error == .missingAPIKey { needsConfiguration = true }
        }
        flushSession()
    }

    /// 中断只说明没有收到结果，不能声称有副作用的工具已撤销或未执行。
    private func settleUnfinishedTools() {
        let completed = Set(messages.filter { $0.role == .tool }.compactMap(\.toolCallId))
        let missing = messages.flatMap(\.toolCalls).filter { !completed.contains($0.id) }
        for call in missing {
            messages.append(AgentMessage(role: .tool,
                content: #"{"error_code":"interrupted","message":"本地跟踪已停止，执行结果未知；继续操作前请检查槽位实际内容，勿直接重复修改。"}"#,
                toolCallId: call.id, toolName: call.name, isFailure: true))
        }
        for index in liveActivities.indices where liveActivities[index].state == .running {
            liveActivities[index].state = .stopped
            liveActivities[index].summary = "已停止 · 结果未知"
        }
    }

    static func preview(_ json: String) -> String {
        let compact = json.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return compact.count > 80 ? String(compact.prefix(80)) + "…" : compact
    }

    // MARK: 供 UI 的转写视图
    //
    // 把线上下文折叠成可渲染条目：user 气泡 / assistant 气泡 / 工具行组。
    // role=tool 的消息不单独成气泡，而是和触发它的 assistant 消息配对显示。

    struct TranscriptItem: Identifiable {
        enum Kind {
            case user(String)
            case assistant(text: String, reasoning: String?, isFailure: Bool)
            case tools([AgentToolActivity])
        }
        let id: String
        let kind: Kind
    }

    var transcript: [TranscriptItem] {
        var items: [TranscriptItem] = []
        // 先把 tool 结果按 call id 索引，供 assistant 轮次配对。
        var results: [String: AgentMessage] = [:]
        for message in messages where message.role == .tool {
            if let id = message.toolCallId { results[id] = message }
        }

        for message in messages {
            switch message.role {
            case .user:
                items.append(TranscriptItem(id: message.id.uuidString, kind: .user(message.content)))
            case .assistant:
                if !message.content.isEmpty || (message.reasoning?.isEmpty == false) {
                    items.append(TranscriptItem(
                        id: message.id.uuidString,
                        kind: .assistant(text: message.content,
                                         reasoning: message.reasoning,
                                         isFailure: message.isFailure)))
                }
                if !message.toolCalls.isEmpty {
                    let rows = message.toolCalls.map { call -> AgentToolActivity in
                        let result = results[call.id]
                        return AgentToolActivity(
                            id: call.id,
                            name: call.name,
                            argumentsPreview: Self.preview(call.argumentsJSON),
                            state: result == nil ? .running : (Self.wasInterrupted(result!) ? .stopped : (result!.isFailure ? .failure : .success)),
                            summary: result.map { Self.summarize($0) })
                    }
                    items.append(TranscriptItem(id: message.id.uuidString + "_tools", kind: .tools(rows)))
                }
            case .tool, .system:
                continue
            }
        }
        return items
    }

    static func summarize(_ toolMessage: AgentMessage) -> String {
        if wasInterrupted(toolMessage) { return "已停止 · 结果未知" }
        if toolMessage.isFailure {
            if let code = (try? JSONValue.decode(jsonText: toolMessage.content))?["error_code"]?.stringValue {
                return "失败（\(code)）"
            }
            return "失败"
        }
        return "完成"
    }

    private static func wasInterrupted(_ message: AgentMessage) -> Bool {
        (try? JSONValue.decode(jsonText: message.content))?["error_code"]?.stringValue == "interrupted"
    }
// MARK: - 后端切换
    //
    // UI 里保存"AI 后端"选择时调用。刻意做成运行时可切：不重启 App、不影响当前 conversation
    // history；下一次 `send` 时就走新后端。**如果当前有正在跑的请求**，切换只影响未来 turn，
    // 已经在流上的那一轮跑到完成再算数（不 mid-stream 换传输，避免半截消息状态紊乱）。
    func setBackend(_ backend: any AgentBackend) {
        self.backend = backend
    }
}

// MARK: - 会话仓库
//
// ObservableObject 但**没有任何 @Published**：它只是个生命周期容器，
// 挂在 ContentView 的 @StateObject 上不会引起任何重算（见文件头说明）。

@MainActor
final class AgentSessionStore: ObservableObject {
    let edit = AgentChatModel(displayName: "编辑页",
        persistenceURL: ClipSlotsPaths.dataRoot.appendingPathComponent("agent-sessions/edit.json"))
    let canvas = AgentChatModel(displayName: "画布页",
        persistenceURL: ClipSlotsPaths.dataRoot.appendingPathComponent("agent-sessions/canvas.json"))

    /// v2.17.7：监听后端切换通知。**独立实例**分给 edit / canvas——Tika 后端会在实例里持有
    /// tikacli session state（首轮 `--new`、后续复用同一 session-id），共用会互相污染。
    private var backendObserver: NSObjectProtocol?

    init() {
        backendObserver = NotificationCenter.default.addObserver(
            forName: AgentBackendCoordinator.backendChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.edit.setBackend(AgentBackendCoordinator.currentBackend())
                self.canvas.setBackend(AgentBackendCoordinator.currentBackend())
            }
        }
    }

    func session(for mode: WorkspaceMode) -> AgentChatModel {
        mode == .canvas ? canvas : edit
    }
}
