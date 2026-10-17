import Foundation
import CryptoKit
import Darwin

public enum LocalTool: String, CaseIterable, Codable, Sendable, Identifiable {
    case node, crate, ba, tika, rea
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .node: return "Node.js"
        case .crate: return "Crate CLI"
        case .ba: return "ByteArtist CLI"
        case .tika: return "Tika CLI"
        case .rea: return "REA"
        }
    }
    public var command: String {
        switch self {
        case .tika: return "tikacli"
        default: return rawValue
        }
    }
    public var pinnedVersion: String {
        switch self {
        case .node: return "22.23.3"
        case .crate: return "0.6.1"
        case .ba: return "1.1.5"
        case .tika: return "0.6.8"
        case .rea: return "6.3.0"
        }
    }
    var package: String {
        switch self {
        case .crate: return "@byted-opero/crate-cli"
        case .ba: return "@byted-aip/byteartist-cli"
        case .tika: return "@tt-tika/tika-cli"
        case .rea: return "rea-agents"
        case .node: return ""
        }
    }
    var entry: String {
        switch self {
        case .crate: return "bin/crate.js"
        case .ba: return "bin/ba.mjs"
        case .tika: return "dist/tikacli-public.js"
        case .rea: return "scripts/rea.mjs"
        case .node: return ""
        }
    }
    var registry: String {
        self == .rea ? "https://registry.npmjs.org" : "https://bnpm.byted.org"
    }
}

public struct LocalToolStatus: Sendable {
    public let tool: LocalTool
    public let path: String?
    public let version: String?
    public let issue: String?
    public var ready: Bool { path != nil && issue == nil && version != nil }
}

/// Shared by detection, the installer, generation and Tika. No shell startup scripts or
/// global npm configuration changes are needed, including when launched from Finder.
public struct LocalToolchain: Sendable {
    /// Avoid choosing a reachable IPv6 socket whose corporate route never returns HTTP.
    /// IPv6-only DNS still works; only dual-stack preference changes.
    public static let nodeNetworkArguments = ["--dns-result-order=ipv4first", "--no-network-family-autoselection"]
    public let root: URL
    public let useSystemTools: Bool
    public init(root: URL = ClipSlotsPaths.dataRoot.appendingPathComponent("toolchain"),
                useSystemTools: Bool = true) {
        self.root = root
        self.useSystemTools = useSystemTools
    }

    struct Activation: Codable {
        let executable: String
        let node: String
        let version: String
    }
    func marker(_ tool: LocalTool) -> URL { root.appendingPathComponent("active-\(tool.rawValue).json") }
    func activation(_ tool: LocalTool) -> Activation? {
        guard let data = try? Data(contentsOf: marker(tool)),
              let value = try? JSONDecoder().decode(Activation.self, from: data),
              value.executable.hasPrefix(root.path + "/"),
              FileManager.default.isExecutableFile(atPath: value.executable) else { return nil }
        return value
    }

    public func searchPath(inherited: String? = nil) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = LocalTool.allCases.compactMap { activation($0) }.flatMap {
            [URL(fileURLWithPath: $0.node).deletingLastPathComponent().path,
             URL(fileURLWithPath: $0.executable).deletingLastPathComponent().path]
        }
        if let crate = activation(.crate) {
            paths.append(URL(fileURLWithPath: crate.executable).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("node_modules/.bin").path)
        }
        if useSystemTools {
            paths += ["\(home)/bin/node-v22/bin", "/opt/homebrew/bin", "/usr/local/bin",
                      "\(home)/.local/bin", "\(home)/bin", "\(home)/.volta/bin", "\(home)/.fnm/current/bin"]
            let nvm = URL(fileURLWithPath: "\(home)/.nvm/versions/node")
            paths += ((try? FileManager.default.contentsOfDirectory(at: nvm,
                       includingPropertiesForKeys: nil)) ?? []).sorted { $0.path > $1.path }
                .map { $0.appendingPathComponent("bin").path }
            paths += (inherited ?? ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        }
        paths += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
    }

    public func environment(inheritedPath: String? = nil) -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        result["PATH"] = searchPath(inherited: inheritedPath)
        return result
    }

    public func resolve(_ tool: LocalTool, customPath: String? = nil) -> String? {
        if let customPath, customPath != tool.command, !customPath.isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return expanded } // Preserve explicit user override, even broken.
            return searchPath().components(separatedBy: ":").map { $0 + "/" + expanded }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        if let managed = activation(tool) { return managed.executable }
        return searchPath().components(separatedBy: ":").map { $0 + "/" + tool.command }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Crate's own login calls bytedcli with --json, which suppresses auto-open.
    /// Start the official driver's text-mode browser flow before Crate imports its login.
    public func crateLoginDriver() -> String? {
        var candidates = searchPath().components(separatedBy: ":").map { $0 + "/bytedcli" }
        if let crate = resolve(.crate) {
            let package = URL(fileURLWithPath: crate).resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(package.appendingPathComponent("node_modules/.bin/bytedcli").path)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func authenticated(_ output: String, tool: LocalTool) -> Bool {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if tool == .tika { return object["authenticated"] as? Bool == true }
        if tool == .crate { return !(object["username"] as? String ?? "").isEmpty }
        if tool == .ba { return object["loggedIn"] as? Bool == true }
        return false
    }

    public static func supportsNode(_ raw: String) -> Bool {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "").split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return (parts[0] == 22 && parts[1] >= 19) || (parts[0] == 24 && parts[1] >= 11) || parts[0] >= 26
    }

    public func detect(_ tool: LocalTool, customPath: String? = nil) async -> LocalToolStatus {
        guard let path = resolve(tool, customPath: customPath) else {
            return LocalToolStatus(tool: tool, path: nil, version: nil, issue: "未安装")
        }
        do {
            let output = try await ToolProcess.run(path, ["--version"], environment: environment(), timeout: 20)
            let raw = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard output.status == 0, !raw.isEmpty else {
                return LocalToolStatus(tool: tool, path: path, version: nil, issue: "无法启动，可自动修复")
            }
            if tool == .crate, crateLoginDriver() == nil {
                return LocalToolStatus(tool: tool, path: path, version: String(raw.prefix(80)),
                                       issue: "登录组件缺失，可自动修复")
            }
            if tool == .ba, !ByteArtistGenerationAdapter.supportsVersion(raw) {
                return LocalToolStatus(tool: tool, path: path, version: String(raw.prefix(80)),
                                       issue: "需 BA 1.1.5 或兼容的 1.x，可自动修复")
            }
            let compatible = tool != .node || Self.supportsNode(raw)
            return LocalToolStatus(tool: tool, path: path, version: String(raw.prefix(80)),
                                   issue: compatible ? nil : "需兼容运行时（22.19+ / 24.11+ / 26+）")
        } catch {
            return LocalToolStatus(tool: tool, path: path, version: nil,
                                   issue: error is CancellationError ? "已取消" : "检测失败，可重试或自动修复")
        }
    }

    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Private, pinned installs; atomic activation only after a successful --version check.
/// Failed/cancelled installs leave the previous executable active. Old installs remain valid
/// for running tasks. A file lock also prevents a second app process racing the activation.
public actor LocalToolchainInstaller {
    public let toolchain: LocalToolchain
    private var busy = false
    public init(toolchain: LocalToolchain = LocalToolchain()) { self.toolchain = toolchain }

    public func install(_ requested: [LocalTool],
                        progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws {
        guard !busy else { throw ToolProcess.Failure.failed("环境配置正在进行，请稍候。") }
        busy = true
        defer { busy = false }
        let fm = FileManager.default
        try fm.createDirectory(at: toolchain.root, withIntermediateDirectories: true)
        let fd = open(toolchain.root.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw ToolProcess.Failure.failed("无法写入环境目录。") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw ToolProcess.Failure.failed("另一个 ClipSlots 正在配置环境，请稍后重试。")
        }
        var node = await toolchain.detect(.node)
        try Task.checkCancellation()
        if !node.ready {
            await progress("正在下载并校验 Node.js \(LocalTool.node.pinnedVersion)…")
            try await installNode()
            node = await toolchain.detect(.node)
        }
        guard node.ready, let nodePath = node.path else {
            throw ToolProcess.Failure.failed("Node.js 校验未通过，请重试。")
        }
        for tool in LocalTool.allCases where requested.contains(tool) && tool != .node {
            try Task.checkCancellation()
            if await toolchain.detect(tool).ready {
                await progress("\(tool.title) 已可用，保留现有安装")
                continue
            }
            await progress("正在安装 \(tool.title) \(tool.pinnedVersion)…")
            try await installPackage(tool, node: toolchain.activation(.node)?.node ?? nodePath)
        }
        try Task.checkCancellation()
        await progress("环境已就绪")
    }

    private func requireSuccess(_ output: ToolProcess.Output, _ stage: String) throws {
        guard output.status == 0 else {
            // npm/auth diagnostics may contain local configuration or credentials.
            // Surface actionable categories rather than copying subprocess output into UI/logs.
            let text = (output.stderr + output.stdout).lowercased()
            let reason: String
            if text.contains("enospc") { reason = "磁盘空间不足" }
            else if text.contains("e401") || text.contains("e403") { reason = "官方仓库拒绝访问，请检查网络或组织权限" }
            else if text.contains("enotfound") || text.contains("etimedout") || text.contains("econn") {
                reason = "无法连接官方仓库，请检查网络后重试"
            } else { reason = "校验未通过（退出码 \(output.status)），可重新安装" }
            throw ToolProcess.Failure.failed("\(stage)：\(reason)。")
        }
    }

    private func installNode() async throws {
        #if arch(arm64)
        let architecture = "arm64"
        let expected = "23b25245dcfb9af7262f8ff142e9e2e0af025368117329e7a7458a51e5922f53"
        #else
        let architecture = "x64"
        let expected = "8a677b0219178efd6eb0e475457c4afb452b521a92f6e67845a73bd85727f2a8"
        #endif
        let fm = FileManager.default
        let stage = toolchain.root.appendingPathComponent(".node-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let archive = stage.appendingPathComponent("node.tar.gz")
        let name = "node-v\(LocalTool.node.pinnedVersion)-darwin-\(architecture)"
        let output = try await ToolProcess.run("/usr/bin/curl",
            ["--fail", "--location", "--silent", "--show-error", "--proto", "=https",
             "--proto-redir", "=https", "--connect-timeout", "20", "--max-time", "300", "--retry", "1",
             "--output", archive.path, "https://nodejs.org/dist/v\(LocalTool.node.pinnedVersion)/\(name).tar.gz"],
            timeout: 640)
        try requireSuccess(output, "Node.js 下载失败")
        try Task.checkCancellation()
        guard try LocalToolchain.sha256(archive) == expected else {
            throw ToolProcess.Failure.failed("Node.js 下载校验不一致，请重试。")
        }
        let unpacked = try await ToolProcess.run("/usr/bin/tar", ["-xzf", archive.path, "-C", stage.path], timeout: 90)
        try requireSuccess(unpacked, "Node.js 解压失败")
        let destination = toolchain.root.appendingPathComponent("node-\(LocalTool.node.pinnedVersion)-\(UUID().uuidString)")
        try fm.moveItem(at: stage.appendingPathComponent(name), to: destination)
        var activated = false
        defer { if !activated { try? fm.removeItem(at: destination) } }
        let node = destination.appendingPathComponent("bin/node").path
        let version = try await ToolProcess.run(node, ["--version"])
        try requireSuccess(version, "Node.js 启动失败")
        guard LocalToolchain.supportsNode(version.stdout) else {
            throw ToolProcess.Failure.failed("Node.js 版本不兼容。")
        }
        try Task.checkCancellation()
        let marker = LocalToolchain.Activation(executable: node, node: node, version: LocalTool.node.pinnedVersion)
        try JSONEncoder().encode(marker).write(to: toolchain.marker(.node), options: .atomic)
        activated = true
    }

    private func installPackage(_ tool: LocalTool, node: String) async throws {
        let fm = FileManager.default
        let stage = toolchain.root.appendingPathComponent(".\(tool.rawValue)-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let nodeURL = URL(fileURLWithPath: node).resolvingSymlinksInPath()
        let npm = nodeURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js")
        guard fm.fileExists(atPath: npm.path) else {
            // Some standalone Node distributions omit npm. Install the complete official runtime.
            try await installNode()
            guard let managed = toolchain.activation(.node) else { throw ToolProcess.Failure.failed("npm 配置失败。") }
            try await installPackage(tool, node: managed.node)
            return
        }
        let userConfig = stage.appendingPathComponent("user.npmrc")
        let globalConfig = stage.appendingPathComponent("global.npmrc")
        try Data().write(to: userConfig); try Data().write(to: globalConfig)
        var env = toolchain.environment()
        for key in Array(env.keys) where key.lowercased().hasPrefix("npm_config_") { env.removeValue(forKey: key) }
        env["PATH"] = nodeURL.deletingLastPathComponent().path + ":" + toolchain.searchPath()
        env["NPM_CONFIG_USERCONFIG"] = userConfig.path
        env["NPM_CONFIG_GLOBALCONFIG"] = globalConfig.path
        env["NPM_CONFIG_CACHE"] = toolchain.root.appendingPathComponent("npm-cache").path
        env["CI"] = "1"
        let output = try await ToolProcess.run(node, LocalToolchain.nodeNetworkArguments + [npm.path, "install", "--prefix", stage.path,
            "--registry", tool.registry, "--ignore-scripts", "--no-audit", "--no-fund",
            "--fetch-timeout=30000", "--fetch-retries=1", "--fetch-retry-mintimeout=1000",
            "--fetch-retry-maxtimeout=3000", "\(tool.package)@\(tool.pinnedVersion)"],
            environment: env, directory: stage, timeout: 600)
        try requireSuccess(output, "\(tool.title) 安装失败")
        try Task.checkCancellation()
        let destination = toolchain.root.appendingPathComponent("\(tool.rawValue)-\(tool.pinnedVersion)-\(UUID().uuidString)")
        try fm.moveItem(at: stage, to: destination)
        var activated = false
        defer { if !activated { try? fm.removeItem(at: destination) } }
        let entry = destination.appendingPathComponent("node_modules/\(tool.package)/\(tool.entry)")
        let bin = destination.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let wrapper = bin.appendingPathComponent(tool.command)
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let runtimePath = nodeURL.deletingLastPathComponent().path + ":"
            + destination.appendingPathComponent("node_modules/.bin").path
        let script = "#!/bin/sh\nexport PATH=\(quote(runtimePath)):\"$PATH\"\nexec \(quote(node)) \(LocalToolchain.nodeNetworkArguments.joined(separator: " ")) \(quote(entry.path)) \"$@\"\n"
        try Data(script.utf8).write(to: wrapper)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let version = try await ToolProcess.run(wrapper.path, ["--version"], environment: toolchain.environment(), timeout: 30)
        try requireSuccess(version, "\(tool.title) 启动失败")
        guard version.stdout.contains(tool.pinnedVersion) else {
            throw ToolProcess.Failure.failed("\(tool.title) 版本校验失败，请重试。")
        }
        try Task.checkCancellation()
        let marker = LocalToolchain.Activation(executable: wrapper.path, node: node, version: tool.pinnedVersion)
        try JSONEncoder().encode(marker).write(to: toolchain.marker(tool), options: .atomic)
        activated = true
    }
}
