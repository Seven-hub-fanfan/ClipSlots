import SwiftUI
import ClipSlotsKit

struct AgentApprovalPicker: View {
    @ObservedObject var model: AgentChatModel
    @State private var showing = false
    @State private var about = false

    var body: some View {
        Button { showing.toggle(); about = false } label: {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 13)).frame(width: 26, height: 30)
                .background(showing ? TapSkin.subtleFill : .clear, in: Circle())
        }.buttonStyle(.plain)
            .disabled(model.isRunning || model.canResumeGateway || model.isControllingRun)
            .help(model.automaticApproval ? "自动生成" : "手动确认")
            .accessibilityLabel(model.automaticApproval ? "审批模式：自动生成" : "审批模式：手动确认")
            .accessibilityIdentifier("agent-approval-policy")
            .onChange(of: model.selectedConversationID) { _ in showing = false; about = false }
            .onChange(of: model.backendKind) { _ in showing = false; about = false }
            .popover(isPresented: $showing, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if about {
                        Button("返回") { about = false }.buttonStyle(.plain).padding(8)
                        Text("审批与访问范围").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10)
                        Text("目录菜单控制可访问范围。审批菜单控制每次操作是否需要确认。更改目录范围不会更改审批选择。")
                            .font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk).padding(10)
                        Text("删除、清空和未声明的外部操作始终确认。拒绝、停止或会话切换会终止待批准操作。")
                            .font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk).padding(10)
                    } else {
                        row("手动确认", detail: "生图、生视频和本地文件/目录操作均需每次确认。",
                            symbol: "hand.raised", automatic: false)
                        row("自动生成", detail: "已挂载范围内生成与安全本地操作可自动执行；删除仍需确认。",
                            symbol: "checkmark.arrow.trianglehead.counterclockwise", automatic: true)
                        Divider().padding(.vertical, 5)
                        Button { about = true } label: {
                            Text("了解更多").font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("agent-approval-about")
                    }
                }.padding(5).frame(width: 260)
                    .foregroundColor(TapSkin.ink).background(TapSkin.tone(0xffffff, 0x222222))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("agent-approval-menu")
            }
    }

    private func row(_ title: String, detail: String, symbol: String, automatic: Bool) -> some View {
        AgentApprovalRow(title: title, detail: detail, symbol: symbol,
                         selected: model.automaticApproval == automatic) {
            model.selectAutomaticApproval(automatic)
            showing = false
        }.accessibilityIdentifier(automatic ? "agent-approval-automatic" : "agent-approval-manual")
    }
}

private struct AgentApprovalRow: View {
    let title: String
    let detail: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 16).padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark").opacity(selected ? 1 : 0).font(.system(size: 11))
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? TapSkin.subtleFill : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}
