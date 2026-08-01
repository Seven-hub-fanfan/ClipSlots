import Foundation

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
/// This actor bounds the number of concurrent decodes to a small, core-count-derived cap. Callers
/// `await limiter.run { ... }`; excess callers suspend (cheaply, no thread blocked) until a permit
/// frees. The decode work itself still runs on `Task.detached`, so the actor's executor is never
/// occupied by CPU-heavy work — the actor only hands out permits.
///
/// Correctness / no-leak notes:
/// - `run(_:)` always calls `release()` after `body` returns; `body` is non-throwing so there is no
///   early-exit path that could leak a permit.
/// - The awaited suspension points (`acquire()`'s continuation and the caller's own detached
///   `.value`) are not resumed by cancellation, so a cancelled caller still balances acquire/release.
actor ThumbnailDecodeLimiter {
    static let shared = ThumbnailDecodeLimiter()

    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Cap = half the active cores, clamped to [2, 6]. Enough parallelism to keep the grid
    /// filling quickly, low enough to never let a burst of decodes swamp CPU/memory.
    init(limit: Int? = nil) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let resolved = limit ?? min(6, max(2, cores / 2))
        self.limit = resolved
        self.available = resolved
    }

    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    private func release() {
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            cont.resume()
        } else {
            available += 1
        }
    }

    /// Acquire a permit, run `body` (which should perform / await the actual decode), then release.
    func run<T>(_ body: @Sendable () async -> T) async -> T {
        await acquire()
        let result = await body()
        release()
        return result
    }
}
