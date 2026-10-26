#if DEBUG
import AppKit
import ScreenCaptureKit
import CoreMedia
import Vision

/// Test-only evidence from the window compositor. This API captures only this
/// process's isolated window and does not request Screen Recording permission.
/// A captured sample is not a rendered frame: unchanged pixels are counted
/// separately, and navigation readiness requires OCR of real slot content.
final class OwnWindowCompositorProbe: NSObject, SCStreamOutput {
    private struct Frame {
        let time: Double
        let hash: UInt64
        let readMS: Double
        let image: CGImage?
    }
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var lastHash: UInt64?
    private var imageCount = 0
    private var region = CGRect.zero
    private var retainImages = false
    private var stream: SCStream?
    private var timeScale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    var now: Double { Double(mach_absolute_time()) * timeScale }

    @available(macOS 14.4, *)
    @MainActor static func start(window: NSWindow) async throws -> OwnWindowCompositorProbe {
        let own = try await SCShareableContent.currentProcess
        guard let target = own.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw NSError(domain: "ClipSlots.OwnWindowProbe", code: 1)
        }
        let probe = OwnWindowCompositorProbe()
        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width)
        config.height = Int(target.frame.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = .zero
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target),
                              configuration: config, delegate: nil)
        try stream.addStreamOutput(probe, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "com.clipslots.probe.compositor"))
        probe.stream = stream
        try await stream.startCapture()
        return probe
    }

    func begin(region: CGRect, retainImages: Bool) {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        lastHash = nil
        imageCount = 0
        self.region = region
        self.retainImages = retainImages
        lock.unlock()
    }

    func stop() async { try? await stream?.stopCapture(); stream = nil }

    func exportAnimation(since start: Double, until end: Double, directory: URL) async -> Int {
        let images = snapshot().filter { $0.time >= start && $0.time <= end && $0.image != nil }
        return await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var timing = [[String: Any]]()
            for (index, frame) in images.enumerated() {
                guard let image = frame.image else { continue }
                let name = String(format: "frame-%03d.png", index)
                let bitmap = NSBitmapImageRep(cgImage: image)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent(name))
                timing.append(["file": name, "timeMS": (frame.time - start) * 1000])
            }
            try? JSONSerialization.data(withJSONObject: timing, options: [.prettyPrinted])
                .write(to: directory.appendingPathComponent("timing.json"))
            return timing.count
        }.value
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              let details = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              (details[.status] as? NSNumber)?.intValue == SCFrameStatus.complete.rawValue,
              let ticks = (details[.displayTime] as? NSNumber)?.uint64Value,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let started = now
        lock.lock()
        defer { lock.unlock() }
        guard frames.count < 1500, region.width > 0 else { return }
        let rect = region.integral.intersection(CGRect(x: 0, y: 0,
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
        guard rect.width > 0, rect.height > 0 else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytes = address.assumingMemoryBound(to: UInt8.self)
        let strideBytes = CVPixelBufferGetBytesPerRow(buffer)
        var hash: UInt64 = 14695981039346656037
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 3) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 3) {
                let i = y * strideBytes + x * 4
                hash = (hash ^ UInt64(bytes[i])) &* 1099511628211
                hash = (hash ^ UInt64(bytes[i + 1])) &* 1099511628211
                hash = (hash ^ UInt64(bytes[i + 2])) &* 1099511628211
            }
        }
        var image: CGImage?
        if retainImages && hash != lastHash && imageCount < 96 {
            let width = Int(rect.width), height = Int(rect.height), row = width * 4
            var data = Data(count: row * height)
            data.withUnsafeMutableBytes { destination in
                guard let base = destination.baseAddress else { return }
                for y in 0..<height {
                    memcpy(base.advanced(by: y * row),
                           address.advanced(by: (Int(rect.minY) + y) * strideBytes + Int(rect.minX) * 4), row)
                }
            }
            if let provider = CGDataProvider(data: data as CFData) {
                image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                        .union(.byteOrder32Little), provider: provider, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent)
            }
            imageCount += 1
        }
        lastHash = hash
        frames.append(Frame(time: Double(ticks) * timeScale, hash: hash,
                            readMS: (now - started) * 1000, image: image))
    }

    private func snapshot() -> [Frame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    func report(since start: Double, until end: Double, expectedText: String?,
                directory: URL, name: String) async -> [String: Any] {
        let all = snapshot()
        let collected = all.filter { $0.time >= start && $0.time <= end }
        let baselineHash = all.last(where: { $0.time < start })?.hash
        return await Task.detached(priority: .utility) {
            var changed: [Frame] = []
            var previous = baselineHash
            for frame in collected {
                if previous != frame.hash { changed.append(frame) }
                previous = frame.hash
            }
            let intervals = zip(changed.dropFirst(), changed).map { ($0.time - $1.time) * 1000 }.sorted()
            // Disambiguate Array.last from last(where:). In an Any dictionary
            // Swift can otherwise select the function overload, which isn't JSON.
            let maximumInterval: Double = intervals.last ?? 0
            var result: [String: Any] = [
                "source": "own-window ScreenCaptureKit compositor; actual content-region pixels",
                "completeSamples": collected.count,
                "changedPixelSamples": changed.count,
                "unchangedSamples": collected.count - changed.count,
                "intervalMS": (end - start) * 1000,
                "maxChangedPixelIntervalMS": maximumInterval,
                "p95ChangedPixelIntervalMS": intervals.isEmpty ? 0 : intervals[Int(Double(intervals.count - 1) * 0.95)],
                "maxCaptureReadMS": collected.map(\.readMS).max() ?? 0,
                "note": "Pixel changes include animations. Static intervals are not dropped frames."
            ]
            func save(_ image: CGImage, suffix: String) {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("compositor-\(name)-\(suffix).png"))
            }
            if let image = changed.last?.image { save(image, suffix: "last") }
            if let expectedText {
                func normalized(_ text: String) -> String {
                    text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
                        .map(String.init).joined()
                }
                let expected = normalized(expectedText)
                var found = false
                for frame in changed {
                    guard let image = frame.image else { continue }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = expectedText.unicodeScalars.allSatisfy(\.isASCII)
                        ? ["en-US"] : ["zh-Hans", "en-US"]
                    request.usesLanguageCorrection = false
                    try? VNImageRequestHandler(cgImage: image).perform([request])
                    let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
                    if normalized(text).contains(expected) {
                        result["firstVisibleContentMS"] = (frame.time - start) * 1000
                        result["recognizedText"] = text
                        save(image, suffix: "first-match")
                        found = true
                        break
                    }
                }
                result["expectedText"] = expectedText
                result["contentVerified"] = found
            }
            return result
        }.value
    }
}
#endif
