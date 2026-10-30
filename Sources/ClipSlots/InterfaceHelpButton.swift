import SwiftUI

/// Keeps contextual explanations within reach without repeating the visible controls.
struct InterfaceHelpButton: View {
    let title: String
    let text: String
    var identifier: String = ""
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $presented) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { presented = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("关闭说明")
                }
                Text(text).font(.system(size: 12)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(width: 320)
        }
    }
}
