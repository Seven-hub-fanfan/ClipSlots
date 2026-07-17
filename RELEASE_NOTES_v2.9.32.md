# ClipSlots v2.9.32 发布说明

本次发布聚焦修复 CLI 中两个会导致 Agent 写错页面 / 误判页面已满的 P0 级 bug，并强化页面作用域语义、同步更新 Skill 文档。

## CLI 修复

- **修复 `--page-name` 不约束 group 匹配范围导致写错页面的 bug（A1，根治）**
  `list` / `read` / `write` / `paste` 在同时传入 `--page` / `--page-name` 与 `--group` / `--group-name` 时，group 匹配现在被限定在该页面范围内，不再全局取第一个同名组。组名允许跨页面重复，此前会命中别的页面的同名组、把内容写到错误页面。

- **新增 page + group 不一致护栏（A2）**
  当 `--page-name X` 与 `--group-name Y`（或 `--group Y`）不一致、Y 不属于 X 页面时，返回 `{"ok":false,"error":"group 'Y' not found in page 'X'"}`，不再静默写到别处。

- **修复 `list --page-name` 回落全局 default 导致误判已满的 bug（A3）**
  `list` 只指定 `--page` / `--page-name` 而不带组时，不再回落到全局 `default` 组，改为返回该页面下所有组各自的槽位，附 `groupCount`（页面无组则为 0）。此前会返回全局 default 组的非空数据，使 Agent 误判新建页面"已满"。

- **`groups` 命令支持 `--page` / `--page-name` 过滤（A4）**
  `groups` 可只返回指定页面下的槽位组，作为 Agent 判断某页面是否有空组的核心原语。

以上改动均向后兼容：不带页面参数时，`list` / `groups` 等命令行为不变。

## Skill 文档更新

- 纠正 `--page-name` 现会约束 `--group-name` 匹配范围的说明，删除旧版注意事项。
- 精确描述新建页面后的默认组机制：`create-page` 只建页面，存储层会在下一次命令时惰性补建一个空的默认槽位组；复用它写入即可，无需重复 `create-group`。
- 下线未实现的 `write --on-conflict`，冲突处理改为"显式读取后判断，或新建组"。
- 补充 `groups --page-name` 判空用法与 `list --page-name`（A3）新语义。
