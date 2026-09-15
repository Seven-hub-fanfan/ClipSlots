---
name: clipslots-manager
description: 当需要以编程方式读取、写入、检索、加载或整理 macOS 剪贴板槽位管理器 ClipSlots 中的内容时使用。把文本/文件存进槽位、读出内容、搜索历史、把内容放到系统剪贴板、批量整理文件夹素材到槽位组/页面、删除槽位组/页面等。前置要求：macOS + 已安装 ClipSlots v2.9.33+，CLI 位于 /usr/local/bin/clipslots。
version: 1.7.0
compatibility: Requires macOS, ClipSlots, and /usr/local/bin/clipslots. Verified with ClipSlots CLI 2.11.8; probe version and command help at runtime.
used_when: 当需要以编程方式读取、写入、检索、加载或整理 macOS 剪贴板槽位管理器 ClipSlots 中的槽位内容时使用（写文本/文件进槽位、读出内容、搜索历史、把内容放到系统剪贴板、批量整理文件夹素材到槽位组/页面、删除槽位组/页面等）。
requires: macOS + 已安装 ClipSlots v2.9.33+，CLI 位于 /usr/local/bin/clipslots。
---

# ClipSlots CLI 使用技能

> 本文件为随 App bundle 打包、供各 Agent 实际读取的正式版本，也是本项目 Skill 内容的唯一来源。

> **Skill v1.3.2（对齐 CLI v2.9.58，已验证 CLI 2.9.58）**：本版为完整安全策略升级——写入前按能力矩阵优先使用 CLI 原生护栏，空槽 ≠ 可占用，定位歧义强制消歧，批量走预检。运行时先探测（`version` → 子命令 `--help` → `write --batch`/`CLIPSLOTS_DATA_DIR`），按实际能力降级。
>
> **v2.9.57 新增能力（Skill 默认使用）**：
> - **`write --if-empty`**（空槽保护，v2.9.57 新增，Skill 默认使用）：仅当目标槽位为空（主体为空 AND 附件列表为空，即 `SlotContent.isEmpty`；**label 不纳入判空**，与 `list`/`read` 的 `empty` 字段一致）才写入；非空返回 `error_code:"SLOT_NOT_EMPTY"` 且零副作用。探测到该参数时优先用它判冲突；未探测到时 Skill 自行 `read`/`list` 预检并请用户确认后再写。
> - **`write --overwrite-text`**（明确覆盖，v2.9.57 新增）：只覆盖槽位文本主体，**保留附件与标签**；与 `--if-empty` 互斥（同传返回 `INVALID_ARGUMENT_COMBINATION`）。`--label` 三态：不传保留、传非空覆盖、传空串（`--label ""`）清除。
> - **`write --batch --stop-on-error`**（批量遇错停止，v2.9.57 新增，默认 `false`）：批量写入前做**完整预检**（解析目标 / 去重 / 静态冲突 / 参数校验）；**预检失败整批零写入、磁盘不变**（`preflight_passed:false`，如 `BATCH_DUPLICATE_TARGET`、`SLOT_NOT_EMPTY`、`INVALID_ARGUMENT_COMBINATION`）。执行期失败（运行时错误）默认继续、失败项 `status:"failed"`；带 `--stop-on-error` 时其后项标记 `status:"not_executed"`。响应含 `preflight_passed`、`total/written/failed/skipped/not_executed`，每项含 `status`；顶层 `ok = preflight_passed && failed==0 && not_executed==0`，失败退出码非 0。未探测到 `--stop-on-error`/`--batch` 时改为高安全模式逐条 `write`、逐条查 `ok`、失败即停且不重放整批。**v2.9.58 起批量每个 item 的组解析与单条 `write` 一致（F1 逻辑）**：未知组名/ID → `GROUP_NOT_FOUND`，跨页同名组（无页面上下文）→ `AMBIGUOUS_GROUP`（含 candidates 列表），任一预检失败则整批零写入、`preflight_passed:false`、`written:0`。响应中的 `skipped` 字段**当前恒为 0，保留供未来扩展**。
> - **默认页/默认组保护 + 启动自动修复**：`delete-page default_page` 返回 `DEFAULT_PAGE_PROTECTED`、`delete-group default` 返回 `DEFAULT_GROUP_PROTECTED`（CLI 层与 Kit 层均拒绝）。每次 CLI 调用初始化时检测并**自动修复**缺失的默认页/默认组，所有成功响应含 `repaired` 字段（未修复为 `false`），修复时附 `repair_actions`。因此不再把"默认页可删"当作 CLI 缺陷，但破坏性操作仍需确认。
> - **错误码稳定化**：所有失败返回体含全大写下划线 `error_code`（如 `GROUP_REQUIRED`、`AMBIGUOUS_GROUP`、`GROUP_NOT_FOUND`、`SLOT_NOT_EMPTY`、`INVALID_ARGUMENT_COMBINATION`、`INVALID_LIMIT`），退出码非 0；按 `error_code` 稳定分支，不要只解析文案。跨页同名组无页面限定时返回 `AMBIGUOUS_GROUP`（含候选列表），按组名操作务必绑定 `--page`/`--page-name`。

> **v1.0 对齐 CLI v2.9.32**：页面作用域 group 解析（`--page`/`--page-name` 约束 `--group` 匹配范围）、`list` 仅传页面时返回该页所有组的语义（A3）、页面/组不一致的 A2 护栏、`groups --page` 过滤（A4）。

`clipslots` 是 ClipSlots.app 的命令行接口，与 GUI **共享同一份磁盘数据**（`ClipSlotsKit` 库），CLI 的读写会实时反映到 GUI，反之亦然。所有命令输出**单个 JSON 对象**到 stdout，专为智能体调用设计。

> **v2.9.42 新增**：(1) **`rename-group` 命令**——重命名已有槽位组，同页内名称不可重复（冲突返回 `a group named '...' already exists on this page`），可选 `--page-name` 校验防止误改错页的同名组。(2) **`create-page` 支持 `--group-name`**——建页时直接把默认组命名为指定名称（不传则保持向后兼容，defaultGroup.name = "默认槽位组"），实现「零废组」建库姿势。

> **v2.9.7 新增**：(1) **未知 flag 报错（R1）**——任一命令传入其不认识的 `--flag` 时，不再静默忽略，而是返回 `{"ok":false,"error":"unknown flag: --xxx for command '...' (allowed flags: ...)"}` 并退出码 1，帮助发现拼写错误（如 `--lable`→`--label`）。位置参数不受此校验影响。(2) **`list` 支持分页（S2）**——传 `--page-size <N>` 即按页返回，并附带 `pagination:{pageNum,pageSize,total,totalPages,hasMore}`；可选 `--page-num <N>`（从 1 开始，默认 1）。不传 `--page-size` 时行为不变（返回全部，无 pagination 字段）。(3) **`write` / `write-attachment` 支持 `--label`（S3）**——写入槽位时可同时设置标签，省去一次额外调用。

> **v2.9.5 新增**：(1) `.trash` **自动清理**——`delete-group`/`delete-page` 的软删除数据不再无限堆积，删除时及启动时自动清理（默认保留最近 30 天、最多 200 条，超出的最旧条目被物理删除）；30 天内、条数在上限内的删除仍可人工恢复。(2) **子命令级 `--help`/`-h`**——任意子命令加 `--help` 或 `-h` 即返回该命令的用法与参数说明（`{command,description,flags,usage}`），无需查顶层 `help`。

> **v2.9.4 跨进程并发安全（重要）**：CLI 与 GUI 是两个独立进程，共享同一份磁盘数据。v2.9.4 起所有写操作都通过一把基于 `flock()` 的跨进程文件锁串行化（锁文件 `~/.local/share/clipslots/special_slots/.storage.lock`），CLI 与 GUI 的并发写不会再互相覆盖。锁为非阻塞重试、约 5 秒超时；若另一进程长时间占用锁，命令会返回 `{"ok":false,"error":"storage is busy (lock timeout)"}`（退出码 1）——此时**稍等片刻重试即可**，不要当作数据错误。GUI 端对 CLI 的改动会通过文件监听自动刷新界面（约 300ms 去抖），无需手动切组或重启。

## 0. 调用方式与通用约定

- 可执行文件：`/usr/local/bin/clipslots`。
- 输出：始终是一个 JSON 对象。成功 `{"ok":true,...}`（退出码 0）；失败 `{"ok":false,"error":"<原因>"}`（退出码 1）。
- stdout 只有 JSON；日志走 stderr，解析时忽略 stderr。
- 数据模型三层：`页面(page) → 槽位组(group) → 槽位(slot)`。
  - 默认组 id：`default`；默认页 id：`default_page`；每组固定 `1..10` 共 10 个槽位。
  - **每个页面最多 10 个槽位组**；槽位组数超限需新建页面。
- 省略 `--group` 默认操作 `default` 组（**注意**：`list` 的分页参数是 `--page-size`/`--page-num`，与 `--page` 是两回事）。
- **按 UUID 或名称过滤/指定页面**（适用于接受 `--page` 的命令：`list`、`read`、`write`、`paste`、`create-group`、`groups`）：
  - `--page <uuid>`：按 UUID 过滤/指定页面
  - `--page-name <名称>`：按名称过滤/指定页面，找不到时报错（不会静默回落到默认页）
  - 两者功能等价，查找方式不同，互斥使用
- **`--page`/`--page-name` 会约束 group 匹配范围（v2.9.32；v2.9.35 起 `clear`/`write-attachment` 同样支持，重要）**：在 `list`/`read`/`write`/`paste`/`clear`/`write-attachment` 中，只要同时传了页面，`--group`/`--group-name` 的匹配就被限定在**该页面内**，不再全局取第一个同名组。组名允许跨页面重复，因此**跨页写入务必带上 `--page-name`（或 `--page`）**，否则同名组可能命中别的页面导致写错页面。
  - **护栏（A2）**：若页面与组不一致（传了 `--page-name X` 但组 `Y` 不在 X 页面内），命令返回 `{"ok":false,"error":"group 'Y' not found in page 'X'"}`，不会静默写到别处。
- **未知 flag 会报错（v2.9.7）**：给某命令传它不支持的 `--flag` 会返回 `ok:false`（`unknown flag: --xxx ...`），请以 `--help` 输出的 flags 为准；位置参数不受影响。
- 每个槽位包含：**主体内容（items，文本/图片/文件）** + **附件列表（attachments，按顺序）** + 标签(label)。主体与附件相互独立，主体可为空而只有附件。
- **空槽判定（重要）**：
  - 一个槽位"为空"当且仅当【主体内容(items)为空 AND 附件列表为空】。
  - 有主体内容 = 非空；主体为空但有附件 = 非空；两者都为空才是空槽。
  - Agent 扫描空槽时必须同时检查主体与附件。CLI 已按此定义：`read`/`list` 的 `empty` 字段（v2.9.3+）表示"主体与附件都为空"；`list` 每个槽位还返回 `attachmentCount`。判断空槽直接用 `empty:true` 即可（它已包含附件检查）。

**首选工作流**：动手前先 `clipslots help` / `groups` / `list` 了解现状，再执行读写；写入前优先选空槽，避免覆盖。

### 0.1 可直接复制的最短命令序列（实测于 CLI 2.11.7）

下面 6 段是最常见的 6 个任务。**照抄、只替换引号里的中文和路径即可**，不要自行改写 flag 组合。

```bash
# ① 全库找一段内容（最常用；不加 --all-groups 就只搜 default 组，等于搜不到）
clipslots search "关键词" --all-groups

# ② 看某页有哪些组、哪些槽是空的（判空标准两步）
clipslots groups --page-name "Q3项目"
clipslots list --page-name "Q3项目"            # 每槽看 empty / attachmentCount

# ③ 新建一个页面并直接把第一个组命名好（零废组），再写第 1 槽
clipslots create-page "Q3项目" --group-name "品牌VI"
clipslots write 1 --text "内容" --group-name "品牌VI" --page-name "Q3项目" --if-empty --label "主视觉"

# ④ 往一个已有槽位加附件（多个文件按顺序传，不要打包成 ZIP）
clipslots write-attachment 1 ~/Desktop/a.png ~/Desktop/b.pdf --group-name "品牌VI" --page-name "Q3项目"

# ⑤ 一次写多个槽位（>3 个就用 --batch；注意 item 键名是 snake_case）
echo '[{"slot":2,"text":"文案A","if_empty":true},{"slot":3,"text":"文案B","if_empty":true}]' \
  | clipslots write --batch --group-name "品牌VI" --page-name "Q3项目"

# ⑥ 取用：把某槽位送进系统剪贴板（不会自动粘贴，要提示用户按 Cmd+V）
clipslots paste 1 --group-name "品牌VI" --page-name "Q3项目"
```

**三条硬规则（照做即可，不要自行推断）：**
1. 只要涉及具体某个组，**永远同时带上 `--page-name`**（组名允许跨页重复；不带页面且撞名 → `AMBIGUOUS_GROUP` 直接失败）。
2. 写文本一律先带 `--if-empty`；报 `SLOT_NOT_EMPTY` 就换空槽，或问用户是否覆盖（要覆盖才改用 `--overwrite-text`）。两个 flag 不能同时传。
3. 每条命令执行后**先看 `ok` 字段**：`ok:true` 才算成功；`ok:false` 时按 `error_code` 处理（见 1.4 错误码对照表），不要重试同一条命令。

## 1. 命令参考（实测于 CLI v2.11.7，共 19 个命令；每个子命令均支持 `--help`/`-h`）

### 只读
```bash
clipslots version                                  # {"ok":true,"version":"2.9.58"}
clipslots help                                     # 命令清单 + version/defaultGroup/defaultPage/slotCount
clipslots groups [--page <uuid>|--page-name <名称>]   # 所有槽位组，返回对象 {groups:[{id,name,pageId,pageName,pageCount,slotCount,current}]}；带页面参数时只返回该页面下的组（v2.9.32 A4），是 Agent 判断"某页面是否有空组"的核心原语
clipslots pages                                    # 所有页面，返回对象 {pages:[{id,name,current}]}
clipslots list [--group <id>] [--page <uuid>|--page-name <名称>] [--page-size <N>] [--page-num <N>]   # 传 --group（或 --group-name）时返回单组顶层对象 {group,page,slots:[{slot,label,preview,type,attachmentCount,empty,hasManualThumbnail,thumbnailBytes}]}（注意 slots 是对象里的字段，不是裸数组）；empty 表示主体与附件都为空（v2.9.3+），每槽含 attachmentCount 字段。v2.11.2 起每槽还含 hasManualThumbnail(bool) 与 thumbnailBytes(int)，用于确认手动缩略图状态。只传 --page/--page-name 而不传组时（v2.9.32 A3）返回 {page,pageName,groupCount,groups:[{group,name,slots:[...]}]}（该页所有组各自的槽位），不再回落到全局 default 组。传 --page-size 后按页返回并附带 pagination:{pageNum,pageSize,total,totalPages,hasMore}（v2.9.7）。--page 按 UUID、--page-name 按名称指定页面，两者互斥
clipslots read <slot> [--group <id>] [--page <uuid>|--page-name <名称>]               # 单槽完整内容 {slot,label,preview,text,htmlSource,types,attachmentCount,empty,hasManualThumbnail,thumbnailBytes}；empty 表示主体与附件都为空（v2.9.3+）；hasManualThumbnail/thumbnailBytes 为 v2.11.2 新增，是 set-thumbnail/clear-thumbnail 之后唯一的自检依据
clipslots search <query> [--group <id|name>] [--page <uuid>|--page-name <名称>] [--all-groups] [--limit 50]   # 子串搜索（不分大小写），返回 {query,results:[{group,page,pageName,slot,label,preview}]}；命中范围含预览/正文/标签/附件文件名（v2.9.3+）。v2.9.58 起支持 --page/--page-name，采用与其它命令相同的「页面+组」定位规则（只传页面不传组时搜索该页所有组）；并修复了 --group <UUID> 精确过滤（早期 CLI 2.9.57 指定有效组 UUID 会错误返回空结果）
#   ⚠️【必读，v2.11.7 实测】search 匹配的是【全文】，不再只匹配 preview 的前 100 字：正文第 400 字处的词也能命中（已实测验证）。
#   ⚠️【最容易出错的一条】不传任何范围参数时，search 只搜【default 组】，几乎必然返回空 results:[]，而不是搜全库。
#      要搜全库必须显式加 --all-groups：  clipslots search "关键词" --all-groups
#      只搜某页：clipslots search "关键词" --page-name "Q3项目"
#      只搜某组：clipslots search "关键词" --group-name "品牌VI" --page-name "Q3项目"
#      results 里的 preview 只是截断预览，命中的词可能不出现在 preview 里 —— 不要因为 preview 里看不到关键词就判定为误命中，要 read <slot> 看全文。
#   --limit 必须为正整数，传 0 或负数返回 error_code:"INVALID_LIMIT"

# 仅在索引(index.json)确实损坏时才修复；索引健康时不做任何改动、返回 {"ok":true,"action":"none","note":"index is healthy — no repair needed; no data was modified"}
# 只在其他命令持续报索引/存储损坏类错误时才用它。它是只读安全的（健康即 no-op），但不要当常规步骤每次都跑。
clipslots repair-index
```

> **Agent 判空标准流程（v2.9.32）**：先 `groups --page-name <页名>` 列出该页所有组（`groups` 带页面参数即只返回该页的组，A4），再 `list --page-name <页名>` 看各组槽位的 `empty`/`attachmentCount`。`list` 只传页面不传组时会返回该页所有组各自的槽位（A3），**不再**回落到全局 `default` 组——旧版无组回落是"误判已满"的根因。要单组结果时显式带 `--group`/`--group-name`。

> `type` 字段可能取值（由 CLI `classify` 生成）：`empty`（主体+附件都为空）、`attachment`（主体空但有附件）、`image`（含图片数据）、`image-file`（图片文件）、`video-file`（视频文件）、`file`（其他文件）、`html`（富文本/HTML 源）、`text`（纯文本）、`rtf`（RTF）、`other`（其余）。

### 写入 / 变更
```bash
# 写纯文本进【槽位主体】，保留已有附件；--text 必填（缺失即报错）；--text - 从 stdin 读取（必须是 UTF-8 文本，二进制会报错且不清空槽位）；--label 可选
# --if-empty：写空槽保护，目标槽非空（主体或附件任一非空）时返回 SLOT_NOT_EMPTY 并 exit 1；判空口径与 list/read 的 empty 字段一致（不含 label），仅在显式传入时生效
# --overwrite-text：明确覆盖槽位文本主体，保留已有附件和标签
# --if-empty 与 --overwrite-text 互斥，同传返回 INVALID_ARGUMENT_COMBINATION
# --label ""：传空串可清除已有标签（v2.9.7+）
clipslots write <slot> --text "内容" [--group <id>] [--page <uuid>|--page-name <名称>] [--label "标签"] [--if-empty | --overwrite-text]

# 批量写入多个槽位（v2.9.57+）：单进程内顺序执行，比循环逐条 write 更快更安全
# ⚡ 超过 3 个槽位写入时，优先使用 --batch，避免循环启动多个进程
# 输入：从 stdin 读取 JSON 数组。
#
# ⚠️⚠️ 【实测于 CLI 2.11.7，最容易出错的一条】item 的键名必须是 snake_case，写错会被【静默忽略】：
#   允许的键：slot(必填,int) / text(必填,string) / group(组名或组 id) / label(string)
#              / if_empty(bool) / overwrite_text(bool)
#   ✅ "if_empty": true      ❌ "ifEmpty": true      ← 写成 ifEmpty 不报错，但保护失效，会直接覆盖非空槽！
#   ✅ "overwrite_text": true ❌ "overwriteText": true
#   同一 item 同时给 if_empty 和 overwrite_text → 预检失败 INVALID_ARGUMENT_COMBINATION，整批零写入
#
# ⚠️ 【定位组只能用命令级 flag 或组 id】write --batch 的 item 里写 "page"/"page_name" 对组消歧【无效】：
#   组名跨页重复时，item 里带 "page_name" 仍会返回 AMBIGUOUS_GROUP、整批零写入（实测 2.11.7）。
#   正确写法二选一：
#     ① 命令级带页面 + 组（推荐）：clipslots write --batch --group "组A" --page-name "测试页2"
#     ② item 里直接给组 id（UUID）：{"slot":1,"text":"x","group":"special_XXXX-..."}
#   注意：只给命令级 --page-name 而不给 --group/--group-name → GROUP_REQUIRED（批量不支持「只给页面」）
#   （set-thumbnail --batch 相反：它的 item 支持 "page_name"/"page" 消歧，见缩略图小节）
#
# 预检：解析→去重→冲突→参数校验，预检失败整批零写入（preflight_passed:false）
#   两个目标解析到同一 (group,slot) → BATCH_DUPLICATE_TARGET，返回体含 duplicates:[下标...]
#   任一 if_empty 目标非空 → SLOT_NOT_EMPTY，整批零写入（written:0）
# 执行期失败默认继续（failed 项标 status:"failed"），加 --stop-on-error 时其后项标 not_executed
# 顺序保证：按数组下标顺序写入，不会乱序
echo '[{"slot":1,"text":"内容A","if_empty":true},{"slot":2,"text":"内容B","if_empty":true}]' \
  | clipslots write --batch --group <id或组名> [--page-name <名称>] [--stop-on-error]

# 向【槽位附件】追加一个或多个文件（按顺序），不改动主体；--replace 先清空旧附件
# 返回 {slot,group,added:[文件名...],attachmentCount,slotBodyEmpty}
clipslots write-attachment <slot> <file> [file ...] [--group <id>] [--page <uuid>|--page-name <名称>] [--replace] [--label "标签"]

# 把某槽位内容加载到系统剪贴板（NSPasteboard），不模拟按键（之后用户/工具再 Cmd+V）
# 主体非空 → 送主体；主体空但有附件 → 送附件文件 URL，返回 {slot,action,attachmentsCopied[,attachmentsSkipped]}
clipslots paste <slot> [--group <id>] [--page <uuid>|--page-name <名称>]

# 清空某槽位（内容+标签+附件全部移除）
clipslots clear <slot> [--group <id>] [--page <uuid>|--page-name <名称>]

# 新建槽位组（返回 id）；页面已满(10组)会报错 → 先 create-page
# v2.9.4: 同一页面内不允许重名（大小写/去空格后完全相同即冲突）；冲突时返回
#   {"ok":false,"error":"a group named '<name>' already exists on this page"}
#   → 改个名或加 -2/-3 后缀重试。不同页面允许同名。
# ⚠️ 并发约定：需要建多个组时，create-group 必须【顺序调用】，不可并行。
#   组的排序按创建先后确定，并行调用会导致组排序不确定（顺序错乱）。
#   请等前一条 create-group 返回后再发下一条。
clipslots create-group <name> [--page <uuid>|--page-name <名称>]

# 新建页面（返回 id）；页面名不可重复
# v2.9.33: 同步创建一个空的「默认槽位组」，并在返回 JSON 附带 defaultGroup：
#   {"ok":true,"page":{"id":"...","name":"..."},"defaultGroup":{"id":"...","name":"默认槽位组"}}
#   → 新建页面后直接用 defaultGroup.id 写入，无需再跑 groups/list 查询。
# v2.9.42: 可选 --group-name 直接给默认组命名（返回的 defaultGroup.name 即传入的名称）：
#   不传 --group-name → 行为与原来完全一致（向后兼容），defaultGroup.name = "默认槽位组"；
#   传了 --group-name → 建页后把 defaultGroup 直接命名为指定名称。返回结构不变。
#   → 推荐建库时直接带上 --group-name，第一个组即为实际用组，避免残留废组。
clipslots create-page <name> [--group-name <第一个组的名称>]

# 重命名一个槽位组（v2.9.42）；把指定 group 的 name 改为新名称
# 同页内名称不可重复；重名时返回 {"ok":false,"error":"a group named '...' already exists on this page"}
# 成功返回 {"ok":true,"group":{"id":"...","name":"..."}}
# 可选 --page-name 校验：若提供且与该组所属页不符，返回页面不符错误，防止误改错页的同名组
clipslots rename-group <group-id> --name <新名称> [--page-name <页面名>]

# 删除一个槽位组（软删除）；其数据目录移动到 .trash（可人工恢复，v2.9.5 起 .trash 自动清理）
# 成功返回 {"ok":true,"deleted":"<id>","movedToTrash":true}
# id 不存在返回 {"ok":false,"error":"group <id> not found"}
# ⚠️ 默认组 `default` 删不掉：返回 {"ok":false,"error_code":"DEFAULT_GROUP_PROTECTED"}（实测 2.11.7）。
#    遇到它不要重试、不要换 --force，直接告诉用户「默认组受保护，只能清空槽位（clear）不能删组」。
# ⚠️ 只接受组 id（位置参数），不接受组名，也没有 --group-name。要按名字删：先 groups 拿到该组 id 再删。
clipslots delete-group <id>

# 删除一个页面及其下所有槽位组（软删除）；相关数据目录移动到 .trash（可人工恢复，v2.9.5 起 .trash 自动清理）
# 成功返回 {"ok":true,"deleted":"<id>","movedToTrash":true}
# id 不存在返回 {"ok":false,"error":"page <id> not found"}
# ⚠️ 默认页 `default_page` 删不掉：返回 {"ok":false,"error_code":"DEFAULT_PAGE_PROTECTED"}（实测 2.11.7），同样不要重试。
# ⚠️ 只接受页面 id（位置参数），不接受页面名。要按名字删：先 pages 拿到该页 id 再删。
clipslots delete-page <id>

# 任意子命令加 --help / -h 返回该命令的用法与参数说明（v2.9.5）
# 返回 {"ok":true,"command":"write","description":"...","flags":[...],"usage":"clipslots write ..."}
clipslots write --help
clipslots delete-group -h
```

### 槽位缩略图（v2.11.2 新增）

```bash
# 给槽位配一张「封面图」。卡片与轮盘会优先展示它，没有时才回退到自动生成的预览。
# 图片被统一压成最长边 1024px 的 JPEG 存进槽位；不改动槽位主体与附件。
# 支持 PNG / JPEG / HEIC / TIFF / GIF / BMP / WebP；SVG / PDF 会返回 INVALID_IMAGE。
# 路径支持 ~ 与相对路径。
clipslots set-thumbnail <slot> --image <path> [--group <id|name>] [--group-name <名称>] [--page <uuid>|--page-name <名称>] [--if-absent]

# --if-absent：仅当槽位「还没有」手动缩略图时才写入（幂等护栏，推荐批处理时默认带上）。
#   已有缩略图时返回 {"ok":false,"error_code":"THUMBNAIL_ALREADY_SET"}，磁盘零改动。
#   不带该 flag 则直接覆盖，返回体里 replaced:true 表示顶掉了旧封面。
# 成功返回 {"ok":true,"slot":1,"group":"...","source":"/abs/path.png","thumbnailId":"...","thumbnailBytes":12160,"hasManualThumbnail":true,"replaced":false}

# 批量设置（stdin 传 JSON 数组）。item 键名必须是 snake_case（实测 2.11.7）：
#   允许的键：slot(必填,int) / image(必填,path) / group(组名或 id) / page(页面 uuid) / page_name(页面名) / if_absent(bool)
#   ✅ "page_name":"素材"  ❌ "pageName":"素材"（写成驼峰会被忽略；组名跨页重名时直接 AMBIGUOUS_GROUP、整批零写入）
#   ✅ "if_absent":true    ❌ "ifAbsent":true（写成驼峰保护失效，会直接覆盖已有封面）
#   注意与 write --batch 的差异：set-thumbnail --batch 的 item 支持 page/page_name 消歧（已实测生效）；
#   write --batch 的 item 不支持，只能靠命令级 --page-name 或 item 里给组 id。
echo '[{"slot":1,"image":"~/a.png","group":"设计稿","page_name":"素材"},{"slot":2,"image":"~/b.jpg","if_absent":true}]' \
  | clipslots set-thumbnail --batch [--stop-on-error]
# 两阶段契约与 write --batch 一致：预检（路径存在性 + 可解码 + 组/页解析 + 重复目标 + if_absent 冲突）
#   任一失败 → 整批零写入（preflight_passed:false, written:0）；执行期失败 → 前项成功、后项 not_executed。

# 移除手动缩略图，回落到自动生成的预览。槽位内容/附件/标签均不受影响。
# 本来就没有缩略图时返回 {"ok":false,"error_code":"NO_MANUAL_THUMBNAIL"}。
clipslots clear-thumbnail <slot> [--group <id|name>] [--group-name <名称>] [--page <uuid>|--page-name <名称>]
```

> ⚠️ **`set-thumbnail` ≠ `write-attachment`，别混用**：`set-thumbnail` 只是给槽位「配张封面」，图片本身不会成为槽位的内容；`write-attachment` 才是把图片作为附件**存进**槽位。用户说「给这个槽位配个封面/图标/缩略图，看着好找」→ `set-thumbnail`；说「把这张图存进去/附上这张图」→ `write-attachment`。

> 写入后请用 `read <slot>` 的 `hasManualThumbnail` / `thumbnailBytes` 自检：`thumbnailBytes` 应与 `set-thumbnail` 回执里的数值一致。GUI 开着时会在约 1 秒内自动刷新卡片与轮盘，无需重启 App。

> 说明：`write-attachment` 的文件路径支持 `~` 与相对路径；图片扩展名归 `image` 类型，其余归 `file`。

> ⚠️ 注意：`write-attachment` 不支持文件夹路径。如需上传文件夹内的文件，应遍历该文件夹，将所有文件路径逐一传入；不得未经用户确认将文件夹压缩为 ZIP 后上传。如用户意图不明，必须先询问澄清。

### 已知能力 / 限制（v2.9.58）

- ✅ **`rename-group` 重命名槽位组**（v2.9.42 新增）：把指定 group 的 name 改为新名称，成功返回 `{"ok":true,"group":{"id":"...","name":"..."}}`。同页内名称去重规则与 `create-group` 一致，重名返回 `a group named '<name>' already exists on this page`；可选 `--page-name` 做归属校验（组不在该页则返回页面不符错误），防止误改错页的同名组。常用于「建页后延迟命名默认组」或整理时改名。
- ✅ **`create-page --group-name` 零废组建库**（v2.9.42 新增）：建页时直接把默认组命名为指定名称，返回的 `defaultGroup.name` 即传入名称，返回结构不变。不传 `--group-name` 完全向后兼容（`defaultGroup.name = "默认槽位组"`）。这样第一个组就是实际使用的组，不再残留一个闲置的「默认槽位组」废组。
- ✅ **未知 flag 报错**（v2.9.7 R1）：命令收到它不支持的 `--flag` 会返回 `ok:false`（`unknown flag: --xxx for command '...' (allowed flags: ...)`），便于发现拼写错误；不确定某命令支持哪些 flag 时先跑 `<cmd> --help`。仅校验 `--flag`，位置参数不受影响。
- ✅ **`list` 分页**（v2.9.7 S2）：传 `--page-size <N>`（>0）按页返回该组槽位并附带 `pagination:{pageNum,pageSize,total,totalPages,hasMore}`，可用 `--page-num <N>`（从 1 开始）翻页；不传 `--page-size` 则返回全部（无 pagination 字段，向后兼容）。注意 `--page-size`/`--page-num` 与用于指定/约束页面的 `--page <id>`/`--page-name` 是两回事：后者会把 `--group` 匹配限定到该页面（v2.9.32），且只传页面不传组时返回该页所有组的槽位（A3）。
- ✅ **`write` / `write-attachment` 支持 `--label`**（S3）：写入槽位主体或追加附件时可同时设置标签，减少一次额外的调用往返。
- ✅ **子命令级 `--help` / `-h`**（v2.9.5）：任意子命令加 `--help` 或 `-h` 返回该命令的独立说明（`{command,description,flags,usage}`），不必再解析顶层 `help` 的整表。
- ✅ **`.trash` 自动清理**（v2.9.5 新增；v2.10.16 上限调整）：`delete-group`/`delete-page` 的软删除数据会在删除时与 app/CLI 启动时自动清理，默认保留最近 30 天、最多 200 条（v2.10.16 起由 50 条上调至 200 条），超出的最旧条目被物理删除。删除仍是"先移动到 `.trash`"，30 天内且未超上限的条目仍可人工恢复，因此删除依旧可安全用于整理。
- ✅ **`delete-group` / `delete-page` 软删除**（v2.9.4 新增）：删除是"移动到 `.trash`"而非物理抹除，可人工恢复；因此可安全用于整理。删除不存在的 id 返回 `ok:false`（`group/page <id> not found`），不会误删。
- ✅ **`create-group` 同页去重**（v2.9.4 新增）：同一页面内不允许出现同名槽位组，冲突返回 `a group named '<name>' already exists on this page`；不同页面之间允许同名。批量导入/自动建组时遇冲突请改名或加 `-2`/`-3` 后缀。
- ⚠️ **`create-group` 必须顺序调用**：组的排序按创建先后确定，需要一次建多个组时**不可并行**发起 `create-group`，否则组排序不确定（顺序错乱）。务必等前一条返回后再发下一条。
- ✅ **跨进程写锁**（v2.9.4 新增）：CLI 与 GUI 的并发写通过 `flock()` 串行化，不再互相覆盖；锁争用超时（约 5s）返回 `storage is busy (lock timeout)`，稍后重试即可。
- ✅ **`paste` 支持纯附件槽位**：主体为空、仅有附件的槽位，`paste` 会把附件的文件 URL 写入系统剪贴板（`clearContents` 后 `writeObjects([NSURL])`），返回 `attachmentsCopied`（无法解析出文件路径的附件会被跳过并计入 `attachmentsSkipped`）。旧版"纯附件槽位无法 paste"的限制已在 v2.9.3 修复。
- ✅ **`search` 命中附件文件名**：搜索的匹配范围已扩展到"预览 + 正文 + 标签 + 附件文件名"，因此模式C（纯附件）槽位可通过文件名被搜到。旧版"搜索不覆盖附件名"的限制已在 v2.9.3 修复。
- ✅ **`search` 按组精确过滤修复 + 支持页面定位**（v2.9.58）：`search --group <UUID>` 在早期 CLI（2.9.57）中可能错误返回空结果，v2.9.58 已修复；现同时支持 `--page`/`--page-name`，采用与其它命令一致的「页面+组」定位规则（只传页面不传组时搜索该页所有组）。⚠️ 若在异常环境中遇到 `search` 按组返回异常，**不要静默扩大到 `--all-groups`**（会污染结果范围），应改用定向 `list`/`read` 替代核对。
- ✅ **`search` 全文匹配**（v2.11.7 实测确认）：搜索匹配的是槽位**全文**，不再局限于 `preview` 的前 100 字——正文中后段（实测第 400 字处）的词也能命中，命中项的 `preview` 里可能看不到关键词，这是正常的，需要 `read <slot>` 看全文。⚠️ 但**范围不会自动放大**：不传 `--all-groups` / `--page-name` / `--group-name` 时只搜 `default` 组，全库搜索必须显式 `--all-groups`。
- ⚠️ **`clipslots help` 文案里 `.trash` 写「最多 50 条」是旧文案**，实际上限自 v2.10.16 起为 **200 条**（保留 30 天不变）。以本节说明为准，不必据 help 文案调整删除策略。
- ⚠️ **`write` 仅写纯文本主体**：`--text` 必填，仅接受 UTF-8 文本；`--text -` 从 stdin 读取时若不是合法 UTF-8（二进制）会返回 `ok:false` 且**不清空槽位**。把图片/文件放入槽位请用 `write-attachment`（或走 GUI）。
- ✅ **`write` 覆盖写入前自动备份旧内容**（v2.10.16 新增）：`write` 覆盖已有槽位内容时，会在覆盖前把被覆盖槽位的旧内容软删除备份进 `.trash/`（30 天内可人工恢复），因此即使误覆盖也有回滚窗口。此备份同样受 `.trash` 自动清理约束（保留最近 30 天、最多 200 条）。仍建议写入前用 `--if-empty` 或 `read`/`list` 预检，把备份当作兜底而非常规回滚手段。

## 1.4 错误码对照表（`ok:false` 时照此处理，实测于 CLI 2.11.7）

失败返回体一定含 `error_code`（全大写下划线）。**按 `error_code` 分支，不要解析 `error` 文案**（文案会变，可能是中文也可能是英文）。

| error_code | 含义 | 正确处理动作（不要重试原命令） |
|---|---|---|
| `AMBIGUOUS_GROUP` | 组名跨多页重复，没给页面 | 补 `--page-name <页名>` 重发；返回体的 `candidates:[{group,page,pageName}]` 已列出所有候选，也可直接用其中的 `group`（UUID）当 `--group` |
| `GROUP_NOT_FOUND` | 该页里没有这个组 / 组 id 不存在 | 先 `groups --page-name <页名>` 看真实组名，再改名重发；不要新建同名组顶替 |
| `GROUP_REQUIRED` | 只给了页面没给组（单槽操作与 `write --batch` 都不允许） | 补 `--group-name` 或 `--group` |
| `SLOT_NOT_EMPTY` | `--if-empty` 命中非空槽（批量时整批零写入） | 换一个 `empty:true` 的空槽；确实要覆盖 → 问用户确认后改用 `--overwrite-text` |
| `INVALID_ARGUMENT_COMBINATION` | `--if-empty` 与 `--overwrite-text` 同传 / 缺 `--text` / 传了不存在的 flag（拼错，如 `--lable`） | 读 `error` 里的 `allowed flags: ...`，或跑 `clipslots <cmd> --help` 后改正参数 |
| `INVALID_SLOT` | 槽位号越界 | 槽位只有 1..10；超出请建续组 `-2` 而不是写 11 |
| `INVALID_LIMIT` | `search --limit` 传了 0 或负数 | 传正整数（默认 50） |
| `BATCH_DUPLICATE_TARGET` | 批量里两个 item 落到同一 (组,槽)，整批零写入 | 看返回体 `duplicates:[下标...]`，去重后重发整批 |
| `DEFAULT_PAGE_PROTECTED` | 试图删默认页 `default_page` | 停手，告知用户默认页不可删；要清内容用 `clear` |
| `DEFAULT_GROUP_PROTECTED` | 试图删默认组 `default` | 停手，告知用户默认组不可删；要清内容用 `clear` |
| `THUMBNAIL_ALREADY_SET` | `set-thumbnail --if-absent` 且已有封面 | 想换封面 → 去掉 `--if-absent`（会覆盖，返回 `replaced:true`）；否则跳过 |
| `NO_MANUAL_THUMBNAIL` | `clear-thumbnail` 但该槽本来就没手动封面 | 视为已达目标，跳过即可，不是错误状态 |
| `INVALID_IMAGE` | 给 `set-thumbnail` 传了 SVG/PDF 等矢量或文档格式 | 先导出成 PNG/JPEG 再设；或告知用户该格式不支持 |
| 文案含 `storage is busy (lock timeout)` | 另一进程（通常是 GUI）占着写锁约 5s | **这一条可以重试**：等 1~2 秒重发一次，不是数据损坏 |

## 1.5 环境与兼容（高级用法）

- **`CLIPSLOTS_DATA_DIR` 覆盖数据目录**：

  ```
  CLIPSLOTS_DATA_DIR=/path/to/dir clipslots <command>
  ```

  说明：覆盖默认数据目录（`~/.local/share/clipslots`），锁文件路径同步变更。GUI 从 Finder 启动时不继承 shell 环境变量，设此变量只影响 CLI，两端数据目录会分离，请谨慎使用。

## 2. 存入位置决策流（决定存到哪个页面/组）

先决定"存到哪个页面/哪个槽位组"，再按第 3 节判定"具体怎么放（模式A/B/C）"。核心是**默认最保守、不碰已有数据**。

1. 先判断：用户有没有指定目标页面/组？
2. **【没有指定 = 默认】** 优先"新建页面 + 复用其默认组"（最安全，不碰已有数据）。
   - **新建页面直接给默认组命名（v2.9.42，推荐「零废组」姿势）**：`create-page` 现在**同步**创建页面 + 一个空的默认组，并在返回 JSON 里附带 `defaultGroup:{id,name}`。建库时**直接带上 `--group-name` 给默认组命名**，第一个组即为实际使用的组，无需再跑 `groups`/`list` 查询，也不会残留闲置废组：
     ```bash
     # 新推荐做法（零废组）：defaultGroup 直接就是第一个实际用的组
     create-page "Q3项目" --group-name "品牌VI"        # defaultGroup 直接命名为「品牌VI」
     create-group "产品图" --page-name "Q3项目"         # 后续分类组顺序建
     create-group "活动Banner" --page-name "Q3项目"
     ```
     若建页时还不知道第一个组名（需延迟命名），可先建页拿 `defaultGroup.id`，再用 `rename-group` 命名：
     ```bash
     create-page "Q3项目"                                       # 得到 defaultGroup.id
     rename-group <defaultGroup.id> --name "品牌VI" --page-name "Q3项目"
     ```
   - ⚠️ **切勿沿用旧做法**：旧版先 `create-page "Q3项目"`（得到"默认槽位组"废组）再 `create-group "品牌VI"`（第一个实际用组），会残留一个闲置的默认组。建库时用 `--group-name` 或 `rename-group` 复用默认组，实现零废组。
   - 说明：v2.9.33 起 `create-page` 同步建页 + 建组（已删除旧的存储层惰性补建逻辑，避免时序空窗导致误建多余组）。只有需要额外分类时才 `create-group`。
   - 实现说明：当前版本 `create-page` 无硬性数量上限，故默认此分支恒可执行；下面"页面已满"子分支是为未来引入页面上限预留的预案。
   - 若未来引入页面数上限并达到上限：暂停并询问用户如何存（选项 A：选一个现有页面新建组；选项 B：覆盖某页面，需二次确认）。
3. **【指定了页面、未指定组】** 标准判空流程：先 `groups --page-name <页面名>` 列出该页所有组，再 `list --page-name <页面名>` 看各组槽位的 `empty`/`attachmentCount`，找"有空槽"的组：
   - 找到 → 提示用户确认后存入。
   - 所有组都无空槽 → 在该页面新建槽位组。
4. **【指定了页面 + 组】**：
   - 目标位置无内容 → 直接存入。
   - 目标位置有内容 → 用 CLI 原生护栏控制，不自作主张：
     - `--if-empty`（写空槽保护）：目标槽非空（主体或附件任一非空）时返回 `SLOT_NOT_EMPTY` 并 exit 1，避免误覆盖；判空口径与 `list`/`read` 的 `empty` 一致（不含 label）。
     - `--overwrite-text`（明确覆盖文本）：确需替换文本时使用，只覆盖槽位文本主体，**保留已有附件和标签**。
     - `--if-empty` 与 `--overwrite-text` 互斥，同传返回 `INVALID_ARGUMENT_COMBINATION`。
   - 冲突时给用户选项、不自作主张：① 同页面新建槽位组；② 新建页面 + 新建槽位组；③ 找空槽依次存（组满则建续组 -2/-3，续组满则新建页面 + 新组）。

**核心原则：**
- 默认最保守：默认只"新建"，不碰已有数据。
- 用户指定才询问：确认意图后再操作。
- 冲突时给选项，不自作主张。
- 复用已有页面时不改页面名，只按命名规则给"新建的槽位组"命名。

> 命名规则见第 5 节（页面名 ≤10字[新建时]、组名 ≤10字、Label ≤10字；续组用 `-2`/`-3`；优先用文件夹名/任务名，序号用阿拉伯数字）。"空槽"定义见第 0 节"空槽判定"：主体与附件都为空才算空槽（用 `empty:true` 判定，已含附件检查）。

## 3. 存入逻辑（把一批内容/文件放进槽位的判定规则）

给定「一段文本 + 若干文件」时，按下述**优先级从高到低**决定放法：

1. **用户明确要求槽位留空** → 走【模式C】。触发词例：「放附件」「槽位另有用途」「我要（自己）编辑槽位」。
2. **有文本** → 【模式A】：文本写入**槽位主体**（`write`），其余文件按顺序进**附件**（`write-attachment`）。
3. **纯图片（无文本）** → 【模式B】：**首图**写入槽位主体，**其余图**按顺序进附件。
4. **其他情况**（纯视频 / 纯文档 / 混合非文本文件） → 【模式C】：**全部文件进附件**，槽位主体留空。

> **封面 vs 存图（v2.11.2）**：用户说「配个封面/图标/缩略图」→ `set-thumbnail`（只设展示用的封面，不占用槽位内容）；说「把图存进去/附上图片」→ `write-attachment`（图片本身作为附件入库）。两者互不冲突，可以先 `write-attachment` 存图、再 `set-thumbnail` 用同一张图当封面。

| 模式 | 主体(items) | 附件(attachments) | 命令 |
|---|---|---|---|
| A 有文本 | 文本 | 其余文件按序 | `write` + `write-attachment` |
| B 纯图片 | 首图 | 其余图按序 | `write`(首图)* + `write-attachment` |
| C 留空 | 空 | 全部文件按序 | 仅 `write-attachment` |

> *当前 CLI 限制：模式 B 退化为模式 C——首图无法通过 CLI 写入主体，全部进附件，Agent 执行时无需额外说明，直接按模式 C 处理即可。

## 4. 容量管理

- **槽位溢出**：一个组只有 10 个槽位。当内容超过 10 个槽位时，**新建同名组并加后缀 `-2` / `-3` …**（`create-group "<原名>-2"`），继续放。
- **页面溢出**：一个页面最多 10 个槽位组。当 `create-group` 返回「页面槽位组已达上限」错误时，**新建页面**（`create-page`）后再在新页面建组。
- ⚠️ **每页填满优先（硬性约束）**：每页**最多 10 个槽位组**（CLI 硬限制）。批量建组时**必须优先把当前页填满（达到 10 组上限）再创建新页面**，**不得**以「留余量」「均衡布局」「美观分布」等理由主动减少每页组数。例如需要建 15 个组时，正确做法是「第 1 页 10 组 + 第 2 页 5 组」，而**不是**「每页 7~8 组均分」。只有 CLI 明确返回「页面槽位组已达上限」错误时才开新页。

## 5. 命名规则

- **长度**：页面名 ≤ 10 字，组名 ≤ 10 字，Label ≤ 10 字。
- **取名来源**：优先用**文件夹名 / 任务名**；序号用**阿拉伯数字**（如 `导入 1`、`方案 2`）。
- **续组**：用 `-2` / `-3` 后缀，**不要用「续」**（如 `产品图-2`，不写 `产品图续`）。

  > ⚠️ 续组 `-2`/`-3` 后缀**只用于同名组需要扩容时**（如「设计素材」组满了 → 建「设计素材-2」）。若组名本身已是递增序号（词1、词2…词10），则延续命名为「词11」「词12」，不加 `-2`/`-3` 后缀。
- **改名**：用 `rename-group` 改组名时同样遵守组名 ≤ 10 字的建议规则，并注意同页内不可与已有组重名。

## 6. 典型场景（按讨论结果整理）

### 场景一：客服 —— 常用话术/回复模板
- 内容多为**纯文本**（模式A，无附件）。
- 按主题分组：一个组放一类话术，组名用主题（≤10字，如 `售后退款`），每条话术占一个槽位，Label 用短标识（≤10字，如 `催发货`）。
- 写入：`clipslots write <slot> --text "<话术>" --group <组> --label <短标签>`。
- 取用：`clipslots paste <slot> --group <组>` → 提示客服在对话框 Cmd+V。
- 话术超过 10 条 → `create-group "售后退款-2"`。

### 场景二：设计师 —— 共享素材库（一个文件夹的成套素材）
- 一个素材文件夹对应**一个槽位组**，组名用文件夹名（≤10字，超长则截断/概括）。
- 判定：
  - 文件夹含说明文字 → 模式A（说明进主体，素材文件进附件）。
  - 纯图片 → 模式B（首图进主体做封面，其余进附件）。
  - 图/视频/文档混合 → 模式C（全部进附件，主体留空）。
- 每个槽位承载一组相关素材：主体 + 有序附件；Label 标注用途（≤10字，如 `主视觉`）。
- 素材项超过 10 个槽位 → `create-group "<文件夹名>-2"`；该页组数满 → `create-page` 新建页面（如按项目/客户分页）。

### 场景三：设计师 —— 一对一交付
- 面向单个接收者的定向交付：通常「一句交付说明 + 若干成品文件」→ 模式A（说明进主体，成品进附件），或接收者要自行编辑 → 模式C（全部进附件、主体留空）。
- 组名用接收者/任务名（≤10字），页面可按「交付对象」或日期组织（页面名 ≤10字）。
- 交付后可 `paste` 关键文件到剪贴板，或直接告知对方在 GUI 对应组/页取用。

## 7. 智能体使用规则

1. **先读后写**（三步清单）：`① 读（list/read 查现有状态）→ ② 分析（判断目标槽位/页面/组）→ ③ 执行（write/create）`。优先写 `empty:true` 空槽，批量覆盖前与用户确认。新建页面时直接带 `--group-name` 给默认组命名（零废组，v2.9.42），无需额外 `rename-group`。
2. **空槽判定**（详见第 0 节"空槽判定"）：一个槽位为空当且仅当**主体内容与附件列表都为空**；有主体或有附件都算非空。扫描空槽必须同时检查主体与附件——直接用 `empty:true` 判定即可（v2.9.3+ 的 `empty` 已含附件检查，`list` 另有 `attachmentCount`），不要只看主体。
3. **存入位置**：先按第 2 节"存入位置决策流"决定存到哪个页面/组（默认最保守：只新建、不碰已有数据；冲突时给选项不自作主张），再按第 3 节判定模式A/B/C。
4. **以 `ok` 判断成败**，`ok:false` 时按 `error_code` 分支处理（对照第 1.4 节表格），`error` 文案只用于给用户解释，不要用来做程序判断。**同一条失败命令不要原样重试**（唯一例外：`storage is busy (lock timeout)`，等 1~2 秒可重试一次）。
5. **槽位范围** 1..10，越界返回 `ok:false` + `error_code:"INVALID_SLOT"`。
6. **主体 vs 附件**：`write` 改主体（保留附件）；`write-attachment` 只加附件（不动主体）；二者配合实现模式A/B/C。
7. **paste 语义**：只送入剪贴板，不自动粘贴；需要真正粘贴时提示用户 Cmd+V。纯附件槽位（主体空）也可 `paste`，会把附件文件 URL 送入剪贴板（v2.9.3+）。
8. **多组/多页**：优先使用 `--group-name` / `--page-name` 直接按名称操作，无需手动获取 UUID。**只要指定了组，就必须同时带 `--page-name`**（组名可跨页重复，漏带页面会 `AMBIGUOUS_GROUP` 或写到别的页）。两个例外必须用 id：`delete-group <id>` / `delete-page <id>` 只吃 id，`rename-group <group-id>` 也只吃 group id——先 `groups` / `pages` 拿 id 再操作。
9. **容量与命名**：严格按第 4、5 节；溢出用 `-2/-3` 或新页面，命名遵守字数上限与阿拉伯数字序号。**每页必须优先填满 10 组再开新页**（第 4 节硬性约束），不得以「留余量」「均衡布局」等理由主动减少每页组数。
10. **批量前先确认分页方案**：当批量操作涉及**多页 / 多组结构**（预计超过 1 页，或总组数 > 10）时，**必须先向用户输出完整的分页方案**——列明「每页几个组、每组几个槽、总槽数、共几页」——并**等待用户确认后再开始执行写入**。禁止在未确认结构的情况下直接批量建组/写入。批量建组前先 `groups --page-name <页名>` 确认当前页剩余组数（10 - 已有组数），不要等 `create-group` 报「页面已满」错误再处理。
11. **富文本**：`read` 的 `htmlSource` 非空表示有 HTML 源；CLI `write` 只写纯文本，需保 HTML 走 GUI。
12. **批量写入用 `--batch`**：当需要向同一组（或跨组）写入 **>3 个槽位**时，优先使用 `write --batch`（v2.9.57+），一次进程完成全部写入，比 shell 循环逐条 `write` 快得多且顺序有保证（按数组下标顺序，单进程内串行）。循环逐条 `write` 仅在 `--batch` 不可用时作为降级方案。**item 键名必须是 snake_case（`if_empty` / `overwrite_text`），写成驼峰会被静默忽略导致误覆盖**，详见第 1 节 `write --batch` 说明。
13. **搜索必须显式给范围**：`search "词"` 不带范围参数时只搜 `default` 组，通常返回空结果。全库搜用 `search "词" --all-groups`，限定页用 `--page-name`，限定组用 `--group-name` + `--page-name`。搜不到时先确认是不是漏了 `--all-groups`，再下"库里没有"的结论。
14. **兜底规则**：任何不确定的情况下，**新建页面 + 新建组**，每组只放 1 个槽位。污染用户已有数据比浪费空槽位更严重。⚠️ 注意 `--force` **只用于跳过跨进程写锁**（`write`/`clear`/`write-attachment`/`set-thumbnail`/`clear-thumbnail` 支持），它**不能**用来解决 `SLOT_NOT_EMPTY`、`AMBIGUOUS_GROUP`、`DEFAULT_*_PROTECTED` 等冲突；正常情况下**不要加 `--force`**（会绕过 GUI/CLI 并发保护，有互相覆盖风险），遇到锁超时优先「等 1~2 秒重试」。

---
> 本文件为随 App bundle 打包、供各 Agent 实际读取的正式版本，接口以 `clipslots help` 实际输出为准；场景部分按当前讨论整理，可再据实际使用微调。CLI 与 GUI 共享 `ClipSlotsKit` 数据层，随 app 版本演进。
