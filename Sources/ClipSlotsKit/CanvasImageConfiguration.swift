import Foundation

/// Reference sizing measured from TapNow's vR helper, applied only to a catalog
/// model that explicitly publishes width and height. Model identities stay unchanged.
public enum CanvasImageConfiguration {
    public static let ratios = ["1:1", "4:3", "3:4", "16:9", "9:16", "3:2", "2:3", "21:9"]
    public static let qualities = ["2K", "3K"]
    public static let splitModels: Set<String> = ["seedream45", "seedream5"]
    /// Captured from both models' published dimension constraints, 2026-10-11.
    public static let seedreamMinimumPixels = 3_686_400
    public struct Selection: Equatable {
        public let ratio: String
        public let quality: String
    }
    public struct Dimensions: Equatable {
        public let width: Int
        public let height: Int
    }
    public static func supportsSplit(_ model: CrateModelCatalog.ModelInfo?) -> Bool {
        guard let model else { return false }
        return splitModels.contains(model.id) && model.isImageGenerator
            && model.parameterNames.contains("width") && model.parameterNames.contains("height")
            && Set(ratios).isSubset(of: Set(model.ratioOptions.map(\.value)))
    }
    public static func selection(ratio: String, resolution: String) -> Selection {
        let parts = ratio.split(separator: " ").map(String.init)
        let aspect = parts.first(where: { ratios.contains($0) }) ?? "1:1"
        let quality = resolution.isEmpty
            ? parts.first(where: { ["1K", "2K", "3K", "4K"].contains($0) }) ?? "2K" : resolution
        return Selection(ratio: aspect, quality: quality)
    }
    public static func dimensions(ratio: String, quality: String,
                                  minimumPixels: Int? = nil) -> Dimensions? {
        let sides: [String: Int] = ["1K": 1024, "2K": 2560, "3K": 3072, "4K": 3840]
        guard ratios.contains(ratio), let long = sides[quality] else { return nil }
        let parts = ratio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        var width = parts[0] >= parts[1] ? long : Int((Double(long) * parts[0] / parts[1]).rounded())
        var height = parts[0] >= parts[1] ? Int((Double(long) * parts[1] / parts[0]).rounded()) : long
        if let minimumPixels, minimumPixels > width * height {
            // Keep the requested shape when the reference long-side preset is
            // below this provider's published minimum image area.
            let scale = sqrt(Double(minimumPixels) / Double(width * height))
            width = Int(ceil(Double(width) * scale))
            height = Int(ceil(Double(height) * scale))
        }
        guard (16...16384).contains(width), (16...16384).contains(height) else { return nil }
        return Dimensions(width: width, height: height)
    }
}
