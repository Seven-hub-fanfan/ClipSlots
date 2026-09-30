# ClipSlots v2.17.5

修两个用户实机确认的窗口交互 bug，均由 v2.17.4 引入。

## Bug 1｜最小化按钮 / 关闭 / 缩放 / 标题栏拖拽偶发失灵

**根因**：v2.17.4 起 `CanvasEventInterceptor` 的 `NSEvent.addLocalMonitorForEvents` 把 `.leftMouseDown` 也纳入拦截范围。它是**全 App 级** local monitor，先于 AppKit 的 `sendEvent` 触发，返回 nil 就把事件吞掉。画布模式下窗口开着 `fullSizeContentView`，红绿灯（miniaturize/close/zoom）和标题栏拖拽区都浮在画布之上，坐标同样会落进 anchor.bounds 里；只要 `handle` 里任意一个分支返回 true，那些系统按钮当场失灵，用户体感就是「最小化没反应」。

**修法**：在路由分发前判断 `window.contentView?.hitTest(event.locationInWindow)`。命中 nil = 事件不属于 SwiftUI 内容层（红绿灯 / titlebar container / resize 边框），一律放行，交回 AppKit 默认路由。画布内的事件路由完全不受影响。

## Bug 2｜点击程序坞图标唤不回窗口

**根因**：`applicationShouldHandleReopen` 里只做了 `deminiaturize` + `makeKeyAndOrderFront`，缺少 `NSApp.activate`。当窗口刚从 miniaturized 复原时，仅 orderFront 常常只把窗口 order 到前面而不把 App 激活到 frontmost，用户体感是「点程序坞没反应」。

**修法**：`applicationShouldHandleReopen` 末尾追加 `NSApp.activate(ignoringOtherApps: true)`，与从 Dock 打开 App 的默认体验对齐。

## 验证

- Kit smoke：**32342 通过 / 0 失败**（含 CLI 版本号断言）
- 本机原子替换安装到 `/Applications/ClipSlots.app`

## DMG

`ClipSlots_v2.17.5.dmg`
SHA256: `1f7b8be5752dc2831d7b1c787c8a78a9b3795931e9bd8d23a0b7c96190e859e0`
