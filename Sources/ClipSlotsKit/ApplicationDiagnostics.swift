import Foundation

/// Ordinary logs must not serialize Error descriptions or userInfo: both may
/// carry prompts, file names, signed URLs and credentials from external tools.
public enum ApplicationDiagnostics {
    public static func error(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        let value = error as NSError
        let family: String
        switch value.domain {
        case NSCocoaErrorDomain: family = "storage"
        case NSURLErrorDomain: family = "network"
        case NSPOSIXErrorDomain: family = "system"
        case NSOSStatusErrorDomain: family = "os"
        default: family = "application"
        }
        return "\(family):\(value.code)"
    }
}
