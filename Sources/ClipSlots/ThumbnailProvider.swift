import AppKit
import QuickLookThumbnailing

final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private var cache: [String: NSImage] = [:]

    func thumbnail(
        for url: URL,
        cacheKey: String,
        size: CGSize = CGSize(width: 240, height: 160),
        completion: @escaping (NSImage?) -> Void
    ) {
        if let cached = cache[cacheKey] {
            completion(cached)
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, error in
            if let error = error {
                NSLog("[ClipSlots] ThumbnailProvider failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
            let image = thumbnail?.nsImage
            if let image = image {
                self?.cache[cacheKey] = image
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    func clearCache() {
        cache.removeAll()
    }
}
