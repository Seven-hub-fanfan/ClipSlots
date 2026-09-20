import Foundation

/// 画布**项目**（v2.13.0）。
///
/// ## 为什么要引入这个维度
///
/// v2.12.x 全 App 只有一张画布（`canvas/canvas.json` 硬编码单文件）。用户要「新建项目」：
/// 一条片子一张画布，互不干扰。
///
/// ## 它同时解决了另一个问题
///
/// v2.11.8 给画布节点安排了一个保留组「未入库」当停车场（见 `SpecialSlotStorage.unfiledGroupId`），
/// 容量 60。单张画布时够用；一旦有多个项目，60 个槽位变成所有项目共享的池子 —— 三个项目各 25 个
/// 节点就撞墙，而且「删掉整个项目」没法干净地把它那部分内容一起带走。
///
/// 所以每个项目自带一个**私有保留组**（`privateGroupId`）：
///
/// - 容量各自独立，项目之间不会互相挤
/// - 删项目 = 删它的私有组（整目录进 `.trash`，30 天可恢复）
/// - 它和「未入库」走同一条保留组过滤（`SpecialSlotStorage.isReservedGroupId`），因此同样不会
///   出现在槽位库的组列表、页面分区和 `clipslots list` 里
///
/// ## 默认项目为什么复用 `__unfiled__`
///
/// 老用户的画布内容全在 `__unfiled__` 里。如果默认项目也用 `__canvas__default`，升级时就得把
/// 那个组的内容整体搬家 —— 搬家是有损操作（附件外置、缩略图缓存、Label 都要跟着走），而收益
/// 只是让命名整齐。默认项目直接认领 `__unfiled__` 当私有组，升级零迁移。
public struct CanvasProject: Codable, Identifiable, Equatable {

    /// 默认项目的 id。**固定字面量**，不是 UUID：升级路径要能无条件认出"那个老画布"。
    public static let defaultId = "default"
    public static let defaultName = "默认项目"

    /// 项目名最大长度。与组名（8 字）不同——项目名只出现在一个下拉里，没有标签栏宽度约束，
    /// 但仍然要有上限，否则切换器会被一个 200 字的名字撑爆。
    public static let maxNameLength = 20

    public var id: String
    public var name: String
    public var createdAt: Date
    /// 最后一次被打开或编辑的时间。切换器按它倒序排（最近用的在最上面）。
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                name: String,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 该项目的私有保留组 id（画布自有内容的落点）。
    ///
    /// 默认项目认领历史上的 `__unfiled__`，理由见类型注释。
    public var privateGroupId: String {
        id == CanvasProject.defaultId
            ? SpecialSlotStorage.unfiledGroupId
            : SpecialSlotStorage.canvasGroupPrefix + id
    }

    /// 私有组在存储层的展示名。用户看不到（组被过滤掉了），但它会进 `index.json`，
    /// 留一个可读的名字是为了有人翻磁盘时能看懂这堆目录是什么。
    public var privateGroupName: String {
        id == CanvasProject.defaultId
            ? SpecialSlotStorage.unfiledGroupName
            : "画布·\(name)"
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt
    }

    /// 容错解码。项目索引丢一个字段不该让整个项目列表打不开（那等于用户所有画布一起消失）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = (try? c.decode(String.self, forKey: .id)) ?? ""
        id = rawId.isEmpty ? UUID().uuidString : rawId
        let rawName = (try? c.decode(String.self, forKey: .name)) ?? ""
        name = rawName.isEmpty ? CanvasProject.defaultName : rawName
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? createdAt
    }

    // MARK: - 命名

    /// 把用户输入规整成一个可用的项目名。
    ///
    /// 空串回落到"未命名项目"而不是拒绝：新建项目时用户可能直接回车，这时给个名字比弹错误好。
    public static func sanitizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "未命名项目" }
        return String(trimmed.prefix(maxNameLength))
    }

    /// 在已有名字里挑一个不重复的名字（`项目` → `项目 2` → `项目 3`）。
    ///
    /// 重名本身不影响数据（身份是 id），但两个一模一样的名字挂在切换器里等于让用户抓瞎。
    public static func uniqueName(base raw: String, existing: [String]) -> String {
        let base = sanitizedName(raw)
        let taken = Set(existing)
        if !taken.contains(base) { return base }
        var n = 2
        while true {
            let candidate = String("\(base) \(n)".prefix(maxNameLength))
            // prefix 截断后可能又撞上：再退一步用纯序号收尾，保证循环一定能结束。
            if !taken.contains(candidate) { return candidate }
            if n > 999 { return "\(UUID().uuidString.prefix(8))" }
            n += 1
        }
    }

    /// 新建项目的默认名：`项目 N`，N 取当前不重复的最小值。
    public static func nextDefaultName(existing: [String]) -> String {
        uniqueName(base: "项目", existing: existing)
    }
}

// MARK: - 项目索引

/// 全部项目 + 当前打开的是哪个（落盘在 `canvas/projects.json`）。
public struct CanvasProjectIndex: Codable, Equatable {

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var projects: [CanvasProject]
    public var activeProjectId: String

    public init(schemaVersion: Int = CanvasProjectIndex.currentSchemaVersion,
                projects: [CanvasProject],
                activeProjectId: String) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.activeProjectId = activeProjectId
    }

    /// 只有默认项目的初始索引。
    public static var initial: CanvasProjectIndex {
        let p = CanvasProject(id: CanvasProject.defaultId, name: CanvasProject.defaultName)
        return CanvasProjectIndex(projects: [p], activeProjectId: p.id)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projects, activeProjectId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        projects = (try? c.decode([CanvasProject].self, forKey: .projects)) ?? []
        activeProjectId = (try? c.decode(String.self, forKey: .activeProjectId)) ?? ""
        self = CanvasProjectIndex.normalized(self)
    }

    /// 规整索引：去重、补默认项目、修正 activeProjectId。
    ///
    /// **永远不能返回空列表**：画布 UI 假定"当前一定有一个项目"，空列表会让整个画布页变成一片
    /// 什么都点不了的灰。宁可凭空补一个默认项目，也不要让用户面对一个死界面。
    public static func normalized(_ raw: CanvasProjectIndex) -> CanvasProjectIndex {
        var seen = Set<String>()
        var projects: [CanvasProject] = []
        for p in raw.projects {
            guard !p.id.isEmpty, !seen.contains(p.id) else { continue }
            seen.insert(p.id)
            projects.append(p)
        }
        if projects.isEmpty {
            projects = [CanvasProject(id: CanvasProject.defaultId, name: CanvasProject.defaultName)]
        }
        let active = projects.contains(where: { $0.id == raw.activeProjectId })
            ? raw.activeProjectId
            // 指向一个不存在的项目（项目被另一个进程删掉 / 索引被手改）→ 回落到第一个，
            // 而不是保留悬空 id 让画布加载出一张永远空的图。
            : projects[0].id
        return CanvasProjectIndex(schemaVersion: CanvasProjectIndex.currentSchemaVersion,
                                  projects: projects,
                                  activeProjectId: active)
    }

    public var activeProject: CanvasProject? {
        projects.first { $0.id == activeProjectId }
    }

    /// 切换器里的展示顺序：最近用过的在最上面。
    public var displayOrder: [CanvasProject] {
        projects.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.createdAt < $1.createdAt
        }
    }

    /// 能不能删 `id`。**最后一个项目不能删**：删完就没有当前项目了，见 `normalized` 的注释。
    public func canDelete(_ id: String) -> Bool {
        projects.count > 1 && projects.contains { $0.id == id }
    }
}
