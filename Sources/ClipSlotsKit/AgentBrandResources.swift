import Foundation

/// Exact provider artwork from the local reference package, bundled for offline use.
public enum AgentBrandResources {
    public static let identifiers = ["claude", "chatgpt", "deepseek", "workbuddy", "qwenwork"]

    public static func usesTemplateRendering(for identifier: String) -> Bool {
        identifier == "chatgpt" || identifier == "deepseek"
    }

    public static func iconURL(for identifier: String) -> URL? {
        guard identifiers.contains(identifier) else { return nil }
        let relative = "ClipSlots_ClipSlotsKit.bundle/Resources/AgentBrands/\(identifier).png"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(relative),
            Bundle.main.bundleURL.appendingPathComponent(relative)
        ].compactMap { $0 }
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return url
        }
        return Bundle.module.url(forResource: identifier, withExtension: "png",
                                 subdirectory: "Resources/AgentBrands")
    }
}
