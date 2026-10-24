import Foundation
import ClipSlotsKit

/// One declared tool set for both sidebars. Library defaults belong to the
/// submitted turn; changing the displayed group cannot retarget a queued call.
final class AgentSharedSidebarTools: AgentToolExecuting, AgentCLICommandAuthorizing {
    private let canvas: AgentToolExecuting
    private let library: AgentToolExecuting
    private let pageID: String?
    private let groupID: String?
    private let automaticApproval: Bool
    private let isCurrent: @MainActor @Sendable () -> Bool
    private let onInteraction: @Sendable (AgentInteraction) async -> Void
    private static let readers: Set<String> = [
        "list_slots", "read_slot", "search_slots", "list_groups", "list_pages",
        "list_skills", "read_skill"
    ]

    init(canvas: AgentToolExecuting, library: AgentToolExecuting,
         pageID: String?, groupID: String?, automaticApproval: Bool,
         isCurrent: @escaping @MainActor @Sendable () -> Bool,
         onInteraction: @escaping @Sendable (AgentInteraction) async -> Void) {
        self.canvas = canvas
        self.library = library
        self.pageID = pageID
        self.groupID = groupID
        self.automaticApproval = automaticApproval
        self.isCurrent = isCurrent
        self.onInteraction = onInteraction
    }

    func specs() -> [AgentToolSpec] {
        let names = Set(canvas.specs().map(\.name))
        return canvas.specs() + library.specs().filter { !names.contains($0.name) }
    }

    // Local file tools cannot bypass this wrapper's per-call approval and target binding.
    func permitsCLI(_ command: String) -> Bool { command == "version" || command == "help" }

    func execute(call: AgentToolCall) async -> AgentToolResult {
        guard !Task.isCancelled, await isCurrent() else {
            return .failure("会话或项目已改变，本轮没有继续执行。", code: "STALE_TARGET")
        }
        if canvas.specs().contains(where: { $0.name == call.name }) {
            return await canvas.execute(call: call)
        }
        guard let spec = library.specs().first(where: { $0.name == call.name }) else {
            return .failure("本轮未开放此工具。", code: "ACCESS_MODE_DENIED")
        }
        do {
            var input = try JSONValue.decode(jsonText: call.argumentsJSON)
            try ByteArtistContract.validateField(try input.encodedText(), schema: spec.parameters)
            guard var object = input.objectValue else { throw AgentOperationError("工具参数必须是对象。") }
            let properties = spec.parameters["properties"]?.objectValue ?? [:]
            if properties["page"] != nil && object["page"] == nil && object["group"] == nil,
               input["all_groups"] != .bool(true), let pageID {
                object["page"] = .string(pageID)
            }
            if properties["group"] != nil && object["group"] == nil,
               input["page"] == nil,
               input["all_groups"] != .bool(true), let groupID {
                object["group"] = .string(groupID)
            }
            input = .object(object)
            try ByteArtistContract.validateField(try input.encodedText(), schema: spec.parameters)
            if AgentApprovalPolicy.requiresConfirmation(call.name, automatic: automaticApproval,
                                                         reader: Self.readers.contains(call.name)) {
                let decision = SidebarToolDecision()
                let request = AgentInteraction(kind: .commandApproval, params: [
                    "command": .string(call.name), "reason": "修改槽位库",
                    "title": .string("槽位库 · \(call.name)"),
                    "preview": .string(String(call.argumentsJSON.prefix(400))),
                    "item": ["command": .string(call.name), "arguments": input],
                    "availableDecisions": ["accept", "decline"]
                ]) { value in decision.set(value["decision"] == .string("accept")) }
                await onInteraction(request)
                defer { request.invalidate() }
                while decision.value == nil && Date() < request.expiresAt {
                    try Task.checkCancellation()
                    guard await isCurrent() else { throw AgentCanvasError.staleTarget }
                    guard request.isPending else { break }
                    try await Task.sleep(for: .milliseconds(80))
                }
                guard decision.value == true else {
                    return .failure("未允许本次槽位操作。", code: "DECLINED")
                }
            }
            try Task.checkCancellation()
            guard await isCurrent() else { throw AgentCanvasError.staleTarget }
            return await library.execute(call: .init(id: call.id, name: call.name,
                                                     argumentsJSON: try input.encodedText()))
        } catch {
            return .failure(error.localizedDescription,
                code: error is CancellationError ? "CANCELLED" : "SIDEBAR_TOOL_FAILED")
        }
    }
}

private final class SidebarToolDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Bool?
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return answer }
    func set(_ value: Bool) { lock.lock(); defer { lock.unlock() }; answer = value }
}
