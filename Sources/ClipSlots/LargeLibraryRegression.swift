#if DEBUG
import AppKit
import SwiftUI
import Combine
import Vision
import ClipSlotsKit

@MainActor
enum LargeLibraryRegression {
    static func run(directory: URL, store: SlotStoreObservable, canvas: CanvasStore,
                    request: @escaping (WorkspaceMode) -> Void,
                    ready: @escaping () -> Bool) async {
        NativeAccessibilityProbe.enable()
        AgentModelCatalogStore.debugCredentials = { endpoint, _ in
            guard endpoint.host == "127.0.0.1" else { throw AgentOperationError("Expected isolated model service") }
            return "fixture"
        }
        defer { AgentModelCatalogStore.debugCredentials = nil }
        let environment = ProcessInfo.processInfo.environment
        let requestedSkin = AppSkin.minimal
        let requestedAppearance = ThemeMode(rawValue: environment["CLIPSLOTS_TEST_APPEARANCE"] ?? "light") ?? .light
        AppSkinCenter.apply(requestedSkin)
        UserDefaults.standard.set(requestedAppearance.rawValue, forKey: AppearanceDefaults.key)
        NSApp.appearance = requestedAppearance.nsAppearance
        var checks: [String: Bool] = [:]
        var measurements: [[String: Any]] = []
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }),
              let root = window.contentView else { return }
        window.setContentSize(CGSize(width: 1280, height: 720))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        UserDefaults.standard.set(true, forKey: AgentPreferences.sharedSidebarVisibleKey)
        var compositor: OwnWindowCompositorProbe?
        func pause(_ ms: Int = 200) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func residentBytes() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return status == KERN_SUCCESS ? info.resident_size : 0
        }
        func until(_ condition: () -> Bool) async -> Bool {
            let start = ProcessInfo.processInfo.systemUptime
            while !condition(), ProcessInfo.processInfo.systemUptime - start < 12 { await pause(10) }
            return condition()
        }
        func check(_ condition: Bool, _ title: String) {
            checks[title] = condition
            NSLog("[LargeLibrary] \(condition ? "PASS" : "FAIL") \(title)")
        }
        func all() -> [AnyObject] { NativeAccessibilityProbe.elements(root) }
        func identifier(_ name: String) -> AnyObject? {
            all().first { $0.accessibilityIdentifier?() == name }
        }
        func capture(_ name: String, view: NSView? = nil) {
            let target = view ?? root
            guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
            target.cacheDisplay(in: target.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
        func measure(_ name: String, action: () -> Void, completed: () -> Bool,
                     seconds: Double = 0.6, expectedText: String? = nil) async {
            compositor?.begin(region: expectedText == nil
                ? CGRect(x: 0, y: 190, width: 820, height: 470)
                : CGRect(x: 20, y: 210, width: 285, height: 330),
                retainImages: expectedText != nil)
            var gaps: [Double] = []
            var last = ProcessInfo.processInfo.systemUptime
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(8))
                    let now = ProcessInfo.processInfo.systemUptime
                    gaps.append((now - last) * 1000)
                    last = now
                }
            }
            await pause(20)
            let displayStart = compositor?.now ?? 0
            let start = ProcessInfo.processInfo.systemUptime
            action()
            let handling = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let settled = await until(completed)
            let content = (ProcessInfo.processInfo.systemUptime - start) * 1000
            try? await Task.sleep(for: .seconds(seconds))
            ticker.cancel()
            let ordered = gaps.sorted()
            var value: [String: Any] = ["scenario": name, "handlerMS": handling,
                "contentReadyMS": content, "maxMainGapMS": ordered.last ?? 0,
                "p95MainGapMS": ordered.isEmpty ? 0 : ordered[Int(Double(ordered.count - 1) * 0.95)],
                "gapsOver16_7MS": gaps.filter { $0 > 16.7 }.count,
                "gapsOver50MS": gaps.filter { $0 > 50 }.count,
                "samples": gaps.count, "settled": settled]
            if let compositor {
                let display = await compositor.report(since: displayStart, until: compositor.now,
                    expectedText: expectedText, directory: directory, name: name)
                value["compositor"] = display
                if expectedText != nil {
                    check(display["contentVerified"] as? Bool == true, name + " content visible in compositor pixels")
                }
            }
            measurements.append(value)
            NSLog("[LargeLibrary] %@", String(data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(),
                                              encoding: .utf8) ?? "")
            check(settled, name + " settles")
        }
        request(.edit)
        check(await until(ready), "edit initial surface ready")
        await pause(600)
        check(AppSkinCenter.current == requestedSkin, "requested skin applied")
        check((window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
              == (requestedAppearance == .dark), "requested native appearance applied")
        if environment["CLIPSLOTS_COMPOSITOR_PROBE"] == "1" {
            if #available(macOS 14.4, *) {
                compositor = try? await OwnWindowCompositorProbe.start(window: window)
            }
            check(compositor != nil, "own-window compositor capture starts without permission request")
        }
        let modelOnly = ProcessInfo.processInfo.environment["CLIPSLOTS_MODEL_ONLY_PROBE"] == "1"
        if !modelOnly {
        for round in 0..<2 {
            for group in store.specialSlots.prefix(5) {
                if group.id == store.currentSpecialSlotId { continue }
                await measure("edit-group-\(round)-\(group.id)", action: {
                    store.switchSpecialSlot(id: group.id, fromNavigation: true)
                }, completed: {
                    store.currentSpecialSlotId == group.id
                        && store.slots[1]?.plainText?.hasPrefix("workload \(group.id) ") == true
                        && !store.isSwitchingGroup
                }, expectedText: "workload \(group.id)")
            }
            for page in store.pages.prefix(4) {
                let first = store.specialSlots.filter { $0.pageId == page.id }.min { $0.order < $1.order }?.id ?? ""
                await measure("edit-page-\(round)-\(page.id)", action: {
                    store.switchToPage(id: page.id, fromNavigation: true)
                }, completed: {
                    store.currentPageId == page.id
                        && store.slots[1]?.plainText?.hasPrefix("workload \(first) ") == true
                        && !store.isSwitchingGroup
                }, expectedText: "workload \(first)")
            }
        }
        for target: WorkspaceMode in [.canvas, .edit, .canvas] {
            await measure("workspace-\(target.rawValue)", action: { request(target) }, completed: ready, seconds: 0.8)
        }
        canvas.isLibraryExpanded = true
        await pause(400)
        func scrolls(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
        }
        if let scroll = scrolls(root).first(where: {
            $0.convert($0.bounds, to: root).minX < 50 && $0.bounds.width < 300 && $0.bounds.height > 200
        }) {
            let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
            for fraction: CGFloat in [0.25, 0.5, 0.75, 1, 0] {
                await measure("canvas-library-scroll-\(fraction)", action: {
                    scroll.contentView.scroll(to: CGPoint(x: 0, y: maxY * fraction))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                    root.layoutSubtreeIfNeeded()
                }, completed: { true }, seconds: 0.3)
            }
            check(maxY > 1000, "large library has real offscreen rows")
            var steps: [Double] = []
            compositor?.begin(region: CGRect(x: 0, y: 110, width: 270, height: 500), retainImages: false)
            await pause(30)
            let displayStart = compositor?.now ?? 0
            for step in 0..<90 {
                let start = ProcessInfo.processInfo.systemUptime
                scroll.contentView.scroll(to: CGPoint(x: 0, y: min(maxY, CGFloat(step) * 18)))
                scroll.reflectScrolledClipView(scroll.contentView)
                root.layoutSubtreeIfNeeded()
                steps.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                await pause(16)
            }
            let sortedSteps = steps.sorted()
            measurements.append(["scenario": "continuous-library-scroll",
                "steps": steps.count, "medianStepMS": sortedSteps[sortedSteps.count / 2],
                "p95StepMS": sortedSteps[Int(Double(sortedSteps.count - 1) * 0.95)],
                "maxStepMS": sortedSteps.last ?? 0,
                "metric": "programmatic scroll and layout CPU time; not presented frame rate"])
            if let compositor {
                let display = await compositor.report(since: displayStart, until: compositor.now,
                    expectedText: nil, directory: directory, name: "continuous-library-scroll")
                measurements.append(["scenario": "continuous-library-scroll-compositor", "compositor": display])
                check((display["changedPixelSamples"] as? Int ?? 0) > 20,
                      "continuous library scroll changes actual compositor pixels")
            }
            // A separate event-driven workload: send pixel scroll events to our
            // own native scroll view at 60 Hz deadlines, with no forced layout.
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            await pause(200)
            compositor?.begin(region: CGRect(x: 0, y: 110, width: 270, height: 500), retainImages: false)
            await pause(30)
            let eventStart = compositor?.now ?? 0
            let clockStart = ProcessInfo.processInfo.systemUptime
            var eventCosts: [Double] = []
            var lateness: [Double] = []
            for step in 0..<90 {
                let deadline = clockStart + Double(step) / 60
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                let started = ProcessInfo.processInfo.systemUptime
                lateness.append(max(0, started - deadline) * 1000)
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                    wheelCount: 1, wheel1: -18, wheel2: 0, wheel3: 0) {
                    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    if let event = NSEvent(cgEvent: cg) { scroll.scrollWheel(with: event) }
                }
                eventCosts.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            }
            await pause(150)
            let eventSorted = eventCosts.sorted()
            let lateSorted = lateness.sorted()
            measurements.append(["scenario": "native-library-scroll-events",
                "events": eventCosts.count, "displacementY": scroll.contentView.bounds.minY,
                "p95HandlerMS": eventSorted[Int(Double(eventSorted.count - 1) * 0.95)],
                "p95DeadlineLatenessMS": lateSorted[Int(Double(lateSorted.count - 1) * 0.95)],
                "residentBytes": residentBytes(),
                "metric": "own-view scrollWheel dispatch at 60Hz deadlines; not hardware gesture FPS"])
            check(scroll.contentView.bounds.minY > 500, "native scroll events move real library viewport")
            if let compositor {
                let display = await compositor.report(since: eventStart, until: compositor.now,
                    expectedText: nil, directory: directory, name: "native-library-scroll-events")
                measurements.append(["scenario": "native-library-scroll-events-compositor", "compositor": display])
                check((display["changedPixelSamples"] as? Int ?? 0) > 20,
                      "native scroll events change actual compositor pixels")
            }
        } else { check(false, "canvas library scroll surface mounted") }
        // The search scanner is measured independently from UI layout and never
        // evaluated on the main actor. These are local workload fixtures.
        let refs = store.searchableGroupsSnapshot()
        let scanStart = ProcessInfo.processInfo.systemUptime
        let hits = await Task.detached {
            SlotStoreObservable.expandSearchableSlots(refs, query: "workload", filter: .all)
        }.value
        measurements.append(["scenario": "global-search-scan", "groups": refs.count, "hits": hits.count,
            "scanMS": (ProcessInfo.processInfo.systemUptime - scanStart) * 1000, "residentBytes": residentBytes()])
        measurements.append(["scenario": "global-search-stages", "stagesMS": SlotSearchDiagnostics.take()])
        check(!hits.isEmpty, "global scanner finds fixture content")
        let warmStart = ProcessInfo.processInfo.systemUptime
        let warm = await Task.detached {
            SlotStoreObservable.expandSearchableSlots(refs, query: "workload", filter: .all)
        }.value
        measurements.append(["scenario": "global-search-warm", "groups": refs.count, "hits": warm.count,
            "scanMS": (ProcessInfo.processInfo.systemUptime - warmStart) * 1000])
        check(warm.count == hits.count, "warm search preserves all results")
        if let lastGroup = refs.last {
            for query in [lastGroup.groupId, "no_such_keyword_xyz", lastGroup.groupId] {
                let start = ProcessInfo.processInfo.systemUptime
                let selected = await Task.detached {
                    SlotStoreObservable.expandSearchableSlots(refs, query: query, filter: .all)
                }.value
                measurements.append(["scenario": "global-search-selective", "query": query,
                    "hits": selected.count, "scanMS": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                    "residentBytes": residentBytes()])
                check(selected.count == (query == lastGroup.groupId ? lastGroup.slotCount : 0),
                      "selective query preserves expected hits: \(query)")
            }
        }
        let cancelled = Task.detached {
            SlotStoreObservable.expandSearchableSlots(refs, query: "workload", filter: .all,
                                                     isCancelled: { Task.isCancelled })
        }
        cancelled.cancel()
        let cancelStart = ProcessInfo.processInfo.systemUptime
        _ = await cancelled.value
        let cancelMS = (ProcessInfo.processInfo.systemUptime - cancelStart) * 1000
        measurements.append(["scenario": "global-search-cancel", "cancelMS": cancelMS])
        check(cancelMS < 200, "cancelled search releases worker promptly")
        if environment["CLIPSLOTS_GUI_SEARCH_PROBE"] == "1", let lastGroup = refs.last {
            request(.edit)
            _ = await until(ready)
            await pause(400)
            func searchField() -> NSTextField? {
                all().compactMap({ $0 as? NSTextField }).first {
                    $0.placeholderString == "搜索槽位…" && $0.window != nil
                }
            }
            if searchField() != nil {
                for (query, expectedCount) in [("workload", hits.count),
                                              (lastGroup.groupId, lastGroup.slotCount),
                                              ("workload", hits.count), ("no_such_keyword_xyz", 0)] {
                    guard let field = searchField() else {
                        check(false, "GUI query current input exists: \(query)")
                        break
                    }
                    compositor?.begin(region: CGRect(x: 0, y: 100, width: 820, height: 500),
                                      retainImages: true)
                    await pause(30)
                    let displayStart = compositor?.now ?? 0
                    window.makeKey()
                    field.selectText(nil)
                    let start = ProcessInfo.processInfo.systemUptime
                    if let editor = field.currentEditor() as? NSTextView {
                        editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    }
                    let settled = await until {
                        identifier("global-search-count-\(expectedCount)") != nil
                    }
                    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    await pause(250)
                    var result: [String: Any] = ["scenario": "global-search-native-input",
                        "query": query, "expectedHits": expectedCount, "inputToAXResultMS": elapsed,
                        "settled": settled, "residentBytes": residentBytes(),
                        "metric": "actual field edit through debounce, scanner, sort and native result header"]
                    if let compositor {
                        let visibleMarker = expectedCount == 0 ? "全局未找到" : "全局找到 \(expectedCount)"
                        let display = await compositor.report(since: displayStart, until: compositor.now,
                            expectedText: visibleMarker, directory: directory, name: "gui-search-\(query)")
                        result["compositor"] = display
                        check(display["contentVerified"] as? Bool == true, "GUI query pixels show header: \(query)")
                    }
                    measurements.append(result)
                    check(settled, "GUI query returns exact count: \(query)")
                    capture("gui-search-\(query)")
                }
                if let field = searchField() {
                    field.selectText(nil)
                    if let editor = field.currentEditor() as? NSTextView {
                        editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    }
                }
                await pause(300)
            } else { check(false, "native global search input mounted") }
        }
        let searchPanel = NSPanel(contentRect: NSRect(x: 80, y: 120, width: 940, height: 340),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        searchPanel.isReleasedWhenClosed = false
        let searchHost = NSHostingView(rootView: GlobalSearchResultsView(results: hits,
            currentPageId: store.currentPageId, currentGroupId: store.currentSpecialSlotId,
            onJump: { _ in }, sortRule: .constant(.smart), loadPreview: { result in
                await Task.detached {
                    SpecialSlotStorage.shared.get(result.slot, in: result.groupId)
                }.value
            }))
        await measure("global-search-result-mount", action: {
            searchPanel.contentView = searchHost
            searchPanel.orderFront(nil)
            searchHost.layoutSubtreeIfNeeded()
        }, completed: { searchHost.window != nil }, seconds: 0.3)
        if let list = scrolls(searchHost).first {
            let bottom = max(0, (list.documentView?.bounds.height ?? 0) - list.contentView.bounds.height)
            check(bottom > 1000, "search results have real offscreen rows")
            for fraction: CGFloat in [0.5, 1, 0] {
                await measure("global-search-result-scroll", action: {
                    list.contentView.scroll(to: CGPoint(x: 0, y: bottom * fraction))
                    list.reflectScrolledClipView(list.contentView)
                    searchHost.layoutSubtreeIfNeeded()
                }, completed: { true }, seconds: 0.1)
            }
            capture("large-search-results", view: searchHost)
        } else { check(false, "search results scroll surface mounted") }
        searchPanel.orderOut(nil)
        searchPanel.close()
        if ProcessInfo.processInfo.environment["CLIPSLOTS_EXTENDED_LARGE_PROBE"] == "1" {
            request(.edit)
            _ = await until(ready)
            let targets = Array(store.specialSlots.prefix(3))
            if targets.count == 3 {
                func navigationShield(_ view: NSView) -> NSView? {
                    if view.identifier?.rawValue == "slot-navigation-shield" { return view }
                    return view.subviews.lazy.compactMap(navigationShield).first
                }
                var shield: NSView? { navigationShield(root) }
                func gridHit() -> NSView? {
                    guard let shield else { return nil }
                    let visible = shield.visibleRect
                    let point = shield.convert(NSPoint(x: visible.midX, y: visible.midY),
                                               to: root.superview)
                    return root.hitTest(point)
                }
                check(shield != nil && gridHit() !== shield, "idle grid input shield passes clicks through")
                let a = targets[0].id, b = targets[1].id, c = targets[2].id
                let blocker = Task.detached {
                    try? StorageLock.shared.withLock { Thread.sleep(forTimeInterval: 0.35) }
                }
                await pause(40)
                await measure("rapid-navigation-under-lock", action: {
                    for id in [a, b, c, b, a] { store.switchSpecialSlot(id: id, fromNavigation: true) }
                }, completed: {
                    store.currentSpecialSlotId == a && store.displayedSpecialSlotId == a
                        && store.slots[1]?.plainText?.hasPrefix("workload \(a) ") == true
                        && !store.isSwitchingGroup
                })
                _ = await blocker.value
                root.layoutSubtreeIfNeeded()
                check(shield != nil && gridHit() !== shield, "committed navigation restores grid clicks")
                check(SpecialSlotStorage.shared.loadIndex().activeHotkeySpecialSlotId == a,
                      "rapid navigation persists only final hotkey group")
                let clickBlocker = Task.detached {
                    try? StorageLock.shared.withLock { Thread.sleep(forTimeInterval: 0.35) }
                }
                await pause(40)
                store.switchSpecialSlot(id: b, fromNavigation: true)
                await pause(20)
                root.layoutSubtreeIfNeeded()
                measurements.append(["scenario": "navigation-click-shield",
                    "frame": shield.map { NSStringFromRect($0.frame) } ?? "",
                    "visible": shield.map { NSStringFromRect($0.visibleRect) } ?? "",
                    "hitType": gridHit().map { String(describing: type(of: $0)) } ?? "nil"])
                check(store.transientUI.isNavigationPending && shield != nil && gridHit() === shield,
                      "pending navigation intercepts old grid clicks")
                _ = await clickBlocker.value
                _ = await until { !store.transientUI.isNavigationPending }
                store.switchSpecialSlot(id: a, fromNavigation: true)
                _ = await until { !store.transientUI.isNavigationPending && store.currentSpecialSlotId == a }
                let indexURL = ClipSlotsPaths.specialSlots.appendingPathComponent("index.json")
                await Task.detached {
                    try? StorageLock.shared.withLock {
                        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as! [String: Any]
                        var groups = object["specialSlots"] as! [[String: Any]]
                        if let i = groups.firstIndex(where: { $0["id"] as? String == b }) {
                            groups[i]["name"] = "EXTERNAL_INDEX"
                        }
                        object["specialSlots"] = groups
                        try JSONSerialization.data(withJSONObject: object).write(to: indexURL, options: .atomic)
                    }
                }.value
                check(await until { store.specialSlots.first { $0.id == b }?.name == "EXTERNAL_INDEX" },
                      "external index replacement reaches UI")
                let body = ClipSlotsPaths.specialSlots.appendingPathComponent(a)
                    .appendingPathComponent("1/item_0/public.utf8-plain-text.bin")
                await Task.detached { try? Data("EXTERNAL_BODY".utf8).write(to: body, options: .atomic) }.value
                check(await until { store.slots[1]?.plainText == "EXTERNAL_BODY" },
                      "external body-only change reaches UI")
                await pause(100)
                capture("external-body-refresh")
                let bodyImage = directory.appendingPathComponent("external-body-refresh.png")
                let visibleText = await Task.detached {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    try? VNImageRequestHandler(url: bodyImage).perform([request])
                    return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
                }.value
                check(visibleText.contains {
                    $0.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
                        .contains("EXTERNALBODY")
                }, "external body replacement appears in rendered slot card")
                await Task.detached {
                    try? SpecialSlotStorage.shared.renameSpecialSlot(id: b, name: "EXTERNAL_MIXED")
                    try? Data("EXTERNAL_MIXED_BODY".utf8).write(to: body, options: .atomic)
                }.value
                check(await until {
                    store.specialSlots.first { $0.id == b }?.name == "EXTERNAL_MIXED"
                        && store.slots[1]?.plainText == "EXTERNAL_MIXED_BODY"
                }, "mixed index and body event reaches UI")
                store.updateTextSlot(2, text: "QUEUED_EDIT_BEFORE_NAV")
                store.switchSpecialSlot(id: b, fromNavigation: true)
                check(await until { store.displayedSpecialSlotId == b && !store.isSwitchingGroup },
                      "navigation after queued edit settles")
                check(SpecialSlotStorage.shared.get(2, in: a).plainText == "QUEUED_EDIT_BEFORE_NAV",
                      "queued edit remains in original group")
                check(SpecialSlotStorage.shared.get(2, in: b).plainText?.hasPrefix("workload \(b) ") == true,
                      "queued edit does not leak into destination group")
            }
            request(.canvas)
            _ = await until(ready)
            for index in 0..<250 {
                let group = store.specialSlots[index / 10 % store.specialSlots.count]
                _ = canvas.placeSlot(pageId: group.pageId, groupId: group.id, slot: index % 10 + 1,
                    name: "真实引用 \(index)", at: CGPoint(x: 200 + index % 20 * 290, y: 180 + index / 20 * 230))
            }
            canvas.clearSelection()
            await pause(500)
            check(canvas.nodes.count == 250, "large canvas has 250 real slot references")
            for mode: WorkspaceMode in [.edit, .canvas] {
                await measure("referenced-canvas-workspace-\(mode.rawValue)",
                              action: { request(mode) }, completed: ready)
            }
            for node in canvas.nodes.prefix(10) {
                await measure("referenced-canvas-select", action: {
                    canvas.select(id: node.id, additive: false)
                }, completed: { canvas.selectedNodeIds == [node.id] }, seconds: 0.1)
            }
            capture("large-referenced-canvas")
        }
        if let manifest = environment["CLIPSLOTS_MEDIA_MANIFEST"] {
            request(.canvas)
            _ = await until(ready)
            let media = await LargeMediaRegression.run(manifest: URL(fileURLWithPath: manifest),
                directory: directory, store: store, canvas: canvas, window: window,
                request: request, ready: ready)
            for (title, passed) in media.checks { check(passed, title) }
            measurements.append(contentsOf: media.measurements)
        }
        }
        await compositor?.stop()
        compositor = nil
        request(.edit)
        check(await until(ready), "edit ready before model popup")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await pause(400)
        if let picker = identifier("agent-model-picker") {
            check(picker.accessibilityPerformPress?() == true, "model trigger accepts native press")
            await pause(800)
            measurements.append(["scenario": "model-windows",
                "windows": NSApp.windows.map { item -> [String: Any] in
                    ["type": String(describing: type(of: item)), "frame": NSStringFromRect(item.frame),
                     "visible": item.isVisible, "identifiers": item.contentView.map {
                         NativeAccessibilityProbe.elements($0).compactMap { $0.accessibilityIdentifier?() }
                     } ?? []]
                }])
            func popup() -> NSView? {
                for candidate in NSApp.windows where candidate !== window && candidate.isVisible {
                    if let view = candidate.contentView,
                       NativeAccessibilityProbe.elements(view).contains(where: {
                           $0.accessibilityIdentifier?() == "agent-model-menu"
                       }) { return view }
                }
                return nil
            }
            if let view = popup(), let popupWindow = view.window {
                capture("model-menu-before-hover", view: view)
                measurements.append(["scenario": "model-popup", "frame": NSStringFromRect(popupWindow.frame),
                                     "screen": NSStringFromRect(popupWindow.screen?.visibleFrame ?? .zero)])
                check(popupWindow.frame.width > 200 && popupWindow.frame.height > 100, "model menu has a usable initial size")
                let choices = NativeAccessibilityProbe.elements(view)
                if let info = choices.first(where: {
                    ($0.accessibilityIdentifier?() ?? "").hasPrefix("agent-model-info-")
                }) {
                    _ = info.accessibilityPerformPress?()
                    await pause(300)
                    capture("model-menu-details", view: view)
                    if let screen = popupWindow.screen {
                        check(screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(popupWindow.frame),
                              "model details stay completely inside screen")
                    }
                }
                func find(_ id: String) -> AnyObject? {
                    NativeAccessibilityProbe.elements(view).first { $0.accessibilityIdentifier?() == id }
                }
                check(find("agent-model-choice-deepseek-chat") != nil, "service catalog loaded beyond selected fallback")
                _ = find("agent-model-info-deepseek-reasoner")?.accessibilityPerformPress?()
                await pause(100)
                check(find("agent-model-effort-deepseek-reasoner-max")?.accessibilityPerformPress?() == true,
                      "native effort choice accepts press")
                await pause(100)
                check(find("agent-model-effort-deepseek-reasoner")?.accessibilityPerformDecrement?() == true,
                      "native effort slider changes level")
                check(find("agent-model-more")?.accessibilityPerformPress?() == true, "more models expands")
                await pause(200)
                check(popupWindow.screen?.visibleFrame.contains(popupWindow.frame) == true,
                      "expanded catalog stays inside screen")
                if let field = NativeAccessibilityProbe.elements(view).compactMap({ $0 as? NSTextField })
                    .first(where: { $0.placeholderString == "搜索模型" }) {
                    popupWindow.makeKey()
                    field.selectText(nil)
                    if let editor = field.currentEditor() as? NSTextView {
                        editor.insertText("service-model-34",
                                          replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    }
                    await pause(200)
                    check(find("agent-model-choice-service-model-34") != nil
                          && find("agent-model-choice-service-model-0") == nil,
                          "native search filters long catalog")
                    capture("model-menu-search", view: view)
                    check(find("agent-model-choice-service-model-34")?.accessibilityPerformPress?() == true,
                          "filtered model accepts selection")
                    check(await until { popup() == nil }, "selection dismisses native panel")
                    check(UserDefaults.standard.string(forKey: "agent.model") == "service-model-34",
                          "selection persists exact service model id")
                } else { check(false, "native model search field mounted") }
                for (label, size, corner) in [
                    ("narrow-left", CGSize(width: 760, height: 620), false),
                    ("wide-right", CGSize(width: 1280, height: 720), true)
                ] {
                    window.setContentSize(size)
                    if let screen = window.screen {
                        window.setFrameOrigin(CGPoint(x: corner ? screen.visibleFrame.maxX - window.frame.width
                            : screen.visibleFrame.minX, y: screen.visibleFrame.minY))
                    }
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    await pause(150)
                    _ = identifier("agent-model-picker")?.accessibilityPerformPress?()
                    await pause(150)
                    if let edgeView = popup(), let edgePanel = edgeView.window {
                        let buttons = NativeAccessibilityProbe.elements(edgeView)
                        _ = buttons.first { ($0.accessibilityIdentifier?() ?? "").hasPrefix("agent-model-info-") }?
                            .accessibilityPerformPress?()
                        await pause(100)
                        check(edgePanel.screen?.visibleFrame.contains(edgePanel.frame) == true,
                              "\(label) detail contained")
                        capture("model-menu-\(label)", view: edgeView)
                        edgePanel.cancelOperation(nil)
                        check(await until { popup() == nil }, "\(label) Escape dismisses")
                    } else { check(false, "\(label) reopens menu") }
                }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                await pause(200)
                _ = identifier("agent-model-picker")?.accessibilityPerformPress?()
                check(await until { popup() != nil }, "menu reopens before outside click")
                if let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 20, y: 20),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.sendEvent(outside)
                }
                check(await until { popup() == nil }, "outside click dismisses")
            } else { check(false, "model popup has an independent native surface") }
        } else { check(false, "model picker accessibility trigger mounted") }
        capture("large-library-final")
        let report: [String: Any] = ["fixture": "isolated workload; not user library",
            "groups": store.specialSlots.count, "pages": store.pages.count,
            "measurements": measurements, "checks": checks,
            "passed": checks.values.filter { $0 }.count, "failures": checks.filter { !$0.value }.map(\.key)]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}
#endif
