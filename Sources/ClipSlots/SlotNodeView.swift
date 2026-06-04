import SwiftUI

struct SlotNodeView: View {
    let slot: Int
    let content: SlotContent?
    let colorId: Int?
    let isHovered: Bool
    let connectedPorts: Set<SlotPort>
    let highlightedPort: SlotPort?
    let onBeginDrag: (SlotPort, CGPoint) -> Void
    let onUpdateDrag: (CGPoint) -> Void
    let onEndDrag: () -> Void

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("\(slot)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(SlotConnectionColor.color(for: colorId) == .clear ? .accentColor : SlotConnectionColor.color(for: colorId)))
                    Text(nodeTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if let colorId {
                        Circle().fill(SlotConnectionColor.color(for: colorId)).frame(width: 7, height: 7)
                    }
                }
                Text(nodePreview)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(SlotConnectionColor.color(for: colorId).opacity(colorId == nil ? 0.18 : 0.8), lineWidth: colorId == nil ? 1 : 2))
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)
            portLayer
        }
    }

    private var nodeTitle: String {
        guard let content else { return "空槽位" }
        let text = content.plainText ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "槽位内容" }
        return text.components(separatedBy: .newlines).first ?? "槽位内容"
    }

    private var nodePreview: String {
        guard let content else { return "拖拽端口建立连接" }
        let text = content.plainText ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        // Fallback to preview for non-text content
        if content.hasImage || content.isImageFile { return "[图片]" }
        if content.isFileContent { return "[文件] \(content.fileDisplayName ?? "")" }
        return content.preview
    }

    private var shouldShowPorts: Bool { isHovered || !connectedPorts.isEmpty || highlightedPort != nil }
    private var portColor: Color { SlotConnectionColor.color(for: colorId) == .clear ? .accentColor : SlotConnectionColor.color(for: colorId) }

    private var portLayer: some View {
        ZStack {
            port(.top).position(x: 75, y: 0)
            port(.right).position(x: 150, y: 48)
            port(.bottom).position(x: 75, y: 96)
            port(.left).position(x: 0, y: 48)
        }
    }

    private func port(_ port: SlotPort) -> some View {
        Circle()
            .fill(highlightedPort == port || connectedPorts.contains(port) ? portColor : Color(NSColor.windowBackgroundColor))
            .overlay(Circle().stroke(portColor, lineWidth: 2))
            .frame(width: highlightedPort == port ? 16 : 12, height: highlightedPort == port ? 16 : 12)
            .frame(width: 28, height: 28)
            .opacity(shouldShowPorts ? 1 : 0)
            .scaleEffect(shouldShowPorts ? 1 : 0.7)
            .animation(.easeOut(duration: 0.12), value: shouldShowPorts)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("nodeCanvas"))
                    .onChanged { value in
                        onBeginDrag(port, value.startLocation)
                        onUpdateDrag(value.location)
                    }
                    .onEnded { _ in onEndDrag() }
            )
    }
}
