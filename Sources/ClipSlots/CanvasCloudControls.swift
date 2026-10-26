import SwiftUI
import ClipSlotsKit

struct CanvasCloudControls: View {
    @ObservedObject var session: CanvasToolSession
    @Binding var draft: CanvasToolConfiguration
    let isAudio: Bool
    var generateSpeech: (() -> Void)? = nil
    @State private var key = ""
    @State private var showSettings = false
    private var localSpeech: Bool { isAudio && draft.audio.scene == .speech }
    private var providers: [CanvasCloudConfiguration.Provider] {
        isAudio ? (draft.audio.scene == .sound ? [.elevenLabs] : [.elevenLabs, .miniMax]) : [.tripo, .worldLabs]
    }
    private var cloud: Binding<CanvasCloudConfiguration> {
        Binding(get: { draft.cloudGeneration ?? defaults }, set: { draft.cloudGeneration = $0 })
    }
    private var defaults: CanvasCloudConfiguration {
        var value = CanvasCloudConfiguration()
        if !isAudio { value.provider = .tripo; value.mode = .text3D }
        else if draft.audio.scene == .sound { value.mode = .sound; value.duration = 5 }
        return value
    }
    private var modeChoices: [(CanvasCloudConfiguration.Mode, String)] {
        [(.text3D, "文字生 3D"), (.image3D, "图片生 3D"), (.rig, "自动骨骼"), (.animate, "角色动作")]
    }
    private var promptHint: String {
        if localSpeech { return "输入需要配音的文字…" }
        if isAudio { return draft.audio.scene == .sound ? "描述音效、环境和声音变化…" : "描述音乐的情绪、风格和乐器…" }
        return cloud.wrappedValue.mode == .world ? "描述你想探索的 3D 世界…" : "描述模型的外形、材质和细节…"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            prompt
            toolbar
            taskStatus
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(CanvasSkin.chromeFill))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(CanvasSkin.border, lineWidth: 0.5))
        .buttonStyle(CanvasToolButtonStyle()).toggleStyle(.switch).controlSize(.small)
        .onChange(of: draft.audio.scene) { scene in
            guard isAudio, scene != .speech else { return }
            var value = cloud.wrappedValue
            if scene == .sound { value.provider = .elevenLabs }
            let mode: CanvasCloudConfiguration.Mode = scene == .sound ? .sound : .music
            if value.mode != mode {
                value.mode = mode; value.model = ""; value.task = nil
                value.duration = scene == .sound ? 5 : 60
            }
            cloud.wrappedValue = value
        }
        .onChange(of: cloud.wrappedValue.provider) { provider in
            var value = cloud.wrappedValue; value.model = ""; value.task = nil
            value.mode = isAudio ? (draft.audio.scene == .sound ? .sound : .music)
                : provider == .worldLabs ? .world : .text3D
            cloud.wrappedValue = value
        }
        .onChange(of: cloud.wrappedValue.mode) { _ in cloud.wrappedValue.task = nil; cloud.wrappedValue.model = "" }
        .onDisappear { key = "" }
    }
    @ViewBuilder private var prompt: some View {
            if [.rig, .animate].contains(cloud.wrappedValue.mode) && !localSpeech {
                CanvasToolChoice(title: "模型任务", selection: cloud.sourceTaskID, choices: sourceTasks)
                if cloud.wrappedValue.mode == .animate {
                    HStack {
                        CanvasToolChoice(title: "动作", selection: cloud[dynamicMember: \.animation],
                            choices: ["idle", "walk", "run", "jump"].map { ($0, $0) })
                        Toggle("原地动作", isOn: cloud.inPlace)
                    }
                }
            } else {
                CanvasToolPrompt(text: localSpeech ? $draft.audio.text : cloud.prompt, placeholder: promptHint)
            }
    }
    private var toolbar: some View {
            HStack(spacing: 6) {
                if isAudio {
                    CanvasToolChoice(title: "音频场景", selection: $draft.audio.scene,
                        choices: CanvasAudioConfiguration.Scene.allCases.map { ($0, $0.title) })
                }
                if !localSpeech {
                    CanvasToolChoice(title: "服务", selection: cloud.provider, choices: providers.map { ($0, $0.title) })
                    if !isAudio && cloud.wrappedValue.provider == .tripo {
                        CanvasToolChoice(title: "生成方式", selection: cloud.mode, choices: modeChoices)
                    }
                    Button { showSettings.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: key.isEmpty ? "slider.horizontal.3" : "checkmark.circle")
                            Text(isAudio ? "\(Int(cloud.wrappedValue.duration)) s" : "参数")
                        }
                    }
                    .help("模型、参考素材与服务密钥")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { settings }
                    .accessibilityIdentifier("tool-cloud-settings")
                } else {
                    Text("本机配音").font(.system(size: 11)).foregroundColor(CanvasSkin.secondaryInk)
                }
                Spacer(minLength: 0)
                Button {
                    if localSpeech { generateSpeech?() }
                    else if cloud.wrappedValue.task == nil { generate(resume: false) }
                    else { generate(resume: true) }
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .foregroundColor(CanvasSkin.onAccent).background(Circle().fill(CanvasSkin.accent))
                }
                .buttonStyle(.plain)
                .disabled(generationDisabled)
                .help(localSpeech ? "生成配音到节点" : cloud.wrappedValue.task == nil ? "开始云生成" : "继续查询任务")
                .accessibilityLabel(localSpeech ? "生成配音" : cloud.wrappedValue.task == nil ? "开始云生成" : "继续查询任务")
                .accessibilityIdentifier("tool-generate")
            }
    }
    private var generationDisabled: Bool {
        if session.busy { return true }
        if localSpeech { return draft.audio.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return key.isEmpty || (cloud.wrappedValue.task?.id == nil && cloud.wrappedValue.task != nil)
    }
    @ViewBuilder private var taskStatus: some View {
            if !localSpeech {
                if let task = cloud.wrappedValue.task {
                    HStack {
                        Text("任务：\(task.id ?? "提交结果未知") · \(task.state.rawValue)").textSelection(.enabled).lineLimit(1)
                        Spacer(minLength: 0)
                        Button("新建任务") { cloud.wrappedValue.task = nil }
                    }.font(.system(size: 10)).foregroundColor(CanvasSkin.secondaryInk)
                    if task.state == .unknown {
                        Text("先在服务控制台确认提交结果，再新建任务，避免重复扣费。")
                            .font(.system(size: 10)).foregroundColor(CanvasSkin.secondaryInk)
                    }
                } else if key.isEmpty {
                    Text("在参数中填写服务密钥后生成").font(.system(size: 10)).foregroundColor(CanvasSkin.faintInk)
                }
            }
    }
    private var sourceTasks: [(String?, String)] {
        [(nil, "选择模型任务")] + (draft.cloudResources ?? [:]).keys.sorted().compactMap { id in
            guard let resource = draft.cloudResources?[id], resource.provider == .tripo, let task = resource.taskID else { return nil }
            return (Optional(task), session.attachments.first(where: { $0.id.uuidString == id })?.name ?? task)
        }
    }
    private func generate(resume: Bool) {
        draft.cloudGeneration = cloud.wrappedValue
        if session.save(draft, detail: "保存云生成参数") { session.generateCloud(key: key, resume: resume) }
    }
    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("生成参数").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { showSettings = false } label: { Image(systemName: "xmark") }.help("关闭参数")
                }
                if !cloud.wrappedValue.supportedModels.isEmpty {
                    CanvasToolChoice(title: "模型", selection: cloud.model,
                        choices: [("", "默认 · \(cloud.wrappedValue.supportedModels.first ?? "")")]
                        + cloud.wrappedValue.supportedModels.map { ($0, $0) })
                }
                if cloud.wrappedValue.mode == .image3D {
                    CanvasToolChoice(title: "参考图", selection: cloud.inputAttachmentID,
                        choices: [(String?.none, "选择参考图")] + session.attachments
                            .filter { ["png", "jpg", "jpeg"].contains(($0.name as NSString).pathExtension.lowercased()) }
                            .map { (Optional($0.id.uuidString), $0.name) })
                    Button("导入参考图") {
                        draft.cloudGeneration = cloud.wrappedValue
                        if session.save(draft, detail: "保存参考图参数") { session.chooseReferenceImage() }
                    }
                }
                if isAudio {
                    HStack {
                        Text("时长 / 秒")
                        Spacer()
                        TextField("时长", value: cloud.duration, format: .number).frame(width: 90)
                    }
                    Toggle("纯音乐", isOn: cloud.instrumental).disabled(cloud.wrappedValue.mode == .sound)
                    if cloud.wrappedValue.provider == .miniMax && !cloud.wrappedValue.instrumental {
                        CanvasToolPrompt(text: cloud.lyrics, placeholder: "输入歌词…")
                    }
                    if cloud.wrappedValue.provider == .miniMax {
                        Text("MiniMax 音乐自 2026-08-20 起仅对已有付费账号开放。")
                            .font(.system(size: 10)).foregroundColor(CanvasSkin.secondaryInk)
                    }
                } else if cloud.wrappedValue.provider == .tripo {
                    Toggle("精细纹理", isOn: cloud.detailedTexture)
                } else {
                    CanvasToolChoice(title: "世界点数", selection: cloud.worldQuality, choices: [("100k", "100k"), ("500k", "500k")])
                }
                Divider()
                SecureField("\(cloud.wrappedValue.provider.title) API Key", text: $key)
                    .accessibilityIdentifier("tool-service-key")
                Text("密钥仅在此窗口内使用；关闭窗口后需重新填写。云服务会按账户计费。")
                    .font(.system(size: 10)).foregroundColor(CanvasSkin.secondaryInk)
            }.padding(16)
        }
        .frame(width: 310).frame(maxHeight: 410)
        .background(CanvasSkin.chromeFill).foregroundColor(CanvasSkin.ink)
        .font(.system(size: 11)).textFieldStyle(CanvasToolFieldStyle())
        .buttonStyle(CanvasToolButtonStyle()).toggleStyle(.switch).controlSize(.small)
    }
}
