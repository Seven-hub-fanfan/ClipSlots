# ClipSlots v2.17.5

修两个用户实机确认的窗口交互 bug，均由 v2.17.4 引入。

## Bug 1｜最小化按钮点了没反应

**根因**（osascript AXPress + stderr NSLog 抓帧确认）：
`didChangeScreenParametersNotification` 在此环境下会随 Dock 增/减 minimize tile 一起发出（外接屏 / Stage Manager / Dock magnification）。这条通知我们订了 `rescueMainWindowVisibility`，v2.11.8 起它无条件对任何 miniaturized 窗口调 `deminiaturize`。抓到的时序：`WillMiniaturize` → `DidMiniaturize` → **~0.6s** 后 `[rescue] deminiaturize` → `DidDeminiaturize`。用户视角：窗口进 dock 一瞬间就自己蹦回来了。

**修法**：把 `deminiaturize` 挪到 `needsRescue == true` 之后。miniaturized 状态下 `window.frame` 仍是入 dock 前的位置，用它判定是否离屏；不需要救就是用户自愿的最小化，一律不碰。只有窗口真的落到不可见区域（副屏拔掉那种）才 `deminiaturize + setFrame`，保留原自救语义。

## Bug 2｜点程序坞图标唤不回

**根因**：Bug 1 修完后，`applicationShouldHandleReopen` 不再能通过 `rescueMainWindowVisibility` 顺带把窗口 deminiaturize——因为 miniaturized 状态下窗口 frame 还在屏内，`needsRescue == false`。

**修法**：`applicationShouldHandleReopen` 在拿到窗口后**显式** `deminiaturize`（Dock 点击本就是"把窗口拉回眼前"的语义），再调 `rescueMainWindowVisibility` 做几何自救，最后 `makeKeyAndOrderFront + NSApp.activate`（只 orderFront 有时不激活到 frontmost）。

## 实机验证（osascript + `open` + `keystroke`）

在 release DMG (`e103d221...`) adhoc 签名安装到 `/Applications/ClipSlots.app` 后：

| 测试 | 期望 | 实测 |
| --- | --- | --- |
| ① AXPress 最小化按钮 | 进 dock | `WillMiniaturize + DidMiniaturize`，无回弹 ✅ |
| ② `open ClipSlots.app`（≈Dock 点击 reopen）| 出 dock | `DidDeminiaturize` ✅ |
| ③ Cmd+M | 进 dock | `WillMiniaturize + DidMiniaturize` ✅ |
| ④ `reopen` AppleEvent | 出 dock | `DidDeminiaturize` ✅ |

Kit smoke **32342 通过 / 0 失败**。

## DMG

`ClipSlots_v2.17.5.dmg`
SHA256: `e103d221833b5180e4564b081912619d57b57c267c18b64175560f7787dad5d5`
