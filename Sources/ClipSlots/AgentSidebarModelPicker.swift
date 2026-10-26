import AppKit
import SwiftUI
import ClipSlotsKit

struct AgentSidebarModelPicker: View {
    let options: [AgentDiscoveredModel]
    let selected: String
    let loading: Bool
    let notice: String?
    let compactDetails: Bool
    let refresh: () -> Void
    let settings: () -> Void
    var reasoningEffort = ""
    var effortModelIDs: Set<String> = []
    var changeEffort: (String, String) -> Void = { _, _ in }
    let choose: (String) -> Void
    @State private var expanded = false
    @State private var query = ""
    @State private var focused: String?
    @State private var localEfforts: [String: String] = [:]

    private var automatic: AgentDiscoveredModel? { options.first { $0.automatic } }
    private var manual: [AgentDiscoveredModel] { options.filter { !$0.automatic } }
    private var recommended: [AgentDiscoveredModel] {
        let preferred = manual.filter(\.recommended)
        var rows = Array((preferred.isEmpty ? manual : preferred).prefix(4))
        if let current = manual.first(where: { $0.id == selected }),
           !rows.contains(where: { $0.id == selected }) {
            rows.insert(current, at: 0)
        }
        return rows
    }
    private var filtered: [AgentDiscoveredModel] {
        manual.filter {
            query.isEmpty || ($0.displayName ?? $0.id).localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }
    private var detail: AgentDiscoveredModel? {
        options.first { $0.id == focused }
    }
    private var menuHeight: CGFloat {
        // In the single-column fallback, keep the whole detail card visible
        // when changing to a model with the additional reasoning controls.
        if compactDetails, detail != nil { return 424 }
        return min(424, 190 + CGFloat(recommended.count) * 29
            + (loading || notice != nil ? 32 : 0) + (expanded ? 275 : 0))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !compactDetails {
                Group {
                    if let detail { modelDetails(detail) }
                    else {
                        Color.clear.frame(height: 1)
                    }
                }.frame(width: 218, alignment: .bottom)
            }
            ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                if compactDetails, let detail { modelDetails(detail) }
                Button { if let automatic, automatic.available { choose(automatic.id) } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Auto").font(.system(size: 12, weight: .medium))
                            Spacer()
                            if automatic?.id == selected { Image(systemName: "checkmark") }
                        }
                        Text("平衡速度、思考强度与成本。").font(.system(size: 10))
                            .foregroundColor(TapSkin.secondaryInk)
                    }.padding(9).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(automatic?.available != true)
                    .help(automatic == nil ? "当前服务未提供 Auto" : "自动选择模型")
                    .accessibilityIdentifier("agent-model-auto")
                Text("精选推荐").font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                ForEach(recommended, id: \.id) { option in modelRow(option) }
                Divider().padding(.vertical, 4)
                Button { expanded.toggle(); focused = nil } label: {
                    HStack {
                        Text("更多模型")
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }.font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk)
                        .padding(9).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("agent-model-more")
                if expanded {
                    TextField("搜索模型", text: $query).textFieldStyle(.roundedBorder)
                        .font(.system(size: 11)).padding(.horizontal, 6)
                        .accessibilityIdentifier("agent-model-search")
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(filtered, id: \.id) { option in modelRow(option) }
                            if filtered.isEmpty { Text("没有匹配的模型").font(.system(size: 11)).padding(9) }
                        }
                    }.frame(height: min(230, CGFloat(max(1, filtered.count)) * 32))
                }
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("正在查询模型…") }
                        .font(.system(size: 10)).padding(8)
                } else if let notice {
                    Text(notice).font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk)
                        .lineLimit(2).padding(8)
                }
                HStack {
                    Button("刷新", action: refresh).disabled(loading)
                    Spacer()
                    Button("模型设置", action: settings)
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk).padding(9)
            }.padding(5).frame(width: 242)
                .background(TapSkin.tone(0xffffff, 0x222222), in: RoundedRectangle(cornerRadius: 10))
            }.frame(width: 242, height: menuHeight)
                .background(TapSkin.tone(0xffffff, 0x222222), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(TapSkin.secondaryInk.opacity(0.12), lineWidth: 1))
        }.padding(8).foregroundColor(TapSkin.ink)
            .frame(width: compactDetails ? 258 : 484, height: 440, alignment: .bottomLeading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-model-menu")
    }

    private func modelRow(_ option: AgentDiscoveredModel) -> some View {
        AgentSidebarModelRow(option: option, selected: selected == option.id, highlighted: focused == option.id,
            focus: { focused = option.id }, choose: { choose(option.id) })
    }

    private func modelDetails(_ option: AgentDiscoveredModel) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(option.displayName ?? option.id).font(.system(size: 13, weight: .semibold))
            Text(option.description ?? "当前服务未提供模型介绍。")
                .font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk)
                .fixedSize(horizontal: false, vertical: true).lineLimit(6)
            Divider()
            ForEach(["intelligence", "speed", "cost"], id: \.self) { key in
                HStack {
                    Text(["intelligence": "能力", "speed": "速度", "cost": "成本", "thinking": "思考强度"][key] ?? key)
                    Spacer()
                    if let value = option.ratings[key] {
                        HStack(spacing: 3) {
                            ForEach(0..<5) { index in
                                Capsule().fill(index < value ? TapSkin.secondaryInk : TapSkin.secondaryInk.opacity(0.15))
                                    .frame(width: 8, height: 3)
                            }
                        }.accessibilityLabel("\(value)/5")
                    } else { Text("—") }
                }.font(.system(size: 10))
            }
            if effortModelIDs.contains(option.id), option.available {
                effortControl(option)
            }
            if let capacity = option.contextWindow {
                Text("上下文 \(capacity.formatted()) tokens").font(.system(size: 10))
            }
            if let images = option.supportsImages {
                Text(images ? "支持图像输入" : "文本输入").font(.system(size: 10))
            }
            Text("信息由当前服务提供").font(.system(size: 9)).foregroundColor(TapSkin.secondaryInk)
        }.padding(12).frame(width: 218, alignment: .leading)
            .background(TapSkin.tone(0xf7f7f7, 0x292929), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-model-detail")
    }

    private func effortControl(_ option: AgentDiscoveredModel) -> some View {
        let values = ["low", "high", "max"]
        let labels = ["低", "高", "最高"]
        let value = localEfforts[option.id] ?? (option.id == selected ? reasoningEffort : "")
        let index = values.firstIndex(of: value) ?? 1
        return VStack(spacing: 5) {
            HStack {
                Text("思考强度")
                Spacer()
                Text(value.isEmpty ? "跟随服务端" : labels[index])
            }.font(.system(size: 10))
            AgentEffortSlider(value: Binding(get: { Double(index) }, set: { level in
                let effort = values[max(0, min(2, Int(level.rounded())))]
                localEfforts[option.id] = effort
                changeEffort(option.id, effort)
            }), identifier: "agent-model-effort-\(option.id)")
                .frame(height: 18)
            HStack {
                ForEach(Array(values.enumerated()), id: \.element) { offset, effort in
                    if offset > 0 { Spacer() }
                    Button(labels[offset]) {
                        localEfforts[option.id] = effort
                        changeEffort(option.id, effort)
                    }.buttonStyle(.plain)
                        .foregroundColor(value == effort ? TapSkin.ink : TapSkin.secondaryInk)
                        .accessibilityIdentifier("agent-model-effort-\(option.id)-\(effort)")
                }
            }.font(.system(size: 9))
        }
    }
}

private struct AgentEffortSlider: NSViewRepresentable {
    @Binding var value: Double
    let identifier: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> AgentEffortNativeSlider {
        let slider = AgentEffortNativeSlider(frame: .zero)
        slider.cell = AgentEffortSliderCell()
        slider.minValue = 0
        slider.maxValue = 2
        slider.numberOfTickMarks = 3
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.controlSize = .mini
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel("思考强度")
        slider.setAccessibilityIdentifier(identifier)
        return slider
    }
    func updateNSView(_ slider: AgentEffortNativeSlider, context: Context) {
        context.coordinator.owner = self
        slider.doubleValue = value
    }
    final class Coordinator: NSObject {
        var owner: AgentEffortSlider
        init(_ owner: AgentEffortSlider) { self.owner = owner }
        @objc func changed(_ sender: NSSlider) { owner.value = sender.doubleValue.rounded() }
    }
}

private final class AgentEffortSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor.secondaryLabelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.28).setFill()
        for index in 0..<max(1, Int(track.width / 5)) {
            NSBezierPath(ovalIn: NSRect(x: track.minX + CGFloat(index) * 5 + 1,
                                       y: track.midY - 0.6, width: 1.2, height: 1.2)).fill()
        }
    }
    override func drawKnob(_ knobRect: NSRect) {
        NSColor(srgbRed: 0.36, green: 0.69, blue: 0.90, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: knobRect.midX - 3.5, y: knobRect.midY - 3.5,
                                   width: 7, height: 7)).fill()
    }
    override func drawTickMarks() {}
}

private final class AgentEffortNativeSlider: NSSlider {
    override func accessibilityPerformIncrement() -> Bool { adjust(1) }
    override func accessibilityPerformDecrement() -> Bool { adjust(-1) }
    private func adjust(_ offset: Double) -> Bool {
        guard isEnabled else { return false }
        let next = max(minValue, min(maxValue, doubleValue + offset))
        guard next != doubleValue else { return false }
        doubleValue = next
        return sendAction(action, to: target)
    }
}

private struct AgentSidebarModelRow: View {
    let option: AgentDiscoveredModel
    let selected: Bool
    let highlighted: Bool
    let focus: () -> Void
    let choose: () -> Void
    var body: some View {
        HStack(spacing: 7) {
            Button(action: choose) {
                HStack(spacing: 7) {
                    if option.id.lowercased().contains("deepseek") {
                        AgentBrandIcon(identifier: "deepseek", size: 15)
                    } else {
                        Image(systemName: option.automatic ? "wand.and.stars" : "cpu")
                            .font(.system(size: 11))
                    }
                    Text(option.displayName ?? option.id).lineLimit(1)
                    if !option.available {
                        Text(option.subscriptionRequired ? "订阅解锁" : "未开放")
                            .font(.system(size: 9)).foregroundColor(TapSkin.secondaryInk)
                    }
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark") }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!option.available)
                .accessibilityIdentifier("agent-model-choice-\(option.id)")
            Button(action: focus) { Image(systemName: "info.circle").font(.system(size: 9)) }
                .buttonStyle(.plain).accessibilityIdentifier("agent-model-info-\(option.id)")
        }.font(.system(size: 11)).padding(.horizontal, 8).frame(height: 29)
            .background(highlighted || selected ? TapSkin.subtleFill : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { if $0 { focus() } }
    }
}
