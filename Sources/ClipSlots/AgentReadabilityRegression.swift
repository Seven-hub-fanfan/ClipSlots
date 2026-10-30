#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

/// Local text fixtures only: never issue a remote generation request.
@MainActor
func runAgentReadabilityProbe(directory: URL, check: (Bool, String) -> Void) async {
    NativeAccessibilityProbe.enable()
    func settle() async { try? await Task.sleep(for: .milliseconds(350)) }
    func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
        NativeAccessibilityProbe.elements(node)
    }
    func scrolls(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
    }
    check(AgentMarkdownBlock.parse("第一段🙂\n继续说明。\n\n第二段。") ==
          [.paragraph("第一段🙂\n继续说明。"), .paragraph("第二段。")], "paragraph boundaries and Unicode survive rendering")
    check(AgentMarkdownBlock.parse("#标签\n\n## 小标题") ==
          [.paragraph("#标签"), .heading(2, "小标题")], "hashtags are not mistaken for headings")
    check(AgentMarkdownBlock.parse("10. 第一项\n    续行\n  - 子项\n- [x] 完成") ==
          [.list(marker: "10.", depth: 0, text: "第一项\n续行"),
           .list(marker: "•", depth: 1, text: "子项"),
           .list(marker: "☑", depth: 0, text: "完成")], "ordered nested and task lists retain labels and continuation")
    check(AgentMarkdownBlock.parse("2026.10\n\n> 引用一\n> 引用二") ==
          [.paragraph("2026.10"), .quote("引用一\n引用二")], "dates stay prose and block quotes remain grouped")
    check(AgentMarkdownBlock.parse("````md\n```swift\nlet x = 1\n```\n````") ==
          [.code(language: "md", text: "```swift\nlet x = 1\n```")], "longer code fences preserve nested fences")
    let code = "let 示例 = \"🙂\"\n  print(示例)"
    check(AgentMarkdownBlock.parse("```swift\n" + code) == [.code(language: "swift", text: code)],
          "unfinished streamed code remains visible without trimming indentation")
    check(AgentMarkdownBlock.parse("~~~text\nline\n~~~\n\n结束") ==
          [.code(language: "text", text: "line"), .paragraph("结束")], "tilde fences close without swallowing the following paragraph")
    let skill = "[$clipslots-manager](/Applications/ClipSlots.app/Contents/Resources/skills/clipslots-manager/SKILL.md)"
    let inline = AgentMarkdownText.inline(skill + " 请整理素材。", size: 15)
    check(String(inline.characters) == "$clipslots-manager 请整理素材。" && inline.runs.contains { $0.link != nil },
          "skill references render readable labels with their destination retained")
    let format = AgentMarkdownText.inline("**重点** 与 `clipslots list`")
    check(format.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
          && format.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && $0.font != nil },
          "inline emphasis and code have distinct readable typography")

    let reasoning = """
    排版验收示例：先核对素材和页面的当前状态，再组织清晰的答复。

    Long passages should remain easy to scan. Paragraph spacing separates ideas, while a comfortable line length keeps the reader's place.

    1. 查看已有素材，保留原有附件与顺序。
    2. 区分操作过程和最终答复，让正文成为主要阅读内容。
    """
    let answer = """
    我先看一下 ClipSlots 当前的数据状态，再整理素材。**原有内容会完整保留**，你可以继续补充整理要求。

    ## 素材整理建议

    1. **明确主题**：按项目或用途归类，给每组素材一个容易辨认的名称。
    2. **保留细节**：图片、视频和文本保持原始顺序，长句换行后仍与正文对齐。
    3. **继续创作**：用 `clipslots list` 查看槽位，选择需要处理的内容。

    > 先检查，再修改。过程信息可以随时展开查看。

    ```swift
    let title = "海边日落"
    print(title)
    ```

    接下来可以选择一个分组继续。🙂
    """
    let messages = [
        AgentMessage(role: .user, content: skill + " 请帮我整理素材，保留原始文件。"),
        AgentMessage(role: .assistant, content: "", reasoning: reasoning),
        AgentMessage(role: .assistant, content: answer)
    ]
    let path = directory.appendingPathComponent("readability-history.json")
    try? writeAgentHistoryFixture(messages, to: path, title: "整理素材")
    let model = AgentChatModel(displayName: "排版验收",
        backend: AgentService(transport: AgentScriptedTransport(steps: []),
                              secretStore: AgentInMemorySecretStore(key: "fixture")), persistenceURL: path)
    let host = NSHostingView(rootView: AgentWorkspaceView(model: model))
    let window = NSWindow(contentRect: NSRect(x: 80, y: 60, width: 1280, height: 900),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "ClipSlots · 文字排版验收"
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    await settle()
    func scrollToTop() {
        guard let scroll = scrolls(host).max(by: { $0.bounds.height < $1.bounds.height }) else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    }
    func snapshot(_ name: String) {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            check(false, "native readability snapshot \(name)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("agent-readability-\(name).png"))
    }
    let initialAppearance = UserDefaults.standard.string(forKey: AppearanceDefaults.key)
    let initialSkin = AppSkinCenter.current
    for skin in AppSkin.allCases {
        AppSkinCenter.apply(skin)
        for appearance in ["light", "dark"] {
            UserDefaults.standard.set(appearance, forKey: AppearanceDefaults.key)
            window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
            host.rootView = AgentWorkspaceView(model: model)
            await settle()
            scrollToTop()
            await settle()
            let nodes = elements(host)
            let toggle = nodes.first { ($0.accessibilityIdentifier?() ?? "") == "agent-reasoning-toggle" }
            check(toggle != nil, "\(skin.rawValue) \(appearance) exposes reasoning disclosure")
            check(!nodes.contains { ($0.accessibilityIdentifier?() ?? "") == "agent-reasoning-content" },
                  "\(skin.rawValue) \(appearance) hides reasoning by default")
            let titles = nodes.compactMap { $0.accessibilityLabel?() }
            check(!titles.contains("ClipSlots"), "\(skin.rawValue) \(appearance) has no repeated assistant branding")
            snapshot("\(skin.rawValue)-\(appearance)")
            if skin == .minimal {
                let previousOrigin = scrolls(host).max(by: { $0.bounds.height < $1.bounds.height })?.documentVisibleRect.minY
                check(toggle?.accessibilityPerformPress?() == true, "\(appearance) expands reasoning by native action")
                await settle()
                check(scrolls(host).max(by: { $0.bounds.height < $1.bounds.height })?.documentVisibleRect.minY == previousOrigin,
                      "\(appearance) expanding reasoning keeps the reader's position")
                check(elements(host).contains { ($0.accessibilityIdentifier?() ?? "") == "agent-reasoning-content" },
                      "\(appearance) expanded reasoning is accessible")
                snapshot("expanded-\(appearance)")
                let refreshed = elements(host).first { ($0.accessibilityIdentifier?() ?? "") == "agent-reasoning-toggle" }
                check(refreshed?.accessibilityPerformPress?() == true, "\(appearance) collapses reasoning by native action")
                await settle()
                check(!elements(host).contains { ($0.accessibilityIdentifier?() ?? "") == "agent-back-to-latest" },
                      "\(appearance) fitting conversation has no floating button obscuring text")
            }
        }
    }
    UserDefaults.standard.set("light", forKey: AppearanceDefaults.key)
    window.appearance = NSAppearance(named: .aqua)
    window.setContentSize(NSSize(width: 900, height: 800))
    await settle()
    scrollToTop()
    await settle()
    snapshot("narrow-light")
    check(model.messages == messages && !model.isRunning, "layout and disclosure actions preserve original messages without requests")
    window.close()

    let sidebar = NSHostingView(rootView: AgentSidebarView(model: model, isVisible: .constant(true), workspaceMode: .edit))
    let sidebarWindow = NSWindow(contentRect: NSRect(x: 100, y: 60, width: AgentSidebarView.width, height: 820),
        styleMask: [.titled], backing: .buffered, defer: false)
    sidebarWindow.isReleasedWhenClosed = false
    sidebarWindow.contentView = sidebar
    sidebarWindow.makeKeyAndOrderFront(nil)
    await settle()
    sidebar.layoutSubtreeIfNeeded()
    if let rep = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds) {
        sidebar.cacheDisplay(in: sidebar.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("agent-readability-sidebar.png"))
    }
    sidebarWindow.close()
    UserDefaults.standard.set(initialAppearance, forKey: AppearanceDefaults.key)
    AppSkinCenter.apply(initialSkin)
}
#endif
