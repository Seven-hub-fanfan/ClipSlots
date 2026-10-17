import AppKit
import SwiftUI

struct AgentComposerItem: Identifiable, Equatable {
    enum Action: Equatable {
        case skills, model, newConversation, summarize
        case skill(name: String, path: String)
    }
    let id: String
    let title: String
    let detail: String
    let action: Action
    var isSkill: Bool { if case .skill = action { return true }; return false }
}

/// Shared by the native editor and the visible menu; selection never takes keyboard focus.
@MainActor
final class AgentComposerCompletion: ObservableObject {
    struct Token: Equatable {
        let range: NSRange
        let trigger: String
        let query: String
    }
    @Published private(set) var rows: [AgentComposerItem] = []
    @Published private(set) var selected = 0
    @Published private(set) var token: Token?
    weak var editor: AgentDraftEditor.Editor?
    private var dismissed: Token?

    static func token(in text: String, selection: NSRange) -> Token? {
        let ns = text as NSString
        guard selection.length == 0, selection.location <= ns.length else { return nil }
        let prefix = ns.substring(to: selection.location)
        guard let expression = try? NSRegularExpression(pattern: #"(?:^|\s)([/\$])([^\s/\$]*)$"#),
              let match = expression.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) else { return nil }
        let start = match.range(at: 1).location
        var end = selection.location
        while end < ns.length {
            let unit = ns.substring(with: NSRange(location: end, length: 1))
            if unit.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { break }
            end += 1
        }
        return Token(range: NSRange(location: start, length: end - start),
                     trigger: (prefix as NSString).substring(with: match.range(at: 1)),
                     query: (prefix as NSString).substring(with: match.range(at: 2)))
    }

    func update(text: String, selection: NSRange, marked: Bool, items: [AgentComposerItem]) {
        let next = marked ? nil : Self.token(in: text, selection: selection)
        if next != token, selected != 0 { selected = 0 }
        if next != dismissed { dismissed = nil }
        if token != next { token = next }
        guard let next, next != dismissed else {
            if !rows.isEmpty { rows = [] }
            return
        }
        let matches = Array(items.filter {
            (next.trigger != "$" || $0.isSkill)
                && (next.query.isEmpty || $0.title.localizedCaseInsensitiveContains(next.query)
                    || $0.detail.localizedCaseInsensitiveContains(next.query))
        }.prefix(40))
        if rows != matches { rows = matches }
        let index = min(selected, max(0, rows.count - 1))
        if selected != index { selected = index }
    }

    var isOpen: Bool { token != nil && token != dismissed }
    func dismiss() { dismissed = token; rows = [] }
    func move(_ offset: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + offset + rows.count) % rows.count
    }
    func accept(_ item: AgentComposerItem? = nil) {
        guard let item = item ?? (rows.indices.contains(selected) ? rows[selected] : nil),
              let token else { return }
        editor?.accept(item, range: token.range)
    }
    func openSkills() { dismissed = nil; editor?.openSkills() }
}

struct AgentComposerMenu: View {
    @ObservedObject var completion: AgentComposerCompletion
    let isScanning: Bool
    @State private var hoveredID: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(completion.token?.trigger == "$" ? "引用技能" : "快捷操作与技能")
                Spacer()
                Text("↑↓ 选择 · ↵ / Tab 确认 · Esc 关闭")
            }
            .font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk)
            .padding(.horizontal, 10).padding(.vertical, 6)
            if completion.rows.isEmpty {
                Text(isScanning ? "正在扫描本机技能…" : "没有匹配项，继续输入或按 Esc 关闭")
                    .font(.system(size: 12)).foregroundColor(TapSkin.secondaryInk).padding(10)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(completion.rows.enumerated()), id: \.element.id) { index, item in
                                Button { completion.accept(item) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: item.isSkill ? "sparkles" : "command")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text(item.detail).font(.system(size: 10))
                                                .foregroundColor(TapSkin.secondaryInk).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                        if completion.selected == index { Image(systemName: "return") }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(completion.selected == index || hoveredID == item.id ? CreativeMenuStyle.hover : .clear,
                                                in: RoundedRectangle(cornerRadius: 10))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).id(item.id)
                                .onHover { if $0 { hoveredID = item.id } else if hoveredID == item.id { hoveredID = nil } }
                                .accessibilityIdentifier("agent-completion-" + item.id)
                            }
                        }.padding(.horizontal, 4)
                    }
                    .frame(height: min(230, CGFloat(completion.rows.count) * 48))
                    .onChange(of: completion.selected) { index in
                        hoveredID = nil
                        if completion.rows.indices.contains(index) {
                            proxy.scrollTo(completion.rows[index].id)
                        }
                    }
                }
            }
        }
        .padding(4)
        .background(CreativeMenuStyle.fill, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(CreativeMenuStyle.border, lineWidth: 0.5))
        .accessibilityIdentifier("agent-completion-menu")
    }
}
