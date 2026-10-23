#if DEBUG
import AppKit
import ClipSlotsKit

@MainActor
func runAgentScreenCaptureProbe(model: AgentChatModel, host: NSView,
                                check: (Bool, String) -> Void) async {
    guard ProcessInfo.processInfo.environment["CLIPSLOTS_CAPTURE_FIXTURE"] != nil else { return }
    func find(_ root: NSView, _ id: String) -> AnyObject? {
        NativeAccessibilityProbe.elements(root).first { ($0.accessibilityIdentifier?() ?? "") == id }
    }
    func press(_ root: NSView, _ id: String) -> Bool {
        find(root, id)?.accessibilityPerformPress?() == true
    }
    func wait(_ count: Int) async {
        for _ in 0..<100 {
            if model.draftAttachments.count == count && !model.isImportingAttachments { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }
    model.draftAttachments = []
    check(press(host, "agent-screen-capture"), "native scissors starts screenshot attachment")
    await wait(1)
    check(model.draftAttachments.first?.imageSnapshot != nil
          && model.draftAttachments.first?.sha256 != nil,
          "captured screenshot imports immutable image bytes")
    check(AgentScreenCapture.debugArguments.contains("-x")
          && AgentScreenCapture.debugArguments.contains("-i")
          && AgentScreenCapture.debugArguments.contains("-U")
          && AgentScreenCapture.debugArguments.contains("-Jselection"),
          "screenshot uses silent native region/window picker with selection toolbar")
    // Import finishes before SwiftUI has enabled the capture controls again.
    try? await Task.sleep(for: .milliseconds(250))
    check(press(host, "agent-capture-menu"), "native capture chevron opens menu")
    try? await Task.sleep(for: .milliseconds(250))
    if let menu = NSApp.windows.compactMap(\.contentView).first(where: {
        find($0, "agent-capture-record") != nil
    }) {
        check(press(menu, "agent-capture-record"), "native menu starts recording attachment")
    } else { check(false, "native capture recording menu exists") }
    await wait(2)
    check(model.draftAttachments.last?.sampledFrames?.count == 3
          && model.draftAttachments.last?.textSnapshot?.contains("未读取音轨") == true,
          "recording imports actual video frames with explicit scope")
    check(AgentScreenCapture.debugArguments.contains("-v")
          && AgentScreenCapture.debugArguments.contains("-x")
          && !AgentScreenCapture.debugArguments.contains("-g")
          && !AgentScreenCapture.debugArguments.contains(where: { $0.hasPrefix("-G") }),
          "recording has no sound or microphone capture flags")
    model.clearHistory()
    let capture = AgentScreenCapture()
    capture.start(.image, model: model)
    model.draft = "切换对话的捕获隔离验收"
    let previousConversation = model.selectedConversationID
    model.clearHistory()
    check(model.selectedConversationID != previousConversation,
          "capture scope probe switches to an actual new conversation")
    for _ in 0..<100 where capture.isCapturing { try? await Task.sleep(for: .milliseconds(20)) }
    check(model.draftAttachments.isEmpty && !capture.isCapturing,
          "capture cannot attach to another conversation")
    capture.start(.image, model: model)
    capture.cancel()
    for _ in 0..<100 where capture.isCapturing { try? await Task.sleep(for: .milliseconds(20)) }
    check(model.draftAttachments.isEmpty && !capture.isCapturing,
          "cancelled capture leaves draft empty")
}
#endif
