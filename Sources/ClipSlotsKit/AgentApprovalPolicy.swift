import Foundation

/// Directory scope and operation approval are independent, frozen per turn.
public enum AgentApprovalPolicy {
    public static let destructive: Set<String> = [
        "canvas_delete_nodes", "clear_slot", "delete_group", "delete_page",
        "clear_thumbnail", "repair_index"
    ]
    private static let automaticLibraryWrites: Set<String> = [
        "write_slot", "create_group", "create_page", "rename_group",
        "write_attachment", "set_thumbnail"
    ]

    public static func requiresConfirmation(_ name: String, automatic: Bool, reader: Bool) -> Bool {
        if reader { return false }
        if !automatic || destructive.contains(name) { return true }
        if CanvasAgentActionTools.writers.contains(name) { return false }
        // Undeclared skill/subprocess effects never inherit automatic file approval.
        return !automaticLibraryWrites.contains(name) && name != "local_write_file"
    }
}
