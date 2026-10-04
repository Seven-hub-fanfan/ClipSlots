# Agent 欢迎页与画布读取范围

历史候选构建：21781103。开发验证使用独立 bundle ID 和 CandidateData；用户随后授权安装，并将此能力纳入正式版 2.17.9（217900）。

## 界面调整

- 删除 ChatGPT Work 页面、页面枚举及模式下拉入口；左上角保留当前 Codex / Agent 标题。
- 独立 Agent 欢迎区复用画布侧栏的模板：问候、创作标题、灵感创作/视频分镜卡片、换一组。
- 独立页内容居中、最大宽度 560pt；卡片字体、背景、边框、旋转角度与侧栏共用实现。
- 卡片继续填入草稿，不自动发送；输入框原有 Enter、Shift+Enter、斜杠菜单和技能引用沿用。

## 当前能力核查

以下读取边界同样适用于正式版 2.17.9，发布过程没有扩展 Agent 的画布读取范围。

| 信息 | 画布侧栏 Agent 当前收到的内容 |
| --- | --- |
| 节点正文 | 用户点击“引用选中素材”后收到，最多 3 个节点、合计 96 KB |
| 节点身份 | 项目/节点/槽位 ID、标题、创建时间和正文版本 |
| 写在正文里的 prompt | 可收到，作为正文快照的一部分 |
| 文本节点的单独生成指令 | 未收到 `CanvasNode.textGenerationPrompt` |
| 连线、上下游依赖及连线用途 | 未收到 |
| 最终生图/视频 prompt | 未自动收到；生成链路另行合并节点自身正文和上游 prompt |
| 模型、比例、数量、视频时长、分辨率等 | 未收到 |
| 图片/视频 | 仅附件名称，不含文件字节或视觉理解 |
| 选中的 Skill | 读取并传递 SKILL.md 规范快照，不新增脚本执行权限 |
| 独立 Agent 页面 | 独立会话，不自动携带当前画布 |

证据入口：

- `CanvasAgentContext.reference(for:)` 只构造正文、附件名称与节点身份快照。
- `AgentCanvasReference` 不包含连线或生成参数字段。
- `AgentChatModel.send` 将明确选择的 `draftReferences` 放入消息。
- `AgentMessage.wireContent` 将引用快照传给后端。
- `CanvasWorkspaceView.startGeneration` 通过 `resolveEdgeInputs` 和 `CanvasEdgeInputs.mergedPrompt` 另行计算最终生成 prompt。

因此，目前可以让 Agent 总结已经提供的文字，但还不能自动分析完整画布流程并保存成可复用 Skill。这次 UI 调整没有扩展画布读取范围。

要实现用户提到的工作流总结，需要补齐：用户选择整个画布或某个子流程 → 预览节点、连线、prompt 与参数的工作流快照 → Agent 提炼步骤、输入输出和参数 → 预览并保存 SKILL.md。这个流程尚未实现，也未执行真实模型调用。

## 验证与产物

构建日志 `.dbg/agent-home-build.log`；原生回归日志 `.dbg/agent-home-native.log`；截图与报告位于 `build/validation/agent-workspace/`。欢迎区截图为 `canvas-agent-workspace-route.png`。

构建与签名校验通过，原生回归 **247/247** 通过，桌面未锁屏。已查看实际欢迎页截图。交付证据位于 `build/agent-home-delivery-20261004/`。

上一候选的报告、截图及清单保留在 `.dbg/home-before-21781102/`。
