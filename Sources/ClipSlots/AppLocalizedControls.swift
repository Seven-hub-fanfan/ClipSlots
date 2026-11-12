import SwiftUI
import ClipSlotsKit

/// A language change updates labels in place without recreating the workspace,
/// its editors, or the canvas state.
struct AppLocalizedText: View {
    let key: String
    let arguments: [CVarArg]
    @AppStorage(AppInterfaceLanguage.preferenceKey) private var languageRaw = AppInterfaceLanguage.chinese.rawValue

    init(_ key: String, _ arguments: CVarArg...) {
        self.key = key
        self.arguments = arguments
    }
    init(_ key: String, arguments: [CVarArg]) {
        self.key = key
        self.arguments = arguments
    }
    var body: some View {
        let language = AppInterfaceLanguage.resolve(languageRaw)
        Text(verbatim: arguments.isEmpty ? AppInterfaceStrings.text(key, language: language) :
            AppInterfaceStrings.format(key, language: language, arguments: arguments))
    }
}

extension Button where Label == AppLocalizedText {
    init(localized key: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { AppLocalizedText(key) }
    }
}

extension Toggle where Label == AppLocalizedText {
    init(localized key: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { AppLocalizedText(key) }
    }
}

extension Picker where Label == AppLocalizedText {
    init(localized key: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { AppLocalizedText(key) }
    }
}

extension Label where Title == AppLocalizedText, Icon == Image {
    init(localized key: String, systemImage: String) {
        self.init { AppLocalizedText(key) } icon: { Image(systemName: systemImage) }
    }
    init(localized key: String, arguments: [CVarArg], systemImage: String) {
        self.init { AppLocalizedText(key, arguments: arguments) } icon: { Image(systemName: systemImage) }
    }
}

private struct AppLocalizedHelp: ViewModifier {
    let key: String
    let arguments: [CVarArg]
    @AppStorage(AppInterfaceLanguage.preferenceKey) private var languageRaw = AppInterfaceLanguage.chinese.rawValue
    func body(content: Content) -> some View {
        let language = AppInterfaceLanguage.resolve(languageRaw)
        return content.help(arguments.isEmpty ? AppInterfaceStrings.text(key, language: language) :
            AppInterfaceStrings.format(key, language: language, arguments: arguments))
    }
}

private struct AppLocalizedAccessibilityLabel: ViewModifier {
    let key: String
    let arguments: [CVarArg]
    @AppStorage(AppInterfaceLanguage.preferenceKey) private var languageRaw = AppInterfaceLanguage.chinese.rawValue
    func body(content: Content) -> some View {
        let language = AppInterfaceLanguage.resolve(languageRaw)
        return content.accessibilityLabel(arguments.isEmpty ? AppInterfaceStrings.text(key, language: language) :
            AppInterfaceStrings.format(key, language: language, arguments: arguments))
    }
}

private struct AppLocalizedAccessibilityValue: ViewModifier {
    let key: String
    @AppStorage(AppInterfaceLanguage.preferenceKey) private var languageRaw = AppInterfaceLanguage.chinese.rawValue
    func body(content: Content) -> some View {
        content.accessibilityValue(AppInterfaceStrings.text(key, language: AppInterfaceLanguage.resolve(languageRaw)))
    }
}

extension View {
    func localizedHelp(_ key: String, _ arguments: CVarArg...) -> some View {
        modifier(AppLocalizedHelp(key: key, arguments: arguments))
    }
    func localizedAccessibilityLabel(_ key: String, _ arguments: CVarArg...) -> some View {
        modifier(AppLocalizedAccessibilityLabel(key: key, arguments: arguments))
    }
    func localizedAccessibilityValue(_ key: String) -> some View {
        modifier(AppLocalizedAccessibilityValue(key: key))
    }
}
