import SwiftUI
import ClipSlotsKit

struct CanvasModelAPIControls: View {
    let node: CanvasNode
    @ObservedObject var canvas: CanvasStore
    @ObservedObject var models = ModelWorkspaceStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("API 节点参数").font(.system(size: 15, weight: .semibold))
                if let profile = models.canvasProfile(for: node) {
                    InterfaceHelpButton(title: "模型参数映射",
                        text: "\(profile.contract.title)。只有配置中心声明的参数映射会发送给服务。首帧、尾帧及图像 / 视频 / 音频参考按显式映射提交。",
                        identifier: "canvas-api-mapping-help")
                }
                Spacer()
            }
            Picker("模型", selection: Binding(get: { node.modelProfileID ?? "__default__" }, set: { id in edit { $0.modelProfileID = id } })) {
                Text("用途默认模型").tag("__default__")
                ForEach(models.profiles.filter { !$0.isCLI && $0.kind == ModelWorkspaceStore.purpose(for: node).kind }) { Text(ModelCatalogPresentation.text($0.name)).tag($0.id) }
            }
            if let profile = models.canvasProfile(for: node) {
                if node.kind == .image || node.kind == .video {
                    TextField("比例，例如 16:9", text: Binding(get: { node.ratio }, set: { value in edit { $0.ratio = value } }))
                    TextField("分辨率", text: Binding(get: { node.resolution }, set: { value in edit { $0.resolution = value } }))
                }
                if node.kind == .video {
                    TextField("时长 / 秒（留空默认）", text: Binding(get: { node.duration.map(String.init) ?? "" }, set: { value in edit { $0.duration = Int(value) } }))
                    Picker("生成音频", selection: Binding(get: { node.generateAudio.map { $0 ? "true" : "false" } ?? "" }, set: { value in edit { $0.generateAudio = value.isEmpty ? nil : value == "true" } })) {
                        Text("服务默认").tag(""); Text("开启").tag("true"); Text("关闭").tag("false")
                    }
                }
                if let item = models.catalog?.entries.first(where: { $0.id == profile.catalogID }) {
                    DisclosureGroup("目录参数与范围") {
                        Text("只有配置中心声明的参数映射会发送给服务；参考素材按显式映射提交。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        ScrollView { Text((try? item.presentationConfig.encodedText()) ?? "").font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 240)
                    }
                }
            } else { Text("请在配置中心设置此用途模型。").font(.system(size: 11)).foregroundStyle(.secondary) }
        }.padding(16).frame(width: 360).textFieldStyle(.roundedBorder)
    }
    private func edit(_ change: (inout CanvasNode) -> Void) { canvas.updateNode(id: node.id, change); canvas.flushSave() }
}
