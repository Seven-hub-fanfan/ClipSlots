import SwiftUI
import ClipSlotsKit

struct AgentCompactionCard: View {
    let entry: AgentContextCompactionLifecycle.Entry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.phase == .finished ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .medium))
            Text(entry.phase == .finished ? "上下文已压缩" : "正在压缩上下文…")
                .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .foregroundColor(TapSkin.secondaryInk)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(TapSkin.tone(0xf4f4f5, 0x262628),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-context-compaction:" + entry.displayID)
    }
}
