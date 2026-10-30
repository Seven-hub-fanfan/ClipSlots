import SwiftUI
import ClipSlotsKit

struct AgentTaskSubagentCard: View {
    let entry: AgentTaskSubagentProjection.Entry
    @State var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch entry.content {
            case .tasks(let snapshot):
                HStack {
                    Label("任务计划", systemImage: "list.bullet.clipboard")
                    Spacer(minLength: 0)
                    Text(snapshot.planReady ? "计划已就绪" : "规划中")
                        .foregroundColor(TapSkin.secondaryInk)
                }
                ForEach(Array(snapshot.tasks.enumerated()), id: \.offset) { _, task in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: task["status"] == "completed" ? "checkmark.circle.fill"
                            : task["status"] == "in_progress" ? "circle.dotted" : "circle")
                            .foregroundColor(TapSkin.secondaryInk)
                        Text(task["subject"]?.stringValue ?? "").textSelection(.enabled)
                    }
                }
            case .subagent(let state):
                DisclosureGroup(isExpanded: $expanded) {
                    details(state)
                } label: {
                    title(state)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundColor(TapSkin.ink)
        .padding(12)
        .background(TapSkin.tone(0xf4f4f5, 0x262628),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("agent-task-subagent:" + entry.id)
    }

    private func title(_ state: AgentSubagentState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.crop.circle.badge.clock")
            VStack(alignment: .leading, spacing: 4) {
                Text(state.agentType ?? "子任务").fontWeight(.medium)
                if let description = state.taskDescription, !description.isEmpty {
                    Text(description).foregroundColor(TapSkin.secondaryInk).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Text(state.status.label).foregroundColor(TapSkin.secondaryInk)
        }
    }

    private func details(_ state: AgentSubagentState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.timeline.isEmpty, !state.text.isEmpty { Text(state.text).textSelection(.enabled) }
            ForEach(Array(state.timeline.enumerated()), id: \.offset) { _, item in
                switch item {
                case .text(let text): Text(text).textSelection(.enabled)
                case .tool(let id):
                    if let tool = state.tools.first(where: { AgentSubagentState.toolIdentity($0) == id }) {
                        toolRow(tool)
                    }
                }
            }
            let recorded = Set(state.timeline.compactMap { item -> String? in
                if case .tool(let id) = item { return id }; return nil
            })
            ForEach(Array(state.tools.enumerated()), id: \.offset) { _, tool in
                if AgentSubagentState.toolIdentity(tool).map({ !recorded.contains($0) }) ?? true { toolRow(tool) }
            }
        }.padding(.top, 8)
    }

    private func toolRow(_ tool: JSONValue) -> some View {
        DisclosureGroup {
            if let request = tool["request"], let text = try? request.encodedText(), text != "{}" {
                Text(text).textSelection(.enabled)
            }
            if let response = tool["response"], response != .null, let text = try? response.encodedText() {
                Text(text).textSelection(.enabled)
            }
        } label: {
            HStack {
                Text(tool["tool"]?.stringValue ?? "工具")
                Spacer(minLength: 0)
                Text(toolStatus(tool["status"]?.stringValue ?? ""))
                    .foregroundColor(TapSkin.secondaryInk)
            }
        }.font(.system(size: 11))
    }

    private func toolStatus(_ raw: String) -> String {
        switch raw {
        case "started", "running": return "执行中"
        case "completed": return "已完成"
        case "failed": return "失败"
        case "stopped": return "已停止"
        default: return "结果未知"
        }
    }
}
