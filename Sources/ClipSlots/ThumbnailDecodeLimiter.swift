import Foundation
import AppKit
import ClipSlotsKit

// MARK: - Thumbnail Decode Limiter (P0-4, v2.10.38)

/// Global concurrency limiter for OFF-main image decodes (grid thumbnails + inline previews).
///
/// Why this exists: every image slot cell (`SlotThumbnailView`) and every inline image preview
/// (`InlineImageView`) spawns its own `Task.detached` that runs a full ImageIO downsample decode.
/// On a large library (hundreds of image slots appearing at once — e.g. right after importing a
/// 1.6GB `.clipslotspack`, or fast-scrolling a big group) this fired *hundreds* of decode tasks
/// simultaneously. Each holds a decoded bitmap + competes for CPU/IO/memory, spiking memory and
/// starving the main thread → the multi-second beachball described in the v2.10.37 analysis.
///
/// This actor bounds concurrent decodes to one or two based on memory and pressure. Callers
/// `await limiter.run { ... }`; excess callers suspend (cheaply, no thread blocked) until a permit
/// frees. The decode work itself still runs on `Task.detached`, so the actor's executor is never
/// occupied by CPU-heavy work — the actor only hands out permits.
///
/// Cancelled queued views leave immediately. Active ImageIO work drains before releasing its
/// permit; focused previews take precedence over list thumbnails without interrupting a decode.
actor ThumbnailDecodeLimiter {
    static let shared = ThumbnailDecodeLimiter()

    private let limiter: AsyncWorkLimiter

    /// Explicit limits are used only by isolated tests.
    init(limit: Int? = nil) {
        if let limit { limiter = AsyncWorkLimiter(limit: limit) }
        else {
            limiter = AsyncWorkLimiter(limit: 2, currentLimit: { ResourceBudget.shared.decodeConcurrency })
        }
    }

    /// Acquire a permit, run `body` (which should perform / await the actual decode), then release.
    func run(priority: Int = 10, _ body: @Sendable () async -> NSImage?) async -> NSImage? {
        try? await limiter.withPermit(priority: priority) {
            let result = await body()
            try Task.checkCancellation()
            return result
        }
    }
}
