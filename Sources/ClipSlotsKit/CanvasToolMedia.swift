import Foundation
import AVFoundation

public enum CanvasToolError: LocalizedError {
    case invalid(String), missingMedia, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .missingMedia: return "素材已不可用，请重新导入"
        case .cancelled: return "操作已取消"
        }
    }
}

public enum CanvasToolMedia {
    public static func worker<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    public static func inspect(_ url: URL) async throws -> (duration: Double, video: Bool, size: CGSize) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 86400 else {
            throw CanvasToolError.invalid("素材时长无效或超过 24 小时")
        }
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard !video.isEmpty || !audio.isEmpty else { throw CanvasToolError.invalid("未找到音频或视频轨道") }
        var size = CGSize.zero
        if let track = video.first {
            let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            size = CGSize(width: abs(rect.width), height: abs(rect.height))
        }
        return (duration, !video.isEmpty, size)
    }

    /// Constant memory decoding, independent of the duration of an audio file.
    public static func waveform(_ url: URL, bars: Int = 160) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, bars > 0, bars <= 1024,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)
        else { throw CanvasToolError.invalid("无法读取波形") }
        var peaks = [Float](repeating: 0, count: bars), frame: Int64 = 0
        while frame < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, file.length - frame)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for index in 0..<Int(buffer.frameLength) {
                let bucket = min(bars - 1, Int(Double(frame + Int64(index)) / Double(file.length) * Double(bars)))
                for channel in 0..<Int(buffer.format.channelCount) {
                    let sample = abs(channels[channel][index])
                    if sample.isFinite { peaks[bucket] = max(peaks[bucket], sample) }
                }
            }
            frame += Int64(buffer.frameLength)
        }
        let maximum = max(0.001, peaks.max() ?? 1)
        return peaks.map { min(1, $0 / maximum) }
    }

    public struct Composition {
        public let asset: AVMutableComposition
        public let video: AVMutableVideoComposition?
        public let audio: AVMutableAudioMix
        private let lease: MediaLease
        fileprivate init(asset: AVMutableComposition, video: AVMutableVideoComposition?,
                         audio: AVMutableAudioMix, lease: MediaLease) {
            self.asset = asset; self.video = video; self.audio = audio; self.lease = lease
        }
    }

    public static func composition(_ config: CanvasTimelineConfiguration,
                                   urls: [String: URL]) async throws -> Composition {
        try Task.checkCancellation()
        var validation = CanvasToolConfiguration(); validation.timeline = config
        if let error = validation.validationError(for: .timeline) { throw CanvasToolError.invalid(error) }
        guard !config.clips.isEmpty, config.clips.count <= 500, config.clips.allSatisfy(\.isValid),
              (16...4096).contains(config.width), (16...4096).contains(config.height),
              (1...60).contains(config.fps), config.duration <= 86400
        else { throw CanvasToolError.invalid("时间线参数无效") }
        let output = AVMutableComposition()
        let lease = try MediaLease()
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var audioParams: [AVMutableAudioMixInputParameters] = []
        for clip in config.clips {
            try Task.checkCancellation()
            guard let url = urls[clip.attachmentID] else { throw CanvasToolError.missingMedia }
            let readable = try lease.readable(url, id: clip.attachmentID, name: clip.name)
            let asset = AVURLAsset(url: readable), assetDuration = try await asset.load(.duration).seconds
            guard assetDuration.isFinite, clip.sourceEnd <= assetDuration + 0.001 else {
                throw CanvasToolError.invalid("「\(clip.name)」裁剪范围超过素材时长")
            }
            let range = CMTimeRange(start: CMTime(seconds: clip.sourceStart, preferredTimescale: 60000),
                                    duration: CMTime(seconds: clip.duration, preferredTimescale: 60000))
            let start = CMTime(seconds: clip.timelineStart, preferredTimescale: 60000)
            if !clip.isAudio {
                guard let source = try await asset.loadTracks(withMediaType: .video).first,
                      let track = output.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
                else { throw CanvasToolError.invalid("视频轨道不可用") }
                try track.insertTimeRange(range, of: source, at: start)
                let transform = try await source.load(.preferredTransform)
                let naturalSize = try await source.load(.naturalSize)
                let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform)
                guard bounds.width != 0, bounds.height != 0 else { throw CanvasToolError.invalid("视频尺寸无效") }
                let scale = min(CGFloat(config.width) / abs(bounds.width), CGFloat(config.height) / abs(bounds.height))
                let fitted = transform
                    .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: (CGFloat(config.width) - abs(bounds.width) * scale) / 2,
                                                   y: (CGFloat(config.height) - abs(bounds.height) * scale) / 2))
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layer.setTransform(fitted, at: start)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: start, duration: range.duration)
                instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
                instruction.layerInstructions = [layer]
                instructions.append(instruction)
            }
            if let source = try await asset.loadTracks(withMediaType: .audio).first,
               let track = output.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try track.insertTimeRange(range, of: source, at: start)
                let parameter = AVMutableAudioMixInputParameters(track: track)
                parameter.setVolume(Float(clip.volume), at: start); audioParams.append(parameter)
            }
        }
        var video: AVMutableVideoComposition?
        if !instructions.isEmpty {
            let ordered = instructions.sorted { $0.timeRange.start < $1.timeRange.start }
            var cursor = CMTime.zero, complete: [AVMutableVideoCompositionInstruction] = []
            for instruction in ordered {
                guard instruction.timeRange.start >= cursor else {
                    throw CanvasToolError.invalid("视频片段重叠，请调整顺序")
                }
                if instruction.timeRange.start > cursor {
                    let gap = AVMutableVideoCompositionInstruction()
                    gap.timeRange = CMTimeRange(start: cursor, end: instruction.timeRange.start)
                    gap.backgroundColor = CGColor(gray: 0, alpha: 1); gap.layerInstructions = []
                    complete.append(gap)
                }
                complete.append(instruction); cursor = instruction.timeRange.end
            }
            if cursor.seconds < config.duration {
                let gap = AVMutableVideoCompositionInstruction()
                gap.timeRange = CMTimeRange(start: cursor, end: CMTime(seconds: config.duration, preferredTimescale: 60000))
                gap.backgroundColor = CGColor(gray: 0, alpha: 1); gap.layerInstructions = []; complete.append(gap)
            }
            let composition = AVMutableVideoComposition()
            composition.renderSize = CGSize(width: config.width, height: config.height)
            composition.frameDuration = CMTime(value: 1, timescale: Int32(config.fps))
            composition.instructions = complete; video = composition
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = audioParams
        return Composition(asset: output, video: video, audio: mix, lease: lease)
    }

    public static func export(_ composition: Composition, to url: URL) async throws {
        try Task.checkCancellation()
        guard let exporter = AVAssetExportSession(asset: composition.asset,
            presetName: composition.video == nil ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality)
        else { throw CanvasToolError.invalid("无法创建导出器") }
        exporter.outputURL = url; exporter.outputFileType = composition.video == nil ? .m4a : .mp4
        exporter.videoComposition = composition.video; exporter.audioMix = composition.audio
        exporter.shouldOptimizeForNetworkUse = true
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                exporter.exportAsynchronously {
                    switch exporter.status {
                    case .completed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CanvasToolError.cancelled)
                    default: continuation.resume(throwing: exporter.error ?? CanvasToolError.invalid("导出失败"))
                    }
                }
            }
        }, onCancel: { exporter.cancelExport() })
    }
}

private final class MediaLease {
    private let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipslots-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func readable(_ url: URL, id: String, name: String) throws -> URL {
        guard url.pathExtension.lowercased() == "bin" else { return url }
        let ext = (name as NSString).pathExtension.lowercased()
        guard ["mp4","mov","m4v","wav","mp3","m4a","aiff","aif","caf","aac","flac"].contains(ext) else {
            throw CanvasToolError.invalid("素材格式无法解码")
        }
        let target = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor public final class CanvasSpeechExporter {
    private var synthesizer: AVSpeechSynthesizer?
    private var finish: ((Result<URL, Error>) -> Void)?
    public init() {}
    public func cancel() {
        synthesizer?.stopSpeaking(at: .immediate)
        finish?(.failure(CanvasToolError.cancelled)); finish = nil; synthesizer = nil
    }
    public func export(_ config: CanvasAudioConfiguration, to url: URL) async throws -> URL {
        try Task.checkCancellation()
        var validation = CanvasToolConfiguration(); validation.audio = config
        if let error = validation.validationError(for: .audio) { throw CanvasToolError.invalid(error) }
        guard !config.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, config.text.count <= 30000
        else { throw CanvasToolError.invalid("请输入配音文字（最多 30,000 字）") }
        guard synthesizer == nil else { throw CanvasToolError.invalid("配音正在导出") }
        let utterance = AVSpeechUtterance(string: config.text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: config.voiceID)
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = Float(min(AVSpeechUtteranceMaximumSpeechRate,
                                  max(AVSpeechUtteranceMinimumSpeechRate, Float(config.rate))))
        utterance.pitchMultiplier = Float(min(2, max(0.5, config.pitch)))
        utterance.volume = Float(min(1, max(0, config.volume)))
        let engine = AVSpeechSynthesizer(); synthesizer = engine
        let sink = SpeechSink(url: url)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                finish = { [weak self] result in
                    guard let self, self.finish != nil else { return }
                    self.finish = nil; self.synthesizer = nil; continuation.resume(with: result)
                }
                engine.write(utterance) { [weak self] buffer in
                    if let result = sink.consume(buffer) {
                        DispatchQueue.main.async { self?.finish?(result) }
                    }
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
    }
}

private final class SpeechSink {
    let url: URL; private let lock = NSLock()
    private var file: AVAudioFile?; private var ended = false
    init(url: URL) { self.url = url }
    func consume(_ buffer: AVAudioBuffer) -> Result<URL, Error>? {
        lock.lock(); defer { lock.unlock() }
        guard !ended, let pcm = buffer as? AVAudioPCMBuffer else { return nil }
        do {
            if pcm.frameLength == 0 {
                ended = true; let written = file != nil; file = nil
                return written ? .success(url) : .failure(CanvasToolError.invalid("系统语音未输出音频"))
            }
            if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings) }
            try file?.write(from: pcm); return nil
        } catch { ended = true; file = nil; return .failure(error) }
    }
}
