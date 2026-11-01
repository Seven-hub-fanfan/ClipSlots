# 当前候选打包入口

版本和 build 从当前源码 `Info.plist` 读取。以下命令均在候选源码根执行，产品目录与全新输出目录必须显式给定；不会安装、发布或启动 GUI。

```sh
swift build -c release --jobs 2 --product ClipSlots
swift build -c release --jobs 2 --product ClipSlotsCLI
swift build -c release --jobs 2 --product ClipSlotsMCP
python3 scripts/package_agent_lite.py \
  --products-dir "/absolute/products/release" \
  --output "/absolute/existing-parent/new-candidate" --allow-adhoc
python3 scripts/audit_agent_lite.py \
  --app "/absolute/new-candidate/ClipSlots.app" \
  --manifest "/absolute/new-candidate/manifest.json" \
  --output "/absolute/existing-parent/new-size-audit.json"
python3 scripts/create_agent_lite_dmg.py \
  --app "/absolute/new-candidate/ClipSlots.app" \
  --output "/absolute/existing-parent/new-candidate.dmg" \
  --report "/absolute/existing-parent/new-dmg-readback.json"
```

本地 ad-hoc 候选需要显式 `--allow-adhoc`；正式签名复用 `sign_app_bundle.py` 的现有证书和指纹约束。不能以本地签名通过代替 Developer ID、notarization 或发布验收。

三产品分别位于 `Contents/MacOS/ClipSlots`、`clipslots-cli`、`clipslots-mcp`，与现有 CLI 安装和 MCP 查找入口一致。Kit 的全部 36 份资源、AppIcon 与内置 manager Skill 放在 `Contents/Resources`。复制前比对构建资源与当前源资源，签名后比对候选读回；Release Kit 优先解析包内资源和真实可执行文件所在目录，不使用绝对构建目录回退。

`audit_agent_lite.py` 可接受 `--baseline-app` 与 `--baseline-id`，二者必须同时给定。基线必须标明版本与角色，不能把历史 2.17.12 数据当作当前值。源码、产品、资源、App 和 DMG 分别统计，不能将这些重叠视角相加；5% 增长仅是已指定基线上的建议门槛。

默认全目标 Release 构建包含使用 `@testable import` 的 smoke runner，未启用 testing 时会失败。正式产品使用上述三个 `--product` 命令；完整 smoke 回归使用 Debug 或独立启用 testing 的测试构建，不混入生产候选产品身份。

本入口不创建 Preview。旧 Preview 仅设置 data/config，未隔离 gateway journal、市场缓存、UserDefaults 和 Keychain 等全部根。`validate_isolated_candidate.py` 的旧启动结果只适用于原版本，不能作为当前 GUI 隔离证据。`install_agent_lite.py` 仍包含 2.17.11→2.17.12 历史安装和回滚假设，当前候选禁止使用；受保护安装流程须在独立阶段修订验证并取得安装授权。

资源探针执行真实 Kit 合同并读回源字节，不能代替 App 初始化、GUI 手势、真实 IME、最低 macOS 或真实 provider 验收。主树、安装与候选源码的身份必须分别记录。
