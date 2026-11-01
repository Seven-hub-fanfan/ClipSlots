import Foundation

/// SwiftPM places a copied resource bundle beside development executables.
/// Installed GUI, CLI and MCP products share Contents/Resources instead.
enum ClipSlotsResourceBundle {
    static let bundle: Bundle? = {
        let name = "ClipSlots_ClipSlotsKit.bundle"
        let executableDirectory = Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let locations = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            executableDirectory?.deletingLastPathComponent().appendingPathComponent("Resources")
                .appendingPathComponent(name),
            executableDirectory?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name)
        ].compactMap { $0 }
        for location in locations {
            if let bundle = Bundle(url: location) { return bundle }
        }
        #if DEBUG
        // Existing isolated source probes link Kit outside the SwiftPM products
        // directory. Only development builds may use the generated build fallback.
        return Bundle.module
        #else
        return nil
        #endif
    }()
}
