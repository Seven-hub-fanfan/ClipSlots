#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit

@MainActor
enum UIRedesignRegression {
    private static var started = false
    static func schedule(store: SlotStoreObservable, canvas: CanvasStore,
                         request: @escaping (WorkspaceMode) -> Void, ready: @escaping () -> Bool,
                         setAgent: @escaping (Bool) -> Void, agent: @escaping () -> Bool,
                         selection: @escaping () -> String?, results: @escaping () -> [SlotGlobalSearchResult]) {
        let env = ProcessInfo.processInfo.environment
        if let path = env["CLIPSLOTS_SELECTION_MEDIA_REGRESSION"], !SelectionMediaRegression.started {
            guard path.hasPrefix("/private/tmp/clipslots-agent-background-"),
                  env["CLIPSLOTS_DATA_DIR"] == path + "/data",
                  env["CLIPSLOTS_CONFIG_PATH"] == path + "/config.toml",
                  Bundle.main.bundleIdentifier == "com.clipslots.app.agent-onboarding-regression",
                  Bundle.main.object(forInfoDictionaryKey: "ClipSlotsIsolatedCandidate") as? Bool == true else { exit(2) }
            SelectionMediaRegression.started = true
            Task {
                try? await Task.sleep(for: .seconds(1))
                request(.canvas)
                for _ in 0..<200 {
                    if ready(), let view = SelectionMediaRegression.current {
                        await view.runSelectionMediaProbe(directory: URL(fileURLWithPath: path))
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                exit(3)
            }
            return
        }
        guard !started, let path = env["CLIPSLOTS_UI_REDESIGN_REGRESSION"] else { return }
        guard path.hasPrefix("/private/tmp/clipslots-agent-background-"),
              env["CLIPSLOTS_DATA_DIR"] == path + "/data",
              env["CLIPSLOTS_CONFIG_PATH"] == path + "/config.toml",
              Bundle.main.bundleIdentifier == "com.clipslots.app.agent-onboarding-regression",
              Bundle.main.object(forInfoDictionaryKey: "ClipSlotsIsolatedCandidate") as? Bool == true else { exit(2) }
        started = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            await run(root: URL(fileURLWithPath: path), store: store, canvas: canvas, request: request,
                      ready: ready, setAgent: setAgent, agent: agent, selection: selection, results: results)
        }
    }

    private static func run(root: URL, store: SlotStoreObservable, canvas: CanvasStore,
                            request: (WorkspaceMode) -> Void, ready: () -> Bool,
                            setAgent: (Bool) -> Void, agent: () -> Bool,
                            selection: () -> String?, results: () -> [SlotGlobalSearchResult]) async {
        var passes = 0, failures: [String] = [], diagnostics: [[String: Any]] = []
        func check(_ condition: Bool, _ label: String) {
            if condition { passes += 1 } else { failures.append(label) }
            print("\(condition ? "PASS" : "FAIL") \(label)"); fflush(stdout)
        }
        func settle(_ seconds: Double = 0.22) async { try? await Task.sleep(for: .seconds(seconds)) }
        func wait(_ condition: () -> Bool) async {
            for _ in 0..<200 { if condition() { return }; await settle(0.025) }
        }
        NativeAccessibilityProbe.enable()
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }),
              let view = window.contentView else { exit(3) }
        func nodes(_ parent: NSView? = nil) -> [AnyObject] { NativeAccessibilityProbe.elements(parent ?? view) }
        func element(_ id: String, in parent: NSView? = nil) -> AnyObject? {
            nodes(parent).first { $0.accessibilityIdentifier?() == id }
        }
        @discardableResult func press(_ id: String, in parent: NSView? = nil) -> Bool {
            element(id, in: parent)?.accessibilityPerformPress?() ?? false
        }
        func capture(_ name: String, _ parent: NSView? = nil) {
            let host = parent ?? view
            host.layoutSubtreeIfNeeded()
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                check(false, "\(name) snapshot"); return
            }
            host.cacheDisplay(in: host.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(name + ".png"))
        }
        func frame(_ id: String) -> CGRect { element(id)?.accessibilityFrame?() ?? .zero }
        func click(_ id: String) async {
            let rect = frame(id)
            guard !rect.isEmpty else { return }
            window.makeKeyAndOrderFront(nil)
            let point = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
            for type: NSEvent.EventType in [.mouseMoved, .leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1) { NSApp.postEvent(event, atStart: false) }
                await settle(0.1)
            }
        }
        func theme(_ dark: Bool) {
            UserDefaults.standard.set((dark ? ThemeMode.dark : .light).rawValue, forKey: AppearanceDefaults.key)
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
        AppSkinCenter.apply(.minimal)
        setAgent(false)
        window.setContentSize(CGSize(width: 1180, height: 740))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let group = store.currentSpecialSlotId
        for (index, text) in ["镜头 · 雨后小巷", "镜头 · 城市日落", "镜头 · 海边清晨"].enumerated() {
            check(store.specialStorage.set(index + 1, content: SlotContent(text: text + "\n保持自然光影与真实材质。"), in: group),
                  "isolated search fixture \(index)")
        }
        store.reloadAll()
        await settle(0.5)
        for dark in [false, true] {
            theme(dark); await settle()
            let label = dark ? "深色" : "浅色"
            capture("编辑界面-\(label)")
            try? nodes().map { "\($0.accessibilityIdentifier?() ?? "-") | \($0.accessibilityRole?()?.rawValue ?? "-") | \($0.accessibilityLabel?() ?? "-")" }
                .joined(separator: "\n").write(to: root.appendingPathComponent("editor-ax.txt"), atomically: true, encoding: .utf8)
            let ids = ["editor-auto-advance", "slot-connection-entry", "editor-action-打包", "editor-action-导入", "editor-action-清空"]
            let rects = ids.map(frame)
            check(rects.allSatisfy { abs($0.height - 32) < 1 }, "\(label) actions all 32pt")
            check(rects.allSatisfy { abs($0.midY - rects[0].midY) < 1 }, "\(label) actions share baseline")
            check(zip(rects, rects.dropFirst()).allSatisfy { $0.maxX <= $1.minX }, "\(label) actions never overlap")
            check(abs(frame("workspace-agent-orb").width - 44) < 1, "\(label) editor orb 44pt")
            check(press("workspace-agent-orb"), "\(label) editor orb responds")
            await settle()
            check(agent(), "\(label) orb opens sidebar")
            check(press("workspace-agent-orb"), "\(label) editor orb closes")
            await settle()
            check(!agent(), "\(label) sidebar closes")
            await click("workspace-agent-orb"); await settle()
            check(agent(), "\(label) pointer opens editor Agent")
            await click("workspace-agent-orb"); await settle()
            check(!agent(), "\(label) pointer closes editor Agent")
            store.setSettingsOverlay(true); await settle()
            for category in SettingsCategory.allCases {
                check(press("settings-category-\(category.rawValue)"), "\(label) settings \(category.rawValue) navigable")
                await settle(0.1)
                if [.appearance, .slot, .shortcut, .permission].contains(category) {
                    capture("设置-\(category.rawValue)-\(label)")
                }
            }
            _ = press("settings-category-slot"); await settle()
            let savedSlots = store.config.slots
            check(press("settings-slot-count-7"), "\(label) slot selector interactive")
            check(press("settings-cancel"), "\(label) settings cancel")
            await settle()
            check(store.config.slots == savedSlots && !store.transientUI.isSettingsOverlayPresented,
                  "\(label) cancel keeps slot config")
        }
        theme(false); await settle()
        func fields(_ parent: NSView) -> [NSTextField] {
            (parent as? NSTextField).map { [$0] } ?? parent.subviews.flatMap(fields)
        }
        if let input = fields(view).first(where: { $0.accessibilityIdentifier() == "slot-search-field" }),
           let delegate = input.delegate as? SearchInputField.Coordinator {
            // Put the pointer over the input before results mount. The previous
            // settings-button location can otherwise hover-select a result.
            await click("slot-search-field")
            window.makeFirstResponder(input)
            input.stringValue = "镜头"
            delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
            await wait { results().count == 3 }
            check(results().count == 3, "global search finds all isolated slots")
            await settle()
            capture("搜索界面-浅色")
            diagnostics.append(["phase": "before-search-keys", "selected": selection() ?? "",
                "resultIDs": results().map(\.id),
                "mouseX": window.mouseLocationOutsideOfEventStream.x,
                "mouseY": window.mouseLocationOutsideOfEventStream.y])
            let editor = input.currentEditor() as? NSTextView ?? NSTextView()
            check(delegate.control(input, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))),
                  "search down handled with text focus")
            await settle()
            check(selection() == results().first?.id, "down selects first result")
            _ = delegate.control(input, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
            await settle()
            check(results().count > 1 && selection() == results()[1].id, "down advances selection")
            _ = delegate.control(input, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
            await settle()
            check(selection() == results().first?.id, "up restores first result")
            theme(true); await settle(); capture("搜索界面-深色")
            let target = results().first
            _ = delegate.control(input, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            await settle()
            check(target?.groupId == store.currentSpecialSlotId &&
                  target?.slot == store.flashHighlightSlot?.slot, "return reveals and highlights exact slot")
            input.stringValue = "清除测试"
            delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
            _ = delegate.control(input, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            await settle()
            check(input.stringValue.isEmpty, "escape clears search")
        } else { check(false, "native search field mounted") }
        window.makeFirstResponder(nil)
        request(.canvas); await settle(0.5); await wait(ready); await settle()
        for dark in [false, true] {
            theme(dark); await settle()
            for width: CGFloat in [1180, 800] {
                setAgent(width == 800)
                window.setContentSize(CGSize(width: width, height: 740)); await settle()
                let label = "\(dark ? "深色" : "浅色")-\(Int(width))"
                check(element("canvas-agent-toggle") == nil, "\(label) old canvas Agent entry removed")
                check(element("canvas-save-status") == nil && element("canvas-help") == nil,
                      "\(label) removed canvas entries absent")
                let orb = frame("workspace-agent-orb")
                let tools = ["canvas-tool-select", "canvas-tool-hand", "canvas-tool-pickSlot", "canvas-tool-history"].map(frame)
                check(orb.width == 44 && tools.allSatisfy { $0.height == 32 && !$0.intersects(orb) },
                      "\(label) canvas tools avoid fixed orb")
                let map = frame("canvas-minimap")
                check(map.isEmpty || tools.allSatisfy { !$0.intersects(map) }, "\(label) minimap never covers toolbar")
                let previousAgent = agent()
                _ = press("workspace-agent-orb"); await settle()
                check(agent() != previousAgent, "\(label) accessible canvas Agent toggles")
                setAgent(previousAgent); await settle()
                await click("workspace-agent-orb"); await settle()
                check(agent() != previousAgent, "\(label) pointer toggles canvas Agent")
                setAgent(previousAgent); await settle()
                check(press("canvas-tool-hand"), "\(label) hand responds"); await settle(0.08)
                check(canvas.activeTool == .hand, "\(label) hand mode selected")
                check(press("canvas-tool-select"), "\(label) select responds"); await settle(0.08)
                check(canvas.activeTool == .select, "\(label) select mode restored")
                check(press("canvas-tool-history"), "\(label) history opens"); await settle(0.08)
                _ = press("canvas-tool-history")
                window.makeKeyAndOrderFront(nil)
                await settle()
                capture("画布-\(label)")
                diagnostics.append(["stage": label, "orb": NSStringFromRect(orb), "tools": tools.map(NSStringFromRect),
                                    "actualWindowWidth": view.bounds.width, "sidebarOpen": agent()])
            }
        }
        setAgent(false)
        // The permission panel uses a backend with no system calls.
        let permissions = PermissionCenterModel(backend: PermissionBackend(preflight: { _ in false },
            requestScreenCapture: {}, openSettings: { _ in true }, reset: { _ in }))
        var authorized: [AppPermission] = []
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: PermissionCenter.cardSize),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PermissionCenterCard(model: permissions, onClose: {},
                                                                onAuthorize: { authorized.append($0) }))
        panel.contentView = host
        panel.orderFront(nil)
        for dark in [false, true] {
            theme(dark); await settle()
            check(element("permission-repair-accessibility", in: host) == nil, "permission inline repair removed")
            check(press("permission-authorize-accessibility", in: host), "permission authorize responds")
            check(press("permission-authorize-screenCapture", in: host), "screen authorization responds")
            check(element("permission-refresh", in: host) != nil, "permission refresh remains reachable")
            capture("权限面板-\(dark ? "深色" : "浅色")", host)
        }
        check(authorized.count == 4, "permission buttons keep original callbacks")
        panel.orderOut(nil)
        let compactWindow = NSPanel(contentRect: CGRect(x: 80, y: 100, width: 720, height: 580),
                                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        compactWindow.isReleasedWhenClosed = false
        var savedConfig: AppConfig?
        let settingsHost = NSHostingView(rootView: SettingsView(config: store.config, onSave: { savedConfig = $0 },
                                                                onClose: {}))
        compactWindow.contentView = settingsHost
        compactWindow.makeKeyAndOrderFront(nil)
        await settle()
        _ = press("settings-category-slot", in: settingsHost); await settle()
        check(press("settings-slot-count-6", in: settingsHost), "compact settings selects slot count")
        check(press("settings-save", in: settingsHost), "compact settings save responds")
        check(savedConfig?.slots == 6, "settings save returns changed configuration")
        capture("设置-窄窗口", settingsHost)
        let searchState = SearchFixture()
        let searchHost = NSHostingView(rootView: SearchFixtureView(state: searchState))
        compactWindow.contentView = searchHost
        compactWindow.setContentSize(CGSize(width: 510, height: 360))
        await settle()
        searchState.selected = searchState.results[270].id
        await settle(0.4)
        check(element("global-search-result-\(searchState.results[270].id)", in: searchHost) != nil,
              "keyboard selection mounts and scrolls beyond first result page")
        capture("搜索-窄窗口-分页", searchHost)
        compactWindow.orderOut(nil)
        let report: [String: Any] = ["passed": failures.isEmpty, "passes": passes, "failures": failures,
                                     "diagnostics": diagnostics, "fixture_only": true]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("ui-regression.json"))
        exit(failures.isEmpty ? 0 : 1)
    }

    private final class SearchFixture: ObservableObject {
        let selection = SearchResultSelection()
        var selected: String? {
            get { selection.id }
            set { selection.id = newValue }
        }
        @Published var sort: SlotSearchSortRule = .smart
        let results = (1...300).map {
            SlotGlobalSearchResult(pageId: "p", pageName: "创作素材", groupId: "group-\($0 / 10)",
                groupName: "镜头参考", slot: $0 % 10 + 1,
                content: SlotContent(text: "镜头 \($0) · 保持自然光影与空间层次"), label: "",
                pageOrder: 0, groupOrder: $0 / 10)
        }
    }
    private struct SearchFixtureView: View {
        @ObservedObject var state: SearchFixture
        var body: some View {
            GlobalSearchResultsView(results: state.results, currentPageId: "p", currentGroupId: "",
                onJump: { _ in }, sortRule: $state.sort, selectionModel: state.selection)
                .padding(12)
        }
    }
}
#endif
