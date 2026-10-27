import SwiftUI
import ClipSlotsKit

struct ModelHubConfigurationView: View {
    @ObservedObject var models: ModelWorkspaceStore
    var editProfile: (ModelProfile) -> Void
    @State private var section = "模型目录"
    @State private var search = ""
    @State private var kind = ""
    @State private var provider = ""
    @State private var detail: TapNowModelCatalog.Entry?
    @State private var serviceDraft: ModelServiceConnection?
    private let sections = ["模型目录", "已接入", "服务连接", "用途路由"]
    init(models: ModelWorkspaceStore, initialSection: String = "模型目录", editProfile: @escaping (ModelProfile) -> Void) {
        self.models = models; self.editProfile = editProfile
        _section = State(initialValue: initialSection)
    }
    private var entries: [TapNowModelCatalog.Entry] {
        (models.catalog?.entries ?? []).filter {
            (kind.isEmpty || $0.kind.rawValue == kind) && (provider.isEmpty || $0.provider == provider)
                && (search.isEmpty || ($0.displayName + $0.model + ($0.provider ?? "") + $0.description).localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ForEach(sections, id: \.self) { title in
                    Button { section = title } label: {
                        Text(title).font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(section == title ? TapSkin.tone(0xe9ebf0, 0x353840) : .clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("model-hub-\(title)")
                }
                Spacer(minLength: 0)
            }
            switch section {
            case "模型目录": catalog
            case "已接入": connected
            case "服务连接": services
            default: routes
            }
        }
        .sheet(item: $detail) { item in
            VStack(alignment: .leading, spacing: 16) {
                Text(item.displayName).font(.system(size: 22, weight: .semibold))
                Text("\(item.kind.title) · \(item.model) · \(item.provider ?? "未声明") · \(item.statusTitle)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(item.description).font(.system(size: 12))
                ScrollView {
                    Text((try? item.config.encodedText()) ?? "").font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(12).background(TapSkin.tone(0xf3f4f7, 0x24262b), in: RoundedRectangle(cornerRadius: 10))
                Text("TapNow \(models.catalog?.sourceVersion ?? "") · \(item.sourceSymbol) · UTF-16 \(item.sourceRange)\n函数和服务端条件保留在原配置中。目录标识需映射为实际服务的模型标识。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("关闭") { detail = nil }
                    Button("接入此模型") { detail = nil; editProfile(item.draft()) }
                }
            }.padding(24).frame(width: 680, height: 660)
        }
        .sheet(item: $serviceDraft) { ModelServiceEditor(service: $0, models: models) }
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(TapSkin.tone(0xffffff, 0x24262b), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(TapSkin.tone(0xe5e6eb, 0x353840), lineWidth: 1))
    }
    private var catalog: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                HStack(spacing: 24) {
                    ForEach(ModelKind.allCases) { category in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(models.catalog?.counts[category.rawValue] ?? 0)").font(.system(size: 24, weight: .semibold))
                            Text(category.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text("TapNow \(models.catalog?.sourceVersion ?? "") · 完整客户端目录 · 155 个媒体变体 · 隐藏与地区条件条目均保留")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                TextField("搜索模型名称、标识或用途", text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("model-hub-search")
                Picker("类型", selection: $kind) {
                    Text("全部类型").tag("")
                    ForEach(ModelKind.allCases) { Text($0.title).tag($0.rawValue) }
                }.frame(width: 125)
                Picker("路由", selection: $provider) {
                    Text("全部路由").tag("")
                    ForEach(Array(Set((models.catalog?.entries ?? []).compactMap(\.provider))).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(width: 145)
            }
            Text("目录路由属于 TapNow；接入时填写真实上游标识。实时可用性由所配置服务决定。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            GeometryReader { size in
                VStack(spacing: 0) {
                    HStack {
                        Text("模型 / 标识").frame(maxWidth: .infinity, alignment: .leading)
                        Text("类型").frame(width: 44)
                        if size.size.width > 850 {
                            Text("TapNow 路由").frame(width: 100, alignment: .leading)
                            Text("支持模式").frame(width: 200, alignment: .leading)
                        }
                        Text("状态").frame(width: 80)
                        Text("操作").frame(width: 96)
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(12)
                    Divider()
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { item in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(item.model).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.kind.title).font(.system(size: 11)).frame(width: 44)
                                if size.size.width > 850 {
                                    Text(item.provider ?? "—").font(.system(size: 11)).frame(width: 100, alignment: .leading)
                                    Text(item.modes.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                                        .frame(width: 200, alignment: .leading)
                                }
                                Text(models.document.profiles.contains { $0.catalogID == item.id } ? "已绑定" : item.statusTitle)
                                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 80)
                                HStack(spacing: 8) {
                                    Button("详情") { detail = item }
                                    Button("接入") { editProfile(item.draft()) }
                                }.font(.system(size: 11)).frame(width: 96)
                            }.padding(12).accessibilityIdentifier("catalog-\(item.model)")
                            Divider().opacity(0.5)
                        }
                    }
                }.background(TapSkin.tone(0xffffff, 0x24262b), in: RoundedRectangle(cornerRadius: 12))
            }.frame(height: CGFloat(entries.count) * 65 + 42)
            Text("显示 \(entries.count) / \(models.catalog?.entries.count ?? 0) 个模型").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var connected: some View {
        VStack(alignment: .leading, spacing: 12) {
            if models.document.profiles.filter({ !$0.isCLI }).isEmpty {
                card { Text("从目录接入模型，或新增自定义 API 模型。").foregroundStyle(.secondary) }
            }
            ForEach(models.document.profiles.filter { !$0.isCLI }) { profile in
                card {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(profile.name).font(.system(size: 15, weight: .semibold))
                            Text("\(profile.kind.title) · \(profile.model) · \(profile.contract.title)").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(profile.serviceID.flatMap { id in models.document.services?.first { $0.id == id }?.name } ?? profile.endpoint)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(!profile.enabled ? "已停用" : models.profiles.contains { $0.id == profile.id } ? "配置就绪" : "连接不可用")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("编辑") { editProfile(profile) }
                        Button("复制") {
                            var copy = profile; copy.id = UUID().uuidString; copy.name += " 副本"
                            if copy.serviceID == nil { copy.credentialAccount = nil; copy.credentialService = nil; copy.legacyKeyAccount = nil }
                            editProfile(copy)
                        }
                        Button("移除") { Task { await models.removeProfile(profile.id) } }
                    }
                }
            }
        }
    }
    private var services: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("一个服务连接可供多个模型共享地址与认证。").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("新增连接") { serviceDraft = ModelServiceConnection() }.accessibilityIdentifier("model-hub-new-service")
            }
            ForEach(models.document.services ?? []) { service in
                card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(service.name).font(.system(size: 15, weight: .semibold))
                                Text(service.baseURL).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                                Text("\(models.document.profiles.filter { $0.serviceID == service.id }.count) 个绑定模型 · 共享并发 \(service.concurrency) · \(service.enabled ? "启用" : "停用")")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("只读发现") { Task { await models.discoverService(service) } }
                                .disabled(models.discoveringServiceID != nil || service.discoveryURL.isEmpty)
                            Button("编辑") { serviceDraft = service }
                            Button("移除") { Task { await models.removeService(service.id) } }
                        }
                        if let discovered = models.discoveredModels[service.id] {
                            DisclosureGroup("发现 \(discovered.count) 个上游模型") {
                                ForEach(discovered) { model in
                                    HStack {
                                        Text(model.title).font(.system(size: 11)).textSelection(.enabled)
                                        Spacer()
                                        Button("接入") { var p = ModelProfile(); p.name = model.title; p.model = model.id; p.serviceID = service.id; p.endpoint = "chat/completions"; editProfile(p) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private var routes: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                Text("用途路由").font(.system(size: 17, weight: .semibold))
                Text("选择默认模型。节点可覆盖；切换只影响下一次请求，已提交任务使用原配置。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(ModelPurpose.allCases) { purpose in
                    Picker(purpose.title, selection: Binding(get: { models.document.defaults[purpose.rawValue] ?? "" },
                        set: { id in Task { await models.setDefault(purpose, id: id) } })) {
                        Text("未设置 / 沿用原配置").tag("")
                        ForEach(models.profiles.filter { models.supports($0, purpose: purpose) }) {
                            Text($0.name).tag($0.id)
                        }
                    }.frame(maxWidth: 560)
                }
            }
        }
    }
}

private struct ModelServiceEditor: View {
    @State var service: ModelServiceConnection
    @ObservedObject var models: ModelWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("共享服务连接").font(.system(size: 21, weight: .semibold))
            Form {
                TextField("名称", text: $service.name)
                TextField("基础地址", text: $service.baseURL)
                Text("模型请求路径会接在此地址后。也可为模型填写完整 URL。").font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("需要认证", isOn: $service.requiresKey)
                if service.requiresKey {
                    SecureField("新密钥（留空保留）", text: $key)
                    TextField("认证请求头", text: $service.authHeader)
                    TextField("认证前缀", text: $service.authPrefix)
                }
                TextField("只读发现地址 / 相对路径", text: $service.discoveryURL)
                TextField("模型数组路径", text: $service.discoveryPath)
                Stepper("共享并发：\(service.concurrency)", value: $service.concurrency, in: 1...14)
                TextField("超时 / 秒", value: $service.timeout, format: .number)
                Toggle("启用", isOn: $service.enabled)
            }.textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            Text("密钥存入 macOS 钥匙串；模型发现只发送 GET 请求。").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { Task { if await models.saveService(service, key: key) { dismiss() } else { error = models.message } } }
            }
        }.padding(24).frame(width: 580, height: 530)
    }
}
