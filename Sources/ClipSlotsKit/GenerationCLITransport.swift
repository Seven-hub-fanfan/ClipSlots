import Foundation

public struct GenerationCLIInvocation: Sendable {
    public let arguments: [String]
    public let environment: [String: String]
    public let directory: URL
    public let timeout: TimeInterval
    public let submitting: Bool
    public init(arguments: [String], environment: [String: String], directory: URL,
                timeout: TimeInterval, submitting: Bool = false) {
        self.arguments = arguments; self.environment = environment; self.directory = directory
        self.timeout = timeout; self.submitting = submitting
    }
}

public typealias GenerationCLIExecutor = @Sendable (GenerationCLIInvocation) async throws -> ToolProcess.Output

/// Shared process budget for both adapters. App wiring can inject the existing Crate
/// limiter rather than creating a second independent process budget.
public struct GenerationCLITransport: Sendable {
    private let nodePath: String
    private let entryPath: String
    private let limiter: AsyncWorkLimiter

    public init(nodePath: String, entryPath: String, limiter: AsyncWorkLimiter) throws {
        guard nodePath.hasPrefix("/"), entryPath.hasPrefix("/"),
              !nodePath.contains("\0"), !entryPath.contains("\0") else {
            throw GenerationAdapterError.invalidConfiguration("Node 和 CLI 入口必须为绝对路径。")
        }
        self.nodePath = nodePath; self.entryPath = entryPath; self.limiter = limiter
    }
    public func execute(_ invocation: GenerationCLIInvocation) async throws -> ToolProcess.Output {
        try await limiter.withPermit {
            guard FileManager.default.isExecutableFile(atPath: nodePath),
                  FileManager.default.isReadableFile(atPath: entryPath) else {
                throw GenerationAdapterError.processNotStarted
            }
            do {
                try FileManager.default.createDirectory(at: invocation.directory, withIntermediateDirectories: true)
                // Once a submitting command has started, a stopped process may have
                // printed task_created. Keep captured output so the ID is recoverable.
                return try await ToolProcess.run(nodePath,
                    LocalToolchain.nodeNetworkArguments + [entryPath] + invocation.arguments,
                    environment: invocation.environment, directory: invocation.directory,
                    timeout: invocation.timeout, outputLimit: 4_194_304,
                    captureStoppedOutput: invocation.submitting)
            } catch is CancellationError {
                // ToolProcess only throws cancellation before launch when capture is enabled.
                throw CancellationError()
            } catch ToolProcess.Failure.timeout {
                throw GenerationAdapterError.timeout
            } catch {
                // After launch ToolProcess returns captured output; other thrown errors
                // originate from directory creation or Process.run, before submission.
                throw GenerationAdapterError.processNotStarted
            }
        }
    }
    public var executor: GenerationCLIExecutor { { try await self.execute($0) } }
}

enum GenerationAdapterRuntime {
    static func environment() -> [String: String] {
        var env = LocalToolchain().environment()
        // Provider credentials and native runtime overrides must not leak between adapters.
        for key in ["CRATE_TOKEN", "CRATE_USER", "CRATE_ENV", "CRATE_BASE_URL", "BA_REFERENCES_DIR",
                    "BA_CLI_TASK_CACHE_FILE", "BA_CLI_AUTH_BASE_DIR", "BA_CLI_CREDENTIAL_FILE",
                    "BYTEARTIST_API_BASE", "BYTECLOUD_AUTH_RPC_BINARY", "BYTECLOUD_CORE_RPC_BINARY"] {
            env.removeValue(forKey: key)
        }
        env["NO_COLOR"] = "1"
        return env
    }
    static func output(_ output: ToolProcess.Output) throws -> String {
        if output.stopped { throw GenerationAdapterError.timeout }
        if output.truncated { throw GenerationAdapterError.invalidResponse }
        if output.status != 0 {
            if let objects = try? GenerationWire.objects(output.stdout),
               let error = objects.reversed().compactMap(GenerationWire.error).first { throw error }
            if output.status == 2 { throw GenerationAdapterError.authenticationRequired }
            throw GenerationAdapterError.commandFailed(code: "EXIT_\(output.status)", phase: nil)
        }
        return output.stdout
    }
    static func file(_ path: String) throws -> GenerationInputFile {
        guard path.hasPrefix("/"), FileManager.default.isReadableFile(atPath: path),
              (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw GenerationAdapterError.invalidInput("素材必须是可读取的本地普通文件。")
        }
        return GenerationInputFile(path: path, version: GenerationRunContext.fileVersion(path))
    }
}
