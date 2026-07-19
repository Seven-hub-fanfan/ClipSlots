# ClipSlots v2.9.47

## 修复

- **修复「重新安装 Skill」逻辑**：旧实现把 bundle 内的 `SKILL.md` 拷贝进各 Agent 的 skill 目录（真实目录），导致 skill 目标从软链退化为真实目录。此后安装逻辑的安全护栏（「目标非软链接，为安全起见未删除」）会拦截重装。现统一为「删旧路径 → 重建软链」：无论目标是软链还是遗留真实目录，先删除，再重建软链指向 App bundle 内 `skills/clipslots-manager`（与插件市场安装逻辑完全一致），彻底避免遗留真实目录导致下次安装被拦截。
- 家目录不可写时，回退系统鉴权弹窗执行 `rm -rf` 删旧路径后重建软链。
- 「卸载 Skill」逻辑复核：`uninstallSkillFromAllAgents` 使用 `removeItem`，软链与真实目录均能正常删除。
