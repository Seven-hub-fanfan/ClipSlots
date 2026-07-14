---
name: clipslots-manager
description: 通过命令行工具 clipslots 以编程方式操作 macOS 剪贴板槽位管理器 ClipSlots。能读取/写入/检索槽位内容、把内容加载到系统剪贴板、批量整理文件夹素材到"页面→槽位组→槽位"三层结构、创建/删除页面与槽位组。适用场景：需要把文本或文件存进 ClipSlots 槽位、读出或搜索已存内容、把某槽位内容放到剪贴板供粘贴、按规则批量归档素材、清理整理槽位数据等。要求 macOS 且已安装 ClipSlots v2.9.7+（CLI 位于 ~/bin/clipslots）。
author: 帅帅
---

# ClipSlots CLI 使用技能

`clipslots`（`~/bin/clipslots`）是 ClipSlots.app 的命令行接口，与 GUI **共享同一份磁盘数据**（`ClipSlotsKit` 库），CLI 的读写会实时反映到 GUI，反之亦然。所有命令输出**单个 JSON 对象**到 stdout，专为智能体调用设计。

## 0. 调用方式与通用约定

- 可执行文件：`~/bin/clipslots`（软链到应用内 `clipslots-cli`）。
- 输出：始终是一个 JSON 对象。成功 `{"ok":true,...}`（退出码 0）；失败 `{"ok":false,"error":"<原因>"}`（退出码 1）。
- stdout 只有 JSON；日志走 stderr，解析时忽略 stderr。
- **以 `ok` 字段判断成败**，`ok:false` 时读 `error`；不要只看退出码文案。
- 数据模型三层：`页面(page) → 槽位组(group) → 槽位(slot)`。
  - 默认组 id：`default`；默认页 id：`default_page`；每组固定 `1..10` 共 10 个槽位。
  - **每个页面最多 10 个槽位组**；槽位组数超限需新建页面。
- 省略 `--group` 默认操作 `default` 组；`--page` 仅用于回显（**注意**：`list` 的分页参数是 `--page-size`/`--page-num`，与 `--page` 完全不同）。
- **未知 flag 会报错（v2.9.7）**：给某命令传它不支持的 `--flag` 会返回 `ok:false`（`unknown flag: --xxx for command '...' (allowed flags: ...)`）。不确定某命令支持哪些 flag 时先跑 `<cmd> --help`。仅校验 `--flag`，位置参数不受影响。
- 每个槽位包含：**主体内容（items，文本/图片/文件）** + **附件列表（attachments，按顺序）** + 标签(label)。主体与附件相互独立，主体可为空而只有附件。

### 空槽判定（重要）
- 一个槽位"为空"当且仅当【主体内容(items)为空 AND 附件列表为空】。
- 有主体内容 = 非空；主体为空但有附件 = 非空；两者都为空才是空槽。
- 扫描空槽时直接用 `read`/`list` 的 `empty:true` 判定（它已含附件检查）；`list` 每槽还返回 `attachmentCount`。

**首选工作流**：动手前先 `clipslots help` / `groups` / `list` 了解现状，再执行读写；写入前优先选空槽，避免覆盖。

## 1. 命令参考（共 15 个；每个子命令均支持 `--help`/`-h`）

### 只读
```bash
clipslots version                                  # {"ok":true,"version":"2.9.7"}
clipslots help                                     # 命令清单 + version/defaultGroup/defaultPage/slotCount
clipslots groups                                   # {groups:[{id,name,pageId,pageName,pageCount,slotCount,current}]}
clipslots pages                                    # {pages:[{id,name,current}]}
# list 支持分页：传 --page-size 后按页返回并附带 pagination 元信息（见下）
clipslots list [--group <id>] [--page <id>] [--page-size <N>] [--page-num <N>]
clipslots read <slot> [--group <id>]               # {slot,label,preview,text,htmlSource,types,attachmentCount,empty}
clipslots search <query> [--group <id>] [--all-groups] [--limit 50]   # 子串搜索(不分大小写)，命中范围含 预览/正文/标签/附件文件名
```

- `list` 返回顶层对象 `{group,page,slots:[{slot,label,preview,type,attachmentCount,empty}]}`（`slots` 是字段，不是裸数组）。
- **`list` 分页**：传 `--page-size <N>`（正整数）即按页返回，额外带 `pagination:{pageNum,pageSize,total,totalPages,hasMore}`；`--page-num <N>` 从 1 开始（默认 1）。不传 `--page-size` 则返回全部、无 pagination 字段（向后兼容）。
- `type` 可能取值：`empty`（主体+附件都空）、`attachment`（主体空但有附件）、`image`（含图片数据）、`image-file`、`video-file`、`file`、`html`、`text`、`rtf`、`other`。

### 写入 / 变更
```bash
# 写纯文本进【槽位主体】，保留已有附件；--text 必填(缺失报错)；--text - 从 stdin 读取(须 UTF-8 文本,二进制报错且不清空)；--label 可选
clipslots write <slot> --text "内容" [--group <id>] [--label "标签"]

# 向【槽位附件】追加一个或多个文件(按顺序)，不改动主体；--replace 先清空旧附件；--label 可选
# 返回 {slot,group,added:[文件名...],attachmentCount,slotBodyEmpty}
clipslots write-attachment <slot> <file> [file ...] [--group <id>] [--replace] [--label "标签"]

# 把某槽位内容加载到系统剪贴板(NSPasteboard)，不模拟按键(之后用户/工具再 Cmd+V)
# 主体非空 → 送主体；主体空但有附件 → 送附件文件 URL，返回 {slot,action,attachmentsCopied[,attachmentsSkipped]}
clipslots paste <slot> [--group <id>]

# 清空某槽位(内容+标签+附件全部移除)
clipslots clear <slot> [--group <id>]

# 新建槽位组(返回 id)；页面已满(10组)报错 → 先 create-page；同页面不允许重名(冲突改名或加 -2/-3)
clipslots create-group <name> [--page <id>]

# 新建页面(返回 id)；页面名不可重复
clipslots create-page <name>

# 删除槽位组 / 页面(软删除→移动到 .trash，可人工恢复；.trash 自动清理保留30天/50条)；id 不存在返回 ok:false
clipslots delete-group <id>
clipslots delete-page <id>

# 任意子命令加 --help / -h 返回该命令用法 {command,description,flags,usage}
clipslots write --help
```

> `write-attachment` 的文件路径支持 `~` 与相对路径；图片扩展名归 `image` 类型，其余归 `file`。

### 关键能力 / 限制
- ⚠️ **`write` 仅写纯文本主体**：`--text` 必填，仅接受 UTF-8 文本；`--text -` 从 stdin 读取时若为二进制会 `ok:false` 且**不清空槽位**。把图片/文件放入槽位请用 `write-attachment`（或走 GUI）。
- ✅ **`paste` 支持纯附件槽位**：主体空、仅有附件时，`paste` 把附件文件 URL 写入剪贴板（无法解析路径的附件计入 `attachmentsSkipped`）。
- ✅ **`search` 命中附件文件名**：匹配范围为 预览+正文+标签+附件文件名。
- ✅ **跨进程写锁**：CLI 与 GUI 并发写通过 `flock()` 串行化；锁争用超时(约5s)返回 `storage is busy (lock timeout)`，稍后重试即可，不是数据错误。
- ✅ **软删除可恢复**：`delete-group`/`delete-page` 移动到 `.trash`（保留30天/50条内可恢复），可安全用于整理。

## 2. 存入位置决策流（决定存到哪个页面/组）

先决定"存到哪个页面/哪个槽位组"，再按第 3 节判定"具体怎么放"。核心是**默认最保守、不碰已有数据**。

1. 先判断：用户有没有指定目标页面/组？
2. **【没有指定 = 默认】** 优先"新建页面 + 新建槽位组"（最安全，不碰已有数据）。
3. **【指定了页面、未指定组】** 扫描该页面所有槽位组找"有空槽"的组：找到 → 确认后存入；都无空槽 → 在该页面新建槽位组。
4. **【指定了页面 + 组】**：目标位置无内容 → 直接存入；有内容 → 询问是否覆盖；不覆盖则给优先级选项：① 同页面新建组；② 新建页面+新组；③ 找空槽依次存（组满建续组 -2/-3，续组满则新建页面+新组）。

**核心原则**：默认最保守（只新建、不碰已有）；用户指定才询问；冲突时给选项不自作主张；复用已有页面时不改页面名。

## 3. 存入逻辑（把一批内容/文件放进槽位）

给定「一段文本 + 若干文件」时，按**优先级从高到低**决定放法：

1. **用户明确要求槽位留空** → 【模式C】。触发词例：「放附件」「槽位另有用途」「我要自己编辑槽位」。
2. **有文本** → 【模式A】：文本写入**槽位主体**（`write`），其余文件按顺序进**附件**（`write-attachment`）。
3. **纯图片（无文本）** → 【模式B】：**首图**进主体、**其余图**按序进附件。
4. **其他**（纯视频/纯文档/混合非文本） → 【模式C】：**全部文件进附件**，主体留空。

| 模式 | 主体(items) | 附件(attachments) | 命令 |
|---|---|---|---|
| A 有文本 | 文本 | 其余文件按序 | `write` + `write-attachment` |
| B 纯图片 | 首图 | 其余图按序 | `write`(首图)* + `write-attachment` |
| C 留空 | 空 | 全部文件按序 | 仅 `write-attachment` |

> *当前 CLI 的 `write` 仅支持写纯文本主体；模式B 首图入主体暂由 GUI 或后续版本处理，CLI 侧可先全部用 `write-attachment` 落附件并在报告中说明。

## 4. 容量管理
- **槽位溢出**：一组只有 10 个槽位。超过时新建同名组加后缀 `-2`/`-3`（`create-group "<原名>-2"`）。
- **页面溢出**：一页最多 10 个槽位组。`create-group` 返回"页面槽位组已达上限"错误时先 `create-page` 再在新页面建组。

## 5. 命名规则
- **长度**：页面名 ≤ 6 字，组名 ≤ 8 字，Label ≤ 6 字。
- **取名来源**：优先用文件夹名/任务名；序号用阿拉伯数字（如 `导入 1`、`方案 2`）。
- **续组**：用 `-2`/`-3` 后缀，不要用「续」（写 `产品图-2`，不写 `产品图续`）。

## 6. 智能体使用规则
1. **先读后写**：改槽位前先 `read`/`list`，优先写 `empty:true` 空槽，批量覆盖前与用户确认。
2. **空槽判定**：主体与附件都为空才算空；直接用 `empty:true`（已含附件检查），不要只看主体。
3. **存入位置**：先按第 2 节决定页面/组（默认最保守），再按第 3 节判定模式A/B/C。
4. **主体 vs 附件**：`write` 改主体（保留附件）；`write-attachment` 只加附件（不动主体）。写入时可用 `--label` 顺带设标签。
5. **paste 语义**：只送入剪贴板，不自动粘贴；需真正粘贴时提示用户 Cmd+V。
6. **多组/多页**：涉及非默认组先 `groups`/`pages` 拿真实 id，不要臆测。
7. **长输出用分页**：`list` 输出过长时用 `--page-size`/`--page-num` 按页取，读 `pagination.hasMore` 判断是否还有下一页。
8. **flag 拼写**：未知 flag 会报错；不确定支持哪些 flag 先 `<cmd> --help`。
9. **富文本**：`read` 的 `htmlSource` 非空表示有 HTML 源；CLI `write` 只写纯文本，需保 HTML 走 GUI。

---
> 接口以 `clipslots help` 实际输出为准。CLI 与 GUI 共享 `ClipSlotsKit` 数据层，随 app 版本演进。工作草稿见 `docs/clipslots-cli-skill-draft.md`。
