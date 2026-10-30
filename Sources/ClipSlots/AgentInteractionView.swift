import SwiftUI
import ClipSlotsKit

struct AgentInteractionView: View {
    let request: AgentInteraction
    @ObservedObject var model: AgentChatModel
    @State private var answers: [String: String] = [:]
    @State private var submitting = false
    @State private var itemDecisions: [Int: String] = [:]
    @State private var modifications: [Int: [String: String]] = [:]
    @State private var modifiedFields: [Int: Set<String>] = [:]
    @State private var modificationTypes: [Int: [String: String]] = [:]
    @State private var costDecision = ""

    private var result: JSONValue {
        withCost(["answers": .object(answers.mapValues { ["answers": [.string($0)]] })])
    }
    private func withCost(_ value: JSONValue) -> JSONValue {
        guard request.requiresCostDecision, var fields = value.objectValue else { return value }
        fields["costDecision"] = .string(costDecision)
        return .object(fields)
    }
    private var batchResult: JSONValue {
        var values: [JSONValue] = []
        for (offset, item) in request.batchItems.enumerated() {
            let decision = itemDecisions[offset] ?? ""
            var edits: [String: JSONValue] = [:]
            if decision != "decline" {
                for field in modifiedFields[offset] ?? [] {
                    guard let value = modificationValue(offset, field, item) else { return .null }
                    edits[field] = value
                }
            }
            values.append(["index": item["index"] ?? .null, "action": item["action"] ?? .null,
                           "decision": .string(decision), "modifications": .object(edits)])
        }
        return withCost(["items": .array(values)])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(request.kind == .questions ? "需要你的回答" : "等待本次操作授权",
                  systemImage: request.kind == .questions ? "questionmark.bubble" : "hand.raised")
                .font(.system(size: 13, weight: .semibold))
            if request.state != .pending || !request.isPending {
                Text(request.state == .pending ? "请核对原请求是否仍可回答" : request.state.summary).font(.system(size: 12))
                    .accessibilityIdentifier("agent-decision-state")
                if request.canReconcile && !request.state.accepted {
                    Button("核对原回复") {
                        submitting = true
                        Task { await model.reconcile(request); submitting = false }
                    }
                    .disabled(submitting)
                    .accessibilityIdentifier("agent-reconcile-decision")
                }
                if request.canSendSaved {
                    Button("发送已保存回答") {
                        submitting = true
                        Task { await model.sendSaved(request); submitting = false }
                    }
                    .disabled(submitting)
                    .accessibilityIdentifier("agent-send-saved-decision")
                }
            } else if !request.batchItems.isEmpty { batchForm }
            else if request.kind == .questions { questionForm }
            else { approvalForm }
            Button("停止本轮") { model.stop() }.font(.system(size: 11))
                .accessibilityIdentifier("agent-stop-interaction")
        }
        .buttonStyle(.bordered)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TapSkin.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(TapSkin.accent.opacity(0.3)))
        .task(id: ObjectIdentifier(request)) {
            while request.state == .pending && !Task.isCancelled {
                let remaining = request.remainingTime
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(min(remaining, 86400) * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                if request.isGateway {
                    await model.reconcile(request)
                    if request.remainingTime <= 0 { return }
                } else {
                    if request.expire() { model.objectWillChange.send() }
                    return
                }
            }
        }
    }

    @ViewBuilder private var batchForm: some View {
        if let title = request.params["title"]?.stringValue {
            Text(title).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
        }
        ForEach(Array(request.batchItems.enumerated()), id: \.offset) { offset, item in
            batchRow(offset, item)
        }
        costForm
        Button("全部拒绝") {
            for offset in request.batchItems.indices { itemDecisions[offset] = "decline" }
            modifications = [:]; modifiedFields = [:]
        }
        .disabled(!request.batchItems.allSatisfy { AgentInteraction.decisions($0).contains("decline") })
        .accessibilityIdentifier("agent-batch-decline-all")
        Button("提交逐项决定") { submit(batchResult) }
            .disabled(!request.accepts(batchResult) || submitting || !request.isPending)
            .accessibilityIdentifier("agent-submit-batch-decisions")
    }

    private func batchRow(_ offset: Int, _ item: JSONValue) -> some View {
        let index = item["index"]?.intValue.map(String.init) ?? "?"
        let action = item["action"]?.stringValue ?? ""
        let fields = item["allowedModifications"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text("项目 \(index) · \(action)").font(.system(size: 12, weight: .medium))
            if let title = item["title"]?.stringValue { Text(title).font(.system(size: 12)) }
            if let preview = item["preview"]?.stringValue { Text(preview).font(.system(size: 12)).textSelection(.enabled) }
            if let command = item["command"]?.stringValue {
                Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            if let path = item["path"]?.stringValue { Text("路径：\(path)").font(.system(size: 12)).textSelection(.enabled) }
            Picker("决定", selection: Binding(get: { itemDecisions[offset] ?? "" },
                                              set: { itemDecisions[offset] = $0 })) {
                Text("请选择").tag("")
                ForEach(AgentInteraction.decisions(item), id: \.self) { decision in
                    Text(decision == "accept" ? "允许本次" : "拒绝").tag(decision)
                }
            }.accessibilityIdentifier("agent-batch-decision-\(offset)")
            if itemDecisions[offset] == "accept" {
                ForEach(fields, id: \.self) { field in
                    modificationEditor(offset, field, item)
                }
            }
        }
    }

    private func modificationType(_ offset: Int, _ field: String, _ item: JSONValue) -> String {
        if let value = modificationTypes[offset]?[field] { return value }
        switch item[field] {
        case .number?: return "number"
        case .bool?: return "bool"
        case .array?, .object?, .null?: return "json"
        default: return "text"
        }
    }

    private func modificationValue(_ offset: Int, _ field: String, _ item: JSONValue) -> JSONValue? {
        let raw = modifications[offset]?[field] ?? ""
        let type = modificationType(offset, field, item)
        if type == "text" { return .string(raw) }
        guard let bytes = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { return nil }
        if type == "number" { if case .number(let n) = value, n.isFinite { return value }; return nil }
        if type == "bool" { if case .bool = value { return value }; return nil }
        return value
    }

    @ViewBuilder private func modificationEditor(_ offset: Int, _ field: String, _ item: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("修改 \(field)", isOn: Binding(
                get: { modifiedFields[offset]?.contains(field) == true },
                set: { enabled in
                    if enabled {
                        modifiedFields[offset, default: []].insert(field)
                        if modifications[offset]?[field] == nil {
                            modifications[offset, default: [:]][field] = item[field]?.stringValue
                                ?? (try? item[field]?.encodedText()) ?? (modificationType(offset, field, item) == "bool" ? "false" : "")
                        }
                    } else { modifiedFields[offset, default: []].remove(field) }
                }))
                .accessibilityIdentifier("agent-batch-edit-\(offset)-\(field)")
            if modifiedFields[offset]?.contains(field) == true {
                Picker("内容类型", selection: Binding(
                    get: { modificationType(offset, field, item) },
                    set: { modificationTypes[offset, default: [:]][field] = $0 })) {
                    Text("文本").tag("text")
                    Text("数值").tag("number")
                    Text("布尔值").tag("bool")
                    Text("结构化内容").tag("json")
                }.accessibilityIdentifier("agent-batch-type-\(offset)-\(field)")
                let binding = Binding(get: { modifications[offset]?[field] ?? "" },
                    set: { modifications[offset, default: [:]][field] = $0 })
                if modificationType(offset, field, item) == "bool" {
                    Picker("新值", selection: binding) {
                        Text("是").tag("true")
                        Text("否").tag("false")
                    }.accessibilityIdentifier("agent-batch-modification-\(offset)-\(field)")
                } else {
                    TextField(modificationType(offset, field, item) == "json" ? "输入 JSON 内容" : "输入新值",
                        text: binding, axis: .vertical)
                        .lineLimit(1...6)
                        .accessibilityIdentifier("agent-batch-modification-\(offset)-\(field)")
                }
                if modificationValue(offset, field, item) == nil {
                    Text("请填写有效的\(modificationType(offset, field, item) == "number" ? "数值" : "内容")")
                        .font(.system(size: 11)).foregroundColor(.red)
                }
            }
        }
    }

    @ViewBuilder private var questionForm: some View {
                ForEach(request.questions) { question in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(question.text).font(.system(size: 13)).textSelection(.enabled)
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            Button {
                                answers[question.id] = option
                            } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: answers[question.id] == option ? "largecircle.fill.circle" : "circle")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(option)
                                        if index < question.descriptions.count, !question.descriptions[index].isEmpty {
                                            Text(question.descriptions[index]).foregroundColor(TapSkin.secondaryInk)
                                        }
                                    }
                                }
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if question.allowsOther {
                            let binding = Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 })
                            if question.secret {
                                SecureField("输入回答", text: binding)
                                    .accessibilityIdentifier("agent-question-\(question.id)")
                            } else {
                                TextField("输入回答", text: binding)
                                    .accessibilityIdentifier("agent-question-\(question.id)")
                            }
                        }
                    }
                }
                costForm
                Button("提交回答") { submit(result) }
                    .disabled(!request.accepts(result) || submitting || !request.isPending)
                    .accessibilityIdentifier("agent-submit-answers")
    }

    @ViewBuilder private var approvalForm: some View {
                if let title = request.params["title"]?.stringValue {
                    Text(title).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                    if let preview = request.params["preview"]?.stringValue, !preview.isEmpty {
                        Text(preview).font(.system(size: 12)).textSelection(.enabled)
                    }
                } else if let command = request.params["command"]?.stringValue {
                    Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
                if let cwd = request.params["cwd"]?.stringValue {
                    Text("目录：\(cwd)").font(.system(size: 11)).textSelection(.enabled)
                }
                if let reason = request.params["reason"]?.stringValue {
                    Text(reason).font(.system(size: 12)).textSelection(.enabled)
                }
                if request.kind == .fileApproval {
                    let changes = request.params["item"]?["changes"]?.arrayValue ?? []
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                        DisclosureGroup(change["path"]?.stringValue ?? "文件变更") {
                            Text(change["diff"]?.stringValue ?? "未提供差异正文")
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                DisclosureGroup("查看完整请求") {
                    Text((try? request.params.encodedText(pretty: true)) ?? "")
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }.font(.system(size: 11))
                costForm
                HStack {
                    Button("拒绝") { submit(withCost(["decision": "decline"])) }
                        .disabled(!request.accepts(withCost(["decision": "decline"])) || submitting || !request.isPending)
                        .accessibilityIdentifier("agent-decline")
                    Button("允许本次") { submit(withCost(["decision": "accept"])) }
                        .disabled(!request.accepts(withCost(["decision": "accept"])) || submitting || !request.isPending)
                        .accessibilityIdentifier("agent-approve-once")
                }
    }

    @ViewBuilder private var costForm: some View {
        if let cost = request.params["cost"] {
            VStack(alignment: .leading, spacing: 6) {
                Text("费用授权").font(.system(size: 12, weight: .semibold))
                if let summary = cost["summary"]?.stringValue { Text(summary).font(.system(size: 12)) }
                ForEach((cost.objectValue?.keys.sorted() ?? []).filter {
                    $0 != "summary" && $0 != "availableDecisions"
                }, id: \.self) { field in
                    Text("\(costLabel(field))：\(cost[field]?.stringValue ?? (try? cost[field]?.encodedText(pretty: true)) ?? "")")
                        .font(.system(size: 12)).textSelection(.enabled)
                        .accessibilityIdentifier("agent-cost-detail-\(field)")
                }
                if cost.objectValue == nil {
                    Text((try? cost.encodedText(pretty: true)) ?? "").font(.system(size: 12))
                }
                Picker("费用决定", selection: $costDecision) {
                    Text("请选择").tag("")
                    ForEach(AgentInteraction.decisions(cost), id: \.self) { decision in
                        Text(decision == "accept" ? "允许费用" : "拒绝费用").tag(decision)
                    }
                }.accessibilityIdentifier("agent-cost-decision")
            }
        }
    }

    private func costLabel(_ field: String) -> String {
        ["amount": "金额", "currency": "币种", "estimate": "费用估算", "maximum": "最高费用",
         "unit": "计费单位", "quantity": "数量", "provider": "服务", "description": "费用说明"][field] ?? field
    }

    private func submit(_ value: JSONValue) {
        guard !submitting else { return }
        submitting = true
        Task { await model.respond(to: request, result: value); submitting = false }
    }
}
