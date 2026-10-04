import Foundation

/// Explicit, immutable input for a turn. Media bytes and filesystem paths are never included.
public struct AgentCanvasReference: Codable, Equatable, Identifiable, Sendable {
    public var id: String { nodeID }
    public let projectID: String
    public let nodeID: String
    public let nodeCreatedAt: Date
    public let groupID: String
    public let slot: Int
    public let title: String
    public let text: String
    public let attachmentNames: [String]
    public let contentRevision: String?

    public init(projectID: String, nodeID: String, nodeCreatedAt: Date, groupID: String,
                slot: Int, title: String, text: String, attachmentNames: [String], contentRevision: String? = nil) {
        self.projectID = projectID
        self.nodeID = nodeID
        self.nodeCreatedAt = nodeCreatedAt
        self.groupID = groupID
        self.slot = slot
        self.title = title
        self.text = text
        self.attachmentNames = attachmentNames
        self.contentRevision = contentRevision
    }
}

/// Only the body is exchanged. Attachments, labels and manual covers remain live.
public struct AgentSlotBody: Equatable {
    public let items: [[PasteboardItem]]
    public let htmlSource: String?
    public init(_ content: SlotContent) {
        items = content.items
        htmlSource = content.htmlSource
    }
    public init(text: String) {
        items = [[PasteboardItem(type: "public.utf8-plain-text", data: Data(text.utf8))]]
        htmlSource = nil
    }
    public var plainText: String { SlotContent(items: items, htmlSource: htmlSource).plainText ?? "" }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.htmlSource == rhs.htmlSource && lhs.items.count == rhs.items.count &&
        zip(lhs.items, rhs.items).allSatisfy { a, b in
            a.count == b.count && zip(a, b).allSatisfy { $0.type == $1.type && $0.data == $1.data }
        }
    }
}

public enum AgentCanvasError: LocalizedError {
    case conflict, unavailable, writeFailed, busy, staleTarget
    public var errorDescription: String? {
        switch self {
        case .conflict: return "正文已被修改。请重新预览，确认最新内容后再应用。"
        case .unavailable: return "目标槽位不存在或暂时无法读取。"
        case .writeFailed: return "内容未能保存，本次操作未完成。"
        case .busy: return "槽位仍在保存，请稍后重试。"
        case .staleTarget: return "目标节点已删除、重新绑定或已切换项目。请重新选择目标。"
        }
    }
}

/// No executable capabilities in the canvas preview workflow, including Skills.
public final class AgentPreviewTools: AgentToolExecuting {
    public init() {}
    public func specs() -> [AgentToolSpec] { [] }
    public func execute(call: AgentToolCall) async -> AgentToolResult {
        .failure("画布结果需要由用户预览并确认应用。此会话不执行工具。", code: "PREVIEW_REQUIRED")
    }
}
