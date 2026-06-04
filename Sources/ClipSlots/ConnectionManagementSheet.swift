import SwiftUI

struct ConnectionManagementSheet: View {
    @ObservedObject var store: SlotStoreObservable
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var fromSlot: Int = 1
    @State private var toSlot: Int = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            chainSummarySection
            addConnectionSection
            edgeListSection
            Divider()
            footer
        }
        .padding(18)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("连接管理")
                    .font(.system(size: 18, weight: .semibold))
                Text("v2.7.1 先使用稳定列表管理连接，主界面只保留色点提醒。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var chainSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前链路")
                .font(.headline)
            let chains = store.connectionChainSummaries()
            if chains.isEmpty {
                Text("当前槽位组还没有连接")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            } else {
                ForEach(chains, id: \.self) { chain in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(SlotConnectionColor.color(for: store.currentConnectionMap.colorId(for: chain.first ?? 1)))
                            .frame(width: 8, height: 8)
                        Text(compactChainDescription(chain))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                        Spacer()
                        Text("串联 \(chain.count) 个")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                }
            }
        }
    }

    private var addConnectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("新增连接")
                .font(.headline)
            HStack(spacing: 10) {
                Picker("从槽位", selection: $fromSlot) {
                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                }
                .frame(width: 120)

                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)

                Picker("到槽位", selection: $toSlot) {
                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                }
                .frame(width: 120)

                Button {
                    store.addManagedConnection(fromSlot: fromSlot, toSlot: toSlot)
                } label: {
                    Label("添加连接", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(fromSlot == toSlot)
            }
        }
    }

    private var edgeListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("连接列表")
                .font(.headline)
            if store.currentConnectionMap.edges.isEmpty {
                Text("暂无连接边")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.currentConnectionMap.edges) { edge in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(SlotConnectionColor.color(for: edge.colorId))
                                    .frame(width: 8, height: 8)
                                Text("槽位 \(edge.fromSlot) → 槽位 \(edge.toSlot)")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Button(role: .destructive) {
                                    store.deleteManagedConnection(edge.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("十槽位全串联") { store.applyBuiltInFullChainTemplate() }
            Button("导出模板") { store.exportConnectionTemplate() }
            Button("导入模板") { store.importConnectionTemplate() }
            Spacer()
            Button("清除连接", role: .destructive) { store.confirmAndClearCurrentConnections() }
        }
        .buttonStyle(.bordered)
    }
}
