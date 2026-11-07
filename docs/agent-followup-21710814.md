# Agent 修复：21710814

本构建修复应用绑定入口、统一模型图标、恢复卡片上的滚轮与原生减速滑动，并调整设置页控件及工作区过渡。

## 应用绑定

实际目录的连接器声明使用 `connectors[].connector_id`。客户端现在按声明解析连接器，兼容别名及授权 URL、表单重试、管理员待批准、多个连接器依次授权和取消后的过期响应隔离。无外部连接器的应用进入本地工具授权。

验证覆盖 14 个外部连接器的状态流程。在线目录中 13 个连接器可用，另有 9 个应用不依赖外部账号；Vimeo 的连接查询与授权入口目前返回上游 404。测试中的授权完成状态来自隔离 fixture，不代表各平台的真实账号均已完成同意。

## 动画来源与实现

TapNow 实机画布加载状态指向 `loading-BWU_g4Wm.webp`，配套组件为 `loading-overlay-CfKK9qM2.js`。资源文件的 SHA-256：

`e90e059cd2c39b8c739a2e00f25fbed5f3e322a69dfe26be4b17d5ea93c798e0`

ClipSlots 直接使用相同文件，由 ImageIO 解码并通过 Core Animation 播放：

- 86 帧，每帧 40 毫秒，3.44 秒循环，保留原始透明边缘。
- 64 px 居中显示，缩放在 0.95 → 1.05 → 0.95 之间以两秒周期变化。
- 黑色背景一秒淡入淡出；内层延迟 0.1 秒，以 0.3 秒显现、0.8 秒退场。
- 后台解码，退场后释放图片和动画；快速重复切换不会被前一次退场的清理影响。
- 遵循系统“减少动态效果”设置。

原始文件一致和原生运行时采样用于验证资源、帧推进、缩放及生命周期；不将这些证据表述为 TapNow 与 ClipSlots 全场景逐帧完全一致。

## 原生验证

2026-11-07 的最终源码通过 Agent 原生集成 343 项、选中与附件 26 项、UI 回归 109 项，共 478 项，零失败。GUI、CLI、MCP 的 Release 构建均通过。核心 43,843 项、连接协议 102 项、模型工作区 65 项和备份检查点 3 项的既有通过结果对应的核心源码未变化。

本机替换与启动验证通过，受保护数据、配置和外部链接保持一致。当前 ad-hoc 签名更新后，系统仍要求确认辅助功能、屏幕录制和钥匙串访问授权；这些授权不由测试结果替代。

在已解锁的 Mac 上构建 DEBUG 版本，再通过磁盘保护入口运行：

```sh
python3 scripts/disk_guard.py check --reserve-gib 0.5
python3 scripts/disk_guard.py run \
  --output "$PWD/.build" \
  --output /private/tmp/clipslots-agent-background-regression \
  --budget-gib 4 -- swift build --product ClipSlots -j 4
python3 scripts/disk_guard.py run \
  --output "$PWD/.build" \
  --output /private/tmp/clipslots-agent-background-regression \
  --budget-gib 4 -- python3 scripts/run-agent-onboarding.py \
  --output /private/tmp/clipslots-agent-background-regression/native-integration
```

Python 需要 PyObjC 的 Quartz 模块以及系统输入和录屏权限。运行器使用隔离测试应用及最小数据 fixture。原生滚动验收使用六张卡片上的 48 px 滚轮输入，以及手势结束后由 AppKit 实际产生的减速滑动，并与非 WebView 区域对照。Quartz 人工注入的独立 momentum 包在原生控件中也不稳定，不作为惯性通过证据。
