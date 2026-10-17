import SwiftUI
import ClipSlotsKit

struct CanvasLiveDocumentView<Content: View>: View {
    @ObservedObject var document: CanvasTextDocument
    @ViewBuilder let content: (String, Binding<String>) -> Content
    var body: some View {
        content(document.text, Binding(get: { document.text }, set: { document.edit($0) }))
    }
}

/// Native editing with a single explicit AI entry point. Both editors bind to
/// the same slot document; the composer never owns a second prompt draft.
struct CanvasTextComposer: View {
    private typealias TapSkin = CanvasSkin
    @ObservedObject var document: CanvasTextDocument
    let node: CanvasNode
    let editing: Bool
    let maximumEditorHeight: CGFloat
    let onBegin: () -> Void
    let onEnd: () -> Void
    let onPolish: () -> Void
    let onStop: () -> Void
    let onHeightChange: (CGFloat) -> Void
    @State private var editorHeight: CGFloat = 112
    @State private var showingError = false
    @State private var backendRevision: UInt = 0
    @AppStorage(AgentPreferences.modelKey) private var model = AgentConfig.defaultModel

    private var busy: Bool {
        switch node.state {
        case .queued, .running: return true
        default: return false
        }
    }
    private var error: String? {
        if let error = document.saveError { return error }
        if case .failed(let reason) = node.state { return reason }
        return nil
    }
    private var backend: AgentBackendKind {
        _ = backendRevision
        return AgentBackendCoordinator.kind(for: .sidebar)
    }
    private var modelLabel: String {
        switch backend {
        case .deepseek: return model
        case .tika: return "Tika Agent"
        case .gateway: return "可恢复 Agent"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft").foregroundColor(TapSkin.secondaryInk)
                Text("文本").font(.system(size: 12, weight: .medium))
                Spacer()
                if busy {
                    Button("取消", action: onStop)
                        .buttonStyle(.plain).font(.system(size: 11))
                        .foregroundColor(TapSkin.secondaryInk)
                        .canvasControlRegion("composer-polish-cancel")
                }
                AgentPolishButton(busy: busy,
                                  enabled: !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  action: onPolish)
                .accessibilityIdentifier("canvas-ai-polish")
                .help("使用当前画布 Agent 的模型润色正文")
                .canvasControlRegion("composer-polish")
            }
            CanvasPromptEditor(
                text: Binding(get: { document.text }, set: { document.edit($0) }),
                font: .systemFont(ofSize: 13),
                onCommit: finishEditing, onCancel: finishEditing, onBlur: finishEditing,
                autoFocus: editing, placeholder: "输入内容，实时同步到文本节点…",
                onFocus: onBegin, returnInsertsNewline: true, allowsLiveReplacement: true,
                maximumHeight: maximumEditorHeight,
                onHeightChange: { editorHeight = $0 })
                .frame(height: min(editorHeight, maximumEditorHeight))
                .tapCursor(.iBeam)
            HStack(spacing: 8) {
                Menu {
                    if backend == .deepseek {
                        ForEach(AgentConfig.modelPresets) { preset in
                            Button(preset.id) { model = preset.id }
                        }
                    } else {
                        Text(backend == .tika ? "模型由 Tika 服务配置" : "模型在 Agent 网关设置中配置")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text(modelLabel).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(busy)
                .help("与画布 Agent 共用模型设置")
                .canvasControlRegion("composer-text-model")
                Spacer(minLength: 4)
                if let error {
                    Button {
                        showingError = true
                    } label: {
                        Label(document.saveError == nil ? "润色未完成" : "保存未完成", systemImage: "exclamationmark.circle")
                            .font(.system(size: 11)).foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingError) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(error).font(.system(size: 12)).textSelection(.enabled)
                            if document.saveError != nil {
                                Button("重试保存") { document.saveSoon(); showingError = false }
                            }
                        }.padding(16).frame(width: 320)
                    }
                } else {
                    Text("实时同步").font(.system(size: 10)).foregroundColor(TapSkin.chromeInkDim)
                }
            }.frame(height: 26)
        }
        .padding(16)
        .foregroundColor(TapSkin.chromeInk)
        .background(TapSkin.cardEmptyFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(editing ? Color.blue.opacity(0.45) : TapSkin.border, lineWidth: 1))
        .overlay {
            ComposerEntranceGlow(token: "\(node.id):\(busy)", active: busy, repeating: true)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .onChange(of: editorHeight) { onHeightChange(min($0, maximumEditorHeight) + 108) }
        .onChange(of: maximumEditorHeight) { onHeightChange(min(editorHeight, $0) + 108) }
        .onAppear { onHeightChange(min(editorHeight, maximumEditorHeight) + 108) }
        .onDisappear { document.saveSoon() }
        .onReceive(NotificationCenter.default.publisher(
            for: AgentBackendCoordinator.backendChangedNotification)) { notification in
                let scope = AgentBackendCoordinator.scope(from: notification)
                if scope == nil || scope == .sidebar { backendRevision &+= 1 }
            }
    }

    private func finishEditing() {
        document.saveSoon()
        onEnd()
    }
}
