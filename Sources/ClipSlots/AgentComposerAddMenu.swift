import SwiftUI
import ClipSlotsKit

struct AgentComposerAddMenu: View {
    @ObservedObject var model: AgentChatModel
    @ObservedObject var sync: AgentMarketSyncStore
    let localItems: [AgentComposerItem]
    let fromCanvas: () -> Void
    let attach: () -> Void
    let directory: () -> Void
    let manage: (String) -> Void
    let importSkill: (Bool) -> Void
    let createSkill: () -> Void
    let localPick: (AgentComposerItem.Action) async throws -> Bool
    let onUse: () -> Void
    var workflowLibrary: (() -> Void)?
    @State private var skills = false
    @State private var apps = false
    private var recent: AgentMarketItem? {
        sync.managementItems.first { $0.kind == "app" && sync.sourceAdded($0) }
    }
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if skills { list("skill") }
            if apps { list("app") }
            root
        }.foregroundStyle(TapSkin.ink)
            .accessibilityElement(children: .contain).accessibilityIdentifier("agent-composer-add-menu")
    }
    private var root: some View {
        VStack(spacing: 2) {
            row("从画布添加", symbol: "square.on.square", action: fromCanvas)
                .disabled(model.canvasContext == nil).accessibilityIdentifier("agent-add-canvas-reference")
            row("上传附件", symbol: "paperclip", action: attach)
                .disabled(model.isImportingAttachments)
            row("添加本地文件夹并记住授权", symbol: "folder", action: directory)
            Divider().padding(.vertical, 5)
            row("技能", symbol: "sparkles", trailing: true) { apps = false; skills = true }
                .onHover { if $0 { apps = false; skills = true } }
                .accessibilityIdentifier("agent-add-skills")
            Divider().padding(.vertical, 5)
            if let recent {
                Button { Task { await reference(recent) } } label: {
                    HStack(spacing: 9) {
                        MarketArtwork(item: recent, sync: sync).frame(width: 18, height: 18)
                        Text(recent.title).lineLimit(1)
                        Spacer()
                    }.font(.system(size: 12)).padding(.horizontal, 9).frame(height: 32).contentShape(Rectangle())
                }.buttonStyle(AgentMenuRowStyle()).accessibilityIdentifier("agent-add-recent")
            }
            row("全部应用", symbol: "square.grid.2x2", trailing: true) { skills = false; apps = true }
                .onHover { if $0 { skills = false; apps = true } }
                .accessibilityIdentifier("agent-add-apps")
        }.padding(7).frame(width: 236)
            .foregroundStyle(TapSkin.ink).background(TapSkin.tone(0xffffff, 0x222222))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(TapSkin.tone(0xe7e7e9, 0x333333), lineWidth: 0.5))
    }
    private func row(_ title: String, symbol: String, trailing: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: 2)
                if trailing { Image(systemName: "chevron.right").font(.system(size: 9)) }
            }.font(.system(size: 12)).padding(.horizontal, 9).frame(height: 32).contentShape(Rectangle())
        }.buttonStyle(AgentMenuRowStyle())
    }
    private func list(_ kind: String) -> some View {
        AgentInstalledApplicationList(model: model, sync: sync, kind: kind, localItems: localItems,
            localPick: localPick, onUse: onUse, onManage: { manage(kind == "app" ? "应用" : "技能") },
            importSkill: importSkill, createSkill: createSkill, workflowLibrary: workflowLibrary)
    }
    private func reference(_ item: AgentMarketItem) async {
        if !sync.isInstalled(item) { sync.connectionPrompt = item; onUse(); return }
        do {
            if !sync.sourceEnabled(item) { try await sync.changeInstallation(item, action: "enabled") }
            if try await model.prepareReference(loader: { try await sync.reference(item) }) { onUse() }
        }
        catch { model.errorText = error.localizedDescription }
    }
}

struct AgentInstalledApplicationList: View {
    @ObservedObject var model: AgentChatModel
    @ObservedObject var sync: AgentMarketSyncStore
    var kind = "app"
    let localItems: [AgentComposerItem]
    let localPick: (AgentComposerItem.Action) async throws -> Bool
    let onUse: () -> Void
    let onManage: () -> Void
    var importSkill: (Bool) -> Void = { _ in }
    var createSkill: () -> Void = {}
    var workflowLibrary: (() -> Void)?
    @State private var search = ""
    @State private var error: String?
    private var items: [AgentMarketItem] {
        sync.managementItems.filter { $0.kind == kind && sync.sourceAdded($0)
            && (kind != "skill" || sync.sourceEnabled($0))
            && (search.isEmpty || ($0.title + $0.summary).localizedCaseInsensitiveContains(search)) }
    }
    private var locals: [AgentComposerItem] {
        guard kind == "skill" else { return [] }
        return localItems.filter { $0.isSkill && !$0.id.contains("/market-sync/scopes/")
            && (search.isEmpty || ($0.title + $0.detail).localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(TapSkin.secondaryInk)
                TextField(kind == "app" ? "搜索应用" : "搜索技能", text: $search).textFieldStyle(.plain)
                    .accessibilityIdentifier("market-installed-search")
            }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 32)
                .background(TapSkin.tone(0xefeff0, 0x353535), in: RoundedRectangle(cornerRadius: 12))
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(items) { item in
                        Button {
                            Task {
                                if kind == "app", !sync.isInstalled(item) {
                                    sync.connectionPrompt = item; onUse(); return
                                }
                                do {
                                    if !sync.sourceEnabled(item) { try await sync.changeInstallation(item, action: "enabled") }
                                    if try await model.prepareReference(loader: { try await sync.reference(item) }) { onUse() }
                                }
                                catch { self.error = error.localizedDescription }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                MarketArtwork(item: item, sync: sync).frame(width: 16, height: 16)
                                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                Text(item.summary).font(.system(size: 12)).foregroundStyle(TapSkin.secondaryInk).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.horizontal, 9).frame(height: 32).contentShape(Rectangle())
                        }.buttonStyle(AgentMenuRowStyle()).disabled(model.isAddingSkill)
                            .accessibilityIdentifier("market-installed-" + item.name)
                    }
                    ForEach(locals) { item in
                        Button {
                            Task {
                                do { if try await localPick(item.action) { onUse() } }
                                catch { self.error = error.localizedDescription }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "sparkles").frame(width: 16)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(String(item.title.dropFirst())).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(item.detail).font(.system(size: 11)).foregroundStyle(TapSkin.secondaryInk).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.horizontal, 9).frame(height: 32).contentShape(Rectangle())
                        }.buttonStyle(AgentMenuRowStyle()).disabled(model.isAddingSkill)
                            .accessibilityIdentifier("agent-skill-pick-" + item.id)
                    }
                    if items.isEmpty && locals.isEmpty {
                        Text(search.isEmpty ? "尚未添加\(kind == "app" ? "应用" : "技能")" : "没有匹配结果")
                            .font(.system(size: 12)).foregroundStyle(TapSkin.secondaryInk).padding(20)
                    }
                }
            }.frame(height: min(320, CGFloat(max(1, items.count + locals.count)) * 32))
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            Divider()
            if kind == "skill" {
                if let workflowLibrary {
                    footer("我的创作 Skill", symbol: "square.stack.3d.up", action: workflowLibrary)
                        .accessibilityIdentifier("agent-workflow-skills")
                }
                footer("上传技能文件", symbol: "doc.badge.plus") { importSkill(false) }
                footer("上传技能文件夹", symbol: "folder.badge.plus") { importSkill(true) }
                footer("创建技能", symbol: "square.and.pencil", action: createSkill)
            }
            footer(kind == "app" ? "管理应用" : "管理技能", symbol: "slider.horizontal.3", action: onManage)
                .accessibilityIdentifier("market-installed-manage")
        }.padding(7).frame(width: 360)
            .foregroundStyle(TapSkin.ink).background(TapSkin.tone(0xffffff, 0x222222))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(TapSkin.tone(0xe7e7e9, 0x333333), lineWidth: 0.5))
            .accessibilityElement(children: .contain).accessibilityIdentifier("agent-installed-applications")
            .task { await sync.refreshManagement() }
    }
    private func footer(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 30)
                .contentShape(Rectangle())
        }.buttonStyle(AgentMenuRowStyle())
    }
}

private struct AgentMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration) }
    private struct RowBody: View {
        let configuration: Configuration
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .background(isEnabled && (hovered || configuration.isPressed) ? TapSkin.tone(0xf1f1f3,0x353535) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovered = $0 }
        }
    }
}
