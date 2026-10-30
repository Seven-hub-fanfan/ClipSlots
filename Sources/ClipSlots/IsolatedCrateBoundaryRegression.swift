#if DEBUG
import Foundation

@MainActor
func runIsolatedCrateBoundaryProbe(check: (Bool, String) -> Void) {
    let env = ProcessInfo.processInfo.environment
    guard let fixture = env["CLIPSLOTS_CRATE_FIXTURE"],
          let digest = env["CLIPSLOTS_CRATE_FIXTURE_SHA256"] else {
        check(false, "isolated fixture identity is configured"); return
    }
    check((try? CrateGenerationService.shared.resolveBinary()) == fixture,
          "copied local Crate fixture passes exact byte validation")
    for key in ["CLIPSLOTS_CRATE_FIXTURE", "CLIPSLOTS_CRATE_FIXTURE_SHA256"] {
        unsetenv(key)
        do {
            _ = try CrateGenerationService.shared.resolveBinary()
            check(false, "\(key) missing must reject production fallback")
        } catch {
            if case CrateGenerationService.ServiceError.invalidTestFixture = error {
                check(true, "\(key) missing rejects production fallback")
            } else { check(false, "\(key) unexpected fixture error") }
        }
        setenv(key, key == "CLIPSLOTS_CRATE_FIXTURE" ? fixture : digest, 1)
    }
    setenv("CLIPSLOTS_CRATE_FIXTURE_SHA256", String(repeating: "0", count: 64), 1)
    do {
        _ = try CrateGenerationService.shared.resolveBinary()
        check(false, "changed fixture bytes must reject production fallback")
    } catch {
        if case CrateGenerationService.ServiceError.invalidTestFixture = error {
            check(true, "changed fixture digest rejects production fallback")
        } else { check(false, "changed fixture unexpected error") }
    }
    setenv("CLIPSLOTS_CRATE_FIXTURE_SHA256", digest, 1)
    check((try? CrateGenerationService.shared.resolveBinary()) == fixture,
          "restoring fixture identity restores local execution")
}
#endif
