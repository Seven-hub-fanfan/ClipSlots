import AppKit
import QuickLookThumbnailing

final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private var cache: [URL: NSImage] = [:]
    private let cacheQueue = DispatchQueue(label: "com.clipslots.thumbnail", qos: .userInitiated)

    func thumbnail(
        for url: URL,
        size: CGSize = CGSize(width: 240, height: 160),
        completion: @escaping (NSImage?) -> Void
    ) {
        cacheQueue.async { [weak self] in
            if let cached = self?.cache[url] {
                DispatchQueue.main.async { completion(cached) }
                return
            }
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
                self?.cacheQueue.async {
                    self?.cache[url] = image
                }
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    func clearCache() {
        cacheQueue.async { [weak self] in
            self?.cache.removeAll()
        }
    }
}
