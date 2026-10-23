import Foundation

public protocol AgentCLICommandAuthorizing {
    func permitsCLI(_ command: String) -> Bool
}

public enum AgentAccessMode: String, Codable, CaseIterable, Sendable {
    case selectedDirectories, allDirectoriesReadOnly, fullAccess
    public var title: String {
        switch self {
        case .selectedDirectories: return "仅所选目录"
        case .allDirectoriesReadOnly: return "全部目录 · 只读"
        case .fullAccess: return "Full Access"
        }
    }
    public var detail: String {
        switch self {
        case .selectedDirectories: return "只访问所选工作目录，写入前确认。"
        case .allDirectoriesReadOnly: return "可读取 macOS 已允许访问的目录，禁止本地写入和业务修改工具。"
        case .fullAccess: return "可读写 macOS 已允许访问的目录，文件写入自动执行。"
        }
    }
}

/// Enforce mode at dispatch as well as schema publication. Skill subprocesses
/// cannot be confined by a prompt, so they are available only in Full Access.
public final class AgentAccessTools: AgentToolExecuting, AgentCLICommandAuthorizing {
    private let base: AgentToolExecuting
    private let mode: AgentAccessMode
    private static let readers: Set<String> = [
        "list_slots", "read_slot", "search_slots", "list_groups", "list_pages",
        "list_skills", "read_skill"
    ]
    private static let scoped: Set<String> = readers.union([
        "write_slot", "clear_slot", "create_group", "create_page", "rename_group",
        "delete_group", "delete_page", "clear_thumbnail", "repair_index"
    ])
    public init(base: AgentToolExecuting, mode: AgentAccessMode) { self.base = base; self.mode = mode }
    public func permitsCLI(_ command: String) -> Bool {
        if command == "version" || command == "help" { return true }
        let names = ["list": "list_slots", "read": "read_slot", "search": "search_slots",
                     "groups": "list_groups", "pages": "list_pages", "write": "write_slot",
                     "clear": "clear_slot", "paste": "paste_slot", "create-group": "create_group",
                     "create-page": "create_page", "rename-group": "rename_group",
                     "delete-group": "delete_group", "delete-page": "delete_page",
                     "write-attachment": "write_attachment", "set-thumbnail": "set_thumbnail",
                     "clear-thumbnail": "clear_thumbnail", "repair-index": "repair_index"]
        guard let name = names[command] else { return false }
        return permits(name)
    }
    private func permits(_ name: String) -> Bool {
        mode == .fullAccess || (mode == .allDirectoriesReadOnly ? Self.readers : Self.scoped).contains(name)
    }
    public func specs() -> [AgentToolSpec] { base.specs().filter { permits($0.name) } }
    public func execute(call: AgentToolCall) async -> AgentToolResult {
        guard permits(call.name), specs().contains(where: { $0.name == call.name }) else {
            return .failure("当前访问模式没有开放此工具，请在权限菜单中调整模式。", code: "ACCESS_MODE_DENIED")
        }
        return await base.execute(call: call)
    }
}
