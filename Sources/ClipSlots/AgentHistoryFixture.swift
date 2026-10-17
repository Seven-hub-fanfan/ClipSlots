#if DEBUG
import Foundation
import ClipSlotsKit

/// Writes only to the isolated regression directory, using the production schema.
@MainActor
func writeAgentHistoryFixture(_ messages: [AgentMessage], to url: URL,
                              title: String? = nil, attachments: [AgentAttachment] = []) throws {
    struct Envelope: Encodable {
        let current: AgentChatModel.SavedConversation
        let recent: [AgentChatModel.SavedConversation]
    }
    let saved = AgentChatModel.SavedConversation(id: UUID(), messages: messages, draft: "",
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000), codexThreadID: "legacy-fixture",
        draftAttachments: attachments,
        codexContext: .init(cwd: "/legacy", title: title))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(Envelope(current: saved, recent: [])).write(to: url, options: .atomic)
}
#endif
