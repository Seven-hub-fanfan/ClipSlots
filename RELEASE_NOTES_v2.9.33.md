# ClipSlots v2.9.33 发布说明

本次发布把 `create-page` 的「惰性补建默认组」改为「同步建组」，消除新建页面后默认组存在的时序空窗，让 Agent 一步到位拿到默认组 id 直接写入。

## CLI 改动

- **`create-page` 同步创建默认槽位组**
  `create-page` 现在在创建页面的同一事务内同步创建一个空的「默认槽位组」，不再依赖存储层的惰性补建（repair）。新建页面后该页可靠地拥有恰好一个空默认组。

- **返回值新增 `defaultGroup` 字段**
  ```json
  {
    "ok": true,
    "page": { "id": "...", "name": "..." },
    "defaultGroup": { "id": "...", "name": "默认槽位组" }
  }
  ```
  Agent 可直接用 `defaultGroup.id` 写入第一批数据，无需再跑 `groups` / `list` 查询。

- **删除惰性补建机制**
  移除 `repairPageScopedConsistency` 中「为无组页面自动补建默认槽位组」的逻辑，避免两套建组路径共存导致的时序不确定：此前 `create-page` 返回后到补建生效之间存在空窗，`groups` 查询可能暂时返回空组，导致 Agent 误建多余的槽位组。

以上改动向后兼容：GUI 新建页面、批量导入等路径行为不变（导入路径显式建组，不生成多余默认组）。

## Skill 文档更新

- 说明 `create-page` 现在同步返回 `defaultGroup`。
- 决策流改为：新建页面后直接用返回的 `defaultGroup.id` 写入，删除「需要 groups 查询才能拿到默认组 id」的步骤。
- `docs/clipslots-cli-skill-draft.md` 与 `skills/clipslots-manager/SKILL.md` 两份同步更新。
