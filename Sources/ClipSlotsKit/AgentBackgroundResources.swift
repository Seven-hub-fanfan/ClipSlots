import Foundation

/// Approved line artwork, bundled offline.
public enum AgentBackgroundResources {
    public static var pageURL: URL? {
        let relative = "ClipSlots_ClipSlotsKit.bundle/Resources/AgentOnboarding/index.html"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(relative),
            Bundle.main.bundleURL.appendingPathComponent(relative)
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? ClipSlotsResourceBundle.bundle?.url(forResource: "index", withExtension: "html",
                                                   subdirectory: "Resources/AgentOnboarding")
    }
}
