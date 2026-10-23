import AVFoundation
import CoreAudio
import Accelerate
import SwiftUI

/// The audio callback only updates this locked accumulator. UI publication
/// happens at 20Hz in the recording status and native mascot.
final class VoiceCaptureMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: UInt64 = 0
    private var sum: Double = 0
    private var peak: Float = 0
    private var recent: Float = 0
    private var lastBufferTime = 0.0
    private var diagnosticLevels: [Double] = []
    private var file: AVAudioFile?
    private var writeError: String?
    let sampleRate: Double
    let channels: UInt32
    let deviceName: String
    let directory: URL?

    init(format: AVAudioFormat, deviceID: UInt32? = nil) throws {
        sampleRate = format.sampleRate; channels = format.channelCount
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        if let deviceID { device = deviceID }
        var name: CFString = "麦克风" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioObjectPropertyName
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        deviceName = name as String
        if let path = ProcessInfo.processInfo.environment["CLIPSLOTS_VOICE_DIAGNOSTICS_DIRECTORY"], !path.isEmpty {
            let root = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            directory = root
            file = try AVAudioFile(forWriting: root.appendingPathComponent("microphone.caf"), settings: format.settings)
        } else { directory = nil }
    }
    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = vDSP_Length(buffer.frameLength)
        var rms: Float = 0, maximum: Float = 0
        var energy: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var channelRMS: Float = 0, channelPeak: Float = 0
            vDSP_rmsqv(data[channel], 1, &channelRMS, count)
            vDSP_maxmgv(data[channel], 1, &channelPeak, count)
            energy += channelRMS * channelRMS; maximum = max(maximum, channelPeak)
        }
        rms = sqrt(energy / Float(buffer.format.channelCount))
        lock.lock(); defer { lock.unlock() }
        frames += UInt64(buffer.frameLength)
        sum += Double(rms * rms) * Double(buffer.frameLength)
        recent = rms; peak = max(peak, maximum)
        lastBufferTime = ProcessInfo.processInfo.systemUptime
        do { try file?.write(from: buffer) } catch { writeError = error.localizedDescription }
    }
    var level: Double {
        lock.lock(); defer { lock.unlock() }
        let value = ProcessInfo.processInfo.systemUptime-lastBufferTime > 0.2 ? 0 :
            min(1, max(0, (20 * log10(Double(max(recent, 0.00001))) + 52) / 52))
        if directory != nil && diagnosticLevels.count < 1500 { diagnosticLevels.append(value) }
        return value
    }
    func finish(text: String, error: String?) -> (frames: UInt64, peak: Float) {
        lock.lock(); defer { lock.unlock() }
        file = nil
        if let directory {
            let report: [String: Any] = [
                "scope": "formal ClipSlots AVAudioEngine hardware capture",
                "device": deviceName, "sample_rate": sampleRate, "channels": channels,
                "frames": frames, "seconds": Double(frames) / sampleRate,
                "rms": frames == 0 ? 0 : sqrt(sum / Double(frames)), "peak": peak,
                "recognized_text": text, "error": error ?? NSNull(), "write_error": writeError ?? NSNull(),
                "requires_on_device_recognition": true]
            var details = report
            details["observed_levels"] = diagnosticLevels
            details["max_observed_level"] = diagnosticLevels.max() ?? 0
            try? JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("microphone-report.json"))
        }
        return (frames, peak)
    }
}

@MainActor
final class VoiceRecordingLevels: ObservableObject {
    @Published var audioLevel: Double = 0
}

struct VoiceRecordingLevelBar: View {
    @ObservedObject var levels: VoiceRecordingLevels
    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(Color.accentColor.opacity(0.7))
                .frame(width: max(2, proxy.size.width * levels.audioLevel))
        }
        .frame(width: 52, height: 4)
    }
}

struct VoiceRecordingStatus: View {
    @ObservedObject var voice: AgentVoiceInput
    var body: some View {
        if voice.isRecording {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundColor(.accentColor)
                Text("正在录音 · \(voice.deviceName)").font(.system(size: 11))
                VoiceRecordingLevelBar(levels: voice.levels)
                Spacer(minLength: 0)
            }
            .accessibilityLabel("正在录音，\(voice.deviceName)")
        } else if voice.isStarting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(voice.isFinishing ? "正在整理识别文字…" : "正在准备本地语音输入…")
                    .font(.system(size: 11))
                Spacer(minLength: 0)
            }
            .accessibilityLabel(voice.isFinishing ? "正在整理识别文字" : "正在准备本地语音输入")
        }
    }
}
