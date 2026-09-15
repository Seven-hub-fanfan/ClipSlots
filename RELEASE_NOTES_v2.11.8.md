## v2.11.8

版本号从 v2.11.7 升到 v2.11.8，并在本版加入 **ScrollApp 官方插件（动态获取最新版）** 与一个启动阻塞修复。

### 新增：插件市场「官方插件」上架 ScrollApp

「插件」→ 官方插件 Tab 新增 **ScrollApp**（左键长按滚动工具，让鼠标左键长按时像中键一样滚动页面）。

- **下载直链不写死**：条目只声明仓库 `Seven-hub-fanfan/scrollapp-leftclick`。点「获取」时实时请求
  `https://api.github.com/repos/Seven-hub-fanfan/scrollapp-leftclick/releases/latest`，从 assets 里挑 `.dmg`
  的 `browser_download_url`，用系统浏览器打开 → **直接开始下载**，无需在 Release 页面里翻附件。
  ScrollApp 以后发新版，ClipSlots 这边不用改代码、不用发版，拿到的永远是最新版。
- **版本号也是实时的**：卡片/详情页上的版本号来自同一个接口（打开插件市场时异步刷新一次，结果带 TTL 缓存）。
  拿到之前显示「获取中…」——刻意不显示一个写死的兜底版本号，那会在对方发新版后变成一个看起来确定、实际过期的数字。
- **在途状态**：解析直链要先问一次网络，所以「获取」按钮有「获取中…」态，避免网络慢时用户连点、开出好几个下载。
- **降级路径**：离线 / GitHub 限流 / 该版本确实没有 dmg → 打开 `releases/latest` 页面，用户自己点 assets，不静默失败。
- **安全校验**（纯逻辑，已被 smoke 覆盖）：只接受 `https`，host 限定 `github.com` / `githubusercontent.com` 及其子域
  （`github.com.evil.example` 这类后缀伪装会被拒），仓库 slug 必须是干净的 `owner/repo`（`a/b/c`、`o/..`、带
  `?`/`#` 的一律拒，避免拼出的请求逃出 `/repos/` 前缀）。
- **安装检测**：App 类条目的检测从单一名字扩成候选列表，`Scrollapp.app` / `ScrollApp.app` /
  `scrollapp-leftclick.app` 任一存在即判为已安装，卡片显示「已安装 ✓」+「打开」。

### 修复

- **「仅显示已安装」会把真装了的 App 类插件过滤掉**：该过滤器此前只认 Skill 的 Agent 安装状态，对官方插件 /
  社区插件一律返回未安装 —— 卡片上写着「已安装 ✓」，列表却说它没装。现在 App 类条目按磁盘真实检测结果参与过滤与排序。
- **覆盖安装后首次启动，主窗口在点掉钥匙串授权框之前不显示**：Agent 侧栏在首帧同步读了一次钥匙串判断有没有
  API Key，而 `SecItemCopyMatching` 弹系统授权框时会**阻塞调用线程** —— 主线程卡在钥匙串里，窗口画不出来，
  表现为「更新完点图标没反应，只有一个授权框」。本版新增后台线程探测（`AgentKeychainProbe`），窗口先出来，
  授权框浮在上面。安全语义不变：照样走 ACL、照样弹框、照样只读钥匙串。

> 说明：ad-hoc 签名每次构建都变，因此覆盖安装后首次读钥匙串必然弹一次授权框（点「始终允许」），
> 「隐私与安全性 → 辅助功能」里的勾选也可能需要重新勾一次。这是系统行为，不是 bug。

### 承接 v2.11.7 的全部能力

**侧边栏 Agent（DeepSeek）**：默认 `deepseek-reasoner`，SSE 流式输出、reasoning 默认折叠、API Key 只进系统钥匙串
（`com.clipslots.agent` / `deepseek_api_key`），Skill 勾选后才对模型可见可执行。

**Function Calling：内置 17 个工具直连 ClipSlots CLI**

- 读：`list_slots` / `read_slot` / `search_slots` / `list_groups` / `list_pages`
- 写：`write_slot` / `clear_slot` / `write_attachment` / `set_thumbnail` / `clear_thumbnail`
- 结构：`create_page` / `create_group` / `rename_group` / `delete_page` / `delete_group`
- 其它：`paste_slot`（装进系统剪贴板，不模拟按键）/ `repair_index`

`delete_group` / `rename_group` / `delete_page` 的名称 → ID 解析放在工具层：唯一命中直接执行，同名跨页面多命中回
`AMBIGUOUS_GROUP` 并列出候选，绝不替用户挑一个删。工具集刻意不暴露 `--force`。

**UI**：窗口最小内容尺寸 1060 × 560；顶栏 `CenterReservedRow` 保证中间切换器几何与窗口中线一致；Agent 侧栏贴到
标题栏下沿通高；画布节点即槽位（正文 / Label / 入参文件实时读写），框选、多选拖动、撤销重做、字体设置、
Cmd+数字送槽位进画布；简洁模式皮肤。

### 安全边界

工具执行一律 argv 直传、不经过 shell；Skill 脚本必须落在 Skill 目录内（`../`、绝对路径、`~` 一律拒绝），仅白名单
脚本类型可执行，带超时与输出截断；工具轮次有上限。自动更新下载 DMG 后做 SHA-256 流式校验，不一致即删包中止安装。

### 测试

`swift build` 通过；零依赖 smoke **2111 条断言全部通过**（新增 GitHub latest release 解析与钥匙串探测两组）。
另做真机联网校验：latest 接口返回 ScrollApp `v2.2.3`，解析出的 dmg 直链 `curl -I` 为 302 → 200 且
`content-disposition: attachment`，即点「获取」确实直接下载而不是打开网页。打包后覆盖安装
`/Applications/ClipSlots.app`，App 与 CLI 版本号均为 2.11.8。

### 安装

DMG 为 ad-hoc 签名、未公证。若通过浏览器下载，macOS 可能附加隔离属性；首次打开请右键 → 打开。

SHA256 (`ClipSlots_v2.11.8.dmg`):

```
90eaac5caab6b1acd2351d66a343074a1b3406ffe1cc589bd511060e9875f400
```
