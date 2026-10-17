#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor
    func runEnvironmentSetupProbe(directory: URL) async -> (Int, [String]) {
        var passed = 0, failures: [String] = []
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failures.append(name) }
        }
        func wait(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<400 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return false
        }
        func capture(_ root: NSView, _ name: String) {
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        }
        do {
            // Local auth-contract fixtures: these do not contact an account or open a browser.
            // Actual official runtime installs and REA analysis run separately in --toolchain-live.
            let chain = LocalToolchain()
            let bin = chain.root.appendingPathComponent("fixture/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for tool in LocalTool.allCases {
                let path = bin.appendingPathComponent(tool.command)
                let status = tool == .tika ? #"{"authenticated":true}"# : #"{"username":"fixture"}"#
                let script = """
                #!/bin/sh
                if [ "$1" = "--version" ]; then echo '\(tool.pinnedVersion)'; exit 0; fi
                if [ "$1 $2" = "auth status" ]; then echo '\(status)'; exit 0; fi
                if [ "$1 $2" = "auth login" ]; then exit 0; fi
                exit 9

                """
                try Data(script.utf8).write(to: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
                let marker = ["executable": path.path, "node": bin.appendingPathComponent("node").path,
                              "version": tool.pinnedVersion]
                try JSONSerialization.data(withJSONObject: marker)
                    .write(to: chain.root.appendingPathComponent("active-\(tool.rawValue).json"))
            }
            let driver = bin.appendingPathComponent("bytedcli")
            try Data("#!/bin/sh\ncase \"$*\" in *--json*) exit 9;; esac\nexit 0\n".utf8).write(to: driver)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: driver.path)
            let manager = EnvironmentSetupManager.shared
            manager.check()
            check(await wait { !manager.busy }, "environment native detection completes")
            check(LocalTool.allCases.allSatisfy { manager.statuses[$0]?.ready == true },
                  "environment marks all four verified executable fixtures ready")
            manager.login(.crate)
            check(await wait { !manager.busy }, "Crate browser-flow fixture completes")
            check(manager.auth[.crate] == "已登录", "Crate login uses browser-capable driver without JSON then verifies identity")
            manager.login(.tika)
            check(await wait { !manager.busy }, "Tika browser-flow fixture completes")
            check(manager.auth[.tika] == "已登录", "Tika login verifies authenticated true")
            check(PluginCatalog.items(in: .community).contains { $0.id == "rea" },
                  "REA is shipped in community plugin catalog")
            check(REAIntegration.iconURL.flatMap { NSImage(contentsOf: $0) }?.size == NSSize(width: 32, height: 32),
                  "REA original SVG loads as a native image")
            for skin in [AppSkin.minimal, .colorful] {
                AppSkinCenter.apply(skin)
                for dark in [false, true] {
                    let host = NSHostingView(rootView: EnvironmentSetupView(includeREA: true)
                        .environment(\.colorScheme, dark ? .dark : .light))
                    let window = NSWindow(contentRect: .init(x: 20, y: 20, width: 550, height: 540),
                                          styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    window.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .milliseconds(300))
                    _ = await wait { !manager.busy }
                    capture(host, "batch-environment-\(skin.rawValue)-\(dark ? "dark" : "light").png")
                    check(host.fittingSize.width <= 552, "environment panel fits \(skin)/\(dark)")
                    window.close()
                    for detail in [false, true] {
                        let plugins = NSHostingView(rootView:
                            PluginsView(onClose: {}, initialCategory: .community, initialItemID: detail ? "rea" : nil)
                                .environment(\.colorScheme, dark ? .dark : .light))
                        let pluginWindow = NSWindow(contentRect: .init(x: 20, y: 20, width: 560, height: 588),
                                                    styleMask: [.titled], backing: .buffered, defer: false)
                        pluginWindow.isReleasedWhenClosed = false
                        pluginWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        pluginWindow.contentView = plugins
                        pluginWindow.makeKeyAndOrderFront(nil)
                        try? await Task.sleep(for: .milliseconds(400))
                        capture(plugins, "batch-rea-\(detail ? "detail" : "market")-\(skin.rawValue)-\(dark ? "dark" : "light").png")
                        check(plugins.fittingSize.width <= 562, "REA plugin \(detail ? "detail" : "market") fits \(skin)/\(dark)")
                        pluginWindow.close()
                    }
                }
            }
        } catch { check(false, "environment native probe: \(error)") }
        return (passed, failures)
    }
}
#endif
