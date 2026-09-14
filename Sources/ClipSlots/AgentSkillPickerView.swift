import SwiftUI
import ClipSlotsKit

// MARK: - Skill 选择器
//
// 输入区「Skill」按钮弹出的面板：列出本机已安装的 Skill（App bundle 内置 +
// 插件市场上传 + 各 Agent 目录），可逐个勾选是否开放给 Agent。
//
// 勾选即授权。这不是装饰性开关——启用一个 Skill 意味着 Agent 可以读它的
// SKILL.md 并执行它目录内的脚本（见 AgentToolRegistry 的安全边界说明）。
// 所以默认全不选，并在面板底部把这件事说清楚，而不是藏在文档里。

struct AgentSkillPickerView: View {
    @ObservedObject private var library = AgentSkillLibrary.shared
    @AppStorage(AgentPreferences.enabledSkillsKey) private var enabledRaw = ""

    /// 内置 CLI 工具数量，仅用于展示"当前 Agent 手里有什么"。
    let builtinToolCount: Int

    private var enabledSlugs: Set<String> { AgentPreferences.decodeEnabledSlugs(enabledRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)

            if library.skills.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(library.skills) { skill in
                            row(skill)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 320)
            }

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 360)
        .onAppear {
            // 首次打开或距上次扫描较久时刷新，避免每次点开都扫盘。
            if library.skills.isEmpty || (library.lastScanAt?.timeIntervalSinceNow ?? -999) < -30 {
                library.refresh()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.chromeAccentInk)
            Text("Skill 工具")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if library.isScanning {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else {
                Button {
                    library.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("重新扫描 Skill 目录")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(library.isScanning ? "正在扫描…" : "没有发现已安装的 Skill")
                .font(.system(size: 12, weight: .medium))
            Text("可在「插件」面板上传 Skill（.zip 或 SKILL.md），或安装到 ~/.codex/skills 后回来刷新。")
                .font(.system(size: 10))
                .foregroundColor(AppTheme.canvasCardMetaInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private func row(_ skill: AgentSkill) -> some View {
        let isOn = enabledSlugs.contains(skill.slug)
        return Button {
            toggle(skill.slug)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundColor(isOn ? AppTheme.chromeAccentInk : AppTheme.canvasCardMetaInk)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        tag(skill.source.displayName)
                        if let version = skill.version { tag("v\(version)") }
                    }
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.system(size: 10))
                            .foregroundColor(AppTheme.canvasCardMetaInk)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // 说清楚启用后 Agent 到底多了什么能力，而不是只说"已启用"。
                    HStack(spacing: 8) {
                        if !skill.declaredTools.isEmpty {
                            capability("\(skill.declaredTools.count) 个声明工具", icon: "wrench.and.screwdriver")
                        }
                        if !skill.scripts.isEmpty {
                            capability("\(skill.scripts.count) 个可执行脚本", icon: "terminal")
                        }
                        if skill.declaredTools.isEmpty && skill.scripts.isEmpty {
                            capability("仅说明文档", icon: "doc.text")
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(isOn ? AppTheme.chipBackground : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(skill.markdownPath)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(AppTheme.chipBackground)
            .foregroundColor(AppTheme.canvasCardMetaInk)
            .clipShape(Capsule())
    }

    private func capability(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text).font(.system(size: 9))
        }
        .foregroundColor(AppTheme.canvasCardMetaInk)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "hammer.fill").font(.system(size: 9))
                Text("内置槽位工具 \(builtinToolCount) 个始终可用")
                    .font(.system(size: 10))
                Spacer()
                if !enabledSlugs.isEmpty {
                    Button("全部关闭") { enabledRaw = "" }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
            .foregroundColor(AppTheme.canvasCardMetaInk)

            Text("启用后 Agent 可读取该 Skill 的说明并执行其目录内脚本，请只启用你信任的 Skill。")
                .font(.system(size: 9))
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func toggle(_ slug: String) {
        var slugs = enabledSlugs
        if slugs.contains(slug) { slugs.remove(slug) } else { slugs.insert(slug) }
        enabledRaw = AgentPreferences.encodeEnabledSlugs(slugs)
    }
}
