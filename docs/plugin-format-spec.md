# `.clipslot-plugin` 包格式规范草案 (Draft v0.1)

> 本文档为 ClipSlots 插件系统的格式规范草案，供下一期实现「A 方案（真实安装第三方插件）」使用。
> 状态：**草案 / 待评审**。字段与约束在正式实现前可能调整。
> 关联版本：v2.9.8（C+ 方案：插件页面已上线，安装能力预留）。

## 1. 目标与定位

`.clipslot-plugin` 是 ClipSlots 第三方插件的分发与安装单元。设计目标：

- **单文件分发**：一个插件 = 一个可拖入 App 的文件，便于传播与安装。
- **声明式清单**：插件能力通过清单（manifest）声明，App 侧据此展示与管控。
- **安全可控**：明确权限边界，禁止插件直接访问用户磁盘数据层，统一通过 CLI / 受控 API 交互。
- **与 Skill 解耦**：官方 Skill（`clipslots-manager`）走内置通道；第三方插件走本规范。

## 2. 包结构

`.clipslot-plugin` 本质是一个 **ZIP 归档**（扩展名替换为 `.clipslot-plugin`），解包后目录结构如下：

```
my-plugin.clipslot-plugin        (ZIP 归档)
├── manifest.json                (必需) 插件清单
├── icon.png                     (可选) 128×128 图标，缺省用系统占位图
├── README.md                    (可选) 插件说明，展示在插件详情页
├── scripts/                     (可选) 可执行脚本 / 二进制
│   └── main                     入口脚本（由 manifest.entry 指定）
└── resources/                   (可选) 插件自带静态资源
```

- 归档根目录必须包含 `manifest.json`，否则安装时判定为非法包。
- 归档内路径统一使用正斜杠 `/`，禁止 `..` 等路径穿越。
- 单包解包后大小上限建议 **≤ 50 MB**（正式实现时可配置）。

## 3. `manifest.json` 字段规范

```jsonc
{
  "schemaVersion": 1,                    // 必需，清单格式版本，当前固定为 1
  "id": "com.example.my-plugin",         // 必需，反向域名唯一标识，安装冲突以此为准
  "name": "My Plugin",                   // 必需，展示名称（建议 ≤ 20 字）
  "version": "1.0.0",                    // 必需，语义化版本 SemVer
  "description": "一句话描述插件用途",     // 必需，展示在插件卡片（建议 ≤ 60 字）
  "author": "作者名",                    // 必需
  "homepage": "https://...",             // 可选，插件主页 / 仓库地址
  "minAppVersion": "2.10.0",             // 可选，要求的最低 ClipSlots 版本
  "kind": "cli-extension",               // 必需，插件类型，见 §4
  "entry": "scripts/main",               // 条件必需，入口相对路径（kind 决定是否需要）
  "permissions": [                       // 必需，声明所需权限，见 §5
    "clipslots.read",
    "clipslots.write"
  ],
  "commands": [                          // 可选，插件向 App 注册的命令 / 动作
    {
      "id": "organize",
      "title": "整理素材",
      "description": "按规则批量归档剪贴板素材"
    }
  ],
  "signature": "base64...",              // 可选（正式实现建议必需），包签名，见 §6
  "checksum": "sha256:..."               // 可选，除签名字段外内容的校验和
}
```

### 字段约束
- `id`：`^[a-z0-9]+(\.[a-z0-9-]+)+$`，全局唯一；重复安装同 `id` 视为「更新」。
- `version` / `minAppVersion`：遵循 SemVer（`MAJOR.MINOR.PATCH`）。
- `name` / `description`：纯文本，不允许含控制字符。
- 未知字段：解析时忽略并保留（前向兼容），不报错。

## 4. 插件类型 `kind`

| kind | 说明 | `entry` | 运行方式（拟定） |
|------|------|---------|------------------|
| `cli-extension` | 扩展 CLI 能力，向 `clipslots` 注册子命令 | 必需 | 沙盒子进程，stdin/stdout JSON 协议 |
| `action` | 在 GUI 中提供动作按钮（如批量整理） | 必需 | 受控子进程，参数经 JSON 传入 |
| `theme` | 提供外观主题（颜色 / 图标包） | 不需要 | 纯声明式，读取 `resources/` |
| `template` | 提供槽位/连接模板预设 | 不需要 | 纯数据，导入到模板库 |

> 本期（v2.9.8）仅上线插件页面与占位，以上运行机制在 A 方案落地时实现。

## 5. 权限模型 `permissions`

插件必须显式声明权限，App 安装时向用户展示并要求确认：

| 权限标识 | 含义 |
|----------|------|
| `clipslots.read` | 读取槽位/页面/组内容（经受控 API，不直接读磁盘） |
| `clipslots.write` | 写入/修改槽位内容 |
| `clipslots.delete` | 删除页面/组/槽位 |
| `clipboard.access` | 读写系统剪贴板 |
| `filesystem.read` | 读取用户选择的文件（需用户在文件面板授权） |
| `network` | 访问网络 |

原则：
- **最小权限**：未声明的权限一律拒绝。
- **无直连数据层**：插件禁止直接读写 `~/.local/share/clipslots/`，必须经 CLI / 受控 API。
- **用户可撤销**：插件页面提供逐项权限开关（正式实现）。

## 6. 签名与校验（安全）

- `checksum`：对除 `signature`、`checksum` 外的包内容计算 `sha256`，防止篡改。
- `signature`：正式实现建议对 `checksum` 做签名。官方插件用官方私钥签名并标记「已验证」徽章；第三方未签名插件安装时给出风险提示。
- 安装流程校验顺序：结构合法性 → `manifest.json` schema → checksum → signature（可选）→ 权限确认 → 落地。

## 7. 安装与生命周期（拟定）

1. 用户在「插件页面 → 第三方插件 → 添加插件」中选择或拖入 `.clipslot-plugin`。
2. App 解包到临时目录并按 §6 校验。
3. 展示插件信息 + 所需权限，用户确认。
4. 落地到插件目录（拟定）：`~/.local/share/clipslots/plugins/<id>/`。
5. 在插件页面以卡片形式展示，支持启用/禁用/卸载/查看详情。
6. 卸载即删除对应插件目录并注销其注册的命令/动作。

## 8. 版本与兼容

- `schemaVersion` 用于清单结构演进；App 只安装 `schemaVersion` ≤ 自身支持上限的插件。
- `minAppVersion` 高于当前 App 版本时，拒绝安装并提示升级 App。

## 9. 待决问题（Open Questions）

- 子进程运行时的沙盒粒度（App Sandbox / 自定义 seatbelt profile）。
- 插件与官方 Skill 的能力边界是否需要统一到同一注册表。
- 是否需要官方插件市场 / 分发渠道与签名信任链。
- 拖入安装的 UTI 类型注册（`com.clipslots.plugin`）与 Finder 关联。

---

*最后更新：v2.9.8。本规范为草案，正式实现（A 方案）时以最终版为准。*
