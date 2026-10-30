#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runAgentDirectoryProbe(directory: URL, check: (Bool, String) -> Void) async {
    func settle() async { try? await Task.sleep(for: .milliseconds(180)) }
    func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 30 else { return [] }
        let children = node.accessibilityChildren?() ?? []
        let fallback = (node as? NSView)?.subviews ?? []
        return [node] + (children.isEmpty ? fallback : children).flatMap { elements($0 as AnyObject, depth: depth + 1) }
    }
    let root = directory.appendingPathComponent("local-directory-fixture")
    let store = AgentWorkingDirectoryStore(root: root)
    let backend = DirectoryCaptureBackend()
    let model = AgentChatModel(displayName: "目录验证", backend: backend,
        persistenceURL: root.appendingPathComponent("session.json"), workingDirectories: store)
    do {
        let a = root.appendingPathComponent("超长目录名称-项目 A-需要中间省略以保证窄窗口布局")
        let b = root.appendingPathComponent("项目 B")
        for path in [a, b] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        try Data("project-A".utf8).write(to: a.appendingPathComponent("input.txt"))
        try Data("project-B".utf8).write(to: b.appendingPathComponent("input.txt"))
        let aid = try await store.add(a)
        let bid = try await store.add(b)
        let duplicate = try await store.add(a)
        check(duplicate == aid && store.directories.count == 2, "directory add deduplicates canonical URL")
        model.selectWorkingDirectory(aid)
        model.draft = "保存的草稿"
        let conversationA = model.selectedConversationID
        check(model.flushSession(), "directory selection persists with conversation")
        model.clearHistory()
        model.selectWorkingDirectory(bid)
        check(model.workingDirectoryID == bid, "new conversation can select another directory")
        model.openConversation(id: conversationA)
        check(model.workingDirectoryID == aid && model.draft == "保存的草稿", "history restores its own directory and draft")
        let reopened = AgentChatModel(displayName: "重新打开", backend: backend,
            persistenceURL: root.appendingPathComponent("session.json"),
            workingDirectories: AgentWorkingDirectoryStore(root: root))
        check(reopened.workingDirectoryID == aid, "restart restores OS directory selection")
        check(model.send(text: "读取目录文件", config: AgentConfig(), enabledSkills: []), "directory-backed Agent turn starts")
        model.selectWorkingDirectory(bid)
        check(model.workingDirectoryID == aid && store.error != nil, "in-flight turn cannot switch its directory")
        store.error = nil
        for _ in 0..<40 { if !model.isRunning { break }; await settle() }
        check(backend.paths.last == a.resolvingSymlinksInPath().path
              && model.messages.last?.content.contains("project-A") == true,
              "Agent backend receives selected path and reads selected file")
        model.selectWorkingDirectory(bid)
        _ = model.send(text: "读取另一个目录", config: AgentConfig(), enabledSkills: [])
        for _ in 0..<40 { if !model.isRunning { break }; await settle() }
        check(backend.paths.last == b.resolvingSymlinksInPath().path
              && model.messages.last?.content.contains("project-B") == true, "next turn uses newly selected directory")
        try store.remove(bid)
        let sent = model.send(text: "无效目录不能发送", config: AgentConfig(), enabledSkills: [])
        check(!sent && model.errorText != nil && FileManager.default.fileExists(atPath: b.path),
              "removing directory blocks stale selection without deleting its files")
        model.selectWorkingDirectory(aid)
        model.draft = ""
        let originalSkin = AppSkinCenter.current
        defer { AppSkinCenter.apply(originalSkin) }
        let host = NSHostingView(rootView: AgentSidebarView(model: model, isVisible: .constant(true), workspaceMode: .edit))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 60, width: 480, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for skin in AppSkin.allCases {
            AppSkinCenter.apply(skin)
            for dark in [false, true] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for (mode, width) in [(WorkspaceMode.edit, AgentSidebarView.width), (.agent, CGFloat(360)), (.agent, CGFloat(800))] {
                    window.setContentSize(NSSize(width: width, height: 720))
                    host.rootView = AgentSidebarView(model: model, isVisible: .constant(true), workspaceMode: mode)
                    await settle()
                    host.layoutSubtreeIfNeeded()
                    let button = elements(host).first { ($0.accessibilityIdentifier?() ?? "") == "agent-working-directory" }
                    let frame = button?.accessibilityFrame?()
                    let bounds = window.convertToScreen(host.bounds)
                    let label = "\(mode.rawValue)-\(skin.rawValue)-\(dark ? "dark" : "light")-\(Int(width))"
                    check(frame.map { $0.width >= 26 && $0.width <= 34 && $0.height >= 26
                        && $0.minX >= bounds.minX - 2 && $0.maxX <= bounds.maxX + 2
                        && $0.minY >= bounds.minY - 2 && $0.maxY <= bounds.maxY + 2 } ?? false,
                          "directory control visible inside composer \(label)")
                    if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: image)
                        try image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("directory-\(label).png"))
                    }
                }
            }
        }
        if let button = elements(host).first(where: { ($0.accessibilityIdentifier?() ?? "") == "agent-working-directory" }) {
            _ = button.accessibilityPerformPress?()
            await settle()
            let nodes = NSApp.windows.compactMap(\.contentView).flatMap { elements($0) }
            let add = nodes.first { ($0.accessibilityIdentifier?() ?? "") == "agent-directory-add" }
            check(add != nil, "directory management popover exposes add action")
            for mode in AgentAccessMode.allCases {
                check(nodes.contains { ($0.accessibilityIdentifier?() ?? "") == "agent-access-\(mode.rawValue)" },
                      "native permission menu exposes \(mode.title)")
            }
            let access = nodes.first { ($0.accessibilityIdentifier?() ?? "") == "agent-access-allDirectoriesReadOnly" }
            _ = access?.accessibilityPerformPress?()
            await settle()
            check(model.accessMode == .allDirectoriesReadOnly, "native permission choice changes actual model policy")
            let currentNodes = NSApp.windows.compactMap(\.contentView).flatMap { elements($0) }
            let selected = currentNodes.first { ($0.accessibilityIdentifier?() ?? "") == "agent-access-selectedDirectories" }
            _ = selected?.accessibilityPerformPress?()
            await settle()
            check(model.accessMode == .selectedDirectories, "native permission choice restores selected-directory policy")
            for window in NSApp.windows where window.contentView != host {
                if let view = window.contentView, view.bounds.width > 300, view.bounds.width < 400,
                   let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: image)
                    try image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("access-mode-popover.png"))
                }
            }
            let freshAdd = NSApp.windows.compactMap(\.contentView).flatMap { elements($0) }
                .first { ($0.accessibilityIdentifier?() ?? "") == "agent-directory-add" }
            _ = freshAdd?.accessibilityPerformPress?()
            await settle()
            let panel = NSApp.windows.compactMap { $0 as? NSOpenPanel }.first
            check(panel?.canChooseDirectories == true && panel?.canChooseFiles == false,
                  "native directory-only NSOpenPanel opens from composer")
            panel?.cancel(nil)
            await settle()
            check(!store.isChoosing && store.directories.count == 1 && model.workingDirectoryID == aid,
                  "cancelling OS directory picker preserves list and selection")
        } else { check(false, "directory control is actionable") }
    } catch { check(false, "directory native probe: \(error)") }
}

private final class DirectoryCaptureBackend: AgentBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var paths: [String] { lock.withLock { storage } }
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        lock.withLock { storage.append(config.workingDirectory ?? "") }
        try await Task.sleep(for: .milliseconds(300))
        let result = await tools?.execute(call: .init(id: UUID().uuidString, name: "local_read_file",
                                                    argumentsJSON: #"{"path":"input.txt"}"#))
        let json = try? JSONValue.decode(jsonText: result?.content ?? "")
        let message = AgentMessage(role: .assistant, content: "已读取 input.txt：" + (json?["content"]?.stringValue ?? "读取失败"))
        await onEvent(.assistantCompleted(message))
        return [message]
    }
}
#endif
