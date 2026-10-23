import SwiftUI
import ClipSlotsKit

struct CanvasGenerationInput: Equatable {
    let busy: Bool
    let failed: Bool
    let image: SlotContent.SlotAttachment?
    let isImage: Bool
    let reducedMotion: Bool
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.busy == rhs.busy && lhs.failed == rhs.failed && lhs.isImage == rhs.isImage
            && lhs.reducedMotion == rhs.reducedMotion
            && lhs.image?.canvasSourceIdentity == rhs.image?.canvasSourceIdentity
    }
}

/// Owns a generation session independently of SwiftUI's captured view values.
/// Output decoding, timeout, overlay removal and reveal all validate the session.
@MainActor
final class CanvasGenerationHandoff: ObservableObject {
    @Published private(set) var visible = false
    @Published private(set) var opacity = 0.0
    @Published private(set) var baseMedia: SlotContent.SlotAttachment?
    @Published private(set) var previousMedia: SlotContent.SlotAttachment?
    @Published private(set) var prepared = false
    @Published private(set) var revealing = false
    @Published private(set) var imageFailed = false
    private(set) var session = UUID()
    private var busy = false
    private var reduced = false
    private var waiting = false
    private var loadingIdentity: String?
    private var decode: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var removal: Task<Void, Never>?
    private var reveal: Task<Void, Never>?

    func apply(_ input: CanvasGenerationInput) {
        update(busy: input.busy, failed: input.failed, image: input.image,
               isImage: input.isImage, reducedMotion: input.reducedMotion)
    }

    func update(busy: Bool, failed: Bool, image: SlotContent.SlotAttachment?,
                isImage: Bool, reducedMotion: Bool) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPSLOTS_TAPNOW_MOTION_PROBE"] == "1" {
            NSLog("[TapNowMotion] handoff busy=%@ oldBusy=%@ visible=%@ opacity=%@ image=%@",
                  String(busy), String(self.busy), String(visible), String(opacity), image?.name ?? "nil")
        }
        #endif
        reduced = reducedMotion
        if busy {
            guard !self.busy else { return }
            cancelWork()
            session = UUID()
            self.busy = true
            baseMedia = image; previousMedia = image
            prepared = false; revealing = false; imageFailed = false
            loadingIdentity = nil; waiting = false
            visible = true; opacity = 0
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: reduced ? 0.2 : 1.6)) { opacity = 1 }
            return
        }
        self.busy = false
        guard visible, opacity > 0 else { return }
        if failed || !isImage { fade(session); return }
        if !waiting {
            waiting = true
            let ticket = session
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, let self, self.session == ticket, !self.busy else { return }
                self.timeout = nil
                self.fade(ticket)
            }
        }
        loadOutput(image)
    }

    private func loadOutput(_ image: SlotContent.SlotAttachment?, retry: Bool = false) {
        guard let image, image.canvasSourceIdentity != baseMedia?.canvasSourceIdentity,
              retry || image.canvasSourceIdentity != loadingIdentity else { return }
        decode?.cancel()
        loadingIdentity = image.canvasSourceIdentity
        let identity = loadingIdentity, ticket = session
        prepared = true; revealing = false; imageFailed = false
        decode = Task { [weak self] in
            let loaded = await withCheckedContinuation { continuation in
                CanvasAttachmentThumbnails.load(image, maxPixel: 900, retry: retry) {
                    continuation.resume(returning: $0 != nil)
                }
            }
            guard !Task.isCancelled, let self, self.session == ticket,
                  self.loadingIdentity == identity, !self.busy else { return }
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_TAPNOW_MOTION_PROBE"] == "1" {
                NSLog("[TapNowMotion] decoded=%@ session=%@", String(loaded), ticket.uuidString)
            }
            #endif
            guard loaded else { self.imageFailed = true; return }
            self.timeout?.cancel()
            self.fade(ticket)
            self.reveal = Task { [weak self] in
                await CanvasDisplayClock.shared.nextFrame()
                await CanvasDisplayClock.shared.nextFrame()
                guard !Task.isCancelled, let self, self.session == ticket, !self.busy else { return }
                self.revealing = true
                try? await Task.sleep(for: .milliseconds(self.reduced ? 200 : 2100))
                guard !Task.isCancelled, self.session == ticket else { return }
                self.prepared = false; self.previousMedia = nil; self.baseMedia = nil
            }
        }
    }

    func retry(_ image: SlotContent.SlotAttachment?) {
        guard !busy, imageFailed else { return }
        loadOutput(image, retry: true)
    }

    private func fade(_ ticket: UUID) {
        guard session == ticket, !busy else { return }
        timeout?.cancel()
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: reduced ? 0.2 : 1.4)) { opacity = 0 }
        removal?.cancel()
        removal = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(self.reduced ? 200 : 1400))
            guard !Task.isCancelled, self.session == ticket, !self.busy else { return }
            self.visible = false
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_TAPNOW_MOTION_PROBE"] == "1" {
                NSLog("[TapNowMotion] overlay removed session=%@", ticket.uuidString)
            }
            #endif
        }
    }

    func stop() {
        session = UUID(); busy = false
        cancelWork()
        visible = false; opacity = 0; prepared = false; revealing = false
        previousMedia = nil; baseMedia = nil; imageFailed = false
    }

    private func cancelWork() {
        decode?.cancel(); timeout?.cancel(); removal?.cancel(); reveal?.cancel()
        decode = nil; timeout = nil; removal = nil; reveal = nil
    }

    deinit { decode?.cancel(); timeout?.cancel(); removal?.cancel(); reveal?.cancel() }
}
