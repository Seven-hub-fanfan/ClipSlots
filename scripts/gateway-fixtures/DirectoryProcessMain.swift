import Foundation
import Darwin
import ClipSlotsKit

@main enum DirectoryProcessMain {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let mode = CommandLine.arguments[2]
        guard root.path.hasPrefix("/private/tmp/clipslots-directory-process-") else { exit(2) }
        let script: String
        switch mode {
        case "duplex":
            script = """
            import os,sys
            open(sys.argv[1], 'w').write(str(os.getpid()))
            sys.stdout.write('o' * 1048576); sys.stdout.flush()
            data=sys.stdin.buffer.read()
            print('INPUT_BYTES=' + str(len(data)))
            """
        case "descendant", "cancel-descendant":
            script = """
            import os,sys,time,signal
            child=os.fork()
            if child == 0:
                open(sys.argv[1], 'w').write(str(os.getpid()))
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                time.sleep(4)
                os._exit(0)
            print('CHILD=' + str(child), flush=True)
            """
        case "budget":
            script = "import sys; sys.stdout.write('o'*1000000); sys.stderr.write('e'*1000000)"
        case "malformed-output":
            script = "import os; os.write(1,b'\\xff'*10000); os.write(2,b'\\xfe'*10000)"
        case "closed-stdin":
            script = "import os; os.close(0); print('closed')"
        case "blocked-stdin":
            script = """
            import os,sys,signal,time
            open(sys.argv[1], 'w').write(str(os.getpid()))
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(30)
            """
        case "precancelled":
            script = "import sys; open(sys.argv[1], 'w').write('UNAUTHORIZED-LAUNCH')"
        default: exit(2)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let task = Task {
            if mode == "precancelled" {
                while !Task.isCancelled { await Task.yield() }
            }
            return await AgentProcessRunner.run(executable: "/usr/bin/python3",
                arguments: ["-c", script, root.appendingPathComponent("child.pid").path],
                standardInput: ["duplex", "closed-stdin", "blocked-stdin"].contains(mode) ? String(repeating: "i", count: 1048576) : nil,
                timeout: mode == "cancel-descendant" ? 20 : 0.4, maxOutputBytes: 512)
        }
        if mode == "cancel-descendant" {
            try await Task.sleep(for: .milliseconds(200))
            task.cancel()
        }
        if mode == "precancelled" { task.cancel() }
        let result = await task.value
        print(try JSONValue.object([
            "mode": .string(mode), "exitCode": .number(Double(result.exitCode)),
            "seconds": .number(ProcessInfo.processInfo.systemUptime - started),
            "timedOut": .bool(result.timedOut), "succeeded": .bool(result.succeeded),
            "cancelled": .bool(result.cancelled), "outputTruncated": .bool(result.outputTruncated),
            "stdoutBytes": .number(Double(result.stdout.utf8.count)),
            "stderrBytes": .number(Double(result.stderr.utf8.count))
        ]).encodedText())
    }
}
