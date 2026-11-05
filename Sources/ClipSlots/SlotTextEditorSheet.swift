import SwiftUI
import AppKit
import ClipSlotsKit
import ImageIO

struct SlotTextEditorSheet: View {
    @ObservedObject var model: SlotEditorModel
    let onFullScreen: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme
    @StateObject private var voice = AgentVoiceInput()
    @State private var rightTab = 0
    @State private var modelInfo = false
    @State private var dropTarget = false

    private var fill: Color { scheme == .dark ? Color(red: 0.105, green: 0.11, blue: 0.125) : .white }
    private var panel: Color { scheme == .dark ? Color.white.opacity(0.025) : Color(red: 0.978, green: 0.979, blue: 0.985) }
    private var hairline: Color { Color.primary.opacity(scheme == .dark ? 0.10 : 0.075) }
    private var composerFill: Color {
        scheme == .dark ? Color(red: 0.16, green: 0.18, blue: 0.215)
            : Color(red: 240 / 255, green: 244 / 255, blue: 249 / 255)
    }
    private var sideWidth: CGFloat { model.fullScreen ? 286 : 278 }
    private var inset: CGFloat { model.fullScreen ? 34 : 24 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(hairline)
            HStack(spacing: 0) {
                if model.showsOutline { outline.frame(width: 184) }
                VStack(spacing: 0) {
                    editor
                    if let error = model.error {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.circle")
                            Text(error).textSelection(.enabled)
                            Spacer(minLength: 0)
                            icon("xmark", help: "关闭提示") { model.error = nil }
                        }
                        .font(.system(size: 12)).foregroundColor(.orange)
                        .padding(.horizontal, inset).padding(.vertical, 8)
                    }
                    if model.showHistory { history.frame(maxHeight: 180).padding(.horizontal, inset) }
                    composer.padding(.horizontal, inset).padding(.bottom, 24).padding(.top, 16)
                }
                if !model.focused {
                    Divider().overlay(hairline)
                    VStack(spacing: 0) {
                        references
                        Spacer(minLength: 12)
                    }.frame(width: sideWidth)
                }
            }
        }
        .font(.system(size: 13))
        .foregroundColor(.primary)
        .background(fill)
        .disabled(model.saving)
        .onChange(of: model.draft) { _ in model.updateOutline() }
        .onDisappear { voice.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("\(model.snapshot.slot)")
                .font(.system(size: 16, weight: .medium)).frame(width: 38, height: 38)
                .background(panel, in: Circle()).overlay(Circle().stroke(hairline))
            VStack(alignment: .leading, spacing: 4) {
                Text("编辑内容").font(.system(size: 20, weight: .semibold))
                Text("\(model.snapshot.pageName)  /  \(model.snapshot.group.name)  /  槽位 \(model.snapshot.slot)")
                    .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 20)
            if model.fullScreen {
                Button { model.textBridge.commit(); model.focused.toggle() } label: {
                    Label(model.focused ? "退出专注" : "专注模式", systemImage: "scope")
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(panel, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityIdentifier("slot-editor-focus")
            }
            Button(action: onFullScreen) {
                HStack(spacing: 8) {
                    Image(systemName: model.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    if model.fullScreen { Text("退出全屏") }
                }.padding(.horizontal, 10).padding(.vertical, 8)
            }.buttonStyle(.plain).help(model.fullScreen ? "退出全屏" : "全屏编辑")
                .accessibilityLabel(model.fullScreen ? "退出全屏" : "全屏编辑")
                .accessibilityIdentifier("slot-editor-fullscreen")
            if !model.fullScreen { icon("xmark", help: "取消编辑", action: onCancel) }
        }
        .padding(.horizontal, model.fullScreen ? 24 : 22).padding(.vertical, 18)
    }

    private var outline: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("内容大纲").font(.system(size: 11)).foregroundColor(.secondary).padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.outline) { item in
                        Button {
                            model.preview = false
                            model.textBridge.reveal(item.range)
                        } label: {
                            Text(item.title).font(.system(size: 12)).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(model.selectedRange.location >= item.range.location
                                    && model.selectedRange.location < NSMaxRange(item.range)
                                    ? Color.blue.opacity(0.08) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: min(320, CGFloat(model.outline.count) * 42 + 12))
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("当前槽位").font(.system(size: 10)).foregroundColor(.secondary)
                Text(model.snapshot.content.label ?? "槽位 \(model.snapshot.slot)").font(.system(size: 13, weight: .medium))
                Text("\(model.formatName) · \(model.attachments.count) 个附件")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            Spacer()
        }.padding(14).padding(.top, 12).background(panel)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                if model.showsPreviewPicker {
                    Picker("编辑视图", selection: $model.preview) {
                        Text("正文编辑").tag(false)
                        Text("修改预览").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 208)
                        .accessibilityIdentifier("slot-editor-preview-picker")
                } else { Text(model.formatName == "文本" ? "正文" : "\(model.formatName) 正文")
                        .font(.system(size: 14, weight: .semibold)) }
                Spacer()
                icon("arrow.uturn.backward", help: "撤销正文编辑") { model.textBridge.undo() }
                icon("arrow.uturn.forward", help: "重做正文编辑") { model.textBridge.redo() }
                Divider().frame(height: 16)
                icon("magnifyingglass", help: "查找正文 · ⌘F") { model.preview = false; model.textBridge.find() }
            }.padding(.horizontal, inset).padding(.vertical, model.fullScreen ? 16 : 18)
            VStack(spacing: 0) {
              ZStack {
                SlotEditorTextView(text: $model.draft, bridge: model.textBridge,
                    fullScreen: model.fullScreen, html: model.isHTML,
                    onSelection: { range in if model.selectedRange != range { model.selectedRange = range } })
                    .padding(.horizontal, model.fullScreen ? inset : 0)
                    .opacity(model.preview ? 0 : 1)
                    .allowsHitTesting(!model.preview)
                    .accessibilityHidden(model.preview)
                if model.draft.isEmpty && !model.preview {
                    Text("开始编写内容…").foregroundColor(.secondary.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(model.fullScreen ? 36 : 20).allowsHitTesting(false)
                }
                if model.preview, let proposal = model.proposal { proposalView(proposal) }
              }
              HStack(spacing: 10) {
                  if model.dirty {
                      Circle().fill(Color.orange).frame(width: 4, height: 4)
                      Text("未保存修改").font(.system(size: 10)).foregroundColor(.secondary)
                  }
                  Spacer(minLength: 12)
                  Text("\(model.characterCount) 字").font(.system(size: 10)).foregroundColor(.secondary)
                      .padding(.trailing, 8)
                  actions
              }
              .padding(.horizontal, model.fullScreen ? inset : 20).padding(.vertical, 12)
            }
            .background(model.fullScreen ? fill : panel)
            .clipShape(RoundedRectangle(cornerRadius: model.fullScreen ? 0 : 12))
            .overlay {
                if !model.fullScreen { RoundedRectangle(cornerRadius: 12).stroke(hairline) }
            }
            .padding(.horizontal, model.fullScreen ? 0 : inset)
        }
    }

    private func proposalView(_ proposal: SlotEditorModel.Proposal) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AI 修改建议", systemImage: "sparkles").font(.system(size: 13, weight: .medium))
                Spacer()
                Button("保留原文") { model.proposal = nil; model.preview = false }.buttonStyle(.plain)
                Button("接受修改") { model.acceptProposal() }.buttonStyle(.borderedProminent)
                    .tint(.primary).accessibilityIdentifier("slot-editor-accept")
            }
            Text(proposal.instruction).font(.system(size: 12)).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("原文").font(.system(size: 11)).foregroundColor(.secondary)
                    Text(proposal.original).textSelection(.enabled).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background(Color.red.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    Text("修改后").font(.system(size: 11)).foregroundColor(.secondary)
                    Text(proposal.replacement).textSelection(.enabled).lineSpacing(7)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background(Color.blue.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }.padding(24)
    }

    private var references: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(model.fullScreen ? "参考资料" : "附件").font(.system(size: 14, weight: .semibold))
                if !model.fullScreen { Text("\(model.attachments.count)").foregroundColor(.secondary) }
                Spacer()
            }
            if model.fullScreen {
                Picker("参考资料", selection: $rightTab) {
                    Text("附件 \(model.attachments.count)").tag(0)
                    Text("修改记录 \(model.turns.count)").tag(1)
                }.pickerStyle(.segmented).labelsHidden()
            }
            if rightTab == 1 && model.fullScreen { history }
            else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.attachments) { file in
                            SlotEditorAttachmentCard(attachment: file, panel: panel, hairline: hairline) {
                                model.attachments.removeAll { $0.id == file.id }
                            }
                        }
                        Button { model.chooseFiles() } label: {
                            VStack(spacing: 6) {
                                Label("添加附件", systemImage: "plus")
                                Text("或拖放文件到这里").font(.system(size: 10)).foregroundColor(.secondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 16)
                        }.buttonStyle(.plain)
                            .background(dropTarget ? Color.blue.opacity(0.05) : .clear)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(hairline,
                                style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                            .accessibilityIdentifier("slot-editor-add-attachment")
                    }
                }
                Toggle("允许 AI 读取附件", isOn: $model.allowAttachments)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                    .help("开启后，下次发送会读取当前附件作为修改资料")
            }
        }.padding(18).padding(.top, 7)
            .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { model.addFiles([url]) } }
                    }
                }
                return !providers.isEmpty
            }
    }

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.turns.isEmpty {
                    Text("修改建议会保留在这里").font(.system(size: 11)).foregroundColor(.secondary)
                }
                ForEach(model.turns) { turn in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(turn.instruction).font(.system(size: 12, weight: .medium))
                        Text(turn.result).font(.system(size: 12)).foregroundColor(.secondary).textSelection(.enabled)
                        if turn.accepted { Label("已接受", systemImage: "checkmark").font(.system(size: 10)).foregroundColor(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(panel, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Menu {
                    Button("引用全文") { model.quoteSelection = false }
                    Button("引用选中内容") { model.quoteSelection = true }
                        .disabled(model.selectedRange.length == 0)
                } label: {
                    Label(model.quoteSelection && model.selectedRange.length > 0 ? "引用：选中内容" : "引用：全文", systemImage: "sparkles")
                        .font(.system(size: 11)).foregroundColor(.blue)
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer(minLength: 0)
                Button { model.showHistory.toggle() } label: {
                    Text("对话记录").font(.system(size: 10)).foregroundColor(.secondary)
                    Image(systemName: model.showHistory ? "chevron.down" : "chevron.up").font(.system(size: 9))
                }.buttonStyle(.plain)
            }
            AgentDraftEditor(text: $model.instruction, focusRequest: model.inputFocus,
                conversationID: model.id, sourceID: ObjectIdentifier(model),
                isEditable: !voice.isRecording && !voice.isStarting,
                placeholder: "告诉 AI 如何修改这段内容…", onSend: model.send)
                .frame(height: model.fullScreen ? 44 : 48)
                .accessibilityLabel("编辑 AI 输入").accessibilityIdentifier("slot-editor-ai-input")
            if let error = voice.error { Text(error).font(.system(size: 11)).foregroundColor(.orange) }
            HStack(spacing: 8) {
                Menu {
                    Button("添加附件…") { model.chooseFiles() }
                    Button("引用选中内容") { model.quoteSelection = true; model.inputFocus += 1 }
                        .disabled(model.selectedRange.length == 0)
                } label: { Image(systemName: "plus").frame(width: 24, height: 26) }
                    .menuStyle(.borderlessButton).fixedSize().help("添加资料")
                Menu {
                    Toggle("允许 AI 读取附件", isOn: $model.allowAttachments)
                    Text("AI 仅生成建议，接受修改后进入草稿")
                } label: { Image(systemName: "shield").frame(width: 22, height: 26) }
                    .menuStyle(.borderlessButton).fixedSize().help("资料与编辑权限")
                icon("checkmark.circle", help: "查看修改预览") {
                    if model.proposal != nil { model.preview.toggle() }
                }.disabled(model.proposal == nil)
                Menu {
                    Button("润色表达") { preset("润色表达，保留原意与事实。") }
                    Button("精简文字") { preset("精简重复与冗余表达，保留关键信息。") }
                    Button("增强画面感") { preset("增强文字的画面感，保留场景、事实与数值。") }
                    Button("修正错别字") { preset("仅修正错别字、语法与标点，保持其余内容。") }
                } label: { Image(systemName: "scissors").frame(width: 24, height: 26) }
                    .menuStyle(.borderlessButton).fixedSize().help("快捷修改")
                Spacer(minLength: 4)
                Circle().trim(from: 0, to: min(1, Double(model.draft.utf8.count + model.instruction.utf8.count) / 262144))
                    .stroke(Color.secondary.opacity(0.45), lineWidth: 1.4).frame(width: 13, height: 13)
                    .background(Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 1.4))
                    .help("本轮正文 \(model.characterCount) 字")
                AgentPolishButton(busy: model.polishing,
                    enabled: !model.busy && !model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    compact: true, action: model.polishInstruction)
                Button { modelInfo.toggle() } label: { Image(systemName: "cpu").frame(width: 24, height: 26) }
                    .buttonStyle(.plain).help("当前模型")
                    .popover(isPresented: $modelInfo) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("当前文本模型").font(.headline)
                            Text(model.modelName).textSelection(.enabled)
                            Text("使用配置中心的 Agent 文本服务").font(.caption).foregroundColor(.secondary)
                        }.padding(16)
                    }
                icon(voice.isRecording || voice.isStarting ? "stop.circle" : "mic", help: "本地语音输入") {
                    if voice.isRecording || voice.isStarting { voice.stop() }
                    else {
                        let initial = model.instruction
                        voice.start { text in model.instruction = initial + (initial.isEmpty ? "" : "\n") + text }
                    }
                }.disabled(model.busy)
                Button {
                    if model.busy { model.stop() } else { model.send() }
                } label: {
                    Image(systemName: model.busy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(composerFill)
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(model.canSend || model.busy ? 1 : 0.35), in: Circle())
                }.buttonStyle(.plain).disabled(!model.canSend && !model.busy)
                    .help(model.busy ? "停止生成" : "Enter 发送 · Shift+Enter 换行")
                    .accessibilityLabel(model.busy ? "停止生成" : "发送修改要求")
                    .accessibilityIdentifier("slot-editor-send")
            }.foregroundColor(.primary.opacity(0.72))
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16).fill(composerFill)
                .overlay {
                    ComposerEntranceGlow(token: "\(model.id):\(model.busy)", active: true, repeating: model.busy)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(hairline, lineWidth: 0.5))
    }

    private func preset(_ text: String) { model.instruction = text; model.inputFocus += 1 }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("取消", action: onCancel).buttonStyle(.plain)
                .padding(.horizontal, 20).frame(height: 34)
                .background(panel, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(hairline))
                .keyboardShortcut(.cancelAction)
            Button(model.saving ? "保存中…" : "保存", action: onSave).buttonStyle(.plain)
                .foregroundColor(fill).padding(.horizontal, 24).frame(height: 34)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 7))
                .keyboardShortcut(.return, modifiers: .command).disabled(model.saving)
                .accessibilityIdentifier("slot-editor-save")
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func icon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 13)).frame(width: 24, height: 26) }
            .buttonStyle(.plain).foregroundColor(.secondary).help(help).accessibilityLabel(help)
    }
}

private struct SlotEditorAttachmentCard: View {
    let attachment: SlotContent.SlotAttachment
    let panel: Color
    let hairline: Color
    let onRemove: () -> Void
    @State private var image: NSImage?
    private var icon: String {
        switch attachment.type {
        case .image: return "photo"
        case .url: return "link"
        case .text: return "text.alignleft"
        case .reference: return "arrow.triangle.branch"
        case .file: return "doc"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                    .frame(maxHeight: 154).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 9) {
                if image == nil {
                    Image(systemName: icon).font(.system(size: 18)).foregroundColor(.secondary)
                        .frame(width: 32, height: 38).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 5))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(attachment.name).font(.system(size: 12)).lineLimit(2)
                    Text(attachment.type == .image ? "图片" : attachment.type == .url ? "链接" : "参考附件")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(.secondary) }
                    .buttonStyle(.plain).help("移除 \(attachment.name)").accessibilityLabel("移除 \(attachment.name)")
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(hairline))
            .contextMenu {
                if let path = attachment.localFileReferencePath ?? attachment.storagePath {
                    Button("打开附件") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                Button("移除附件", action: onRemove)
            }
            .task(id: attachment.id) {
                guard attachment.type == .image else { return }
                let file = attachment
                let result = await Task.detached(priority: .utility) { () -> Data? in
                    let source: CGImageSource?
                    if let path = file.localFileReferencePath ?? file.storagePath {
                        source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
                    } else if let data = file.data {
                        source = CGImageSourceCreateWithData(data as CFData, nil)
                    } else { source = nil }
                    guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 560,
                        kCGImageSourceCreateThumbnailWithTransform: true
                    ] as CFDictionary) else { return nil }
                    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                }.value
                if !Task.isCancelled { image = result.flatMap(NSImage.init(data:)) }
            }
    }
}
