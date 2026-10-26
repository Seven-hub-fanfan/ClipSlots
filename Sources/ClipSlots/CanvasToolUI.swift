import SwiftUI

/// Shared native controls for the floating tool panels.
enum CanvasToolUI {
    static let radius: CGFloat = 16
    static let controlHeight: CGFloat = 30
}

struct CanvasToolButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        CanvasToolButtonBody(configuration: configuration, prominent: prominent)
    }
    private struct CanvasToolButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minHeight: CanvasToolUI.controlHeight)
                .foregroundColor(prominent ? CanvasSkin.onAccent : CanvasSkin.ink)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(prominent ? CanvasSkin.accent : CanvasSkin.subtleFill.opacity(hovered ? 1 : 0.65)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(CanvasSkin.border.opacity(prominent ? 0 : 0.7), lineWidth: 0.5))
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 9))
                .onHover { hovered = $0 }
        }
    }
}

struct CanvasToolFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(CanvasSkin.subtleFill))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CanvasSkin.border, lineWidth: 0.5))
    }
}

struct CanvasToolSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(CanvasSkin.secondaryInk)
                .accessibilityIdentifier("tool-section-\(title)")
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(CanvasSkin.cardEmptyFill))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(CanvasSkin.border, lineWidth: 0.5))
    }
}

struct CanvasToolMenuLabel: View {
    let title: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).frame(width: 12) }
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10).frame(height: CanvasToolUI.controlHeight)
        .background(RoundedRectangle(cornerRadius: 9).fill(CanvasSkin.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(CanvasSkin.border, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct CanvasToolChoice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [(Value, String)]
    private var selectedTitle: String { choices.first(where: { $0.0 == selection })?.1 ?? title }
    var body: some View {
        Menu {
            ForEach(choices.indices, id: \.self) { index in
                Button {
                    selection = choices[index].0
                } label: {
                    if selection == choices[index].0 {
                        Label(choices[index].1, systemImage: "checkmark")
                    } else {
                        Text(choices[index].1)
                    }
                }
            }
        } label: {
            CanvasToolMenuLabel(title: selectedTitle.count > 18 ? String(selectedTitle.prefix(12)) + "…" : selectedTitle)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(title)
        .help("\(title) · \(selectedTitle)")
    }
}

struct CanvasToolPrompt: View {
    @Binding var text: String
    let placeholder: String
    var height: CGFloat = 88
    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).foregroundColor(CanvasSkin.faintInk)
                    .padding(.horizontal, 5).padding(.top, 7).allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .scrollContentBackground(.hidden).background(Color.clear)
                .accessibilityLabel(placeholder)
        }
        .font(.system(size: 12))
        .frame(height: height)
    }
}

struct CanvasToolEmptyPreview: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light))
                .foregroundColor(CanvasSkin.faintInk)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 18).fill(CanvasSkin.subtleFill))
            Text(title).font(.system(size: 13, weight: .medium))
            Text(subtitle).font(.system(size: 11)).foregroundColor(CanvasSkin.secondaryInk)
                .multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
