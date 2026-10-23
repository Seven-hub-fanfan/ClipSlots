import Foundation

public enum CanvasGenerationAssets {
    public static let loadingCSS: String = {
        guard let url = Bundle.module.url(forResource: "node-loading", withExtension: "css",
                                         subdirectory: "Resources/TapNowMotion"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return value
    }()
}
