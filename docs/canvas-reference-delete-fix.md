# 连接素材缩略图与节点直接删除

## 用户可见行为

- 生成面板的连接引用显示上游图片/视频缩略图；视频带播放标记，点击定位对应上游节点。
- 上游素材替换、撤销、切换连接或生成新产物后，引用缩略图自动更新。
- 文字连接保留文字入口；槽位连接保留图片数量。尚无产物的生成节点不会把入参冒充输出。
- 选中节点后，Delete或Forward Delete直接删除，支持多选，有下游连接也不弹二次确认。
- Cmd+Z可恢复节点、连线和附件内容；Shift+Cmd+Z重做。实际编辑提示词时Delete只删除文字。
- 保留217803的素材/生成节点区分和Tika长任务修复。

## 实现

`CanvasNodeComposer`复用主卡片的媒体选择及异步缩略图缓存。`CanvasRenderBoundary.Key`追踪上游节点和连线身份，读取上游主媒体位于缓存边界内；文件检查、解码沿后台队列执行。

删除入口移除`pendingDeletion`及alert，键盘和菜单仍统一进入`performDelete`，保留既有历史事务和私有内容暂存恢复。未改变Delete键码或放宽文本编辑保护：本轮已复现的删除阻塞来自有下游引用时的确认流程。

## 当前验证

- Debug、Release构建与修复包签名校验通过。
- 核心回归：32,715通过，0失败。
- 引用/删除专项：简洁浅色、多彩深色各24通过，0失败。
- 原画布回归：74通过，0失败；平移期间节点正文重算为0。
- 专项覆盖：单选/多选直接删除、真实编辑器焦点保护、键盘撤销/重做、连线与附件字节恢复、缩略图点击定位、素材替换/撤销刷新、同数量换连接、mock生成后显示产物。
- 浅/深主题截图已检查；视频测试文件为灰度帧，缩略图显示对应帧。
- 2026-10-02用户解锁后已重跑两主题专项和原画布回归，均通过；专项报告明确`sessionLocked: false`，原画布运行前后也确认桌面未锁定。
- UI运行使用隔离bundle、数据和mock Crate，原生事件队列覆盖点击、键盘与焦点；不调用付费生成服务、不修改用户画布。

最终报告及截图：`build/validation/input-upload-reference-delete-final-*`、`build/validation/canvas-report.json`；完整画布运行记录`.dbg/reference-delete-final-canvas.log`。此前锁屏运行仅作诊断。调试记录保持`debug-canvas-reference-delete.md`（OPEN），等待用户使用反馈。

## 本机更新

2026-10-02已替换并启动`/Applications/ClipSlots.app`，版本**2.17.8（217804）**。

- 旧App备份：`build/backup/ClipSlots-217803-before-reference-delete-fix-20261002-134244.app`。
- 画布文档备份：`build/local-reference-delete-fix-20261002-134244/canvas-data-before-update`。
- App/内置CLI签名与安装包SHA-256校验通过；App已重新启动。
- 页面索引、编辑页及画布Agent会话三份文件替换前后SHA-256一致。
- 安装记录：`.dbg/canvas-reference-delete-install.json`。

保留素材/生成角色区分和Tika长任务修复。未提交、推送或发布远端版本。
