#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
enum MainWindowChromeRegression {
    private static var started = false
    private static weak var sidebar: NSView?
    private static weak var composer: NSView?
    private static weak var footer: NSView?
    private static weak var connection: NSView?
    enum Surface { case sidebar, composer, footer, connection }
    struct SurfaceBounds: NSViewRepresentable {
        let surface: Surface
        init(_ surface: Surface) { self.surface = surface }
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            updateNSView(view, context: context)
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {
            switch surface {
            case .sidebar: MainWindowChromeRegression.sidebar = view
            case .composer: MainWindowChromeRegression.composer = view
            case .footer: MainWindowChromeRegression.footer = view
            case .connection: MainWindowChromeRegression.connection = view
            }
        }
    }
    final class LibraryHeaderView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    struct LibraryHeaderBounds: NSViewRepresentable {
        func makeNSView(context: Context) -> LibraryHeaderView { LibraryHeaderView() }
        func updateNSView(_ view: LibraryHeaderView, context: Context) {}
    }
    static func schedule(store: SlotStoreObservable, canvas: CanvasStore,
                         mode: @escaping () -> WorkspaceMode,
                         request: @escaping (WorkspaceMode) -> Void,
                         ready: @escaping () -> Bool,
                         expanded: @escaping () -> Bool,
                         toggleExpanded: @escaping () -> Void) {
        if ProcessInfo.processInfo.environment["CLIPSLOTS_LIBRARY_DESIGN_PROBE"] == "1",
           !started,
           let path = ProcessInfo.processInfo.environment["CLIPSLOTS_FIXTURE_DIR"],
           ProcessInfo.processInfo.environment["CLIPSLOTS_DATA_DIR"]?.hasPrefix("/tmp/") == true {
            started = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                await runLibraryDesignProbe(directory: URL(fileURLWithPath: path), store: store, canvas: canvas)
            }
            return
        }
        guard !started, ProcessInfo.processInfo.environment["CLIPSLOTS_WINDOW_CHROME_PROBE"] == "1",
              let path = ProcessInfo.processInfo.environment["CLIPSLOTS_FIXTURE_DIR"],
              ProcessInfo.processInfo.environment["CLIPSLOTS_DATA_DIR"]?.hasPrefix("/tmp/") == true else { return }
        started = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            await run(directory: URL(fileURLWithPath: path), store: store, canvas: canvas,
                      mode: mode, request: request, ready: ready, expanded: expanded,
                      toggleExpanded: toggleExpanded)
        }
    }

    private static func run(directory: URL, store: SlotStoreObservable, canvas: CanvasStore,
                            mode: @escaping () -> WorkspaceMode,
                            request: @escaping (WorkspaceMode) -> Void,
                            ready: @escaping () -> Bool,
                            expanded: @escaping () -> Bool,
                            toggleExpanded: @escaping () -> Void) async {
        var passed = 0, failures: [String] = [], observations: [[String: Any]] = []
        func check(_ value: Bool, _ title: String) {
            if value { passed += 1 } else { failures.append(title) }
            NSLog("[WindowChrome] \(value ? "PASS" : "FAIL") \(title)")
        }
        func pause(_ seconds: Double = 0.3) async { try? await Task.sleep(for: .seconds(seconds)) }
        func wait(_ value: () -> Bool) async -> Bool {
            for _ in 0..<300 {
                if value() { return true }
                await pause(0.03)
            }
            return value()
        }
        func views<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
            (root as? T).map { [$0] } ?? root.subviews.flatMap { views($0, type) }
        }
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }),
              let root = window.contentView else { return }
        func libraryHeader() -> NSView? {
            views(root, LibraryHeaderView.self).first { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
        }
        func capture(_ name: String) {
            guard let image = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
        func checkCanvasHeader(_ stage: String) {
            let buttons = views(root, CanvasHeaderButtonProbeView.self)
                .filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
                .map { $0.convert($0.bounds, to: root) }.sorted { $0.minX < $1.minX }
            check(buttons.count == 4, "\(stage) mounts connection appearance Agent and batch header controls")
            guard buttons.count == 4 else { return }
            check(buttons.allSatisfy { abs($0.height - 40) < 0.5 },
                  "\(stage) canvas header controls share 40pt height")
            check(buttons.prefix(3).allSatisfy { abs($0.width - 44) < 0.5 },
                  "\(stage) canvas header icons share 44pt targets")
            check(buttons.allSatisfy { abs(top($0) - top(buttons[0])) < 0.5 },
                  "\(stage) canvas header controls align on the same baseline")
            check(zip(buttons, buttons.dropFirst()).allSatisfy { abs($1.minX - $0.maxX - 8) < 0.5 },
                  "\(stage) canvas header has consistent 8pt gaps")
            let sidebarRect = sidebar.map { $0.convert($0.bounds, to: root) }
            let libraryRight: CGFloat = canvas.isLibraryExpanded ? 240 : 0
            check(buttons.first!.minX >= libraryRight
                && buttons.last!.maxX <= (sidebarRect?.minX ?? root.bounds.maxX) + 0.5,
                  "\(stage) canvas header stays outside both sidebars")
            observations.append(["stage": stage, "canvasHeader": buttons.map(NSStringFromRect)])
        }
        func top(_ rect: CGRect) -> CGFloat { root.isFlipped ? rect.minY : root.bounds.maxY - rect.maxY }
        func strip(_ name: String, xs: [CGFloat]) -> Double {
            let rect = CGRect(x: 0, y: root.isFlipped ? 0 : root.bounds.maxY - 64,
                              width: root.bounds.width, height: 64)
            guard let image = root.bitmapImageRepForCachingDisplay(in: rect) else { return 1 }
            root.cacheDisplay(in: rect, to: image)
            if !name.isEmpty {
                try? image.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent(name + ".png"))
            }
            let scale = CGFloat(image.pixelsWide) / rect.width
            // Compare pixels from the same capture. Device RGB and sRGB conversions
            // differ on dark grays; an unrelated color swatch is not a stripe reference.
            guard let reference = image.colorAt(x: Int(5 * scale), y: Int(60 * scale))?
                .usingColorSpace(.sRGB) else { return 1 }
            var error = 0.0
            for x in xs {
                for y: CGFloat in [4, 12, 24] {
                    guard let color = image.colorAt(x: Int(x * scale), y: Int(y * scale))?
                        .usingColorSpace(.sRGB) else { return 1 }
                    error = max(error, Double(abs(color.redComponent - reference.redComponent)),
                                Double(abs(color.greenComponent - reference.greenComponent)),
                                Double(abs(color.blueComponent - reference.blueComponent)))
                }
            }
            return error
        }
        window.setContentSize(CGSize(width: 1280, height: 720))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        UserDefaults.standard.set(true, forKey: AgentPreferences.sharedSidebarVisibleKey)
        let frame = window.frame
        canvas.isLibraryExpanded = true
        let shared = AgentSessionStore.shared.sidebarSession(canvas: canvas, store: store)
        shared.draft = "编辑与画布共用草稿🙂"
        let sharedID = shared.selectedConversationID
        await runHeaderMascotProbe(root: root, directory: directory, check: check)
        // Switching commits the focused native IME buffer. Wait until the test's
        // model change has reached that editor before asking it to commit.
        check(await wait {
            shared.draft == "编辑与画布共用草稿🙂"
                && views(root, AgentDraftEditor.Editor.self).contains { $0.string == "编辑与画布共用草稿🙂" }
        }, "initial shared draft reaches the mounted native editor")
        func observe(_ stage: String) {
            observations.append(["stage": stage, "frame": NSStringFromRect(window.frame),
                "expectedFrame": NSStringFromRect(frame), "transparent": window.titlebarAppearsTransparent,
                "titleHidden": window.titleVisibility == .hidden, "isZoomed": window.isZoomed])
        }
        for cycle in 0..<3 {
            for target: WorkspaceMode in [.canvas, .edit] {
                request(target)
                var loadingFrames = 0, loadingGeometryOK = true, loadingPixelError = 0.0
                var loadingRectangles: [[String: String]] = []
                for index in 0..<240 {
                    guard let loading = views(root, WorkspaceLoadingView.self).first,
                          loading.layer?.opacity == 1 else {
                        if ready() { break }
                        await pause(0.025)
                        continue
                    }
                    let rect = loading.convert(loading.bounds, to: root)
                    if index < 12 {
                        loadingRectangles.append(["loading": NSStringFromRect(rect),
                                                  "root": NSStringFromRect(root.bounds)])
                    }
                    loadingGeometryOK = loadingGeometryOK && abs(top(rect)) < 0.5
                        && abs(rect.width - root.bounds.width) < 0.5
                        && abs(rect.height - root.bounds.height) < 0.5
                    loadingPixelError = max(loadingPixelError, strip(
                        index < 12 ? "top-loading-\(cycle)-\(target.rawValue)-\(index)" : "",
                        xs: [120, 200, 300, 900, 1180]))
                    loadingFrames += 1
                    await pause(0.025)
                    if ready() { break }
                }
                check(loadingFrames > 0, "\(cycle) \(target.rawValue) samples live workspace transition")
                check(loadingGeometryOK, "\(cycle) \(target.rawValue) loading covers native top safe area")
                check(loadingPixelError < 1.0 / 255,
                      "\(cycle) \(target.rawValue) transition pixels have no titlebar stripe")
                observations.append(["stage": "\(cycle) \(target.rawValue) loading",
                    "sampledFrames": loadingFrames, "maxPixelChannelError": loadingPixelError,
                    "fullWindowGeometry": loadingGeometryOK, "rectangles": loadingRectangles])
                check(await wait { mode() == target && ready() }, "\(cycle) \(target.rawValue) workspace settles")
                await pause()
                observe("\(cycle) \(target.rawValue) settled")
                if let loading = views(root, WorkspaceLoadingView.self).first {
                    let rect = loading.convert(loading.bounds, to: root)
                    check(abs(top(rect)) < 0.5 && abs(rect.height - root.bounds.height) < 0.5,
                          "\(cycle) \(target.rawValue) content occupies the full window height")
                } else { check(false, "loading surface remains mounted") }
                let pixelError = strip("top-settled-\(cycle)-\(target.rawValue)",
                                       xs: target == .canvas ? [80] : [8])
                check(pixelError < 1.0 / 255, "\(cycle) \(target.rawValue) settled top pixels match workspace surface")
                if target == .canvas, let header = libraryHeader() {
                    check(abs(top(header.convert(header.bounds, to: root))) < 0.5,
                          "\(cycle) library header has zero vertical titlebar reservation")
                }
                check(window.styleMask.contains(.fullSizeContentView),
                      "\(cycle) \(target.rawValue) fills native titlebar area")
                check(window.titlebarAppearsTransparent && window.titleVisibility == .hidden,
                      "\(cycle) \(target.rawValue) has transparent unnamed chrome")
                check(window.frame == frame, "\(cycle) \(target.rawValue) switch preserves window frame")
                if let sidebar, let composer {
                    let side = sidebar.convert(sidebar.bounds, to: root)
                    let input = composer.convert(composer.bounds, to: root)
                    check(abs(top(side) + side.height - root.bounds.height) < 1,
                          "\(cycle) \(target.rawValue) Agent reaches native bottom edge")
                    check(abs(side.maxX - root.bounds.maxX) < 1
                        && input.minX >= side.minX - 1 && input.maxX <= side.maxX + 1,
                          "\(cycle) \(target.rawValue) composer remains inside right sidebar")
                    if target == .edit, let footer, let connection {
                        let bar = footer.convert(footer.bounds, to: root)
                        let entry = connection.convert(connection.bounds, to: root)
                        check(bar.maxX <= side.minX + 1, "edit footer stops before Agent")
                        check(top(entry) < 200 && entry.maxX <= side.minX + 1,
                              "connection entry is in the edit action row")
                    }
                } else { check(false, "sidebar and composer bounds remain mounted") }
                let current = AgentSessionStore.shared.sidebarSession(canvas: canvas, store: store)
                check(current === shared && current.selectedConversationID == sharedID
                    && current.draft == "编辑与画布共用草稿🙂",
                    "\(cycle) \(target.rawValue) switch retains shared draft and conversation")
                check(views(root, AgentDraftEditor.Editor.self).contains {
                    $0.string == "编辑与画布共用草稿🙂"
                }, "\(cycle) \(target.rawValue) native composer displays the same draft")
                if let host = views(root, MainWindowDragRegion.Host.self).first {
                    func parentPoint(_ local: CGPoint) -> CGPoint { host.convert(local, to: host.superview) }
                    check(host.hitTest(parentPoint(CGPoint(x: 30, y: 14))) == nil
                        && host.hitTest(parentPoint(CGPoint(x: host.bounds.midX, y: 14))) == nil,
                        "\(target.rawValue) traffic lights and workspace switch keep their pointer ownership")
                    if target == .canvas {
                        check(host.hitTest(parentPoint(CGPoint(x: 220, y: 14))) == nil,
                              "library collapse retains pointer ownership at the top edge")
                    }
                    let point = CGPoint(x: max(180, host.leadingControlsWidth + 32), y: 14)
                    check(host.hitTest(parentPoint(point)) === host, "\(target.rawValue) top blank owns window gestures")
                    let location = host.convert(point, to: nil)
                    let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                        clickCount: 2, pressure: 1)!
                    host.mouseDown(with: event)
                    await pause()
                    observe("\(cycle) \(target.rawValue) zoomed")
                    check(window.frame != frame, "\(target.rawValue) double click zooms the native window")
                    host.mouseDown(with: event)
                    await pause()
                    observe("\(cycle) \(target.rawValue) restored")
                    check(window.frame == frame, "\(target.rawValue) second double click restores native size")
                } else { check(false, "\(target.rawValue) native drag region is mounted") }
                if cycle == 0 {
                    if target == .canvas { checkCanvasHeader("wide") }
                    capture("chrome-" + target.rawValue)
                }
            }
        }
        request(.canvas)
        _ = await wait { mode() == .canvas && ready() }
        await pause()
        canvas.isLibraryExpanded = false
        await pause()
        if let header = libraryHeader() {
            let rect = header.convert(header.bounds, to: root)
            check(top(rect) >= 28 && rect.width <= 40 && rect.height <= 36,
                  "collapsed library is a compact control below native traffic lights")
            check(CanvasSlotLibraryPanel.width(expanded: false) == 0,
                  "collapsed library reserves no full-height rail")
            let point = CGPoint(x: rect.maxX - 12, y: rect.midY)
            let overlaps = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].contains { kind in
                guard let button = window.standardWindowButton(kind) else { return false }
                return button.convert(button.bounds, to: root).contains(point)
            }
            check(!overlaps, "collapsed library expander center avoids native traffic lights")
            capture("library-collapsed")
        } else { check(false, "collapsed library header is mounted") }
        canvas.isLibraryExpanded = true
        await pause()
        check(libraryHeader().map { abs($0.convert($0.bounds, to: root).width - 240) < 0.5 } ?? false,
              "library restores expanded width without top reservation")
        window.setContentSize(CGSize(width: 980, height: 720))
        await pause()
        checkCanvasHeader("narrow")
        capture("canvas-header-narrow")
        window.setFrame(frame, display: true)
        await pause()
        let session = AgentSessionStore.shared.canvasSession(canvas: canvas, store: store)
        session.draft = "同一画布会话展开验收"
        let identity = ObjectIdentifier(session), conversation = session.selectedConversationID
        let document = canvas.gatewayDocument()
        let pan = CanvasAgentGroupsProbeBridge.current?.pan
        let zoom = CanvasAgentGroupsProbeBridge.current?.zoom
        func editorWidth() -> CGFloat {
            views(root, AgentDraftEditor.Editor.self).map { $0.convert($0.bounds, to: root).width }.max() ?? 0
        }
        let narrow = editorWidth()
        toggleExpanded()
        check(await wait { expanded() && editorWidth() > narrow + 100 }, "Agent expands across the same workspace")
        let full = AgentSessionStore.shared.canvasSession(canvas: canvas, store: store)
        check(ObjectIdentifier(full) == identity && full.selectedConversationID == conversation
            && full.draft == "同一画布会话展开验收", "Agent full view retains session identity conversation and draft")
        var afterExpansion = canvas.gatewayDocument()
        // gatewayDocument constructs a new serialization timestamp even without a mutation.
        afterExpansion.updatedAt = document.updatedAt
        check(afterExpansion == document, "Agent expansion preserves the live canvas document")
        capture("agent-expanded")
        toggleExpanded()
        check(await wait { !expanded() && abs(editorWidth() - narrow) < 3 }, "Agent restores original sidebar width")
        check(CanvasAgentGroupsProbeBridge.current?.pan == pan && CanvasAgentGroupsProbeBridge.current?.zoom == zoom,
              "Agent collapse preserves canvas pan and zoom")
        check(session.draft == "同一画布会话展开验收", "Agent collapse preserves unsent input")
        capture("agent-restored")
        await runAgentHandoffDesignProbe(directory: directory, check: check)
        let report: [String: Any] = ["passed": passed, "failures": failures, "observations": observations,
            "scope": "actual root and library top geometry, rendered top pixels, sampled loading transitions, native window gestures",
            "skin": AppSkinCenter.current.rawValue,
            "appearance": window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "",
            "sessionLocked": (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}
#endif
