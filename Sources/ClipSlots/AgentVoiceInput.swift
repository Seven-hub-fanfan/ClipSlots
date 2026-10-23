import Foundation
import Speech
import AVFoundation
import AudioToolbox

@MainActor
final class AgentVoiceInput: ObservableObject {
    static let activityChangedNotification = Notification.Name("com.clipslots.agent.voiceActivityChanged")
    private static var recordingInputs = Set<UUID>()
    private static var inputLevels: [UUID: Double] = [:]
    static var anyRecording: Bool { !recordingInputs.isEmpty }
    static var recordingLevel: Double { inputLevels.values.max() ?? 0 }
    private let inputID = UUID()
    @Published private(set) var isRecording = false {
        didSet {
            if isRecording { Self.recordingInputs.insert(inputID) }
            else {
                Self.recordingInputs.remove(inputID)
                Self.inputLevels.removeValue(forKey: inputID)
            }
            if oldValue != isRecording {
                NotificationCenter.default.post(name: Self.activityChangedNotification, object: nil)
            }
        }
    }
    @Published private(set) var isStarting = false
    @Published private(set) var isFinishing = false
    @Published private(set) var error: String?
    let levels = VoiceRecordingLevels()
    @Published private(set) var deviceName = "麦克风"
    private let engine = AVAudioEngine()
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var hasTap = false
    private var generation = UUID()
    private var timeout: Task<Void, Never>?
    private var meter: VoiceCaptureMeter?
    private var meterTimer: Timer?
    private var recognizedText = ""
    private var startTask: Task<Void, Never>?
    private let speechPermission: () async -> Bool
    private let microphonePermission: () async -> Bool

    init(speechPermission: @escaping () async -> Bool = AgentVoiceInput.authorizeSpeech,
         microphonePermission: @escaping () async -> Bool = AgentVoiceInput.authorizeMicrophone) {
        self.speechPermission = speechPermission
        self.microphonePermission = microphonePermission
    }

    private static func authorizeSpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        @unknown default: return false
        }
    }

    private static func authorizeMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default: return false
        }
    }

    func start(onText: @escaping (String) -> Void) {
        guard !isRecording, !isStarting else { return }
        error = nil; isStarting = true; isFinishing = false; recognizedText = ""; levels.audioLevel = 0
        let ticket = UUID(); generation = ticket
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, self?.generation == ticket else { return }
            self?.finish("语音输入启动超时，请检查系统授权后重试。")
        }
        startTask = Task {
            let authorized = await speechPermission()
            guard !Task.isCancelled, generation == ticket else { return }
            guard authorized else { finish("请在系统设置中允许 ClipSlots 使用语音识别。"); return }
            let microphone = await microphonePermission()
            guard !Task.isCancelled, generation == ticket else { return }
            guard microphone else { finish("请在系统设置中允许 ClipSlots 使用麦克风。"); return }
            guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable,
                  recognizer.supportsOnDeviceRecognition else {
                finish("当前语言的本地语音识别不可用，请在系统设置中下载语音资源。"); return
            }
            let audio = SFSpeechAudioBufferRecognitionRequest()
            audio.requiresOnDeviceRecognition = true
            audio.shouldReportPartialResults = true
            request = audio
            let input = engine.inputNode
            var captureDevice: UInt32?
            if ProcessInfo.processInfo.environment["CLIPSLOTS_VOICE_DIAGNOSTICS_DIRECTORY"] != nil,
               let raw = ProcessInfo.processInfo.environment["CLIPSLOTS_VOICE_DIAGNOSTICS_INPUT_DEVICE"],
               var device = UInt32(raw), let unit = input.audioUnit {
                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<UInt32>.size))
                guard status == noErr else { finish("测试输入设备不可用（\(status)）。"); return }
                captureDevice = device
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                finish("未找到可用的麦克风。"); return
            }
            let capture: VoiceCaptureMeter
            do { capture = try VoiceCaptureMeter(format: format, deviceID: captureDevice) }
            catch { finish(error.localizedDescription); return }
            meter = capture; deviceName = capture.deviceName
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                capture.consume(buffer)
                audio.append(buffer)
            }
            hasTap = true
            recognition = recognizer.recognitionTask(with: audio) { [weak self] result, failure in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let message = failure?.localizedDescription
                Task { @MainActor in
                    guard let self, self.generation == ticket else { return }
                    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.recognizedText = text
                        onText(text)
                    }
                    if final || message != nil { self.finish(message) }
                }
            }
            do {
                engine.prepare(); try engine.start()
                isStarting = false; isRecording = true
                startTask = nil
                timeout?.cancel()
                let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.isRecording, self.generation == ticket else { return }
                        let level = self.meter?.level ?? 0
                        self.levels.audioLevel = level
                        Self.inputLevels[self.inputID] = level
                        NotificationCenter.default.post(name: Self.activityChangedNotification, object: nil)
                    }
                }
                meterTimer = timer
                RunLoop.main.add(timer, forMode: .common)
                timeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard !Task.isCancelled, self?.generation == ticket else { return }
                    self?.stop()
                }
            } catch { finish(error.localizedDescription) }
        }
    }

    func stop() {
        guard isRecording else { finish(nil); return }
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio()
        meterTimer?.invalidate(); meterTimer = nil
        isRecording = false; isStarting = true; isFinishing = true
        timeout?.cancel()
        let ticket = generation
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self?.generation == ticket else { return }
            self?.finish(nil)
        }
    }

    func cancel() { finish(nil) }

    private func finish(_ message: String?) {
        generation = UUID()
        startTask?.cancel(); startTask = nil
        timeout?.cancel(); timeout = nil
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio(); request = nil
        recognition?.cancel(); recognition = nil
        meterTimer?.invalidate(); meterTimer = nil
        let captured = meter?.finish(text: recognizedText, error: message)
        meter = nil; levels.audioLevel = 0
        isStarting = false; isFinishing = false; isRecording = false
        error = recognizedText.isEmpty ? message : nil
        if let captured, captured.frames > 0, recognizedText.isEmpty {
            error = captured.peak < 0.001
                ? "未检测到声音，请检查「\(deviceName)」或切换系统输入设备。"
                : "已收到麦克风声音，但未识别出文字，请靠近麦克风重试。"
        }
    }
}
