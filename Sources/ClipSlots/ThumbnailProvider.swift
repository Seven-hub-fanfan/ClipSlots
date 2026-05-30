import AppKit
import QuickLookThumbnailing

final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let lock = NSLock()
    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    /// Generate (or return cached) thumbnail for the given URL.
    ///
    /// - Parameters:
    ///   - url: The file URL to thumbnail.
    ///   - cacheKey: Composite key (`specialSlotId::slot::contentId::updatedAt`) that
    ///     uniquely identifies this slot version. The same key is returned in the
    ///     completion so callers can discard stale results.
    ///   - size: Target thumbnail size (points).
    ///   - completion: Called on the main queue with `(image?, returnedKey)`.
    func thumbnail(
        for url: URL,
        cacheKey: String,
        size: CGSize = CGSize(width: 240, height: 160),
        completion: @escaping (NSImage?, _ returnedKey: String) -> Void
    ) {
        // Fast path: cache hit
        lock.lock()
        if let cached = cache[cacheKey] {
            lock.unlock()
            DispatchQueue.main.async { completion(cached, cacheKey) }
            return
        }

        // Dedup: already loading this key
        guard !inFlight.contains(cacheKey) else {
            lock.unlock()
            return
        }
        inFlight.insert(cacheKey)
        lock.unlock()

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, error in
            guard let self = self else { return }

            if let error = error {
                NSLog("[ClipSlots] ThumbnailProvider failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }

            let image = thumbnail?.nsImage

            self.lock.lock()
            if let image = image {
                self.cache[cacheKey] = image
            }
            self.inFlight.remove(cacheKey)
            self.lock.unlock()

            DispatchQueue.main.async {
                completion(image, cacheKey)
            }
        }
    }

    /// Invalidate all cached thumbnails and in-flight requests for a specific slot.
    func invalidateSlot(specialSlotId: String, slot: Int) {
        let prefix = "\(specialSlotId)::\(slot)::"
        lock.lock()
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        inFlight = inFlight.filter { !$0.hasPrefix(prefix) }
        lock.unlock()
        NSLog("[ClipSlots] ThumbnailProvider invalidateSlot prefix=\(prefix)")
    }

    /// Invalidate all cached thumbnails and in-flight requests for an entire special slot.
    func invalidateSpecialSlot(specialSlotId: String) {
        let prefix = "\(specialSlotId)::"
        lock.lock()
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        inFlight = inFlight.filter { !$0.hasPrefix(prefix) }
        lock.unlock()
        NSLog("[ClipSlots] ThumbnailProvider invalidateSpecialSlot prefix=\(prefix)")
    }

    func clearCache() {
        lock.lock()
        cache.removeAll()
        inFlight.removeAll()
        lock.unlock()
    }
}
