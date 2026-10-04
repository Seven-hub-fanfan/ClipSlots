import SwiftUI
import ClipSlotsKit

struct AgentInteractionView: View {
    let request: AgentInteraction
    @ObservedObject var model: AgentChatModel
    @State private var answers: [String: String] = [:]
    @State private var submitting = false

    private var result: JSONValue {
        ["answers": .object(answers.mapValues { ["answers": [.string($0)]] })]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(request.kind == .questions ? "需要你的回答" : "等待本次操作授权",
                  systemImage: request.kind == .questions ? "questionmark.bubble" : "hand.raised")
                .font(.system(size: 13, weight: .semibold))
            if request.kind == .questions {
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
                Button("提交回答") { submit(result) }
                    .disabled(!request.accepts(result))
                    .accessibilityIdentifier("agent-submit-answers")
            } else {
                if let command = request.params["command"]?.stringValue {
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
                HStack {
                    Button("拒绝") { submit(["decision": "decline"]) }
                        .accessibilityIdentifier("agent-decline")
                    Button("允许本次") { submit(["decision": "accept"]) }
                        .disabled(!request.canAccept)
                        .accessibilityIdentifier("agent-approve-once")
                }
            }
            Button("停止本轮") { model.stop() }.font(.system(size: 11))
                .accessibilityIdentifier("agent-stop-interaction")
        }
        .buttonStyle(.bordered)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TapSkin.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(TapSkin.accent.opacity(0.3)))
        .disabled(submitting)
    }

    private func submit(_ value: JSONValue) {
        guard !submitting else { return }
        submitting = true
        Task { await model.respond(to: request, result: value); submitting = false }
    }
}
