// v2.11.7 hotfix15 截图辅助：把鼠标移到指定屏幕坐标并投递真实 mouseMoved 事件。
//
// 用 `CGWarpMouseCursorPosition` 只挪光标、不产生事件，SwiftUI 的 `.onHover` 收不到；
// 所以这里用 `CGEvent(mouseEventSource:)` 连投两次（先落到目标点、再微移 1pt），
// 确保 AppKit 的 hover tracking 一定被唤醒。
//
// 用法：swift scripts/warp_mouse.swift <x> <y>   （屏幕左上原点、逻辑点）
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write("usage: warp_mouse.swift <x> <y>\n".data(using: .utf8)!)
    exit(2)
}

func move(_ point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                        mouseType: .mouseMoved,
                        mouseCursorPosition: point,
                        mouseButton: .left)
    event?.post(tap: .cghidEventTap)
}

move(CGPoint(x: x - 1, y: y - 1))
usleep(120_000)
move(CGPoint(x: x, y: y))
usleep(120_000)
