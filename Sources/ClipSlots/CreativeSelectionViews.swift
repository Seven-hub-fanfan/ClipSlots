import SwiftUI
import ClipSlotsKit

struct CreativeModelOption: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let details: [String]

    init(id: String, title: String, subtitle: String, details: [String]) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.details = details
    }
    init(_ model: CrateModelCatalog.ModelInfo) {
        id = model.id; title = model.displayName
        let types = model.generationTypes.map {
            ["text-2-image": "文生图", "image-2-image": "图生图",
             "text-2-video": "文生视频", "image-to-video": "图生视频"][$0] ?? $0
        }.joined(separator: " · ")
        subtitle = model.family.isEmpty ? types : model.family + " · " + types
        var facts: [String] = [types]
        if model.requiresImageInput { facts.append("需要输入图片") }
        if model.referenceImageMaxCount > 0 { facts.append("最多 \(model.referenceImageMaxCount) 张参考图") }
        if model.supportsLastFrame { facts.append("支持首尾帧") }
        if model.framesExcludeReferences { facts.append("首尾帧与多模态参考不能同时使用") }
        if model.supportsRatio { facts.append("比例：" + model.ratioOptions.map(\.label).joined(separator: "、")) }
        if model.supportsResolution { facts.append("分辨率：" + model.resolutionOptions.map(\.label).joined(separator: "、")) }
        if model.supportsDuration, let spec = model.durationSpec {
            switch spec {
            case .options(let options): facts.append("时长：" + options.map { "\($0)s" }.joined(separator: "、"))
            case .range(let lo, let hi, let step, _): facts.append("时长：\(lo)–\(hi)s · 步长 \(step)s")
            }
        }
        if model.supportsAudio { facts.append("支持生成音频") }
        details = facts.filter { !$0.isEmpty }
    }
}

enum CreativeMenuStyle {
    static var fill: Color { TapSkin.tone(0xffffff, 0x202020) }
    static var hover: Color { TapSkin.tone(0xeff1f4, 0x343434) }
    static var border: Color { TapSkin.tone(0xe0e1e5, 0x383838) }
}

/// Hover only changes the information card. Selection is explicit and keyboard
/// accessible; no catalog request is made from a row or from a hover event.
struct CreativeModelPicker: View {
    let options: [CreativeModelOption]
    let selected: String
    var loading = false
    var searchPlaceholder = "搜索模型"
    var emptyMessage = "没有匹配的模型"
    var notice: String?
    var disabledIDs = Set<String>()
    var preparingID: String?
    var onMore: (() -> Void)?
    var onCancel: (() -> Void)?
    var settingsTitle = "模型与服务设置…"
    var efforts: [String] = []
    var effort = ""
    var onEffort: ((String) -> Void)?
    var onSettings: (() -> Void)?
    var onCustom: (() -> Void)?
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted: String?
    private var filtered: [CreativeModelOption] {
        options.filter { query.isEmpty || "\($0.title) \($0.subtitle) \($0.id) \($0.details.joined(separator: " "))".localizedCaseInsensitiveContains(query) }
    }
    private var detail: CreativeModelOption? {
        filtered.first { $0.id == highlighted } ?? filtered.first { $0.id == selected } ?? filtered.first
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(TapSkin.secondaryInk)
                TextField(searchPlaceholder, text: $query).textFieldStyle(.plain)
                    .accessibilityIdentifier("creative-model-search")
                    .onSubmit { if let detail, !disabledIDs.contains(detail.id) { onPick(detail.id) } }
                if loading || preparingID != nil { CreativeLoadingMark().frame(width: 22, height: 22) }
            }.padding(12)
            Divider().overlay(CreativeMenuStyle.border)
            HStack(alignment: .top, spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            if filtered.isEmpty {
                                Text(loading ? "正在读取目录…" : emptyMessage)
                                    .foregroundColor(TapSkin.secondaryInk).padding(18)
                            }
                            ForEach(filtered) { option in
                                Button { onPick(option.id) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "sparkles").frame(width: 20, height: 28)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(option.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text(option.subtitle).font(.system(size: 10))
                                                .foregroundColor(TapSkin.secondaryInk).lineLimit(1)
                                        }
                                        Spacer(minLength: 2)
                                        Image(systemName: option.id == preparingID ? "hourglass" : option.id == selected ? "checkmark" : "chevron.right")
                                            .font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk)
                                    }
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(detail?.id == option.id ? CreativeMenuStyle.hover : .clear,
                                                in: RoundedRectangle(cornerRadius: 10))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).id(option.id)
                                .disabled(disabledIDs.contains(option.id))
                                .opacity(disabledIDs.contains(option.id) ? 0.5 : 1)
                                .onHover { if $0 { highlighted = option.id } }
                                .accessibilityLabel(option.title + (option.id == selected ? "，已选择" : ""))
                                .accessibilityIdentifier("creative-model-" + option.id)
                            }
                        }.padding(6)
                    }
                    .onChange(of: highlighted) { id in if let id { proxy.scrollTo(id) } }
                }.frame(width: 268, height: 278)
                Rectangle().fill(CreativeMenuStyle.border).frame(width: 0.5)
                VStack(alignment: .leading, spacing: 12) {
                    if let detail {
                        Image(systemName: "sparkles").font(.system(size: 23))
                            .frame(width: 46, height: 46).background(CreativeMenuStyle.hover, in: RoundedRectangle(cornerRadius: 12))
                        Text(detail.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach(Array(detail.details.enumerated()), id: \.offset) { _, fact in
                                    Text(fact).font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        Text(detail.id.isEmpty ? "跟随当前服务默认" : detail.id)
                            .font(.system(size: 9, design: .monospaced)).foregroundColor(TapSkin.faintInk)
                            .lineLimit(2).textSelection(.enabled)
                    }
                }.padding(16).frame(width: 224, height: 278, alignment: .topLeading)
            }
            if let notice, !notice.isEmpty {
                Text(notice).font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if onMore != nil || onCancel != nil {
                Divider().overlay(CreativeMenuStyle.border)
                HStack {
                    if let onMore { Button("加载更多能力", action: onMore).disabled(loading) }
                    Spacer()
                    if let onCancel, loading || preparingID != nil { Button("取消加载", action: onCancel) }
                }.padding(12)
            }
            if let onEffort {
                Divider().overlay(CreativeMenuStyle.border)
                HStack {
                    Text("推理强度").foregroundColor(TapSkin.secondaryInk)
                    Spacer()
                    Picker("推理强度", selection: Binding(get: { effort }, set: onEffort)) {
                        Text("默认").tag("")
                        ForEach(efforts, id: \.self) { Text(Self.effortLabel($0)).tag($0) }
                    }.labelsHidden().frame(width: 150)
                }.padding(12)
            }
            if let onSettings {
                Divider().overlay(CreativeMenuStyle.border)
                HStack {
                    Button(action: onSettings) { Label(settingsTitle, systemImage: "slider.horizontal.3") }
                    Spacer()
                    if let onCustom { Button("自定义模型…", action: onCustom) }
                }.buttonStyle(.plain).foregroundColor(TapSkin.secondaryInk).padding(12)
            }
        }
        .font(.system(size: 12)).foregroundColor(TapSkin.ink)
        .background(CreativeMenuStyle.fill)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onMoveCommand { direction in
            let index = filtered.firstIndex { $0.id == detail?.id } ?? 0
            guard !filtered.isEmpty else { return }
            if direction == .down { highlighted = filtered[(index + 1) % filtered.count].id }
            if direction == .up { highlighted = filtered[(index + filtered.count - 1) % filtered.count].id }
        }
        .onExitCommand { dismiss() }
    }
    static func effortLabel(_ value: String) -> String {
        ["low": "低", "medium": "中", "high": "高", "xhigh": "极高", "minimal": "最小", "none": "无"][value] ?? value
    }
}

/// The button opens a searchable picker without inserting text. `$` and `/skills`
/// continue to use the native editor's completion menu and marked-text protection.
struct AgentReferenceSkillPicker: View {
    let items: [AgentComposerItem]
    let isScanning: Bool
    let onPick: (AgentComposerItem.Action) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hovered: String?
    private var matches: [AgentComposerItem] {
        items.filter { $0.isSkill && (query.isEmpty || "\($0.title) \($0.detail)".localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Skills").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("引用到当前对话").font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk)
            }.padding(.horizontal, 8)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(TapSkin.faintInk)
                TextField("搜索技能、用途或项目", text: $query).textFieldStyle(.plain)
                    .accessibilityIdentifier("agent-skill-search")
                    .onSubmit {
                        if let item = matches.first(where: { $0.id == hovered }) ?? matches.first { onPick(item.action) }
                    }
            }.padding(10).background(CreativeMenuStyle.hover, in: RoundedRectangle(cornerRadius: 9))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if matches.isEmpty {
                            HStack(spacing: 8) {
                                if isScanning { CreativeLoadingMark().frame(width: 26, height: 26) }
                                Text(isScanning ? "正在读取技能…" : "没有匹配的技能")
                                    .foregroundColor(TapSkin.secondaryInk)
                            }.padding(18)
                        }
                        ForEach(matches) { item in
                            Button { onPick(item.action) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "sparkles").frame(width: 28, height: 28)
                                        .background(CreativeMenuStyle.hover, in: RoundedRectangle(cornerRadius: 7))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(String(item.title.dropFirst())).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(item.detail).font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "plus").font(.system(size: 11)).foregroundColor(TapSkin.faintInk)
                                }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(hovered == item.id ? CreativeMenuStyle.hover : .clear,
                                                in: RoundedRectangle(cornerRadius: 10))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(item.id)
                                .onHover { if $0 { hovered = item.id } }
                                .accessibilityIdentifier("agent-skill-pick-" + item.id)
                        }
                    }
                }
                .frame(height: min(320, max(80, CGFloat(matches.count) * 62)))
                .onChange(of: hovered) { id in if let id { proxy.scrollTo(id) } }
            }
            Text("也可在输入框中用 $ 搜索").font(.system(size: 10)).foregroundColor(TapSkin.faintInk)
                .padding(.horizontal, 8).padding(.top, 4)
        }
        .padding(12).frame(width: 352).foregroundColor(TapSkin.ink).background(CreativeMenuStyle.fill)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onMoveCommand { direction in
            guard !matches.isEmpty else { return }
            let index = matches.firstIndex { $0.id == hovered } ?? 0
            if direction == .down { hovered = matches[(index + 1) % matches.count].id }
            if direction == .up { hovered = matches[(index + matches.count - 1) % matches.count].id }
        }
        .onExitCommand { dismiss() }
    }
}
