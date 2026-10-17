import Foundation
import ClipSlotsKit

func runLocalToolchainTests(_ t: TestRunner, live: Bool = false) {
    t.check(!LocalToolchain.authenticated(#"{"authenticated":false}"#, tool: .tika),
            "Tika status exit zero with authenticated false is not a successful login")
    t.check(LocalToolchain.authenticated(#"{"authenticated":true}"#, tool: .tika), "Tika verified login")
    t.check(LocalToolchain.authenticated(#"{"username":"test"}"#, tool: .crate), "Crate verified login")
    for version in ["v22.19.0", "v22.23.3", "v24.11.0", "v26.0.0"] {
        t.check(LocalToolchain.supportsNode(version), "runtime accepts \(version)")
    }
    for version in ["v18.20.0", "v20.19.0", "v22.18.0", "v24.10.0", "garbage"] {
        t.check(!LocalToolchain.supportsNode(version), "runtime rejects incompatible \(version)")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("toolchain test '\(UUID())")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let chain = LocalToolchain(root: root, useSystemTools: false)
    t.check(chain.resolve(.crate) == nil && chain.resolve(.tika) == nil, "clean environment never borrows installed CLIs")
    t.equal(chain.resolve(.tika, customPath: "/a/missing/tikacli"), "/a/missing/tikacli", "explicit user path is preserved")
    let outcomes: [Bool] = smokeAwait {
        var checks: [Bool] = []
        do {
            let output = try await ToolProcess.run("/bin/sh", ["-c", "printf 'out'; printf 'err' >&2"])
            checks.append(output.status == 0 && output.stdout == "out" && output.stderr == "err")
            let flood = try await ToolProcess.run("/usr/bin/awk",
                ["BEGIN { for(i=0;i<200000;i++) { print \"stdout\"; print \"stderr\" > \"/dev/stderr\"; } }"],
                timeout: 15, outputLimit: 8192)
            checks.append(flood.status == 0 && flood.stdout.utf8.count == 8192 && flood.stderr.utf8.count == 8192)
            let start = Date()
            do {
                _ = try await ToolProcess.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 8"], timeout: 0.1)
                checks.append(false)
            } catch ToolProcess.Failure.timeout { checks.append(Date().timeIntervalSince(start) < 3) }
            catch { checks.append(false) }
            let task = Task { try await ToolProcess.run("/bin/sleep", ["8"], timeout: 30) }
            try await Task.sleep(for: .milliseconds(60))
            task.cancel()
            do { _ = try await task.value; checks.append(false) }
            catch is CancellationError { checks.append(true) }
            catch { checks.append(false) }
            let missing = await chain.detect(.crate)
            checks.append(!missing.ready && missing.path == nil)
        } catch { checks.append(false) }
        return checks
    }
    t.check(outcomes.count == 5 && outcomes.allSatisfy { $0 }, "process capture, large dual streams, timeout, cancellation and missing detection: \(outcomes)")
    do {
        let corrupt = root.appendingPathComponent("active-crate.json")
        try Data("{bad json".utf8).write(to: corrupt)
        t.check(chain.resolve(.crate) == nil, "corrupt activation never marks installed")
        let file = root.appendingPathComponent("checksum")
        try Data("abc".utf8).write(to: file)
        t.equal(try LocalToolchain.sha256(file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                "streaming SHA256 matches standard vector")
        let node = root.appendingPathComponent("mock/bin/node")
        let npm = root.appendingPathComponent("mock/lib/node_modules/npm/bin/npm-cli.js")
        try FileManager.default.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: npm.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nif [ \"$1\" = '--version' ]; then echo v22.23.3; fi\nexit 0\n".utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        try Data().write(to: npm)
        let activation = ["executable": node.path, "node": node.path, "version": "22.23.3"]
        try JSONSerialization.data(withJSONObject: activation).write(to: root.appendingPathComponent("active-node.json"))
        let original = try Data(contentsOf: corrupt)
        let failedSafely: Bool = smokeAwait {
            do { try await LocalToolchainInstaller(toolchain: chain).install([.crate]); return false }
            catch { return chain.resolve(.crate) == nil }
        }
        let afterFailure = try Data(contentsOf: corrupt)
        t.check(failedSafely && afterFailure == original,
                "npm success without usable CLI fails verification and preserves previous activation")
        let cancelledSafely: Bool = smokeAwait {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await LocalToolchainInstaller(toolchain: chain).install([.crate])
            }
            do { try await task.value; return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        t.check(cancelledSafely, "cancelled installation cannot activate an unverified package")
    } catch { t.check(false, "toolchain files: \(error)") }
    if live { runToolchainLive(t) }
}

private func runToolchainLive(_ t: TestRunner) {
    guard let configuredRoot = ProcessInfo.processInfo.environment["CLIPSLOTS_TOOLCHAIN_TEST_ROOT"] else {
        t.check(false, "live test requires explicit CLIPSLOTS_TOOLCHAIN_TEST_ROOT"); return
    }
    let root = URL(fileURLWithPath: configuredRoot)
    let chain = LocalToolchain(root: root, useSystemTools: false)
    let failure: String? = smokeAwait {
        do {
            let installer = LocalToolchainInstaller(toolchain: chain)
            try await installer.install([.crate, .ba, .tika, .rea]) { text in
                print("[LIVE INSTALL] \(text)"); fflush(stdout)
            }
            for tool in LocalTool.allCases {
                let status = await chain.detect(tool)
                guard status.ready else { return "\(tool.title) failed: \(status.issue ?? "")" }
                print("[LIVE VERSION] \(tool.title) \(status.version ?? "")"); fflush(stdout)
            }
            let before = LocalTool.allCases.map { chain.resolve($0) }
            try await installer.install([.crate, .ba, .tika, .rea])
            guard before == LocalTool.allCases.map({ chain.resolve($0) }) else { return "repeat install changed working executables" }
            let fixture = root.appendingPathComponent("analysis-fixture")
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            try Data(#"{"name":"clipslots-local-fixture","version":"1.0.0","main":"index.js"}"#.utf8)
                .write(to: fixture.appendingPathComponent("package.json"))
            try Data("export function group(items) { return { title: 'Fixture', children: items }; }\n".utf8)
                .write(to: fixture.appendingPathComponent("index.js"))
            let result = try await REAIntegration.analyze(fixture, mode: .javascript, toolchain: chain)
            try Data(result.utf8).write(to: root.appendingPathComponent("rea-analysis.json"))
            guard result.contains("index.js") else { return "REA result missing selected fixture" }
            print("[LIVE REA] local JavaScript analysis and report verified"); fflush(stdout)
            for tool in [LocalTool.crate, .tika] {
                let help = try await ToolProcess.run(chain.resolve(tool)!, ["auth", "--help"],
                                                     environment: chain.environment(), timeout: 30)
                guard help.status == 0, help.stdout.contains("login") else { return "\(tool.title) auth module failed" }
            }
            guard let driver = chain.crateLoginDriver() else { return "Crate browser login driver missing" }
            let driverHelp = try await ToolProcess.run(driver, ["--site", "i18n-tt", "auth", "login", "--help"],
                                                       environment: chain.environment(), timeout: 30)
            guard driverHelp.status == 0 else { return "Crate browser auth driver cannot start" }
            return nil
        } catch { return error.localizedDescription }
    }
    t.check(failure == nil, "real clean install, idempotency, auth command load and REA local analysis: \(failure ?? "PASS")")
}
