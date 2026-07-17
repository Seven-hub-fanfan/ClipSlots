---
name: clipslots-manager
description: 通过命令行工具 clipslots 以编程方式操作 macOS 剪贴板槽位管理器 ClipSlots。能读取/写入/检索槽位内容、把内容加载到系统剪贴板、批量整理文件夹素材到"页面→槽位组→槽位"三层结构、创建/删除页面与槽位组。适用场景：需要把文本或文件存进 ClipSlots 槽位、读出或搜索已存内容、把某槽位内容放到剪贴板供粘贴、按规则批量归档素材、清理整理槽位数据等。要求 macOS 且已安装 ClipSlots v2.9.32+（CLI 位于 /usr/local/bin/clipslots）。
author: 帅帅
---

# ClipSlots CLI 使用技能

`clipslots`（`/usr/local/bin/clipslots`）是 ClipSlots.app 的命令行接口，与 GUI **共享同一份磁盘数据**（`ClipSlotsKit` 库），CLI 的读写会实时反映到 GUI，反之亦然。所有命令输出**单个 JSON 对象**到 stdout，专为智能体调用设计。

## 0. 调用方式与通用约定

- 可执行文件：`/usr/local/bin/clipslots`（软链到应用内 `clipslots-cli`）。
- 输出：始终是一个 JSON 对象。成功 `{"ok":true,...}`（退出码 0）；失败 `{"ok":false,"error":"<原因>"}`（退出码 1）。
- stdout 只有 JSON；日志走 stderr，解析时忽略 stderr。
- **以 `ok` 字段判断成败**，`ok:false` 时读 `error`；不要只看退出码文案。
- 数据模型三层：`页面(page) → 槽位组(group) → 槽位(slot)`。
  - 默认组 id：`default`；默认页 id：`default_page`；每组固定 `1..10` 共 10 个槽位。
  - **每个页面最多 10 个槽位组**；槽位组数超限需新建页面。
- 省略 `--group` 默认操作 `default` 组（**注意**：`list` 的分页参数是 `--page-size`/`--page-num`，与 `--page` 完全不同）。
- **按 UUID 或名称过滤/指定页面**（适用于接受 `--page` 的命令：`list`、`read`、`write`、`paste`、`create-group`、`groups`）：
  - `--page <uuid>`：按 UUID 过滤/指定页面
  - `--page-name <名称>`：按名称过滤/指定页面，找不到时报错（不会静默回落到默认页）
  - 两者功能等价，查找方式不同，互斥使用
- **`--page`/`--page-name` 会约束 group 匹配范围（v2.9.32；v2.9.35 起 `clear`/`write-attachment` 同样支持，重要）**：在 `list`/`read`/`write`/`paste`/`clear`/`write-attachment` 中，只要同时传了页面，`--group`/`--group-name` 的匹配就被限定在**该页面内**，不再全局取第一个同名组。组名允许跨页面重复，因此**跨页写入务必带上 `--page-name`（或 `--page`）**，否则同名组可能命中别的页面导致写错页面。
  - **护栏（A2）**：若页面与组不一致（传了 `--page-name X` 但组 `Y` 不在 X 页面内），命令返回 `{"ok":false,"error":"group 'Y' not found in page 'X'"}`，不会静默写到别处。
- **按组名引用（v2.9.16）**：读写类命令（`list`/`read`/`write`/`paste`/`search`/`clear`/`write-attachment`）的 `--group` 既可传组 id，也可直接传组名（如 `--group "导入 1"`）；也可用专门的 `--group-name "<组名>"` 精确匹配（优先级高于 `--group`，无匹配则报错）。匹配顺序：先按 id，再按 name。组名不确定时先 `groups`（可加 `--page-name` 限定页面）查真实名称。
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
clipslots version                                  # {"ok":true,"version":"2.9.33"}
clipslots help                                     # 命令清单 + version/defaultGroup/defaultPage/slotCount
clipslots groups [--page <uuid>|--page-name <名称>] # {groups:[{id,name,pageId,pageName,pageCount,slotCount,current}]}；带页面则只列该页的组(v2.9.32 A4)
clipslots pages                                    # {pages:[{id,name,current}]}
# list 支持分页：传 --page-size 后按页返回并附带 pagination 元信息（见下）
# list 只传 --page/--page-name 而不传组时：列出该页所有组（v2.9.32 A3，见下）
clipslots list [--group <id>] [--page <uuid>|--page-name <名称>] [--page-size <N>] [--page-num <N>]
clipslots read <slot> [--group <id>] [--page <uuid>|--page-name <名称>]               # {slot,label,preview,text,htmlSource,types,attachmentCount,empty}
clipslots search <query> [--group <id>] [--all-groups] [--limit 50]   # 子串搜索(不分大小写)，命中范围含 预览/正文/标签/附件文件名
```

- **`groups --page-name <页面名>`（v2.9.32 A4，判空核心原语）**：只返回该页面下的槽位组。判断"某页面是否有空组可用"应以此为准——遍历该页各组、配合 `list --page-name` 看槽位 `empty`/`attachmentCount`，**不要**再用旧的 `list --page-name`（无 `--group` 时旧版会回落全局 `default` 组，导致误判）。
- `list` 返回顶层对象 `{group,page,slots:[{slot,label,preview,type,attachmentCount,empty}]}`（`slots` 是字段，不是裸数组）。
- **`list` 只指定页面、不指定组（v2.9.32 A3）**：返回 `{page,pageName,groupCount,groups:[{group,name,slots:[...]}]}`——即该页面下**所有组各自的槽位**，`groupCount` 为该页组数（新建页通常为 1，即自动生成的空默认组）。不再像旧版那样回落到全局 `default` 组（那是"误判已满"的根因）。要单组结果时显式带 `--group`/`--group-name`。
- **`list` 分页**：传 `--page-size <N>`（正整数）即按页返回，额外带 `pagination:{pageNum,pageSize,total,totalPages,hasMore}`；`--page-num <N>` 从 1 开始（默认 1）。不传 `--page-size` 则返回全部、无 pagination 字段（向后兼容）。分页仅作用于单组列表。
- `type` 可能取值：`empty`（主体+附件都空）、`attachment`（主体空但有附件）、`image`（含图片数据）、`image-file`、`video-file`、`file`、`html`、`text`、`rtf`、`other`。

### 写入 / 变更
```bash
# 写纯文本进【槽位主体】，保留已有附件；--text 必填(缺失报错)；--text - 从 stdin 读取(须 UTF-8 文本,二进制报错且不清空)；--label 可选
# v2.9.16: 成功返回含 preview 字段(写入内容前100字符)，无需再 read 确认
clipslots write <slot> --text "内容" [--group <id|name>] [--page <uuid>|--page-name <名称>] [--label "标签"] [--force]

# v2.9.16 批量写入：从 stdin 传入 JSON 数组一次写多条，逐条执行(单条失败不影响其余)
# 每个元素: {"slot":Int, "text":String, "group"?:id或组名, "label"?:String}；缺省 group/label 用命令行 --group/--label
# 返回 {batch:true,total,written,failed,results:[{index,slot,group,ok,preview|error}]}
echo '[{"slot":1,"text":"甲"},{"slot":2,"text":"乙","label":"L2"}]' | clipslots write --batch [--group <id|name>]

# 向【槽位附件】追加一个或多个文件(按顺序)，不改动主体；--replace 先清空旧附件；--label 可选
# 返回 {slot,group,added:[文件名...],attachmentCount,slotBodyEmpty}
clipslots write-attachment <slot> <file> [file ...] [--group <id|name>] [--page <uuid>|--page-name <名称>] [--replace] [--label "标签"] [--force]

# 把某槽位内容加载到系统剪贴板(NSPasteboard)，不模拟按键(之后用户/工具再 Cmd+V)
# 主体非空 → 送主体；主体空但有附件 → 送附件文件 URL，返回 {slot,action,attachmentsCopied[,attachmentsSkipped]}
clipslots paste <slot> [--group <id>] [--page <uuid>|--page-name <名称>]

# 清空某槽位(内容+标签+附件全部移除)
clipslots clear <slot> [--group <id|name>] [--page <uuid>|--page-name <名称>] [--force]

# 新建槽位组(返回 id)；页面已满(10组)报错 → 先 create-page；同页面不允许重名(冲突改名或加 -2/-3)
clipslots create-group <name> [--page <uuid>|--page-name <名称>]

# 新建页面(返回 id)；页面名不可重复。v2.9.33: 同步创建默认槽位组并在返回值附带 defaultGroup {id,name}，可直接用其 id 写入，无需再跑 groups 查询
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
- ✅ **跨进程写锁**：CLI 与 GUI 并发写通过 `flock()` 串行化；锁争用超时(约5s)返回 `storage is busy: lock held by process pid N ...`（v2.9.16 会指出持锁进程 PID，且若持锁进程已死会自动回收残留锁），稍后重试即可，不是数据错误。
- ✅ **错误区分（v2.9.16 #4）**：锁争用报 `storage is busy ...`（可重试）；真正的磁盘/权限问题报 `filesystem permission error ...` / `no space left ...`（不是锁冲突，需查目录权限/磁盘），不再出现误导性的 "You don't have permission to save index.json"。
- ✅ **沙盒兼容 + `--force`（v2.9.16 #6）**：受限环境 `flock()` 返回 EPERM 时自动降级为无锁写并向 stderr 打印一次警告，写入照常进行；变更类命令可加 `--force` 主动跳过锁检查（stdout 仍是干净 JSON，警告只走 stderr）。⚠️ 仅在确定没有其他 ClipSlots 进程在写时使用，否则可能产生数据竞争。
- ✅ **批量写入（v2.9.16 #3）**：`write --batch` 从 stdin 读 JSON 数组一次写多条，逐条独立执行，单条失败不影响其余，`results` 里逐条给 `ok`/`preview`/`error`。
- ✅ **软删除可恢复**：`delete-group`/`delete-page` 移动到 `.trash`（保留30天/50条内可恢复），可安全用于整理。

## 1.5 环境与兼容（高级用法）

- **`CLIPSLOTS_DATA_DIR` 覆盖数据目录**：

  ```
  CLIPSLOTS_DATA_DIR=/path/to/dir clipslots <command>
  ```

  说明：覆盖默认数据目录（`~/.local/share/clipslots`），锁文件路径同步变更。GUI 从 Finder 启动时不继承 shell 环境变量，设此变量只影响 CLI，两端数据目录会分离，请谨慎使用。

## 2. 存入位置决策流（决定存到哪个页面/组）

先决定"存到哪个页面/哪个槽位组"，再按第 3 节判定"具体怎么放"。核心是**默认最保守、不碰已有数据**。

1. 先判断：用户有没有指定目标页面/组？
2. **【没有指定 = 默认】** 优先"新建页面 + 复用其默认组"（最安全，不碰已有数据）。
   - **新建页面直接拿返回的默认组**（v2.9.33）：`create-page` 现在**同步**创建一个空的「默认槽位组」，并在返回 JSON 里附带 `defaultGroup:{id,name}`。因此新建页面后**直接用返回的 `defaultGroup.id` 写第一批数据即可，无需再跑 `groups`/`list` 查询**。旧版的"惰性补建 + 二次查询拿默认组"流程已废弃（那会有时序空窗，查询可能暂时返回空组）。只有需要额外分类时才 `create-group`。**切勿**在新建页后无脑 `create-group`，否则会得到「默认槽位组 + 新组」两个组、残留一个闲置空组。
3. **【指定了页面、未指定组】** 标准判空流程：先 `groups --page-name <页面名>` 列出该页所有组，再 `list --page-name <页面名>` 看各组槽位的 `empty`/`attachmentCount`，找"有空槽"的组 → 确认后存入；都无空槽 → 在该页面新建槽位组。（**不要**用旧的 `list --page-name` 无组回落判空——旧版会回落全局 `default` 组导致误判已满。）
4. **【指定了页面 + 组】**：先 `read`/`list`（务必带 `--page-name` 约束到该页面）确认目标槽位是否有内容。目标为空 → 直接存入；已有内容 → **不自作主张覆盖**：询问用户是否覆盖；不覆盖则给优先级选项：① 同页面新建组；② 新建页面+新组；③ 找空槽依次存（组满建续组 -2/-3，续组满则新建页面+新组）。
   - 注：早期文档提到的 `write --on-conflict error|overwrite|skip|new-group` **当前 CLI 并未实现**，请勿使用；冲突处理一律走"显式读取后判断，或新建组"。

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

> *当前 CLI 限制：模式 B 退化为模式 C——首图无法通过 CLI 写入主体，全部进附件，Agent 执行时无需额外说明，直接按模式 C 处理即可。

## 4. 容量管理
- **槽位溢出**：一组只有 10 个槽位。超过时新建同名组加后缀 `-2`/`-3`（`create-group "<原名>-2"`）。
- **页面溢出**：一页最多 10 个槽位组。`create-group` 返回"页面槽位组已达上限"错误时先 `create-page` 再在新页面建组。

## 5. 命名规则
- **长度**：页面名 ≤ 10 字，组名 ≤ 10 字，Label ≤ 10 字。
- **取名来源**：优先用文件夹名/任务名；序号用阿拉伯数字（如 `导入 1`、`方案 2`）。
- **续组**：用 `-2`/`-3` 后缀，不要用「续」（写 `产品图-2`，不写 `产品图续`）。

## 6. 智能体使用规则
1. **先读后写**（三步清单）：`① 读（list/read 查现有状态）→ ② 分析（判断目标槽位/页面/组）→ ③ 执行（write/create）`。优先写 `empty:true` 空槽，批量覆盖前与用户确认。
2. **空槽判定**：主体与附件都为空才算空；直接用 `empty:true`（已含附件检查），不要只看主体。
3. **存入位置**：先按第 2 节决定页面/组（默认最保守），再按第 3 节判定模式A/B/C。
4. **主体 vs 附件**：`write` 改主体（保留附件）；`write-attachment` 只加附件（不动主体）。写入时可用 `--label` 顺带设标签。
5. **paste 语义**：只送入剪贴板，不自动粘贴；需真正粘贴时提示用户 Cmd+V。
6. **多组/多页**：优先使用 `--group-name` / `--page-name` 直接按名称操作，无需手动获取 UUID。
7. **长输出用分页**：`list` 输出过长时用 `--page-size`/`--page-num` 按页取，读 `pagination.hasMore` 判断是否还有下一页。
8. **flag 拼写**：未知 flag 会报错；不确定支持哪些 flag 先 `<cmd> --help`。
9. **富文本**：`read` 的 `htmlSource` 非空表示有 HTML 源；CLI `write` 只写纯文本，需保 HTML 走 GUI。
10. **兜底规则**：任何不确定的情况下，使用 `--force` + 新建页面 + 新建组，每组只放 1 个槽位。污染用户已有数据比浪费空槽位更严重。（`--force` 当前用于跳过跨进程写锁；若冲突处理相关的 `--force` 语义未实现，则用等效的新建页/组方式规避冲突。）

---
> 接口以 `clipslots help` 实际输出为准。CLI 与 GUI 共享 `ClipSlotsKit` 数据层，随 app 版本演进。工作草稿见 `docs/clipslots-cli-skill-draft.md`。
