import Foundation

/// Explicit, immutable input for a turn. Captured images are sent separately from reference metadata.
public struct AgentCanvasReference: Codable, Equatable, Identifiable, Sendable {
    public static let maxReferences = 20
    public static let maxTextBytes = 96_000
    public enum MediaKind: String, Codable, Sendable {
        case text, image, video, audio, file
        public var title: String {
            switch self {
            case .text: return "Text"
            case .image: return "Image"
            case .video: return "Video"
            case .audio: return "Audio"
            case .file: return "File"
            }
        }
        public var symbol: String {
            switch self {
            case .text: return "text.alignleft"
            case .image: return "photo"
            case .video: return "video"
            case .audio: return "waveform"
            case .file: return "doc"
            }
        }
    }
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
    public let images: [AgentAttachment]?
    public let mediaKind: MediaKind?
    /// Presentation only; never included in model context or counted as inspected media.
    public let previewImage: Data?

    public init(projectID: String, nodeID: String, nodeCreatedAt: Date, groupID: String,
                slot: Int, title: String, text: String, attachmentNames: [String], contentRevision: String? = nil,
                images: [AgentAttachment]? = nil, mediaKind: MediaKind? = nil, previewImage: Data? = nil) {
        self.projectID = projectID
        self.nodeID = nodeID
        self.nodeCreatedAt = nodeCreatedAt
        self.groupID = groupID
        self.slot = slot
        self.title = title
        self.text = text
        self.attachmentNames = attachmentNames
        self.contentRevision = contentRevision
        self.images = images
        self.mediaKind = mediaKind
        self.previewImage = previewImage
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

/// Only concrete immutable readers may pass. A registry or custom executor cannot
/// opt into preview privileges by advertising read-like tool names.
public final class AgentPreviewTools: AgentToolExecuting {
    public init() {}
    public static func restricted(_ tools: AgentToolExecuting?) -> AgentToolExecuting {
        if let reader = tools as? CanvasAgentReadTools { return reader }
        if let directory = tools as? AgentDirectoryTools { return directory.restrictedForPreview() }
        if let journaled = tools as? AgentJournaledTools { return journaled.restrictedForPreview() }
        return AgentPreviewTools()
    }
    public func specs() -> [AgentToolSpec] { [] }
    public func execute(call: AgentToolCall) async -> AgentToolResult {
        .failure("画布结果需要由用户预览并确认应用。此会话只允许固定快照读取工具。", code: "PREVIEW_REQUIRED")
    }
}
