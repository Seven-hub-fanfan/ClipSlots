#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
enum PermissionRegression {
    private static var started = false
    static func startIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard env["CLIPSLOTS_PERMISSION_PROBE"] == "1", !started,
              Bundle.main.object(forInfoDictionaryKey: "ClipSlotsIsolatedCandidate") as? Bool == true,
              let output = env["CLIPSLOTS_PERMISSION_OUTPUT"],
              let data = env["CLIPSLOTS_DATA_DIR"], data.hasPrefix("/tmp/") else { return false }
        started = true
        Task { await run(directory: URL(fileURLWithPath: output)) }
        return true
    }

    private static func run(directory: URL) async {
        var passed = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 } else { failures.append(message) }
            NSLog("[PermissionProbe] \(condition ? "PASS" : "FAIL") \(message)")
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(100)) }
        func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
            guard depth < 30 else { return [] }
            let children = node.accessibilityChildren?() ?? []
            let fallback = (node as? NSView)?.subviews ?? []
            return [node] + (children.isEmpty ? fallback : children).flatMap { elements($0 as AnyObject, depth: depth + 1) }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = Fixture()
        let model = PermissionCenterModel(backend: PermissionBackend(
            preflight: { fixture.grants.contains($0) },
            requestScreenCapture: {
                fixture.requests += 1
                await withCheckedContinuation { fixture.pending = $0 }
            },
            openSettings: { fixture.opens.append($0); return fixture.canOpen },
            reset: {
                fixture.resets.append($0)
                if fixture.holdReset {
                    await withCheckedContinuation { fixture.pendingReset = $0 }
                }
                if let failure = fixture.resetFailure { throw PermissionRepairCoordinator.Failure(message: failure) }
            },
            requestAccessibility: { fixture.axRequests += 1 }
        ))
        check(model.authorized.isEmpty && fixture.requests == 0 && fixture.opens.isEmpty,
              "initial denied or undetermined preflight performs no request")
        fixture.grants = [.accessibility]
        model.refresh()
        check(model.authorized == [.accessibility], "accessibility grant refreshes independently")
        fixture.grants.removeAll()
        model.refresh()
        check(model.authorized.isEmpty, "revoked authorization never remains cached")
        model.authorize(.accessibility)
        check(fixture.opens == [.accessibility] && fixture.requests == 0, "AX action opens only its own pane")
        model.authorize(.screenCapture)
        model.authorize(.screenCapture)
        await settle()
        check(model.requestingScreenCapture && fixture.requests == 1,
              "concurrent native screen requests deduplicated")
        check(fixture.opens == [.accessibility, .screenCapture], "repeated pending click does not refocus Settings")
        check(!model.authorized.contains(.screenCapture), "pending request never displayed as authorized")
        var mainQueueRan = false
        DispatchQueue.main.async { mainQueueRan = true }
        await settle()
        check(mainQueueRan, "main dispatch queue remains responsive during native request")
        let opensBeforeCompletion = fixture.opens.count
        model.stopGuiding()
        fixture.pending?.resume()
        fixture.pending = nil
        await settle()
        check(!model.requestingScreenCapture && model.authorized.isEmpty,
              "rejected native request leaves truthful state and permits closing")
        check(fixture.opens.count == opensBeforeCompletion && model.settingsPermission == nil,
              "native request completion neither reopens settings nor replays an action")
        model.authorize(.screenCapture)
        await settle()
        check(fixture.requests == 1, "repeat denied action uses settings without native prompt loop")
        fixture.grants = [.accessibility, .screenCapture]
        model.refresh()
        check(model.authorized.count == 2, "both grants become ready only after preflight")
        let readyOpens = fixture.opens.count
        model.authorize(.screenCapture)
        check(fixture.opens.count == readyOpens, "authorized action does not request again")
        fixture.grants = [.accessibility]
        model.startMonitoring()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        await settle()
        check(model.authorized == [.accessibility], "return to app detects revocation")
        fixture.grants = [.accessibility, .screenCapture]
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        await settle()
        check(model.authorized.count == 2, "return to app refreshes newly granted permission")
        model.stopMonitoring()
        model.stopMonitoring()
        fixture.grants = []
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        await settle()
        check(model.authorized.count == 2, "monitoring teardown removes activation observer")
        fixture.grants = []
        fixture.canOpen = false
        model.authorize(.accessibility)
        check(model.error != nil && model.authorized.isEmpty, "failed settings URL has actionable fallback")
        fixture.canOpen = true
        model.stopGuiding()

        // Explicit repair, with a backend that never calls tccutil.
        fixture.grants = [.accessibility]
        model.repair(.accessibility)
        await settle()
        check(fixture.resets.isEmpty, "repair preserves a permission that is already effective")
        fixture.grants = []
        fixture.holdReset = true
        model.repair(.accessibility)
        model.repair(.screenCapture)
        model.authorize(.screenCapture)
        await settle()
        check(fixture.resets == [.accessibility] && model.repairing == .accessibility,
              "repair serializes resets and ordinary authorization actions")
        let priorRepairOpens = fixture.opens.count
        check(model.authorized.isEmpty && model.settingsPermission == nil,
              "reset in flight neither grants permission nor launches settings")
        fixture.pendingReset?.resume()
        fixture.pendingReset = nil
        await settle()
        check(fixture.axRequests == 1 && fixture.opens.count == priorRepairOpens + 1
                && fixture.opens.last == .accessibility,
              "AX reset completion starts only its own native regrant and settings")
        check(model.authorized.isEmpty && model.repairNotice != nil && model.repairing == nil,
              "successful reset is shown as cleared, never authorized")
        model.stopGuiding()
        model.repair(.screenCapture)
        await settle()
        fixture.pendingReset?.resume()
        fixture.pendingReset = nil
        await settle()
        check(fixture.requests == 2 && model.requestingScreenCapture,
              "screen repair permits one new native request after an earlier denial")
        let busyResets = fixture.resets.count
        model.repair(.accessibility)
        await settle()
        check(fixture.resets.count == busyResets, "native screen prompt blocks all destructive repairs")
        model.stopGuiding()
        fixture.pending?.resume()
        fixture.pending = nil
        await settle()
        model.repair(.accessibility)
        await settle()
        let closeOpens = fixture.opens.count, closeAXRequests = fixture.axRequests
        model.stopGuiding()
        fixture.pendingReset?.resume()
        fixture.pendingReset = nil
        await settle()
        check(model.settingsPermission == nil && fixture.opens.count == closeOpens
                && fixture.axRequests == closeAXRequests && model.repairing == nil,
              "closing during reset suppresses late settings, prompts and repair notice")
        fixture.holdReset = false
        fixture.resetFailure = "受管策略拒绝"
        model.repair(.accessibility)
        await settle()
        check(model.error == "受管策略拒绝" && fixture.opens.count == closeOpens,
              "reset failure is actionable and never begins regrant")
        let failedResets = fixture.resets.count
        model.refresh()
        await settle()
        check(fixture.resets.count == failedResets, "failure and refresh never automatically retry a reset")
        fixture.resetFailure = nil
        model.stopGuiding()
        for permission in AppPermission.allCases {
            let args = try? PermissionRepairCoordinator.arguments(for: permission, bundleID: "com.clipslots.app")
            check(args == ["reset", permission == .accessibility ? "Accessibility" : "ScreenCapture", "com.clipslots.app"],
                  "repair command scopes \(permission.rawValue) to one service and formal bundle ID")
        }
        for bundleID in ["", "com.other.app", "com.clipslots.app; echo bad", "com.clipslots.app.test"] {
            check((try? PermissionRepairCoordinator.arguments(for: .accessibility, bundleID: bundleID)) == nil,
                  "repair rejects invalid or isolated identifier \(bundleID)")
        }
        do {
            try await PermissionRepairCoordinator.reset(.accessibility)
            check(false, "isolated candidate must refuse system reset")
        } catch { check(true, "isolated candidate refuses system reset before running tccutil") }
        do {
            let args = try PermissionRepairCoordinator.arguments(for: .screenCapture, bundleID: "com.clipslots.app")
            let result = try await ToolProcess.run("/usr/bin/printf", ["%s\\n"] + args, timeout: 3)
            check(result.status == 0 && result.stdout == "reset\nScreenCapture\ncom.clipslots.app\n",
                  "subprocess preserves exact argument boundaries without a shell")
        } catch { check(false, "bounded argument subprocess: \(error)") }
        let startTime = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await ToolProcess.run("/bin/sleep", ["3"], timeout: 0.15)
            check(false, "bounded reset worker times out")
        } catch {
            check(ProcessInfo.processInfo.systemUptime - startTime < 2,
                  "timeout stops worker promptly without blocking the UI")
        }
        let worker = Task { try await ToolProcess.run("/bin/sleep", ["3"], timeout: 5) }
        await settle()
        worker.cancel()
        do {
            _ = try await worker.value
            check(false, "cancellation stops reset worker")
        } catch is CancellationError { check(true, "cancellation stops reset worker") }
        catch { check(false, "reset cancellation error \(error)") }

        func identity(hash: String = "A", signer: String? = nil, id: String = "com.clipslots.app") -> AppCodeIdentity {
            AppCodeIdentity(bundleID: id, version: "2.17.34", path: "/Applications/ClipSlots.app",
                            requirement: Data(hash.utf8), codeHash: hash, signerSHA256: signer)
        }
        let old = identity(signer: "stable"), new = identity(hash: "B", signer: "stable")
        check(CodeIdentityInspector.transition(from: old, to: new, satisfiesPrevious: true) == .compatible,
              "changed binary hash with matching signer and old DR is a normal upgrade")
        check(CodeIdentityInspector.transition(from: identity(), to: identity(hash: "B"), satisfiesPrevious: false) == .migration,
              "incompatible ad-hoc replacement is classified as migration")
        check(CodeIdentityInspector.transition(from: identity(), to: new, satisfiesPrevious: false) == .migration,
              "first certificate migration from ad-hoc is classified explicitly")
        check(CodeIdentityInspector.transition(from: old, to: identity(signer: "other"), satisfiesPrevious: true) == .rejected,
              "candidate cannot bypass signer continuity using a broad DR")
        check(CodeIdentityInspector.transition(from: old, to: identity(), satisfiesPrevious: true) == .rejected,
              "certificate identity never downgrades silently to ad-hoc")
        check(CodeIdentityInspector.transition(from: old, to: identity(id: "com.other.app"), satisfiesPrevious: true) == .rejected,
              "different bundle ID is not an upgrade")
        check(CodeIdentityInspector.transition(from: nil, to: new, satisfiesPrevious: false) == .unknown,
              "missing history is unknown, never evidence of stale permission")
        let suite = "com.clipslots.permission-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let upgrade = PermissionUpgradeState(defaults: defaults)
        check(upgrade.observe(identity(), satisfiesPrevious: false) == .unknown && upgrade.pending == nil,
              "fresh install stores identity without creating repair intent")
        check(!upgrade.consumeAutomaticAccessibilityRepair(isAuthorized: false),
              "fresh install never automatically resets permission")
        check(upgrade.observe(identity(hash: "B"), satisfiesPrevious: false) == .migration && upgrade.pending != nil,
              "Finder replacement is detected from persisted previous identity")
        check(!upgrade.consumeAutomaticAccessibilityRepair(isAuthorized: true),
              "migration preserves effective accessibility permission")
        check(upgrade.consumeAutomaticAccessibilityRepair(isAuthorized: false)
                && !upgrade.consumeAutomaticAccessibilityRepair(isAuthorized: false),
              "known migration consumes automatic AX repair exactly once")
        check(upgrade.consumeMigrationGuidance() && !upgrade.consumeMigrationGuidance(),
              "known migration shows automatic guidance once, respecting declined optional permission")
        _ = upgrade.observe(identity(hash: "B"), satisfiesPrevious: true)
        check(upgrade.pending != nil, "restart preserves known migration while permissions are still unavailable")
        check(!upgrade.consumeMigrationGuidance(), "same identity restart does not repeat the upgrade popup")
        check(!PermissionUpgradeState(defaults: defaults).consumeAutomaticAccessibilityRepair(isAuthorized: false),
              "restart preserves the automatic repair attempt even when permission remains denied")
        upgrade.completeIfReady(false)
        check(upgrade.pending != nil, "one missing permission preserves migration guidance")
        upgrade.completeIfReady(true)
        check(upgrade.pending == nil, "effective grants complete migration guidance")
        upgrade.recordInstalled(from: old, to: new, transition: .compatible)
        check(upgrade.pending == nil && upgrade.previous == old, "normal installer transition does not require reauthorization")
        check(!upgrade.consumeAutomaticAccessibilityRepair(isAuthorized: false),
              "compatible update does not create automatic reset eligibility")
        _ = upgrade.observe(identity(hash: "rejected", signer: "other"), satisfiesPrevious: true)
        check(!upgrade.consumeAutomaticAccessibilityRepair(isAuthorized: false),
              "rejected signer transition never clears authorization automatically")

        // Exercise the same launch dispatcher, not just the eligibility flag.
        upgrade.recordInstalled(from: identity(), to: identity(hash: "C"), transition: .migration)
        fixture.grants = []
        model.refresh()
        let autoResets = fixture.resets.count, autoRequests = fixture.axRequests
        let autoOpens = fixture.opens.count
        var guideCount = 0
        check(!AccessibilityPermissionGuide.startAutomaticRepair(using: model, upgrade: upgrade,
                isFormalInstall: false, presentGuide: { guideCount += 1 }),
              "isolated launch never consumes a real-install automatic repair")
        check(AccessibilityPermissionGuide.startAutomaticRepair(using: model, upgrade: upgrade,
                isFormalInstall: true, presentGuide: { guideCount += 1 }),
              "migration launch starts automatic repair without a button click")
        await settle()
        check(fixture.resets.count == autoResets + 1 && fixture.resets.last == .accessibility
                && fixture.axRequests == autoRequests + 1 && fixture.opens.count == autoOpens + 1
                && fixture.opens.last == .accessibility && guideCount == 1,
              "automatic launch clears AX only, requests it and opens its settings pane")
        check(!AccessibilityPermissionGuide.startAutomaticRepair(using: model, upgrade: upgrade,
                isFormalInstall: true, presentGuide: { guideCount += 1 }),
              "activation cannot repeat automatic reset after request")
        model.stopGuiding()
        upgrade.recordInstalled(from: identity(), to: identity(hash: "D"), transition: .migration)
        fixture.resetFailure = "automatic reset fixture failure"
        let failedAutoResets = fixture.resets.count, failedAutoOpens = fixture.opens.count
        _ = AccessibilityPermissionGuide.startAutomaticRepair(using: model, upgrade: upgrade,
                isFormalInstall: true, presentGuide: {})
        await settle()
        check(model.error == fixture.resetFailure && fixture.resets.count == failedAutoResets + 1
                && fixture.opens.count == failedAutoOpens,
              "automatic reset failure is visible and never falsely opens regrant")
        check(!PermissionUpgradeState(defaults: defaults).consumeAutomaticAccessibilityRepair(isAuthorized: false),
              "failed automatic reset never loops on next launch")
        fixture.resetFailure = nil
        model.stopGuiding()
        defaults.removePersistentDomain(forName: suite)
        check(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("PermissionUpgrade.") },
              "isolated identity tests clean up their own preferences")
        do {
            let actual = try CodeIdentityInspector.inspect(Bundle.main.bundleURL)
            check(CodeIdentityInspector.satisfies(actual, at: Bundle.main.bundleURL),
                  "public Security APIs verify actual signed candidate against its own DR")
            check(!CodeIdentityInspector.satisfies(identity(), at: Bundle.main.bundleURL),
                  "invalid saved requirement cannot be accepted as compatible")
        } catch { check(false, "native code identity inspection \(error)") }

        let current = Bundle.main.bundleURL
        check(PermissionApplicationFile.currentURL == current, "drag refers to actual running app location")
        let writer = PermissionApplicationFile.pasteboardWriter(for: current)
        let pasteboard = NSPasteboard.withUniqueName()
        if let writer { pasteboard.writeObjects([writer]) }
        let values = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        check(values?.first == current && pasteboard.types?.contains(.fileURL) == true,
              "native drag exports NSURL file URL accepted by privacy settings")
        pasteboard.releaseGlobally()
        check(PermissionApplicationFile.validated(URL(fileURLWithPath: "/Applications/NoSuchClipSlots.app")) == nil,
              "missing application cannot generate misleading drag")
        check(PermissionApplicationFile.validated(current.appendingPathComponent("Contents/Info.plist")) == nil,
              "drag excludes files and non-application bundles")
        let view = PermissionFileDragView(url: current)
        check(view.accessibilityIdentifier() == "permission-app-drag" && view.accessibilityRole() == .button,
              "drag card exposes accessible Finder fallback")
        for visible in [CGRect(x: 0, y: 23, width: 1280, height: 740),
                        CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                        CGRect(x: 1280, y: -900, width: 800, height: 900)] {
            for settings in [CGRect(x: visible.minX - 100, y: visible.minY - 200, width: 700, height: 600),
                             CGRect(x: visible.maxX - 100, y: visible.maxY - 100, width: 700, height: 600)] {
                let frame = PermissionHelperGeometry.frame(size: PermissionCenter.helperSize,
                                                           settings: settings, visible: visible)
                check(frame.map { visible.contains($0) && !$0.intersects(settings) } ?? true,
                      "helper docks outside Settings or hides on display \(visible.origin)")
            }
        }
        check(PermissionHelperGeometry.frame(size: PermissionCenter.helperSize, settings: nil,
              visible: CGRect(x: 0, y: 0, width: 1280, height: 720)) == nil,
              "unknown Settings bounds hide helper without obscuring controls")
        check(PermissionHelperGeometry.frame(size: PermissionCenter.helperSize,
              settings: CGRect(x: 0, y: 0, width: 1000, height: 740),
              visible: CGRect(x: 0, y: 0, width: 1000, height: 740)) == nil,
              "maximized Settings remains unobstructed")
        check(PermissionHelperGeometry.frame(size: PermissionCenter.helperSize,
              settings: CGRect(x: 80, y: 220, width: 840, height: 460),
              visible: CGRect(x: 0, y: 0, width: 1000, height: 740)) != nil,
              "helper docks below Settings when horizontal space is unavailable")
        check(PermissionHelperGeometry.companionFrame(size: PermissionCenter.cardSize,
              settings: CGRect(x: 550, y: 60, width: 700, height: 650),
              visible: CGRect(x: 0, y: 0, width: 1280, height: 740)) != nil,
              "status card fits beside Settings when display permits")
        check(PermissionHelperGeometry.companionFrame(size: PermissionCenter.cardSize,
              settings: CGRect(x: 100, y: 60, width: 700, height: 650),
              visible: CGRect(x: 0, y: 0, width: 1000, height: 740)) == nil,
              "narrow display uses small helper without covering Settings")

        let secondary = CGRect(x: -1280, y: 0, width: 1280, height: 740)
        let maximized = CGRect(x: 0, y: 0, width: 1280, height: 740)
        let crossDisplay = PermissionHelperGeometry.guideFrame(size: PermissionCenter.helperSize,
            settings: maximized, visibleFrames: [maximized, secondary])
        check(crossDisplay.map { secondary.contains($0) && !$0.intersects(maximized) } == true,
              "maximized Settings keeps drag helper on an available second display")
        check(PermissionHelperGeometry.guideFrame(size: PermissionCenter.helperSize,
            settings: CGRect(x: 20, y: 20, width: 250, height: 150),
            visibleFrames: [CGRect(x: 0, y: 0, width: 300, height: 200)]) == nil,
              "small display does not produce an off-screen or overlapping drag card")

        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 140), size: PermissionCenter.cardSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let savedSkin = AppSkinCenter.current
        let savedAppearance = NSApp.appearance
        var closeCount = 0
        let host = NSHostingView(rootView: PermissionCenterCard(model: model, onClose: { closeCount += 1 },
                                                               onAuthorize: { model.authorize($0) },
                                                               onRepair: { model.repair($0) }))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The external test runner asks for the lazily built SwiftUI AX tree.
        // A child of this untrusted test app cannot act as an AX client.
        try? String(ProcessInfo.processInfo.processIdentifier).write(
            to: directory.appendingPathComponent("accessibility-pid"), atomically: true, encoding: .utf8)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("accessibility-ready").path) { break }
            await settle()
        }
        for skin in [AppSkin.minimal, .colorful] {
            AppSkinCenter.apply(skin)
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.rootView = PermissionCenterCard(model: model, onClose: { closeCount += 1 },
                                                     onAuthorize: { model.authorize($0) },
                                                     onRepair: { model.repair($0) })
                await settle()
                let nodes = elements(host)
                let dump = nodes.map { "\($0.accessibilityRole?()?.rawValue ?? "-") | \($0.accessibilityIdentifier?() ?? "-") | \($0.accessibilityLabel?() ?? "-")" }
                try? dump.joined(separator: "\n").write(to: directory.appendingPathComponent(
                    "accessibility-\(skin.rawValue)-\(dark).txt"), atomically: true, encoding: .utf8)
                check(nodes.contains { ($0.accessibilityIdentifier?() ?? "") == "permission-authorize-accessibility" },
                      "\(skin.rawValue) \(dark ? "dark" : "light") denied row accessible")
                check(nodes.contains { ($0.accessibilityIdentifier?() ?? "") == "permission-close" },
                      "\(skin.rawValue) \(dark ? "dark" : "light") close button accessible")
                check(nodes.contains { ($0.accessibilityIdentifier?() ?? "") == "permission-repair-accessibility" },
                      "\(skin.rawValue) \(dark ? "dark" : "light") explicit repair is accessible")
                check(nodes.contains { ($0.accessibilityIdentifier?() ?? "") == "permission-app-drag" },
                      "\(skin.rawValue) \(dark ? "dark" : "light") main permission card exposes application drag")
                func dragView(_ view: NSView) -> PermissionFileDragView? {
                    if let drag = view as? PermissionFileDragView { return drag }
                    return view.subviews.compactMap { dragView($0) }.first
                }
                let nativeDrag = dragView(host)
                check(nativeDrag.map { $0.dragEnabled && !$0.isHiddenOrHasHiddenAncestor
                        && host.bounds.contains($0.convert($0.bounds, to: host)) } == true,
                      "\(skin.rawValue) \(dark ? "dark" : "light") drag card is visible and inside the panel")
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(
                        "permission-fixture-\(skin.rawValue)-\(dark ? "dark" : "light").png"))
                    check(bitmap.pixelsWide > 0, "native permission card renders \(skin.rawValue) \(dark)")
                } else { check(false, "native snapshot available") }
            }
        }
        AppSkinCenter.apply(.minimal)
        NSApp.appearance = NSAppearance(named: .aqua)
        fixture.grants = [.accessibility]
        model.refresh()
        await settle()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("permission-fixture-partial-ready.png"))
        }
        fixture.grants = [.accessibility, .screenCapture]
        model.refresh()
        await settle()
        let readyNodes = elements(host)
        check(readyNodes.contains { ($0.accessibilityIdentifier?() ?? "") == "permission-status-screenCapture" },
              "native row changes to authorized after preflight")
        check(!readyNodes.contains { ($0.accessibilityIdentifier?() ?? "") == "permission-app-drag" },
              "all effective permissions complete the optional drag guide")
        let close = readyNodes.first { ($0.accessibilityIdentifier?() ?? "") == "permission-close" }
        _ = close?.accessibilityPerformPress?()
        check(closeCount == 1, "native close action executes once")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("permission-fixture-all-ready.png"))
        }
        window.close()
        fixture.grants = []
        model.refresh()
        let helperHost = NSHostingView(rootView: PermissionDragHelper(
            model: model, permission: .accessibility, onClose: {}, onRepair: { model.repair($0) }))
        let helperWindow = NSWindow(contentRect: NSRect(origin: NSPoint(x: 150, y: 130), size: PermissionCenter.helperSize),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        helperWindow.isReleasedWhenClosed = false
        helperWindow.contentView = helperHost
        helperWindow.makeKeyAndOrderFront(nil)
        await settle()
        check(elements(helperHost).contains { ($0.accessibilityIdentifier?() ?? "") == "permission-app-drag" },
              "native helper includes real app drag target")
        check(elements(helperHost).contains { ($0.accessibilityIdentifier?() ?? "") == "permission-helper-repair-accessibility" },
              "native drag helper includes its own explicit cleanup action")
        if let bitmap = helperHost.bitmapImageRepForCachingDisplay(in: helperHost.bounds) {
            helperHost.cacheDisplay(in: helperHost.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("permission-helper-native.png"))
        }
        helperWindow.close()
        AppSkinCenter.apply(savedSkin)
        NSApp.appearance = savedAppearance

        // These panels use the actual system backend. Do not click authorize.
        PermissionCenter.present(for: .accessibility)
        let first = PermissionCenter.panel
        PermissionCenter.present(for: .screenCapture)
        check(PermissionCenter.panel === first, "AX and screen feature gates share a single panel")
        check((first?.contentView as? NSHostingView<PermissionCenterCard>)?.rootView.purpose == .screenCapture,
              "existing permission panel updates to the most recent feature context")
        check(first?.level == .floating && first?.canBecomeKey == true,
              "permission panel is keyboard accessible and avoids screensaver-level UI")
        mainQueueRan = false
        DispatchQueue.main.async { mainQueueRan = true }
        await settle()
        check(mainQueueRan, "visible real panel does not enter a nested modal run loop")
        first?.cancelOperation(nil)
        check(PermissionCenter.panel == nil, "Escape cancel action dismisses the permission panel")
        PermissionCenter.dismiss()
        check(PermissionCenter.panel == nil && PermissionCenter.helper == nil, "closing clears all companion panels")

        // Drive the same window-routing code with a fake backend and desktop
        // bounds. This catches the wide-display regression without opening
        // System Settings or resetting the installed app's TCC decisions.
        PermissionCenter.present(for: .accessibility)
        PermissionCenter.model.onRefresh = nil
        PermissionCenter.model.stopMonitoring()
        model.authorize(.accessibility)
        let wideDisplay = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let settingsBounds = CGRect(x: 600, y: 120, width: 700, height: 650)
        func showHelper() {
            PermissionCenter.updateHelperForTesting(using: model, settingsFrame: settingsBounds,
                visibleFrames: [wideDisplay], frontBundleID: "com.apple.systempreferences")
        }
        showHelper()
        await settle()
        check(PermissionCenter.helper?.isVisible == true && PermissionCenter.panel?.isVisible == false,
              "wide display prioritizes the drag helper instead of hiding it behind the large panel")
        check(PermissionCenter.helper.map { !$0.frame.intersects(settingsBounds)
                && wideDisplay.contains($0.frame) } == true,
              "visible helper stays outside the system permission controls")
        func firstDrag(_ view: NSView) -> PermissionFileDragView? {
            (view as? PermissionFileDragView) ?? view.subviews.compactMap { firstDrag($0) }.first
        }
        check(PermissionCenter.helper.map { !$0.isMovable && !$0.isMovableByWindowBackground } == true,
              "nonactivating helper cannot be dragged as a window")
        if let helper = PermissionCenter.helper,
           let card = helper.contentView.flatMap({ firstDrag($0) }) {
            check(!card.mouseDownCanMoveWindow && card.acceptsFirstMouse(for: nil),
                  "file card accepts the first press without starting background window movement")
            let anchor = card.convert(NSPoint(x: 30, y: 18), to: nil)
            func event(_ type: NSEvent.EventType, offset: CGFloat = 0) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: anchor.x + offset, y: anchor.y),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: helper.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            }
            func moveSettings() {
                PermissionCenter.updateHelperForTesting(using: model,
                    settingsFrame: settingsBounds.offsetBy(dx: -100, dy: 20),
                    visibleFrames: [wideDisplay], frontBundleID: "com.apple.systempreferences")
            }
            let frameBeforePress = helper.frame
            // Send actual AppKit input to the native card. Staying below 3 px
            // exercises the gap before beginDraggingSession, without a system
            // drop, global mouse injection or any change to TCC.
            card.mouseDown(with: event(.leftMouseDown))
            card.mouseDragged(with: event(.leftMouseDragged, offset: 1))
            moveSettings()
            await settle()
            check(helper.frame == frameBeforePress && helper.isVisible && !helper.isKeyWindow
                    && !PermissionCenter.draggingApplication,
                  "press and subthreshold drag freeze docking before a file session starts")
            card.mouseUp(with: event(.leftMouseUp))
            moveSettings()
            await settle()
            check(helper.frame != frameBeforePress && !PermissionCenter.draggingApplication,
                  "release without a file drag restores helper docking")
            showHelper()
            await settle()
            card.mouseDown(with: event(.leftMouseDown))
            card.dragEnabled = false
            moveSettings()
            await settle()
            check(helper.frame != frameBeforePress,
                  "disabling an armed application card clears the docking freeze")
            card.mouseDown(with: event(.leftMouseDown))
            showHelper()
            await settle()
            check(helper.frame == frameBeforePress,
                  "disabled card cannot arm a new pointer interaction")
            card.dragEnabled = true
            let detached = PermissionFileDragView(url: current)
            detached.frame = NSRect(x: 0, y: 0, width: 300, height: 39)
            helper.contentView?.addSubview(detached)
            detached.mouseDown(with: event(.leftMouseDown))
            detached.removeFromSuperview()
            moveSettings()
            await settle()
            check(helper.frame != frameBeforePress,
                  "removing an armed card clears the docking freeze")
            showHelper()
            await settle()
        } else { check(false, "actual helper exposes a native file card for mouse regression") }
        let initialFrame = PermissionCenter.helper?.frame
        PermissionCenter.draggingApplication = true
        PermissionCenter.updateHelperForTesting(using: model,
            settingsFrame: settingsBounds.offsetBy(dx: -300, dy: 20),
            visibleFrames: [wideDisplay], frontBundleID: "com.apple.systempreferences")
        check(PermissionCenter.helper?.frame == initialFrame, "native drag freezes helper movement and ordering")
        PermissionCenter.draggingApplication = false
        model.onRefresh = { showHelper() }
        fixture.holdReset = true
        for skin in [AppSkin.minimal, .colorful] {
            AppSkinCenter.apply(skin)
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                await settle()
                if let host = PermissionCenter.helper?.contentView,
                   let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(
                        to: directory.appendingPathComponent("drag-helper-\(skin.rawValue)-\(dark ? "dark" : "light").png"))
                }
                check(PermissionCenter.helper?.isVisible == true,
                      "\(skin.rawValue) \(dark ? "dark" : "light") live helper remains visible")
            }
        }
        let helperNodes = PermissionCenter.helper?.contentView.map { elements($0) } ?? []
        let resetAction = helperNodes.first {
            ($0.accessibilityIdentifier?() ?? "") == "permission-helper-repair-accessibility"
        }
        let resetsBeforeHelper = fixture.resets.count
        _ = resetAction?.accessibilityPerformPress?()
        await settle()
        check(fixture.resets.count == resetsBeforeHelper + 1 && fixture.resets.last == .accessibility,
              "actual helper cleanup button invokes exactly one scoped reset through the fixture")
        check(PermissionCenter.helper?.isVisible == true && model.repairing == .accessibility,
              "drag helper stays visible during old-record cleanup")
        let busyHost = PermissionCenter.helper?.contentView
        check(busyHost.flatMap { firstDrag($0) }?.dragEnabled == false,
              "application drag waits until record cleanup finishes")
        fixture.pendingReset?.resume()
        fixture.pendingReset = nil
        await settle()
        check(PermissionCenter.helper?.isVisible == true && model.settingsPermission == .accessibility
                && busyHost.flatMap { firstDrag($0) }?.dragEnabled == true,
              "cleanup completion restores usable drag without returning to the app")
        let closeNodes = PermissionCenter.helper?.contentView.map { elements($0) } ?? []
        let closeAction = closeNodes.first {
            ($0.accessibilityIdentifier?() ?? "") == "permission-helper-close"
        }
        _ = closeAction?.accessibilityPerformPress?()
        await settle()
        showHelper()
        check(PermissionCenter.helper == nil && model.settingsPermission == nil,
              "closing the drag helper stops guidance and polling never reopens it")
        model.onRefresh = nil
        model.stopGuiding()
        PermissionCenter.dismiss()
        AppSkinCenter.apply(savedSkin)
        NSApp.appearance = savedAppearance

        let report: [String: Any] = ["passed": passed, "failures": failures, "complete": true,
            "fixture_backend": true, "actual_tcc_changed": false,
            "real_preflight": ["accessibility": AXIsProcessTrusted(), "screenCapture": CGPreflightScreenCaptureAccess()]]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }

    private final class Fixture {
        var grants: Set<AppPermission> = []
        var requests = 0
        var opens: [AppPermission] = []
        var canOpen = true
        var pending: CheckedContinuation<Void, Never>?
        var resets: [AppPermission] = []
        var axRequests = 0
        var holdReset = false
        var resetFailure: String?
        var pendingReset: CheckedContinuation<Void, Never>?
    }
}
#endif
