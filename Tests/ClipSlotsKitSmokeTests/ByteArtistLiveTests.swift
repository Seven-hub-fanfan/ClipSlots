import Foundation
import ClipSlotsKit

/// Explicit opt-in local provisioning plus read-only official CLI checks.
/// Never calls submit/run, refreshes auth or sends notifications.
func runByteArtistLiveTests(_ t: TestRunner) {
    guard ProcessInfo.processInfo.environment["CLIPSLOTS_BA_LIVE_PROVISION"] == "1" else {
        t.check(false, "BA live provisioning requires explicit environment opt-in")
        return
    }
    let error: String? = smokeAwait {
        do {
            let chain = LocalToolchain()
            try await LocalToolchainInstaller(toolchain: chain).install([.ba]) { text in
                print("[BA] \(text)"); fflush(stdout)
            }
            let status = await chain.detect(.ba)
            guard status.ready else { return status.issue ?? "BA not ready" }
            print("[BA] version: \(status.version ?? "")"); fflush(stdout)
            let runtime = try ByteArtistRuntime()
            try await runtime.adapter.preflight()
            let candidates = try await runtime.adapter.localReferences()
            print("[BA] authenticated; local references: \(candidates.count)"); fflush(stdout)
            if let id = ProcessInfo.processInfo.environment["CLIPSLOTS_BA_LIVE_WORKFLOW"] {
                guard candidates.contains(where: { $0.id == id }) else { return "Requested workflow is not in CLI references" }
                try await runtime.adapter.refreshReference(id: id)
                let capabilities = try await runtime.adapter.discover()
                guard let capability = capabilities.first(where: { $0.id == id }) else { return "Imported reference missing" }
                var config = ByteArtistCanvasConfiguration(); config.select(capability)
                let request = try await runtime.prepare(configuration: config, capability: capability,
                    prompt: "ClipSlots read-only integration validation", images: [], firstFrame: nil, lastFrame: nil)
                print("[BA] prepared \(capability.id); \(request.input.values.count) typed input(s); NO SUBMISSION")
            }
            return nil
        } catch { return error.localizedDescription }
    }
    t.check(error == nil, "BA private install and read-only preflight/prepare: \(error ?? "passed")")
}
