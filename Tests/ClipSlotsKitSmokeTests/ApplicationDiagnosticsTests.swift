import Foundation
import ClipSlotsKit

func runApplicationDiagnosticsTests(_ t: TestRunner) {
    let marker = "PRIVATE_BODY_TOKEN_SIGNED_URL"
    for domain in [NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain,
                   NSOSStatusErrorDomain, marker] {
        let error = NSError(domain: domain, code: -91, userInfo: [
            NSLocalizedDescriptionKey: marker, NSFilePathErrorKey: "/private/" + marker,
            NSUnderlyingErrorKey: NSError(domain: marker, code: 2)])
        let output = ApplicationDiagnostics.error(error)
        t.check(!output.contains(marker) && !output.contains("/private/") && output.utf8.count < 40,
                "ordinary error log excludes domain, description, nested error and path")
        t.check(output.hasSuffix(":-91"), "ordinary log retains numeric failure code")
    }
    t.equal(ApplicationDiagnostics.error(CancellationError()), "cancelled", "cancelled classification is stable")
}
