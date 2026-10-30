import Foundation

final class TestRunner {
    private var passed = 0
    private var failed = 0

    func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1 }
        else { failed += 1; print("FAIL: \(message)") }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        check(actual == expected, message)
    }

    func report() -> Never {
        print("Gateway fixtures: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

private final class GatewayTestBox<T>: @unchecked Sendable { var value: T? }

func smokeAwait<T>(_ body: @escaping @Sendable () async -> T) -> T {
    let signal = DispatchSemaphore(value: 0)
    let box = GatewayTestBox<T>()
    Task.detached {
        box.value = await body()
        signal.signal()
    }
    signal.wait()
    return box.value!
}

@main
enum GatewayTestMain {
    static func main() {
        let runner = TestRunner()
        runAuthoritativeContextUsageTests(runner)
        runContextCompactionTranscriptTests(runner)
        runTaskSubagentProjectionTests(runner)
        runAgentRunGatewayTests(runner)
        runner.report()
    }
}
