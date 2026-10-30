import Foundation
import ClipSlotsKit

enum AgentApplicationApproval {
    private final class Decision: @unchecked Sendable {
        let lock = NSLock()
        private var answer: Bool?
        var value: Bool? { lock.lock(); defer { lock.unlock() }; return answer }
        func set(_ value: Bool) { lock.lock(); defer { lock.unlock() }; answer = value }
    }
    static func request(title: String, tool: AgentMCPTool, call: AgentToolCall,
                        isCurrent: @escaping @MainActor @Sendable () -> Bool,
                        onInteraction: @escaping @Sendable (AgentInteraction) async -> Void) async -> Bool {
        let decision = Decision()
        let request = AgentInteraction(kind: .commandApproval, params: [
            "command": .string(tool.name), "reason": .string(tool.readOnly ? "读取应用数据" : "执行应用操作"),
            "title": .string(title + " · " + tool.name), "preview": .string(String(call.argumentsJSON.prefix(1000))),
            "availableDecisions": ["accept", "decline"]
        ]) { value in decision.set(value["decision"] == "accept") }
        await onInteraction(request)
        defer { request.invalidate() }
        while decision.value == nil && Date() < request.expiresAt && request.isPending {
            guard !Task.isCancelled, await isCurrent() else { return false }
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return false }
        }
        return decision.value == true && !Task.isCancelled
    }
}
