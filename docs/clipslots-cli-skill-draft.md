---
name: clipslots-manager
version: 0.6 (draft)
used_when: 当需要以编程方式读取、写入、检索、加载或整理 macOS 剪贴板槽位管理器 ClipSlots 中的内容时使用（把文本/文件存进槽位、读出内容、搜索历史、把内容放到系统剪贴板、批量整理文件夹素材到槽位组/页面、删除槽位组/页面等）。
requires: macOS + 已安装 ClipSlots v2.9.5+（CLI 位于 `~/bin/clipslots`）
---

# ClipSlots CLI 使用技能（草稿）

`clipslots` 是 ClipSlots.app 的命令行接口，与 GUI **共享同一份磁盘数据**（`ClipSlotsKit` 库），CLI 的读写会实时反映到 GUI，反之亦然。所有命令输出**单个 JSON 对象**到 stdout，专为智能体调用设计。

> **v2.9.5 新增**：(1) `.trash` **自动清理**——`delete-group`/`delete-page` 的软删除数据不再无限堆积，删除时及启动时自动清理（默认保留最近 30 天、最多 50 条，超出的最旧条目被物理删除）；30 天内、条数在上限内的删除仍可人工恢复。(2) **子命令级 `--help`/`-h`**——任意子命令加 `--help` 或 `-h` 即返回该命令的用法与参数说明（`{command,description,flags,usage}`），无需查顶层 `help`。

> **v2.9.4 跨进程并发安全（重要）**：CLI 与 GUI 是两个独立进程，共享同一份磁盘数据。v2.9.4 起所有写操作都通过一把基于 `flock()` 的跨进程文件锁串行化（锁文件 `~/.local/share/clipslots/special_slots/.storage.lock`），CLI 与 GUI 的并发写不会再互相覆盖。锁为非阻塞重试、约 5 秒超时；若另一进程长时间占用锁，命令会返回 `{"ok":false,"error":"storage is busy (lock timeout)"}`（退出码 1）——此时**稍等片刻重试即可**，不要当作数据错误。GUI 端对 CLI 的改动会通过文件监听自动刷新界面（约 300ms 去抖），无需手动切组或重启。

## 0. 调用方式与通用约定

- 可执行文件：`~/bin/clipslots`。
- 输出：始终是一个 JSON 对象。成功 `{"ok":true,...}`（退出码 0）；失败 `{"ok":false,"error":"<原因>"}`（退出码 1）。
- stdout 只有 JSON；日志走 stderr，解析时忽略 stderr。
- 数据模型三层：`页面(page) → 槽位组(group) → 槽位(slot)`。
  - 默认组 id：`default`；默认页 id：`default_page`；每组固定 `1..10` 共 10 个槽位。
  - **每个页面最多 10 个槽位组**；槽位组数超限需新建页面。
- 省略 `--group` 默认操作 `default` 组；`--page` 目前仅用于回显。
- 每个槽位包含：**主体内容（items，文本/图片/文件）** + **附件列表（attachments，按顺序）** + 标签(label)。主体与附件相互独立，主体可为空而只有附件。
- **空槽判定（重要）**：
  - 一个槽位"为空"当且仅当【主体内容(items)为空 AND 附件列表为空】。
  - 有主体内容 = 非空；主体为空但有附件 = 非空；两者都为空才是空槽。
  - Agent 扫描空槽时必须同时检查主体与附件。CLI 已按此定义：`read`/`list` 的 `empty` 字段（v2.9.3+）表示"主体与附件都为空"；`list` 每个槽位还返回 `attachmentCount`。判断空槽直接用 `empty:true` 即可（它已包含附件检查）。

**首选工作流**：动手前先 `clipslots help` / `groups` / `list` 了解现状，再执行读写；写入前优先选空槽，避免覆盖。

## 1. 命令参考（v2.9.5，共 15 个；每个子命令均支持 `--help`/`-h`）

### 只读
```bash
clipslots version                                  # {"ok":true,"version":"2.9.4"}
clipslots help                                     # 命令清单 + version/defaultGroup/defaultPage/slotCount
clipslots groups                                   # 所有槽位组，返回对象 {groups:[{id,name,pageId,pageName,pageCount,slotCount,current}]}
clipslots pages                                    # 所有页面，返回对象 {pages:[{id,name,current}]}
clipslots list [--group <id>] [--page <id>]        # 返回顶层对象 {group,page,slots:[{slot,label,preview,type,attachmentCount,empty}]}（注意 slots 是对象里的字段，不是裸数组）；empty 表示主体与附件都为空（v2.9.3+），每槽含 attachmentCount 字段
clipslots read <slot> [--group <id>]               # 单槽完整内容 {slot,label,preview,text,htmlSource,types,attachmentCount,empty}；empty 表示主体与附件都为空（v2.9.3+）
clipslots search <query> [--group <id>] [--all-groups] [--limit 50]   # 子串搜索（不分大小写），返回 {query,results:[{group,page,pageName,slot,label,preview}]}；命中范围含预览/正文/标签/附件文件名（v2.9.3+）
```

> `type` 字段可能取值（由 CLI `classify` 生成）：`empty`（主体+附件都为空）、`attachment`（主体空但有附件）、`image`（含图片数据）、`image-file`（图片文件）、`video-file`（视频文件）、`file`（其他文件）、`html`（富文本/HTML 源）、`text`（纯文本）、`rtf`（RTF）、`other`（其余）。

### 写入 / 变更
```bash
# 写纯文本进【槽位主体】，保留已有附件；--text 必填（缺失即报错）；--text - 从 stdin 读取（必须是 UTF-8 文本，二进制会报错且不清空槽位）；--label 可选
clipslots write <slot> --text "内容" [--group <id>] [--label "标签"]

# 向【槽位附件】追加一个或多个文件（按顺序），不改动主体；--replace 先清空旧附件
# 返回 {slot,group,added:[文件名...],attachmentCount,slotBodyEmpty}
clipslots write-attachment <slot> <file> [file ...] [--group <id>] [--replace] [--label "标签"]

# 把某槽位内容加载到系统剪贴板（NSPasteboard），不模拟按键（之后用户/工具再 Cmd+V）
# 主体非空 → 送主体；主体空但有附件 → 送附件文件 URL，返回 {slot,action,attachmentsCopied[,attachmentsSkipped]}
clipslots paste <slot> [--group <id>]

# 清空某槽位（内容+标签+附件全部移除）
clipslots clear <slot> [--group <id>]

# 新建槽位组（返回 id）；页面已满(10组)会报错 → 先 create-page
# v2.9.4: 同一页面内不允许重名（大小写/去空格后完全相同即冲突）；冲突时返回
#   {"ok":false,"error":"a group named '<name>' already exists on this page"}
#   → 改个名或加 -2/-3 后缀重试。不同页面允许同名。
clipslots create-group <name> [--page <id>]

# 新建页面（返回 id）；页面名不可重复
clipslots create-page <name>

# 删除一个槽位组（软删除）；其数据目录移动到 .trash（可人工恢复，v2.9.5 起 .trash 自动清理）
# 成功返回 {"ok":true,"deleted":"<id>","movedToTrash":true}
# id 不存在返回 {"ok":false,"error":"group <id> not found"}
clipslots delete-group <id>

# 删除一个页面及其下所有槽位组（软删除）；相关数据目录移动到 .trash（可人工恢复，v2.9.5 起 .trash 自动清理）
# 成功返回 {"ok":true,"deleted":"<id>","movedToTrash":true}
# id 不存在返回 {"ok":false,"error":"page <id> not found"}
clipslots delete-page <id>

# 任意子命令加 --help / -h 返回该命令的用法与参数说明（v2.9.5）
# 返回 {"ok":true,"command":"write","description":"...","flags":[...],"usage":"clipslots write ..."}
clipslots write --help
clipslots delete-group -h
```

> 说明：`write-attachment` 的文件路径支持 `~` 与相对路径；图片扩展名归 `image` 类型，其余归 `file`。

### 已知能力 / 限制（v2.9.5）

- ✅ **子命令级 `--help` / `-h`**（v2.9.5 新增）：任意子命令加 `--help` 或 `-h` 返回该命令的独立说明（`{command,description,flags,usage}`），不必再解析顶层 `help` 的整表。
- ✅ **`.trash` 自动清理**（v2.9.5 新增）：`delete-group`/`delete-page` 的软删除数据会在删除时与 app/CLI 启动时自动清理，默认保留最近 30 天、最多 50 条，超出的最旧条目被物理删除。删除仍是"先移动到 `.trash`"，30 天内且未超上限的条目仍可人工恢复，因此删除依旧可安全用于整理。
- ✅ **`delete-group` / `delete-page` 软删除**（v2.9.4 新增）：删除是"移动到 `.trash`"而非物理抹除，可人工恢复；因此可安全用于整理。删除不存在的 id 返回 `ok:false`（`group/page <id> not found`），不会误删。
- ✅ **`create-group` 同页去重**（v2.9.4 新增）：同一页面内不允许出现同名槽位组，冲突返回 `a group named '<name>' already exists on this page`；不同页面之间允许同名。批量导入/自动建组时遇冲突请改名或加 `-2`/`-3` 后缀。
- ✅ **跨进程写锁**（v2.9.4 新增）：CLI 与 GUI 的并发写通过 `flock()` 串行化，不再互相覆盖；锁争用超时（约 5s）返回 `storage is busy (lock timeout)`，稍后重试即可。
- ✅ **`paste` 支持纯附件槽位**：主体为空、仅有附件的槽位，`paste` 会把附件的文件 URL 写入系统剪贴板（`clearContents` 后 `writeObjects([NSURL])`），返回 `attachmentsCopied`（无法解析出文件路径的附件会被跳过并计入 `attachmentsSkipped`）。旧版"纯附件槽位无法 paste"的限制已在 v2.9.3 修复。
- ✅ **`search` 命中附件文件名**：搜索的匹配范围已扩展到"预览 + 正文 + 标签 + 附件文件名"，因此模式C（纯附件）槽位可通过文件名被搜到。旧版"搜索不覆盖附件名"的限制已在 v2.9.3 修复。
- ⚠️ **`write` 仅写纯文本主体**：`--text` 必填，仅接受 UTF-8 文本；`--text -` 从 stdin 读取时若不是合法 UTF-8（二进制）会返回 `ok:false` 且**不清空槽位**。把图片/文件放入槽位请用 `write-attachment`（或走 GUI）。

## 2. 存入位置决策流（决定存到哪个页面/组）

先决定"存到哪个页面/哪个槽位组"，再按第 3 节判定"具体怎么放（模式A/B/C）"。核心是**默认最保守、不碰已有数据**。

1. 先判断：用户有没有指定目标页面/组？
2. **【没有指定 = 默认】** 优先"新建页面 + 新建槽位组"（最安全，不碰已有数据）。
   - 实现说明：当前版本 `create-page` 无硬性数量上限，故默认此分支恒可执行；下面"页面已满"子分支是为未来引入页面上限预留的预案。
   - 若未来引入页面数上限并达到上限：暂停并询问用户如何存（选项 A：选一个现有页面新建组；选项 B：覆盖某页面，需二次确认）。
3. **【指定了页面、未指定组】** 扫描该页面所有槽位组，找"有空槽"的组：
   - 找到 → 提示用户确认后存入。
   - 所有组都无空槽 → 在该页面新建槽位组。
4. **【指定了页面 + 组】**：
   - 目标位置无内容 → 直接存入。
   - 目标位置有内容 → 询问是否覆盖；同意则覆盖；不同意则给优先级选项：① 同页面新建槽位组；② 新建页面 + 新建槽位组；③ 找空槽依次存（组满则建续组 -2/-3，续组满则新建页面 + 新组）。

**核心原则：**
- 默认最保守：默认只"新建"，不碰已有数据。
- 用户指定才询问：确认意图后再操作。
- 冲突时给选项，不自作主张。
- 复用已有页面时不改页面名，只按命名规则给"新建的槽位组"命名。

> 命名规则见第 5 节（页面名 ≤6字[新建时]、组名 ≤8字、Label ≤6字；续组用 `-2`/`-3`；优先用文件夹名/任务名，序号用阿拉伯数字）。"空槽"定义见第 0 节"空槽判定"：主体与附件都为空才算空槽（用 `empty:true` 判定，已含附件检查）。

## 3. 存入逻辑（把一批内容/文件放进槽位的判定规则）

给定「一段文本 + 若干文件」时，按下述**优先级从高到低**决定放法：

1. **用户明确要求槽位留空** → 走【模式C】。触发词例：「放附件」「槽位另有用途」「我要（自己）编辑槽位」。
2. **有文本** → 【模式A】：文本写入**槽位主体**（`write`），其余文件按顺序进**附件**（`write-attachment`）。
3. **纯图片（无文本）** → 【模式B】：**首图**写入槽位主体，**其余图**按顺序进附件。
4. **其他情况**（纯视频 / 纯文档 / 混合非文本文件） → 【模式C】：**全部文件进附件**，槽位主体留空。

| 模式 | 主体(items) | 附件(attachments) | 命令 |
|---|---|---|---|
| A 有文本 | 文本 | 其余文件按序 | `write` + `write-attachment` |
| B 纯图片 | 首图 | 其余图按序 | `write`(首图)* + `write-attachment` |
| C 留空 | 空 | 全部文件按序 | 仅 `write-attachment` |

> *当前 CLI 的 `write` 仅支持写纯文本主体；若首图需进主体（模式B）暂由 GUI 或后续版本的图片写入能力处理，CLI 侧可先全部用 `write-attachment` 落附件并在报告中说明。

## 4. 容量管理

- **槽位溢出**：一个组只有 10 个槽位。当内容超过 10 个槽位时，**新建同名组并加后缀 `-2` / `-3` …**（`create-group "<原名>-2"`），继续放。
- **页面溢出**：一个页面最多 10 个槽位组。当 `create-group` 返回「页面槽位组已达上限」错误时，**新建页面**（`create-page`）后再在新页面建组。

## 5. 命名规则

- **长度**：页面名 ≤ 6 字，组名 ≤ 8 字，Label ≤ 6 字。
- **取名来源**：优先用**文件夹名 / 任务名**；序号用**阿拉伯数字**（如 `导入 1`、`方案 2`）。
- **续组**：用 `-2` / `-3` 后缀，**不要用「续」**（如 `产品图-2`，不写 `产品图续`）。

## 6. 典型场景（草稿，按讨论结果整理）

### 场景一：客服 —— 常用话术/回复模板
- 内容多为**纯文本**（模式A，无附件）。
- 按主题分组：一个组放一类话术，组名用主题（≤8字，如 `售后退款`），每条话术占一个槽位，Label 用短标识（≤6字，如 `催发货`）。
- 写入：`clipslots write <slot> --text "<话术>" --group <组> --label <短标签>`。
- 取用：`clipslots paste <slot> --group <组>` → 提示客服在对话框 Cmd+V。
- 话术超过 10 条 → `create-group "售后退款-2"`。

### 场景二：设计师 —— 共享素材库（一个文件夹的成套素材）
- 一个素材文件夹对应**一个槽位组**，组名用文件夹名（≤8字，超长则截断/概括）。
- 判定：
  - 文件夹含说明文字 → 模式A（说明进主体，素材文件进附件）。
  - 纯图片 → 模式B（首图进主体做封面，其余进附件）。
  - 图/视频/文档混合 → 模式C（全部进附件，主体留空）。
- 每个槽位承载一组相关素材：主体 + 有序附件；Label 标注用途（≤6字，如 `主视觉`）。
- 素材项超过 10 个槽位 → `create-group "<文件夹名>-2"`；该页组数满 → `create-page` 新建页面（如按项目/客户分页）。

### 场景三：设计师 —— 一对一交付
- 面向单个接收者的定向交付：通常「一句交付说明 + 若干成品文件」→ 模式A（说明进主体，成品进附件），或接收者要自行编辑 → 模式C（全部进附件、主体留空）。
- 组名用接收者/任务名（≤8字），页面可按「交付对象」或日期组织（页面名 ≤6字）。
- 交付后可 `paste` 关键文件到剪贴板，或直接告知对方在 GUI 对应组/页取用。

## 7. 智能体使用规则

1. **先读后写**：改槽位前先 `read`/`list`，优先写 `empty:true` 空槽，批量覆盖前与用户确认。
2. **空槽判定**（详见第 0 节"空槽判定"）：一个槽位为空当且仅当**主体内容与附件列表都为空**；有主体或有附件都算非空。扫描空槽必须同时检查主体与附件——直接用 `empty:true` 判定即可（v2.9.3+ 的 `empty` 已含附件检查，`list` 另有 `attachmentCount`），不要只看主体。
3. **存入位置**：先按第 2 节"存入位置决策流"决定存到哪个页面/组（默认最保守：只新建、不碰已有数据；冲突时给选项不自作主张），再按第 3 节判定模式A/B/C。
4. **以 `ok` 判断成败**，`ok:false` 读 `error`；不要只看退出码文案。
5. **槽位范围** 1..10，越界返回 `ok:false`。
6. **主体 vs 附件**：`write` 改主体（保留附件）；`write-attachment` 只加附件（不动主体）；二者配合实现模式A/B/C。
7. **paste 语义**：只送入剪贴板，不自动粘贴；需要真正粘贴时提示用户 Cmd+V。纯附件槽位（主体空）也可 `paste`，会把附件文件 URL 送入剪贴板（v2.9.3+）。
8. **多组/多页**：涉及非默认组先 `groups`/`pages` 拿真实 id，不要臆测。
9. **容量与命名**：严格按第 4、5 节；溢出用 `-2/-3` 或新页面，命名遵守字数上限与阿拉伯数字序号。
10. **富文本**：`read` 的 `htmlSource` 非空表示有 HTML 源；CLI `write` 只写纯文本，需保 HTML 走 GUI。

---
> 本文件为 Skill 草稿，接口以 `clipslots help` 实际输出为准；场景部分按当前讨论整理，可再据实际使用微调。CLI 与 GUI 共享 `ClipSlotsKit` 数据层，随 app 版本演进。
