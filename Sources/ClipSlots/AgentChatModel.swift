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
            systemPrompt: systemPrompt,
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
    enum State: Equatable { case running, success, failure }
    let id: String          // tool_call id
    let name: String
    let argumentsPreview: String
    var state: State
    var summary: String?
}

// MARK: - 一条会话

@MainActor
final class AgentChatModel: ObservableObject {
    /// 完整线上下文（含 role=tool 的消息）。UI 渲染时再折叠成气泡 + 工具行。
    /// 刻意保存完整历史而不是"只留展示用的部分"：工具结果是模型下一轮的依据，
    /// 丢了它模型就会重复调用同一个工具。
    @Published private(set) var messages: [AgentMessage] = []
    @Published private(set) var streamingContent = ""
    @Published private(set) var streamingReasoning = ""
    @Published private(set) var liveActivities: [AgentToolActivity] = []
    @Published private(set) var isRunning = false
    @Published var errorText: String?
    /// 上一轮 token 用量，显示在输入区上方（让用户对成本有感知）。
    @Published private(set) var usageLine: String?
    /// 触发配置页：没有 API Key 时第一次发送会把它置 true。
    @Published var needsConfiguration = false

    let displayName: String
    private let service: AgentService
    private let registry: AgentToolRegistry
    private var runTask: Task<Void, Never>?

    init(displayName: String,
         service: AgentService = AgentService(),
         registry: AgentToolRegistry = AgentToolRegistry()) {
        self.displayName = displayName
        self.service = service
        self.registry = registry
    }

    var hasAPIKey: Bool { service.hasAPIKey }

    var isEmpty: Bool { messages.isEmpty }

    // MARK: 发送

    func send(text: String, config: AgentConfig, enabledSkills: [AgentSkill]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        guard service.hasAPIKey else {
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
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 事件回调是 @Sendable，且会在任意线程被调用，所以统一 hop 回主线程。
                try await self.service.run(history: history,
                                           config: config,
                                           tools: self.registry) { event in
                    await self.apply(event)
                }
                await MainActor.run { self.completeRun() }
            } catch let error as AgentError {
                await MainActor.run { self.failRun(error) }
            } catch is CancellationError {
                await MainActor.run { self.failRun(AgentError.cancelled) }
            } catch {
                await MainActor.run { self.failRun(AgentError.network(error.localizedDescription)) }
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        // 不在这里改 isRunning：让 catch 分支统一收尾，避免"UI 已恢复但流还在写"的错位。
    }

    func clearHistory() {
        stop()
        messages = []
        streamingContent = ""
        streamingReasoning = ""
        liveActivities = []
        errorText = nil
        usageLine = nil
        isRunning = false
    }

    // MARK: 事件

    private func apply(_ event: AgentRunEvent) async {
        await MainActor.run {
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
        isRunning = false
        runTask = nil
        streamingContent = ""
        streamingReasoning = ""
    }

    private func failRun(_ error: AgentError) {
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
                            state: result == nil ? .running : (result!.isFailure ? .failure : .success),
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
        if toolMessage.isFailure {
            if let code = (try? JSONValue.decode(jsonText: toolMessage.content))?["error_code"]?.stringValue {
                return "失败（\(code)）"
            }
            return "失败"
        }
        return "完成"
    }
}

// MARK: - 会话仓库
//
// ObservableObject 但**没有任何 @Published**：它只是个生命周期容器，
// 挂在 ContentView 的 @StateObject 上不会引起任何重算（见文件头说明）。

@MainActor
final class AgentSessionStore: ObservableObject {
    let edit = AgentChatModel(displayName: "编辑页")
    let canvas = AgentChatModel(displayName: "画布页")

    func session(for mode: WorkspaceMode) -> AgentChatModel {
        mode == .canvas ? canvas : edit
    }
}
