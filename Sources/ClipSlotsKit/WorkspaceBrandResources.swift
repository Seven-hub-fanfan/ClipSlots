import Foundation

public enum WorkspaceBrandResources {
    public static var markURL: URL? {
        let relative = "ClipSlots_ClipSlotsKit.bundle/Resources/WorkspaceBrandMark.png"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(relative),
            Bundle.main.bundleURL.appendingPathComponent(relative)
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            ?? Bundle.module.url(forResource: "WorkspaceBrandMark", withExtension: "png",
                                 subdirectory: "Resources")
    }
}
